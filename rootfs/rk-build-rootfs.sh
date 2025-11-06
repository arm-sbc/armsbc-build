#!/bin/bash
set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$BASE_DIR/common/log.sh"

script_start
SCRIPT_NAME="rk-build-rootfs.sh"

: "${BOARD:?BOARD not set}"
: "${CHIP:?CHIP not set}"
: "${ARCH:?ARCH not set}"
: "${OUTPUT_DIR:?OUTPUT_DIR not set}"

DISTRO="${DISTRO:-bookworm}"                           # change to 'noble' for Ubuntu 24.04
MIRROR="${MIRROR:-http://deb.debian.org/debian}"       # change to 'http://archive.ubuntu.com/ubuntu' for Ubuntu
ROOTFS_DIR="$OUTPUT_DIR/rootfs"

section_start "Create rootfs ($DISTRO, $ARCH) for $BOARD ($CHIP)"
info "ROOTFS_DIR: $ROOTFS_DIR"

sudo mkdir -p "$ROOTFS_DIR"

# wipe if requested / or ask if non-empty
if [ "${BUILD_FORCE:-0}" = "1" ]; then
  warn "BUILD_FORCE=1 → removing existing $ROOTFS_DIR contents"
  sudo rm -rf "$ROOTFS_DIR"/*
else
  if [ -d "$ROOTFS_DIR" ] && [ "$(ls -A "$ROOTFS_DIR" 2>/dev/null)" ]; then
    read -rp "Rootfs exists at $ROOTFS_DIR, wipe it? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] && sudo rm -rf "$ROOTFS_DIR"/* || { info "Keeping existing rootfs"; script_end; exit 0; }
  fi
fi

section_start "Install host deps"
sudo apt-get update -y >/dev/null
sudo apt-get install -y debootstrap qemu-user-static binfmt-support ca-certificates >/dev/null
section_end "Install host deps"

section_start "debootstrap stage1"
sudo debootstrap --arch=arm64 --foreign "$DISTRO" "$ROOTFS_DIR" "$MIRROR"
section_end "debootstrap stage1"

sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"

section_start "debootstrap stage2 (chroot)"
sudo chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage
section_end "debootstrap stage2 (chroot)"

section_start "Base config"
echo "armsbc-$BOARD" | sudo tee "$ROOTFS_DIR/etc/hostname" >/dev/null

if [[ "$DISTRO" == "bookworm" ]]; then
  cat <<'EOF' | sudo tee "$ROOTFS_DIR/etc/apt/sources.list" >/dev/null
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
fi

cat <<'EOF' | sudo tee "$ROOTFS_DIR/etc/fstab" >/dev/null
proc    /proc   proc    defaults 0 0
tmpfs   /tmp    tmpfs   defaults,noatime 0 0
EOF

# DHCP on eth0 via systemd-networkd
sudo mkdir -p "$ROOTFS_DIR/etc/systemd/network"
cat <<'EOF' | sudo tee "$ROOTFS_DIR/etc/systemd/network/eth0.network" >/dev/null
[Match]
Name=eth0

[Network]
DHCP=yes
EOF

# enable networkd & resolved
sudo chroot "$ROOTFS_DIR" systemctl enable systemd-networkd.service >/dev/null 2>&1 || true
sudo chroot "$ROOTFS_DIR" systemctl enable systemd-resolved.service >/dev/null 2>&1 || true
sudo chroot "$ROOTFS_DIR" ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# root password: root
echo "root:root" | sudo chroot "$ROOTFS_DIR" chpasswd
section_end "Base config"

section_start "Install minimal packages"
sudo chroot "$ROOTFS_DIR" apt-get update
sudo chroot "$ROOTFS_DIR" apt-get install -y --no-install-recommends \
  systemd-sysv net-tools iproute2 iputils-ping ethtool openssh-server \
  sudo vim less locales tzdata ca-certificates >/dev/null
section_end "Install minimal packages"

section_start "Locale & timezone"
sudo chroot "$ROOTFS_DIR" ln -sf /usr/share/zoneinfo/Asia/Dubai /etc/localtime
sudo chroot "$ROOTFS_DIR" bash -c 'echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen'
sudo chroot "$ROOTFS_DIR" locale-gen en_US.UTF-8
sudo chroot "$ROOTFS_DIR" update-locale LANG=en_US.UTF-8
section_end "Locale & timezone"

# marker file
echo "$DISTRO" | sudo tee "$ROOTFS_DIR/.armsbc_distro" >/dev/null

section_end "Create rootfs ($DISTRO, $ARCH) for $BOARD ($CHIP)"
script_end
success "rk-build-rootfs.sh completed → $ROOTFS_DIR"

