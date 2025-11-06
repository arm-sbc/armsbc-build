#!/bin/bash
set -e

SCRIPT_NAME=$(basename "$0")
BUILD_START_TIME=$(date +%s)
: "${LOG_FILE:=build.log}"
touch "$LOG_FILE"

# --- Unified Logging ---
log_internal() {
  local LEVEL="$1"
  local MESSAGE="$2"
  local TIMESTAMP="[$(date +'%Y-%m-%d %H:%M:%S')]"
  local COLOR RESET

  case "$LEVEL" in
    INFO)    COLOR="\033[1;34m" ;;
    WARN)    COLOR="\033[1;33m" ;;
    ERROR)   COLOR="\033[1;31m" ;;
    DEBUG)   COLOR="\033[1;36m" ;;
    PROMPT)  COLOR="\033[1;32m" ;;
    SUCCESS) COLOR="\033[1;92m" ;;
    *)       COLOR="\033[0m" ;;
  esac
  RESET="\033[0m"

  local SHORT_LINE="[$LEVEL] $MESSAGE"
  local FULL_LINE="${TIMESTAMP}[$LEVEL][$SCRIPT_NAME] $MESSAGE"

  if [ -t 1 ]; then
    echo -e "${COLOR}${SHORT_LINE}${RESET}" | tee -a "$LOG_FILE"
  else
    echo "$SHORT_LINE" >> "$LOG_FILE"
  fi

  echo "$FULL_LINE" >> "$LOG_FILE"
}

info()    { log_internal INFO "$@"; }
warn()    { log_internal WARN "$@"; }
error()   { log_internal ERROR "$@"; exit 1; }
debug()   { log_internal DEBUG "$@"; }
success() { log_internal SUCCESS "$@"; }

# --- Inputs ---
ROOTFS_DIR="$1"
ARCH="$2"
QEMU_BIN="$3"
VERSION="$4"
BOARD="${BOARD:-$5}"            # optional 5th arg from caller
DESKTOP_FLAVOR="${DESKTOP_FLAVOR:-}"  # may be exported from board_config.sh

cleanup_mounts() {
  info "Cleaning up mounts..."
  sudo umount -l "$ROOTFS_DIR/sys" 2>/dev/null || true
  sudo umount -l "$ROOTFS_DIR/proc" 2>/dev/null || true
  sudo umount -l "$ROOTFS_DIR/dev" 2>/dev/null || true
}
trap cleanup_mounts EXIT INT TERM

# --- Validation ---
if [ -z "$ROOTFS_DIR" ] || [ -z "$ARCH" ] || [ -z "$QEMU_BIN" ] || [ -z "$VERSION" ]; then
  error "Usage: $0 <rootfs_dir> <arch> <qemu_bin> <version> [BOARD]"
fi
if [ "$ROOTFS_DIR" = "/" ]; then
  error "Refusing to operate on ROOTFS_DIR=/"
fi
if [ ! -f "$QEMU_BIN" ]; then
  error "QEMU binary not found at $QEMU_BIN"
fi

info "ROOTFS_DIR=$ROOTFS_DIR ARCH=$ARCH VERSION=$VERSION BOARD=${BOARD:-<unset>} DESKTOP_FLAVOR=${DESKTOP_FLAVOR:-<unset>}"

# --- Setup outside chroot ---
info "Copying QEMU binary..."
sudo cp "$QEMU_BIN" "$ROOTFS_DIR/usr/bin/"

info "Ensuring /tmp..."
sudo mkdir -p "$ROOTFS_DIR/tmp"
sudo chmod 1777 "$ROOTFS_DIR/tmp"

info "Binding /dev, /proc, /sys..."
sudo mount --bind /dev  "$ROOTFS_DIR/dev"
sudo mount --bind /proc "$ROOTFS_DIR/proc"
sudo mount --bind /sys  "$ROOTFS_DIR/sys"

info "Setting resolv.conf..."
sudo mkdir -p "$ROOTFS_DIR/etc"
if [ -L "$ROOTFS_DIR/etc/resolv.conf" ]; then
  sudo rm -f "$ROOTFS_DIR/etc/resolv.conf"
fi
cat <<EOF | sudo tee "$ROOTFS_DIR/etc/resolv.conf" > /dev/null
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# --- Run inside chroot ---
# pass BOARD, VERSION, DESKTOP_FLAVOR through env
sudo BOARD="$BOARD" VERSION="$VERSION" DESKTOP_FLAVOR="$DESKTOP_FLAVOR" chroot "$ROOTFS_DIR" /bin/bash -s <<'CHROOT_EOF'
set -e

echo "[INFO] In chroot: VERSION=${VERSION:-n/a} BOARD=${BOARD:-n/a} DESKTOP_FLAVOR=${DESKTOP_FLAVOR:-auto}"

# hostname
echo "armsbc" > /etc/hostname
if ! grep -q "127.0.1.1" /etc/hosts; then
  echo "127.0.1.1   armsbc" >> /etc/hosts
fi

apt-get update -y
apt-get install -y locales

sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# user
if ! id ubuntu >/dev/null 2>&1; then
  useradd -m -s /bin/bash ubuntu
  echo "ubuntu:ubuntu" | chpasswd
fi
usermod -aG sudo ubuntu
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-ubuntu-user
chmod 0440 /etc/sudoers.d/99-ubuntu-user

# base packages
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  openssh-server network-manager gpiod alsa-utils fdisk nano i2c-tools util-linux-extra

# detect ubuntu
is_ubuntu=0
case "$VERSION" in
  noble|jammy|focal|bionic)
    is_ubuntu=1
    ;;
esac

# decide desktop:
# 1) explicit DESKTOP_FLAVOR from env (unity|lxqt|none)
# 2) else: your old rule (Ubuntu + EDGE -> unity, else lxqt)
final_desktop="$DESKTOP_FLAVOR"

if [ -z "$final_desktop" ]; then
  if [ "$is_ubuntu" -eq 1 ] && [[ "$BOARD" == *EDGE* ]]; then
    final_desktop="unity"
  else
    final_desktop="lxqt"
  fi
fi

echo "[INFO] Final desktop selection: $final_desktop"

if [ "$final_desktop" = "unity" ]; then
  echo "[INFO] Installing Unity desktop ..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
  unity-session unity-control-center compiz compiz-plugins \
  indicator-session lightdm network-manager-gnome blueman \
  gnome-terminal gnome-system-monitor gvfs-backends gvfs-fuse \
  xdg-user-dirs firefox || true

  mkdir -p /etc/lightdm/lightdm.conf.d
  cat <<AUTOLOGIN >/etc/lightdm/lightdm.conf.d/50-autologin.conf
[Seat:*]
autologin-user=ubuntu
autologin-user-timeout=0
user-session=unity
AUTOLOGIN

elif [ "$final_desktop" = "none" ]; then
  echo "[INFO] DESKTOP_FLAVOR=none → skipping desktop install"

else
  echo "[INFO] Installing LXQt desktop ..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    lxqt-core lxqt-panel lxqt-session openbox lightdm xinit \
    pcmanfm lxterminal qps lxqt-policykit lxappearance \
    network-manager-gnome blueman || true

  mkdir -p /etc/lightdm/lightdm.conf.d
  cat <<AUTOLOGIN >/etc/lightdm/lightdm.conf.d/50-autologin.conf
[Seat:*]
autologin-user=ubuntu
autologin-user-timeout=0
user-session=lxqt
AUTOLOGIN
fi

# netplan
rm -f /etc/netplan/*.yaml
mkdir -p /etc/netplan
cat <<NETPLAN >/etc/netplan/01-network-manager.yaml
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    default:
      match:
        name: "e*"
      dhcp4: true
NETPLAN
chown root:root /etc/netplan/01-network-manager.yaml
chmod 600 /etc/netplan/01-network-manager.yaml

apt clean
rm -rf /var/lib/apt/lists/*
CHROOT_EOF

# --- Unmount ---
info "Unmounting bind mounts..."
sudo umount "$ROOTFS_DIR/dev"
sudo umount "$ROOTFS_DIR/proc"
sudo umount "$ROOTFS_DIR/sys"

# --- Timing ---
if [ -n "$BUILD_START_TIME" ]; then
  BUILD_END_TIME=$(date +%s)
  BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
  minutes=$((BUILD_DURATION / 60))
  seconds=$((BUILD_DURATION % 60))
  info "Total postinstall time: ${minutes}m ${seconds}s"
fi

success "Post-installation complete."

