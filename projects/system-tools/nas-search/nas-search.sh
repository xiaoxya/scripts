#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════╗
# ║  NAS 文件查找工具                                        ║
# ║  支持按名称、内容、大小、日期、类型搜索                    ║
# ║  依赖: find, fzf, grep                                  ║
# ╚══════════════════════════════════════════════════════════╝

# ── 搜索根目录 (默认脚本所在目录, 环境变量 NAS_ROOT 覆盖, 逗号分隔) ──────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IFS=',' read -ra DEFAULT_ROOTS <<< "${NAS_ROOT:-$SCRIPT_DIR}"
SEARCH_ROOTS=("${DEFAULT_ROOTS[@]}")

# ── 颜色 ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; RESET='\033[0m'

# ── 帮助 ──────────────────────────────────────────────────
usage() {
  cat <<'EOF'
用法: nas-search.sh [选项] [搜索词]

选项:
  -n, --name PATTERN    按文件名搜索 (支持通配符)
  -c, --content PATTERN 按文件内容搜索 (grep -i)
  -s, --size RANGE      按大小搜索 (如: 100M, 1G, <10M, >100M)
  -d, --date RANGE      按修改日期搜索 (如: -7d, -30d, -1y)
  -t, --type TYPE       按类型搜索 (image, video, audio, document, archive, code)
  -e, --ext EXT         按扩展名搜索 (如: mp4, pdf, py)
  -f, --full            全文内容搜索 (较慢)
  -o, --output FORMAT   输出: fzf | list | json (默认 fzf)
  -r, --root DIR        搜索根目录, 可多次指定
  -h, --help            显示帮助

示例:
  nas-search.sh                         # 交互式搜索所有文件
  nas-search.sh -n "*.mp4"              # 查找所有 mp4
  nas-search.sh -c "TODO"               # 按内容搜索
  nas-search.sh -s ">100M"              # 大于 100MB
  nas-search.sh -d -7d                  # 7天内修改
  nas-search.sh -t video                # 所有视频
  nas-search.sh -e .py                  # 所有 python
  nas-search.sh -r /data -r /mnt -n "report"  # 多目录

搜索类型 (-t):
  image    图片: jpg, png, gif, bmp, webp, svg
  video    视频: mp4, mkv, avi, mov, wmv
  audio    音频: mp3, wav, flac, aac, ogg
  document 文档: pdf, doc, docx, xls, xlsx, txt, md
  archive  压缩包: zip, rar, 7z, tar, gz, bz2
  code     代码: py, js, ts, go, rs, java, sh, yaml, json
EOF
  exit 0
}

# ── 工具函数 ──────────────────────────────────────────────
err() { echo -e "${RED}✗ $*${RESET}" >&2; }
info() { echo -e "${GREEN}✓ $*${RESET}"; }
warn() { echo -e "${YELLOW}! $*${RESET}"; }

fmt_size() {
  local bytes=$1
  if   (( bytes >= 1073741824 )); then awk "BEGIN{printf \"%.1fG\", $bytes/1073741824}"
  elif (( bytes >= 1048576 ));    then awk "BEGIN{printf \"%.1fM\", $bytes/1048576}"
  elif (( bytes >= 1024 ));       then awk "BEGIN{printf \"%.1fK\", $bytes/1024}"
  else echo "${bytes}B"; fi
}

fmt_time() {
  date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown"
}

get_file_type() {
  case "$1" in
    *.jpg|*.jpeg|*.png|*.gif|*.bmp|*.webp|*.svg|*.ico|*.tiff) echo "image" ;;
    *.mp4|*.mkv|*.avi|*.mov|*.wmv|*.flv|*.webm) echo "video" ;;
    *.mp3|*.wav|*.flac|*.aac|*.ogg|*.wma|*.m4a) echo "audio" ;;
    *.pdf|*.doc|*.docx|*.xls|*.xlsx|*.ppt|*.pptx|*.txt|*.md|*.epub) echo "document" ;;
    *.zip|*.rar|*.7z|*.tar|*.gz|*.bz2|*.xz|*.tgz) echo "archive" ;;
    *.py|*.js|*.ts|*.go|*.rs|*.java|*.c|*.cpp|*.sh|*.yaml|*.yml|*.json|*.xml) echo "code" ;;
    *) echo "other" ;;
  esac
}

# ── 参数解析 ──────────────────────────────────────────────
NAME_PATTERN=""
CONTENT_PATTERN=""
SIZE_FILTER=""
DATE_FILTER=""
TYPE_FILTER=""
EXT_FILTER=""
FULL_TEXT=false
OUTPUT_MODE="fzf"
SEARCH_ROOTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)    NAME_PATTERN="$2"; shift 2 ;;
    -c|--content) CONTENT_PATTERN="$2"; shift 2 ;;
    -s|--size)    SIZE_FILTER="$2"; shift 2 ;;
    -d|--date)    DATE_FILTER="$2"; shift 2 ;;
    -t|--type)    TYPE_FILTER="$2"; shift 2 ;;
    -e|--ext)     EXT_FILTER="$2"; shift 2 ;;
    -f|--full)    FULL_TEXT=true; shift ;;
    -o|--output)  OUTPUT_MODE="$2"; shift 2 ;;
    -r|--root)    SEARCH_ROOTS+=("$2"); shift 2 ;;
    -h|--help)    usage ;;
    -*)           err "未知选项: $1"; usage ;;
    *)            NAME_PATTERN="$1"; shift ;;
  esac
done

# 默认根目录
if [[ ${#SEARCH_ROOTS[@]} -eq 0 ]]; then
  SEARCH_ROOTS=("${DEFAULT_ROOTS[@]}")
fi

# ── 构建 find 命令字符串 ──────────────────────────────────
build_find_cmd() {
  local cmd="find"

  # 验证根目录
  local valid_roots=()
  for root in "${SEARCH_ROOTS[@]}"; do
    if [[ ! -d "$root" ]]; then
      warn "目录不存在, 跳过: $root"
      continue
    fi
    valid_roots+=("$root")
  done

  if [[ ${#valid_roots[@]} -eq 0 ]]; then
    err "没有有效的搜索目录"
    exit 1
  fi

  cmd="$cmd ${valid_roots[*]}"

  # 排除目录
  cmd="$cmd -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' -not -path '*/.DS_Store' -not -path '*/Thumbs.db'"

  # 名称搜索
  if [[ -n "$NAME_PATTERN" ]]; then
    cmd="$cmd -name \"$NAME_PATTERN\""
  fi

  # 扩展名搜索
  if [[ -n "$EXT_FILTER" ]]; then
    local ext="$EXT_FILTER"
    [[ "$ext" != .* ]] && ext=".$ext"
    cmd="$cmd -name \"*${ext}\""
  fi

  # 文件类型过滤
  if [[ -n "$TYPE_FILTER" ]]; then
    case "$TYPE_FILTER" in
      image)    cmd="$cmd -regex '.*\.\(jpg\|jpeg\|png\|gif\|bmp\|webp\|svg\|ico\|tiff\)'" ;;
      video)    cmd="$cmd -regex '.*\.\(mp4\|mkv\|avi\|mov\|wmv\|flv\|webm\)'" ;;
      audio)    cmd="$cmd -regex '.*\.\(mp3\|wav\|flac\|aac\|ogg\|wma\|m4a\)'" ;;
      document) cmd="$cmd -regex '.*\.\(pdf\|doc\|docx\|xls\|xlsx\|ppt\|pptx\|txt\|md\|epub\)'" ;;
      archive)  cmd="$cmd -regex '.*\.\(zip\|rar\|7z\|tar\|gz\|bz2\|xz\|tgz\)'" ;;
      code)     cmd="$cmd -regex '.*\.\(py\|js\|ts\|go\|rs\|java\|c\|cpp\|sh\|yaml\|yml\|json\|xml\)'" ;;
      *)        warn "未知类型: $TYPE_FILTER" ;;
    esac
  fi

  # 大小过滤
  if [[ -n "$SIZE_FILTER" ]]; then
    local size_val="${SIZE_FILTER}"
    # 去掉 < > 符号
    size_val="${size_val#<}"
    size_val="${size_val#>}"
    # 如果末尾没有单位, 默认 M
    if [[ "$size_val" != *M && "$size_val" != *G && "$size_val" != *K && "$size_val" != *c ]]; then
      size_val="${size_val}M"
    fi
    case "$SIZE_FILTER" in
      \<*) cmd="$cmd -size \"-${size_val}\"" ;;
      \>*) cmd="$cmd -size \"+${size_val}\"" ;;
      *)   cmd="$cmd -size \"${size_val}\"" ;;
    esac
  fi

  # 日期过滤
  if [[ -n "$DATE_FILTER" ]]; then
    local days=""
    case "$DATE_FILTER" in
      *[0-9]d) days="${DATE_FILTER%d}" ;;
      *[0-9]w) days=$(( ${DATE_FILTER%w} * 7 )) ;;
      *[0-9]m) days=$(( ${DATE_FILTER%m} * 30 )) ;;
      *[0-9]y) days=$(( ${DATE_FILTER%y} * 365 )) ;;
      *)       days="$DATE_FILTER" ;;
    esac
    # days 可能已有负号 (如 -7), 避免重复
    [[ "$days" == -* ]] && cmd="$cmd -mtime $days" || cmd="$cmd -mtime -$days"
  fi

  # 只找文件 + 输出格式: timestamp size filepath
  cmd="$cmd -type f -printf '%T@ %s %p\\n'"

  echo "$cmd"
}

# ── 内容搜索 ─────────────────────────────────────────────
content_search() {
  local pattern="$1"
  info "正在搜索内容: ${BOLD}$pattern${RESET}"
  echo ""

  local find_cmd
  find_cmd=$(build_find_cmd)

  local count=0
  while IFS= read -r line; do
    local filepath="${line#* }"
    filepath="${filepath#* }"
    local matches
    matches=$(grep -ci "$pattern" "$filepath" 2>/dev/null || true)
    if [[ "$matches" -gt 0 ]]; then
      echo -e "${BLUE}$filepath${RESET} (${GREEN}${matches} matches${RESET})"
      (( count++ )) || true
    fi
  done <<< "$(eval "$find_cmd" 2>/dev/null)"

  echo ""
  info "找到 ${BOLD}$count${RESET} 个文件"
}

# ── 主搜索 ───────────────────────────────────────────────
main_search() {
  local find_cmd
  find_cmd=$(build_find_cmd)

  local results
  results=$(eval "$find_cmd" 2>/dev/null)

  if [[ -z "$results" ]]; then
    warn "没有找到匹配的文件"
    exit 0
  fi

  case "$OUTPUT_MODE" in
    fzf)
      echo "$results" | fzf --ansi \
        --preview 'line="{}"; filepath="${line#* }"; filepath="${filepath#* }"; if [[ -f "$filepath" ]]; then stat -c "大小: %s bytes | 修改: %y" "$filepath" 2>/dev/null; fi' \
        --preview-window=right:60% \
        --header="按 Enter 复制路径 | 方向键选择" \
        --prompt="搜索: " \
        --filter="$NAME_PATTERN" 2>/dev/null | while IFS= read -r selected; do
          filepath="${selected#* }"
          filepath="${filepath#* }"
          echo "$filepath"
        done
      ;;
    list)
      while IFS= read -r line; do
        local timestamp size filepath
        timestamp=$(echo "$line" | cut -d' ' -f1)
        size=$(echo "$line" | cut -d' ' -f2)
        filepath=$(echo "$line" | cut -d' ' -f3-)

        local human_size human_time ftype
        human_size=$(fmt_size "$size")
        human_time=$(fmt_time "$timestamp")
        ftype=$(get_file_type "$filepath")

        case "$ftype" in
          image)    echo -e "${GREEN}[$human_size] $human_time  $filepath${RESET}" ;;
          video)    echo -e "${MAGENTA}[$human_size] $human_time  $filepath${RESET}" ;;
          audio)    echo -e "${CYAN}[$human_size] $human_time  $filepath${RESET}" ;;
          code)     echo -e "${BLUE}[$human_size] $human_time  $filepath${RESET}" ;;
          *)        echo -e "[$human_size] $human_time  $filepath" ;;
        esac
      done <<< "$results"
      ;;
    json)
      echo "["
      local first=true
      while IFS= read -r line; do
        local timestamp size filepath
        timestamp=$(echo "$line" | cut -d' ' -f1)
        size=$(echo "$line" | cut -d' ' -f2)
        filepath=$(echo "$line" | cut -d' ' -f3-)

        [[ "$first" == "true" ]] || echo ","
        first=false

        local human_size human_time
        human_size=$(fmt_size "$size")
        human_time=$(fmt_time "$timestamp")

        printf '  {"path": "%s", "size": "%s", "modified": "%s", "bytes": %s}\n' \
          "$filepath" "$human_size" "$human_time" "$size"
      done <<< "$results"
      echo "]"
      ;;
  esac
}

# ── 主入口 ───────────────────────────────────────────────
main() {
  # 内容搜索
  if [[ -n "$CONTENT_PATTERN" ]]; then
    content_search "$CONTENT_PATTERN"
    exit 0
  fi

  # 全文搜索
  if [[ "$FULL_TEXT" == true && -n "$NAME_PATTERN" ]]; then
    info "全文搜索: ${BOLD}$NAME_PATTERN${RESET} (可能需要一些时间...)"
    echo ""
    local find_cmd
    find_cmd=$(build_find_cmd)
    eval "$find_cmd" 2>/dev/null | while IFS= read -r line; do
      filepath="${line#* }"
      filepath="${filepath#* }"
      grep -qi "$NAME_PATTERN" "$filepath" 2>/dev/null && echo -e "${BLUE}$filepath${RESET}"
    done
    exit 0
  fi

  # 普通搜索
  main_search
}

main
