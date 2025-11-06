#!/bin/bash
set -e

OUT_DIR="$1"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$BASE_DIR/common/log.sh"

check_dialog() { command -v dialog >/dev/null 2>&1; }

section_start "Sunxi image creation"

if check_dialog; then
  exec 3>&1
  choice=$(dialog --menu "Create Sunxi images?" 12 60 6 \
    sd   "Create SD card image (make-sdcard.sh)" \
    emmc "Create eMMC image (make-emmc-sunxi.sh)" \
    both "Create both" \
    skip "Skip" \
    3>&1 1>&2 2>&3)
  clear
else
  echo "Create Sunxi images?"
  select c in sd emmc both skip; do choice="$c"; break; done
fi

case "$choice" in
  sd)
    if [ -x "$BASE_DIR/make-sdcard.sh" ]; then
      "$BASE_DIR/make-sdcard.sh"
    else
      warn "make-sdcard.sh not found"
    fi
    ;;
  emmc)
    if [ -x "$BASE_DIR/make-emmc-sunxi.sh" ]; then
      "$BASE_DIR/make-emmc-sunxi.sh"
    else
      warn "make-emmc-sunxi.sh not found"
    fi
    ;;
  both)
    [ -x "$BASE_DIR/make-sdcard.sh" ] && "$BASE_DIR/make-sdcard.sh" || warn "make-sdcard.sh not found"
    [ -x "$BASE_DIR/make-emmc-sunxi.sh" ] && "$BASE_DIR/make-emmc-sunxi.sh" || warn "make-emmc-sunxi.sh not found"
    ;;
  *)
    info "Skipping Sunxi image creation."
    ;;
esac

section_end "Sunxi image creation"

