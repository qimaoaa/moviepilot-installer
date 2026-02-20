# MoviePilot 一键安装与管理脚本

这是一个用于一键安装、更新、卸载和管理 [MoviePilot](https://github.com/jxxghp/MoviePilot)（包括前端和插件）的 Bash 脚本。
它会自动配置好环境并将前后端合并为一个 Systemd 守护服务（`moviepilot.service`），方便日常维护。

## 一键运行

你可以直接使用以下单行命令下载并运行该管理脚本：

```bash
bash <(curl -s https://raw.githubusercontent.com/qimaoaa/moviepilot-installer/refs/heads/main/moviepilot_manager.sh)
```

## 功能特点
- **环境自动安装**：检测并自动安装 Python 3.12 和 Node.js v20。
- **配置交互**：安装时可自定义监听地址（IP）、前端端口和后端端口。
- **统一服务**：前后端合并为一个名为 `moviepilot` 的 systemctl 服务，互相守护。
- **一键更新**：通过菜单选项，自动拉取最新代码并更新依赖。
- **日志与状态**：内置命令查看运行状态、实时日志、重启或完全卸载。