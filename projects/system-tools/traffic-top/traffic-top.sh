#!/bin/bash
# =============================================================================
# traffic-top.sh - Linux 网络流量使用排行查询工具
# =============================================================================
# 功能：
#   1. 按进程排行：显示各进程的实时收发流量
#   2. 按接口排行：显示各网络接口的流量统计
#   3. 按连接排行：显示各 TCP/UDP 连接统计（需 root）
#   4. 实时监控：类似 top 的持续刷新模式
#
# 用法：
#   ./traffic-top.sh [选项]
#
# 选项：
#   -m, --mode <type>    模式：process / interface / connection / all（默认 process）
#   -n, --count <num>    显示前 N 条（默认 10）
#   -d, --delay <sec>    刷新间隔（秒，默认 2）
#   -t, --top <num>      同 --count
#   -c, --cumulative     累计模式（仅 process 模式）
#   -i, --include-lo     包含 loopback 接口
#   -h, --help           显示帮助
#
# 依赖：ss, awk, sort, bc（均为 Linux 系统预装）
# 注意：按进程/连接排行需要 root 权限
# =============================================================================

set -euo pipefail

# ── 颜色定义 (使用 printf 获取真实 escape 字节) ─────────────────────────────
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
CYAN=$(printf '\033[0;36m')
BOLD=$(printf '\033[1m')
NC=$(printf '\033[0m')

# ── 默认参数 ────────────────────────────────────────────────────────────────
MODE="process"
COUNT=10
DELAY=2

# ── 工具函数 ────────────────────────────────────────────────────────────────

# 格式化字节数为人类可读格式
format_bytes() {
    local bytes=${1:-0}
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        printf "%.1fG" "$(echo "scale=1; $bytes / 1073741824" | bc)"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        printf "%.1fM" "$(echo "scale=1; $bytes / 1048576" | bc)"
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        printf "%.1fK" "$(echo "scale=1; $bytes / 1024" | bc)"
    else
        printf "%dB" "$bytes"
    fi
}

# 百分比计算（保证有前导零）
calc_pct() {
    local num=$1
    local den=$2
    if [ "$den" -eq 0 ] 2>/dev/null; then
        echo "0.0%"
        return
    fi
    local result
    result=$(echo "scale=1; $num * 100 / $den" | bc)
    # 确保前导零
    if [[ "$result" == .* ]]; then
        result="0${result}"
    fi
    echo "${result}%"
}

# 打印分隔线
print_separator() {
    printf '%*s\n' 80 '' | tr ' ' '='
}

print_header() {
    local title="$1"
    printf '\n'
    print_separator
    local pad=$(( (78 + ${#title} + 4) / 2 ))
    printf '%*s\n' "$pad" "  $title"
    print_separator
    printf '\n'
}

# 显示帮助
show_help() {
    cat <<'EOF'
用法: traffic-top.sh [选项]

选项:
  -m, --mode <type>    排行模式:
                         process    - 按进程排行（默认）
                         interface  - 按网络接口排行
                         connection - 按连接排行（需 root）
                         all        - 同时显示所有模式
  -n, --count <num>    显示前 N 条结果（默认 10）
  -d, --delay <sec>    刷新间隔秒数（默认 2，仅实时监控模式）
  -t, --top <num>      同 --count
  -c, --cumulative     累计模式：显示从系统启动以来的总流量
  -i, --include-lo     包含 loopback 接口
  -h, --help           显示此帮助信息

示例:
  ./traffic-top.sh                        # 按进程排行，前10
  ./traffic-top.sh -m interface           # 按接口排行
  ./traffic-top.sh -m connection -n 20    # 按连接排行，前20
  ./traffic-top.sh -m process -n 5 -d 1   # 按进程排行，前5，1秒刷新
  ./traffic-top.sh -m all                 # 同时显示所有模式
  ./traffic-top.sh -m process -c          # 显示累计流量

依赖: ss, awk, sort, bc
注意: 按进程/连接排行需要 root 权限以获取完整信息
EOF
}

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if [ "$MODE" = "connection" ]; then
            echo "${YELLOW}[WARN]${NC} 按连接排行需要 root 权限，部分信息可能不完整"
            echo "${YELLOW}[WARN]${NC} 建议使用 sudo $0 $*"
        fi
    fi
}

# ── 核心功能：按进程排行 ─────────────────────────────────────────────────────

rank_by_process() {
    local include_lo="${1:-0}"
    local top_n="${2:-10}"

    print_header "📊 进程流量排行 (Process Traffic Ranking)"

    local tmpfile
    tmpfile=$(mktemp /tmp/traffic-top.XXXXXX)

    # 遍历所有进程，读取 /proc/<pid>/net/dev 累加网卡流量
    for pid_dir in /proc/[0-9]*; do
        local pid
        pid=$(basename "$pid_dir")
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue

        local proc_rx=0 proc_tx=0
        if [ -f "$pid_dir/net/dev" ]; then
            while IFS=: read -r iface stats; do
                iface=$(echo "$iface" | tr -d ' ')
                [ "$include_lo" -eq 0 ] && [ "$iface" = "lo" ] && continue
                local rx tx
                rx=$(echo "$stats" | awk '{print $2}')
                tx=$(echo "$stats" | awk '{print $10}')
                proc_rx=$((proc_rx + rx))
                proc_tx=$((proc_tx + tx))
            done < "$pid_dir/net/dev"
        fi
        echo "$pid $proc_rx $proc_tx"
    done > "$tmpfile"

    local total_rx=0 total_tx=0
    local -A pid_rx_map=() pid_tx_map=() pid_name_map=()

    # 批量获取进程名（使用 ps，比逐个读 /proc/<pid>/cmdline 快且可靠）
    # 输出格式: PID  COMMAND_LINE...
    local -A ps_name_map=()
    while read -r p rest; do
        [ -z "$p" ] && continue
        ps_name_map[$p]="${rest:-unknown}"
    done < <(ps -eo pid=,args= --no-headers 2>/dev/null)

    while read -r pid rx tx; do
        pid_rx_map[$pid]=$rx
        pid_tx_map[$pid]=$tx
        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))
        # 获取进程名：ps → /proc/<pid>/comm → /proc/<pid>/cmdline → unknown
        if [ -n "${ps_name_map[$pid]:-}" ]; then
            pid_name_map[$pid]="${ps_name_map[$pid]}"
        elif [ -r "/proc/$pid/comm" ]; then
            pid_name_map[$pid]=$(cat "/proc/$pid/comm" 2>/dev/null | head -c 50) || pid_name_map[$pid]="unknown"
        elif [ -d "/proc/$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
            pid_name_map[$pid]=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | head -c 50) || pid_name_map[$pid]="unknown"
        else
            pid_name_map[$pid]="unknown"
        fi
    done < "$tmpfile"

    # 按总流量排序取前 N
    local ranked
    ranked=$(awk '{print $1, $2, $3, $2+$3}' "$tmpfile" | sort -k4 -rn | head -n "$top_n")

    # 打印表头
    echo "${BOLD}  排名        进程 (PID)                    接收流量        发送流量        总流量         占比${NC}"
    echo "  ------ ------------------------- ------------ ------------ ------------ ----------"

    local grand_total=$((total_rx + total_tx))

    local rank=0
    while read -r pid rx tx total; do
        [ -z "$pid" ] && continue
        rank=$((rank + 1))
        local name="${pid_name_map[$pid]:-unknown}"
        local pct
        pct=$(calc_pct "$total" "$grand_total")
        local color="$NC"
        [ $rank -le 3 ] && color="$YELLOW"

        echo "${color}  #${rank}         ${name} (${pid})           $(format_bytes $rx)      $(format_bytes $tx)      $(format_bytes $total)      ${pct}${NC}"
    done <<< "$ranked"

    echo ""
    echo "${GREEN}总流量:${NC} ${BOLD}$(format_bytes $grand_total)${NC} (收 $(format_bytes $total_rx) / 发 $(format_bytes $total_tx))"

    rm -f "$tmpfile"
}

# ── 核心功能：按接口排行 ─────────────────────────────────────────────────────

rank_by_interface() {
    local include_lo="${1:-0}"
    local top_n="${2:-10}"

    print_header "📡 网络接口流量排行 (Interface Traffic Ranking)"

    local -a iface_list=()
    if [ "$include_lo" -eq 1 ]; then
        while IFS= read -r line; do
            iface_list+=("$line")
        done < <(awk 'NR>2 {gsub(/:/, "", $1); print $1}' /proc/net/dev)
    else
        while IFS= read -r line; do
            iface_list+=("$line")
        done < <(awk 'NR>2 {gsub(/:/, "", $1); if ($1 != "lo") print $1}' /proc/net/dev)
    fi

    local total_rx=0 total_tx=0
    local -A iface_rx_map=() iface_tx_map=()

    # 读取当前流量
    for iface in "${iface_list[@]}"; do
        local line
        line=$(grep "^ *${iface}:" /proc/net/dev)
        local rx tx
        rx=$(echo "$line" | awk '{print $2}')
        tx=$(echo "$line" | awk '{print $10}')
        iface_rx_map[$iface]=$rx
        iface_tx_map[$iface]=$tx
        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))
    done

    local grand_total=$((total_rx + total_tx))

    # 打印表头
    echo "${BOLD}  接口               接收             发送             总计          收占比       发占比${NC}"
    echo "  --------------- ------------ ------------ ------------ ---------- ----------"

    # 按总流量排序
    local -a sorted_data=()
    while IFS= read -r line; do
        [ -n "$line" ] && sorted_data+=("$line")
    done < <(
        for iface in "${iface_list[@]}"; do
            local rx=${iface_rx_map[$iface]:-0}
            local tx=${iface_tx_map[$iface]:-0}
            local total=$((rx + tx))
            echo "$iface $rx $tx $total"
        done | sort -k4 -rn | head -n "$top_n"
    )

    local rank=0
    for entry in "${sorted_data[@]}"; do
        [ -z "$entry" ] && continue
        rank=$((rank + 1))
        read -r iface rx tx total <<< "$entry"
        local rx_pct tx_pct
        rx_pct=$(calc_pct "$rx" "$grand_total")
        tx_pct=$(calc_pct "$tx" "$grand_total")

        local color="$NC"
        [ $rank -le 3 ] && color="$YELLOW"

        echo "${color}  ${iface}         $(format_bytes $rx)      $(format_bytes $tx)      $(format_bytes $total)      ${rx_pct}      ${tx_pct}${NC}"
    done

    echo ""
    echo "${GREEN}总流量:${NC} ${BOLD}$(format_bytes $grand_total)${NC} (收 $(format_bytes $total_rx) / 发 $(format_bytes $total_tx))"
}

# ── 核心功能：按连接排行 ─────────────────────────────────────────────────────

rank_by_connection() {
    local top_n="${1:-10}"

    print_header "🔗 连接统计排行 (Connection Ranking)"

    local ss_data
    ss_data=$(ss -tanp 2>/dev/null || true)

    if [ -z "$ss_data" ]; then
        echo "${YELLOW}[WARN]${NC} 无法获取连接信息，请确保以 root 运行或使用其他模式"
        echo "${YELLOW}提示:${NC} sudo $0 -m connection"
        return 0
    fi

    local total_conns
    total_conns=$(echo "$ss_data" | tail -n +2 | wc -l)

    echo "$ss_data" | tail -n +2 | awk '{
        split($5, parts, ":")
        ip = parts[1]
        port = parts[length(parts)]
        key = ip ":" port
        count[key]++
        states[key] = $1
    }
    END {
        for (key in count) {
            print count[key], key, states[key]
        }
    }' | sort -k1 -rn | head -n "$top_n" | \
    awk '
    BEGIN {
        printf "  \033[1m  排名            远程地址                    连接数      状态\033[0m\n"
        printf "  ------ ------------------------- ------------ ------\n"
    }
    {
        rank = NR
        ip = $2; port = $3; conns = $1; state = $4
        color = ""
        if (rank <= 3) color = "\033[1;33m"
        printf "  %s  #%-5s %-25s %-12s %s\033[0m\n", color, rank, ip ":" port, conns, state
    }'

    echo ""
    echo "${GREEN}连接总数:${NC} ${BOLD}${total_conns}${NC}"
}

# ── 实时监控模式 ─────────────────────────────────────────────────────────────

monitor_mode() {
    local mode="$1"
    local count="$2"
    local delay="$3"
    local include_lo="0"

    check_root

    trap 'echo ""; echo ""; exit 0' INT TERM

    while true; do
        clear
        echo "${BOLD}${CYAN}┌─ 实时流量监控 (Ctrl+C 退出)${NC}                    ${BOLD}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo "${BOLD}${CYAN}│${NC} 模式: ${BOLD}${mode}                  ${NC}  刷新: ${BOLD}${delay}秒${NC}                    ${BOLD}${CYAN}│${NC}"
        echo "${BOLD}${CYAN}└${CYAN}$(printf '%0.s─' $(seq 1 78))${CYAN}┘${NC}"
        echo ""

        case "$mode" in
            process)
                local tmp1 tmp2
                tmp1=$(mktemp)
                tmp2=$(mktemp)

                for pid_dir in /proc/[0-9]*; do
                    local pid
                    pid=$(basename "$pid_dir")
                    [ "$pid" = "$$" ] && continue
                    [ "$pid" = "$PPID" ] && continue
                    local proc_rx=0 proc_tx=0
                    if [ -f "$pid_dir/net/dev" ]; then
                        while IFS=: read -r iface stats; do
                            iface=$(echo "$iface" | tr -d ' ')
                            [ "$include_lo" -eq 0 ] && [ "$iface" = "lo" ] && continue
                            local rx tx
                            rx=$(echo "$stats" | awk '{print $2}')
                            tx=$(echo "$stats" | awk '{print $10}')
                            proc_rx=$((proc_rx + rx))
                            proc_tx=$((proc_tx + tx))
                        done < "$pid_dir/net/dev"
                    fi
                    echo "$pid $proc_rx $proc_tx"
                done > "$tmp1"

                sleep "$delay"

                for pid_dir in /proc/[0-9]*; do
                    local pid
                    pid=$(basename "$pid_dir")
                    [ "$pid" = "$$" ] && continue
                    [ "$pid" = "$PPID" ] && continue
                    local proc_rx=0 proc_tx=0
                    if [ -f "$pid_dir/net/dev" ]; then
                        while IFS=: read -r iface stats; do
                            iface=$(echo "$iface" | tr -d ' ')
                            [ "$include_lo" -eq 0 ] && [ "$iface" = "lo" ] && continue
                            local rx tx
                            rx=$(echo "$stats" | awk '{print $2}')
                            tx=$(echo "$stats" | awk '{print $10}')
                            proc_rx=$((proc_rx + rx))
                            proc_tx=$((proc_tx + tx))
                        done < "$pid_dir/net/dev"
                    fi
                    echo "$pid $proc_rx $proc_tx"
                done > "$tmp2"

                # 批量获取进程名（ps 比逐个读 /proc/<pid>/cmdline 快且可靠）
                local -A mon_ps_name=()
                while read -r p rest; do
                    [ -z "$p" ] && continue
                    mon_ps_name[$p]="${rest:-unknown}"
                done < <(ps -eo pid=,args= --no-headers 2>/dev/null)

                # 计算差值并排序
                paste "$tmp1" "$tmp2" | awk -v cols=$(wc -l < "$tmp1") '
                { pid[NR]=$1; rx1[NR]=$2; tx1[NR]=$3 }
                NR > cols {
                    idx = NR - cols
                    drx = $2 - rx1[idx]; dtx = $3 - tx1[idx]
                    if (drx < 0) drx = 0; if (dtx < 0) dtx = 0
                    print idx, drx, dtx, drx+dtx
                }' | sort -k4 -rn | head -n "$count" > /tmp/traffic-top-ranked.$$

                # 打印表头
                echo "${BOLD}  排名            进程 (PID)                    接收速率          发送速率          总速率${NC}"
                echo "  ------ ------------------------- --------------- --------------- ------------"

                local rank=0
                while read -r pid drx dtx total; do
                    [ -z "$pid" ] && continue
                    rank=$((rank + 1))
                    local name="${mon_ps_name[$pid]:-unknown}"
                    local color="$NC"
                    [ $rank -le 3 ] && color="$YELLOW"

                    # 格式化速率
                    local fmt_drx fmt_dtx fmt_total
                    fmt_drx=$(format_bytes $drx)
                    fmt_dtx=$(format_bytes $dtx)
                    fmt_total=$(format_bytes $total)

                    echo "${color}  #${rank}         ${name} (${pid})           ${fmt_drx}/s      ${fmt_dtx}/s      ${fmt_total}/s${NC}"
                done < /tmp/traffic-top-ranked.$$

                rm -f "$tmp1" "$tmp2" /tmp/traffic-top-ranked.$$
                ;;
            interface)
                local tmp1
                tmp1=$(mktemp)
                awk 'NR>2 {gsub(/:/, "", $1); print $1, $2, $10}' /proc/net/dev > "$tmp1"
                sleep "$delay"

                awk 'NR>2 {gsub(/:/, "", $1); print $1, $2, $10}' /proc/net/dev | while read -r iface rx tx; do
                    local old_rx old_tx
                    old_rx=$(awk -v i="$iface" '$1==i {print $2}' "$tmp1")
                    old_tx=$(awk -v i="$iface" '$1==i {print $3}' "$tmp1")
                    old_rx=${old_rx:-0}; old_tx=${old_tx:-0}
                    local drx=$((rx - old_rx))
                    local dtx=$((tx - old_tx))
                    [ $drx -lt 0 ] && drx=0
                    [ $dtx -lt 0 ] && dtx=0
                    echo "$iface $drx $dtx"
                done | sort -k3 -rn | head -n "$count" | \
                awk '
                function fmt(b) {
                    if (b >= 1073741824) return sprintf("%.1fG/s", b/1073741824)
                    if (b >= 1048576) return sprintf("%.1fM/s", b/1048576)
                    if (b >= 1024) return sprintf("%.1fK/s", b/1024)
                    return b "/s"
                }
                BEGIN {
                    printf "  \033[1m  接口               接收速率          发送速率          总速率\033[0m\n"
                    printf "  --------------- --------------- --------------- ------------\n"
                }
                { printf "  %-15s %15s %15s %12s\n", $1, fmt($2), fmt($3), fmt($2+$3) }'

                rm -f "$tmp1"
                ;;
            connection)
                echo ""
                echo "${BOLD}当前活跃连接统计:${NC}"
                ss -s 2>/dev/null || echo "  无法获取连接统计"
                echo ""
                ss -tan 2>/dev/null | tail -n +2 | awk '{
                    split($5, parts, ":")
                    count[parts[1]]++
                }
                END {
                    for (ip in count) print count[ip], ip
                }' | sort -rn | head -n "$count" | \
                awk '
                BEGIN {
                    printf "  \033[1m  排名            IP 地址              连接数\033[0m\n"
                    printf "  ------ ------------------------- --------\n"
                }
                { printf "  #%-5s %-25s %s\n", NR, $2, $1 }'
                ;;
        esac

        sleep "$delay"
    done
}

# ── 辅助：显示所有模式 ───────────────────────────────────────────────────────

show_all() {
    local count="$1"
    rank_by_interface "0" "$count"
    echo ""
    rank_by_process "0" "$count"
    echo ""
    rank_by_connection "$count"
}

# ── 参数解析 ────────────────────────────────────────────────────────────────

main() {
    local mode="$MODE"
    local count="$COUNT"
    local delay="$DELAY"

    while [ $# -gt 0 ]; do
        case "$1" in
            -m|--mode) mode="$2"; shift 2 ;;
            -n|--count|--top|-t) count="$2"; shift 2 ;;
            -d|--delay) delay="$2"; shift 2 ;;
            -c|--cumulative) shift ;;
            -i|--include-lo) shift ;;
            -h|--help) show_help; exit 0 ;;
            *) echo "${RED}未知选项: $1${NC}"; echo "使用 -h 查看帮助"; exit 1 ;;
        esac
    done

    case "$mode" in
        process|interface|connection|all) ;;
        *) echo "${RED}无效模式: $mode${NC}"; echo "可选: process, interface, connection, all"; exit 1 ;;
    esac

    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "${RED}count 必须是正整数${NC}"; exit 1
    fi

    check_root

    case "$mode" in
        process) rank_by_process "0" "$count" ;;
        interface) rank_by_interface "0" "$count" ;;
        connection) rank_by_connection "$count" ;;
        all) show_all "$count" ;;
    esac
}

main "$@"
