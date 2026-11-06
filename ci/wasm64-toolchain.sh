#!/bin/bash

# Build and package the trimmed toolchain that the wasm64 targets are compiled
# with: clang, lld and the LLVM binutils, without LLDB, clang-tools-extra or
# wasm-component-ld. Run by `.github/workflows/wasm64-toolchain.yml`.
#
#   ci/wasm64-toolchain.sh build <build-dir>
#       Configure and build the toolchain into <build-dir>/toolchain/install.
#       CI runs this inside the `ci/docker/Dockerfile` image, as the wasi-sdk
#       release builds do, so the binaries need only an old glibc.
#
#   ci/wasm64-toolchain.sh package <build-dir> <out-dir>
#       Pack <build-dir>/toolchain/install as
#       <out-dir>/wasm64-toolchain-<arch>-linux.tar.zst plus a `.sha256`
#       beside it. The tarball's root directory has the same name, and holds
#       `REVISION`, the commit of this repository it was built from.
#
# The tarball is a function of the installed files alone: entries are sorted,
# owned by 0:0 and dated at the commit's time, and zstd runs single-threaded.
# Two builds from the same commit in the same image give the same bytes, which
# is what the workflow checks before it publishes.

set -euo pipefail

usage() {
  echo "usage: $0 build <build-dir>" >&2
  echo "       $0 package <build-dir> <out-dir>" >&2
  exit 2
}

build() {
  local build_dir=$1
  cmake -G Ninja -B "$build_dir/toolchain" -S . \
    -DWASI_SDK_BUILD_TOOLCHAIN=ON \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DWASI_SDK_LLDB=OFF \
    -DWASI_SDK_CLANG_TOOLS_EXTRA=OFF \
    -DWASI_SDK_WASM_COMPONENT_LD=OFF \
    -DWASI_SDK_DISABLE_CCACHE=ON
  cmake --build "$build_dir/toolchain"
}

package() {
  local build_dir=$1 out_dir=$2
  local install=$build_dir/toolchain/install
  local name
  name=wasm64-toolchain-$(uname -m)-linux

  if [ ! -x "$install/bin/clang" ]; then
    echo "no toolchain at $install; run '$0 build $build_dir' first" >&2
    exit 1
  fi
  # REVISION has to name what was built. Dirty submodule contents are
  # expected (the build applies src/*.patch to llvm-project); a changed file
  # in this repository or a moved submodule is not.
  if ! git diff --quiet --ignore-submodules=dirty HEAD; then
    echo "the work tree differs from HEAD; REVISION would not describe this build:" >&2
    git status --short --ignore-submodules=dirty >&2
    exit 1
  fi

  local stage=$build_dir/package
  rm -rf "$stage"
  mkdir -p "$stage/$name" "$out_dir"
  cp -a "$install/." "$stage/$name/"
  git rev-parse HEAD > "$stage/$name/REVISION"

  local epoch
  epoch=$(git log -1 --format=%ct)
  tar --create --file=- --directory="$stage" \
      --sort=name --format=gnu \
      --owner=0 --group=0 --numeric-owner \
      --mtime="@$epoch" --mode='u+rw,go-w' \
      "$name" \
    | zstd -q -19 -T1 -c > "$out_dir/$name.tar.zst"
  (cd "$out_dir" && sha256sum "$name.tar.zst" > "$name.tar.zst.sha256")
  cat "$out_dir/$name.tar.zst.sha256"
}

case "${1:-}" in
  build)
    [ $# -eq 2 ] && [ -n "$2" ] || usage
    build "$2"
    ;;
  package)
    [ $# -eq 3 ] && [ -n "$2" ] && [ -n "$3" ] || usage
    package "$2" "$3"
    ;;
  *)
    usage
    ;;
esac
