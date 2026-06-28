# llama.cpp 交互式部署脚本

通过**对话引导**完成 llama.cpp 环境检测 → CUDA 安装 → 源码编译 → 后续更新。

## 功能

- **交互式菜单** — 每一步都有清晰选项，不用记参数
- **自动检测包管理器** — pacman / apt / dnf / yum / zypper
- **CUDA 检测与安装引导** — 检测到 GPU 自动启用 CUDA 编译
- **GPU 架构选择** — 自动检测 / 手动指定 / 最小集合
- **增量更新** — 菜单中直接选更新，自动拉取最新源码
- **systemd 服务** — 后台自启 llama-server，开机自动运行
- **自定义设置** — 随时修改安装目录、并行数、CMake 选项
- **卸载** — 清理所有安装文件

## 快速开始

```bash
# 交互式部署 (推荐)
bash deploy.sh
```

## 主菜单

```
╔══════════════════════════════════════════════╗
║        llama.cpp 交互式部署        ║
╚══════════════════════════════════════════════╝

  系统: Linux x86_64
  包管理器: pacman
  安装目录: /opt/llama.cpp
  CPU 核心: 16

  1) 全新安装    → 克隆源码 → 检测 CUDA → 编译安装
  2) 增量更新    → 拉取最新源码 → 重新编译
  3) 仅编译      → 源码已存在，直接编译
  4) CUDA 设置   → 查看 CUDA 状态 / 切换开关
  5) 自定义设置  → 安装目录 / 编译数 / CMake 选项
  6) 验证安装    → 检查已安装组件
  7) 卸载        → 删除所有安装文件
  8) systemd 服务 → 安装/启动/管理后台服务
  0) 退出
```

## 安装流程

```
1. 输入安装目录 (默认 /opt/llama.cpp)
2. 选择编译模式 (CUDA / CPU)
3. 选择 GPU 架构 (自动 / 手动 / 最小集合)
4. 输入并行编译数 (默认 nproc)
5. 确认后自动执行
```

### GPU 架构速查

| 架构 | GPU 型号 |
|------|----------|
| AD102 | RTX 4090 / 4080 |
| GA102 | RTX 3090 / 3080 |
| GA100 | A100 |
| TU102 | RTX 2080 Ti |
| GA10B | L40 / L40S |

多个架构用分号分隔：`AD102;GA102`

## 使用

```bash
# 加载环境
source /opt/llama.cpp/env.sh

# CLI 推理
llama-cli -m model.gguf -p "你好，请介绍自己"

# 启动 API 服务器
llama-server -m model.gguf --host 0.0.0.0 --port 8080

# 量化
llama-quantize model.gguf model-q4_k_m.gguf Q4_K_M

# 其他工具
llama-bench          # 性能基准测试
llama-eval-cache     # 评估缓存
```

## systemd 服务

### 菜单操作

```
1) 安装服务    → 生成 unit 文件 + 配置文件
2) 启动服务
3) 停止服务
4) 重启服务
5) 查看状态
6) 开机自启
7) 取消自启
8) 编辑配置
9) 卸载服务
```

### 手动管理

```bash
sudo systemctl start llama-server    # 启动
sudo systemctl stop llama-server     # 停止
sudo systemctl restart llama-server  # 重启
sudo systemctl status llama-server   # 状态
sudo systemctl enable llama-server   # 开机自启
sudo systemctl disable llama-server  # 取消自启
```

### 查看日志

```bash
journalctl -u llama-server -f        # 实时日志
journalctl -u llama-server --since "1 hour ago"  # 最近日志
```

### 配置文件

```
/opt/llama.cpp/etc/server.conf
```

```bash
# 模型路径 (绝对路径)
LLAMA_MODEL="/opt/llama.cpp/models/llama-3.1-8b-instruct-q4_k_m.gguf"

# 额外参数 (可选)
# LLAMA_EXTRA_ARGS="--host 0.0.0.0 --port 8080 --threads 16 --ctx-size 4096 --gpu-layers 35"
```

**常用启动参数：**

| 参数 | 说明 | 示例 |
|------|------|------|
| `--host` | 监听地址 | `0.0.0.0` |
| `--port` | 端口号 | `8080` |
| `--threads` | CPU 线程数 | `16` |
| `--ctx-size` | 上下文长度 | `4096` / `8192` |
| `--gpu-layers` | GPU 加载层数 | `35` (全部) |
| `--batch-size` | 批处理大小 | `512` |
| `--embedding` | 启用嵌入 | (布尔值) |

## 安装目录

```
/opt/llama.cpp/
├── bin/           # 可执行文件 + 环境变量
│   ├── llama-cli
│   ├── llama-server
│   ├── llama-quantize
│   ├── llama-bench
│   └── ...
├── env.sh         # source 即可使用
├── etc/           # systemd 配置
│   └── server.conf
└── build/         # 构建目录 (可安全删除)
```

systemd unit 文件：`/etc/systemd/system/llama-server.service`

## 支持系统

| 系统 | 包管理器 |
|------|----------|
| Arch Linux | pacman |
| Ubuntu/Debian | apt |
| RHEL/Fedora/CentOS | dnf / yum |
| openSUSE | zypper |

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `LLAMA_CPP_DIR` | 安装目录 | `/opt/llama.cpp` |
| `LLAMA_CPP_CUDA_ARCHS` | GPU 架构 | 空 (自动) |
| `LLAMA_CPP_MAKE_JOBS` | 编译并行数 | `nproc` |
| `SKIP_CUDA` | 跳过 CUDA 安装 | 空 |
| `SKIP_UPDATE` | 跳过更新检查 | 空 |

## 故障排查

### 编译失败

```bash
# 查看完整日志
cat /opt/llama.cpp/build/CMakeFiles/CMakeOutput.log
```

### CUDA 未启用

```bash
# 检查 CUDA 是否可用
nvidia-smi
nvcc --version

# 检查 llama-server 是否支持 CUDA
llama-server --help | grep -i cuda
```

### 服务启动失败

```bash
# 查看详细错误
journalctl -u llama-server -n 50 --no-pager

# 检查配置文件
cat /opt/llama.cpp/etc/server.conf

# 检查模型文件是否存在
ls -lh /opt/llama.cpp/models/*.gguf
```

### 内存不足

```bash
# 减少 GPU 加载层数
# LLAMA_EXTRA_ARGS="--gpu-layers 20"

# 减少上下文大小
# LLAMA_EXTRA_ARGS="--ctx-size 2048"
```
