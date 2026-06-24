#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
ASSUME_YES=0
DISTRO_ID=""
DISTRO_LIKE=""
DISTRO_NAME=""
PKG_FAMILY=""
PKG_MANAGER=""
CURRENT_USER="${SUDO_USER:-${USER:-}}"
CURRENT_HOME=""

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Linux development machine initializer

Usage:
  ./linux-init.sh [options]

Options:
  --dry-run      Print actions without changing the system
  --yes, -y      Assume yes for confirmation prompts
  --help, -h     Show this help

The default mode is an interactive menu. Supported distro families:
  - Debian/Ubuntu
  - RHEL/Rocky/Alma/CentOS/Fedora
  - Arch/Manjaro
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --yes|-y)
        ASSUME_YES=1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] %s\n' "$*"
    return 0
  fi
  "$@"
}

run_shell() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] %s\n' "$*"
    return 0
  fi
  bash -c "$*"
}

run_as_target_user_shell() {
  local command="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] as %s: %s\n' "$CURRENT_USER" "$command"
    return 0
  fi
  if [[ "$(id -u)" -ne 0 && "${USER:-}" == "$CURRENT_USER" ]]; then
    HOME="$CURRENT_HOME" bash -lc "$command"
  elif [[ "$CURRENT_USER" == "root" ]]; then
    HOME="$CURRENT_HOME" bash -lc "$command"
  else
    sudo -u "$CURRENT_USER" HOME="$CURRENT_HOME" bash -lc "$command"
  fi
}

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log "$prompt: yes"
    return 0
  fi
  local answer
  read -r -p "$prompt [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

init_user_context() {
  if [[ -z "$CURRENT_USER" || "$CURRENT_USER" == "root" ]]; then
    CURRENT_USER="root"
    CURRENT_HOME="/root"
    return
  fi
  CURRENT_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6 || true)"
  [[ -n "$CURRENT_HOME" ]] || CURRENT_HOME="$HOME"
}

sudo_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_sudo() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] sudo %s\n' "$*"
    return 0
  fi
  sudo_cmd "$@"
}

require_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    return 0
  fi
  need_cmd sudo || die "sudo is required for system changes"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    sudo -v || die "sudo authentication failed"
  fi
}

detect_distro() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found; unsupported Linux distribution"
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_LIKE="${ID_LIKE:-}"
  DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"

  case "$DISTRO_ID $DISTRO_LIKE" in
    *debian*|*ubuntu*)
      PKG_FAMILY="debian"
      PKG_MANAGER="apt-get"
      ;;
    *rhel*|*fedora*|*centos*|*rocky*|*alma*)
      PKG_FAMILY="rhel"
      if need_cmd dnf; then
        PKG_MANAGER="dnf"
      elif need_cmd yum; then
        PKG_MANAGER="yum"
      else
        die "dnf/yum not found on RHEL-like system"
      fi
      ;;
    *arch*|*manjaro*)
      PKG_FAMILY="arch"
      PKG_MANAGER="pacman"
      ;;
    *)
      PKG_FAMILY="unsupported"
      PKG_MANAGER=""
      ;;
  esac
}

show_system_info() {
  log "Distribution: $DISTRO_NAME"
  log "Package family: $PKG_FAMILY"
  if [[ -n "$PKG_MANAGER" ]]; then
    log "Package manager: $PKG_MANAGER"
  fi
  log "Target user: $CURRENT_USER"
  log "Target home: $CURRENT_HOME"
}

ensure_supported() {
  [[ "$PKG_FAMILY" != "unsupported" ]] || die "Unsupported distro: $DISTRO_NAME"
}

is_installed() {
  local pkg="$1"
  case "$PKG_FAMILY" in
    debian) dpkg -s "$pkg" >/dev/null 2>&1 ;;
    rhel) rpm -q "$pkg" >/dev/null 2>&1 ;;
    arch) pacman -Q "$pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

pkg_update() {
  ensure_supported
  case "$PKG_FAMILY" in
    debian)
      run_sudo apt-get update
      ;;
    rhel)
      run_sudo "$PKG_MANAGER" makecache
      ;;
    arch)
      run_sudo pacman -Sy --noconfirm
      ;;
  esac
}

install_packages() {
  ensure_supported
  local packages=("$@")
  local missing=()
  local pkg

  for pkg in "${packages[@]}"; do
    if ! is_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "All requested packages are already installed"
    return 0
  fi

  log "Installing packages: ${missing[*]}"
  case "$PKG_FAMILY" in
    debian)
      run_sudo apt-get install -y "${missing[@]}"
      ;;
    rhel)
      run_sudo "$PKG_MANAGER" install -y "${missing[@]}"
      ;;
    arch)
      run_sudo pacman -S --needed --noconfirm "${missing[@]}"
      ;;
  esac
}

install_group_development_tools() {
  case "$PKG_FAMILY" in
    rhel)
      log "Installing Development Tools group"
      if [[ "$PKG_MANAGER" == "dnf" ]]; then
        run_sudo dnf groupinstall -y "Development Tools"
      else
        run_sudo yum groupinstall -y "Development Tools"
      fi
      ;;
    *)
      return 0
      ;;
  esac
}

base_packages() {
  case "$PKG_FAMILY" in
    debian)
      printf '%s\n' git curl wget vim zsh tmux unzip jq tree ca-certificates gnupg lsb-release build-essential python3 python3-pip golang
      ;;
    rhel)
      printf '%s\n' git curl wget vim zsh tmux unzip jq tree ca-certificates gnupg2 python3 python3-pip golang
      ;;
    arch)
      printf '%s\n' git curl wget vim zsh tmux unzip jq tree ca-certificates gnupg base-devel python python-pip go
      ;;
  esac
}

module_system_update() {
  log "Updating package metadata"
  require_sudo
  pkg_update
}

module_base_tools() {
  log "Installing base development tools"
  require_sudo
  mapfile -t packages < <(base_packages)
  install_packages "${packages[@]}"
  install_group_development_tools
}

install_nvm() {
  local nvm_dir="$CURRENT_HOME/.nvm"
  if [[ -s "$nvm_dir/nvm.sh" ]]; then
    log "nvm is already installed"
  else
    log "Installing nvm for $CURRENT_USER"
    run_as_target_user_shell 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
  fi

  log "Installing Node.js LTS via nvm"
  local nvm_command="export NVM_DIR=\"$nvm_dir\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm install --lts; nvm alias default lts/*"
  run_as_target_user_shell "$nvm_command"
}

module_node() {
  log "Installing Node.js LTS"
  need_cmd curl || install_packages curl ca-certificates
  install_nvm
}

module_python_go() {
  log "Installing Python and Go toolchains"
  require_sudo
  case "$PKG_FAMILY" in
    debian) install_packages python3 python3-pip golang ;;
    rhel) install_packages python3 python3-pip golang ;;
    arch) install_packages python python-pip go ;;
  esac
}

install_docker_debian() {
  install_packages ca-certificates curl gnupg
  run_sudo install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    run_shell "curl -fsSL https://download.docker.com/linux/${DISTRO_ID}/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    run_sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    local codename
    codename="$(
      . /etc/os-release
      printf '%s' "${VERSION_CODENAME:-}"
    )"
    [[ -n "$codename" ]] || codename="$(lsb_release -cs)"
    run_shell "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} ${codename} stable\" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null"
  fi
  pkg_update
  install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rhel() {
  install_packages ca-certificates curl
  if ! need_cmd "$PKG_MANAGER"; then
    die "$PKG_MANAGER is required"
  fi
  local repo_url="https://download.docker.com/linux/centos/docker-ce.repo"
  if [[ "$DISTRO_ID" == "fedora" ]]; then
    repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"
  fi
  if [[ "$PKG_MANAGER" == "dnf" ]]; then
    install_packages dnf-plugins-core || true
    run_sudo dnf config-manager --add-repo "$repo_url"
  else
    install_packages yum-utils || true
    run_sudo yum-config-manager --add-repo "$repo_url"
  fi
  install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_arch() {
  install_packages docker docker-compose
}

module_docker() {
  log "Installing Docker"
  require_sudo
  if need_cmd docker; then
    log "Docker command already exists"
  else
    case "$PKG_FAMILY" in
      debian) install_docker_debian || { warn "Docker official repo failed; trying distro package"; install_packages docker.io docker-compose-plugin; } ;;
      rhel) install_docker_rhel || { warn "Docker official repo failed; trying distro package"; install_packages docker; } ;;
      arch) install_docker_arch ;;
    esac
  fi

  if need_cmd systemctl || [[ "$DRY_RUN" -eq 1 ]]; then
    if confirm "Enable and start Docker service"; then
      run_sudo systemctl enable --now docker
    fi
  fi

  if [[ "$CURRENT_USER" != "root" ]] && confirm "Add $CURRENT_USER to docker group"; then
    run_sudo usermod -aG docker "$CURRENT_USER"
    warn "Log out and back in for docker group membership to take effect"
  fi
}

backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
  log "Backing up $file to $backup"
  run cp "$file" "$backup"
  if [[ "$DRY_RUN" -eq 0 && "$(id -u)" -eq 0 && "$CURRENT_USER" != "root" ]]; then
    chown "$CURRENT_USER:$CURRENT_USER" "$backup" 2>/dev/null || true
  fi
}

append_if_missing() {
  local file="$1"
  local marker="$2"
  local content="$3"
  if [[ -f "$file" ]] && grep -Fq "$marker" "$file"; then
    log "$file already contains $marker"
    return 0
  fi
  backup_file "$file"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] append %s to %s\n' "$marker" "$file"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  {
    printf '\n%s\n' "$marker"
    printf '%s\n' "$content"
  } >> "$file"
  if [[ "$(id -u)" -eq 0 && "$CURRENT_USER" != "root" ]]; then
    chown "$CURRENT_USER:$CURRENT_USER" "$file" 2>/dev/null || true
  fi
}

module_shell_git() {
  log "Configuring shell and Git gently"
  local shell_file="$CURRENT_HOME/.zshrc"
  local alias_block
  alias_block='alias ll="ls -alF"
alias gs="git status -sb"
alias gl="git log --oneline --graph --decorate --all"'
  append_if_missing "$shell_file" "# linux-init aliases" "$alias_block"

  if need_cmd git; then
    if ! run_as_target_user_shell "git config --global init.defaultBranch >/dev/null 2>&1"; then
      run_as_target_user_shell "git config --global init.defaultBranch main"
    fi
    if ! run_as_target_user_shell "git config --global pull.rebase >/dev/null 2>&1"; then
      run_as_target_user_shell "git config --global pull.rebase false"
    fi
  else
    warn "git is not installed; skipping Git defaults"
  fi

  if need_cmd zsh && [[ "$SHELL" != *zsh ]] && confirm "Set zsh as default shell for $CURRENT_USER"; then
    require_sudo
    local zsh_path
    zsh_path="$(command -v zsh)"
    run_sudo chsh -s "$zsh_path" "$CURRENT_USER"
  fi
}

module_security_check() {
  log "Running low-risk security checks"
  if need_cmd systemctl; then
    if systemctl list-unit-files firewalld.service >/dev/null 2>&1; then
      systemctl is-enabled firewalld >/dev/null 2>&1 || warn "firewalld is installed but not enabled"
    fi
    if systemctl list-unit-files ufw.service >/dev/null 2>&1; then
      systemctl is-enabled ufw >/dev/null 2>&1 || warn "ufw is installed but not enabled"
    fi
  fi

  if [[ -r /etc/ssh/sshd_config ]]; then
    if grep -Eiq '^[[:space:]]*PermitRootLogin[[:space:]]+yes' /etc/ssh/sshd_config; then
      warn "SSH root login appears enabled; review /etc/ssh/sshd_config"
    fi
    if grep -Eiq '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' /etc/ssh/sshd_config; then
      warn "SSH password authentication appears enabled; review /etc/ssh/sshd_config"
    fi
  else
    log "SSH server config not found or not readable"
  fi
}

run_all() {
  module_system_update
  module_base_tools
  module_docker
  module_node
  module_python_go
  module_shell_git
  module_security_check
}

menu() {
  while true; do
    cat <<EOF

Linux initialization menu
  1) System detection and package metadata update
  2) Install base development tools
  3) Install Docker
  4) Install Node.js LTS
  5) Install Python/Go toolchains
  6) Configure Shell and Git
  7) Low-risk security checks
  8) Run all
  0) Exit
EOF
    local choice
    read -r -p "Select an option: " choice
    case "$choice" in
      1) show_system_info; module_system_update ;;
      2) module_base_tools ;;
      3) module_docker ;;
      4) module_node ;;
      5) module_python_go ;;
      6) module_shell_git ;;
      7) module_security_check ;;
      8) run_all ;;
      0) exit 0 ;;
      *) warn "Invalid choice: $choice" ;;
    esac
  done
}

main() {
  parse_args "$@"
  init_user_context
  detect_distro
  show_system_info
  if [[ "$PKG_FAMILY" == "unsupported" ]]; then
    warn "This distro is not supported for automated installation"
  fi
  menu
}

main "$@"
