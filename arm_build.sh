#!/bin/bash
set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BASE_DIR/common/log.sh"

script_start
SCRIPT_NAME=$(basename "$0")

# ----- terminal sizing -----
if SIZE=$(stty size 2>/dev/null); then
  read -r LINES COLUMNS <<< "$SIZE"
else
  LINES=25; COLUMNS=80
fi
if [ "$LINES" -gt 25 ]; then
  DIALOG_HEIGHT=20
else
  tmp=$((LINES - 5)); [ "$tmp" -lt 10 ] && tmp=10; DIALOG_HEIGHT=$tmp
fi
if [ "$COLUMNS" -gt 90 ]; then
  DIALOG_WIDTH=70
else
  tmp=$((COLUMNS - 10)); [ "$tmp" -lt 40 ] && tmp=40; DIALOG_WIDTH=$tmp
fi

# ----- helpers -----
check_dialog() {
  if ! command -v dialog >/dev/null 2>&1; then
    warn "dialog not installed, using CLI prompts"
    return 1
  fi
  return 0
}

get_latest_stable_from_kernel_org() {
  curl -s https://www.kernel.org/ \
    | grep -oP 'linux-\K[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.xz)' \
    | grep -v rc \
    | head -n1
}

# ----- selections -----
select_family() {
  section_start "Select SoC family"
  if check_dialog; then
    exec 3>&1
    CHIP_FAMILY=$(dialog --menu "Select SoC family:" $DIALOG_HEIGHT $DIALOG_WIDTH 5 \
      rockchip "Rockchip SoCs" \
      sunxi    "Allwinner / Sunxi SoCs" \
      3>&1 1>&2 2>&3)
    clear
  else
    echo "Select SoC family:"
    select f in rockchip sunxi; do CHIP_FAMILY="$f"; break; done
  fi
  info "Selected family: $CHIP_FAMILY"
  section_end "Select SoC family"
}

select_board() {
  section_start "Select board"
  local BOARD_DIR="$BASE_DIR/boards/$CHIP_FAMILY"
  [ -d "$BOARD_DIR" ] || error "Board directory not found: $BOARD_DIR"

  local boards=()
  local count=0
  for d in "$BOARD_DIR"/*; do
    [ -d "$d" ] || continue
    count=$((count + 1))
    boards+=("$(basename "$d")")
  done

  if check_dialog; then
    local menu_args=()
    local i=0
    for b in "${boards[@]}"; do
      i=$((i + 1))
      # numbered tags
      menu_args+=("$i" "$b")
    done

    exec 3>&1
    local choice
    choice=$(dialog --menu "Select $CHIP_FAMILY board:" $DIALOG_HEIGHT $DIALOG_WIDTH 15 \
      "${menu_args[@]}" 3>&1 1>&2 2>&3)
    clear

    BOARD="${boards[$((choice - 1))]}"
  else
    echo "Select board:"
    select b in "${boards[@]}"; do
      BOARD="$b"; break
    done
  fi

  info "Selected board: $BOARD"
  section_end "Select board"
}

load_board_config() {
  section_start "Load board config"
  local CFG="$BASE_DIR/boards/$CHIP_FAMILY/$BOARD/board_config.sh"
  [ -f "$CFG" ] || error "board_config.sh not found: $CFG"
  # shellcheck source=/dev/null
  . "$CFG"
  info "Loaded board config: CHIP=$CHIP ARCH=$ARCH"
  export BOARD CHIP ARCH CROSS_COMPILE UBOOT_DEFCONFIG KERNEL_DEFCONFIG DEVICE_TREE
  # NEW: if board_config.sh defined a desktop, pass it down to all children
  if [ -n "${DESKTOP_FLAVOR:-}" ]; then
    export DESKTOP_FLAVOR
    info "Board desktop flavor: $DESKTOP_FLAVOR"
  fi
  section_end "Load board config"
}


select_build_option() {
  section_start "Select build option"
  if check_dialog; then
    exec 3>&1
    BUILD_OPTION=$(dialog --menu "Select build option:" $DIALOG_HEIGHT $DIALOG_WIDTH 12 \
      uboot        "Build only U-Boot" \
      kernel       "Build only kernel" \
      rootfs       "Build only rootfs" \
      uboot+kernel "Build U-Boot + kernel" \
      all          "Full build (U-Boot + kernel + rootfs)" \
      image        "Create SD/eMMC images (requires built artifacts)" \
      3>&1 1>&2 2>&3)
    clear
  else
    echo "Select build option:"
    select o in uboot kernel rootfs uboot+kernel all image; do
      BUILD_OPTION="$o"; break
    done
  fi
  info "Selected build option: $BUILD_OPTION"
  section_end "Select build option"
}

select_rootfs_profile() {
  section_start "Select rootfs profile"

  local _distro_default="bookworm"
  local _mirror_default_deb="http://deb.debian.org/debian"
  local _mirror_default_ubu="http://archive.ubuntu.com/ubuntu"

  if check_dialog; then
    exec 3>&1
    ROOTFS_DISTRO=$(dialog --menu "Choose base distro:" $DIALOG_HEIGHT $DIALOG_WIDTH 6 \
      bookworm "Debian 12 (stable)" \
      trixie   "Debian testing" \
      noble    "Ubuntu 24.04 LTS" \
      jammy    "Ubuntu 22.04 LTS" \
      custom   "Enter manually" \
      3>&1 1>&2 2>&3)
    clear
  else
    echo "Select base distro:"
    select choice in "bookworm (Debian 12)" "trixie (Debian testing)" "noble (Ubuntu 24.04)" "jammy (Ubuntu 22.04)" "custom"; do
      case "$REPLY" in
        1) ROOTFS_DISTRO="bookworm"; break ;;
        2) ROOTFS_DISTRO="trixie";   break ;;
        3) ROOTFS_DISTRO="noble";    break ;;
        4) ROOTFS_DISTRO="jammy";    break ;;
        5) ROOTFS_DISTRO="custom";   break ;;
      esac
    done
  fi

  if [ "$ROOTFS_DISTRO" = "custom" ]; then
    if check_dialog; then
      exec 3>&1
      ROOTFS_DISTRO=$(dialog --inputbox "Enter suite/codename (e.g. bookworm, noble):" 8 60 "$_distro_default" 3>&1 1>&2 2>&3)
      clear
    else
      read -rp "Enter suite/codename (e.g. bookworm, noble): " ROOTFS_DISTRO
    fi
  fi

  case "$ROOTFS_DISTRO" in
    bookworm|trixie) ROOTFS_MIRROR="${ROOTFS_MIRROR:-$_mirror_default_deb}" ;;
    noble|jammy)     ROOTFS_MIRROR="${ROOTFS_MIRROR:-$_mirror_default_ubu}" ;;
    *)               ROOTFS_MIRROR="${ROOTFS_MIRROR:-$_mirror_default_deb}" ;;
  esac

  if check_dialog; then
    exec 3>&1
    ROOTFS_MIRROR=$(dialog --inputbox "APT mirror URL:" 8 70 "$ROOTFS_MIRROR" 3>&1 1>&2 2>&3)
    clear
  else
    read -rp "APT mirror URL [$ROOTFS_MIRROR]: " _m
    [ -n "$_m" ] && ROOTFS_MIRROR="$_m"
  fi

  export DISTRO="$ROOTFS_DISTRO"
  export MIRROR="$ROOTFS_MIRROR"

  info "Rootfs: DISTRO=$DISTRO"
  info "Rootfs: MIRROR=$MIRROR"

  mkdir -p "$OUTPUT_DIR"
  {
    echo "DISTRO=$DISTRO"
    echo "MIRROR=$MIRROR"
  } > "$OUTPUT_DIR/rootfs.profile"

  section_end "Select rootfs profile"
}

select_rootfs_source() {
  section_start "Select rootfs source"
  if check_dialog; then
    exec 3>&1
    ROOTFS_SOURCE=$(dialog --menu "How to get rootfs?" $DIALOG_HEIGHT $DIALOG_WIDTH 6 \
      prebuilt "Download from linuxcontainers.org" \
      fresh    "Create fresh rootfs (debootstrap)" \
      3>&1 1>&2 2>&3)
    clear
  else
    echo "How to get rootfs?"
    select s in prebuilt fresh; do ROOTFS_SOURCE="$s"; break; done
  fi
  export ROOTFS_SOURCE
  info "Rootfs source: $ROOTFS_SOURCE"

  {
    echo "ROOTFS_SOURCE=$ROOTFS_SOURCE"
  } >> "$OUTPUT_DIR/rootfs.profile"

  section_end "Select rootfs source"
}

select_kernel_version() {
  section_start "Select kernel version"

  if [[ "$CHIP_FAMILY" == "sunxi" ]] || [[ "$CHIP" == a* ]]; then
    local latest
    latest=$(get_latest_stable_from_kernel_org)
    [ -z "$latest" ] && error "Failed to fetch latest stable kernel"
    KERNEL_VERSION="$latest"
    info "Selected kernel version: $KERNEL_VERSION"
    export KERNEL_VERSION
    section_end "Select kernel version"
    return
  fi

  local stable
  stable=$(get_latest_stable_from_kernel_org)
  [ -z "$stable" ] && error "Failed to fetch latest stable kernel"

  local opt
  if check_dialog; then
    exec 3>&1
    opt=$(dialog --menu "Select kernel version:" $DIALOG_HEIGHT $DIALOG_WIDTH 5 \
      "$stable" "Latest stable (recommended)" \
      custom     "Enter manually" \
      3>&1 1>&2 2>&3)
    clear
  else
    echo "Select kernel version:"
    select o in "$stable" "custom"; do opt="$o"; break; done
  fi

  if [ "$opt" = "custom" ]; then
    if check_dialog; then
      KERNEL_VERSION=$(dialog --inputbox "Enter custom kernel version (e.g. 6.9.2):" 8 50 3>&1 1>&2 2>&3)
      clear
    else
      read -rp "Enter custom kernel version (e.g. 6.9.2): " KERNEL_VERSION
    fi
  else
    KERNEL_VERSION="$opt"
  fi

  [[ "$KERNEL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "Invalid kernel version format: $KERNEL_VERSION"
  info "Selected kernel version: $KERNEL_VERSION"
  export KERNEL_VERSION
  section_end "Select kernel version"
}

prepare_sources_for_option() {
  section_start "Prepare sources"
  local MODE="--all"
  case "$BUILD_OPTION" in
    uboot)        MODE="--uboot" ;;
    kernel)       MODE="--kernel" ;;
    rootfs)       MODE="--rootfs" ;;
    uboot+kernel) MODE="--kernel" ;;
    all)          MODE="--all" ;;
  esac

  BOARD="$BOARD" CHIP_FAMILY="$CHIP_FAMILY" KERNEL_VERSION="${KERNEL_VERSION:-}" \
    "$BASE_DIR/prepare_sources.sh" "$MODE" --family "$CHIP_FAMILY" --board "$BOARD"

  section_end "Prepare sources"
}

main() {
  select_family
  select_board
  load_board_config
  select_build_option

  OUTPUT_DIR="$BASE_DIR/OUT/${CHIP_FAMILY}/${BOARD}"
  mkdir -p "$OUTPUT_DIR"
  export OUTPUT_DIR
  info "Output directory: $OUTPUT_DIR"

  if [ "$BUILD_OPTION" = "rootfs" ]; then
    select_rootfs_profile
    select_rootfs_source
  elif [ "$BUILD_OPTION" = "all" ]; then
    if [ -f "$OUTPUT_DIR/rootfs.profile" ] && [ -z "$ROOTFS_RESELECT" ]; then
      . "$OUTPUT_DIR/rootfs.profile"
      export DISTRO MIRROR ROOTFS_SOURCE
      info "Loaded previous rootfs profile: DISTRO=$DISTRO MIRROR=$MIRROR ROOTFS_SOURCE=${ROOTFS_SOURCE:-prebuilt}"
    else
      select_rootfs_profile
      select_rootfs_source
    fi
  fi

  case "$BUILD_OPTION" in
    kernel|uboot+kernel|all)
      select_kernel_version
      ;;
  esac

  # IMPORTANT: do NOT prepare/clean when we only want to create images
  if [ "$BUILD_OPTION" != "image" ]; then
    prepare_sources_for_option
  fi

  if [ -f "$OUTPUT_DIR/kernel.version" ]; then
    KV=$(cat "$OUTPUT_DIR/kernel.version")
    [ -n "$KV" ] && export KERNEL_VERSION="$KV" && info "Using kernel version from prepare step: $KERNEL_VERSION"
  fi

  section_start "Build stage"

  case "$BUILD_OPTION" in
    rootfs)
      if [ -x "$BASE_DIR/rootfs/setup_rootfs.sh" ]; then
        if [ "$DISTRO" = "noble" ] || [ "$DISTRO" = "jammy" ]; then
          ROOTFS_DISTRO="ubuntu"
        else
          ROOTFS_DISTRO="debian"
        fi
        BOARD="$BOARD" ARCH="$ARCH" CHIP="$CHIP" OUTPUT_DIR="$OUTPUT_DIR" \
        VERSION="$DISTRO" ROOTFS_VERSION="$DISTRO" \
        ROOTFS_DISTRO="$ROOTFS_DISTRO" ROOTFS_SOURCE="$ROOTFS_SOURCE" \
        DESKTOP_FLAVOR="$DESKTOP_FLAVOR" \
        "$BASE_DIR/rootfs/setup_rootfs.sh"
      else
        warn "rootfs/setup_rootfs.sh not found or not executable – rootfs not created"
      fi
      section_end "Build stage"
      script_end
      success "arm_build.sh completed (rootfs only)"
      return
      ;;

    all)
      case "$CHIP_FAMILY" in
        rockchip)
          "$BASE_DIR/rk-compile.sh" all
          ;;
        sunxi)
          if [ -x "$BASE_DIR/sunxi/sunxi-build-uboot.sh" ]; then
            "$BASE_DIR/sunxi/sunxi-build-uboot.sh" all
          else
            error "sunxi/sunxi-build-uboot.sh not found or not executable"
          fi
          ;;
        *)
          warn "No builder implemented for CHIP_FAMILY=$CHIP_FAMILY"
          ;;
      esac

      if [ -x "$BASE_DIR/rootfs/setup_rootfs.sh" ]; then
        if [ "$DISTRO" = "noble" ] || [ "$DISTRO" = "jammy" ]; then
          ROOTFS_DISTRO="ubuntu"
        else
          ROOTFS_DISTRO="debian"
        fi
        BOARD="$BOARD" ARCH="$ARCH" CHIP="$CHIP" OUTPUT_DIR="$OUTPUT_DIR" \
        VERSION="$DISTRO" ROOTFS_VERSION="$DISTRO" \
        ROOTFS_DISTRO="$ROOTFS_DISTRO" ROOTFS_SOURCE="${ROOTFS_SOURCE:-prebuilt}" \
        "$BASE_DIR/rootfs/setup_rootfs.sh"
      else
        warn "rootfs/setup_rootfs.sh not found or not executable – rootfs phase skipped"
      fi

      if [ -x "$BASE_DIR/images/create-images.sh" ]; then
        "$BASE_DIR/images/create-images.sh" "$CHIP" "$OUTPUT_DIR"
      else
        info "Image creator not found (images/create-images.sh). Skipping image creation."
      fi
      ;;

    image)
      # image-only path: do not build/prepare, just package what we have
      if [ -x "$BASE_DIR/images/create-images.sh" ]; then
        "$BASE_DIR/images/create-images.sh" "$CHIP" "$OUTPUT_DIR"
      else
        warn "images/create-images.sh not found – cannot create images"
      fi
      section_end "Build stage"
      script_end
      success "arm_build.sh completed (image only)"
      return
      ;;

    *)
      case "$CHIP_FAMILY" in
        rockchip)
          "$BASE_DIR/rk-compile.sh" "$BUILD_OPTION"
          ;;
        sunxi)
          if [ -x "$BASE_DIR/sunxi/sunxi-build-uboot.sh" ]; then
            "$BASE_DIR/sunxi/sunxi-build-uboot.shh" "$BUILD_OPTION"
          else
            error "sunxi/sunxi-build-uboot.sh not found or not executable"
          fi
          ;;
        *)
          warn "No builder implemented for CHIP_FAMILY=$CHIP_FAMILY"
          ;;
      esac
      ;;
  esac

  section_end "Build stage"
  script_end
  success "arm_build.sh completed"
}

main "$@"

