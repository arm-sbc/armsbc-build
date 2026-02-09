#!/bin/bash
set -e

# sunxi/sunxi-build-kernel.sh
# build kernel for Allwinner (sunxi) boards using env from arm_build.sh

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$BASE_DIR/common/log.sh"

script_start
SCRIPT_NAME="$(basename "$0")"

# ====== required env ======
: "${BOARD:?BOARD not set}"
: "${CHIP:?CHIP not set}"
: "${ARCH:?ARCH not set}"
: "${OUTPUT_DIR:?OUTPUT_DIR not set}"
: "${KERNEL_DEFCONFIG:?KERNEL_DEFCONFIG not set}"
: "${KERNEL_VERSION:?KERNEL_VERSION not set}"

KERNEL_DIR="$BASE_DIR/linux-${KERNEL_VERSION}"
PATCH_DIR_BASE="$BASE_DIR/patches/sunxi/kernel"
CUSTOM_DEFCONFIG_DIR="$BASE_DIR/custom_configs/defconfig"
CUSTOM_DTS_BASE="$BASE_DIR/custom_configs/dts/sunxi"

info "BOARD=$BOARD CHIP=$CHIP ARCH=$ARCH"
info "KERNEL_VERSION=$KERNEL_VERSION"
info "OUTPUT_DIR=$OUTPUT_DIR"
info "KERNEL_DIR=$KERNEL_DIR"

# ====== check kernel source ======
section_start "Check kernel source"
if [ ! -d "$KERNEL_DIR" ]; then
  error "Kernel source $KERNEL_DIR not found. Run prepare_sources.sh --kernel --family sunxi --board $BOARD"
fi
section_end "Check kernel source"

# ====== apply patches ======
apply_kernel_patches() {
  section_start "Apply kernel patches"

  # 1) board-specific patch
  BOARD_PATCH="$PATCH_DIR_BASE/${BOARD}-kernel.patch"
  if [ -f "$BOARD_PATCH" ]; then
    info "Applying board-specific kernel patch: $(basename "$BOARD_PATCH")"
    (
      cd "$KERNEL_DIR"
      patch -Np1 -i "$BOARD_PATCH" || warn "Board patch already applied / failed"
    )
  else
    info "No board-specific kernel patch for $BOARD"
  fi

  # 2) SoC-specific patches
  for p in "$PATCH_DIR_BASE"/${CHIP}-*.patch; do
    [ -f "$p" ] || continue
    info "Applying SoC kernel patch: $(basename "$p")"
    (
      cd "$KERNEL_DIR"
      patch -Np1 -i "$p" || warn "SoC patch already applied / failed"
    )
  done

  section_end "Apply kernel patches"
}

# ====== setup DTS ======
setup_dts_tree() {
  section_start "Setup DTS for armsbc (sunxi)"

  if [ "$ARCH" = "arm64" ]; then
    K_DTS_DIR="$KERNEL_DIR/arch/arm64/boot/dts"
    ARMSBC_DTS_DIR="$KERNEL_DIR/arch/arm64/boot/dts/armsbc"
    MAIN_DTS_MK="$KERNEL_DIR/arch/arm64/boot/dts/Makefile"
    SRC_DTS_DIR="$CUSTOM_DTS_BASE/arm64"
  else
    K_DTS_DIR="$KERNEL_DIR/arch/arm/boot/dts"
    ARMSBC_DTS_DIR="$KERNEL_DIR/arch/arm/boot/dts/armsbc"
    MAIN_DTS_MK="$KERNEL_DIR/arch/arm/boot/dts/Makefile"
    SRC_DTS_DIR="$CUSTOM_DTS_BASE/arm32"
  fi

  mkdir -p "$ARMSBC_DTS_DIR"

  # copy custom DTS
  if [ -d "$SRC_DTS_DIR" ]; then
    info "Copying board DTS from $SRC_DTS_DIR → $ARMSBC_DTS_DIR"
    cp -f "$SRC_DTS_DIR"/*.dts "$ARMSBC_DTS_DIR"/ 2>/dev/null || true
  else
    warn "No custom DTS dir found at $SRC_DTS_DIR"
  fi

  # ensure vendor dtsi are reachable (allwinner/)
  if [ -d "$K_DTS_DIR/allwinner" ]; then
    info "Ensuring allwinner .dtsi includes are present"
    cp -f "$K_DTS_DIR/allwinner"/*.dtsi "$ARMSBC_DTS_DIR"/ 2>/dev/null || true
  fi

  # generate armsbc DTS Makefile
  info "Generating armsbc DTS Makefile"
  {
    echo "dtb-\$(CONFIG_ARCH_SUNXI) += \\"
    for f in "$ARMSBC_DTS_DIR"/*.dts; do
      [ -f "$f" ] || continue
      echo "  $(basename "${f%.dts}.dtb") \\"
    done
  } > "$ARMSBC_DTS_DIR/Makefile"

  # include armsbc in main Makefile
  if ! grep -q "subdir-y += armsbc" "$MAIN_DTS_MK"; then
    echo "subdir-y += armsbc" >> "$MAIN_DTS_MK"
    info "Added 'subdir-y += armsbc' to $MAIN_DTS_MK"
  else
    info "armsbc already present in $MAIN_DTS_MK"
  fi

  section_end "Setup DTS for armsbc"
}

# ====== kernel build ======
build_kernel() {
  section_start "Kernel build (sunxi)"

  cd "$KERNEL_DIR"

  if [ "$ARCH" = "arm64" ]; then
    : "${CROSS_COMPILE:=aarch64-linux-gnu-}"
    KIMG="Image"
  else
    : "${CROSS_COMPILE:=arm-linux-gnueabihf-}"
    KIMG="zImage"
  fi
  info "Using CROSS_COMPILE=$CROSS_COMPILE"

  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" mrproper >/dev/null 2>&1 || true

  if [ ! -f "$CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG" ]; then
    error "Kernel defconfig not found: $CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG"
  fi

  info "Applying defconfig: $KERNEL_DEFCONFIG"
  cp "$CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG" .config
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

  echo -ne "\033[1;33mRun make menuconfig ? [y/N]: \033[0m"
  read -r DO_MENU
  if [[ "$DO_MENU" =~ ^[Yy]$ ]]; then
    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" menuconfig
    cp .config "$OUTPUT_DIR/config-$KERNEL_VERSION"
  fi

  info "Building kernel image + modules + dtbs ..."
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)" "$KIMG" modules dtbs

  mkdir -p "$OUTPUT_DIR" "$OUTPUT_DIR/dtb" "$OUTPUT_DIR/modules"

  cp "arch/$ARCH/boot/$KIMG" "$OUTPUT_DIR/" || error "Kernel image not found"
  [ -f System.map ] && cp System.map "$OUTPUT_DIR/System.map-$KERNEL_VERSION"
  [ -f .config ] && cp .config "$OUTPUT_DIR/config-$KERNEL_VERSION"

  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    INSTALL_MOD_PATH="$OUTPUT_DIR/modules" modules_install

  # copy DTB for this board
  if [ -n "$DEVICE_TREE" ]; then
    DTB_NAME="$(basename "${DEVICE_TREE%.dts}.dtb")"

    if [ -f "arch/$ARCH/boot/dts/armsbc/$DTB_NAME" ]; then
      cp "arch/$ARCH/boot/dts/armsbc/$DTB_NAME" "$OUTPUT_DIR/dtb/"
      info "Copied DTB: $DTB_NAME"
    elif [ -f "arch/$ARCH/boot/dts/allwinner/$DTB_NAME" ]; then
      cp "arch/$ARCH/boot/dts/allwinner/$DTB_NAME" "$OUTPUT_DIR/dtb/"
      info "Copied DTB (allwinner): $DTB_NAME"
    else
      warn "DTB $DTB_NAME not found after build"
    fi
  fi

  # also copy all armsbc dtbs
  cp arch/$ARCH/boot/dts/armsbc/*.dtb "$OUTPUT_DIR/dtb/" 2>/dev/null || true

  cd "$BASE_DIR"
  section_end "Kernel build (sunxi)"
}

# ====== main flow ======
apply_kernel_patches
setup_dts_tree
build_kernel

script_end
success "sunxi-build-kernel.sh completed for $BOARD ($CHIP)"

