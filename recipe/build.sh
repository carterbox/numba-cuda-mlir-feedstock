#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Local debug builds (compiler cache persists across runs):
#   export SCCACHE_DIR=/home/you/.cache/sccache
#   sccache --show-stats   # "Cache location" must read: Local disk: $SCCACHE_DIR
#   rattler-build build --no-build-id --env-isolation none \
#     --recipe recipe/recipe.yaml -m .ci_support/linux_64_python3.11.____cpython.yaml
#
# --env-isolation none forwards HOME + SCCACHE_DIR into the build; the default
# (strict) normalizes HOME and strips host env, so sccache would instead write to
# a throwaway build-local dir that is wiped after the build. --no-build-id keeps
# the build path stable so the cache actually hits on the next run.
set -euo pipefail

# One build script drives every output; dispatch on the package being built.
# rattler-build leaves PKG_NAME unset for the `staging:` output, so map an unset
# value to the staging name.
PKG_NAME="${PKG_NAME:-numba-cuda-mlir-staging}"

cd "${SRC_DIR}/src"

# Allow the caller to cap parallelism (e.g. PARALLEL=4 to avoid OOM on
# RAM-constrained runners).  Falls back to conda's CPU_COUNT, then nproc.
export PARALLEL="${PARALLEL:-${CPU_COUNT:-$(nproc)}}"

# During cross-compilation, $PREFIX is the HOST (aarch64) prefix whose Python
# cannot run on the build machine. The cross-python wrapper at $BUILD_PREFIX/bin/python
# runs natively but produces extension modules for the target platform.
if [ "${CONDA_BUILD_CROSS_COMPILATION:-0}" = "1" ]; then
    export PYTHON="${BUILD_PREFIX}/bin/python"
else
    export PYTHON="${PREFIX}/bin/python"
fi

export BUILD_ROOT="${SRC_DIR}/_llvm_build"
export LLVM_MODERN_INSTALL="${SRC_DIR}/llvm-modern-install"
export LLVM_MODERN_SRC="${SRC_DIR}/llvm-modern-src"

case "${PKG_NAME}" in
  numba-cuda-mlir-staging)
    echo "=============================================================="
    echo "Staging: Modern LLVM/MLIR + Python bindings (built once, cached)"
    echo "=============================================================="
    chmod +x ci/*.sh

    if [ "${CONDA_BUILD_CROSS_COMPILATION:-0}" = "1" ]; then
        # Cross-compilation requires a two-stage LLVM build because LLVM's cmake
        # needs llvm-tblgen and mlir-tblgen to RUN on the build machine during
        # compilation (they generate source code). With $CC pointing to the
        # aarch64 cross-compiler, cmake sets CMAKE_CROSSCOMPILING=TRUE and refuses
        # to build+run these tools itself -- they must be pre-built natively.
        #
        # We cannot delegate to ci/build-llvm-modern.sh here because it has no
        # cross-compilation support.
        #
        # Stage 1: build native (build-platform) tablegen tools.
        # Stage 2: cross-compile LLVM/MLIR + Python bindings for the host
        #          platform, pointing cmake at the Stage 1 native executables.

        NATIVE_BUILD="${BUILD_ROOT}-native"
        # BUILD_ROOT is created by Stage 2 after rm -rf; only pre-create NATIVE_BUILD
        # and LLVM_MODERN_INSTALL here.
        mkdir -p "${NATIVE_BUILD}" "${LLVM_MODERN_INSTALL}"

        command -v sccache &>/dev/null || { echo "ERROR: sccache not found"; exit 1; }

        # cmake flags identical between Stage 1 (native) and Stage 2 (cross).
        # Defined here so the subshell below can inherit the array.
        LLVM_CMAKE_COMMON=(
            -DLLVM_ENABLE_PROJECTS="mlir"
            -DLLVM_TARGETS_TO_BUILD="NVPTX"
            -DLLVM_BUILD_TOOLS=OFF
            -DLLVM_BUILD_EXAMPLES=OFF
            -DLLVM_INCLUDE_TESTS=OFF
            -DLLVM_INCLUDE_BENCHMARKS=OFF
            -DLLVM_INCLUDE_DOCS=OFF
        )

        echo ">>> Stage 1: building native llvm-tblgen / mlir-tblgen"
        # Run in a subshell so that unsetting cross-compilation vars is scoped to
        # Stage 1 only.  The gcc_linux-aarch64 package installs
        # 'aarch64-conda-linux-gnu-gcc' (not plain 'gcc'), so unsetting CC/CXX lets
        # cmake find the native /usr/bin/gcc from the system PATH.
        #
        # We also unset the conda path vars (LIBRARY_PATH, PKG_CONFIG_PATH, etc.)
        # that conda's host-env activation points at $PREFIX (the aarch64 prefix).
        # Without this, cmake's FindZstd/FindZlib would pick up the aarch64
        # libzstd.so / libz.so from $PREFIX/lib, and the native x86_64 linker
        # would fail with "file in wrong format".  We disable these optional
        # compression libs explicitly to be safe.
        (
            unset CC CXX AR LD NM RANLIB STRIP OBJCOPY
            unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
            unset LIBRARY_PATH LD_LIBRARY_PATH PKG_CONFIG_PATH
            unset CMAKE_PREFIX_PATH CMAKE_ARGS

            cmake -G Ninja \
                -S "${LLVM_MODERN_SRC}/llvm" \
                -B "${NATIVE_BUILD}" \
                -DCMAKE_BUILD_TYPE=Release \
                "${LLVM_CMAKE_COMMON[@]}" \
                -DMLIR_ENABLE_BINDINGS_PYTHON=OFF \
                -DLLVM_ENABLE_ZSTD=OFF \
                -DLLVM_ENABLE_ZLIB=OFF \
                -DCMAKE_C_COMPILER_LAUNCHER=sccache \
                -DCMAKE_CXX_COMPILER_LAUNCHER=sccache

            cmake --build "${NATIVE_BUILD}" -j "${PARALLEL}" \
                --target llvm-tblgen mlir-tblgen llvm-min-tblgen
        )

        echo ">>> Stage 2: cross-compiling LLVM/MLIR + Python bindings"
        # $CC/$CXX are still the aarch64 cross-compilers from the outer env.
        # CMAKE_FIND_ROOT_PATH=$PREFIX tells cmake where to look for host-platform
        # headers and libraries (Python, zlib, zstd, etc.) installed by conda.
        # FIND_ROOT_PATH_MODE_*=BOTH lets cmake also search the normal system
        # paths, which is required because conda's cross env doesn't use a sysroot.

        # When cross-compiling, LLVM's cmake creates a NATIVE sub-build (an
        # ExternalProject at ${BUILD_ROOT}/NATIVE/) to compile host-platform tools
        # such as llvm-min-tblgen and mlir-linalg-ods-yaml-gen.  That sub-cmake
        # invocation inherits $CC from the environment, so without an explicit
        # override it picks up the aarch64 cross-compiler and produces aarch64
        # binaries that can't run on the build machine.
        #
        # CROSS_TOOLCHAIN_FLAGS_NATIVE is LLVM's escape hatch: a semicolon-
        # separated cmake flag string that is appended to the NATIVE ExternalProject
        # cmake invocation.  Set it to the build-platform gcc so the NATIVE build
        # is truly native (x86_64).  We also disable zstd/zlib there to prevent
        # the native linker from picking up aarch64 .so files from $PREFIX/lib.
        # Remove any stale Stage 2 cmake configuration so the NATIVE
        # ExternalProject is reconfigured with the correct CROSS_TOOLCHAIN flags.
        # sccache preserves all object-file work so this is cheap.
        rm -rf "${BUILD_ROOT}"
        mkdir -p "${BUILD_ROOT}"

        NATIVE_CC="${BUILD_PREFIX}/bin/x86_64-conda-linux-gnu-gcc"
        NATIVE_CXX="${BUILD_PREFIX}/bin/x86_64-conda-linux-gnu-g++"
        if [ ! -f "${NATIVE_CC}" ]; then
            NATIVE_CC=/usr/bin/gcc
            NATIVE_CXX=/usr/bin/g++
        fi
        CROSS_NATIVE_FLAGS="\
-DCMAKE_C_COMPILER=${NATIVE_CC};\
-DCMAKE_CXX_COMPILER=${NATIVE_CXX};\
-DLLVM_ENABLE_ZSTD=OFF;\
-DLLVM_ENABLE_ZLIB=OFF;\
-DCMAKE_C_COMPILER_LAUNCHER=sccache;\
-DCMAKE_CXX_COMPILER_LAUNCHER=sccache"

        cmake -G Ninja \
            -S "${LLVM_MODERN_SRC}/llvm" \
            -B "${BUILD_ROOT}" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="${LLVM_MODERN_INSTALL}" \
            -DCMAKE_SYSTEM_NAME=Linux \
            -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
            -DCMAKE_FIND_ROOT_PATH="${PREFIX}" \
            -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
            -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
            -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
            "${LLVM_CMAKE_COMMON[@]}" \
            -DMLIR_ENABLE_BINDINGS_PYTHON=ON \
            -DCMAKE_CXX_FLAGS="-DMLIR_PYTHON_PACKAGE_PREFIX=numba_cuda_mlir._mlir." \
            -DMLIR_BINDINGS_PYTHON_INSTALL_PREFIX="python_packages/numba_cuda_mlir_mlir/numba_cuda_mlir/_mlir" \
            -DMLIR_BINDINGS_PYTHON_NB_DOMAIN=numba_cuda_mlir \
            -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON \
            -DPython3_EXECUTABLE="${PYTHON}" \
            -DLLVM_TABLEGEN="${NATIVE_BUILD}/bin/llvm-tblgen" \
            -DMLIR_TABLEGEN="${NATIVE_BUILD}/bin/mlir-tblgen" \
            "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=${CROSS_NATIVE_FLAGS}" \
            -DCMAKE_C_COMPILER_LAUNCHER=sccache \
            -DCMAKE_CXX_COMPILER_LAUNCHER=sccache

        cmake --build "${BUILD_ROOT}" -j "${PARALLEL}"
        cmake --install "${BUILD_ROOT}"

        echo "=== sccache stats ==="
        sccache --show-stats
    else
        # Native build: delegate to the upstream script unchanged. It sets its own
        # sccache launcher, guards on sccache presence, and handles the install.
        ci/build-llvm-modern.sh
    fi
    ;;

  numba-cuda-mlir)
    echo "=============================================================="
    echo "Package: numba_cuda_mlir wheel (reuses cached LLVM/MLIR)"
    echo "=============================================================="
    # rattler-build restored the staging work directory, so ${LLVM_MODERN_INSTALL}
    # already contains the compiled LLVM/MLIR install tree.

    # Cache the wheel's native (pybind11/nanobind) compile on local rebuilds.
    export CMAKE_C_COMPILER_LAUNCHER=sccache
    export CMAKE_CXX_COMPILER_LAUNCHER=sccache

    # CUDA headers come from the conda host env; FindCUDAToolkit.cmake honors
    # $CUDAToolkit_ROOT for cuda.h.
    export CUDAToolkit_ROOT="${PREFIX}"
    export DLPACK_PATH="${PREFIX}"
    export MLIR_DIR="${LLVM_MODERN_INSTALL}/lib/cmake/mlir"
    # LIBLLVM7 intentionally unset: we don't bundle libLLVM-7.so. The legacy LLVM 7
    # runtime is provided by the libllvm7.1 conda package (see symlink below).

    if [ "${CONDA_BUILD_CROSS_COMPILATION:-0}" = "1" ]; then
        # pip's 'Preparing metadata (pyproject.toml)' step spawns a subprocess
        # using sys.executable.  cross-python sets sys.executable = $PREFIX/bin/python
        # (the aarch64 Python) via the argv[0] trick so that distutils thinks it's
        # building for the host platform.  Exec'ing that aarch64 binary on the x86_64
        # build machine triggers binfmt_misc → QEMU → exit 255.
        #
        # Work-around: build the wheel in-process with setup.py bdist_wheel.
        # BuildExtWithCmake.run() calls cmake via self.spawn() (a subprocess of cmake,
        # NOT of sys.executable), so no binfmt issue.  Then install the pre-built
        # .whl file — wheel installation reads the metadata directly from the zip, no
        # build-backend subprocess required.

        # numba-cuda-mlir/cext/mlir-llvm70/include/llvm70/Dialect/ uses
        # mlir_tablegen() to generate LLVM70Ops header files at cmake build time.
        # The MLIR cmake install (MLIRTargets-release.cmake) exports mlir-tblgen as
        # an IMPORTED executable pointing to ${LLVM_MODERN_INSTALL}/bin/mlir-tblgen.
        # That binary is the aarch64 cross-compiled one — it can't run on x86_64.
        # Replace it with the native (x86_64) mlir-tblgen built in Stage 1 so
        # cmake can exec it during the numba-cuda-mlir build.
        NATIVE_BUILD="${BUILD_ROOT}-native"
        cp "${NATIVE_BUILD}/bin/mlir-tblgen" "${LLVM_MODERN_INSTALL}/bin/mlir-tblgen"

        "${PYTHON}" setup.py bdist_wheel
        "${PYTHON}" -m pip install dist/*.whl --no-deps -vv
    else
        "${PYTHON}" -m pip install . \
            --no-build-isolation \
            --no-deps \
            -vv
    fi

    # numba-cuda-mlir's runtime loader looks for a bundled
    # numba_cuda_mlir/lib/libLLVM-7.so. Point that at the conda libllvm7.1 library
    SP="$("${PYTHON}" -c "import sysconfig; print(sysconfig.get_paths()['platlib'])")"
    mkdir -p "${SP}/numba_cuda_mlir/lib"
    # $SP/numba_cuda_mlir/lib -> up 4 -> $PREFIX/lib
    ln -sf ../../../../libLLVM-7.1.so "${SP}/numba_cuda_mlir/lib/libLLVM-7.so"
    ;;

  *)
    echo "Unknown PKG_NAME: ${PKG_NAME}" >&2
    exit 1
    ;;
esac
