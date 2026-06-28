#!/usr/bin/env bash
# ============================================================================
# llama.cpp 交互式部署脚本
# 通过对话引导用户完成环境检测 → CUDA 安装 → 源码编译 → 后续更新
# 支持: Ubuntu/Debian, RHEL/CentOS/Fedora, Arch Linux, openSUSE
# ============================================================================

set -euo pipefail

# ===================== 颜色 & 日志 =====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
DIM='\033[2m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
fail()    { echo -e "  ${RED}✗${NC} $*"; }
sep()     { echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"; }

on_interrupt() {
    echo ""
    warn "操作已取消"
    exit 130
}

trap on_interrupt INT

read_input() {
    local __result_var="$1"
    local __input

    if ! read -r __input; then
        on_interrupt
    fi

    printf -v "$__result_var" "%s" "$__input"
}

# ===================== 配置 =====================
INSTALL_DIR="/opt/llama.cpp"
GITHUB_REPO="https://github.com/ggml-org/llama.cpp"
BUILD_DIR="${INSTALL_DIR}/build"
CMAKE_OPTS="-DBUILD_SHARED_LIBS=OFF"
CMAKE_CUDA_ARCHS=""
BUILD_WITH_CUDA=0
MAKE_JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || 4)
PKG_MGR=""
PKG_UPDATE_CMD=()
PKG_INSTALL_CMD=()
PKG_DEPS=()
CUDA_AVAILABLE=0
SKIP_CUDA=0
CUDA_VERSION=""
GPU_MODEL=""

# ===================== systemd 服务配置 =====================
SERVICE_NAME="llama-server"
SERVICE_UNIT=""
SERVICE_CONF="${INSTALL_DIR}/etc/server.conf"
HAS_SYSTEMD=0

refresh_paths() {
    BUILD_DIR="${INSTALL_DIR}/build"
    SERVICE_CONF="${INSTALL_DIR}/etc/server.conf"
}

set_install_dir() {
    local new_dir="$1"

    if ! validate_install_dir "$new_dir"; then
        return 1
    fi

    INSTALL_DIR="$new_dir"
    refresh_paths
}

validate_install_dir() {
    local dir="$1"

    if [[ -z "$dir" || "$dir" != /* ]]; then
        error "安装目录必须是绝对路径"
        return 1
    fi

    case "$dir" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|"$HOME")
            error "拒绝使用高风险安装目录: $dir"
            return 1
            ;;
    esac

    return 0
}

validate_jobs() {
    local jobs="$1"

    if [[ "$jobs" =~ ^[1-9][0-9]*$ ]]; then
        return 0
    fi

    error "并行编译数必须是正整数: $jobs"
    return 1
}

# 检测 systemd
if command -v systemctl &>/dev/null || [ -d /run/systemd/system ]; then
    HAS_SYSTEMD=1
fi

# 确定 unit 文件路径
_get_unit_path() {
    if [ -d /etc/systemd/system ]; then
        echo "/etc/systemd/system/${SERVICE_NAME}.service"
    elif [ -d /lib/systemd/system ]; then
        echo "/lib/systemd/system/${SERVICE_NAME}.service"
    else
        echo "/etc/systemd/system/${SERVICE_NAME}.service"
    fi
}

# 检查服务是否已安装
_service_installed() {
    local unit_path
    unit_path=$(_get_unit_path)
    [ -f "$unit_path" ]
}

# 生成 systemd unit 文件
_generate_unit_file() {
    local unit_path="$1"
    local tmp_file
    tmp_file=$(mktemp)

    cat > "${tmp_file}" <<UNITEOF
[Unit]
Description=llama.cpp llama-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SUDO_USER:-$(whoami)}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${SERVICE_CONF}
ExecStart=${INSTALL_DIR}/bin/llama-server -m "\${LLAMA_MODEL}" \${LLAMA_EXTRA_ARGS}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# 资源限制
LimitNOFILE=65536
LimitMEMLOCK=infinity

# 安全加固
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNITEOF

    run_as_root install -m 644 "${tmp_file}" "${unit_path}"
    rm -f -- "${tmp_file}"
}

# 生成默认配置文件
generate_default_conf() {
    local tmp_file
    tmp_file=$(mktemp)

    run_as_root mkdir -p "$(dirname -- "${SERVICE_CONF}")"

    cat > "${tmp_file}" <<EOF
# llama-server systemd 配置
# 模型路径 (绝对路径)
LLAMA_MODEL="${INSTALL_DIR}/models/llama-3.1-8b-instruct-q4_k_m.gguf"
# 额外参数 (可选)
# LLAMA_EXTRA_ARGS="--host 0.0.0.0 --port 8080 --threads $(nproc) --ctx-size 4096 --gpu-layers 35"
EOF

    run_as_root install -m 644 "${tmp_file}" "${SERVICE_CONF}"
    rm -f -- "${tmp_file}"
}

edit_file() {
    local file="$1"

    if [ -w "$file" ]; then
        if command -v vi &>/dev/null; then
            vi "$file"
        elif command -v nano &>/dev/null; then
            nano "$file"
        else
            warn "未找到 vi/nano，使用 cat 查看:"
            cat "$file"
        fi
    elif command -v sudoedit &>/dev/null; then
        sudoedit "$file"
    else
        warn "文件不可写且未找到 sudoedit，使用 cat 查看:"
        cat "$file"
    fi
}

# 生成服务文件并安装
_service_install() {
    local unit_path
    unit_path=$(_get_unit_path)

    # 确认 llama-server 已编译
    if [ ! -f "${INSTALL_DIR}/bin/llama-server" ]; then
        warn "llama-server 未编译，请先执行安装"
        return 1
    fi

    # 生成 unit 文件
    _generate_unit_file "$unit_path"
    ok "生成 unit 文件: ${unit_path}"

    # 生成默认配置
    if [ -f "${SERVICE_CONF}" ]; then
        warn "配置文件已存在，保留现有配置: ${SERVICE_CONF}"
    else
        generate_default_conf
        ok "生成配置文件: ${SERVICE_CONF}"
    fi

    # 询问用户编辑配置
    local edit_conf
    prompt_yes_no edit_conf "是否编辑服务器配置？(模型路径、端口等)" "Y"
    if [[ "$edit_conf" == "Y" ]]; then
        edit_file "${SERVICE_CONF}"
    fi

    # 重载 systemd
    sudo systemctl daemon-reload 2>/dev/null || true
    ok "systemd 服务文件已安装"
}

# 管理服务
_service_manage() {
    local action="$1"

    if ! _service_installed; then
        warn "服务未安装，请先安装"
        return 1
    fi

    sudo systemctl "$action" "${SERVICE_NAME}" 2>&1
    case "$action" in
        start|stop|restart|reload) ok "${action} 完成" ;;
        enable|disable) ok "${action} 完成" ;;
    esac
}

_service_status() {
    if ! _service_installed; then
        warn "服务未安装"
        return 1
    fi

    systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null || echo "服务状态未知"
}

# 卸载服务
_service_remove() {
    local unit_path
    unit_path=$(_get_unit_path)

    if ! _service_installed; then
        ok "服务未安装"
        return 0
    fi

    local confirm
    prompt_yes_no confirm "确认卸载 ${SERVICE_NAME} 服务？" "N"
    if [[ "$confirm" == "N" ]]; then
        info "已取消"
        return 0
    fi

    sudo systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    sudo systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
    run_as_root rm -f -- "$unit_path"
    run_as_root rm -f -- "${SERVICE_CONF}"
    ok "服务已卸载"
}

# ===================== 包管理器检测 =====================
detect_distro() {
    if command -v pacman &>/dev/null; then
        PKG_MGR="pacman"
        PKG_UPDATE_CMD=(pacman -Sy --noconfirm)
        PKG_INSTALL_CMD=(pacman -S --needed --noconfirm)
        PKG_DEPS=(git base-devel cmake)
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
        PKG_UPDATE_CMD=(dnf makecache)
        PKG_INSTALL_CMD=(dnf install -y)
        PKG_DEPS=(git cmake gcc-c++ make)
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
        PKG_UPDATE_CMD=(yum makecache)
        PKG_INSTALL_CMD=(yum install -y)
        PKG_DEPS=(git cmake gcc-c++ make)
    elif command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
        PKG_UPDATE_CMD=(apt-get update)
        PKG_INSTALL_CMD=(apt-get install -y)
        PKG_DEPS=(git cmake build-essential)
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper"
        PKG_UPDATE_CMD=(zypper refresh)
        PKG_INSTALL_CMD=(zypper install -y)
        PKG_DEPS=(git cmake gcc-c++ make)
    else
        error "未检测到支持的包管理器 (pacman/dnf/yum/apt/zypper)"
        exit 1
    fi
}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo &>/dev/null; then
        sudo "$@"
    else
        error "需要 root 权限，请手动执行: $*"
        exit 1
    fi
}

ensure_install_dir_parent() {
    local parent_dir
    parent_dir=$(dirname -- "${INSTALL_DIR}")

    if [ -w "$parent_dir" ]; then
        return 0
    fi

    if [ "$(id -u)" -eq 0 ]; then
        mkdir -p "$parent_dir"
        return 0
    fi

    if command -v sudo &>/dev/null; then
        warn "安装目录父路径不可写，将使用 sudo 创建并授权: ${INSTALL_DIR}"
        sudo mkdir -p "${INSTALL_DIR}"
        sudo chown "$(id -u):$(id -g)" "${INSTALL_DIR}"
        return 0
    fi

    error "无法写入安装目录父路径: ${parent_dir}"
    error "请使用 sudo 运行，或选择当前用户可写的安装目录"
    return 1
}

# ===================== 菜单系统 =====================
menu() {
    local title="$1"
    shift
    echo ""
    sep
    echo -e "  ${BOLD}$title${NC}"
    sep
    echo ""
    local i=1
    local item
    for item in "$@"; do
        echo -e "  ${BOLD}${i})${NC} ${item}"
        ((i++))
    done
    echo ""
}

prompt_choice() {
    local prompt_text="$1"
    local default="$2"
    local choices=()
    local count=0

    for ((i=3; i<=$#; i++)); do
        choices+=("${!i}")
        ((count++))
    done

    while true; do
        printf "  %b选择 [1-%s%s]:%b " "${BOLD}" "${count}" "${default:+, 默认 ${default}}" "${NC}"
        local input
        read_input input

        if [[ -z "$input" && -n "$default" ]]; then
            input="$default"
        fi

        if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$count" ]; then
            echo "${choices[$((input-1))]}"
            return 0
        elif [[ "$input" =~ ^[0-9]+$ ]]; then
            warn "请输入 1-${count} 之间的数字"
        else
            warn "无效输入"
        fi
    done
}

prompt_yes_no() {
    local result_var="$1"
    local question="$2"
    local default="${3:-N}"
    local yn="[Y/n]"
    [[ "$default" == "N" || "$default" == "n" ]] && yn="[y/N]"

    while true; do
        printf "  %b%s (%s)%b " "${BOLD}" "${question}" "${yn}" "${NC}"
        local input
        read_input input
        if [[ -z "$input" ]]; then
            if [[ "$default" == "Y" || "$default" == "y" ]]; then
                printf -v "$result_var" "%s" "Y"
            else
                printf -v "$result_var" "%s" "N"
            fi
            return 0
        fi
        case "$input" in
            [Yy]) printf -v "$result_var" "%s" "Y"; return 0 ;;
            [Nn]) printf -v "$result_var" "%s" "N"; return 0 ;;
            *) warn "请输入 y 或 n" ;;
        esac
    done
}

prompt_input() {
    local result_var="$1"
    local question="$2"
    local default="${3:-}"
    printf "  %b%s%s%b " "${BOLD}" "${question}" "${default:+ [${default}]}" "${NC}"
    local input
    read_input input
    if [[ -z "$input" && -n "$default" ]]; then
        printf -v "$result_var" "%s" "$default"
    else
        printf -v "$result_var" "%s" "$input"
    fi
}

# ===================== 依赖安装 =====================
install_deps() {
    step "安装编译依赖"

    local missing=()
    for cmd in git cmake gcc g++ make; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        ok "所有依赖已满足"
        return 0
    fi

    warn "缺少依赖: ${missing[*]}"
    warn "需要 root 权限安装依赖"

    run_as_root "${PKG_UPDATE_CMD[@]}"
    run_as_root "${PKG_INSTALL_CMD[@]}" "${PKG_DEPS[@]}"
    ok "依赖安装完成"
}

# ===================== CUDA 检测 =====================
check_cuda() {
    CUDA_AVAILABLE=0

    if command -v nvidia-smi &>/dev/null; then
        CUDA_VERSION=$(nvidia-smi | grep -i 'cuda version' | head -1 | grep -oP '[0-9]+\.[0-9]+' || echo "unknown")
        GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
        CUDA_AVAILABLE=1
        BUILD_WITH_CUDA=1
    elif command -v nvcc &>/dev/null; then
        CUDA_VERSION=$(nvcc --version 2>/dev/null | grep -i 'release' | grep -oP '[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        GPU_MODEL="GPU via nvcc"
        CUDA_AVAILABLE=1
        BUILD_WITH_CUDA=1
    elif [ -d /usr/local/cuda ] || [ -d /opt/cuda ]; then
        CUDA_VERSION="已安装路径"
        GPU_MODEL="未知"
        CUDA_AVAILABLE=1
        BUILD_WITH_CUDA=1
    fi
}

# ===================== 交互主流程 =====================
interactive_menu() {
    local mode="${1:-install}"  # install | update | uninstall

    while true; do
        echo ""
        echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}║           ${CYAN}llama.cpp 交互式部署${NC}               ║${NC}"
        echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  系统: $(uname -s) $(uname -m)"
        echo -e "  包管理器: ${PKG_MGR:-未检测}"
        echo -e "  安装目录: ${INSTALL_DIR}"
        echo -e "  CPU 核心: ${MAKE_JOBS}"

        if [ -d "${INSTALL_DIR}" ]; then
            local current_ver
            current_ver=$(cd "${INSTALL_DIR}" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo "?")
            echo -e "  当前版本: ${current_ver}"
        fi

        echo ""
        sep
        echo -e "  ${BOLD}请选择操作:${NC}"
        echo ""
        echo -e "  ${BOLD}1)${NC} 全新安装"
        echo -e "     克隆源码 → 检测 CUDA → 编译安装"
        echo ""
        echo -e "  ${BOLD}2)${NC} 增量更新"
        echo -e "     拉取最新源码 → 重新编译"
        echo ""
        echo -e "  ${BOLD}3)${NC} 仅编译 (源码已存在)"
        echo -e "     跳过拉取，直接编译"
        echo ""
        echo -e "  ${BOLD}4)${NC} CUDA 设置"
        echo -e "     查看 CUDA 状态 / 切换 CUDA 开关"
        echo ""
        echo -e "  ${BOLD}5)${NC} 自定义设置"
        echo -e "     修改安装目录 / 编译选项 / 并行数"
        echo ""
        echo -e "  ${BOLD}6)${NC} 验证安装"
        echo -e "     检查已安装组件"
        echo ""
        echo -e "  ${BOLD}7)${NC} 卸载"
        echo -e "     删除所有安装文件"
        echo ""
        echo -e "  ${BOLD}8)${NC} systemd 服务"
        echo -e "     安装/管理 systemd 服务 (后台自启)"
        echo ""
        echo -e "  ${BOLD}0)${NC} 退出"
        echo ""
        printf "  %b选择:%b " "${BOLD}" "${NC}"
        local choice
        read_input choice

        case "$choice" in
            1) do_install ;;
            2) do_update ;;
            3) do_build_only ;;
            4) do_cuda_settings ;;
            5) do_custom_settings ;;
            6) do_verify ;;
            7) do_uninstall ;;
            8) do_systemd ;;
            0) echo -e "\n${GREEN}再见！${NC}\n"; exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ===================== 安装流程 =====================
do_install() {
    step "开始安装"

    # 1. 选择安装目录
    local target_dir
    prompt_input target_dir "安装目录" "${INSTALL_DIR}"
    if ! set_install_dir "$target_dir"; then
        return 1
    fi

    # 2. 选择编译选项
    local build_mode="cuda"
    local gpu_targets=""

    if [ "$CUDA_AVAILABLE" = "1" ]; then
        local cuda_choice
        menu "编译模式" \
            "CUDA 编译 (推荐，利用 GPU 加速)" \
            "CPU 编译 (无 GPU 加速)"
        printf "  %b选择:%b " "${BOLD}" "${NC}"
        read_input cuda_choice
        case "$cuda_choice" in
            1) build_mode="cuda"; BUILD_WITH_CUDA=1 ;;
            2) build_mode="cpu"; BUILD_WITH_CUDA=0 ;;
            *) build_mode="cuda"; BUILD_WITH_CUDA=1 ;;
        esac
    else
        build_mode="cpu"
        BUILD_WITH_CUDA=0
        warn "未检测到 CUDA，将使用 CPU 编译"
    fi

    # 3. 如果选 CUDA，询问 GPU 架构
    if [ "$build_mode" = "cuda" ]; then
        local arch_choice
        menu "GPU 架构选择" \
            "自动检测 (推荐，编译所有兼容架构)" \
            "手动指定 (性能最优，仅当前 GPU)" \
            "最小集合 (编译最快)"
        printf "  %b选择:%b " "${BOLD}" "${NC}"
        read_input arch_choice
        case "$arch_choice" in
            1) CMAKE_CUDA_ARCHS="" ;;
            2)
                echo ""
                info "支持的 GPU 架构 (用分号分隔):"
                info "  AD102 (RTX 4090/4080) | GA102 (RTX 3090) | GA100 (A100)"
                info "  TU102 (RTX 2080) | Ampere 全家 | Hopper | Ada Lovelace"
                printf "  %b输入架构:%b " "${BOLD}" "${NC}"
                read_input gpu_targets
                if [[ -n "$gpu_targets" ]]; then
                    CMAKE_CUDA_ARCHS="-DGPU_TARGETS=${gpu_targets}"
                fi
                ;;
            3) CMAKE_CUDA_ARCHS="-DGPU_TARGETS=GA100;GA102;AD102" ;;
            *) CMAKE_CUDA_ARCHS="" ;;
        esac
    fi

    # 4. 确认并行编译数
    local jobs
    prompt_input jobs "并行编译数" "${MAKE_JOBS}"
    if ! validate_jobs "$jobs"; then
        return 1
    fi
    MAKE_JOBS="$jobs"

    # 5. 确认并开始
    echo ""
    sep
    echo -e "  ${BOLD}安装配置:${NC}"
    echo -e "  目录: ${INSTALL_DIR}"
    echo -e "  模式: ${build_mode}"
    if [ -n "$CMAKE_CUDA_ARCHS" ]; then
        echo -e "  GPU:  ${CMAKE_CUDA_ARCHS}"
    fi
    echo -e "  并行: ${MAKE_JOBS} jobs"
    sep
    echo ""

    local confirm
    prompt_yes_no confirm "开始安装？"
    if [[ "$confirm" == "N" ]]; then
        info "已取消"
        return 0
    fi

    # 执行安装
    install_deps
    clone_or_update
    build
    setup_env
    do_verify
}

# ===================== 更新流程 =====================
do_update() {
    if [ ! -d "${INSTALL_DIR}" ]; then
        warn "未找到已安装的 llama.cpp，请先执行安装"
        return 0
    fi
    if [ ! -d "${INSTALL_DIR}/.git" ]; then
        error "安装目录不是 git 仓库: ${INSTALL_DIR}"
        return 1
    fi

    step "增量更新"

    # 检查是否有新版本
    cd "${INSTALL_DIR}"
    local current_head
    current_head=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    info "当前版本: ${current_head}"

    if git fetch origin &>/dev/null; then
        local remote_head
        remote_head=$(git rev-parse --short origin/HEAD 2>/dev/null || echo "unknown")
        if [ "$current_head" = "$remote_head" ]; then
            ok "已经是最新版本"
            return 0
        fi
        warn "发现新版本: ${remote_head}"
    fi

    local confirm
    prompt_yes_no confirm "拉取最新源码并重新编译？"
    if [[ "$confirm" == "N" ]]; then
        info "已取消"
        return 0
    fi

    clone_or_update
    build
    setup_env
    do_verify
}

# ===================== 仅编译 =====================
do_build_only() {
    if [ ! -d "${INSTALL_DIR}" ]; then
        warn "未找到源码目录: ${INSTALL_DIR}"
        return 0
    fi

    step "仅编译"
    build
    setup_env
    do_verify
}

# ===================== CUDA 设置 =====================
do_cuda_settings() {
    step "CUDA 设置"
    echo ""

    if [ "$CUDA_AVAILABLE" = "1" ]; then
        ok "CUDA 状态: 已检测到"
        info "CUDA 版本: ${CUDA_VERSION}"
        info "GPU 型号: ${GPU_MODEL}"
    else
        warn "CUDA 状态: 未检测到"
        echo ""
        info "安装 CUDA 的方法:"
        case "$PKG_MGR" in
            pacman) info "  pacman -S cuda" ;;
            apt)    info "  sudo apt-get install -y cuda-toolkit" ;;
            dnf|yum) info "  sudo ${PKG_MGR} install -y cuda-toolkit" ;;
            zypper) info "  sudo zypper install -y cuda-toolkit" ;;
        esac
        echo ""
        info "安装后请重新运行本脚本"
    fi

    local action
    menu "CUDA 操作" \
        "切换 CUDA 编译开关" \
        "查看当前编译选项"
    printf "  %b选择:%b " "${BOLD}" "${NC}"
    read_input action
    case "$action" in
        1)
            local use_cuda
            prompt_yes_no use_cuda "启用 CUDA 编译？" "Y"
            if [[ "$use_cuda" == "Y" ]]; then
                BUILD_WITH_CUDA=1
                info "已启用 CUDA 编译"
            else
                BUILD_WITH_CUDA=0
                info "已禁用 CUDA 编译"
            fi
            ;;
        2)
            info "当前 CMake 选项: ${CMAKE_OPTS}"
            info "CUDA 编译: $([ "$BUILD_WITH_CUDA" = "1" ] && echo "启用" || echo "禁用")"
            ;;
    esac
}

# ===================== 自定义设置 =====================
do_custom_settings() {
    step "自定义设置"
    echo ""

    local setting
    menu "自定义选项" \
        "修改安装目录" \
        "修改编译并行数" \
        "修改 CMake 编译选项"
    printf "  %b选择:%b " "${BOLD}" "${NC}"
    read_input setting

    case "$setting" in
        1)
            local new_dir
            prompt_input new_dir "新安装目录" "${INSTALL_DIR}"
            if ! set_install_dir "$new_dir"; then
                return 1
            fi
            ok "安装目录已更新: ${INSTALL_DIR}"
            ;;
        2)
            local new_jobs
            prompt_input new_jobs "并行编译数" "${MAKE_JOBS}"
            if ! validate_jobs "$new_jobs"; then
                return 1
            fi
            MAKE_JOBS="$new_jobs"
            ok "并行数已更新: ${MAKE_JOBS}"
            ;;
        3)
            local new_opts
            prompt_input new_opts "CMake 选项" "${CMAKE_OPTS}"
            CMAKE_OPTS="$new_opts"
            ok "CMake 选项已更新"
            ;;
    esac
}

# ===================== 验证 =====================
do_verify() {
    step "验证安装"
    echo ""

    local all_ok=1
    local bin_dir="${INSTALL_DIR}/bin"

    # 加载环境
    if [ -f "${INSTALL_DIR}/env.sh" ]; then
        source "${INSTALL_DIR}/env.sh"
    fi

    for bin in llama-cli llama-server llama-quantize; do
        if command -v "$bin" &>/dev/null; then
            ok "$bin 可用"
        else
            fail "$bin 未找到"
            all_ok=0
        fi
    done

    if [ "$CUDA_AVAILABLE" = "1" ]; then
        if llama-server --help 2>&1 | grep -qi cuda 2>/dev/null; then
            ok "CUDA 支持已启用"
        else
            warn "CUDA 支持可能未启用"
        fi
    fi

    if command -v llama-cli &>/dev/null; then
        echo ""
        echo -e "  ${BOLD}版本:${NC}"
        llama-cli --version 2>/dev/null || echo "  (版本信息不可用)"
    fi

    if [ "$all_ok" -eq 1 ]; then
        echo ""
        ok "安装验证通过！"
    fi
}

# ===================== 卸载 =====================
do_uninstall() {
    step "卸载 llama.cpp"
    echo ""
    warn "这将删除 ${INSTALL_DIR} 目录及其所有内容"
    echo ""

    local confirm
    prompt_yes_no confirm "确认卸载？"
    if [[ "$confirm" == "N" ]]; then
        info "已取消"
        return 0
    fi

    if ! validate_install_dir "$INSTALL_DIR"; then
        return 1
    fi

    local typed_dir
    prompt_input typed_dir "请输入完整安装目录以确认删除" ""
    if [[ "$typed_dir" != "$INSTALL_DIR" ]]; then
        info "输入不匹配，已取消"
        return 0
    fi

    if command -v trash &>/dev/null; then
        trash "${INSTALL_DIR}"
    else
        run_as_root rm -rf -- "${INSTALL_DIR}"
    fi
    ok "已删除 ${INSTALL_DIR}"

    # 清理 shell profile
    local shell_rc=""
    case "$SHELL" in
        */zsh) shell_rc="${HOME}/.zshrc" ;;
        */bash) shell_rc="${HOME}/.bashrc" ;;
        *) shell_rc="${HOME}/.bashrc" ;;
    esac

    if [ -f "$shell_rc" ] && grep -qF "llama.cpp env" "$shell_rc" 2>/dev/null; then
        sed -i '/# llama.cpp environment/,+2d' "$shell_rc"
        ok "已清理 ${shell_rc}"
    fi

    ok "卸载完成"
}

# ===================== 源码克隆/更新 =====================
clone_or_update() {
    step "获取 llama.cpp 源码"

    if ! validate_install_dir "$INSTALL_DIR"; then
        return 1
    fi

    if [ -d "${INSTALL_DIR}/.git" ]; then
        cd "${INSTALL_DIR}"
        local current_head
        current_head=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        info "当前版本: ${current_head}"

        if ! git diff --quiet 2>/dev/null; then
            warn "检测到未提交的修改，先 stash"
            git stash --include-untracked 2>/dev/null || true
        fi

        if git fetch origin &>/dev/null; then
            local remote_head
            remote_head=$(git rev-parse --short origin/HEAD 2>/dev/null || echo "unknown")
            if [ "$current_head" = "$remote_head" ]; then
                ok "源码已是最新版本"
            else
                ok "发现新版本，更新中..."
                if ! git reset --hard origin/HEAD 2>/dev/null; then
                    git pull --ff-only origin HEAD
                fi
                local new_head
                new_head=$(git rev-parse --short HEAD)
                ok "已更新至: ${new_head}"
            fi
        else
            warn "无法获取远程更新"
        fi
    else
        if [ -d "${INSTALL_DIR}" ] && [ -n "$(find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
            error "安装目录已存在但不是空目录或 git 仓库: ${INSTALL_DIR}"
            error "请选择空目录，或手动处理该目录后重试"
            return 1
        fi

        info "克隆源码到 ${INSTALL_DIR}"
        ensure_install_dir_parent
        git clone --depth 1 "${GITHUB_REPO}" "${INSTALL_DIR}"
        ok "克隆完成"
    fi
}

# ===================== 编译 =====================
build() {
    step "编译 llama.cpp (jobs=${MAKE_JOBS})"

    local cmake_args=()
    read -r -a cmake_args <<< "$CMAKE_OPTS"

    if [ "$BUILD_WITH_CUDA" = "1" ] && [ "$CUDA_AVAILABLE" = "1" ]; then
        cmake_args+=("-DGGML_CUDA=ON")
        if [ -n "$CMAKE_CUDA_ARCHS" ]; then
            cmake_args+=("${CMAKE_CUDA_ARCHS}")
            info "GPU 架构: ${CMAKE_CUDA_ARCHS}"
        fi
        ok "启用 CUDA 编译"
    elif [ "$BUILD_WITH_CUDA" = "1" ]; then
        warn "已请求 CUDA 编译，但未检测到 CUDA，将使用 CPU 编译"
    else
        warn "使用 CPU 编译"
    fi

    cd "${INSTALL_DIR}"
    rm -rf -- "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"

    info "CMake 配置..."
    cmake .. "${cmake_args[@]}" -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -5

    info "开始编译..."
    if cmake --build . --config Release -j "${MAKE_JOBS}" 2>&1; then
        ok "编译完成"
    else
        error "编译失败"
        error "查看日志: ${BUILD_DIR}/CMakeFiles/CMakeOutput.log"
        exit 1
    fi

    # 安装
    local bin_dir="${INSTALL_DIR}/bin"
    mkdir -p "${bin_dir}"

    for bin in llama-cli llama-server llama-quantize llama-convert-llama2c-to-ggml llama-speculative llama-eval-cache llama-bench; do
        if [ -f "${BUILD_DIR}/bin/${bin}" ]; then
            cp -f "${BUILD_DIR}/bin/${bin}" "${bin_dir}/"
            ok "安装: ${bin}"
        fi
    done

    for lib in "${BUILD_DIR}"/libllama* "${BUILD_DIR}"/libggml* "${BUILD_DIR}"/libggml-base* "${BUILD_DIR}"/libggml-cuda*; do
        [ -f "$lib" ] && cp -f "$lib" "${bin_dir}/" 2>/dev/null || true
    done

    [ -d "${INSTALL_DIR}/include" ] && cp -r "${INSTALL_DIR}/include" "${bin_dir}/" 2>/dev/null || true

    ok "安装到: ${bin_dir}"
}

# ===================== 环境变量配置 =====================
setup_env() {
    step "配置环境变量"

    local bin_dir="${INSTALL_DIR}/bin"
    local env_file="${INSTALL_DIR}/env.sh"

    cat > "${env_file}" <<EOF
#!/usr/bin/env bash
export LLAMA_CPP_DIR="${INSTALL_DIR}"
export PATH="${bin_dir}:\$PATH"
EOF

    if [ "$CUDA_AVAILABLE" = "1" ]; then
        local cuda_lib_paths=""
        for p in /usr/local/cuda/lib64 /usr/local/cuda/extras/CUPTI/lib64 /opt/cuda/lib64; do
            [ -d "$p" ] && cuda_lib_paths="${cuda_lib_paths}:${p}"
        done
        if [ -n "$cuda_lib_paths" ]; then
            printf 'export LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"\n' "${cuda_lib_paths#:}" >> "${env_file}"
        fi
    fi

    chmod +x "${env_file}"

    local shell_rc=""
    case "$SHELL" in
        */zsh) shell_rc="${HOME}/.zshrc" ;;
        */bash) shell_rc="${HOME}/.bashrc" ;;
        *) shell_rc="${HOME}/.bashrc" ;;
    esac

    if ! grep -qF "llama.cpp env" "$shell_rc" 2>/dev/null; then
        echo "" >> "$shell_rc"
        echo "# llama.cpp environment" >> "$shell_rc"
        echo "source \"${env_file}\"" >> "$shell_rc"
        ok "已添加到 ${shell_rc}"
    fi

    source "${env_file}"
    ok "环境变量已生效"
}

# ===================== systemd 服务菜单 =====================
do_systemd() {
    if [ "$HAS_SYSTEMD" = "0" ]; then
        warn "当前系统未检测到 systemd，无法管理服务"
        warn "请确认系统使用 systemd (多数现代 Linux 发行版默认使用)"
        echo ""
        info "非 systemd 系统可使用以下命令管理:"
        echo "  sudo systemctl {start|stop|restart|status} ${SERVICE_NAME}"
        return 0
    fi

    step "systemd 服务管理"
    echo ""

    local svc_action
    menu "服务操作" \
        "安装服务" \
        "启动服务" \
        "停止服务" \
        "重启服务" \
        "查看状态" \
        "开机自启" \
        "取消自启" \
        "编辑配置" \
        "卸载服务"
    printf "  %b选择:%b " "${BOLD}" "${NC}"
    read_input svc_action

    case "$svc_action" in
        1) _service_install ;;
        2) _service_manage start ;;
        3) _service_manage stop ;;
        4) _service_manage restart ;;
        5) _service_status ;;
        6) _service_manage enable ;;
        7) _service_manage disable ;;
        8)
            if [ -f "${SERVICE_CONF}" ]; then
                edit_file "${SERVICE_CONF}"
                ok "编辑完成，重启服务以生效"
                local confirm
                prompt_yes_no confirm "立即重启服务？"
                if [[ "$confirm" == "Y" ]]; then
                    _service_manage restart
                fi
            else
                warn "配置文件不存在: ${SERVICE_CONF}"
                warn "请先安装服务"
            fi
            ;;
        9) _service_remove ;;
        *) warn "无效选择" ;;
    esac
}

# ===================== 主入口 =====================
main() {
    info "llama.cpp 交互式部署脚本"

    detect_distro
    check_cuda

    interactive_menu
}

main "$@"
