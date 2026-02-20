# MoviePilot 一键安装与管理脚本

这是一个用于一键安装、更新、卸载和管理 [MoviePilot](https://github.com/jxxghp/MoviePilot)（包括前端、插件和资源）的 Bash 脚本。
它专门适配了 Debian 13 (Trixie)，会自动配置好隔离的虚拟环境并将前后端合并为一个 Systemd 守护服务（`moviepilot.service`），方便日常维护。

## 一键运行

你可以直接使用以下单行命令下载并运行该管理脚本：

```bash
bash <(curl -s https://raw.githubusercontent.com/qimaoaa/moviepilot-installer/refs/heads/main/moviepilot_manager.sh)
```

## 功能特点
- **环境自动补丁**：检测系统版本，针对 Debian 13 自动下载 Python 3.12 独立运行环境，无需手动编译。
- **配置管理**：支持交互式设置监听地址（IP）、前端端口和后端端口，并可随时通过菜单修改。
- **资源自动整合**：严格遵循官方最新流程，自动从 `MoviePilot-Resources` 同步 v2 版资源。
- **统一服务模式**：前后端合并为一个名为 `moviepilot` 的服务，支持自动就绪检测和异常互杀重启。
- **稳定静态模式**：前端采用 `npm run build` + `node dist/service.js` 生产环境运行，并修复了 CommonJS 兼容性。
- **系统诊断**：内置一键诊断工具，自动检查端口占用、服务状态和关键日志。
- **强力更新**：支持一键强制同步云端代码，自动识别并重置到远程 HEAD 分支。
- **安全加固**：后端强制绑定 127.0.0.1，前端支持锁定 IPv4 地址以防止 IPv6 越权访问。
