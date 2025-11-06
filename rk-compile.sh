#!/bin/bash
set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BASE_DIR/common/log.sh"

script_start
SCRIPT_NAME="rk-compile.sh"

BUILD_OPTION="$1"
[ -z "$BUILD_OPTION" ] && error "No build option passed. Use: uboot | kernel | uboot+kernel | all"

info "rk-compile.sh entrypoint, build option: $BUILD_OPTION"
info "BOARD=$BOARD CHIP=$CHIP ARCH=$ARCH OUTPUT_DIR=$OUTPUT_DIR"

case "$BUILD_OPTION" in
  uboot)
    "$BASE_DIR/rk/rk-build-uboot.sh"
    ;;
  kernel)
    "$BASE_DIR/rk/rk-build-kernel.sh"
    ;;
  uboot+kernel)
    "$BASE_DIR/rk/rk-build-uboot.sh"
    "$BASE_DIR/rk/rk-build-kernel.sh"
    ;;
  all)
    "$BASE_DIR/rk/rk-build-uboot.sh"
    "$BASE_DIR/rk/rk-build-kernel.sh"
    # rootfs will be done by arm_build.sh separately
    ;;
  *)
    error "Invalid argument: $BUILD_OPTION"
    ;;
esac

script_end
success "rk-compile.sh completed (option=$BUILD_OPTION)"

