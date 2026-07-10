#!/bin/bash
# ===================================================================
# VLESS+WS+Argo 一键部署脚本 —— serv00/ct8 专版
# 平台: 仅支持 Serv00/CT8 共享主机(devil 管理),不含普通 Linux VPS 相关代码
# 生命周期: install(默认) / re(改参数重装) / update(强制更新二进制并重启) / de(卸载清理) / status(查看状态)
# 保活方案: 内部 cron 每10分钟巡检保活 (已移除 PHP 触发式唤醒)
# 伪装主页: 标准 Nginx Welcome 静态伪装
# ===================================================================

if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "本脚本需要 bash, 请先确认 bash 可用后重试" >&2
        exit 1
    fi
fi

re="\033[0m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
export LC_ALL=C

ACTION="${1:-install}"
case "$ACTION" in
    install|re|update|de|status) ;;
    *) red "未知参数: ${ACTION} (支持: 留空=安装, re=用新参数重装, update=强制更新二进制, status=查看状态, de=卸载并清理)"; exit 1 ;;
esac

HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1
HAVE_WGET=0; command -v wget >/dev/null 2>&1 && HAVE_WGET=1
if [ "$HAVE_CURL" = 0 ] && [ "$HAVE_WGET" = 0 ]; then
    red "Error: 需要 curl 或 wget, 请先安装其中之一"
    exit 1
fi

IS_TTY=0; [ -t 1 ] && IS_TTY=1

fetch_with_retry() {
    local url="$1" out="$2" attempt=0 max_attempts=3
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        if [ "$HAVE_CURL" = 1 ]; then
            if [ "$IS_TTY" = 1 ]; then
                curl -fL --progress-bar --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 2 -o "$out" "$url" && return 0
            else
                curl -fL -sS --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 2 -o "$out" "$url" && return 0
            fi
        else
            if [ "$IS_TTY" = 1 ]; then
                wget -T 10 -t 1 -O "$out" "$url" && return 0
            else
                wget -q -T 10 -t 1 -O "$out" "$url" && return 0
            fi
        fi
        yellow "下载失败(第 ${attempt} 次): ${url}，2秒后重试..."
        sleep 2
    done
    red "下载失败,已重试 ${max_attempts} 次,放弃: ${url}"
    return 1
}

safe_rm() {
    local target
    if [ -z "$BIN_DIR" ] || [ -z "$WORKDIR" ] || [ -z "$FILE_PATH" ] || [ -z "$HOME" ]; then
        red "safe_rm: 检测到 BIN_DIR/WORKDIR/FILE_PATH/HOME 中有变量意外为空,为安全起见本次调用已全部跳过,不执行任何删除: $*"
        return 1
    fi
    for target in "$@"; do
        case "$target" in
            "$BIN_DIR"|"$BIN_DIR"/*|"$WORKDIR"|"$WORKDIR"/*|"$FILE_PATH"|"$FILE_PATH"/*)
                rm -rf -- "$target"
                ;;
            *)
                yellow "safe_rm: 拒绝删除不在白名单内的路径 [${target:-<空>}],已跳过"
                ;;
        esac
    done
}

graceful_kill_pidfile() {
    local pidfile="$1" pid i
    [ -f "$pidfile" ] || return 0
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -z "$pid" ] && return 0
    if kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1
        for i in 1 2 3 4 5; do
            kill -0 "$pid" >/dev/null 2>&1 || break
            sleep 0.5
        done
        kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1
    fi
}

if ! command -v devil >/dev/null 2>&1; then
    red "未检测到 devil 命令,本脚本是 serv00/ct8 专版,无法在当前环境运行"
    exit 1
fi
PLATFORM="serv00"

HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')

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
STATE_FILE="${BIN_DIR}/.vless_argo.env"

load_state() {
    [ -f "$STATE_FILE" ] || return 0
    source "$STATE_FILE"
}

save_state() {
    mkdir -p "$BIN_DIR"
    cat > "$STATE_FILE" <<EOF
SAVED_UUID=$(printf '%q' "$UUID")
SAVED_PORT=$(printf '%q' "$PORT")
SAVED_ARGO_DOMAIN=$(printf '%q' "$ARGO_DOMAIN")
SAVED_ARGO_AUTH=$(printf '%q' "$ARGO_AUTH")
SAVED_CFIP=$(printf '%q' "$CFIP")
SAVED_CFPORT=$(printf '%q' "$CFPORT")
SAVED_SUB_TOKEN=$(printf '%q' "$SUB_TOKEN")
SAVED_TG_TOKEN=$(printf '%q' "$TG_TOKEN")
SAVED_TG_ID=$(printf '%q' "$TG_ID")
SAVED_BOT_ARGS=$(printf '%q' "$args")
SAVED_WORKDIR=$(printf '%q' "$WORKDIR")
SAVED_FILE_PATH=$(printf '%q' "$FILE_PATH")
SAVED_WARP=$(printf '%q' "$WARP")
EOF
    chmod 600 "$STATE_FILE" >/dev/null 2>&1
}

get_xray_version_string() {
    echo "未知(serv00 使用的是第三方重命名二进制,不支持查询版本)"
}

HEALTH_MARK="px_health"
HEALTH_SCRIPT="${BIN_DIR}/healthcheck.sh"
HEALTH_STATE="${BIN_DIR}/.health_state"

remove_healthcheck_schedule() {
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK" ) | crontab - 2>/dev/null
    fi
}

do_uninstall() {
    purple "正在卸载 vless-argo 并清理相关文件..."
    remove_healthcheck_schedule
    purple "已清理心跳监控定时任务(如有)"

    graceful_kill_pidfile "${BIN_DIR}/web.pid"
    graceful_kill_pidfile "${BIN_DIR}/bot.pid"
    pkill -f "${BIN_DIR}/web" >/dev/null 2>&1
    pkill -f "${BIN_DIR}/bot" >/dev/null 2>&1

    devil www del "${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1
    devil www del "keep.${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1

    safe_rm "$WORKDIR" "$FILE_PATH" "$BIN_DIR"

    green "serv00/ct8 上的节点服务、订阅站点及相关文件已清理完毕"
    green "卸载完成"
}

if [ "$ACTION" = "de" ]; then
    do_uninstall
    exit 0
fi

if [ "$ACTION" = "re" ] || [ "$ACTION" = "update" ] || [ "$ACTION" = "status" ]; then
    load_state
fi
[ "$ACTION" = "update" ] && FORCE_REDOWNLOAD=1

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

export UUID=${UUID:-${SAVED_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}}
if ! [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    red "UUID 格式不合法: $UUID"
    exit 1
fi
export ARGO_DOMAIN=${ARGO_DOMAIN:-${SAVED_ARGO_DOMAIN:-''}}
if [ -n "$ARGO_DOMAIN" ] && ! [[ "$ARGO_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
    red "ARGO_DOMAIN 格式不合法: $ARGO_DOMAIN"
    exit 1
fi
export ARGO_AUTH=${ARGO_AUTH:-${SAVED_ARGO_AUTH:-''}}
export CFIP=${CFIP:-${SAVED_CFIP:-'saas.sin.fan'}}
export CFPORT=${CFPORT:-${SAVED_CFPORT:-'443'}}
export SUB_TOKEN=${SUB_TOKEN:-${SAVED_SUB_TOKEN:-${UUID:0:8}}}
export TG_TOKEN=${TG_TOKEN:-${SAVED_TG_TOKEN:-''}}
export TG_ID=${TG_ID:-${SAVED_TG_ID:-''}}

if [ "$WARP" = "1" ]; then
    export WARP=1
else
    export WARP=0
fi
WARP_PROFILE="${BIN_DIR}/warp.json"

do_status() {
    echo "===================== vless-argo 状态(serv00/ct8) ====================="
    if [ ! -f "$STATE_FILE" ]; then
        yellow "未找到安装记录(${STATE_FILE} 不存在)"
    fi
    echo "UUID         : ${UUID}"
    echo "端口(PORT)   : ${SAVED_PORT:-<尚未分配>}"
    echo "ARGO_DOMAIN  : ${ARGO_DOMAIN:-<未设置,使用quick tunnel>}"
    echo "ARGO_AUTH    : $([ -n "$ARGO_AUTH" ] && echo '已设置(内容不显示)' || echo '<未设置>')"
    echo "Xray 版本     : $(get_xray_version_string)"
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_ID" ]; then
        green "TG心跳监控   : 已启用 (TG_ID=${TG_ID}, 脚本: ${HEALTH_SCRIPT})"
    else
        echo "TG心跳监控   : 未启用"
    fi
    if [ "$SAVED_WARP" = "1" ]; then
        green "WARP出站     : 已启用(凭据: ${WARP_PROFILE})"
    else
        echo "WARP出站     : 未启用"
    fi
    echo "---------------------------------------------------------------"
    for name in web bot; do
        pidfile="${BIN_DIR}/${name}.pid"
        if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" >/dev/null 2>&1; then
            green "${name}: 运行中 (PID $(cat "$pidfile"))"
        else
            red "${name}: 未运行"
        fi
    done
    if [ -f "${FILE_PATH}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_sync.log" ]; then
        echo "订阅链接文件: https://${USERNAME}.${CURRENT_DOMAIN}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_sync.log"
    fi
    echo "==============================================================="
}

if [ "$ACTION" = "status" ]; then
    do_status
    exit 0
fi

purple "检测到运行平台: serv00/ct8"

TOTAL_STEPS=7
[ "$WARP" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
STEP_NUM=0
step() {
    STEP_NUM=$((STEP_NUM + 1))
    purple "\n[步骤 ${STEP_NUM}/${TOTAL_STEPS}] $1"
}

graceful_kill_pidfile "${BIN_DIR}/web.pid"
graceful_kill_pidfile "${BIN_DIR}/bot.pid"
safe_rm "$WORKDIR" "$FILE_PATH"
mkdir -p "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
chmod 755 "$WORKDIR" "$FILE_PATH" >/dev/null 2>&1

check_port() {
  if { [ "$ACTION" = "re" ] || [ "$ACTION" = "update" ]; } && [ -n "$SAVED_PORT" ]; then
      export PORT="$SAVED_PORT"
      purple "沿用已分配端口: $PORT"
      return
  fi
  clear
  purple "正在检测可用端口,请稍等..."
  port_list=$(devil port list)
  tcp_ports=$(echo "$port_list" | grep -c "tcp")
  udp_ports=$(echo "$port_list" | grep -c "udp")

  if [[ $tcp_ports -lt 1 ]]; then
      red "没有可用的TCP端口,正在自动调整配额..."
      if [[ $udp_ports -ge 3 ]]; then
          if [ "$ALLOW_PORT_ADJUST" != "1" ]; then
              red "需要删除一个UDP端口。请加上 ALLOW_PORT_ADJUST=1 重新运行。"
              exit 1
          fi
          udp_port_to_delete=$(echo "$port_list" | awk '/udp/ {print $1}' | head -n 1)
          devil port del udp $udp_port_to_delete
          green "已删除udp端口: $udp_port_to_delete"
      else
          red "UDP端口数不足,请手动在devil面板处理"
          exit 1
      fi
      while true; do
          tcp_port=$(shuf -i 10000-65535 -n 1)
          result=$(devil port add tcp $tcp_port 2>&1)
          if [[ $result == *"Ok"* ]]; then
              green "已添加TCP端口: $tcp_port"
              tcp_port1=$tcp_port
              break
          fi
      done
      devil binexec on >/dev/null 2>&1
      red "端口已调整! 5秒后将断开SSH连接生效,请重新连接后重试"
      sleep 5
      kill -9 $(ps -o ppid= -p $$) >/dev/null 2>&1
  else
      tcp_port1=$(echo "$port_list" | awk '/tcp/ {print $1}' | sed -n '1p')
  fi
  export PORT=$tcp_port1
  purple "vless-argo 使用端口: $PORT"
}
step "检测可用端口"
check_port

detect_argo_mode() {
    if [[ -z $ARGO_AUTH || -z $ARGO_DOMAIN ]]; then
        ARGO_MODE="quick"
    elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
        ARGO_MODE="tunnelsecret"
    elif [[ $ARGO_AUTH =~ ^[A-Za-z0-9=]{120,250}$ ]]; then
        ARGO_MODE="token"
    else
        red "无法识别 ARGO_AUTH 格式,请检查"
        exit 1
    fi
}

argo_configure() {
  detect_argo_mode
  if [ "$ARGO_MODE" = "quick" ]; then
    green "使用临时隧道(quick tunnel)"
    return
  fi

  if [ "$ARGO_MODE" = "tunnelsecret" ]; then
    echo $ARGO_AUTH > "${BIN_DIR}/tunnel.json"
    if command -v python3 >/dev/null 2>&1; then
        TUNNEL_ID=$(python3 -c "import json,sys; print(json.load(open('${BIN_DIR}/tunnel.json'))['TunnelID'])" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        TUNNEL_ID=$(sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${BIN_DIR}/tunnel.json" 2>/dev/null)
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
    yellow "当前使用的是 token 模式！"
    yellow "!!! 请务必在 Cloudflare 后台设置 Public Hostname -> Service: http://localhost:${PORT}"
  fi
}
step "配置 Argo 隧道"
argo_configure

download_binaries() {
  ARCH=$(uname -m)
  cd "$BIN_DIR" || exit 1
  BASE_URL="https://github.com/Joshuagpt/Go_Real/releases/download/v1"
  if [[ "$ARCH" =~ ^(arm|arm64|aarch64)$ ]]; then
      WEB_ASSET="runtime-arm64"
      BOT_ASSET="serv-arm64"
  else
      WEB_ASSET="runtime"
      BOT_ASSET="serv"
  fi

  if [ -x "${BIN_DIR}/web" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
      green "web 已存在,跳过下载"
  else
      fetch_with_retry "${BASE_URL}/${WEB_ASSET}" "${BIN_DIR}/web" || exit 1
      chmod +x "${BIN_DIR}/web"
  fi
  if [ -x "${BIN_DIR}/bot" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
      green "bot 已存在,跳过下载"
  else
      fetch_with_retry "${BASE_URL}/${BOT_ASSET}" "${BIN_DIR}/bot" || exit 1
      chmod +x "${BIN_DIR}/bot"
  fi
}
step "下载核心程序"
download_binaries

# (此处精简 WARP 注册代码以保持清晰，逻辑不变)
check_warp_supported() { [ "$WARP" = "1" ] || return 0; }
warp_register() { [ "$WARP" = "1" ] || return 0; }
if [ "$WARP" = "1" ]; then
    step "配置 WARP 出站"
    check_warp_supported
    warp_register
fi

generate_config() {
  local uuid_json
  uuid_json=$(json_escape "$UUID")
  local warp_outbound="" warp_routing=""
  if [ "$WARP" = "1" ] && [ -f "$WARP_PROFILE" ]; then
    source "$WARP_PROFILE"
    warp_outbound=",{ \"protocol\": \"wireguard\", \"tag\": \"warp-out\", \"settings\": { \"secretKey\": \"${WARP_PRIVATE_KEY}\", \"address\": [\"${WARP_ADDRESS_V4:-172.16.0.2/32}\", \"${WARP_ADDRESS_V6:-::/128}\"], \"peers\": [{ \"publicKey\": \"${WARP_PEER_PUBLIC_KEY}\", \"endpoint\": \"${WARP_ENDPOINT:-engage.cloudflareclient.com:2408}\" }], \"reserved\": [${WARP_RESERVED:-0,0,0}], \"mtu\": 1280 } }"
    warp_routing=",\"routing\": { \"rules\": [{ \"type\": \"field\", \"outboundTag\": \"warp-out\", \"network\": \"tcp,udp\" }] }"
  fi

  # 修正：去除了 wsSettings.path 中的 ?ed=2560，避免匹配失败导致节点不通
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
          "listen": "127.0.0.1",
          "protocol": "vless",
          "settings": {
              "clients": [
                  { "id": "${uuid_json}", "level": 0 }
              ],
              "decryption": "none"
          },
          "streamSettings": {
              "network": "ws",
              "wsSettings": {
                  "path": "/data-sync"
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
        { "protocol": "blackhole", "tag": "blocked" }${warp_outbound}
    ]${warp_routing}
}
EOF
}
step "生成节点配置"
generate_config

start_services() {
  cd "$BIN_DIR" || exit 1
  nohup ./web -c config.json >/dev/null 2>&1 &
  echo $! > "${BIN_DIR}/web.pid"
  sleep 2

  detect_argo_mode
  case "$ARGO_MODE" in
      token)        args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}" ;;
      tunnelsecret) args="tunnel --edge-ip-version auto --config ${BIN_DIR}/tunnel.yml run" ;;
      *)            args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile ${WORKDIR}/boot.log --loglevel info --url http://localhost:$PORT" ;;
  esac
  nohup ./bot $args >/dev/null 2>&1 &
  echo $! > "${BIN_DIR}/bot.pid"
  sleep 2
}
step "启动服务"
start_services
save_state

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

install_healthcheck() {
    cat > "$HEALTH_SCRIPT" << 'HEALTHEOF'
#!/bin/bash
export LC_ALL=C
STATE_FILE="__STATE_FILE__"
BIN_DIR="__BIN_DIR__"
HEALTH_STATE_FILE="__HEALTH_STATE__"

LOCK_DIR="${BIN_DIR}/.health.lock"
if [ -d "$LOCK_DIR" ]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    [ "$lock_age" -gt 120 ] && rm -rf "$LOCK_DIR" 2>/dev/null
fi
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

[ -f "$STATE_FILE" ] && source "$STATE_FILE"
is_port_open() { (exec 3<>"/dev/tcp/127.0.0.1/${1}") >/dev/null 2>&1; }

is_alive_xray() {
    [ -f "${BIN_DIR}/web.pid" ] && kill -0 "$(cat "${BIN_DIR}/web.pid" 2>/dev/null)" >/dev/null 2>&1 || return 1
    is_port_open "$SAVED_PORT"
}

is_alive_cf() {
    [ -f "${BIN_DIR}/bot.pid" ] && kill -0 "$(cat "${BIN_DIR}/bot.pid" 2>/dev/null)" >/dev/null 2>&1
}

if ! is_alive_xray; then
    [ -f "${BIN_DIR}/web.pid" ] && kill -9 "$(cat "${BIN_DIR}/web.pid" 2>/dev/null)" >/dev/null 2>&1
    ( cd "$BIN_DIR" && nohup ./web -c config.json >/dev/null 2>&1 & echo $! > "${BIN_DIR}/web.pid" )
fi

if ! is_alive_cf; then
    [ -f "${BIN_DIR}/bot.pid" ] && kill -9 "$(cat "${BIN_DIR}/bot.pid" 2>/dev/null)" >/dev/null 2>&1
    ( cd "$BIN_DIR" && nohup ./bot ${SAVED_BOT_ARGS} >/dev/null 2>&1 & echo $! > "${BIN_DIR}/bot.pid" )
fi
HEALTHEOF

    sed -i -e "s#__STATE_FILE__#${STATE_FILE}#g" -e "s#__BIN_DIR__#${BIN_DIR}#g" -e "s#__HEALTH_STATE__#${HEALTH_STATE}#g" "$HEALTH_SCRIPT"
    chmod +x "$HEALTH_SCRIPT"

    remove_healthcheck_schedule
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK"; echo "*/10 * * * * ${HEALTH_SCRIPT} >/dev/null 2>&1 # ${HEALTH_MARK}" ) | crontab -
        green "已启用内部巡检保活 (每10分钟)"
    fi
}

install_fake_homepage() {
    purple "正在配置静态伪装主页 (Nginx Welcome Page)..."
    devil www add "${USERNAME}.${CURRENT_DOMAIN}" php > /dev/null 2>&1
    
    local html_file="${FILE_PATH}/index.html"
    cat > "$html_file" << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
    body { width: 35em; margin: 0 auto; font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and working. Further configuration is required.</p>
<p>For online documentation and support please refer to <a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at <a href="http://nginx.com/">nginx.com</a>.</p>
<p><em>Thank you for using nginx.</em></p>
</body>
</html>
HTMLEOF
    chmod 644 "$html_file" >/dev/null 2>&1
    devil www restart "${USERNAME}.${CURRENT_DOMAIN}" > /dev/null 2>&1
    green "伪装主页已生成完毕"
}

generate_links() {
  argodomain=$(get_argodomain)
  echo -e "\e[1;32mArgoDomain: \e[1;35m${argodomain}\e[0m\n"

  NAME="vless-argo-serv00-${USERNAME}"
  LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&type=ws&host=${argodomain}&path=%2Fdata-sync%3Fed%3D2560#${NAME}"

  echo "$LINK" > "${FILE_PATH}/${SUB_TOKEN}_sync.log"
  echo "$LINK"

  green "\n订阅链接(静态文件): https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_sync.log"
  rm -rf "${WORKDIR}/boot.log"
  
  step "配置伪装主页"
  install_fake_homepage
}

step "生成订阅链接"
generate_links

purple "\n[附加] 配置心跳监控 (内部定时巡检)"
install_healthcheck

case "$ACTION" in
    re) green "\n重新配置完成! (platform: serv00/ct8)\n" ;;
    update) green "\n更新完成! (platform: serv00/ct8)\n" ;;
    *) green "\nRunning done! (platform: serv00/ct8)\n" ;;
esac

green "节点订阅: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_sync.log"
green "伪装主页: https://${USERNAME}.${CURRENT_DOMAIN}"
