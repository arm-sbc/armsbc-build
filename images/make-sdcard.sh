#!/bin/bash
set -e

# usage:
#   images/make-sdcard.sh [OUT_DIR] [CHIP]
# if OUT_DIR is omitted, we scan OUT/rockchip/* and let user pick

SCRIPT_NAME="make-sdcard.sh"
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

# re-run with sudo if needed
if [ "$EUID" -ne 0 ]; then
  info "Re-running with sudo..."
  exec sudo "$0" "$@"
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# firmware helper (shared with eMMC)
# ---------------------------------------------------------------------------
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
      local remote_head
      remote_head=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
      remote_head=${remote_head:-main}
      git fetch --depth=1 origin "$remote_head" && \
      git reset --hard "origin/$remote_head"
    ) || {
      warn "Firmware cache update failed – using existing cache"
    }
  fi

  info "Installing Armbian firmware into $target ..."
  sudo mkdir -p "$target/lib/firmware"
  sudo rsync -a --delete "$fw_dir/" "$target/lib/firmware/"
}

OUT_DIR="$1"
PASSED_CHIP="$2"

# -----------------------------------------------------------------------------
# 1) If OUT_DIR not given, list boards from OUT/rockchip and let user pick
# -----------------------------------------------------------------------------
if [ -z "$OUT_DIR" ]; then
  CANDIDATES=()
  if [ -d "$BASE_DIR/OUT/rockchip" ]; then
    while IFS= read -r -d '' d; do
      CANDIDATES+=("$d")
    done < <(find "$BASE_DIR/OUT/rockchip" -maxdepth 1 -mindepth 1 -type d -print0)
  fi
  if [ -d "$BASE_DIR/OUT/sunxi" ]; then
    while IFS= read -r -d '' d; do
      CANDIDATES+=("$d")
    done < <(find "$BASE_DIR/OUT/sunxi" -maxdepth 1 -mindepth 1 -type d -print0)
  fi

  if [ ${#CANDIDATES[@]} -eq 0 ]; then
    error "No OUT/*/* board folders found. Build something first."
  fi

  info "Select an OUT directory to build SD image from:"
  PS3="Enter choice: "
  select d in "${CANDIDATES[@]}"; do
    if [ -n "$d" ]; then
      OUT_DIR="$d"
      break
    fi
  done
fi

[ -d "$OUT_DIR" ] || error "OUT_DIR does not exist: $OUT_DIR"
info "Using OUT_DIR=$OUT_DIR"

BOARD_NAME="$(basename "$OUT_DIR")"
info "Board folder: $BOARD_NAME"

# -----------------------------------------------------------------------------
# 2) Try to load exported info from earlier steps (if arm_build.sh saved it)
# -----------------------------------------------------------------------------
if [ -f "$OUT_DIR/build.env" ]; then
  info "Loading $OUT_DIR/build.env"
  # shellcheck disable=SC1090
  . "$OUT_DIR/build.env"
fi

# -----------------------------------------------------------------------------
# 3) Pick DTB, prefer what board exported
# -----------------------------------------------------------------------------
DTB_FILE=""

if [ -n "${DEVICE_TREE:-}" ]; then
  dtb_name="${DEVICE_TREE%.dts}.dtb"
  if [ -f "$OUT_DIR/dtb/$dtb_name" ]; then
    DTB_FILE="$OUT_DIR/dtb/$dtb_name"
  elif [ -f "$OUT_DIR/$dtb_name" ]; then
    DTB_FILE="$OUT_DIR/$dtb_name"
  fi
fi

if [ -z "$DTB_FILE" ]; then
  DTB_FILE=$(find "$OUT_DIR" -maxdepth 1 -name '*.dtb' | head -n1)
  [ -z "$DTB_FILE" ] && DTB_FILE=$(find "$OUT_DIR/dtb" -maxdepth 1 -name '*.dtb' 2>/dev/null | head -n1)
fi

# -----------------------------------------------------------------------------
# 3.5) NEW: resolve CHIP
# priority:
#   1) PASSED_CHIP
#   2) CHIP from build.env
#   3) derive from DTB_FILE
# -----------------------------------------------------------------------------
if [ -n "$PASSED_CHIP" ]; then
  CHIP="$PASSED_CHIP"
elif [ -n "${CHIP:-}" ]; then
  # already loaded from build.env
  :
elif [ -n "$DTB_FILE" ]; then
  CHIP=$(basename "$DTB_FILE" | cut -d'-' -f1)
else
  error "CHIP is not set and no DTB found to derive it → cannot continue"
fi
info "Using CHIP=$CHIP"

# -----------------------------------------------------------------------------
# 4) Detect platform + root dev
# -----------------------------------------------------------------------------
if [[ "$CHIP" == rk* ]]; then
  PLATFORM="rockchip"
  PARTITION_START=64M
  ROOT_DEV="/dev/mmcblk1p1"
elif [[ "$CHIP" == sun* || "$CHIP" == a* ]]; then
  PLATFORM="sunxi"
  PARTITION_START=2M
  ROOT_DEV="/dev/mmcblk0p1"
else
  error "Unknown platform for CHIP=$CHIP"
fi
info "Platform=$PLATFORM, root=$ROOT_DEV"

# -----------------------------------------------------------------------------
# 5) Detect kernel image
# -----------------------------------------------------------------------------
if [ -f "$OUT_DIR/Image" ]; then
  ARCH="arm64"
  KERNEL_SRC="$OUT_DIR/Image"
  KERNEL_FILE="Image"
elif [ -f "$OUT_DIR/zImage" ]; then
  ARCH="arm32"
  KERNEL_SRC="$OUT_DIR/zImage"
  KERNEL_FILE="zImage"
else
  error "No Image or zImage found in $OUT_DIR"
fi
info "ARCH=$ARCH"

# -----------------------------------------------------------------------------
# 6) Decide image name
# -----------------------------------------------------------------------------
if [ -n "$BOARD_NAME" ]; then
  IMAGE_BASENAME="$BOARD_NAME"
elif [ -n "$CHIP" ]; then
  IMAGE_BASENAME="$CHIP"
elif [ -n "$DTB_FILE" ]; then
  IMAGE_BASENAME="$(basename "$DTB_FILE" .dtb)"
else
  IMAGE_BASENAME="sdimage"
fi
IMAGE_NAME="$OUT_DIR/${IMAGE_BASENAME}-sd.img"
info "Output image: $IMAGE_NAME"

# -----------------------------------------------------------------------------
# 7) Create image file
# -----------------------------------------------------------------------------
dd if=/dev/zero of="$IMAGE_NAME" bs=1M count=6144
sync

# -----------------------------------------------------------------------------
# 8) Write bootloader
# -----------------------------------------------------------------------------
info "Writing bootloader..."
case "$PLATFORM" in
  rockchip)
    if [ -f "$OUT_DIR/idbloader.img" ] && [ -f "$OUT_DIR/u-boot.itb" ]; then
      dd if="$OUT_DIR/idbloader.img" of="$IMAGE_NAME" bs=512 seek=64 conv=notrunc
      dd if="$OUT_DIR/u-boot.itb"   of="$IMAGE_NAME" bs=512 seek=16384 conv=notrunc
    elif [ -f "$OUT_DIR/u-boot-rockchip.bin" ]; then
      dd if="$OUT_DIR/u-boot-rockchip.bin" of="$IMAGE_NAME" bs=512 seek=64 conv=notrunc
    else
      error "No Rockchip bootloader found in $OUT_DIR"
    fi
    ;;
  sunxi)
    if [ -f "$OUT_DIR/u-boot-sunxi-with-spl.bin" ]; then
      dd if="$OUT_DIR/u-boot-sunxi-with-spl.bin" of="$IMAGE_NAME" bs=1024 seek=8 conv=notrunc
    else
      error "No Allwinner bootloader found in $OUT_DIR"
    fi
    ;;
esac
sync

# -----------------------------------------------------------------------------
# 9) Partition
# -----------------------------------------------------------------------------
info "Partitioning image..."
echo "$PARTITION_START,,L" | sfdisk "$IMAGE_NAME"

LOOP_DEV=$(losetup -f --show "$IMAGE_NAME" --partscan)
info "Loop device: $LOOP_DEV"

PART_DEV=""
for i in {1..10}; do
  if [ -e "${LOOP_DEV}p1" ]; then PART_DEV="${LOOP_DEV}p1"; break; fi
  if [ -e "${LOOP_DEV}1" ];  then PART_DEV="${LOOP_DEV}1"; break; fi
  sleep 0.3
done
[ -n "$PART_DEV" ] || { losetup -d "$LOOP_DEV"; error "Partition node not found"; }

info "Formatting $PART_DEV ..."
mkfs.ext4 "$PART_DEV"

MOUNT_PT="/mnt/${BOARD_NAME:-$CHIP}_sd"
mkdir -p "$MOUNT_PT"
mount "$PART_DEV" "$MOUNT_PT"

# -----------------------------------------------------------------------------
# 10) copy rootfs
# -----------------------------------------------------------------------------
if [ -d "$OUT_DIR/rootfs" ]; then
  ROOTFS_DIR="$OUT_DIR/rootfs"
else
  ROOTFS_DIR=$(find "$OUT_DIR" -maxdepth 1 -type d -name 'fresh_*' | head -n1)
fi
[ -d "$ROOTFS_DIR" ] || { umount "$MOUNT_PT"; losetup -d "$LOOP_DEV"; error "No rootfs dir found in $OUT_DIR"; }

info "Copying rootfs from $ROOTFS_DIR ..."
cp -a "$ROOTFS_DIR/." "$MOUNT_PT/"

# -----------------------------------------------------------------------------
# 11) /boot and extlinux
# -----------------------------------------------------------------------------
BOOT_DIR="$MOUNT_PT/boot"
mkdir -p "$BOOT_DIR"
cp "$KERNEL_SRC" "$BOOT_DIR/"

if [ -n "$DTB_FILE" ]; then
  cp "$DTB_FILE" "$BOOT_DIR/"
fi

# copy kernel extras if present
KVER_FILE=$(ls "$OUT_DIR"/config-* 2>/dev/null | head -n1 || true)
if [ -n "$KVER_FILE" ]; then
  KVER=$(basename "$KVER_FILE" | cut -d'-' -f2-)
  [ -f "$OUT_DIR/config-$KVER" ]     && cp "$OUT_DIR/config-$KVER"     "$BOOT_DIR/config"
  [ -f "$OUT_DIR/System.map-$KVER" ] && cp "$OUT_DIR/System.map-$KVER" "$BOOT_DIR/System.map"
fi

EXTLINUX_DIR="$BOOT_DIR/extlinux"
mkdir -p "$EXTLINUX_DIR"

case "$CHIP" in
  rk3588|rk3568|rk3566|rk3399) CONSOLE="ttyS2"; BAUD="1500000" ;;
  *)                           CONSOLE="ttyS0"; BAUD="115200"  ;;
esac

DTB_BASENAME=$(basename "$DTB_FILE")
cat > "$EXTLINUX_DIR/extlinux.conf" <<EOF
LABEL Linux
    KERNEL /boot/$KERNEL_FILE
    FDT /boot/$DTB_BASENAME
    APPEND console=$CONSOLE,$BAUD root=$ROOT_DEV rw rootwait
EOF

# modules
if [ -d "$OUT_DIR/lib/modules" ]; then
  info "Copying kernel modules..."
  mkdir -p "$MOUNT_PT/lib/modules"
  cp -a "$OUT_DIR/lib/modules/"* "$MOUNT_PT/lib/modules/"
fi

# install firmware
install_armbian_firmware "$MOUNT_PT"

umount "$MOUNT_PT"
losetup -d "$LOOP_DEV"
success "SD image created: $IMAGE_NAME"
exit 0

