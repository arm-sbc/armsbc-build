#!/bin/bash
set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BASE_DIR/common/log.sh"

get_latest_stable_kernel() {
  curl -s https://www.kernel.org/ \
    | grep -oP 'linux-\K[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.xz)' \
    | grep -v rc \
    | head -n1
}

script_start

MODE="--all"

# Prefer env exported by arm_build.sh; allow CLI args to override.
CHIP_FAMILY="${CHIP_FAMILY:-}"
BOARD="${BOARD:-}"
ARCH="${ARCH:-}"
CHIP="${CHIP:-}"

# parse args (optional overrides)
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

# Hard require these (arm_build.sh should export them)
[ -z "$CHIP_FAMILY" ] && error "CHIP_FAMILY not set (arm_build.sh must export it or pass --family)"
[ -z "$BOARD" ]       && error "BOARD not set (arm_build.sh must export it or pass --board)"

# Optional but strongly recommended for sunxi TF-A logic
# (rockchip path doesn't need ARCH/CHIP here)
if [ "$CHIP_FAMILY" = "sunxi" ]; then
  [ -z "$ARCH" ] && warn "ARCH not set for sunxi; TF-A decision may be wrong"
  [ -z "$CHIP" ] && warn "CHIP not set for sunxi; TF-A decision may be wrong"
fi

# make sure OUT exists
OUTPUT_DIR="$BASE_DIR/OUT/${CHIP_FAMILY}/${BOARD}"
mkdir -p "$OUTPUT_DIR"
export OUTPUT_DIR
info "Using output dir: $OUTPUT_DIR"

install_deps() {
  section_start "Install dependencies"

  # Detect host OS
  if [ ! -f /etc/os-release ]; then
    error "Cannot detect host OS: /etc/os-release not found"
    section_end "Install dependencies"
    return 1
  fi

  . /etc/os-release
  HOST_OS="${ID:-unknown}"
  HOST_VERSION_ID="${VERSION_ID:-unknown}"
  HOST_PRETTY_NAME="${PRETTY_NAME:-Unknown OS}"

  info "Detected host OS: ${HOST_PRETTY_NAME}"

  # Base packages (common for all supported Ubuntu versions)
  REQUIRED_PACKAGES=(
    git wget curl bc build-essential
    device-tree-compiler
    debootstrap xz-utils
    swig bison flex
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
    libssl-dev libncurses-dev
    python3 python3-pip python3-pyelftools
    genext2fs uuid-dev
    picocom
    libgnutls28-dev
    qemu-user
    binfmt-support
  )

  # Helper: check if package exists in repo
  package_available() {
    apt-cache show "$1" >/dev/null 2>&1
  }

  # Select correct QEMU support package
  QEMU_SUPPORT_PKG=""

  if [ "$HOST_OS" = "ubuntu" ]; then
    case "$HOST_VERSION_ID" in
      24.04)
        info "Using Ubuntu 24.04 dependency logic"

        if package_available qemu-user-static; then
          QEMU_SUPPORT_PKG="qemu-user-static"
        elif package_available qemu-user-binfmt; then
          warn "qemu-user-static not available, falling back to qemu-user-binfmt"
          QEMU_SUPPORT_PKG="qemu-user-binfmt"
        else
          error "No suitable QEMU support package found (expected qemu-user-static or qemu-user-binfmt)"
          section_end "Install dependencies"
          return 1
        fi
        ;;
      26.04)
        info "Using Ubuntu 26.04 dependency logic"

        if package_available qemu-user-binfmt; then
          QEMU_SUPPORT_PKG="qemu-user-binfmt"
        elif package_available qemu-user-static; then
          warn "Using legacy qemu-user-static on Ubuntu 26"
          QEMU_SUPPORT_PKG="qemu-user-static"
        else
          error "No suitable QEMU support package found (expected qemu-user-binfmt or qemu-user-static)"
          section_end "Install dependencies"
          return 1
        fi
        ;;
      *)
        error "Unsupported Ubuntu version: ${HOST_VERSION_ID} (supported: 24.04, 26.04)"
        section_end "Install dependencies"
        return 1
        ;;
    esac
  else
    error "Unsupported host OS: ${HOST_PRETTY_NAME} (only Ubuntu 24/26 supported)"
    section_end "Install dependencies"
    return 1
  fi

  REQUIRED_PACKAGES+=("$QEMU_SUPPORT_PKG")

  # Check missing packages
  MISSING_PACKAGES=()
  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_PACKAGES+=("$pkg")
  done

  if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    info "Installing missing packages: ${MISSING_PACKAGES[*]}"

    sudo apt-get update -y >/dev/null || {
      error "Failed to update package lists"
      section_end "Install dependencies"
      return 1
    }

    sudo apt-get install -y "${MISSING_PACKAGES[@]}" >/dev/null || {
      error "Failed to install required dependencies"
      section_end "Install dependencies"
      return 1
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

download_uboot_stack() {
  section_start "Download / refresh U-Boot stack"

  local UBOOT_DIR="$BASE_DIR/u-boot"

  if [ ! -d "$UBOOT_DIR/.git" ]; then
    info "u-boot not present → cloning fresh"
    git clone https://github.com/u-boot/u-boot.git "$UBOOT_DIR"
  else
    info "u-boot exists → resetting to origin/master"
    (
      cd "$UBOOT_DIR"
      git fetch --all --prune >/dev/null 2>&1 || true
      git reset --hard origin/master
      git clean -fdx
    )
  fi

  # Rockchip extra deps
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

  # Sunxi arm64 needs TF-A BL31 in our build flow (A523/A527/T527 etc.)
  if [ "$CHIP_FAMILY" = "sunxi" ] && [ "${ARCH:-}" = "arm64" ]; then
    if [ ! -d "$BASE_DIR/trusted-firmware-a/.git" ]; then
      info "sunxi arm64 → cloning trusted-firmware-a"
      rm -rf "$BASE_DIR/trusted-firmware-a" 2>/dev/null || true
      git clone https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git "$BASE_DIR/trusted-firmware-a"
    else
      info "trusted-firmware-a already exists, skipping"
    fi
  fi

  section_end "Download / refresh U-Boot stack"
}

download_kernel() {
  section_start "Download kernel"

  if [ -n "${KERNEL_VERSION:-}" ]; then
    info "Using kernel version from environment: $KERNEL_VERSION"
  else
    info "KERNEL_VERSION not set → fetching latest stable from kernel.org..."
    KERNEL_VERSION=$(get_latest_stable_kernel)
    [ -z "$KERNEL_VERSION" ] && error "Failed to detect latest stable kernel from kernel.org"
    info "Latest stable kernel detected: $KERNEL_VERSION"
  fi

  echo "$KERNEL_VERSION" > "$OUTPUT_DIR/kernel.version"

  local TAR="linux-${KERNEL_VERSION}.tar.xz"
  local MAJ=${KERNEL_VERSION%%.*}
  local URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJ}.x/${TAR}"
  local KDIR="$BASE_DIR/linux-${KERNEL_VERSION}"

  if [ ! -f "$BASE_DIR/$TAR" ]; then
    info "Downloading kernel tarball: $TAR"
    wget -q "$URL" -O "$BASE_DIR/$TAR"
  else
    info "Kernel tarball already exists: $TAR"
  fi

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

