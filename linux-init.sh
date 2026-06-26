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
  printf '[信息] %s\n' "$*"
}

warn() {
  printf '[警告] %s\n' "$*" >&2
}

die() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Linux 开发机初始化脚本

用法:
  ./linux-init.sh [options]

选项:
  --dry-run      只打印将要执行的操作，不修改系统
  --yes, -y      对确认提示默认回答 yes
  --help, -h     显示帮助

默认使用交互式菜单。支持的发行版家族:
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
        die "未知选项: $1"
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
    printf '[DRY-RUN] 以用户 %s 执行: %s\n' "$CURRENT_USER" "$command"
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
    log "$prompt: 是"
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
  need_cmd sudo || die "系统级修改需要 sudo"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    sudo -v || die "sudo 认证失败"
  fi
}

detect_distro() {
  [[ -r /etc/os-release ]] || die "找不到 /etc/os-release；不支持当前 Linux 发行版"
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
        die "RHEL 系统未找到 dnf/yum"
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
  log "发行版: $DISTRO_NAME"
  log "包管理家族: $PKG_FAMILY"
  if [[ -n "$PKG_MANAGER" ]]; then
    log "包管理器: $PKG_MANAGER"
  fi
  log "目标用户: $CURRENT_USER"
  log "用户目录: $CURRENT_HOME"
}

ensure_supported() {
  [[ "$PKG_FAMILY" != "unsupported" ]] || die "不支持的发行版: $DISTRO_NAME"
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
    log "请求的软件包均已安装"
    return 0
  fi

  log "正在安装软件包: ${missing[*]}"
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
      log "正在安装 Development Tools 软件包组"
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
  log "正在更新软件包元数据"
  require_sudo
  pkg_update
}

module_base_tools() {
  log "正在安装基础开发工具"
  require_sudo
  mapfile -t packages < <(base_packages)
  install_packages "${packages[@]}"
  install_group_development_tools
}

install_nvm() {
  local nvm_dir="$CURRENT_HOME/.nvm"
  if [[ -s "$nvm_dir/nvm.sh" ]]; then
    log "nvm 已安装"
  else
    log "正在为 $CURRENT_USER 安装 nvm"
    run_as_target_user_shell 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
  fi

  log "正在通过 nvm 安装 Node.js LTS"
  local nvm_command="export NVM_DIR=\"$nvm_dir\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm install --lts; nvm alias default lts/*"
  run_as_target_user_shell "$nvm_command"
}

module_node() {
  log "正在安装 Node.js LTS"
  need_cmd curl || install_packages curl ca-certificates
  install_nvm
}

module_python_go() {
  log "正在安装 Python 和 Go 工具链"
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
    die "需要 $PKG_MANAGER"
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
  log "正在安装 Docker"
  require_sudo
  if need_cmd docker; then
    log "Docker 命令已存在"
  else
    case "$PKG_FAMILY" in
      debian) install_docker_debian || { warn "Docker 官方仓库安装失败，尝试使用发行版软件包"; install_packages docker.io docker-compose-plugin; } ;;
      rhel) install_docker_rhel || { warn "Docker 官方仓库安装失败，尝试使用发行版软件包"; install_packages docker; } ;;
      arch) install_docker_arch ;;
    esac
  fi

  if need_cmd systemctl || [[ "$DRY_RUN" -eq 1 ]]; then
    if confirm "启用并启动 Docker 服务"; then
      run_sudo systemctl enable --now docker
    fi
  fi

  if [[ "$CURRENT_USER" != "root" ]] && confirm "将 $CURRENT_USER 加入 docker 用户组"; then
    run_sudo usermod -aG docker "$CURRENT_USER"
    warn "需要退出并重新登录后，docker 用户组权限才会生效"
  fi
}

backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
  log "正在备份 $file 到 $backup"
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
    log "$file 已包含 $marker"
    return 0
  fi
  backup_file "$file"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] 追加 %s 到 %s\n' "$marker" "$file"
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
  log "正在温和配置 Shell 和 Git"
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
    warn "git 未安装，跳过 Git 默认配置"
  fi

  if need_cmd zsh && [[ "$SHELL" != *zsh ]] && confirm "将 zsh 设置为 $CURRENT_USER 的默认 Shell"; then
    require_sudo
    local zsh_path
    zsh_path="$(command -v zsh)"
    run_sudo chsh -s "$zsh_path" "$CURRENT_USER"
  fi
}

module_security_check() {
  log "正在执行低风险安全检查"
  if need_cmd systemctl; then
    if systemctl list-unit-files firewalld.service >/dev/null 2>&1; then
      systemctl is-enabled firewalld >/dev/null 2>&1 || warn "firewalld 已安装但未启用"
    fi
    if systemctl list-unit-files ufw.service >/dev/null 2>&1; then
      systemctl is-enabled ufw >/dev/null 2>&1 || warn "ufw 已安装但未启用"
    fi
  fi

  if [[ -r /etc/ssh/sshd_config ]]; then
    if grep -Eiq '^[[:space:]]*PermitRootLogin[[:space:]]+yes' /etc/ssh/sshd_config; then
      warn "SSH root 登录看起来已启用，请检查 /etc/ssh/sshd_config"
    fi
    if grep -Eiq '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' /etc/ssh/sshd_config; then
      warn "SSH 密码认证看起来已启用，请检查 /etc/ssh/sshd_config"
    fi
  else
    log "未找到 SSH 服务端配置，或当前用户不可读"
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

Linux 初始化菜单
  1) 系统检测与软件包元数据更新
  2) 安装基础开发工具
  3) 安装 Docker
  4) 安装 Node.js LTS
  5) 安装 Python/Go 工具链
  6) 配置 Shell 和 Git
  7) 低风险安全检查
  8) 执行全部
  0) 退出
EOF
    local choice
    read -r -p "请选择操作: " choice
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
      *) warn "无效选择: $choice" ;;
    esac
  done
}

main() {
  parse_args "$@"
  init_user_context
  detect_distro
  show_system_info
  if [[ "$PKG_FAMILY" == "unsupported" ]]; then
    warn "当前发行版不支持自动安装"
  fi
  menu
}

main "$@"
