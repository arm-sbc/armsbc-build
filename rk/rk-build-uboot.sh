#!/bin/bash
set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$BASE_DIR/common/log.sh"

script_start
SCRIPT_NAME="$(basename "$0")"

: "${BOARD:?BOARD not set}"
: "${CHIP:?CHIP not set}"
: "${ARCH:?ARCH not set}"
: "${OUTPUT_DIR:?OUTPUT_DIR not set}"
: "${UBOOT_DEFCONFIG:?UBOOT_DEFCONFIG not set}"

UBOOT_DIR="$BASE_DIR/u-boot"
PATCH_DIR="$BASE_DIR/patches/rockchip/uboot"

section_start "Prepare U-Boot tree"

if [ ! -d "$UBOOT_DIR/.git" ]; then
  error "u-boot directory is missing or not a git repo. Run prepare_sources.sh first."
fi

# if you want always-clean U-Boot on every board build:
if [ "${UBOOT_FORCE_CLEAN:-1}" -eq 1 ]; then
  info "Resetting u-boot tree to clean HEAD"
  (cd "$UBOOT_DIR" && git reset --hard HEAD && git clean -fdx)
fi

section_end "Prepare U-Boot tree"

section_start "Apply U-Boot patches"

BOARD_PATCH="$PATCH_DIR/${BOARD}-uboot.patch"
if [ -f "$BOARD_PATCH" ]; then
  info "Applying board-specific U-Boot patch: $(basename "$BOARD_PATCH")"
  (
    cd "$UBOOT_DIR"
    patch -Np1 -i "$BOARD_PATCH" && success "Board patch applied"
  ) || warn "Board patch $(basename "$BOARD_PATCH") failed or already applied"
else
  info "No board-specific U-Boot patch for $BOARD"
fi

# optional generic patches
for p in "$PATCH_DIR/${CHIP}-uboot.patch" \
         "$PATCH_DIR/ARM-SBC-MULTI-356x-uboot.patch" \
         "$PATCH_DIR/ARM-SBC-MULTI-3588-uboot.patch"
do
  [ -f "$p" ] || continue
  info "Applying common/generic U-Boot patch: $(basename "$p")"
  (
    cd "$UBOOT_DIR"
    patch -Np1 -i "$p" && success "Common patch applied: $(basename "$p")"
  ) || warn "Common patch $(basename "$p") failed or already applied"
done

section_end "Apply U-Boot patches"

section_start "Build U-Boot"

cd "$UBOOT_DIR"

make distclean >/dev/null 2>&1 || true

# TPL and BL31
case "$CHIP" in
  rk3566|rk3568|rk3576|rk3588)
    TPL_DIR="$BASE_DIR/rkbin/bin/rk35"
    ROCKCHIP_TPL="$(ls "$TPL_DIR"/${CHIP}_ddr_*MHz_v*.bin 2>/dev/null | sort | tail -n1)"
    [ -n "$ROCKCHIP_TPL" ] && export ROCKCHIP_TPL && info "Using ROCKCHIP_TPL: $ROCKCHIP_TPL"
    ;;
esac

if [ "$ARCH" = "arm64" ]; then
  case "$CHIP" in
    rk3588) BL31_CAND=("$BASE_DIR"/rkbin/bin/rk35/rk3588_bl31_v*.elf) ;;
    rk3576) BL31_CAND=("$BASE_DIR"/rkbin/bin/rk35/rk3576_bl31_v*.elf) ;;
    rk3568|rk3566) BL31_CAND=("$BASE_DIR"/rkbin/bin/rk35/rk3568_bl31_v*.elf) ;;
  esac
  BL31="$(printf '%s\n' "${BL31_CAND[@]}" 2>/dev/null | sort -V | tail -n1)"
  [ -z "$BL31" ] && error "BL31 not found in rkbin for $CHIP"
  export BL31
  info "Using BL31: $BL31"
fi

info "Configuring U-Boot: $UBOOT_DEFCONFIG"
make CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}" "$UBOOT_DEFCONFIG"

DEVICE_TREE_NAME=$(grep -oP 'CONFIG_DEFAULT_DEVICE_TREE="\K[^"]+' .config || true)
[ -z "$DEVICE_TREE_NAME" ] && error "CONFIG_DEFAULT_DEVICE_TREE not found in U-Boot .config"

info "Building U-Boot for $BOARD ($CHIP)"
make -j"$(nproc)" \
  CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}" \
  DEVICE_TREE="$DEVICE_TREE_NAME" \
  BL31="$BL31" \
  ${ROCKCHIP_TPL:+ROCKCHIP_TPL="$ROCKCHIP_TPL"}

mkdir -p "$OUTPUT_DIR"
cp idbloader.img "$OUTPUT_DIR"/ || error "idbloader.img missing"
cp u-boot.itb "$OUTPUT_DIR"/ || error "u-boot.itb missing"
cp u-boot-rockchip.bin "$OUTPUT_DIR"/ 2>/dev/null || true

section_end "Build U-Boot"

script_end
success "U-Boot build for $BOARD completed → $OUTPUT_DIR"

