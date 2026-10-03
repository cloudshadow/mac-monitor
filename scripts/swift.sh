#!/bin/bash
set -euo pipefail
# Some CLT installations contain libc++ only inside the SDK while clang searches
# the toolchain directory. Select the existing SDK headers without changing Xcode.
sdk_path=$(xcrun --show-sdk-path)
clang_path=$(xcrun --find clang++)
toolchain_header_dir="$(dirname "$clang_path")/../include/c++/v1"
# Tests use Swift Testing; CLT does not need an XCTest installation.
if [ "${1:-}" = test ]; then set -- "$@" --disable-xctest; fi
case "${1:-}" in
  build|test)
    if [ ! -f "$toolchain_header_dir/memory" ] && [ -f "$sdk_path/usr/include/c++/v1/memory" ]; then
      exec swift "$@" -Xcxx -isystem -Xcxx "$sdk_path/usr/include/c++/v1"
    fi
    ;;
esac
exec swift "$@"
