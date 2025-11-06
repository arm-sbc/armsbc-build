#!/bin/bash
set -e

# rk/rk-build-kernel.sh
# build kernel for Rockchip boards using env from arm_build.sh

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
PATCH_DIR_BASE="$BASE_DIR/patches/rockchip/kernel"
CUSTOM_DEFCONFIG_DIR="$BASE_DIR/custom_configs/defconfig"
CUSTOM_DTS_BASE="$BASE_DIR/custom_configs/dts/rockchip"

info "BOARD=$BOARD CHIP=$CHIP ARCH=$ARCH"
info "KERNEL_VERSION=$KERNEL_VERSION"
info "OUTPUT_DIR=$OUTPUT_DIR"
info "KERNEL_DIR=$KERNEL_DIR"

# ====== check kernel source ======
section_start "Check kernel source"
if [ ! -d "$KERNEL_DIR" ]; then
  error "Kernel source $KERNEL_DIR not found. Run: ./prepare_sources.sh --kernel --family rockchip --board $BOARD"
fi
section_end "Check kernel source"

# ====== optionally clean old kernel tree ======
if [ "${BUILD_FORCE:-0}" -eq 1 ]; then
  section_start "Clean old kernel tree (BUILD_FORCE=1)"
  rm -rf "$KERNEL_DIR"
  error "You removed the kernel tree. Run prepare_sources.sh again."  # we don't re-download here
  section_end "Clean old kernel tree"
fi

# ====== apply patches ======
apply_kernel_patches() {
  section_start "Apply kernel patches"

  # 1) board-specific patch: patches/rockchip/kernel/<BOARD>-kernel.patch
  BOARD_PATCH="$PATCH_DIR_BASE/${BOARD}-kernel.patch"
  if [ -f "$BOARD_PATCH" ]; then
    info "Applying board-specific kernel patch: $(basename "$BOARD_PATCH")"
    (
      cd "$KERNEL_DIR"
      patch -Np1 -i "$BOARD_PATCH" || warn "Board patch already applied / failed: $(basename "$BOARD_PATCH")"
    )
  else
    info "No board-specific kernel patch for $BOARD"
  fi

  # 2) SoC-specific patches: patches/rockchip/kernel/${CHIP}-*.patch
  for p in "$PATCH_DIR_BASE"/${CHIP}-*.patch; do
    [ -f "$p" ] || continue
    info "Applying SoC kernel patch: $(basename "$p")"
    (
      cd "$KERNEL_DIR"
      patch -Np1 -i "$p" || warn "SoC patch already applied / failed: $(basename "$p")"
    )
  done

  # 3) rk35/ folder for 356x/3576/3588
  if [ -d "$PATCH_DIR_BASE/rk35" ]; then
    for p in "$PATCH_DIR_BASE/rk35"/${CHIP}-*.patch; do
      [ -f "$p" ] || continue
      info "Applying rk35 kernel patch: $(basename "$p")"
      (
        cd "$KERNEL_DIR"
        patch -Np1 -i "$p" || warn "rk35 patch already applied / failed: $(basename "$p")"
      )
    done
  fi

  section_end "Apply kernel patches"
}

# ====== copy/custom DTS ======
setup_dts_tree() {
  section_start "Setup DTS for armsbc"

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

  if [ -d "$SRC_DTS_DIR" ]; then
    info "Copying board DTS from $SRC_DTS_DIR → $ARMSBC_DTS_DIR"
    cp -f "$SRC_DTS_DIR"/*.dts "$ARMSBC_DTS_DIR"/ 2>/dev/null || true
  else
    warn "No custom DTS dir found at $SRC_DTS_DIR"
  fi

  # We may also need vendor dtsi from rockchip dir (for includes)
  if [ -d "$K_DTS_DIR/rockchip" ]; then
    info "Ensuring .dtsi includes are present"
    cp -f "$K_DTS_DIR/rockchip"/*.dtsi "$ARMSBC_DTS_DIR"/ 2>/dev/null || true
  fi

  # generate armsbc/Makefile
  info "Generating armsbc DTS Makefile"
  {
    echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += \\"
    for f in "$ARMSBC_DTS_DIR"/*.dts; do
      [ -f "$f" ] || continue
      bname=$(basename "${f%.dts}.dtb")
      echo "  $bname \\"
    done
  } > "$ARMSBC_DTS_DIR/Makefile"

  # make sure main dts makefile includes armsbc
  if ! grep -q "subdir-y += armsbc" "$MAIN_DTS_MK"; then
    echo "subdir-y += armsbc" >> "$MAIN_DTS_MK"
    info "Added 'subdir-y += armsbc' to $MAIN_DTS_MK"
  else
    info "armsbc already present in $MAIN_DTS_MK"
  fi

  section_end "Setup DTS for armsbc"
}

# ====== kernel build ======
# ====== kernel build ======
build_kernel() {
  section_start "Kernel build"

  cd "$KERNEL_DIR"

  # pick cross compiler automatically
  if [ "$ARCH" = "arm64" ]; then
    : "${CROSS_COMPILE:=aarch64-linux-gnu-}"
    KIMG="Image"
  else
    : "${CROSS_COMPILE:=arm-linux-gnueabihf-}"
    KIMG="zImage"
  fi
  info "Using CROSS_COMPILE=$CROSS_COMPILE"

  # clean (just objects, keep sources)
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" mrproper >/dev/null 2>&1 || true

  # copy our defconfig
  if [ ! -f "$CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG" ]; then
    error "Kernel defconfig not found: $CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG"
  fi

  info "Applying defconfig: $KERNEL_DEFCONFIG"
  cp "$CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG" .config
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

  # ask user if they want menuconfig
  echo -ne "\033[1;33mRun make menuconfig ? [y/N]: \033[0m"
  read -r DO_MENU
  if [[ "$DO_MENU" =~ ^[Yy]$ ]]; then
    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" menuconfig
    # save updated .config
    cp .config "$OUTPUT_DIR/config-$KERNEL_VERSION"
  fi

  info "Building kernel image + modules + dtbs ..."
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)" "$KIMG" modules dtbs

  mkdir -p "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR/dtb"
  mkdir -p "$OUTPUT_DIR/modules"

  # copy image
  if [ -f "arch/$ARCH/boot/$KIMG" ]; then
    cp "arch/$ARCH/boot/$KIMG" "$OUTPUT_DIR/"
    info "Copied kernel image → $OUTPUT_DIR/$KIMG"
  else
    error "Kernel image arch/$ARCH/boot/$KIMG not found"
  fi

  # copy map and config
  [ -f System.map ] && cp System.map "$OUTPUT_DIR/System.map-$KERNEL_VERSION" && \
    info "Copied System.map → $OUTPUT_DIR/System.map-$KERNEL_VERSION"
  [ -f .config ] && cp .config "$OUTPUT_DIR/config-$KERNEL_VERSION" && \
    info "Copied .config → $OUTPUT_DIR/config-$KERNEL_VERSION"

  # install modules into OUT/modules
  # we install to a temp root under OUT, then flatten if needed
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    INSTALL_MOD_PATH="$OUTPUT_DIR/modules" modules_install
  info "Installed kernel modules → $OUTPUT_DIR/modules/"

  # copy DTB for this board if present
  if [ -n "$DEVICE_TREE" ]; then
    DTB_NAME="$(basename "${DEVICE_TREE%.dts}.dtb")"

    if [ -f "arch/$ARCH/boot/dts/armsbc/$DTB_NAME" ]; then
      cp "arch/$ARCH/boot/dts/armsbc/$DTB_NAME" "$OUTPUT_DIR/dtb/"
      info "Copied DTB (armsbc): $DTB_NAME → $OUTPUT_DIR/dtb/"
    elif [ -f "arch/$ARCH/boot/dts/rockchip/$DTB_NAME" ]; then
      cp "arch/$ARCH/boot/dts/rockchip/$DTB_NAME" "$OUTPUT_DIR/dtb/"
      info "Copied DTB (rockchip): $DTB_NAME → $OUTPUT_DIR/dtb/"
    else
      warn "DTB $DTB_NAME not found in armsbc/ or rockchip/ after build"
    fi
  else
    warn "DEVICE_TREE not set in board_config.sh → skipping DTB copy"
  fi

  # OPTIONAL: also copy all armsbc dtbs we just generated
  if [ -d "arch/$ARCH/boot/dts/armsbc" ]; then
    cp arch/$ARCH/boot/dts/armsbc/*.dtb "$OUTPUT_DIR/dtb/" 2>/dev/null || true
    info "Copied armsbc DTBs → $OUTPUT_DIR/dtb/"
  fi

  cd "$BASE_DIR"
  section_end "Kernel build"
}

# ====== main flow ======
apply_kernel_patches
setup_dts_tree
build_kernel

script_end
success "rk-build-kernel.sh completed for $BOARD ($CHIP)"
