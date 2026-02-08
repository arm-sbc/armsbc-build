#!/bin/bash
set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BASE_DIR/common/log.sh"

get_latest_stable_kernel() {
  # pulls the latest *stable* (not -rc) from kernel.org
  local latest
  latest=$(
    curl -s https://www.kernel.org/ \
    | grep -oP 'linux-\K[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.xz)' \
    | grep -v rc \
    | head -n1
  )
  echo "$latest"
}

script_start

MODE="--all"
CHIP_FAMILY=""
BOARD=""

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --all|--uboot|--kernel|--rootfs)
      MODE="$1"
      ;;
    --family)
      shift; CHIP_FAMILY="$1"
      ;;
    --board)
      shift; BOARD="$1"
      ;;
    *)
      warn "Unknown argument: $1"
      ;;
  esac
  shift
done

[ -z "$CHIP_FAMILY" ] && CHIP_FAMILY="rockchip"
[ -z "$BOARD" ] && BOARD="generic"

# make sure OUT exists (not armsbc-build/)
OUTPUT_DIR="$BASE_DIR/OUT/${CHIP_FAMILY}/${BOARD}"
mkdir -p "$OUTPUT_DIR"
export OUTPUT_DIR
info "Using output dir: $OUTPUT_DIR"

install_deps() {
  section_start "Install dependencies"

  REQUIRED_PACKAGES=(
    git wget curl bc build-essential
    device-tree-compiler
    qemu-user qemu-user-static binfmt-support
    debootstrap xz-utils
    swig bison flex
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
    libssl-dev libncurses-dev
    python3 python3-pip python3-pyelftools
    genext2fs uuid-dev
    picocom
    libgnutls28-dev
  )

  MISSING_PACKAGES=()

  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      MISSING_PACKAGES+=("$pkg")
    fi
  done

  if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    info "Installing missing packages: ${MISSING_PACKAGES[*]}"
    sudo apt-get update -y >/dev/null
    sudo apt-get install -y "${MISSING_PACKAGES[@]}" >/dev/null || {
      error "Failed to install required dependencies"
      exit 1
    }
    success "All required system packages installed"
  else
    info "All required system dependencies already installed"
  fi

  section_end "Install dependencies"
}
clean_for_all() {
  section_start "Clean board output"
  rm -rf "$OUTPUT_DIR"/*
  section_end "Clean board output"
}

clean_old_sources() {
  local target_dir="$1"
  local what="$2"  # "U-Boot" / "Kernel" / etc.

  if [ -d "$target_dir" ]; then
    warn "$what source already exists: $target_dir"

    if [ "${BUILD_FORCE:-0}" -eq 1 ]; then
      info "BUILD_FORCE=1 → removing without prompt..."
      rm -rf "$target_dir"
    else
      read -rp "Remove and re-download $what sources? [y/N]: " ans
      if [[ "$ans" =~ ^[Yy]$ ]]; then
        info "Removing $target_dir ..."
        rm -rf "$target_dir"
      else
        info "Keeping existing $what source tree."
      fi
    fi
  fi
}

download_uboot_stack() {
  section_start "Download / refresh U-Boot stack"

  local UBOOT_DIR="$BASE_DIR/u-boot"

  if [ ! -d "$UBOOT_DIR/.git" ]; then
    info "u-boot not present → cloning fresh"
    git clone https://github.com/u-boot/u-boot.git "$UBOOT_DIR"
  else
    # repo exists → reset to clean tree so patches apply
    if [ "${BUILD_FORCE:-0}" -eq 1 ]; then
      info "BUILD_FORCE=1 → hard reset u-boot"
      (
        cd "$UBOOT_DIR"
        git fetch --all --prune
        git reset --hard origin/master
        git clean -fdx
      )
    else
      info "u-boot exists → resetting to origin/master"
      (
        cd "$UBOOT_DIR"
        git fetch --all --prune >/dev/null 2>&1 || true
        git reset --hard origin/master
        git clean -fdx
      )
    fi
  fi

  if [ "$CHIP_FAMILY" = "rockchip" ]; then
    if [ ! -d "$BASE_DIR/rkbin" ]; then
      git clone https://github.com/rockchip-linux/rkbin.git "$BASE_DIR/rkbin"
    else
      info "rkbin already exists, skipping"
    fi
    if [ ! -d "$BASE_DIR/trusted-firmware-a" ]; then
      git clone https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git "$BASE_DIR/trusted-firmware-a"
    else
      info "trusted-firmware-a already exists, skipping"
    fi
  fi

  section_end "Download / refresh U-Boot stack"
}

download_kernel() {
  section_start "Download kernel"

  # 1) decide which version to use
  if [ -n "$KERNEL_VERSION" ]; then
    info "Using kernel version from environment: $KERNEL_VERSION"
  else
    info "KERNEL_VERSION not set → fetching latest stable from kernel.org..."
    KERNEL_VERSION=$(get_latest_stable_kernel)
    [ -z "$KERNEL_VERSION" ] && error "Failed to detect latest stable kernel from kernel.org"
    info "Latest stable kernel detected: $KERNEL_VERSION"
  fi

  # write it so rk-build-kernel.sh can read
  echo "$KERNEL_VERSION" > "$OUTPUT_DIR/kernel.version"

  local TAR="linux-${KERNEL_VERSION}.tar.xz"
  local MAJ=${KERNEL_VERSION%%.*}
  local URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJ}.x/${TAR}"
  local KDIR="$BASE_DIR/linux-${KERNEL_VERSION}"

  # download tarball
  if [ ! -f "$BASE_DIR/$TAR" ]; then
    info "Downloading kernel tarball: $TAR"
    wget -q "$URL" -O "$BASE_DIR/$TAR"
  else
    info "Kernel tarball already exists: $TAR"
  fi

  # IMPORTANT: kernel is not a git repo → always extract fresh
  if [ -d "$KDIR" ]; then
    warn "Kernel source folder already exists: $KDIR → removing for a clean tree"
    rm -rf "$KDIR"
  fi

  info "Extracting $TAR → $BASE_DIR"
  tar -xf "$BASE_DIR/$TAR" -C "$BASE_DIR"

  section_end "Download kernel"
}

# ---- main logic ----
install_deps

case "$MODE" in
  --all)
    clean_for_all
    download_uboot_stack
    download_kernel
    ;;
  --uboot)
    download_uboot_stack
    ;;
  --kernel)
    download_kernel
    ;;
  --rootfs)
    section_start "Rootfs prep"
    info "Rootfs-only: nothing to download here"
    section_end "Rootfs prep"
    ;;
  *)
    error "Unknown mode: $MODE"
    ;;
esac

script_end
success "prepare_sources.sh completed (mode=$MODE, family=$CHIP_FAMILY, board=$BOARD)"

