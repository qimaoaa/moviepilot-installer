#!/bin/bash

# 需要 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 sudo 或 root 用户运行此脚本。"
  exit 1
fi

INSTALL_DIR="/opt/MoviePilot"
SERVICE_NAME="moviepilot.service"
CONFIG_FILE="$INSTALL_DIR/mp_config.env"

# 通用的执行并检测错误的函数
run_task() {
    local msg="$1"
    local cmd="$2"
    
    while true; do
        echo -e "\n$msg"
        if eval "$cmd"; then
            return 0
        else
            echo "❌ 任务执行失败！"
            read -p "按 [R] 重新尝试，或按 [M] 取消并返回主菜单: " action
            case "$action" in
                [rR])
                    echo ">>> 正在重试..."
                    ;;
                [mM])
                    echo ">>> 已取消当前操作，返回主菜单。"
                    sleep 1
                    return 1
                    ;;
                *)
                    echo "无效输入，默认返回主菜单..."
                    sleep 1
                    return 1
                    ;;
            esac
        fi
    done
}

install_mp() {
    echo ">>> 开始安装 MoviePilot..."
    
    read -p "请输入监听地址 (默认 0.0.0.0): " LISTEN_ADDR
    LISTEN_ADDR=${LISTEN_ADDR:-0.0.0.0}
    
    read -p "请输入前端服务端口 (默认 3000): " FRONTEND_PORT
    FRONTEND_PORT=${FRONTEND_PORT:-3000}
    
    read -p "请输入后端服务端口 (默认 3001): " BACKEND_PORT
    BACKEND_PORT=${BACKEND_PORT:-3001}
    
    # 1. 环境检测与自动安装
    if ! command -v git &> /dev/null; then
        run_task ">>> 准备自动安装 Git..." "apt-get update && apt-get install -y git" || return 1
    fi
    
    if ! command -v python3 &> /dev/null || ! python3 -m venv -h &> /dev/null; then
        run_task ">>> 准备自动补全 Python 3 及其 venv 模块..." "apt-get update && apt-get install -y curl python3 python3-venv python3-dev" || return 1
    else
        echo "[✓] 检测到 Python 3 及其 venv 模块已安装"
    fi

    local NODE_INSTALLED=false
    if command -v node &> /dev/null; then
        local NODE_VER=$(node -v | grep -oE '[0-9]+' | head -1)
        if [ "$NODE_VER" -eq 20 ]; then
            NODE_INSTALLED=true
        fi
    fi

    if [ "$NODE_INSTALLED" = false ]; then
        run_task ">>> 准备自动安装 Node.js v20..." "apt-get remove -y nodejs npm || true; curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs && npm install -g yarn" || return 1
    else
        echo "[✓] 检测到 Node.js v20 已安装"
    fi

    # 2. 克隆源代码
    mkdir -p "$INSTALL_DIR"
    
    cat > "$CONFIG_FILE" <<EOF
LISTEN_ADDR=$LISTEN_ADDR
FRONTEND_PORT=$FRONTEND_PORT
BACKEND_PORT=$BACKEND_PORT
EOF

    cd "$INSTALL_DIR"

    if [ ! -d "MoviePilot" ]; then
        run_task ">>> 克隆主项目 MoviePilot..." "git clone https://github.com/jxxghp/MoviePilot.git" || return 1
    fi
    if [ ! -d "MoviePilot-Plugins" ]; then
        run_task ">>> 克隆插件项目 MoviePilot-Plugins..." "git clone https://github.com/jxxghp/MoviePilot-Plugins.git" || return 1
    fi
    if [ ! -d "MoviePilot-Frontend" ]; then
        run_task ">>> 克隆前端项目 MoviePilot-Frontend..." "git clone https://github.com/jxxghp/MoviePilot-Frontend.git" || return 1
    fi
    if [ ! -d "MoviePilot-Resources" ]; then
        run_task ">>> 克隆资源项目 MoviePilot-Resources..." "git clone https://github.com/jxxghp/MoviePilot-Resources.git" || return 1
    fi

    # 3. 文件整合
    echo ">>> 正在整合文件..."
    mkdir -p MoviePilot/app/plugins
    mkdir -p MoviePilot-Frontend/public/plugin_icon
    mkdir -p MoviePilot/app/helper

    cp -rf MoviePilot-Plugins/plugins/* MoviePilot/app/plugins/ 2>/dev/null || true
    cp -rf MoviePilot-Plugins/icons/* MoviePilot-Frontend/public/plugin_icon/ 2>/dev/null || true
    cp -rf MoviePilot-Resources/resources.v2/* MoviePilot/app/helper/ 2>/dev/null || true

    # 4. 安装依赖
    if [ ! -d "$INSTALL_DIR/MoviePilot/venv" ]; then
        run_task ">>> 正在创建 Python 虚拟环境..." "cd '$INSTALL_DIR/MoviePilot' && python3 -m venv venv" || return 1
    fi
    
    # 升级虚拟环境内的 pip 后再安装依赖
    run_task ">>> 正在安装后端依赖..." "cd '$INSTALL_DIR/MoviePilot' && ./venv/bin/python3 -m pip install --upgrade pip && ./venv/bin/python3 -m pip install -r requirements.txt" || return 1

    run_task ">>> 正在安装前端依赖..." "cd '$INSTALL_DIR/MoviePilot-Frontend' && npm install" || return 1

    # 5. 创建启动脚本
    cat > "$INSTALL_DIR/start_all.sh" << 'EOF'
#!/bin/bash
source /opt/MoviePilot/mp_config.env

echo "启动 MoviePilot 后端 (监听 $LISTEN_ADDR:$BACKEND_PORT)..."
cd /opt/MoviePilot/MoviePilot
export HOST=$LISTEN_ADDR
export PORT=$BACKEND_PORT
export WEB_PORT=$BACKEND_PORT
PYTHONPATH=. ./venv/bin/python3 app/main.py &
BACKEND_PID=$!

echo "启动 MoviePilot 前端 (监听 $LISTEN_ADDR:$FRONTEND_PORT)..."
cd /opt/MoviePilot/MoviePilot-Frontend
export HOST=$LISTEN_ADDR
export PORT=$FRONTEND_PORT
export VITE_PORT=$FRONTEND_PORT
npm run dev &
FRONTEND_PID=$!

trap "kill $BACKEND_PID $FRONTEND_PID 2>/dev/null; exit" SIGINT SIGTERM
wait -n
kill $BACKEND_PID $FRONTEND_PID 2>/dev/null
exit 1
EOF
    chmod +x "$INSTALL_DIR/start_all.sh"

    # 6. 配置 Systemd
    cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=MoviePilot (Frontend + Backend)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/start_all.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME

    echo ">>> 安装完成！服务已启动。"
    echo ">>> 后端: http://$LISTEN_ADDR:$BACKEND_PORT"
    echo ">>> 前端: http://$LISTEN_ADDR:$FRONTEND_PORT"
    echo ">>> 请注意：确保防火墙已放行对应端口！"
    sleep 3
}

update_mp() {
    echo ">>> 准备更新 MoviePilot..."
    if [ ! -d "$INSTALL_DIR" ]; then
        echo "❌ 未检测到安装目录 $INSTALL_DIR，请先安装！"
        sleep 2
        return 1
    fi

    echo ">>> 正在停止服务..."
    systemctl stop $SERVICE_NAME || true

    cd "$INSTALL_DIR"
    
    if [ -d "MoviePilot" ]; then
        run_task ">>> 拉取后端代码" "cd MoviePilot && git pull" || return 1
    fi
    if [ -d "MoviePilot-Plugins" ]; then
        run_task ">>> 拉取插件代码" "cd MoviePilot-Plugins && git pull" || return 1
    fi
    if [ -d "MoviePilot-Frontend" ]; then
        run_task ">>> 拉取前端代码" "cd MoviePilot-Frontend && git pull" || return 1
    fi
    if [ -d "MoviePilot-Resources" ]; then
        run_task ">>> 拉取资源代码" "cd MoviePilot-Resources && git pull" || return 1
    fi

    echo ">>> 重新整合插件与资源..."
    cp -rf MoviePilot-Plugins/plugins/* MoviePilot/app/plugins/ 2>/dev/null || true
    cp -rf MoviePilot-Plugins/icons/* MoviePilot-Frontend/public/plugin_icon/ 2>/dev/null || true
    cp -rf MoviePilot-Resources/resources.v2/* MoviePilot/app/helper/ 2>/dev/null || true

    run_task ">>> 更新后端依赖..." "cd '$INSTALL_DIR/MoviePilot' && ./venv/bin/python3 -m pip install -r requirements.txt" || return 1
    run_task ">>> 更新前端依赖..." "cd '$INSTALL_DIR/MoviePilot-Frontend' && npm install" || return 1

    echo ">>> 重新启动服务..."
    systemctl start $SERVICE_NAME
    echo ">>> 更新完成！"
    sleep 2
}

uninstall_mp() {
    echo "！！！警告：这将完全删除 MoviePilot 及其配置文件 ！！！"
    read -p "确认卸载？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo ">>> 取消卸载。"
        sleep 1
        return 1
    fi

    echo ">>> 正在停止并删除服务..."
    systemctl stop $SERVICE_NAME || true
    systemctl disable $SERVICE_NAME || true
    rm -f /etc/systemd/system/$SERVICE_NAME
    systemctl daemon-reload

    echo ">>> 正在删除安装目录..."
    rm -rf "$INSTALL_DIR"
    
    echo ">>> 卸载完成！"
    sleep 2
}

status_mp() {
    systemctl status $SERVICE_NAME || true
    echo ""
    read -p "按回车键返回菜单..."
}

logs_mp() {
    echo "正在查看日志，按 Ctrl+C 退出日志查看..."
    journalctl -u $SERVICE_NAME -f
}

restart_mp() {
    echo ">>> 正在重启服务..."
    systemctl restart $SERVICE_NAME
    echo ">>> 重启成功！"
    sleep 2
}

# 菜单主循环
while true; do
    clear
    echo "=============================================="
    echo "       MoviePilot 管理脚本 (单服务版)"
    echo "=============================================="
    echo "  1. 安装 MoviePilot"
    echo "  2. 更新 MoviePilot"
    echo "  3. 卸载 MoviePilot"
    echo "  4. 查看运行状态"
    echo "  5. 查看实时日志"
    echo "  6. 重启服务"
    echo "  0. 退出"
    echo "=============================================="
    read -p "请输入选项 [0-6]: " choice
    case $choice in
        1) install_mp ;;
        2) update_mp ;;
        3) uninstall_mp ;;
        4) status_mp ;;
        5) logs_mp ;;
        6) restart_mp ;;
        0) exit 0 ;;
        *) echo "无效选项!" && sleep 1 ;;
    esac
done