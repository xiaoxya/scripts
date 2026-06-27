#!/usr/bin/env bash
# ============================================================================
# Ricelin — Arch Linux Hyprland Desktop Installer
# ============================================================================
# Installs the complete Ricelin Hyprland desktop environment on Arch Linux.
#
# Stack:
#   WM       : Hyprland (Lua config)
#   Shell UI : Quickshell (custom pill bar)
#   Terminal : Ghostty
#   Shell    : Fish
#   Font     : JetBrains Mono Nerd + Inter + Noto CJK
#   Colors   : Matugen (wallpaper-derived palette)
#
# Usage:
#   chmod +x install-ricelin.sh
#   sudo ./install-ricelin.sh
#
# Requires: root privileges, internet connection, x86_64 Arch Linux (base + base-devel)
# ============================================================================

set -euo pipefail
shopt -s globstar

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
RICELIN_REPO="https://github.com/Gakuseei/Ricelin"
RICELIN_DIR="$HOME/.local/share/ricelin"
CONFIG_DIR="$HOME/.config"
BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S).bak"

# ---------------------------------------------------------------------------
# Colors & logging
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
section() { printf "\n${BOLD}${CYAN}▶ %s${NC}\n" "$*"; }
ok()      { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
fail()    { printf "  ${RED}✗${NC} %s\n" "$*"; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight() {
    # Must be root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi

    # Must be Arch Linux
    if [[ ! -f /etc/arch-release ]]; then
        error "This script is for Arch Linux only."
        exit 1
    fi

    # Must be a graphical environment (or at least have a TTY available)
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        warn "No display detected. Ensure you can start a TTY for Hyprland later."
    fi

    info "Arch Linux detected. Proceeding..."
}

# ---------------------------------------------------------------------------
# Step 0: Bootstrap — install base-devel and git (needed for AUR)
# ---------------------------------------------------------------------------
step_bootstrap() {
    section "Step 0/8 — Bootstrap (base-devel, git, etc.)"

    pacman -S --needed --noconfirm \
        base-devel git sudo reflector wget unzip 7zip \
        linux-headers linux-firmware \
        2>&1 | tail -1
    ok "Base packages installed"
}

# ---------------------------------------------------------------------------
# Step 1: Enable multilib (needed for 32-bit libs / some AUR packages)
# ---------------------------------------------------------------------------
step_multilib() {
    section "Step 1/8 — Enable multilib repository"

    if grep -q "^\[multilib\]" /etc/pacman.conf; then
        ok "multilib already enabled"
    else
        sed -i '/^\[#multilib\]/s/^#//' /etc/pacman.conf
        pacman -Sy --noconfirm 2>&1 | tail -1
        ok "multilib enabled"
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Install yay (AUR helper)
# ---------------------------------------------------------------------------
step_yay() {
    section "Step 2/8 — Install yay (AUR helper)"

    if command -v yay &>/dev/null; then
        ok "yay already installed ($(yay --version | head -1))"
        return
    fi

    info "Building yay from AUR..."
    local build_dir
    build_dir="$(mktemp -d)"
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$build_dir"
    (cd "$build_dir" && makepkg -si --noconfirm 2>&1) | tail -3
    rm -rf "$build_dir"
    ok "yay installed ($(yay --version | head -1))"
}

# ---------------------------------------------------------------------------
# Step 3: Install all core packages
# ---------------------------------------------------------------------------
step_core_packages() {
    section "Step 3/8 — Install core packages"

    # Core native packages (official repos)
    local core_pkgs=(
        hyprland
        quickshell
        matugen
        swww
        hyprpicker
        hyprpolkitagent
        hypridle
        cava
        ghostty
        fish
        zoxide
        cliphist
        wl-clipboard
        imagemagick
        jq
        brightnessctl
        playerctl
        networkmanager
        bluez
        pipewire
        wireplumber
        pamixer
        kde-cli-tools
        kdialog
        fastfetch
        ttf-jetbrains-mono-nerd
        inter-font
        noto-fonts
        noto-fonts-cjk
        noto-fonts-emoji
        papirus-icon-theme
        grim
        slurp
    )

    # AUR packages (need yay)
    local aur_pkgs=(
        dotool
        bibata-cursor-theme-bin
    )

    info "Installing ${#core_pkgs[@]} official repo packages..."
    sudo pacman -S --needed --noconfirm "${core_pkgs[@]}" 2>&1 | tail -1
    ok "Core repo packages installed"

    info "Installing ${#aur_pkgs[@]} AUR packages..."
    yay -S --needed --noconfirm "${aur_pkgs[@]}" 2>&1 | tail -3
    ok "AUR packages installed"
}

# ---------------------------------------------------------------------------
# Step 4: Install full-profile apps
# ---------------------------------------------------------------------------
step_full_packages() {
    section "Step 4/8 — Install full-profile apps"

    local full_pkgs=(
        dolphin
        keepassxc
        zathura
        zathura-pdf-mupdf
        imv
    )

    info "Installing ${#full_pkgs[@]} full-profile packages..."
    sudo pacman -S --needed --noconfirm "${full_pkgs[@]}" 2>&1 | tail -1
    ok "Full-profile packages installed"

    # rnote — available via AUR on Arch
    if yay -Fq rnote &>/dev/null; then
        info "Installing rnote from AUR..."
        yay -S --needed --noconfirm rnote 2>&1 | tail -1
        ok "rnote installed"
    else
        warn "rnote not found in AUR; skipping (install manually: yay -S rnote)"
    fi
}

# ---------------------------------------------------------------------------
# Step 5: Install Brave browser
# ---------------------------------------------------------------------------
step_brave() {
    section "Step 5/8 — Install Brave browser"

    if pacman -Qq brave-bin &>/dev/null; then
        ok "Brave already installed"
        return
    fi

    info "Installing Brave from AUR..."
    yay -S --needed --noconfirm brave-bin 2>&1 | tail -3
    ok "Brave installed"
}

# ---------------------------------------------------------------------------
# Step 6: Install rishot (screenshot tool)
# ---------------------------------------------------------------------------
step_rishot() {
    section "Step 6/8 — Install rishot (screenshot tool)"

    if command -v rishot &>/dev/null; then
        ok "rishot already installed"
        return
    fi

    info "Installing rishot..."
    curl -fsSL https://raw.githubusercontent.com/Gakuseei/rishot/main/install.sh | sh
    ok "rishot installed"
}

# ---------------------------------------------------------------------------
# Step 7: Install gpu-screen-recorder (Flatpak)
# ---------------------------------------------------------------------------
step_gpu_screen_recorder() {
    section "Step 7/8 — Install gpu-screen-recorder (Flatpak)"

    if flatpak list 2>/dev/null | grep -q gpu_screen_recorder; then
        ok "gpu-screen-recorder already installed"
        return
    fi

    info "Installing Flatpak runtime..."
    sudo pacman -S --needed --noconfirm flatpak 2>&1 | tail -1

    flatpak --user remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

    info "Installing gpu-screen-recorder from Flathub..."
    flatpak --user install -y flathub com.dec05eba.gpu_screen_recorder 2>&1 | tail -3
    ok "gpu-screen-recorder installed"
}

# ---------------------------------------------------------------------------
# Step 8: Clone and deploy Ricelin configs
# ---------------------------------------------------------------------------
step_deploy_configs() {
    section "Step 8/8 — Deploy Ricelin configuration"

    # Clone the repo
    if [[ -d "$RICELIN_DIR/.git" ]]; then
        info "Ricelin repo already cloned at $RICELIN_DIR — pulling latest..."
        (cd "$RICELIN_DIR" && git pull --ff-only)
    else
        info "Cloning Ricelin into $RICELIN_DIR..."
        git clone "$RICELIN_REPO" "$RICELIN_DIR" 2>&1 | tail -1
    fi
    ok "Ricelin repo cloned"

    local config_src="$RICELIN_DIR/configs"

    if [[ ! -d "$config_src" ]]; then
        error "Config directory not found at $config_src"
        exit 1
    fi

    # Back up existing configs that will be overwritten
    local configs_to_deploy=(
        "hypr"
        "fastfetch"
        "fish"
        "ghostty"
        "brave-theme"
    )

    for cfg in "${configs_to_deploy[@]}"; do
        local dest="$CONFIG_DIR/$cfg"
        if [[ -d "$dest" ]]; then
            info "Backing up $dest → ${dest}${BACKUP_SUFFIX}"
            mv "$dest" "${dest}${BACKUP_SUFFIX}"
        fi
    done

    # Deploy configs
    for cfg in "${configs_to_deploy[@]}"; do
        local src="$config_src/$cfg"
        local dest="$CONFIG_DIR/$cfg"
        if [[ -d "$src" ]]; then
            mkdir -p "$dest"
            cp -r "$src"/. "$dest"/ 2>/dev/null || true
            ok "Deployed $cfg → $dest"
        else
            warn "No config for $cfg — skipping"
        fi
    done

    # Deploy GRUB theme (optional, only if GRUB exists)
    local grub_theme_src="$config_src/grub/themes/torii"
    if [[ -d "$grub_theme_src" ]]; then
        if [[ -d /boot/grub/themes ]]; then
            local grub_theme_dest="/boot/grub/themes/torii"
            mkdir -p "$grub_theme_dest"
            cp -r "$grub_theme_src"/. "$grub_theme_dest"/ 2>/dev/null || true
            ok "GRUB torii theme deployed to $grub_theme_dest"
        else
            warn "No /boot/grub/themes found — skipping GRUB theme"
        fi
    fi

    # Deploy GRUB install script (optional, user runs manually)
    local grub_install="$config_src/grub/install-torii.sh"
    if [[ -f "$grub_install" ]]; then
        local target_bin="$HOME/.local/bin/install-torii.sh"
        mkdir -p "$HOME/.local/bin"
        cp "$grub_install" "$target_bin"
        chmod +x "$target_bin"
        info "GRUB theme installer copied to $target_bin (run with sudo to apply)"
    fi

    # Deploy Brave theme (copy to ~/.config/ricelin for Brave to load)
    local brave_theme_src="$config_src/brave-theme"
    if [[ -d "$brave_theme_src" ]]; then
        local brave_theme_dest="$HOME/.config/ricelin/brave-theme"
        mkdir -p "$HOME/.config/ricelin"
        cp -r "$brave_theme_src"/. "$brave_theme_dest"/ 2>/dev/null || true
        ok "Brave theme deployed to $brave_theme_dest"
    fi

    # Seed starter wallpapers
    local wp_dir="$HOME/Ricelin/wallpapers"
    local starter_dir="$RICELIN_DIR/installer/starter-wallpapers"
    mkdir -p "$wp_dir"
    if [[ -d "$starter_dir" ]] && [[ -z "$(ls -A "$wp_dir" 2>/dev/null)" ]]; then
        cp "$starter_dir"/* "$wp_dir"/ 2>/dev/null || true
        ok "Starter wallpapers seeded to $wp_dir"
    elif [[ -d "$starter_dir" ]]; then
        ok "Wallpapers already present"
    else
        warn "No starter wallpapers found — download from https://github.com/Gakuseei/Ricelin"
    fi

    # Create wallpapers/downloads directory
    mkdir -p "$wp_dir/downloads"
    mkdir -p "$HOME/.cache/ricelin"

    # Bridge awww → swww (Ricelin scripts call awww, but package is swww)
    if ! command -v awww &>/dev/null && command -v swww &>/dev/null; then
        local bin_dir="$HOME/.local/bin"
        mkdir -p "$bin_dir"
        ln -sf "$(command -v swww)" "$bin_dir/awww"
        if command -v swww-daemon &>/dev/null; then
            ln -sf "$(command -v swww-daemon)" "$bin_dir/awww-daemon"
        fi
        ok "Bridged awww → swww in $bin_dir"
    fi

    # Deploy ImageMagick policy (allow PNG for wallpaper processing)
    local magick_policy_src="$config_src/hypr/scripts/magick-policy/policy.xml"
    if [[ -f "$magick_policy_src" ]]; then
        local magick_policy="/etc/ImageMagick-6/policy.xml"
        if [[ -f "$magick_policy" ]]; then
            # Backup and patch: allow PNG/PNG16/PNG8
            cp "$magick_policy" "${magick_policy}.bak"
            if ! grep -q 'PNG' "$magick_policy" 2>/dev/null || \
               grep -q 'right="NONE"' "$magick_policy" 2>/dev/null; then
                sed -i 's/<policy domain="coder" rights="none" pattern="PNG" \/>/<policy domain="coder" rights="read|write" pattern="PNG" \/>/g' \
                    "$magick_policy"
                ok "ImageMagick PNG policy unlocked"
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 9: System configuration
# ---------------------------------------------------------------------------
step_system_config() {
    section "Step 9/9 — System configuration"

    # Set fish as default login shell
    if ! grep -q "^$(whoami):.*fish$" /etc/shells; then
        echo "$(which fish)" | sudo tee -a /etc/shells >/dev/null
    fi
    chsh -s "$(which fish)"
    ok "Default shell set to fish"

    # Enable and start NetworkManager
    sudo systemctl enable --now NetworkManager
    ok "NetworkManager enabled and started"

    # Enable and start bluetooth
    sudo systemctl enable --now bluetooth
    ok "Bluetooth enabled and started"

    # Enable and start pipewire services
    systemctl --user enable --now pipewire pipewire-pulse wireplumber
    ok "PipeWire + WirePlumber enabled"

    # Enable and start hypridle
    systemctl --user enable --now hypridle
    ok "hypridle enabled"

    # Create uinput module config (needed for dotool)
    if ! lsmod | grep -q uinput; then
        echo "uinput" | sudo tee /etc/modules-load.d/uinput.conf >/dev/null
        sudo modprobe uinput
        ok "uinput kernel module loaded"
    fi

    # Create udev rule for uinput (dotool needs /dev/uinput)
    if [[ ! -f /etc/udev/rules.d/99-uinput.rules ]]; then
        cat | sudo tee /etc/udev/rules.d/99-uinput.rules > /dev/null <<'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
EOF
        sudo groupadd -f input
        sudo usermod -aG input "$(whoami)"
        sudo udevadm control --reload
        sudo udevadm trigger
        ok "uinput udev rule installed"
    fi

    # Configure reflector for faster mirrors
    sudo reflector --latest 50 --age 12 --protocol https --sort rate \
        --save /etc/pacman.d/mirrorlist 2>/dev/null || true
    ok "Mirror list updated (reflector)"

    # Create alias in fish config for ricelin update
    local fish_config="$HOME/.config/fish/config.fish"
    if [[ -f "$fish_config" ]]; then
        if ! grep -q "ricelin-update" "$fish_config"; then
            cat >> "$fish_config" <<'FISH'

# Ricelin update helper
function ricelin-update
    cd ~/.local/share/ricelin && git pull --ff-only
    cd ~/.local/share/ricelin/installer && python3 ricelin_install.py
end
FISH
            ok "Added ricelin-update alias to fish config"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Post-install summary
# ---------------------------------------------------------------------------
post_install_summary() {
    section "🎉 Installation Complete!"
    echo ""
    echo "  ${BOLD}Next steps:${NC}"
    echo ""
    echo "  1. Log out and start Hyprland from TTY:"
    echo "     ${CYAN}Hyprland${NC}"
    echo ""
    echo "  2. Or set a display manager (optional):"
    echo "     ${YELLOW}sudopacman -S sddm sddm-git qt5-graphicaleffects qt5-quickcontrols2 qt5-svg${NC}"
    echo "     ${YELLOW}sudo systemctl enable sddm${NC}"
    echo ""
    echo "  3. Pick a wallpaper: ${CYAN}Super + C${NC}"
    echo "  4. Shuffle & retheme: ${CYAN}Super + B${NC}"
    echo "  5. Open terminal:     ${CYAN}Super + Enter${NC}"
    echo "  6. App launcher:      ${CYAN}Super + Space${NC}"
    echo ""
    echo "  ${BOLD}Keybinds:${NC}"
    echo "  Super+Return  → Terminal (Ghostty)"
    echo "  Super+Space   → App launcher"
    echo "  Super+V       → Clipboard history"
    echo "  Super+C       → Wallpaper picker"
    echo "  Super+B       → Shuffle wallpaper + retheme"
    echo "  Super+E       → File manager (Dolphin)"
    echo "  Super+T       → Toggle floating"
    echo "  Super+L       → Lock screen"
    echo "  Print         → Screenshot (rishot)"
    echo ""
    echo "  ${BOLD}Brave theme setup (optional):${NC}"
    echo "  1. Open Brave"
    echo "  2. Go to brave://settings/appearance"
    echo "  3. Click 'Load theme from disk'"
    echo "  4. Select: ${CYAN}~/.config/ricelin/brave-theme${NC}"
    echo ""
    echo "  ${BOLD}Update your setup:${NC}"
    echo "  ${CYAN}ricelin-update${NC}"
    echo ""
    echo "  ${BOLD}Configs are at:${NC} ${CYAN}~/.config/${NC}"
    echo "  ${BOLD}Ricelin repo:${NC}   ${CYAN}~/.local/share/ricelin${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "  ${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo "  ${BOLD}║   Ricelin — Arch Linux Desktop Installer  ║${NC}"
    echo "  ${BOLD}║   Hyprland + Quickshell + Ghostty         ║${NC}"
    echo "  ${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo ""

    preflight
    step_bootstrap
    step_multilib
    step_yay
    step_core_packages
    step_full_packages
    step_brave
    step_rishot
    step_gpu_screen_recorder
    step_deploy_configs
    step_system_config
    post_install_summary
}

main "$@"
