#!/bin/bash
set -e

# Usage:
#   images/create-images.sh <CHIP> <OUT_DIR>
#
# Example:
#   images/create-images.sh rk3588 OUT/rockchip/ARM-SBC-EDGE-3588

CHIP="$1"
OUT_DIR="$2"

# this file lives in images/
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="$BASE_DIR/images"

. "$BASE_DIR/common/log.sh"

check_dialog() { command -v dialog >/dev/null 2>&1; }

if [ -z "$CHIP" ] || [ -z "$OUT_DIR" ]; then
  error "Usage: $0 <CHIP> <OUT_DIR>"
fi

info "Create-images: CHIP=$CHIP OUT_DIR=$OUT_DIR"

# ---------------------------------------------------------------------------
# detect platform
# ---------------------------------------------------------------------------
if [[ "$CHIP" == rk* ]]; then
  PLATFORM="rockchip"
elif [[ "$CHIP" == sun* || "$CHIP" == a* ]]; then
  PLATFORM="sunxi"
else
  PLATFORM="unknown"
fi
info "Detected platform: $PLATFORM"

# ---------------------------------------------------------------------------
# check artifacts
# ---------------------------------------------------------------------------
missing=()

# rootfs
ROOTFS_DIR="$OUT_DIR/rootfs"
[ -d "$ROOTFS_DIR" ] || missing+=("rootfs directory ($ROOTFS_DIR)")

# kernel
if [ -f "$OUT_DIR/Image" ] || [ -f "$OUT_DIR/vmlinuz" ] || [ -f "$OUT_DIR/kernel.img" ]; then
  :
else
  missing+=("kernel image (Image / vmlinuz / kernel.img) in $OUT_DIR")
fi

# DTB
if ls "$OUT_DIR"/*.dtb >/dev/null 2>&1 || [ -d "$OUT_DIR/dtb" ]; then
  :
else
  missing+=("DTB file(s) in $OUT_DIR")
fi

# U-Boot
have_uboot=0
if [ "$PLATFORM" = "rockchip" ]; then
  for f in "$OUT_DIR"/u-boot*.bin "$OUT_DIR"/idbloader.img "$OUT_DIR"/u-boot.itb "$OUT_DIR"/trust.img; do
    [ -f "$f" ] && have_uboot=1 && break
  done
else
  for f in "$OUT_DIR"/u-boot-sunxi-with-spl.bin "$OUT_DIR"/u-boot.bin; do
    [ -f "$f" ] && have_uboot=1 && break
  done
fi
[ "$have_uboot" -eq 1 ] || missing+=("U-Boot binary for $PLATFORM in $OUT_DIR")

# ---------------------------------------------------------------------------
# warn if missing
# ---------------------------------------------------------------------------
if [ "${#missing[@]}" -ne 0 ]; then
  warn "Some required artifacts are missing:"
  for m in "${missing[@]}"; do
    warn "  - $m"
  done

  if check_dialog; then
    dialog --yesno "Some build artifacts are missing.\n\n$(printf '%s\n' "${missing[@]}")\n\nContinue anyway?" 15 70
    ans=$?
    clear
    if [ "$ans" -ne 0 ]; then
      info "Aborting image creation."
      exit 1
    fi
  else
    read -rp "Continue anyway? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborting image creation."; exit 1; }
  fi
else
  info "All expected artifacts were found."
fi

# ---------------------------------------------------------------------------
# ask what to create
# ---------------------------------------------------------------------------
if check_dialog; then
  exec 3>&1
  choice=$(dialog --menu "Create SD/eMMC images" 12 70 6 \
    sd   "Create SD card image" \
    emmc "Create eMMC image" \
    both "Create both SD + eMMC" \
    skip "Skip" \
    3>&1 1>&2 2>&3)
  clear
else
  echo "What image do you want to create?"
  select c in sd emmc both skip; do choice="$c"; break; done
fi

# ---------------------------------------------------------------------------
# dispatch to maker scripts in images/
# ---------------------------------------------------------------------------
case "$PLATFORM" in
  rockchip)
    case "$choice" in
      sd)
        if [ -x "$IMAGES_DIR/make-sdcard.sh" ]; then
          "$IMAGES_DIR/make-sdcard.sh" "$OUT_DIR" "$CHIP"
        else
          warn "images/make-sdcard.sh not found"
        fi
        ;;
      emmc)
        if [ -x "$IMAGES_DIR/make-eMMC.sh" ]; then
          "$IMAGES_DIR/make-eMMC.sh" "$OUT_DIR" "$CHIP"
        else
          warn "images/make-eMMC.sh not found"
        fi
        ;;
      both)
        [ -x "$IMAGES_DIR/make-sdcard.sh" ] && "$IMAGES_DIR/make-sdcard.sh" "$OUT_DIR" "$CHIP" || warn "images/make-sdcard.sh missing"
        [ -x "$IMAGES_DIR/make-eMMC.sh" ] && "$IMAGES_DIR/make-eMMC.sh" "$OUT_DIR" "$CHIP" || warn "images/make-eMMC.sh missing"
        ;;
      *)
        info "Skipping image creation."
        ;;
    esac
    ;;
  sunxi)
    case "$choice" in
      sd)
        if [ -x "$IMAGES_DIR/make-sdcard.sh" ]; then
          "$IMAGES_DIR/make-sdcard.sh" "$OUT_DIR"
        else
          warn "images/make-sdcard.sh not found"
        fi
        ;;
      emmc)
        if [ -x "$IMAGES_DIR/make-emmc-sunxi.sh" ]; then
          "$IMAGES_DIR/make-emmc-sunxi.sh" "$OUT_DIR"
        else
          warn "images/make-emmc-sunxi.sh not found"
        fi
        ;;
      both)
        [ -x "$IMAGES_DIR/make-sdcard.sh" ] && "$IMAGES_DIR/make-sdcard.sh" "$OUT_DIR" || warn "images/make-sdcard.sh missing"
        [ -x "$IMAGES_DIR/make-emmc-sunxi.sh" ] && "$IMAGES_DIR/make-emmc-sunxi.sh" "$OUT_DIR" || warn "images/make-emmc-sunxi.sh missing"
        ;;
      *)
        info "Skipping image creation."
        ;;
    esac
    ;;
  *)
    error "Unknown platform ($PLATFORM) — cannot create images."
    ;;
esac

success "Image creation step finished."

