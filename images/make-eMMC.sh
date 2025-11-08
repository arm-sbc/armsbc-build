#!/bin/bash
set -e

# usage:
#   images/make-eMMC.sh <OUT_DIR> [CHIP]
# example:
#   images/make-eMMC.sh OUT/rockchip/ARM-SBC-EDGE-3588 rk3588

OUT_DIR="$1"
PASSED_CHIP="$2"

SCRIPT_NAME=$(basename "$0")
: "${LOG_FILE:=build.log}"
touch "$LOG_FILE"

log() {
  local LEVEL="$1"; shift
  local MSG="$*"
  local TS="[$(date +'%Y-%m-%d %H:%M:%S')]"
  local COLOR="\033[0m"
  case "$LEVEL" in
    INFO) COLOR="\033[1;34m" ;;
    WARN) COLOR="\033[1;33m" ;;
    ERROR) COLOR="\033[1;31m" ;;
    SUCCESS) COLOR="\033[1;92m" ;;
  esac
  if [ -t 1 ]; then
    echo -e "${COLOR}[$LEVEL] $MSG\033[0m" | tee -a "$LOG_FILE"
  else
    echo "[$LEVEL] $MSG" >> "$LOG_FILE"
  fi
  echo "${TS}[$LEVEL][$SCRIPT_NAME] $MSG" >> "$LOG_FILE"
}
info()    { log INFO "$@"; }
warn()    { log WARN "$@"; }
error()   { log ERROR "$@"; exit 1; }
success() { log SUCCESS "$@"; }

if [ -z "$OUT_DIR" ]; then
  error "Usage: $0 <OUT_DIR> [CHIP] (e.g. OUT/rockchip/ARM-SBC-EDGE-3588 rk3588)"
fi
if [ ! -d "$OUT_DIR" ]; then
  error "OUT_DIR does not exist: $OUT_DIR"
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
info "BASE_DIR=$BASE_DIR"
info "OUT_DIR=$OUT_DIR"

# ----------------------------------------------------------
# firmware helper
# ----------------------------------------------------------
install_armbian_firmware() {
  local target="$1"
  local cache_dir="$BASE_DIR/cache"
  local fw_dir="$cache_dir/armbian-firmware"

  mkdir -p "$cache_dir"

  if ! command -v git >/dev/null 2>&1; then
    info "git not installed → skipping Armbian firmware"
    return 0
  fi

  if [ ! -d "$fw_dir/.git" ]; then
    info "Fetching Armbian firmware into cache ..."
    rm -rf "$fw_dir"
    git clone --depth=1 https://github.com/armbian/firmware.git "$fw_dir" || {
      warn "Failed to clone Armbian firmware; skipping"
      return 0
    }
  else
    info "Updating cached Armbian firmware ..."
    (
      cd "$fw_dir" || exit 0
      remote_head=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
      remote_head=${remote_head:-main}
      git fetch --depth=1 origin "$remote_head" && git reset --hard "origin/$remote_head"
    ) || {
      warn "Firmware cache update failed – using existing cache"
    }
  fi

  info "Installing Armbian firmware into $target ..."
  sudo mkdir -p "$target/lib/firmware"
  sudo rsync -a --delete "$fw_dir/" "$target/lib/firmware/"
}

RK_TOOLS_DIR="$BASE_DIR/rk-tools"
RK_BIN_DIR="$BASE_DIR/rkbin"

[ -d "$RK_TOOLS_DIR" ] || error "rk-tools directory not found at $RK_TOOLS_DIR"
[ -d "$RK_BIN_DIR" ]    || error "rkbin directory not found at $RK_BIN_DIR"

BOARD="$(basename "$OUT_DIR")"
info "Detected BOARD=$BOARD"

# ----------------------------------------------------------
# load build.env if present
# ----------------------------------------------------------
if [ -f "$OUT_DIR/build.env" ]; then
  info "Loading $OUT_DIR/build.env"
  # shellcheck disable=SC1090
  . "$OUT_DIR/build.env"
fi

# ----------------------------------------------------------
# choose CHIP (prefer passed → build.env → dtb → default)
# ----------------------------------------------------------
DTB_PATH=""

if [ -n "${DEVICE_TREE:-}" ]; then
  dtb_name="${DEVICE_TREE%.dts}.dtb"
  if [ -f "$OUT_DIR/dtb/$dtb_name" ]; then
    DTB_PATH="$OUT_DIR/dtb/$dtb_name"
  elif [ -f "$OUT_DIR/$dtb_name" ]; then
    DTB_PATH="$OUT_DIR/$dtb_name"
  fi
fi

if [ -n "$PASSED_CHIP" ]; then
  CHIP="$PASSED_CHIP"
elif [ -n "${CHIP:-}" ]; then
  CHIP="$CHIP"
else
  if [ -z "$DTB_PATH" ]; then
    DTB_PATH=$(find "$OUT_DIR" -maxdepth 1 -name '*.dtb' | head -n1)
    [ -z "$DTB_PATH" ] && DTB_PATH=$(find "$OUT_DIR/dtb" -maxdepth 1 -name '*.dtb' 2>/dev/null | head -n1)
  fi
  if [ -n "$DTB_PATH" ]; then
    CHIP="$(basename "$DTB_PATH" | cut -d'-' -f1)"
  else
    CHIP="rk3588"
  fi
fi
info "Using CHIP=$CHIP"

if [ -z "$DTB_PATH" ]; then
  DTB_PATH=$(find "$OUT_DIR" -maxdepth 1 -name '*.dtb' | head -n1)
  [ -z "$DTB_PATH" ] && DTB_PATH=$(find "$OUT_DIR/dtb" -maxdepth 1 -name '*.dtb' 2>/dev/null | head -n1)
fi

# ----------------------------------------------------------
# tool and file paths
# ----------------------------------------------------------
AFPTOOL="$RK_TOOLS_DIR/afptool"
RKIMAGEMAKER="$RK_TOOLS_DIR/rkImageMaker"

PARAMETER_FILE="$RK_TOOLS_DIR/${CHIP}-parameter.txt"
PACKAGE_FILE="$RK_TOOLS_DIR/${CHIP}-package-file"

RKBOOT_INI="$RK_BIN_DIR/RKBOOT/${CHIP^^}MINIALL.ini"
BOOT_MERGER="$RK_BIN_DIR/tools/boot_merger"

[ -x "$AFPTOOL" ]        || error "afptool not found/executable: $AFPTOOL"
[ -x "$RKIMAGEMAKER" ]   || error "rkImageMaker not found/executable: $RKIMAGEMAKER"
[ -f "$PARAMETER_FILE" ] || error "parameter file not found: $PARAMETER_FILE"
[ -f "$PACKAGE_FILE" ]   || error "package file not found: $PACKAGE_FILE"
[ -f "$RKBOOT_INI" ]     || error "RKBOOT ini not found: $RKBOOT_INI"
[ -x "$BOOT_MERGER" ]    || error "boot_merger not found/executable: $BOOT_MERGER"

# ---------------------------------------------------------------------------
# ensure loader
# ---------------------------------------------------------------------------
LOADER_BIN="$OUT_DIR/${CHIP}_loader.bin"

if [ ! -f "$LOADER_BIN" ]; then
  info "Loader not found in OUT → generating from rkbin ..."
  (
    cd "$RK_BIN_DIR"
    "$BOOT_MERGER" "RKBOOT/${CHIP^^}MINIALL.ini"
  )
  GENERATED_LOADER=$(ls -1t "$RK_BIN_DIR"/*.bin "$RK_BIN_DIR"/bin/*.bin 2>/dev/null | head -n1)
  [ -f "$GENERATED_LOADER" ] || error "boot_merger ran but no loader was produced"

  LOADER_BASENAME="$(basename "$GENERATED_LOADER")"
  cp "$GENERATED_LOADER" "$OUT_DIR/$LOADER_BASENAME"
  cp "$GENERATED_LOADER" "$LOADER_BIN"

  info "Loader generated and copied as: $OUT_DIR/$LOADER_BASENAME"
else
  info "Using existing loader: $LOADER_BIN"
fi

# ---------------------------------------------------------------------------
# prepare boot/ in OUT_DIR
# ---------------------------------------------------------------------------
BOOT_DIR="$OUT_DIR/boot"
mkdir -p "$BOOT_DIR"

if [ -f "$OUT_DIR/Image" ]; then
  cp "$OUT_DIR/Image" "$BOOT_DIR/"
else
  warn "Kernel Image not found in $OUT_DIR"
fi

if [ -n "$DTB_PATH" ]; then
  cp "$DTB_PATH" "$BOOT_DIR/"
else
  warn "No DTB found to copy into boot/"
fi

# >>> NEW: copy config-* and System.map-* if present <<<
KVER=$(basename "$OUT_DIR"/config-* 2>/dev/null | cut -d'-' -f2-)
if [ -n "$KVER" ]; then
  [ -f "$OUT_DIR/config-$KVER" ]     && cp "$OUT_DIR/config-$KVER"     "$BOOT_DIR/config"
  [ -f "$OUT_DIR/System.map-$KVER" ] && cp "$OUT_DIR/System.map-$KVER" "$BOOT_DIR/System.map"
fi
# <<< end new >>>

EXTLINUX_DIR="$BOOT_DIR/extlinux"
mkdir -p "$EXTLINUX_DIR"

case "$CHIP" in
  rk3588|rk3568|rk3566|rk3399)
    CONSOLE="ttyS2"; BAUD="1500000" ;;
  *)
    CONSOLE="ttyS2"; BAUD="1500000" ;;
esac

cat > "$EXTLINUX_DIR/extlinux.conf" <<EOF
LABEL Linux
    KERNEL /Image
    FDT /$(basename "$DTB_PATH")
    APPEND console=$CONSOLE,$BAUD root=/dev/mmcblk0p4 rw rootwait
EOF

info "boot/ populated."

# ---------------------------------------------------------------------------
# create boot.img
# ---------------------------------------------------------------------------
BOOT_IMG="$OUT_DIR/boot_${CHIP}.img"
info "Creating boot image: $BOOT_IMG"

USED_KB=$(du -s --block-size=1024 "$BOOT_DIR" | cut -f1)
PADDING_KB=$(( USED_KB / 4 ))
TOTAL_KB=$(( USED_KB + PADDING_KB ))
MIN_KB=$(( 32 * 1024 ))
[ "$TOTAL_KB" -lt "$MIN_KB" ] && TOTAL_KB="$MIN_KB"

BLOCK_SIZE=4096
BLOCKS=$(( TOTAL_KB * 1024 / BLOCK_SIZE ))

genext2fs -b "$BLOCKS" -B "$BLOCK_SIZE" -d "$BOOT_DIR" -U "$BOOT_IMG"

# ---------------------------------------------------------------------------
# create rootfs.img
# ---------------------------------------------------------------------------
ROOTFS_SRC="$OUT_DIR/rootfs"
ROOTFS_IMG="$OUT_DIR/rootfs.img"
MNT_DIR="$OUT_DIR/.mnt_rootfs"

[ -d "$ROOTFS_SRC" ] || error "rootfs directory not found: $ROOTFS_SRC"

info "Creating 5GB ext4 rootfs.img from $ROOTFS_SRC ..."
dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count=0 seek=5120
mkfs.ext4 -F "$ROOTFS_IMG"

mkdir -p "$MNT_DIR"
sudo mount "$ROOTFS_IMG" "$MNT_DIR"
info "Copying rootfs into image ..."
sudo rsync -aAX --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*"} "$ROOTFS_SRC/" "$MNT_DIR/" 2> >(grep -v "Permission denied" >&2)

if [ -d "$OUT_DIR/lib/modules" ]; then
  sudo mkdir -p "$MNT_DIR/lib/modules"
  sudo cp -a "$OUT_DIR/lib/modules/"* "$MNT_DIR/lib/modules/"
fi

install_armbian_firmware "$MNT_DIR"

sync
sudo umount "$MNT_DIR"
rmdir "$MNT_DIR"

success "rootfs.img created at $ROOTFS_IMG"

# ---------------------------------------------------------------------------
# pack with afptool
# ---------------------------------------------------------------------------
RAW_IMG="$OUT_DIR/update-emmc.raw.img"
info "Copying parameter.txt into OUT_DIR ..."
cp "$PARAMETER_FILE" "$OUT_DIR/parameter.txt"

info "Packing raw image with afptool ..."
"$AFPTOOL" -pack "$OUT_DIR" "$RAW_IMG" "$PACKAGE_FILE"

# ---------------------------------------------------------------------------
# make final update img
# ---------------------------------------------------------------------------
TAG="RK$(hexdump -s 21 -n 4 -e '4 "%c"' "$LOADER_BIN" | rev)"
OUT_UPDATE_IMG="$OUT_DIR/update-emmc-${BOARD}.img"

info "Creating final update image with rkImageMaker ..."
"$RKIMAGEMAKER" -$TAG "$LOADER_BIN" "$RAW_IMG" "$OUT_UPDATE_IMG" -os_type:linux

[ -f "$OUT_UPDATE_IMG" ] && success "update-eMMC image created: $OUT_UPDATE_IMG" || error "Failed to create final eMMC image"

exit 0

