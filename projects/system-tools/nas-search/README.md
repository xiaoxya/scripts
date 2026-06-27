# NAS 文件查找工具

快速查找 NAS 文件，支持名称、内容、大小、日期、类型等多种搜索方式。

## 依赖

- `find`（通常系统自带）
- `fzf`（交互式搜索，可选）
- `grep`（内容搜索，可选）

## 安装

```bash
# 脚本已在 scripts/ 目录，可直接使用
chmod +x ./scripts/nas-search.sh
```

## 基本用法

```bash
# 交互式搜索（默认，需要 fzf）
./nas-search.sh

# 指定搜索目录
./nas-search.sh -r /data -r /mnt

# 默认搜索脚本所在目录
./nas-search.sh
```

## 搜索方式

### 按文件名

```bash
# 通配符匹配
./nas-search.sh -n "*.mp4"
./nas-search.sh -n "*report*2026*"

# 指定目录
./nas-search.sh -r /data -n "budget.xlsx"
```

### 按文件内容

```bash
# 在文件中搜索文本（grep -i）
./nas-search.sh -c "TODO"
./nas-search.sh -c "password" -r /home/mo/config
```

### 按文件大小

```bash
# 大于 100MB
./nas-search.sh -s ">100M"

# 小于 1MB
./nas-search.sh -s "<1M"

# 精确大小（单位: K/M/G/c=bytes）
./nas-search.sh -s "10M"
./nas-search.sh -s "500K"
```

### 按修改日期

```bash
# 7 天内修改
./nas-search.sh -d -7d

# 30 天内
./nas-search.sh -d -30d

# 1 年内
./nas-search.sh -d -1y
```

### 按文件类型

| 类型 | 说明 | 匹配扩展名 |
|------|------|-----------|
| `image` | 图片 | jpg, png, gif, bmp, webp, svg, ico, tiff |
| `video` | 视频 | mp4, mkv, avi, mov, wmv, flv, webm |
| `audio` | 音频 | mp3, wav, flac, aac, ogg, wma, m4a |
| `document` | 文档 | pdf, doc, docx, xls, xlsx, ppt, pptx, txt, md, epub |
| `archive` | 压缩包 | zip, rar, 7z, tar, gz, bz2, xz, tgz |
| `code` | 代码 | py, js, ts, go, rs, java, c, cpp, sh, yaml, yml, json, xml |

```bash
./nas-search.sh -t video
./nas-search.sh -t code -r /home/mo/projects
```

### 按扩展名

```bash
# 支持带或不带点号
./nas-search.sh -e .py
./nas-search.sh -e mp4
```

## 输出格式

```bash
# fzf 交互式（默认）- 方向键选择，Enter 复制路径
./nas-search.sh -o fzf

# 列表模式 - 带颜色，适合管道
./nas-search.sh -o list

# JSON 格式 - 适合程序处理
./nas-search.sh -o json | jq .
```

## 组合使用

```bash
# 找 7 天内修改的、大于 50MB 的视频
./nas-search.sh -t video -s ">50M" -d -7d

# 在 /data 目录搜索包含 "TODO" 的 Python 文件
./nas-search.sh -r /data -c "TODO" -e .py

# 找所有大于 1GB 的压缩包
./nas-search.sh -t archive -s ">1G" -o list

# 全文搜索（较慢）
./nas-search.sh -f "important keyword"
```

## 环境变量

```bash
# 设置默认搜索目录（逗号分隔多个）
export NAS_ROOT="/data,/mnt,/home/mo"
./nas-search.sh

# 调试模式
DEBUG=1 ./nas-search.sh -n "*.log"
```

## 排除目录

默认排除：`.git`、`node_modules`、`__pycache__`、`.DS_Store`、`Thumbs.db`

## 快捷键（fzf 模式）

| 按键 | 功能 |
|------|------|
| `↑` / `↓` | 选择文件 |
| `Enter` | 复制文件路径到剪贴板 |
| `Ctrl+R` | 实时过滤 |

## 示例

```bash
# 找最大的 10 个文件
./nas-search.sh -o list | sort -r | head -10

# 找所有视频并统计大小
./nas-search.sh -t video -o list | wc -l

# 在项目中找所有配置文件
./nas-search.sh -t code -r /home/mo/projects -o json | jq '.[].path'

# 找 30 天内修改的 Markdown 文件
./nas-search.sh -e .md -d -30d -o list
```
