#!/bin/bash
set -e

# 需要 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 sudo 或 root 用户运行此脚本。"
  exit 1
fi

INSTALL_DIR="/opt/MoviePilot"
SERVICE_NAME="moviepilot.service"
CONFIG_FILE="$INSTALL_DIR/mp_config.env"

show_menu() {
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
        *) echo "无效选项!" && sleep 2 && show_menu ;;
    esac
}

install_mp() {
    echo ">>> 开始安装 MoviePilot..."
    
    # 交互式询问配置
    read -p "请输入监听地址 (默认 0.0.0.0): " LISTEN_ADDR
    LISTEN_ADDR=${LISTEN_ADDR:-0.0.0.0}
    
    read -p "请输入前端服务端口 (默认 3000): " FRONTEND_PORT
    FRONTEND_PORT=${FRONTEND_PORT:-3000}
    
    read -p "请输入后端服务端口 (默认 3001): " BACKEND_PORT
    BACKEND_PORT=${BACKEND_PORT:-3001}
    
    # 1. 环境检测与自动安装
    if ! command -v python3.12 &> /dev/null; then
        echo "[!] 未检测到 Python 3.12，准备自动安装..."
        if command -v apt-get &> /dev/null; then
            # 允许 apt-get update 失败时不退出（例如存在失效的光盘源）
            apt-get update || true
            apt-get install -y software-properties-common curl
            
            if grep -qi "ubuntu" /etc/os-release; then
                add-apt-repository -y ppa:deadsnakes/ppa || true
                apt-get update || true
            fi
            
            apt-get install -y python3.12 python3.12-venv python3.12-dev
            curl -sS https://bootstrap.pypa.io/get-pip.py | python3.12
        else
            echo "❌ 你的系统不是 Ubuntu/Debian，无法自动安装 Python 3.12，请手动安装后重试！"
            exit 1
        fi
    fi

    NODE_INSTALLED=false
    if command -v node &> /dev/null; then
        NODE_VER=$(node -v | grep -oE '[0-9]+' | head -1)
        if [ "$NODE_VER" -eq 20 ]; then
            NODE_INSTALLED=true
        fi
    fi

    if [ "$NODE_INSTALLED" = false ]; then
        echo "[!] 未检测到 Node.js v20，准备自动安装..."
        if command -v apt-get &> /dev/null; then
            apt-get remove -y nodejs npm || true
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            apt-get install -y nodejs
            npm install -g yarn
        else
            echo "❌ 你的系统不是 Ubuntu/Debian，无法自动安装 Node.js！"
            exit 1
        fi
    fi

    # 2. 克隆源代码
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # 保存配置
    cat > "$CONFIG_FILE" <<EOF
LISTEN_ADDR=$LISTEN_ADDR
FRONTEND_PORT=$FRONTEND_PORT
BACKEND_PORT=$BACKEND_PORT
EOF

    [ ! -d "MoviePilot" ] && git clone https://github.com/jxxghp/MoviePilot.git
    [ ! -d "MoviePilot-Plugins" ] && git clone https://github.com/jxxghp/MoviePilot-Plugins.git
    [ ! -d "MoviePilot-Frontend" ] && git clone https://github.com/jxxghp/MoviePilot-Frontend.git

    # 3. 文件整合
    echo ">>> 正在整合文件..."
    mkdir -p MoviePilot/app/plugins
    mkdir -p MoviePilot-Frontend/public/plugin_icon
    mkdir -p MoviePilot/app/helper

    cp -rn MoviePilot-Plugins/plugins/* MoviePilot/app/plugins/ 2>/dev/null || true
    cp -rn MoviePilot-Plugins/icons/* MoviePilot-Frontend/public/plugin_icon/ 2>/dev/null || true
    cp -rn MoviePilot-Plugins/resources/* MoviePilot/app/helper/ 2>/dev/null || true

    # 4. 安装依赖
    echo ">>> 正在安装后端依赖..."
    cd "$INSTALL_DIR/MoviePilot"
    python3.12 -m pip install -r requirements.txt

    echo ">>> 正在安装前端依赖..."
    cd "$INSTALL_DIR/MoviePilot-Frontend"
    npm install

    # 5. 创建启动脚本
    cat > "$INSTALL_DIR/start_all.sh" << 'EOF'
#!/bin/bash
set +e
source /opt/MoviePilot/mp_config.env

echo "启动 MoviePilot 后端 (监听 $LISTEN_ADDR:$BACKEND_PORT)..."
cd /opt/MoviePilot/MoviePilot
export HOST=$LISTEN_ADDR
export PORT=$BACKEND_PORT
export WEB_PORT=$BACKEND_PORT
PYTHONPATH=. python3.12 app/main.py &
BACKEND_PID=$!

echo "启动 MoviePilot 前端 (监听 $LISTEN_ADDR:$FRONTEND_PORT)..."
cd /opt/MoviePilot/MoviePilot-Frontend
export HOST=$LISTEN_ADDR
export PORT=$FRONTEND_PORT
export VITE_PORT=$FRONTEND_PORT
npm run dev -- --host $LISTEN_ADDR --port $FRONTEND_PORT &
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
    sleep 2
    show_menu
}

update_mp() {
    echo ">>> 准备更新 MoviePilot..."
    if [ ! -d "$INSTALL_DIR" ]; then
        echo "未检测到安装目录 $INSTALL_DIR，请先安装！"
        sleep 2 && show_menu
        return
    fi

    echo ">>> 正在停止服务..."
    systemctl stop $SERVICE_NAME || true

    cd "$INSTALL_DIR"
    
    echo ">>> 拉取最新代码..."
    [ -d "MoviePilot" ] && cd MoviePilot && git pull && cd ..
    [ -d "MoviePilot-Plugins" ] && cd MoviePilot-Plugins && git pull && cd ..
    [ -d "MoviePilot-Frontend" ] && cd MoviePilot-Frontend && git pull && cd ..

    echo ">>> 重新整合插件与资源..."
    cp -ru MoviePilot-Plugins/plugins/* MoviePilot/app/plugins/ 2>/dev/null || true
    cp -ru MoviePilot-Plugins/icons/* MoviePilot-Frontend/public/plugin_icon/ 2>/dev/null || true
    cp -ru MoviePilot-Plugins/resources/* MoviePilot/app/helper/ 2>/dev/null || true

    echo ">>> 更新后端依赖..."
    cd "$INSTALL_DIR/MoviePilot"
    python3.12 -m pip install -r requirements.txt

    echo ">>> 更新前端依赖..."
    cd "$INSTALL_DIR/MoviePilot-Frontend"
    npm install

    echo ">>> 重新启动服务..."
    systemctl start $SERVICE_NAME
    echo ">>> 更新完成！"
    sleep 2
    show_menu
}

uninstall_mp() {
    echo "！！！警告：这将完全删除 MoviePilot 及其配置文件 ！！！"
    read -p "确认卸载？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "取消卸载。"
        sleep 2 && show_menu
        return
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
    show_menu
}

status_mp() {
    systemctl status $SERVICE_NAME || true
    echo ""
    read -p "按回车键返回菜单..."
    show_menu
}

logs_mp() {
    echo "正在查看日志，按 Ctrl+C 退出日志查看..."
    journalctl -u $SERVICE_NAME -f
    show_menu
}

restart_mp() {
    echo ">>> 正在重启服务..."
    systemctl restart $SERVICE_NAME
    echo ">>> 重启成功！"
    sleep 2
    show_menu
}

# 运行菜单
show_menu
