# Linux 初始化脚本

这个仓库提供一个跨发行版的 Linux 开发机初始化脚本。

## 用法

```bash
chmod +x linux-init.sh
./linux-init.sh
```

只查看将要执行的操作，不修改系统：

```bash
./linux-init.sh --dry-run
```

跳过确认提示：

```bash
./linux-init.sh --yes
```

## 支持的发行版

- Ubuntu / Debian
- Fedora
- CentOS / RHEL / Rocky Linux / AlmaLinux
- Arch Linux / Manjaro

## 功能

- 检测 Linux 发行版和包管理器。
- 更新软件包元数据。
- 安装常见后端开发工具。
- 安装 Docker，优先使用 Docker 官方仓库。
- 通过 `nvm` 安装 Node.js LTS。
- 安装 Python 和 Go 工具链。
- 添加保守的 Shell alias 和 Git 默认配置，不覆盖已有设置。
- 执行低风险安全检查，不自动修改 SSH 或防火墙配置。

脚本默认采用交互式执行。修改默认 Shell、将用户加入 Docker 用户组等可能影响系统行为的操作，都会先要求确认；使用 `--yes` 时除外。
