#!/bin/bash

# 需要 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 sudo 或 root 用户运行此脚本。"
  exit 1
fi

LOCK_FILE="/tmp/moviepilot_manager.lock"
if command -v flock >/dev/null 2>&1; then
    if ! exec 9>"$LOCK_FILE"; then
        echo "❌ 无法创建锁文件: $LOCK_FILE"
        exit 1
    fi
    if ! flock -n 9; then
        echo "❌ 检测到另一个 moviepilot_manager.sh 实例正在运行，请稍后重试。"
        exit 1
    fi
fi

INSTALL_DIR="/opt/MoviePilot"
SERVICE_NAME="moviepilot.service"
CONFIG_DIR="/etc/moviepilot"
CONFIG_FILE="$CONFIG_DIR/mp_config.env"
APP_CONFIG_DIR="/opt/MoviePilot/MoviePilot/config"
APP_CONFIG_FILE="$APP_CONFIG_DIR/mp_config.env"
APP_DATA_DIR="/etc/moviepilot/config"
LEGACY_CONFIG_FILE="$INSTALL_DIR/mp_config.env"

is_valid_ipv4() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    local IFS='.'
    local octet
    for octet in $ip; do
        if ((octet < 0 || octet > 255)); then
            return 1
        fi
    done
    return 0
}

is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    ((port >= 1 && port <= 65535))
}

validate_runtime_config() {
    if ! is_valid_ipv4 "$LISTEN_ADDR"; then
        echo "❌ 监听地址无效: $LISTEN_ADDR（仅支持 IPv4）"
        return 1
    fi
    if ! is_valid_port "$FRONTEND_PORT"; then
        echo "❌ 前端端口无效: $FRONTEND_PORT"
        return 1
    fi
    if ! is_valid_port "$BACKEND_PORT"; then
        echo "❌ 后端端口无效: $BACKEND_PORT"
        return 1
    fi
    return 0
}

validate_app_data_dir() {
    APP_DATA_DIR=${APP_DATA_DIR:-/etc/moviepilot/config}
    if [[ "$APP_DATA_DIR" != /* ]]; then
        echo "❌ 配置目录必须是绝对路径: $APP_DATA_DIR"
        return 1
    fi
    if [ "$APP_DATA_DIR" = "/" ]; then
        echo "❌ 配置目录不能是根目录 /"
        return 1
    fi
    if ! mkdir -p "$APP_DATA_DIR"; then
        echo "❌ 无法创建配置目录: $APP_DATA_DIR"
        return 1
    fi
    if [ ! -w "$APP_DATA_DIR" ]; then
        echo "❌ 配置目录不可写: $APP_DATA_DIR"
        return 1
    fi
    return 0
}

load_config_file() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        if [ -f "$APP_CONFIG_FILE" ]; then
            echo ">>> 检测到旧配置，正在迁移到 $CONFIG_FILE"
            mv -f "$APP_CONFIG_FILE" "$CONFIG_FILE"
        elif [ -f "$LEGACY_CONFIG_FILE" ]; then
            echo ">>> 检测到旧配置，正在迁移到 $CONFIG_FILE"
            mv -f "$LEGACY_CONFIG_FILE" "$CONFIG_FILE"
        else
            echo "❌ 未找到配置文件: $CONFIG_FILE"
            return 1
        fi
    fi

    LISTEN_ADDR=""
    FRONTEND_PORT=""
    BACKEND_PORT=""
    APP_DATA_DIR=""

    while IFS='=' read -r key value; do
        case "$key" in
            LISTEN_ADDR|FRONTEND_PORT|BACKEND_PORT|APP_DATA_DIR)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < <(grep -E '^(LISTEN_ADDR|FRONTEND_PORT|BACKEND_PORT|APP_DATA_DIR)=' "$CONFIG_FILE")

    if [ -z "$LISTEN_ADDR" ] || [ -z "$FRONTEND_PORT" ] || [ -z "$BACKEND_PORT" ]; then
        echo "❌ 配置文件缺少必要字段（LISTEN_ADDR/FRONTEND_PORT/BACKEND_PORT）"
        return 1
    fi

    APP_DATA_DIR=${APP_DATA_DIR:-/etc/moviepilot/config}
    validate_runtime_config || return 1
    validate_app_data_dir
}

save_config_file() {
    mkdir -p "$CONFIG_DIR"
    APP_DATA_DIR=${APP_DATA_DIR:-/etc/moviepilot/config}
    cat > "$CONFIG_FILE" <<EOF
LISTEN_ADDR=$LISTEN_ADDR
FRONTEND_PORT=$FRONTEND_PORT
BACKEND_PORT=$BACKEND_PORT
APP_DATA_DIR=$APP_DATA_DIR
EOF
}

migrate_app_config_dir() {
    mkdir -p "$CONFIG_DIR"
    validate_app_data_dir || return 1

    if [ -L "$APP_CONFIG_DIR" ]; then
        local OLD_TARGET
        OLD_TARGET=$(readlink -f "$APP_CONFIG_DIR" 2>/dev/null || true)
        if ! mkdir -p "$APP_DATA_DIR"; then
            echo "❌ 无法创建配置目录: $APP_DATA_DIR"
            return 1
        fi
        if [ -n "$OLD_TARGET" ] && [ "$OLD_TARGET" != "$APP_DATA_DIR" ] && [ -d "$OLD_TARGET" ]; then
            if ! cp -a "$OLD_TARGET"/. "$APP_DATA_DIR"/; then
                echo "❌ 配置目录迁移失败: $OLD_TARGET -> $APP_DATA_DIR"
                return 1
            fi
        fi
        ln -sfn "$APP_DATA_DIR" "$APP_CONFIG_DIR"
        return 0
    fi

    if [ -d "$APP_CONFIG_DIR" ]; then
        if ! mkdir -p "$APP_DATA_DIR"; then
            echo "❌ 无法创建配置目录: $APP_DATA_DIR"
            return 1
        fi
        if ! cp -a "$APP_CONFIG_DIR"/. "$APP_DATA_DIR"/; then
            echo "❌ 配置目录迁移失败: $APP_CONFIG_DIR -> $APP_DATA_DIR"
            return 1
        fi
        rm -rf "$APP_CONFIG_DIR"
    else
        if ! mkdir -p "$APP_DATA_DIR"; then
            echo "❌ 无法创建配置目录: $APP_DATA_DIR"
            return 1
        fi
    fi

    ln -sfn "$APP_DATA_DIR" "$APP_CONFIG_DIR"
}

# 通用的执行并检测错误的函数
run_task() {
    local msg="$1"
    local cmd="$2"
    
    while true; do
        echo -e "\n$msg"
        if bash -o pipefail -c "$cmd"; then
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
    read -p "请输入配置目录 (默认 /etc/moviepilot/config): " NEW_APP_DATA_DIR
    APP_DATA_DIR=${NEW_APP_DATA_DIR:-$APP_DATA_DIR}
    validate_runtime_config || return 1
    validate_app_data_dir || return 1
    
    # 1. 环境检测与自动安装
    if ! command -v git &> /dev/null; then
        run_task ">>> 准备自动安装 Git..." "apt-get update && apt-get install -y git" || return 1
    fi
    
    # 针对 Debian 13 (Trixie) 缺少 Python 3.12 的特殊处理
    local PYTHON_BASE=""
    if command -v python3.12 &> /dev/null; then
        PYTHON_BASE="python3.12"
        echo "[✓] 检测到系统已安装 Python 3.12"
    else
        echo "[!] 系统未发现 Python 3.12 (Debian 13 默认为 3.13)"
        local PY312_DIR="$INSTALL_DIR/python312_bin"
        local ARCH=$(uname -m)
        local PY_URL=""
        local PY_RELEASE_TAG="20250212"
        if [ "$ARCH" == "x86_64" ]; then
            PY_URL="https://github.com/indygreg/python-build-standalone/releases/download/20250212/cpython-3.12.9+20250212-x86_64-unknown-linux-gnu-install_only.tar.gz"
        elif [ "$ARCH" == "aarch64" ]; then
            PY_URL="https://github.com/indygreg/python-build-standalone/releases/download/20250212/cpython-3.12.9+20250212-aarch64-unknown-linux-gnu-install_only.tar.gz"
        else
            echo "❌ 不支持的架构: $ARCH，无法自动为 Debian 13 提供 Python 3.12 补丁。"
            return 1
        fi

        if [ ! -f "$PY312_DIR/bin/python3" ]; then
            run_task ">>> 正在下载并校验 Python 3.12 独立运行环境 ($ARCH 版)..." "mkdir -p '$PY312_DIR' && cd '$PY312_DIR' && curl -fL '$PY_URL' -o python312.tar.gz && curl -fL 'https://github.com/indygreg/python-build-standalone/releases/download/$PY_RELEASE_TAG/SHA256SUMS' -o SHA256SUMS && grep '$(basename "$PY_URL")' SHA256SUMS > python312.tar.gz.sha256 && sed -i 's|  .*|  python312.tar.gz|' python312.tar.gz.sha256 && sha256sum -c python312.tar.gz.sha256 && tar -xzf python312.tar.gz --strip-components=1 && rm -f python312.tar.gz python312.tar.gz.sha256 SHA256SUMS" || return 1
        fi
        PYTHON_BASE="$PY312_DIR/bin/python3"
        echo "[✓] 已配置 Python 3.12 独立环境"
    fi

    local NODE_INSTALLED=false
    if command -v node &> /dev/null; then
        local NODE_VER=$(node -v | grep -oE '[0-9]+' | head -1)
        if [ "$NODE_VER" -eq 20 ]; then
            NODE_INSTALLED=true
        fi
    fi

    if [ "$NODE_INSTALLED" = false ]; then
        run_task ">>> 准备自动安装 Node.js v20..." "apt-get remove -y nodejs npm || true; curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs && (command -v yarn >/dev/null || npm install -g yarn)" || return 1
    else
        echo "[✓] 检测到 Node.js v20 已安装"
    fi

    # 2. 克隆源代码
    mkdir -p "$INSTALL_DIR"
    save_config_file

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

    migrate_app_config_dir

    # 3. 文件整合
    integrate_files

    # 4. 安装依赖
    if [ -d "$INSTALL_DIR/MoviePilot/venv" ]; then
        local CURRENT_VENV_VER=$("$INSTALL_DIR/MoviePilot/venv/bin/python" --version 2>&1 | grep -oE '3\.[0-9]+')
        if [ "$CURRENT_VENV_VER" != "3.12" ]; then
            echo "[!] 检测到旧的虚拟环境版本为 $CURRENT_VENV_VER，正在清理并重建为 3.12..."
            rm -rf "$INSTALL_DIR/MoviePilot/venv"
        fi
    fi

    if [ ! -d "$INSTALL_DIR/MoviePilot/venv" ]; then
        run_task ">>> 正在创建 Python 虚拟环境 (使用 3.12)..." "cd '$INSTALL_DIR/MoviePilot' && $PYTHON_BASE -m venv venv" || return 1
    fi
    
    run_task ">>> 正在安装后端依赖..." "cd '$INSTALL_DIR/MoviePilot' && ./venv/bin/python3 -m pip install --upgrade pip && ./venv/bin/python3 -m pip install -r requirements.txt" || return 1

    run_task ">>> 正在安装前端依赖并构建静态文件..." "cd '$INSTALL_DIR/MoviePilot-Frontend' && npm install && npm run build" || return 1
    fix_frontend_esm || return 1

    # 5. 刷新启动脚本和 Systemd
    generate_startup_script
    generate_systemd_service

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME

    echo ">>> 安装完成！服务已启动。"
    echo ">>> 后端: http://$LISTEN_ADDR:$BACKEND_PORT"
    echo ">>> 前端: http://$LISTEN_ADDR:$FRONTEND_PORT"
    sleep 3
}

update_mp() {
    echo ">>> 准备更新 MoviePilot..."
    if [ ! -d "$INSTALL_DIR" ]; then
        echo "❌ 未检测到安装目录，请先安装！"
        sleep 2
        return 1
    fi

    load_config_file || return 1
    local FORCE_SYNC=false
    read -p "是否强制覆盖本地修改并重置到远程 HEAD？(y/N): " FORCE_CHOICE
    case "$FORCE_CHOICE" in
        [yY]) FORCE_SYNC=true ;;
    esac

    echo ">>> 正在停止服务..."
    systemctl stop $SERVICE_NAME || true

    cd "$INSTALL_DIR"
    local SYNC_CMD="git fetch --all && git remote set-head origin -a && git pull --ff-only"
    if [ "$FORCE_SYNC" = true ]; then
        SYNC_CMD="git fetch --all && git remote set-head origin -a && git reset --hard origin/HEAD"
    fi
    
    if [ -d "MoviePilot" ]; then
        run_task ">>> 拉取后端代码" "cd MoviePilot && $SYNC_CMD" || return 1
    fi
    if [ -d "MoviePilot-Plugins" ]; then
        run_task ">>> 拉取插件代码" "cd MoviePilot-Plugins && $SYNC_CMD" || return 1
    fi
    if [ -d "MoviePilot-Frontend" ]; then
        run_task ">>> 拉取前端代码" "cd MoviePilot-Frontend && $SYNC_CMD" || return 1
    fi
    if [ -d "MoviePilot-Resources" ]; then
        run_task ">>> 拉取资源代码" "cd MoviePilot-Resources && $SYNC_CMD" || return 1
    fi

    migrate_app_config_dir

    integrate_files
    
    run_task ">>> 更新后端依赖..." "cd '$INSTALL_DIR/MoviePilot' && ./venv/bin/python3 -m pip install -r requirements.txt" || return 1
    run_task ">>> 更新前端依赖并重新构建..." "cd '$INSTALL_DIR/MoviePilot-Frontend' && npm install && npm run build" || return 1
    fix_frontend_esm || return 1

    # 关键：更新代码后必须重新刷新启动脚本，防止旧的启动逻辑残留
    generate_startup_script
    generate_systemd_service

    echo ">>> 重新启动服务..."
    systemctl daemon-reload
    systemctl restart $SERVICE_NAME
    echo ">>> 更新完成！"
    sleep 2
}

modify_config() {
    echo ">>> 正在修改 MoviePilot 运行配置..."
    load_config_file || return 1

    echo "当前监听地址: $LISTEN_ADDR"
    read -p "请输入新监听地址 (直接回车保持不变): " NEW_ADDR
    LISTEN_ADDR=${NEW_ADDR:-$LISTEN_ADDR}

    echo "当前前端端口: $FRONTEND_PORT"
    read -p "请输入新前端端口 (直接回车保持不变): " NEW_FE_PORT
    FRONTEND_PORT=${NEW_FE_PORT:-$FRONTEND_PORT}

    echo "当前后端端口: $BACKEND_PORT"
    read -p "请输入新后端端口 (直接回车保持不变): " NEW_BE_PORT
    BACKEND_PORT=${NEW_BE_PORT:-$BACKEND_PORT}
    echo "当前配置目录: $APP_DATA_DIR"
    read -p "请输入新配置目录 (直接回车保持不变): " NEW_APP_DATA_DIR
    APP_DATA_DIR=${NEW_APP_DATA_DIR:-$APP_DATA_DIR}
    validate_runtime_config || return 1
    validate_app_data_dir || return 1

    # 保存新配置
    save_config_file
    migrate_app_config_dir

    echo ">>> 配置已保存，正在刷新服务文件..."
    generate_startup_script
    generate_systemd_service
    fix_frontend_esm || return 1

    echo ">>> 正在重启服务以应用新配置..."
    systemctl daemon-reload
    systemctl restart $SERVICE_NAME
    echo ">>> 配置修改成功！"
    echo ">>> 新前端地址: http://$LISTEN_ADDR:$FRONTEND_PORT"
    echo ">>> 新后端地址: http://$LISTEN_ADDR:$BACKEND_PORT"
    sleep 3
}

integrate_files() {
    echo ">>> 正在整合插件、图标和资源文件..."
    mkdir -p "$INSTALL_DIR/MoviePilot/app/plugins"
    mkdir -p "$INSTALL_DIR/MoviePilot-Frontend/public/plugin_icon"
    mkdir -p "$INSTALL_DIR/MoviePilot/app/helper"

    cp -rf "$INSTALL_DIR/MoviePilot-Plugins/plugins/"* "$INSTALL_DIR/MoviePilot/app/plugins/" 2>/dev/null || true
    cp -rf "$INSTALL_DIR/MoviePilot-Plugins/icons/"* "$INSTALL_DIR/MoviePilot-Frontend/public/plugin_icon/" 2>/dev/null || true
    cp -rf "$INSTALL_DIR/MoviePilot-Resources/resources.v2/"* "$INSTALL_DIR/MoviePilot/app/helper/" 2>/dev/null || true
}

fix_frontend_esm() {
    # 修复 service.js 在 ESM 模式下的兼容性问题，并强制其遵循监听地址
    local JS_FILE="$INSTALL_DIR/MoviePilot-Frontend/dist/service.js"
    local CJS_FILE="$INSTALL_DIR/MoviePilot-Frontend/dist/service.cjs"
    local TARGET_FILE=""

    if [ -f "$JS_FILE" ]; then
        TARGET_FILE="$JS_FILE"
    elif [ -f "$CJS_FILE" ]; then
        TARGET_FILE="$CJS_FILE"
    fi

    if [ -z "$TARGET_FILE" ]; then
        echo "❌ 未找到前端服务入口文件（dist/service.js 或 dist/service.cjs）"
        return 1
    fi

    echo ">>> 正在加固前端监听逻辑..."
    # 清理重复注入导致的 host 重复声明
    sed -i "s/; const host = process.env.HOST || '0.0.0.0'; const host = process.env.HOST || '0.0.0.0'/; const host = process.env.HOST || '0.0.0.0'/g" "$TARGET_FILE"
    # 1. 允许通过环境变量 HOST 控制监听地址（幂等）
    if ! grep -q "const host = process.env.HOST || '0.0.0.0'" "$TARGET_FILE"; then
        if grep -q "const port = process.env.NGINX_PORT || 3000" "$TARGET_FILE"; then
            sed -i "s/const port = process.env.NGINX_PORT || 3000/const port = process.env.NGINX_PORT || 3000; const host = process.env.HOST || '0.0.0.0'/g" "$TARGET_FILE"
        else
            echo "❌ 前端监听补丁失败：未找到端口声明锚点。"
            return 1
        fi
    fi
    # 2. 修改 listen 调用，显式传入 host 参数（幂等）
    if ! grep -q "app.listen(port, host, ()" "$TARGET_FILE"; then
        if grep -q "app.listen(port, ()" "$TARGET_FILE"; then
            sed -i "s/app.listen(port, ()/app.listen(port, host, ()/g" "$TARGET_FILE"
        else
            echo "❌ 前端监听补丁失败：未找到 listen 锚点。"
            return 1
        fi
    fi
    
    # 如果是原文件，执行改名
    if [ "$TARGET_FILE" == "$JS_FILE" ]; then
        mv -f "$JS_FILE" "$CJS_FILE"
    fi
}

generate_startup_script() {
    echo ">>> 正在生成启动脚本 (start_all.sh)..."
    cat > "$INSTALL_DIR/start_all.sh" << 'EOF'
#!/bin/bash
CONFIG_FILE="/etc/moviepilot/mp_config.env"

is_valid_ipv4() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    local IFS='.'
    local octet
    for octet in $ip; do
        if ((octet < 0 || octet > 255)); then
            return 1
        fi
    done
    return 0
}

is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    ((port >= 1 && port <= 65535))
}

load_config_file() {
    [ -f "$CONFIG_FILE" ] || return 1
    LISTEN_ADDR=""
    FRONTEND_PORT=""
    BACKEND_PORT=""
    while IFS='=' read -r key value; do
        case "$key" in
            LISTEN_ADDR|FRONTEND_PORT|BACKEND_PORT)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < <(grep -E '^(LISTEN_ADDR|FRONTEND_PORT|BACKEND_PORT)=' "$CONFIG_FILE")
    is_valid_ipv4 "$LISTEN_ADDR" || return 1
    is_valid_port "$FRONTEND_PORT" || return 1
    is_valid_port "$BACKEND_PORT" || return 1
}

if ! load_config_file; then
    echo "配置读取失败，拒绝启动。"
    exit 1
fi

# 定义后端内部通信地址
INTERNAL_BACKEND_IP="127.0.0.1"

# 1. 启动后端 - 显式指定监听 127.0.0.1
echo "启动 MoviePilot 后端 (监听 $INTERNAL_BACKEND_IP:$BACKEND_PORT)..."
cd /opt/MoviePilot/MoviePilot
# 注入后端所需环境变量
export HOST=$INTERNAL_BACKEND_IP
export PORT=$BACKEND_PORT
export WEB_PORT=$BACKEND_PORT
PYTHONPATH=. ./venv/bin/python3 app/main.py &
BACKEND_PID=$!

# 等待后端端口就绪，最多等待 30 秒
echo "正在等待后端服务启动..."
for i in {1..30}; do
    if command -v ss &> /dev/null && ss -tulpn | grep -q "$INTERNAL_BACKEND_IP:$BACKEND_PORT"; then
        echo "后端已就绪！"
        break
    elif command -v netstat &> /dev/null && netstat -tulpn | grep -q "$INTERNAL_BACKEND_IP:$BACKEND_PORT"; then
        echo "后端已就绪！"
        break
    fi
    sleep 1
done

# 2. 启动前端 - 监听用户定义的地址
echo "启动 MoviePilot 前端 (监听 $LISTEN_ADDR:$FRONTEND_PORT)..."
cd /opt/MoviePilot/MoviePilot-Frontend
# 注入前端所需环境变量
export HOST=$LISTEN_ADDR
export NGINX_PORT=$FRONTEND_PORT
export VITE_PORT=$FRONTEND_PORT
# 强制让 Node 代理连接到后端定义的内部端口
export PORT=$BACKEND_PORT

if [ -f "dist/service.cjs" ]; then
    node dist/service.cjs &
elif [ -f "dist/service.js" ]; then
    node dist/service.js &
else
    echo "[!] 未发现构建好的静态文件，使用开发模式启动..."
    npm run dev -- --host $LISTEN_ADDR --port $FRONTEND_PORT &
fi
FRONTEND_PID=$!

trap "kill $BACKEND_PID $FRONTEND_PID 2>/dev/null; exit" SIGINT SIGTERM
wait -n
kill $BACKEND_PID $FRONTEND_PID 2>/dev/null
exit 1
EOF
    chmod +x "$INSTALL_DIR/start_all.sh"
}

generate_systemd_service() {
    echo ">>> 正在刷新 Systemd 服务配置..."
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
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectControlGroups=true
ProtectKernelModules=true
ReadWritePaths=$INSTALL_DIR
ReadWritePaths=$CONFIG_DIR

[Install]
WantedBy=multi-user.target
EOF
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
    read -p "是否删除配置目录 $CONFIG_DIR？(y/N): " remove_cfg
    if [[ "$remove_cfg" == "y" || "$remove_cfg" == "Y" ]]; then
        rm -rf "$CONFIG_DIR"
        echo ">>> 配置目录已删除：$CONFIG_DIR"
    else
        echo ">>> 已保留配置目录：$CONFIG_DIR"
    fi
    
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

diagnose_mp() {
    echo -e "\n>>> 正在进行系统诊断..."
    echo "----------------------------------------------"
    echo "1. 检查服务运行状态:"
    systemctl is-active $SERVICE_NAME
    
    echo -e "\n2. 检查端口监听情况:"
    if command -v ss &> /dev/null; then
        ss -tulpn | grep -E 'python|node|vite'
    elif command -v netstat &> /dev/null; then
        netstat -tulpn | grep -E 'python|node|vite'
    fi

    echo -e "\n3. 检查 Python 虚拟环境:"
    if [ -f "$INSTALL_DIR/MoviePilot/venv/bin/python" ]; then
        "$INSTALL_DIR/MoviePilot/venv/bin/python" --version
    else
        echo "❌ 虚拟环境不存在！"
    fi

    echo -e "\n4. 最近 20 条关键日志:"
    journalctl -u $SERVICE_NAME -n 20 --no-pager
    
    echo "----------------------------------------------"
    read -p "诊断结束，按回车键返回菜单..."
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
    echo "  4. 修改运行配置 (端口/地址)"
    echo "  5. 查看运行状态"
    echo "  6. 查看实时日志"
    echo "  7. 重启服务"
    echo "  8. 系统诊断 (检查端口和环境)"
    echo "  0. 退出"
    echo "=============================================="
    read -p "请输入选项 [0-8]: " choice
    case $choice in
        1) install_mp ;;
        2) update_mp ;;
        3) uninstall_mp ;;
        4) modify_config ;;
        5) status_mp ;;
        6) logs_mp ;;
        7) restart_mp ;;
        8) diagnose_mp ;;
        0) exit 0 ;;
        *) echo "无效选项!" && sleep 1 ;;
    esac
done
