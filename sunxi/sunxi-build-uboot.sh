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
: "${DEVICE_TREE:?DEVICE_TREE not set}"
: "${CROSS_COMPILE:?CROSS_COMPILE not set}"

UBOOT_DIR="$BASE_DIR/u-boot"
ATF_DIR="$BASE_DIR/trusted-firmware-a"
CRUST_DIR="$BASE_DIR/crust"

PATCH_DIR="$BASE_DIR/patches/sunxi/uboot"

# --------------------------
# Helpers
# --------------------------
map_sunxi_atf_plat() {
  case "$CHIP" in
    a64) echo "sun50i_a64" ;;
    a527)  echo "sun55i_a523" ;;
    h6)  echo "sun50i_h6" ;;
    h616) echo "sun50i_h616" ;;
    a133) echo "sun50i_a133" ;;
    *)
      # If you export PROCESSOR_FAMILY as ATF PLAT name, fallback to it
      echo "${PROCESSOR_FAMILY:-}"
      ;;
  esac
}

build_atf_bl31() {
  # Only for arm64 boards which need BL31 in U-Boot build
  [ "$ARCH" = "arm64" ] || return 0

  local PLAT
  PLAT="$(map_sunxi_atf_plat)"
  [ -n "$PLAT" ] || error "ATF PLAT is empty for CHIP=$CHIP (set CHIP mapping in map_sunxi_atf_plat)"

  local BL31_PATH="$ATF_DIR/build/${PLAT}/release/bl31.bin"

  if [ -f "$BL31_PATH" ]; then
    info "ATF BL31 exists → $BL31_PATH"
    export BL31="$BL31_PATH"
    return 0
  fi

  [ -d "$ATF_DIR/.git" ] || error "trusted-firmware-a missing or not a git repo. Run prepare_sources.sh first."

  section_start "Build ATF BL31 (PLAT=$PLAT)"
  (
    cd "$ATF_DIR"
    make CROSS_COMPILE="$CROSS_COMPILE" PLAT="$PLAT" DEBUG=0 bl31 -j"$(nproc)"
  ) || error "ATF BL31 build failed (PLAT=$PLAT)"
  section_end "Build ATF BL31 (PLAT=$PLAT)"

  [ -f "$BL31_PATH" ] || error "BL31 not produced: $BL31_PATH"
  export BL31="$BL31_PATH"
  info "Using BL31: $BL31"
}

prepare_crust_scp() {
  # A64 needs SCP (crust/scp.bin) for U-Boot if you use SCP=...
  [ "$CHIP" = "a64" ] || return 0

  if [ ! -d "$CRUST_DIR/.git" ]; then
    section_start "Fetch Crust"
    info "Cloning crust → $CRUST_DIR"
    git clone https://github.com/arm-sbc/crust.git "$CRUST_DIR" || error "Failed to clone crust"
    section_end "Fetch Crust"
  fi

  # You said you already build it elsewhere; we only check presence
  local SCP_BIN="$CRUST_DIR/scp.bin"
  [ -f "$SCP_BIN" ] || error "Crust SCP missing: $SCP_BIN (build crust to generate scp.bin)"
  export SCP="$SCP_BIN"
  info "Using SCP: $SCP"
}

# --------------------------
# Prepare U-Boot tree
# --------------------------
section_start "Prepare U-Boot tree"

if [ ! -d "$UBOOT_DIR/.git" ]; then
  error "u-boot directory is missing or not a git repo. Run prepare_sources.sh first."
fi

if [ "${UBOOT_FORCE_CLEAN:-1}" -eq 1 ]; then
  info "Resetting u-boot tree to clean HEAD"
  (cd "$UBOOT_DIR" && git reset --hard HEAD && git clean -fdx)
fi

section_end "Prepare U-Boot tree"

# --------------------------
# Apply U-Boot patches
# --------------------------
section_start "Apply U-Boot patches"

apply_patch_strict() {
  local patch_file="$1"
  local strip="${2:-0}"

  [ -f "$patch_file" ] || return 0

  info "Patch: $(basename "$patch_file")"

  # 1) If it applies cleanly (dry-run), apply it for real
  if (cd "$UBOOT_DIR" && patch -p"$strip" --dry-run -N -i "$patch_file" >/dev/null); then
    info "  → applying (p$strip)"
    (cd "$UBOOT_DIR" && patch -p"$strip" -N -i "$patch_file") \
      || error "Patch failed while applying: $(basename "$patch_file")"
    success "  ✔ applied"
    return 0
  fi

  # 2) If it does NOT apply, check whether it's already applied (reverse dry-run)
  if (cd "$UBOOT_DIR" && patch -p"$strip" --dry-run -R -N -i "$patch_file" >/dev/null); then
    warn "  ↪ already applied (skipping)"
    return 0
  fi

  # 3) Otherwise it’s a real failure (wrong base, conflicts, wrong -p level)
  error "Patch cannot be applied and is not already applied: $(basename "$patch_file")
Hints:
  - wrong strip level (-p$strip)
  - patch doesn’t match current U-Boot commit
  - patch expects different paths"
}

# Choose strip level (your RK uses -Np0)
PATCH_STRIP="${PATCH_STRIP:-0}"

# Board patch
BOARD_PATCH="$PATCH_DIR/${BOARD}-uboot.patch"
apply_patch_strict "$BOARD_PATCH" "$PATCH_STRIP"

# Common / generic patches (same list style as RK, adjust as you like)
for p in \
  "$PATCH_DIR/${CHIP}-uboot.patch" \
  "$PATCH_DIR/ARM-SBC-MULTI-sunxi-uboot.patch" \
  "$PATCH_DIR/"*.patch
do
  [ -f "$p" ] || continue
  # avoid applying the board patch twice
  [ "$p" = "$BOARD_PATCH" ] && continue
  apply_patch_strict "$p" "$PATCH_STRIP"
done

section_end "Apply U-Boot patches"

# --------------------------
# Build U-Boot
# --------------------------
section_start "Build U-Boot"

# Build prerequisites for sunxi U-Boot
build_atf_bl31
prepare_crust_scp

cd "$UBOOT_DIR"

make distclean >/dev/null 2>&1 || true

info "Configuring U-Boot: $UBOOT_DEFCONFIG"
make CROSS_COMPILE="$CROSS_COMPILE" "$UBOOT_DEFCONFIG"

# ✅ RK-style: take DT from U-Boot .config (handles upstream dts paths like allwinner/...)
DEVICE_TREE_NAME=$(grep -oP 'CONFIG_DEFAULT_DEVICE_TREE="\K[^"]+' .config || true)

# Fallback only if defconfig doesn't set it (older sunxi configs)
if [ -z "$DEVICE_TREE_NAME" ]; then
  warn "CONFIG_DEFAULT_DEVICE_TREE not found in .config; falling back to exported DEVICE_TREE"
  # convert kernel-style .dts -> basename, and for upstream layout prefix allwinner/
  DT_BASE="${DEVICE_TREE%.dts}"
  DT_BASE="${DT_BASE##*/}"
  DEVICE_TREE_NAME="allwinner/$DT_BASE"
fi

info "Using U-Boot DEVICE_TREE: $DEVICE_TREE_NAME"
info "Building U-Boot for $BOARD ($CHIP)"

make -j"$(nproc)" \
  CROSS_COMPILE="$CROSS_COMPILE" \
  DEVICE_TREE="$DEVICE_TREE_NAME" \
  ${BL31:+BL31="$BL31"} \
  ${SCP:+SCP="$SCP"}

mkdir -p "$OUTPUT_DIR"
cp u-boot-sunxi-with-spl.bin "$OUTPUT_DIR"/ || error "u-boot-sunxi-with-spl.bin missing"

section_end "Build U-Boot"

script_end
success "U-Boot build for $BOARD completed → $OUTPUT_DIR"
