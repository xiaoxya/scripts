# ⏰ Cron Manager — 定时任务 Web 管理系统

一个基于 Node.js 的 Web 端定时任务管理平台，支持通过浏览器可视化创建、管理、监控定时任务。

## 功能特性

- 📋 **任务管理** — 创建、编辑、删除定时任务
- ⏯ **启停控制** — 随时暂停/恢复任务执行
- 💻 **命令执行** — 支持执行任意 Shell 命令，捕获输出和退出码
- 📊 **实时监控** — 上次运行时间、执行次数、输出日志
- 📈 **统计面板** — 总任务数、运行中、已暂停、执行次数一览
- 💾 **持久化存储** — 数据存 JSON 文件，重启不丢失
- 🌐 **Web UI** — 暗色主题，响应式设计，支持手机端
- 🕐 **时区支持** — 默认 Asia/Shanghai

## 快速开始

### 一键部署（推荐）

```bash
# 进入项目目录
cd projects/cron-manager

# 一键安装并启动
bash setup.sh

# 带参数部署
bash setup.sh --port 8080 --systemd    # 指定端口 + 安装为 systemd 服务
bash setup.sh --port 8080 --user www   # 指定端口 + 以 www 用户运行
```

### 手动安装

```bash
# 安装依赖
npm install

# 启动服务
npm start          # 生产模式
npm run dev        # 开发模式（文件改动自动重启）

# 或自定义端口
PORT=8080 npm start
```

### 访问

浏览器打开 `http://<你的IP>:3000`

## 部署方式

### 方式一：systemd 服务（推荐，生产环境）

```bash
bash setup.sh --systemd
```

管理命令：
```bash
sudo systemctl start cron-manager
sudo systemctl stop cron-manager
sudo systemctl restart cron-manager
sudo systemctl status cron-manager
sudo systemctl enable cron-manager   # 开机自启
```

### 方式二：后台运行

```bash
nohup node server.js > logs/app.log 2>&1 &
```

### 方式三：PM2

```bash
npm install -g pm2
pm2 start server.js --name cron-manager
pm2 save
pm2 startup
```

## 配置

通过环境变量配置：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `PORT` | 监听端口 | `3000` |
| `HOST` | 监听地址 | `0.0.0.0` |
| `NODE_ENV` | 运行环境 | `production` |

```bash
PORT=8080 HOST=0.0.0.0 npm start
```

## Cron 表达式

格式：`分 时 日 月 星期`

| 示例 | 含义 |
|------|------|
| `* * * * *` | 每分钟 |
| `0 * * * *` | 每小时整点 |
| `0 2 * * *` | 每天凌晨 2:00 |
| `0 9 * * 1` | 每周一上午 9:00 |
| `0 0 1 * *` | 每月 1 号凌晨 |
| `0 */2 * * *` | 每 2 小时 |
| `0 0 * * 0` | 每周日午夜 |

时区：`Asia/Shanghai`（中国标准时间）

## 项目结构

```
cron-manager/
├── server.js          # Express 后端 + node-cron 调度
├── package.json       # 项目配置
├── setup.sh           # 一键部署脚本
├── start.sh           # 进程守护启动脚本
├── README.md          # 项目文档
├── data/
│   └── tasks.json     # 任务数据（自动创建）
├── logs/
│   └── app.log        # 运行日志
└── public/
    ├── index.html     # Web 页面
    ├── css/style.css  # 样式
    └── js/app.js      # 前端逻辑
```

## API 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/tasks` | 获取所有任务 |
| POST | `/api/tasks` | 创建任务 |
| PUT | `/api/tasks/:id` | 更新任务 |
| DELETE | `/api/tasks/:id` | 删除任务 |
| GET | `/` | Web 页面 |

### 创建任务请求体

```json
{
  "name": "每日备份数据库",
  "schedule": "0 2 * * *",
  "command": "pg_dump mydb > /backup/db.sql",
  "enabled": true
}
```

## 安全建议

- 生产环境建议加反向代理（Nginx/Caddy）
- 建议配置 HTTPS
- 如需外网访问，考虑加认证或限制 IP

### Nginx 反向代理示例

```nginx
server {
    listen 443 ssl;
    server_name cron.example.com;

    ssl_certificate     /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## 注意事项

- `command` 执行超时 1 小时，输出限制 10MB
- 任务数据存储在 `data/tasks.json`，建议定期备份
- 命令在 `node-cron` 调度器中执行，注意权限和安全风险

## 许可证

MIT
