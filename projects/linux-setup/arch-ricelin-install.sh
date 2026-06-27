#!/usr/bin/env bash
# ============================================================================
# Arch Linux + Ricelin Desktop — Fresh Install from Live USB
# ============================================================================
# Complete zero-to-desktop: Live USB → partition → pacstrap → chroot →
# boot loader → user → Ricelin Hyprland desktop.
#
# Usage:
#   1. Boot Arch Linux Live USB
#   2. Download this script to a USB drive or paste it
#   3. Run: sudo bash arch-ricelin-install.sh
#
# Or with the bundled Ricelin installer (if you have it):
#   sudo bash arch-ricelin-install.sh --with-installer /path/to/install-ricelin.sh
#
# Non-interactive mode:
#   sudo bash arch-ricelin-install.sh --auto /dev/sda \
#       --hostname mypc --user mo --password "***" --timezone Asia/Shanghai
#
# WARNING: This will ERASE the entire target disk. Double-check disk selection.
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
RICELIN_REPO="https://github.com/Gakuseei/Ricelin"
RICELIN_DIR="/root/.local/share/ricelin"   # inside chroot
MNT_BASE="/mnt"
MNT_BOOT="${MNT_BASE}/boot"
MNT_EFI="${MNT_BASE}/boot/efi"
MNT_HOME="${MNT_BASE}/home"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RICELIN_INSTALLER="${SCRIPT_DIR}/install-ricelin.sh"

# ---------------------------------------------------------------------------
# Default configuration (overridden by --auto flags)
# ---------------------------------------------------------------------------
DISK=""
HOSTNAME="arch-ricelin"
USERNAME="archuser"
USERPASS=""
TIMEZONE="Asia/Shanghai"
LOCALE="en_US.UTF-8"
KMAP="us"
MIRROR="https://mirrors.aliyun.com/archlinux/$repo/os/$arch"
BOOTLOADER="grub"       # grub or systemd-boot
USE_SWAP=false          # enable swap partition
SWAP_SIZE="4G"          # swap size
WIFI_SSID=""
WIFI_PASS=""
NIC=""                  # network interface name (auto-detected)

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

info()    { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
section() { printf "\n${BOLD}${CYAN}▶ %s${NC}\n\n" "$*"; }
ok()      { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
fail()    { printf "  ${RED}✗${NC} %s\n" "$*"; }
ask()     { printf "  ${CYAN}?${NC}   %s " "$*"; }
warn_bold(){ printf "\n${YELLOW}${BOLD}⚠ %s${NC}\n\n" "$*"; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
AUTO_MODE=false
WITH_INSTALLER=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)
                AUTO_MODE=true
                shift
                ;;
            --disk)     DISK="$2";      shift 2 ;;
            --hostname) HOSTNAME="$2";  shift 2 ;;
            --user)     USERNAME="$2";  shift 2 ;;
            --password) USERPASS="$2";  shift 2 ;;
            --timezone) TIMEZONE="$2";  shift 2 ;;
            --locale)   LOCALE="$2";    shift 2 ;;
            --kmap)     KMAP="$2";      shift 2 ;;
            --bootloader) BOOTLOADER="$2"; shift 2 ;;
            --swap)     USE_SWAP=true;  shift  ;;
            --swap-size) SWAP_SIZE="$2"; shift 2 ;;
            --wifi-ssid)    WIFI_SSID="$2";    shift 2 ;;
            --wifi-pass)    WIFI_PASS="$2";    shift 2 ;;
            --nic)    NIC="$2";     shift 2 ;;
            --with-installer) WITH_INSTALLER="$2"; shift 2 ;;
            --no-wifi)  WIFI_SSID=""; WIFI_PASS=""; shift ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                if [[ -z "$DISK" ]]; then
                    DISK="$1"
                else
                    error "Unknown argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

usage() {
    cat <<'EOF'
Usage: sudo bash arch-ricelin-install.sh [OPTIONS]

Options:
  --auto                        Non-interactive mode (all other options required)
  --disk /dev/sda               Target disk (required)
  --hostname mypc               Machine hostname (default: arch-ricelin)
  --user mo                     Username for default user (default: archuser)
  --password "***"             Password for default user (required in auto mode)
  --timezone Asia/Shanghai      System timezone (default: Asia/Shanghai)
  --locale en_US.UTF-8          System locale (default: en_US.UTF-8)
  --kmap us                     Keyboard layout (default: us)
  --bootloader grub|systemd-boot Boot loader (default: grub)
  --swap                        Enable swap partition
  --swap-size 4G                Swap partition size (default: 4G)
  --wifi-ssid NAME              WiFi SSID (for auto mode)
  --wifi-pass PASS              WiFi password (for auto mode)
  --nic eth0                    Network interface name (auto-detected if omitted)
  --with-installer /path/to/install-ricelin.sh
                                Path to the Ricelin installer script
  --no-wifi                     Skip WiFi setup (use wired)
  --help, -h                    Show this help

Examples:
  # Interactive mode — guided prompts
  sudo bash arch-ricelin-install.sh

  # Auto mode — fully non-interactive
  sudo bash arch-ricelin-install.sh --auto /dev/sda \
      --hostname mypc --user mo --password "***" \
      --timezone Asia/Shanghai --wifi-ssid "MyWiFi" --wifi-pass "secret"

  # With bundled installer
  sudo bash arch-ricelin-install.sh --with-installer install-ricelin.sh
EOF
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi

    if [[ ! -d /sys/firmware/efi ]] && [[ ! -d /sys/firmware/boot ]]; then
        warn "Not running in Arch Live environment. Some checks may fail."
    fi

    local missing=()
    local cmds=(parted sgdisk mkfs.fat mkfs.ext4 mkfs.vfat cryptsetup
        reflector pacstrap genfstab arch-chroot)
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Some tools missing: ${missing[*]}"
        warn "The live USB should have these. Continuing anyway..."
    fi

    if $AUTO_MODE; then
        if [[ -z "$DISK" ]]; then
            error "--auto requires --disk"
            exit 1
        fi
        if [[ -z "$USERPASS" ]]; then
            error "--auto requires --password"
            exit 1
        fi
    fi

    info "Pre-flight checks passed."
}

# ---------------------------------------------------------------------------
# Interactive prompt helpers
# ---------------------------------------------------------------------------
prompt() {
    local varname="$1" default="$2" prompt_text="$3"
    local input

    if $AUTO_MODE; then
        eval "input=\"\${${varname}:-$default}\""
    else
        read -rp "$prompt_text [$default] " input
        input="${input:-$default}"
    fi

    eval "$varname=\"$input\""
}

prompt_bool() {
    local varname="$1" default="$2" prompt_text="$3"
    local input

    if $AUTO_MODE; then
        eval "input=\"\${${varname}:-$default}\""
    else
        local yes_no="Y/n"
        [[ "$default" == "false" ]] && yes_no="y/N"
        read -rp "$prompt_text [$yes_no] " input
        input="${input:-$default}"
    fi

    local lower
    lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        y|yes|true|on)   eval "$varname=true" ;;
        *)               eval "$varname=false" ;;
    esac
}

# ---------------------------------------------------------------------------
# Interactive configuration wizard
# ---------------------------------------------------------------------------
wizard() {
    if $AUTO_MODE; then
        return
    fi

    section "Configuration Wizard"

    if [[ -z "$DISK" ]]; then
        echo "  Available block devices:"
        echo ""
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL -p 2>/dev/null | \
            sed 's/^/    /' || echo "    (unable to list devices)"
        echo ""
        warn_bold "THIS WILL ERASE THE ENTIRE DISK"
        ask "Target disk (e.g. /dev/sda or /dev/nvme0n1): "
        read -r DISK
        DISK="${DISK:-/dev/sda}"
    fi

    if [[ ! -b "$DISK" ]]; then
        error "Disk $DISK does not exist."
        exit 1
    fi

    prompt HOSTNAME "$HOSTNAME" "Hostname"
    prompt USERNAME "$USERNAME" "Username for default user"

    if [[ -z "$USERPASS" ]]; then
        ask "Password for '$USERNAME': "
        read -sr USERPASS
        echo ""
        ask "Confirm password: "
        read -sr USERPASS_CONFIRM
        echo ""
        if [[ "$USERPASS" != "$USERPASS_CONFIRM" ]]; then
            error "Passwords do not match."
            exit 1
        fi
    fi

    prompt TIMEZONE "$TIMEZONE" "Timezone (e.g. Asia/Shanghai)"
    prompt LOCALE "$LOCALE" "Locale (e.g. en_US.UTF-8)"
    prompt KMAP "$KMAP" "Keyboard layout (e.g. us)"

    if ! $AUTO_MODE; then
        ask "Bootloader [grub/systemd-boot] (default: grub): "
        local bl_input
        read -r bl_input
        bl_input="${bl_input:-grub}"
        case "$bl_input" in
            grub|systemd-boot) BOOTLOADER="$bl_input" ;;
            *)
                error "Unknown bootloader: $bl_input. Use 'grub' or 'systemd-boot'."
                exit 1
                ;;
        esac
    fi

    prompt_bool USE_SWAP "false" "Create a swap partition? (recommended for hibernation)"

    if [[ "$USE_SWAP" == "true" ]]; then
        prompt SWAP_SIZE "4G" "Swap size (e.g. 4G, 8G, or use --swap-size)"
    fi

    if ! $AUTO_MODE; then
        ask "Use WiFi? [y/N] "
        local wifi_input
        read -r wifi_input
        if [[ "${wifi_input,,}" == "y" || "${wifi_input,,}" == "yes" ]]; then
            ask "WiFi SSID: "
            read -r WIFI_SSID
            ask "WiFi password: "
            read -sr WIFI_PASS
            echo ""
        fi
    fi

    if [[ -z "$NIC" ]] && ! $AUTO_MODE; then
        ask "Network interface name (leave blank for auto-detect): "
        read -r NIC
    fi

    if [[ -z "$WITH_INSTALLER" ]] && [[ -f "$RICELIN_INSTALLER" ]]; then
        ask "Use bundled Ricelin installer? [Y/n] "
        local inst_input
        read -r inst_input
        if [[ "${inst_input,,}" != "n" && "${inst_input,,}" != "no" ]]; then
            WITH_INSTALLER="$RICELIN_INSTALLER"
        fi
    fi

    echo ""
    warn_bold "🚀 Summary — Review carefully!"
    echo ""
    echo "  Disk:           $DISK"
    echo "  Hostname:       $HOSTNAME"
    echo "  User:           $USERNAME"
    echo "  Timezone:       $TIMEZONE"
    echo "  Locale:         $LOCALE"
    echo "  Keyboard:       $KMAP"
    echo "  Bootloader:     $BOOTLOADER"
    echo "  Swap:           $USE_SWAP ($SWAP_SIZE)"
    [[ -n "$WIFI_SSID" ]] && echo "  WiFi:           $WIFI_SSID"
    echo ""
    warn_bold "This will erase all data on $DISK. Are you sure?"
    echo ""
    ask "Type 'YES ERASE' to continue: "
    read -r confirm
    if [[ "$confirm" != "YES ERASE" ]]; then
        info "Aborted by user."
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Network setup (pre-chroot, for package download)
# ---------------------------------------------------------------------------
setup_network() {
    section "Network — Pre-chroot connectivity"

    if $AUTO_MODE; then
        if [[ -n "$WIFI_SSID" ]]; then
            info "Connecting to WiFi: $WIFI_SSID"
            if command -v nmcli &>/dev/null; then
                nmcli -a dev wifi connect "$WIFI_SSID" password "$WIFI_PASS" 2>/dev/null || \
                    warn "WiFi connection failed, trying with wpa_supplicant..."
                wifi_connect_wpa "$WIFI_SSID" "$WIFI_PASS"
            else
                wifi_connect_wpa "$WIFI_SSID" "$WIFI_PASS"
            fi
        fi
        return
    fi

    if [[ -z "$NIC" ]]; then
        NIC=$(ip -br link | awk '$3 != "lo" && $3 != "docker0" {print $1; exit}' | tr -d '[:space:]')
    fi

    if [[ -z "$NIC" ]]; then
        warn "No network interface detected. Try: ip link"
        if command -v dhcpcd &>/dev/null; then
            info "Trying dhcpcd on all interfaces..."
            dhcpcd 2>/dev/null || warn "dhcpcd failed"
        fi
        return
    fi

    info "Using interface: $NIC"

    if command -v dhcpcd &>/dev/null; then
        info "Connecting via DHCP (dhcpcd)..."
        dhcpcd "$NIC" 2>/dev/null && { ok "Wired connection established"; return; }
    fi

    if command -v nmcli &>/dev/null; then
        info "Trying NetworkManager..."
        nmcli -a dev connect "$NIC" 2>/dev/null && { ok "NM connection established"; return; }
    fi

    if [[ -n "$WIFI_SSID" ]]; then
        info "Connecting to WiFi: $WIFI_SSID"
        wifi_connect_wpa "$WIFI_SSID" "$WIFI_PASS"
    else
        warn "Could not establish network connection."
        warn "You may need to set up networking manually before continuing."
        warn "Check: ip link, ping 8.8.8.8"
    fi
}

wifi_connect_wpa() {
    local ssid="$1" pass="$2"
    local conf="/etc/wpa_supplicant/wpa_supplicant-${NIC}.conf"

    cat > "$conf" <<EOF
ctrl_interface=/run/wpa_supplicant
update_config=1

network={
    ssid="$ssid"
    psk="$pass"
}
EOF

    wpa_supplicant -B -i "$NIC" -c "$conf" 2>/dev/null
    sleep 2
    dhcpcd "$NIC" 2>/dev/null || ip -4 addr flush dev "$NIC" 2>/dev/null
    dhcpcd "$NIC" 2>/dev/null
    ok "WiFi connected: $ssid"
}

# ---------------------------------------------------------------------------
# Step 1: Partition the disk
# ---------------------------------------------------------------------------
step_partition() {
    section "Step 1/10 — Partition the disk"

    info "Target disk: $DISK"

    local is_uefi=false
    if [[ -d /sys/firmware/efi ]]; then
        is_uefi=true
        info "UEFI detected"
    else
        info "BIOS (MBR) mode"
    fi

    info "Wiping disk signatures..."
    sgdisk --zap-all "$DISK" 2>/dev/null || true
    dd if=/dev/zero of="$DISK" bs=1M count=100 2>/dev/null || true
    partprobe "$DISK" 2>/dev/null || true
    sleep 1
    ok "Disk wiped"

    if $is_uefi; then
        info "Creating GPT partitions..."

        sgdisk -n 1:0:+512M -t 1:EF00 -c 1:"EFI" "$DISK"
        ok "EFI partition: 512M (FAT32)"

        if [[ "$USE_SWAP" == "true" ]]; then
            sgdisk -n 2:0:+"$SWAP_SIZE" -t 2:8200 -c 2:"swap" "$DISK"
            ok "Swap partition: $SWAP_SIZE"
            sgdisk -n 3:0:0 -t 3:8300 -c 3:"root" "$DISK"
        else
            sgdisk -n 2:0:0 -t 2:8300 -c 2:"root" "$DISK"
        fi
        ok "Root partition: remaining space"

        EFI_PART="${DISK}1"
        if [[ "$USE_SWAP" == "true" ]]; then
            SWAP_PART="${DISK}2"
            ROOT_PART="${DISK}3"
        else
            SWAP_PART=""
            ROOT_PART="${DISK}2"
        fi
    else
        info "Creating MBR partitions..."

        parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
        parted -s "$DISK" set 1 boot on
        ok "Boot partition: 512M (FAT32)"

        if [[ "$USE_SWAP" == "true" ]]; then
            parted -s "$DISK" mkpart primary ext4 513MiB "+${SWAP_SIZE}"
            ok "Root partition: up to swap"
            parted -s "$DISK" mkpart primary linux-swap "+${SWAP_SIZE}" 100%
            ok "Swap partition: $SWAP_SIZE"
            EFI_PART=""
            ROOT_PART="${DISK}1"
            SWAP_PART="${DISK}3"
        else
            parted -s "$DISK" mkpart primary ext4 513MiB 100%
            ok "Root partition: remaining space"
            EFI_PART=""
            ROOT_PART="${DISK}1"
            SWAP_PART=""
        fi
    fi

    ok "Partitioning complete"
}

# ---------------------------------------------------------------------------
# Step 2: Format partitions
# ---------------------------------------------------------------------------
step_format() {
    section "Step 2/10 — Format partitions"

    if [[ -n "$EFI_PART" ]]; then
        mkfs.fat -F 32 "$EFI_PART" 2>&1 | tail -1
        ok "EFI: FAT32 ($EFI_PART)"
    fi

    mkfs.ext4 "$ROOT_PART" 2>&1 | tail -1
    ok "Root: ext4 ($ROOT_PART)"

    if [[ -n "$SWAP_PART" ]]; then
        mkswap -L swap "$SWAP_PART" 2>&1 | tail -1
        ok "Swap: $SWAP_SIZE ($SWAP_PART)"
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Mount partitions
# ---------------------------------------------------------------------------
step_mount() {
    section "Step 3/10 — Mount partitions"

    mount "$ROOT_PART" "$MNT_BASE"
    ok "Root mounted: $ROOT_PART → $MNT_BASE"

    mkdir -p "$MNT_BOOT" "$MNT_EFI" "$MNT_HOME"

    if [[ -n "$EFI_PART" ]]; then
        mount "$EFI_PART" "$MNT_EFI"
        ok "EFI mounted: $EFI_PART → $MNT_EFI"
    fi

    if [[ "$USE_SWAP" == "true" ]]; then
        swapon "$SWAP_PART"
        ok "Swap activated: $SWAP_PART"
    fi

    mkdir -p "$MNT_HOME"
}

# ---------------------------------------------------------------------------
# Step 4: Install base system
# ---------------------------------------------------------------------------
step_pacstrap() {
    section "Step 4/10 — Install base system"

    info "Running pacstrap..."

    pacstrap "$MNT_BASE" base linux linux-firmware \
        bash-completion reflector sudo vim nano \
        2>&1 | tail -3

    ok "Base system installed"
}

# ---------------------------------------------------------------------------
# Step 5: Generate fstab
# ---------------------------------------------------------------------------
step_fstab() {
    section "Step 5/10 — Generate fstab"

    genfstab -U "$MNT_BASE" > "$MNT_BASE/etc/fstab"
    info "Generated fstab:"
    cat "$MNT_BASE/etc/fstab" | sed 's/^/  /'
    ok "fstab written"
}

# ---------------------------------------------------------------------------
# Step 6: Chroot and configure the new system
# ---------------------------------------------------------------------------
step_chroot_config() {
    section "Step 6/10 — Chroot configuration"

    info "Configuring pacman mirror..."
    cat > "$MNT_BASE/etc/pacman.d/mirrorlist" <<EOF
Server = $MIRROR
EOF

    info "Configuring locale: $LOCALE"
    sed -i "s/^#\s*${LOCALE}/${LOCALE}/" "$MNT_BASE/etc/locale.gen"
    arch-chroot "$MNT_BASE" locale-gen 2>&1 | tail -1
    echo "LANG=$LOCALE" > "$MNT_BASE/etc/locale.conf"
    ok "Locale: $LOCALE"

    info "Setting timezone: $TIMEZONE"
    arch-chroot "$MNT_BASE" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    arch-chroot "$MNT_BASE" hwclock --systohc
    ok "Timezone: $TIMEZONE"

    info "Setting hostname: $HOSTNAME"
    echo "$HOSTNAME" > "$MNT_BASE/etc/hostname"
    cat > "$MNT_BASE/etc/hosts" <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	$HOSTNAME.localdomain	$HOSTNAME
EOF
    ok "Hostname: $HOSTNAME"

    info "Setting keyboard layout: $KMAP"
    echo "KEYMAP=$KMAP" > "$MNT_BASE/etc/vconsole.conf"
    ok "Keyboard: $KMAP"

    info "Setting root password..."
    echo "root:$USERPASS" | arch-chroot "$MNT_BASE" chpasswd 2>/dev/null
    ok "Root password set"

    info "Creating user: $USERNAME"
    arch-chroot "$MNT_BASE" useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$USERPASS" | arch-chroot "$MNT_BASE" chpasswd 2>/dev/null
    arch-chroot "$MNT_BASE" groupadd wheel 2>/dev/null || true
    arch-chroot "$MNT_BASE" usermod -aG wheel "$USERNAME"
    sed -i "s/^#\s*%wheel\s*ALL=(ALL)\s*ALL/%wheel ALL=(ALL) ALL/" \
        "$MNT_BASE/etc/sudoers" 2>/dev/null || true
    ok "User '$USERNAME' created (with sudo)"
}

# ---------------------------------------------------------------------------
# Step 7: Install bootloader
# ---------------------------------------------------------------------------
step_bootloader() {
    section "Step 7/10 — Install bootloader ($BOOTLOADER)"

    if [[ "$BOOTLOADER" == "grub" ]]; then
        install_grub
    elif [[ "$BOOTLOADER" == "systemd-boot" ]]; then
        install_systemd_boot
    else
        error "Unknown bootloader: $BOOTLOADER"
        exit 1
    fi
}

install_grub() {
    info "Installing GRUB..."
    arch-chroot "$MNT_BASE" pacman -S --noconfirm --needed grub efibootmgr os-prober 2>&1 | tail -1

    if [[ -d /sys/firmware/efi ]]; then
        arch-chroot "$MNT_BASE" grub-install --target=x86_64-efi \
            --efi-directory="$MNT_EFI" \
            --bootloader-id=ARCH \
            --recheck 2>&1 | tail -1
    else
        arch-chroot "$MNT_BASE" grub-install --target=i386-pc "$DISK" 2>&1 | tail -1
    fi

    arch-chroot "$MNT_BASE" grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -2
    ok "GRUB installed"
}

install_systemd_boot() {
    info "Installing systemd-boot..."
    arch-chroot "$MNT_BASE" pacman -S --noconfirm --needed systemd-boot 2>&1 | tail -1

    bootctl install --path="$MNT_EFI" 2>&1 | tail -1

    mkdir -p "$MNT_EFI/loader/entries"
    local uuid
    uuid=$(blkid -s UUID -o value "$ROOT_PART")
    cat > "$MNT_EFI/loader/entries/arch.conf" <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux
options root=UUID=$uuid rw
EOF

    cat > "$MNT_EFI/loader/loader.conf" <<EOF
default arch.conf
timeout 5
EOF

    ok "systemd-boot installed"
}

# ---------------------------------------------------------------------------
# Step 8: Post-chroot setup
# ---------------------------------------------------------------------------
step_post_chroot() {
    section "Step 8/10 — Post-chroot setup"

    info "Enabling services..."
    arch-chroot "$MNT_BASE" systemctl enable NetworkManager 2>/dev/null
    arch-chroot "$MNT_BASE" systemctl enable reflector.service 2>/dev/null || true
    ok "Services enabled"

    if [[ -n "$WIFI_SSID" ]]; then
        info "Configuring WiFi: $WIFI_SSID"
        arch-chroot "$MNT_BASE" pacman -S --noconfirm --needed networkmanager 2>&1 | tail -1
        arch-chroot "$MNT_BASE" nmcli -n dev wifi connect "$WIFI_SSID" password "$WIFI_PASS" 2>&1 || true
        ok "WiFi configured: $WIFI_SSID"
    fi

    if [[ -n "$WITH_INSTALLER" ]]; then
        info "Copying Ricelin installer..."
        cp "$WITH_INSTALLER" "$MNT_BASE/root/install-ricelin.sh"
        chmod +x "$MNT_BASE/root/install-ricelin.sh"
        ok "Ricelin installer copied to /root/install-ricelin.sh"
    fi

    cp "${BASH_SOURCE[0]}" "$MNT_BASE/root/arch-ricelin-install.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Step 9: Unmount and reboot
# ---------------------------------------------------------------------------
step_unmount() {
    section "Step 9/10 — Unmount and prepare for reboot"

    info "Syncing filesystems..."
    sync

    info "Unmounting partitions..."
    umount -R "$MNT_BASE" 2>/dev/null || true
    ok "All partitions unmounted"

    if [[ "$USE_SWAP" == "true" ]]; then
        swapoff "$SWAP_PART" 2>/dev/null || true
    fi

    info "System installed. Remove the Live USB and reboot."
}

# ---------------------------------------------------------------------------
# Step 10: Post-reboot instructions
# ---------------------------------------------------------------------------
step_post_reboot() {
    section "Step 10/10 — Next steps"

    echo ""
    echo "  ${BOLD}🎉 Arch Linux is installed!${NC}"
    echo ""
    echo "  ${BOLD}What's installed:${NC}"
    echo "  • Base Arch Linux system"
    echo "  • Bootloader: $BOOTLOADER"
    echo "  • User: $USERNAME"
    echo "  • Hostname: $HOSTNAME"
    echo "  • Timezone: $TIMEZONE"
    echo ""
    echo "  ${BOLD}Next steps:${NC}"
    echo ""
    echo "  1. Reboot:"
    echo "     ${CYAN}reboot${NC}"
    echo ""
    echo "  2. Log in as '$USERNAME' and run:"
    echo "     ${CYAN}sudo bash /root/install-ricelin.sh${NC}"
    echo ""
    echo "     This installs the full Ricelin Hyprland desktop:"
    echo "     • Hyprland (Wayland compositor)"
    echo "     • Quickshell (custom pill bar)"
    echo "     • Ghostty (terminal)"
    echo "     • Fish (shell)"
    echo "     • Brave browser"
    echo "     • Dolphin, Zathura, rishot, and more"
    echo ""
    echo "  ${BOLD}Alternatively, clone and run manually:${NC}"
    echo "     ${CYAN}git clone $RICELIN_REPO ~/.local/share/ricelin${NC}"
    echo "     ${CYAN}cd ~/.local/share/ricelin${NC}"
    echo "     ${CYAN}bash install.sh${NC}"
    echo ""
    echo "  ${BOLD}If you don't have the installer file:${NC}"
    echo "     ${CYAN}curl -fsSL https://raw.githubusercontent.com/Gakuseei/Ricelin/main/install.sh | bash${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo ""
    echo "  ${BOLD}╔═══════════════════════════════════════════════╗${NC}"
    echo "  ${BOLD}║   Arch Linux + Ricelin Desktop — Fresh Install${NC}"
    echo "  ${BOLD}║   Live USB → Full Desktop in one script       ║${NC}"
    echo "  ${BOLD}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    preflight
    wizard
    setup_network
    step_partition
    step_format
    step_mount
    step_pacstrap
    step_fstab
    step_chroot_config
    step_bootloader
    step_post_chroot
    step_unmount
    step_post_reboot
}

main "$@"
