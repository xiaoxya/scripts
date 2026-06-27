# Ventoy Flat Catppuccin (中文本地化版)

基于 [Ventoy-Flat-Catppuccin](https://github.com/KindaSuS1368/Ventoy-Flat-Catppuccin) 的中文本地化主题。

## 改动

- **字体**：使用 **Noto Sans Mono CJK SC**（思源黑体等宽）替代 Comic Mono，支持简体中文显示
- **菜单**：保持原版布局，但所有文本元素使用支持 CJK 的字体
- **配色**：保留 Catppuccin Mocha (Blue) 配色方案

## 安装步骤

### 1. 下载 TTF 字体

从 [life888888/cjk-fonts-ttf](https://github.com/life888888/cjk-fonts-ttf/releases/tag/v0.1.0) 下载：
- `NotoSansMonoCJK-SC.zip` → 解压得到 `NotoSansMonoCJKsc-Regular.ttf`

### 2. 转换字体为 pf2 格式

需要 `grub-mkfont` 工具（来自 `grub` 包）：

```bash
# Ubuntu/Debian
sudo apt install grub-pc-bin
sudo grub-mkfont -s 24 -o NotoSansMonoCJKsc-24.pf2 NotoSansMonoCJKsc-Regular.ttf

# Arch Linux
sudo pacman -S grub
sudo grub-mkfont -s 24 -o NotoSansMonoCJKsc-24.pf2 NotoSansMonoCJKsc-Regular.ttf

# Fedora/RHEL
sudo dnf install grub2-common
sudo grub2-mkfont -s 24 -o NotoSansMonoCJKsc-24.pf2 NotoSansMonoCJKsc-Regular.ttf
```

### 3. 部署到 U 盘

```bash
# 把 theme-vfc-cn 文件夹复制到 U 盘的 /ventoy/themes/ 目录
cp -r theme-vfc-cn /path/to/ventoy-usb/ventoy/themes/

# 把转换好的 pf2 字体文件也复制进去
cp NotoSansMonoCJKsc-24.pf2 /path/to/ventoy-usb/ventoy/themes/theme-vfc-cn/
```

### 4. 配置 Ventoy

修改 U 盘根目录的 `ventoy.json`，添加以下内容：

```json
{
 "theme": {
  "file": [
   "/ventoy/themes/theme-vfc-cn/theme.txt"
  ],
  "fonts": [
   "/ventoy/themes/theme-vfc-cn/NotoSansMonoCJKsc-24.pf2"
  ],
  "gfxmode": "max"
 }
}
```

### 5. 重启

插入 U 盘启动，即可看到中文菜单。

## 文件结构

```
theme-vfc-cn/
├── theme.txt                          # 主题配置（已本地化）
├── background.jpg                     # 背景图
├── title.png                          # 标题图
├── info.png                           # 信息面板
├── crust.png                          # 顶部/底部色条
├── mantle.png                         # 菜单背景
├── base.png                           # 信息区背景
├── blue_c.png                         # 选中项高亮
├── surface0_c.png                     # 滚动条
├── ComicMono.pf2                      # 原版字体（保留）
├── NotoSansMonoCJKsc-Regular.ttf      # 中文字体 TTF（需自行下载）
├── NotoSansMonoCJKsc-24.pf2           # 转换后的 pf2 字体（安装时生成）
└── README.md                          # 本文件
```

## 注意事项

- 需要 **1280×720 或更高**分辨率
- 在高分屏上元素可能偏小
- 底部状态栏的模式指示器（Memdisk、UEFI FS 等）需要在 Ventoy 中启用对应模式才会显示（按 F1 查看说明）
- `grub-mkfont` 需要 root 权限

## 许可证

- 主题配置：MIT License（继承自原版）
- 字体：Noto Sans Mono CJK SC 采用 SIL Open Font License 1.1
- Catppuccin 配色：MIT License
