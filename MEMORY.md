# MEMORY.md - Long-Term Memory

## Workspace Convention

- **Each project gets its own folder** — never drop files in workspace root
- Generated files go into a dedicated project folder (e.g., `traffic-top/`)
- Only workspace-level config files (AGENTS.md, SOUL.md, TOOLS.md, etc.) stay in root

## Projects

### traffic-top
- Linux 网络流量使用排行查询脚本
- 4 种模式：process / interface / connection / all
- 实时监控、彩色输出、流量占比
