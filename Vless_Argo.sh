#!/bin/bash
# ===================================================================
# 通用 VLESS+WS+Argo 一键部署脚本
# 兼容: Serv00/CT8 (共享主机, devil管理) 和 普通 Linux VPS (systemd/OpenRC管理)
# ===================================================================

# Alpine 默认不装 bash(默认 shell 是 busybox ash), 若被 sh 调用则自举切换到 bash
if [ -z "$BASH_VERSION" ]; then
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash >/dev/null 2>&1
    fi
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "本脚本需要 bash, 且自动安装失败, 请手动安装 bash 后重试" >&2
        exit 1
    fi
fi

re="\033[0m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
export LC_ALL=C

# ---------------------------------------------------------------
# 子命令解析: 不带参数=安装, re=用新的环境变量重新配置并重启, de=卸载并清理
# 用法示例:
#   VLESS_PORT=8443 bash <(curl -Ls .../Vless_Argo.sh)         # 安装
#   VLESS_PORT=9443 UUID=xxx bash <(curl -Ls .../Vless_Argo.sh) re   # 改参数重装
#   bash <(curl -Ls .../Vless_Argo.sh) de                            # 卸载清理
# ---------------------------------------------------------------
ACTION="${1:-install}"
case "$ACTION" in
    install|re|de) ;;
    *) red "未知参数: ${ACTION} (支持: 留空=安装, re=用新参数重装, de=卸载并清理)"; exit 1 ;;
esac

# 下载工具探测: 优先 curl, 没有则用 wget(含 busybox wget, 用短参数保证兼容)
HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1
HAVE_WGET=0; command -v wget >/dev/null 2>&1 && HAVE_WGET=1
if [ "$HAVE_CURL" = 0 ] && [ "$HAVE_WGET" = 0 ]; then
    red "Error: 需要 curl 或 wget, 请先安装其中之一"
    exit 1
fi

# 统一的下载函数:自带超时 + 重试,避免网络抖动时脚本直接卡死或静默失败
# 用法: fetch_with_retry <URL> <输出路径>
fetch_with_retry() {
    local url="$1" out="$2" attempt=0 max_attempts=3
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        if [ "$HAVE_CURL" = 1 ]; then
            curl -fL -sS --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 2 -o "$out" "$url" && return 0
        else
            wget -q -T 10 -t 1 -O "$out" "$url" && return 0
        fi
        yellow "下载失败(第 ${attempt} 次): ${url}，2秒后重试..."
        sleep 2
    done
    red "下载失败,已重试 ${max_attempts} 次,放弃: ${url}"
    return 1
}

# ---------------------------------------------------------------
# 平台探测
# ---------------------------------------------------------------
if command -v devil >/dev/null 2>&1; then
    PLATFORM="serv00"
elif [ -f /etc/os-release ] || [ -f /etc/alpine-release ]; then
    PLATFORM="vps"
else
    PLATFORM="other"
fi

if [ "$PLATFORM" = "other" ]; then
    red "未能识别当前平台(既非 serv00/ct8 也非常见 Linux 发行版),脚本退出"
    exit 1
fi

# VPS 场景下,init 系统不一定是 systemd(如 Alpine 默认用 OpenRC),需要单独探测
INIT_SYSTEM="none"
if [ "$PLATFORM" = "vps" ]; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        red "未能识别 init 系统(既非 systemd 也非 OpenRC),脚本退出"
        exit 1
    fi
fi
purple "检测到运行平台: ${PLATFORM}$( [ "$PLATFORM" = "vps" ] && echo " (init: ${INIT_SYSTEM})" )"
[ "$ACTION" = "re" ] && purple "模式: 重新配置(沿用已下载的二进制,套用新的环境变量并重启服务)"

# ---------------------------------------------------------------
# 公共变量 / 环境变量
# ---------------------------------------------------------------
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}
export ARGO_DOMAIN=${ARGO_DOMAIN:-''}
export ARGO_AUTH=${ARGO_AUTH:-''}
export CFIP=${CFIP:-'saas.sin.fan'}
export CFPORT=${CFPORT:-'443'}
export SUB_TOKEN=${SUB_TOKEN:-${UUID:0:8}}
# 仅 VPS 场景使用,serv00 端口由 devil 分配后覆盖
export VLESS_PORT=${VLESS_PORT:-'443'}

# ---------------------------------------------------------------
# 卸载/清理(de 模式专用): 停服务、删配置、删站点,不做任何安装动作
# ---------------------------------------------------------------
do_uninstall() {
    purple "正在卸载 vless-argo 并清理相关文件..."

    if [ "$PLATFORM" = "serv00" ]; then
        for pidfile in "${BIN_DIR}/web.pid" "${BIN_DIR}/bot.pid"; do
            if [ -f "$pidfile" ]; then
                old_pid=$(cat "$pidfile" 2>/dev/null)
                [ -n "$old_pid" ] && kill -9 "$old_pid" >/dev/null 2>&1
            fi
        done
        pkill -f "${BIN_DIR}/web" >/dev/null 2>&1
        pkill -f "${BIN_DIR}/bot" >/dev/null 2>&1

        devil www del "${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1
        devil www del "keep.${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1

        rm -rf "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
        rm -rf "$HOME/domains/keep.${USERNAME}.${CURRENT_DOMAIN}"

        green "serv00/ct8 上的节点服务、保活服务及相关文件已清理完毕"
    else
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            systemctl disable --now xray-argo >/dev/null 2>&1
            systemctl disable --now cloudflared-argo >/dev/null 2>&1
            rm -f /etc/systemd/system/xray-argo.service /etc/systemd/system/cloudflared-argo.service
            systemctl daemon-reload >/dev/null 2>&1
        elif [ "$INIT_SYSTEM" = "openrc" ]; then
            rc-service xray-argo stop >/dev/null 2>&1
            rc-service cloudflared-argo stop >/dev/null 2>&1
            rc-update del xray-argo default >/dev/null 2>&1
            rc-update del cloudflared-argo default >/dev/null 2>&1
            rm -f /etc/init.d/xray-argo /etc/init.d/cloudflared-argo
        fi

        rm -rf "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
        green "VPS 上的服务、配置文件和二进制已清理完毕"
    fi

    green "卸载完成"
}

# ---------------------------------------------------------------
# 目录规划(两个平台分别处理)
# ---------------------------------------------------------------
if [ "$PLATFORM" = "serv00" ]; then
    if [[ "$HOSTNAME" =~ ct8 ]]; then
        CURRENT_DOMAIN="ct8.pl"
    elif [[ "$HOSTNAME" =~ hostuno ]]; then
        CURRENT_DOMAIN="useruno.com"
    else
        CURRENT_DOMAIN="serv00.net"
    fi
    WORKDIR="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/logs"
    FILE_PATH="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/public_html"
    BIN_DIR="${HOME}/.vless_argo_bin"

    if [ "$ACTION" = "de" ]; then
        do_uninstall
        exit 0
    fi

    # 只清理上一次由本脚本启动、且记录在 pid 文件里的进程,不再广撒网 kill 当前用户下所有进程
    for pidfile in "${BIN_DIR}/web.pid" "${BIN_DIR}/bot.pid"; do
        if [ -f "$pidfile" ]; then
            old_pid=$(cat "$pidfile" 2>/dev/null)
            if [ -n "$old_pid" ] && kill -0 "$old_pid" >/dev/null 2>&1; then
                kill -9 "$old_pid" >/dev/null 2>&1
            fi
        fi
    done
    rm -rf "$WORKDIR" "$FILE_PATH" && mkdir -p "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
    chmod 777 "$WORKDIR" "$FILE_PATH" >/dev/null 2>&1
else
    [ "$(id -u)" -ne 0 ] && { red "VPS 模式请使用 root 权限运行本脚本"; exit 1; }
    WORKDIR="/var/log/xray-argo"
    FILE_PATH="/var/www/xray-argo"
    BIN_DIR="/etc/xray-argo"

    if [ "$ACTION" = "de" ]; then
        do_uninstall
        exit 0
    fi

    mkdir -p "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
fi

# ---------------------------------------------------------------
# 端口选择
# ---------------------------------------------------------------
check_port() {
  if [ "$PLATFORM" = "serv00" ]; then
    clear
    purple "正在检测可用端口,请稍等..."
    port_list=$(devil port list)
    tcp_ports=$(echo "$port_list" | grep -c "tcp")
    udp_ports=$(echo "$port_list" | grep -c "udp")

    if [[ $tcp_ports -lt 1 ]]; then
        red "没有可用的TCP端口,正在调整..."
        if [[ $udp_ports -ge 3 ]]; then
            udp_port_to_delete=$(echo "$port_list" | awk '/udp/ {print $1}' | head -n 1)
            devil port del udp $udp_port_to_delete
            green "已删除udp端口: $udp_port_to_delete"
        fi
        while true; do
            tcp_port=$(shuf -i 10000-65535 -n 1)
            result=$(devil port add tcp $tcp_port 2>&1)
            if [[ $result == *"Ok"* ]]; then
                green "已添加TCP端口: $tcp_port"
                tcp_port1=$tcp_port
                break
            else
                yellow "端口 $tcp_port 不可用,尝试其他端口..."
            fi
        done
        green "端口已调整完成, 将断开SSH连接, 请重新连接SSH并重新执行脚本"
        devil binexec on >/dev/null 2>&1
        kill -9 $(ps -o ppid= -p $$) >/dev/null 2>&1
    else
        tcp_port1=$(echo "$port_list" | awk '/tcp/ {print $1}' | sed -n '1p')
    fi
    export PORT=$tcp_port1
  else
    # VPS: 固定端口 + 占用检测
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${VLESS_PORT} "; then
        red "端口 ${VLESS_PORT} 已被占用,请通过 VLESS_PORT=xxxx 环境变量指定其他端口后重试"
        exit 1
    fi
    export PORT=$VLESS_PORT
  fi
  purple "vless-argo 使用端口: $PORT"
}
check_port

# ---------------------------------------------------------------
# Argo 隧道配置(两平台共用同一份逻辑,只是文件落地目录不同)
# ---------------------------------------------------------------
argo_configure() {
  if [[ -z $ARGO_AUTH || -z $ARGO_DOMAIN ]]; then
    green "ARGO_DOMAIN 或 ARGO_AUTH 为空,使用临时隧道(quick tunnel)"
    return
  fi

  if [[ $ARGO_AUTH =~ TunnelSecret ]]; then
    echo $ARGO_AUTH > "${BIN_DIR}/tunnel.json"

    # 提取 TunnelID:优先用 python3 做正规 JSON 解析,不依赖字段固定顺序;
    # 没有 python3 时退化为 sed 基础正则匹配(不依赖 PCRE, busybox sed/grep 也兼容,
    # 不像 grep -P 在 Alpine 等 musl+busybox 系统上大概率不支持),
    # 两者都失败才报错退出,避免生成一个 tunnel id 为空的坏配置。
    if command -v python3 >/dev/null 2>&1; then
        TUNNEL_ID=$(python3 -c "import json,sys; print(json.load(open('${BIN_DIR}/tunnel.json'))['TunnelID'])" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        TUNNEL_ID=$(sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${BIN_DIR}/tunnel.json" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        red "无法从 ARGO_AUTH 中解析出 TunnelID,请检查该 JSON 凭证是否完整(需包含 TunnelID 字段)"
        exit 1
    fi

    cat > "${BIN_DIR}/tunnel.yml" << EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${BIN_DIR}/tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    yellow "当前使用的是token,请在cloudflare后台设置隧道端口为${purple}${PORT}${re}"
  fi
}
argo_configure
wait

# ---------------------------------------------------------------
# 下载核心程序
#   serv00: 沿用原先的 freebsd 二进制(eooce/test)
#   vps   : 官方 XTLS/Xray-core + cloudflare/cloudflared
# ---------------------------------------------------------------
download_binaries() {
  ARCH=$(uname -m)
  cd "$BIN_DIR" || exit 1

  if [ "$PLATFORM" = "serv00" ]; then
    if [[ "$ARCH" =~ ^(arm|arm64|aarch64)$ ]]; then
        BASE_URL="https://github.com/eooce/test/releases/download/freebsd-arm64"
    else
        BASE_URL="https://github.com/eooce/test/releases/download/freebsd"
    fi

    if [ -x "${BIN_DIR}/web" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
        green "web 已存在,跳过下载(如需强制重下载,设置 FORCE_REDOWNLOAD=1)"
    else
        fetch_with_retry "${BASE_URL}/web" "${BIN_DIR}/web" || exit 1
        chmod +x "${BIN_DIR}/web"
    fi
    if [ -x "${BIN_DIR}/bot" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
        green "bot 已存在,跳过下载"
    else
        fetch_with_retry "${BASE_URL}/server" "${BIN_DIR}/bot" || exit 1
        chmod +x "${BIN_DIR}/bot"
    fi
    XRAY_BIN="${BIN_DIR}/web"
    CLOUDFLARED_BIN="${BIN_DIR}/bot"
  else
    case "$ARCH" in
        x86_64|amd64) XARCH="64"; CF_ARCH="amd64" ;;
        aarch64|arm64) XARCH="arm64-v8a"; CF_ARCH="arm64" ;;
        *) red "不支持的架构: $ARCH"; exit 1 ;;
    esac

    if [ -x "${BIN_DIR}/xray-core/xray" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
        green "xray 已存在,跳过下载(如需强制重下载,设置 FORCE_REDOWNLOAD=1)"
    else
        fetch_with_retry "https://api.github.com/repos/XTLS/Xray-core/releases/latest" "${BIN_DIR}/xray_latest.json" || exit 1
        XRAY_VER=$(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' "${BIN_DIR}/xray_latest.json" | head -n1 | cut -d'"' -f4)
        rm -f "${BIN_DIR}/xray_latest.json"
        [ -z "$XRAY_VER" ] && { red "获取 Xray-core 版本号失败(可能是 GitHub API 限流或网络问题),请检查网络后重试"; exit 1; }

        fetch_with_retry "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${XARCH}.zip" "${BIN_DIR}/xray.zip" || exit 1

        # 校验和验证:需要本机有 sha256sum 且能拿到官方 .dgst 摘要文件,任一条件不满足则跳过校验(不阻断部署,只是降级为无校验下载)
        if command -v sha256sum >/dev/null 2>&1 && fetch_with_retry "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${XARCH}.zip.dgst" "${BIN_DIR}/xray.zip.dgst"; then
            expected_sha256=$(grep -i '^SHA256' "${BIN_DIR}/xray.zip.dgst" | awk '{print $NF}')
            actual_sha256=$(sha256sum "${BIN_DIR}/xray.zip" | awk '{print $1}')
            if [ -n "$expected_sha256" ] && [ "$expected_sha256" != "$actual_sha256" ]; then
                red "Xray-core 压缩包 sha256 校验失败!预期 ${expected_sha256},实际 ${actual_sha256}。为安全起见终止部署。"
                exit 1
            elif [ -n "$expected_sha256" ]; then
                green "Xray-core sha256 校验通过"
            fi
        else
            yellow "本机无 sha256sum 或未能获取官方校验和文件,跳过完整性校验(不影响部署,但建议人工确认下载来源可信)"
        fi

        command -v unzip >/dev/null 2>&1 || (apt-get update -y && apt-get install -y unzip) >/dev/null 2>&1 || yum install -y unzip >/dev/null 2>&1 || apk add --no-cache unzip >/dev/null 2>&1
        mkdir -p "${BIN_DIR}/xray-core"
        unzip -o "${BIN_DIR}/xray.zip" -d "${BIN_DIR}/xray-core" >/dev/null && rm -f "${BIN_DIR}/xray.zip" "${BIN_DIR}/xray.zip.dgst"
        chmod +x "${BIN_DIR}/xray-core/xray"
    fi
    XRAY_BIN="${BIN_DIR}/xray-core/xray"

    if [ -x "${BIN_DIR}/cloudflared" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
        green "cloudflared 已存在,跳过下载"
    else
        fetch_with_retry "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" "${BIN_DIR}/cloudflared" || exit 1
        chmod +x "${BIN_DIR}/cloudflared"
    fi
    CLOUDFLARED_BIN="${BIN_DIR}/cloudflared"
  fi
}
download_binaries
wait

# ---------------------------------------------------------------
# 生成 Xray 配置(协议改为 vless)
# ---------------------------------------------------------------
generate_config() {
  cat > "${BIN_DIR}/config.json" << EOF
{
    "log": {
        "access": "/dev/null",
        "error": "/dev/null",
        "loglevel": "none"
    },
    "inbounds": [
        {
          "tag": "vless-ws",
          "port": ${PORT},
          "listen": "0.0.0.0",
          "protocol": "vless",
          "settings": {
              "clients": [
                  { "id": "${UUID}", "level": 0 }
              ],
              "decryption": "none"
          },
          "streamSettings": {
              "network": "ws",
              "wsSettings": {
                  "path": "/vless-argo?ed=2560"
              }
          }
        }
    ],
    "dns": {
        "servers": [
            "https+local://8.8.8.8/dns-query"
        ]
    },
    "outbounds": [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "blackhole", "tag": "blocked" }
    ]
}
EOF
}
generate_config
wait

# ---------------------------------------------------------------
# 启动服务
#   serv00: nohup 后台进程(受共享主机限制,无 systemd 权限)
#   vps   : systemd 服务,自带开机自启 + 崩溃重启
# ---------------------------------------------------------------
start_services() {
  if [ "$PLATFORM" = "serv00" ]; then
    cd "$BIN_DIR" || exit 1
    nohup ./web -c config.json >/dev/null 2>&1 &
    echo $! > "${BIN_DIR}/web.pid"
    sleep 2
    if pgrep -f "web -c config.json" >/dev/null; then
        green "xray(web) 运行中"
    else
        red "xray(web) 未运行,重试中..."
        [ -f "${BIN_DIR}/web.pid" ] && kill -9 "$(cat "${BIN_DIR}/web.pid")" >/dev/null 2>&1
        nohup ./web -c config.json >/dev/null 2>&1 &
        echo $! > "${BIN_DIR}/web.pid"
        sleep 2
    fi

    if [[ $ARGO_AUTH =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
        args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}"
    elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
        args="tunnel --edge-ip-version auto --config ${BIN_DIR}/tunnel.yml run"
    else
        args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile ${WORKDIR}/boot.log --loglevel info --url http://localhost:$PORT"
    fi
    nohup ./bot $args >/dev/null 2>&1 &
    echo $! > "${BIN_DIR}/bot.pid"
    sleep 2
    if pgrep -f "bot" >/dev/null; then
        green "cloudflared(bot) 运行中"
    else
        red "cloudflared(bot) 未运行,重试中..."
        [ -f "${BIN_DIR}/bot.pid" ] && kill -9 "$(cat "${BIN_DIR}/bot.pid")" >/dev/null 2>&1
        nohup ./bot $args >/dev/null 2>&1 &
        echo $! > "${BIN_DIR}/bot.pid"
        sleep 2
    fi
  else
    if [[ $ARGO_AUTH =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
        cf_args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}"
    elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
        cf_args="tunnel --edge-ip-version auto --config ${BIN_DIR}/tunnel.yml run"
    else
        cf_args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile ${WORKDIR}/boot.log --loglevel info --url http://localhost:${PORT}"
    fi

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        cat > /etc/systemd/system/xray-argo.service << EOF
[Unit]
Description=Xray VLESS-WS Service
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${BIN_DIR}/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        cat > /etc/systemd/system/cloudflared-argo.service << EOF
[Unit]
Description=Cloudflared Argo Tunnel
After=network.target xray-argo.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} ${cf_args}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable xray-argo >/dev/null 2>&1
        systemctl enable cloudflared-argo >/dev/null 2>&1
        systemctl restart xray-argo >/dev/null 2>&1
        systemctl restart cloudflared-argo >/dev/null 2>&1
        sleep 2
        systemctl is-active --quiet xray-argo && green "xray-argo.service 运行中" || red "xray-argo.service 启动失败,请用 journalctl -u xray-argo 查看日志"
        systemctl is-active --quiet cloudflared-argo && green "cloudflared-argo.service 运行中" || red "cloudflared-argo.service 启动失败,请用 journalctl -u cloudflared-argo 查看日志"

    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        # Alpine 等使用 OpenRC 的发行版,没有 systemd,用 /etc/init.d 脚本 + rc-service 管理
        cat > /etc/init.d/xray-argo << EOF
#!/sbin/openrc-run
name="xray-argo"
description="Xray VLESS-WS Service"
command="${XRAY_BIN}"
command_args="run -c ${BIN_DIR}/config.json"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${WORKDIR}/xray.log"
error_log="${WORKDIR}/xray.err.log"
respawn_max=0

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/xray-argo

        cat > /etc/init.d/cloudflared-argo << EOF
#!/sbin/openrc-run
name="cloudflared-argo"
description="Cloudflared Argo Tunnel"
command="${CLOUDFLARED_BIN}"
command_args="${cf_args}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${WORKDIR}/cloudflared.log"
error_log="${WORKDIR}/cloudflared.err.log"
respawn_max=0

depend() {
    need net
    after xray-argo
}
EOF
        chmod +x /etc/init.d/cloudflared-argo

        rc-update add xray-argo default >/dev/null 2>&1
        rc-update add cloudflared-argo default >/dev/null 2>&1
        rc-service xray-argo restart >/dev/null 2>&1
        rc-service cloudflared-argo restart >/dev/null 2>&1
        sleep 2
        rc-service xray-argo status 2>/dev/null | grep -q started && green "xray-argo (OpenRC) 运行中" || red "xray-argo (OpenRC) 启动失败,请查看 ${WORKDIR}/xray.err.log"
        rc-service cloudflared-argo status 2>/dev/null | grep -q started && green "cloudflared-argo (OpenRC) 运行中" || red "cloudflared-argo (OpenRC) 启动失败,请查看 ${WORKDIR}/cloudflared.err.log"
    fi
  fi
}
start_services

# ---------------------------------------------------------------
# 获取 Argo 域名
# ---------------------------------------------------------------
get_argodomain() {
  if [[ -n $ARGO_AUTH ]]; then
    echo "$ARGO_DOMAIN"
  else
    local retry=0 max_retries=6 argodomain=""
    while [[ $retry -lt $max_retries ]]; do
        ((retry++))
        argodomain=$(grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' "${WORKDIR}/boot.log" 2>/dev/null | sed 's@https://@@')
        [[ -n $argodomain ]] && break
        sleep 1
    done
    echo "$argodomain"
  fi
}

# ---------------------------------------------------------------
# serv00 专属:全自动保活服务(VPS 用 systemd 自带保活,无需此步骤)
# ---------------------------------------------------------------
install_keepalive() {
    [ "$PLATFORM" != "serv00" ] && return
    purple "正在安装保活服务中,请稍等......"
    devil www del "keep.${USERNAME}.${CURRENT_DOMAIN}" > /dev/null 2>&1
    devil www add "keep.${USERNAME}.${CURRENT_DOMAIN}" nodejs /usr/local/bin/node18 > /dev/null 2>&1
    keep_path="$HOME/domains/keep.${USERNAME}.${CURRENT_DOMAIN}/public_nodejs"
    [ -d "$keep_path" ] || mkdir -p "$keep_path"
    fetch_with_retry "https://xray.ssss.nyc.mn/vmess.js" "${keep_path}/app.js"

    cat > "${keep_path}/.env" <<EOF
UUID=${UUID}
CFIP=${CFIP}
CFPORT=${CFPORT}
SUB_TOKEN=${SUB_TOKEN}
ARGO_DOMAIN=${ARGO_DOMAIN}
ARGO_AUTH=$([[ -z "$ARGO_AUTH" ]] && echo "" || ([[ "$ARGO_AUTH" =~ ^\{.* ]] && echo "'$ARGO_AUTH'" || echo "$ARGO_AUTH"))
EOF
    devil www add "${USERNAME}.${CURRENT_DOMAIN}" php > /dev/null 2>&1
    [ -f "${FILE_PATH}/index.html" ] || fetch_with_retry "https://github.com/eooce/Sing-box/releases/download/00/index.html" "${FILE_PATH}/index.html"
    ln -fs /usr/local/bin/node18 ~/bin/node > /dev/null 2>&1
    ln -fs /usr/local/bin/npm18 ~/bin/npm > /dev/null 2>&1
    mkdir -p ~/.npm-global
    npm config set prefix '~/.npm-global'
    echo 'export PATH=~/.npm-global/bin:~/bin:$PATH' >> "$HOME/.bash_profile" && source "$HOME/.bash_profile"
    rm -rf "$HOME/.npmrc" > /dev/null 2>&1
    (cd "${keep_path}" && npm install dotenv axios --silent > /dev/null 2>&1)
    rm -f "$HOME/domains/keep.${USERNAME}.${CURRENT_DOMAIN}/public_nodejs/public/index.html" > /dev/null 2>&1
    devil www restart "keep.${USERNAME}.${CURRENT_DOMAIN}" > /dev/null 2>&1
    check_url="http://keep.${USERNAME}.${CURRENT_DOMAIN}/${USERNAME}"
    if [ "$HAVE_CURL" = 1 ]; then
        check_result=$(curl -skL "$check_url")
    else
        check_result=$(wget -qO- "$check_url")
    fi
    if echo "$check_result" | grep -q "running"; then
        green "全自动保活服务安装成功"
    else
        red "保活服务安装可能未成功,请访问 http://keep.${USERNAME}.${CURRENT_DOMAIN}/status 检查"
    fi
}

# ---------------------------------------------------------------
# 生成订阅链接(vless://)
# ---------------------------------------------------------------
generate_links() {
  argodomain=$(get_argodomain)
  echo -e "\e[1;32mArgoDomain: \e[1;35m${argodomain}\e[0m\n"

  NAME="vless-argo-${PLATFORM}-${USERNAME}"
  LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${NAME}"

  echo "$LINK" > "${FILE_PATH}/${SUB_TOKEN}_vless.log"
  echo "$LINK"

  if [ "$PLATFORM" = "serv00" ]; then
    green "\n订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_vless.log\n"
    rm -rf "${BIN_DIR}/config.json" "${WORKDIR}/boot.log" "${BIN_DIR}/tunnel.json" "${BIN_DIR}/tunnel.yml"
    install_keepalive
  else
    green "\n节点信息已保存到: ${FILE_PATH}/${SUB_TOKEN}_vless.log"
    yellow "VPS 模式下服务由 systemd 托管(xray-argo / cloudflared-argo),无需额外保活。"
    yellow "如需通过域名访问该订阅文件,请自行用 Nginx/Caddy 反代 ${FILE_PATH} 目录。\n"
  fi
}
generate_links

if [ "$ACTION" = "re" ]; then
    green "\n重新配置完成! 已用新参数重启服务 (platform: ${PLATFORM})\n"
else
    green "\nRunning done! (platform: ${PLATFORM})\n"
fi
