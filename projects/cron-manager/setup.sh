#!/bin/bash
# Cron Manager 一键部署脚本
# 用法: bash setup.sh [--port 3000] [--user cron-manager] [--systemd]

set -euo pipefail

# ===== 颜色输出 =====
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ===== 参数解析 =====
PORT=3000
USER=""
SYSTEMD=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --port)    PORT="$2"; shift 2 ;;
    --user)    USER="$2"; shift 2 ;;
    --systemd) SYSTEMD=true; shift ;;
    --help)
      echo "用法: bash setup.sh [选项]"
      echo ""
      echo "选项:"
      echo "  --port PORT    设置端口 (默认: 3000)"
      echo "  --user USER    以指定用户运行 (默认: 当前用户)"
      echo "  --systemd      安装为 systemd 服务"
      echo "  --help         显示帮助"
      echo ""
      exit 0
      ;;
    *) error "未知参数: $1" ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
NODE_DIR="$PROJECT_DIR/node_modules"
DATA_DIR="$PROJECT_DIR/data"
LOG_DIR="$PROJECT_DIR/logs"

# ===== 前置检查 =====
info "检查前置依赖..."

# 检查 Node.js
if ! command -v node &>/dev/null; then
  error "未检测到 Node.js，请先安装 Node.js 18+"
fi

NODE_VERSION=$(node -v | sed 's/v//')
NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
if [ "$NODE_MAJOR" -lt 18 ]; then
  warn "Node.js 版本 $NODE_VERSION，建议 18+"
fi
ok "Node.js $(node -v)"

# 检查 npm
if ! command -v npm &>/dev/null; then
  error "未检测到 npm"
fi
ok "npm $(npm -v)"

# ===== 创建目录 =====
info "创建目录结构..."
mkdir -p "$DATA_DIR" "$LOG_DIR"
ok "目录结构就绪"

# ===== 安装依赖 =====
info "安装依赖..."
if [ -d "$NODE_DIR" ] && [ -f "$PROJECT_DIR/package-lock.json" ]; then
  info "依赖已存在，跳过安装（如需重装: rm -rf node_modules && bash setup.sh）"
else
  cd "$PROJECT_DIR"
  npm install --production 2>&1 | tail -3
fi
ok "依赖安装完成"

# ===== 端口检查 =====
if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
  warn "端口 $PORT 已被占用"
  if ! ss -tlnp 2>/dev/null | grep ":${PORT} " | grep -q node; then
    warn "占用端口的是其他程序，确认是否继续使用 $PORT"
    read -rp "继续? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || error "已取消"
  else
    info "检测到 cron-manager 已在运行，尝试重启..."
    kill "$(fuser ${PORT}/tcp 2>/dev/null)" 2>/dev/null || true
    sleep 1
  fi
fi

# ===== 创建进程守护脚本 =====
cat > "$PROJECT_DIR/start.sh" << 'STARTUP'
#!/bin/bash
cd "$(dirname "$0")"
exec node server.js >> logs/app.log 2>&1
STARTUP
chmod +x "$PROJECT_DIR/start.sh"
ok "启动脚本就绪"

# ===== 安装 systemd 服务 =====
if [ "$SYSTEMD" = true ]; then
  info "安装 systemd 服务..."
  
  RUN_USER="${USER:-$(whoami)}"
  SERVICE_NAME="cron-manager"
  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
  
  cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Cron Manager - Web-based Task Scheduler
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$PROJECT_DIR
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
StandardOutput=append:$LOG_DIR/app.log
StandardError=append:$LOG_DIR/error.log
Environment=NODE_ENV=production
Environment=PORT=$PORT
Environment=HOST=0.0.0.0

[Install]
WantedBy=multi-user.target
EOF
  
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl start "$SERVICE_NAME"
  ok "systemd 服务已安装并启动"
  systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || true
  
elif [ -n "$USER" ]; then
  info "创建进程守护脚本..."
  cat > "$PROJECT_DIR/start.sh" << STARTUP
#!/bin/bash
# 以用户 $USER 运行
cd "$PROJECT_DIR"
exec sudo -u "$USER" node server.js >> logs/app.log 2>&1
STARTUP
  chmod +x "$PROJECT_DIR/start.sh"
  ok "启动脚本已创建"
fi

# ===== 防火墙配置 =====
info "检查防火墙..."

# 尝试打开端口
open_port() {
  local port=$1
  if command -v ufw &>/dev/null; then
    ufw allow "$port/tcp" 2>/dev/null && ok "ufw: 已放行端口 $port"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="$port/tcp" &>/dev/null && \
    firewall-cmd --reload &>/dev/null && \
    ok "firewalld: 已放行端口 $port"
  elif command -v iptables &>/dev/null && [ -w /etc/iptables ]; then
    iptables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    ok "iptables: 已放行端口 $port"
  else
    warn "未检测到防火墙管理工具，请手动放行端口 $port"
  fi
}
open_port "$PORT"

# ===== 获取本机 IP =====
MY_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)

# ===== 启动服务 =====
info "启动服务..."
cd "$PROJECT_DIR"
node server.js &
SERVER_PID=$!
sleep 1

if kill -0 "$SERVER_PID" 2>/dev/null; then
  ok "服务已启动 (PID: $SERVER_PID)"
else
  error "服务启动失败，查看日志: cat logs/app.log"
fi

# ===== 完成 =====
echo ""
echo "============================================"
echo -e " ${GREEN}✅ Cron Manager 部署完成!${NC}"
echo "============================================"
echo ""
echo "  访问地址: http://$MY_IP:$PORT"
echo "  项目目录: $PROJECT_DIR"
echo "  数据文件: $DATA_DIR/tasks.json"
echo "  日志目录: $LOG_DIR/"
echo ""
echo "  停止服务: kill $SERVER_PID"
if [ "$SYSTEMD" = true ]; then
  echo "  管理服务: systemctl stop/start/restart cron-manager"
fi
echo "============================================"
echo ""
