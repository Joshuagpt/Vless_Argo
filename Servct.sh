#!/bin/bash
# ===================================================================
# VLESS+WS+Argo 一键部署脚本 —— serv00/ct8 专版
# 平台: 仅支持 Serv00/CT8 共享主机(devil 管理),不含普通 Linux VPS 相关代码
# 生命周期: install(默认) / re(改参数重装) / update(强制更新二进制并重启) / de(卸载清理) / status(查看状态)
# 保活方案: 内部 cron 每10分钟巡检一次(订阅触发式唤醒等其他保活方式已移除,后续按需再加)
# ===================================================================

# Alpine/其他环境下若被 sh 调用则自举切换到 bash(serv00 默认自带 bash,这里仅作兜底)
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

# ---------------------------------------------------------------
# 子命令解析
# 用法示例:
#   bash <(curl -Ls .../Go_Real_Serv00.sh)                                    # 安装
#   VLESS_PORT=... UUID=xxx bash <(curl -Ls .../Go_Real_Serv00.sh) re         # 改参数重装(沿用未指定的旧配置; serv00端口由devil分配,VLESS_PORT无效)
#   WARP=1 bash <(curl -Ls .../Go_Real_Serv00.sh) re                          # 开启WARP出站(账号凭据只注册一次、以后自动复用;开关本身每次都要显式带 WARP=1)
#   bash <(curl -Ls .../Go_Real_Serv00.sh) update                             # 强制重新下载二进制并重启
#   bash <(curl -Ls .../Go_Real_Serv00.sh) status                             # 查看当前配置和运行状态
#   bash <(curl -Ls .../Go_Real_Serv00.sh) de                                 # 卸载并清理
# ---------------------------------------------------------------
ACTION="${1:-install}"
case "$ACTION" in
    install|re|update|de|status) ;;
    *) red "未知参数: ${ACTION} (支持: 留空=安装, re=用新参数重装, update=强制更新二进制, status=查看状态, de=卸载并清理)"; exit 1 ;;
esac

# 下载工具探测: 优先 curl, 没有则用 wget(含 busybox wget, 用短参数保证兼容)
HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1
HAVE_WGET=0; command -v wget >/dev/null 2>&1 && HAVE_WGET=1
if [ "$HAVE_CURL" = 0 ] && [ "$HAVE_WGET" = 0 ]; then
    red "Error: 需要 curl 或 wget, 请先安装其中之一"
    exit 1
fi

# 是否连着交互终端:是的话下载时显示原生进度条(百分比/速度/剩余时间),
# 不是的话(比如日志重定向、CI)保持静默,避免大量 \r 刷新行写进日志文件
IS_TTY=0; [ -t 1 ] && IS_TTY=1

# 统一的下载函数:自带超时 + 重试,避免网络抖动时脚本直接卡死或静默失败
# 用法: fetch_with_retry <URL> <输出路径>
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

# 只删除脚本自己拼出来的固定路径,拒绝空值/根目录/HOME 这种明显危险的目标
safe_rm() {
    local target
    # 白名单本身是拿 RUNTIME_DIR/WORKDIR/FILE_PATH 这几个变量拼出来的,如果其中任何一个
    # 意外变成空值,对应的通配符(比如 "$RUNTIME_DIR/*")会退化成"/*"这种几乎匹配一切路径的
    # 模式,白名单就形同虚设、跟没做限制一样危险。这里先做一次前置检查,只要有一个
    # 关键目录变量是空的,这次调用的所有删除操作整体跳过,不尝试"部分安全"。
    if [ -z "$RUNTIME_DIR" ] || [ -z "$WORKDIR" ] || [ -z "$FILE_PATH" ] || [ -z "$HOME" ]; then
        red "safe_rm: 检测到 RUNTIME_DIR/WORKDIR/FILE_PATH/HOME 中有变量意外为空,为安全起见本次调用已全部跳过,不执行任何删除: $*"
        return 1
    fi
    for target in "$@"; do
        case "$target" in
            "$RUNTIME_DIR"|"$RUNTIME_DIR"/*|"$WORKDIR"|"$WORKDIR"/*|"$FILE_PATH"|"$FILE_PATH"/*)
                rm -rf -- "$target"
                ;;
            *)
                yellow "safe_rm: 拒绝删除不在白名单内的路径 [${target:-<空>}],已跳过(如需清理请手动检查)"
                ;;
        esac
    done
}

# 先礼后兵:普通 kill 给进程一点时间自行退出,超时仍未退出再 -9 强杀
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

# ---------------------------------------------------------------
# 平台探测: 本脚本是 serv00/ct8 专版,非该平台直接拒绝运行
# ---------------------------------------------------------------
if ! command -v devil >/dev/null 2>&1; then
    red "未检测到 devil 命令,本脚本是 serv00/ct8 专版,无法在当前环境运行"
    exit 1
fi
PLATFORM="serv00"

HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------
# 路径规划(纯计算,不做任何创建/删除动作;所有子命令都需要先知道这些路径)
# ---------------------------------------------------------------
if [[ "$HOSTNAME" =~ ct8 ]]; then
    CURRENT_DOMAIN="ct8.pl"
elif [[ "$HOSTNAME" =~ hostuno ]]; then
    CURRENT_DOMAIN="useruno.com"
else
    CURRENT_DOMAIN="serv00.net"
fi
WORKDIR="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/logs"
FILE_PATH="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/public_html"

# 新运行时目录结构
RUNTIME_DIR="${HOME}/.local/share/runtime"
BIN_DIR="${RUNTIME_DIR}/bin"
CONF_DIR="${RUNTIME_DIR}/conf"
RUN_DIR="${RUNTIME_DIR}/run"
LOG_DIR="${RUNTIME_DIR}/log"
TMP_DIR="${RUNTIME_DIR}/tmp"

# 配置文件路径
SERVICE_CONF="${CONF_DIR}/service.json"
PROFILE_CONF="${CONF_DIR}/profile.json"        # 原 warp.json，保存 WARP 凭据
STATE_FILE="${CONF_DIR}/install.env"           # 保存安装参数，供 re/update 读取
HEALTH_SCRIPT="${BIN_DIR}/healthcheck.sh"
HEALTH_STATE="${RUN_DIR}/health.state"
HEALTH_MARK="px_health"                        # crontab 条目标识

# ---------------------------------------------------------------
# 状态持久化: install 时保存本次生效的关键参数,re/update/status 时读取,
# 用于实现"改参数重装时,没显式指定的项目沿用上次的值"而不是每次都退回硬编码默认值
# ---------------------------------------------------------------
load_state() {
    [ -f "$STATE_FILE" ] || return 0
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}
save_state() {
    mkdir -p "$CONF_DIR"
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

# ---------------------------------------------------------------
# 心跳监控: 公共变量 + 定时任务清理函数
# 提前到这里定义(而不是放在脚本靠后位置),是因为 de 卸载分支会提前 exit,
# 必须保证清理逻辑在那之前就已经可用
# ---------------------------------------------------------------
remove_healthcheck_schedule() {
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK" ) | crontab - 2>/dev/null
    fi
}

# ---------------------------------------------------------------
# 卸载/清理(de 模式专用): 停服务、删配置、删站点,不做任何安装动作
# ---------------------------------------------------------------
do_uninstall() {
    purple "正在卸载 vless-argo 并清理相关文件..."
    remove_healthcheck_schedule
    purple "已清理心跳监控定时任务(如有)"

    graceful_kill_pidfile "${RUN_DIR}/web.pid"
    graceful_kill_pidfile "${RUN_DIR}/bot.pid"
    pkill -f "${BIN_DIR}/web" >/dev/null 2>&1
    pkill -f "${BIN_DIR}/bot" >/dev/null 2>&1

    devil www del "${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1
    # 兼容清理旧版本(Node.js 保活方案)可能残留的 keep 子域名站点
    devil www del "keep.${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1

    safe_rm "$WORKDIR" "$FILE_PATH" "$RUNTIME_DIR"

    green "serv00/ct8 上的节点服务、订阅站点及相关文件已清理完毕"
    green "卸载完成"
}

if [ "$ACTION" = "de" ]; then
    do_uninstall
    exit 0
fi

# re/update/status 需要先读取上次保存的配置,作为未显式指定环境变量时的回退值
if [ "$ACTION" = "re" ] || [ "$ACTION" = "update" ] || [ "$ACTION" = "status" ]; then
    load_state
fi
# update = re + 强制重新下载二进制,复用同一套"沿用旧配置"的逻辑
[ "$ACTION" = "update" ] && FORCE_REDOWNLOAD=1

# ---------------------------------------------------------------
# 公共变量 / 环境变量
# 优先级: 本次显式传入的环境变量 > 上次安装保存的值(仅 re/update/status) > 硬编码默认值
# ---------------------------------------------------------------

# 把任意字符串转成能安全嵌进 JSON 字符串值里的形式(反斜杠/双引号/换行/制表符转义)。
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# 把任意字符串转成能安全放进 sed "s|pattern|REPLACEMENT|" 替换字符串位置的形式。
sed_repl_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//|/\\|}"
    printf '%s' "$s"
}

export UUID=${UUID:-${SAVED_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}}
if ! [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    red "UUID 格式不合法(必须是标准 UUID 格式,如 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx): $UUID"
    exit 1
fi
export ARGO_DOMAIN=${ARGO_DOMAIN:-${SAVED_ARGO_DOMAIN:-''}}
if [ -n "$ARGO_DOMAIN" ] && ! [[ "$ARGO_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
    red "ARGO_DOMAIN 格式不合法,不像一个域名: $ARGO_DOMAIN"
    exit 1
fi
export ARGO_AUTH=${ARGO_AUTH:-${SAVED_ARGO_AUTH:-''}}
export CFIP=${CFIP:-${SAVED_CFIP:-'saas.sin.fan'}}
export CFPORT=${CFPORT:-${SAVED_CFPORT:-'443'}}
export SUB_TOKEN=${SUB_TOKEN:-${SAVED_SUB_TOKEN:-${UUID:0:8}}}
export TG_TOKEN=${TG_TOKEN:-${SAVED_TG_TOKEN:-''}}
export TG_ID=${TG_ID:-${SAVED_TG_ID:-''}}

# WARP 出站开关: 每次 install/re/update 都必须显式传 WARP=1 才算开启,
# 不传或传其他任何值(包括之前是开启状态)一律视为本次要关闭。
if [ "$WARP" = "1" ]; then
    export WARP=1
else
    export WARP=0
fi
WARP_PROFILE="${PROFILE_CONF}"   # 复用 profile.json

# ---------------------------------------------------------------
# status 模式: 只读查看,不改动任何东西
# ---------------------------------------------------------------
do_status() {
    echo "===================== vless-argo 状态(serv00/ct8) ====================="
    if [ ! -f "$STATE_FILE" ]; then
        yellow "未找到安装记录(${STATE_FILE} 不存在),下面是本次会用到的默认值,不代表实际已部署的配置"
    fi
    echo "UUID         : ${UUID}"
    echo "端口(PORT)   : ${SAVED_PORT:-<尚未分配>}"
    echo "ARGO_DOMAIN  : ${ARGO_DOMAIN:-<未设置,使用quick tunnel>}"
    echo "ARGO_AUTH    : $([ -n "$ARGO_AUTH" ] && echo '已设置(内容不显示)' || echo '<未设置>')"
    echo "Xray 版本     : $(get_xray_version_string)"
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_ID" ]; then
        if [ -x "$HEALTH_SCRIPT" ]; then
            green "TG心跳监控   : 已启用 (TG_ID=${TG_ID}, 脚本: ${HEALTH_SCRIPT})"
        else
            yellow "TG心跳监控   : 已配置TG_TOKEN/TG_ID,但未找到心跳脚本(可能尚未 install/re 过),请重新执行一次脚本"
        fi
        if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "$HEALTH_MARK"; then
            echo "  定时任务   : crontab 已注册 (每10分钟巡检 + 订阅请求触发式唤醒)"
        else
            yellow "  定时任务   : 未检测到(可能需要重新执行脚本以注册)"
        fi
    else
        echo "TG心跳监控   : 未启用(设置 TG_TOKEN + TG_ID 环境变量后重新执行即可自动开启)"
    fi
    if [ "$SAVED_WARP" = "1" ]; then
        if [ -f "$PROFILE_CONF" ]; then
            green "WARP出站     : 已启用(凭据: ${PROFILE_CONF})"
        else
            yellow "WARP出站     : 已请求启用,但尚未找到凭据文件(可能上次注册失败,重新执行脚本会再次尝试注册)"
        fi
    else
        echo "WARP出站     : 未启用(每次 install/re/update 时加上 WARP=1 环境变量才会开启,不会沿用上次的状态)"
    fi
    echo "---------------------------------------------------------------"
    for name in web bot; do
        pidfile="${RUN_DIR}/${name}.pid"
        if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" >/dev/null 2>&1; then
            green "${name}: 运行中 (PID $(cat "$pidfile"))"
        else
            red "${name}: 未运行"
        fi
    done
    if [ -f "${FILE_PATH}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_sync.php" ]; then
        echo "订阅链接文件: https://${USERNAME}.${CURRENT_DOMAIN}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_sync.php"
    fi
    echo "==============================================================="
}

if [ "$ACTION" = "status" ]; then
    do_status
    exit 0
fi

purple "检测到运行平台: serv00/ct8"
case "$ACTION" in
    re) purple "模式: 重新配置(未显式指定的参数沿用上次安装的值,套用新的环境变量并重启服务)" ;;
    update) purple "模式: 强制更新(重新下载 xray/cloudflared 二进制,沿用已保存的配置并重启)" ;;
esac

TOTAL_STEPS=6
[ "$WARP" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
STEP_NUM=0
step() {
    STEP_NUM=$((STEP_NUM + 1))
    purple "\n[步骤 ${STEP_NUM}/${TOTAL_STEPS}] $1"
}

# ---------------------------------------------------------------
# 目录初始化(install/re/update 都要走到这里,de/status 前面已经 exit 了)
# ---------------------------------------------------------------
graceful_kill_pidfile "${RUN_DIR}/web.pid"
graceful_kill_pidfile "${RUN_DIR}/bot.pid"
safe_rm "$WORKDIR" "$FILE_PATH" "$RUNTIME_DIR"
mkdir -p "$BIN_DIR" "$CONF_DIR" "$RUN_DIR" "$LOG_DIR" "$TMP_DIR"
chmod 755 "$WORKDIR" "$FILE_PATH" >/dev/null 2>&1
chmod 700 "$RUNTIME_DIR" "$BIN_DIR" "$CONF_DIR" "$RUN_DIR" "$LOG_DIR" "$TMP_DIR" >/dev/null 2>&1

# ---------------------------------------------------------------
# 端口选择(serv00 端口由 devil 分配,一个账号只能有一个可用 TCP 端口)
# ---------------------------------------------------------------
check_port() {
  if { [ "$ACTION" = "re" ] || [ "$ACTION" = "update" ]; } && [ -n "$SAVED_PORT" ]; then
      export PORT="$SAVED_PORT"
      purple "沿用已分配端口: $PORT (serv00 端口由 devil 分配,如需换端口请先 de 卸载再重新 install)"
      return
  fi
  clear
  purple "正在检测可用端口,请稍等..."
  port_list=$(devil port list)
  tcp_ports=$(echo "$port_list" | grep -c "tcp")
  udp_ports=$(echo "$port_list" | grep -c "udp")

  if [[ $tcp_ports -lt 1 ]]; then
      red "没有可用的TCP端口,需要自动调整端口配额(此操作具有破坏性,会删除一个现有UDP端口并断开当前SSH会话)"
      if [[ $udp_ports -ge 3 ]]; then
          if [ "$ALLOW_PORT_ADJUST" != "1" ]; then
              red "即将删除的UDP端口可能正被你其他服务占用,脚本不会未经确认擅自删除。"
              red "如确认可以删除一个现有UDP端口来腾出TCP配额,请加上环境变量 ALLOW_PORT_ADJUST=1 重新运行本脚本。"
              exit 1
          fi
          udp_port_to_delete=$(echo "$port_list" | awk '/udp/ {print $1}' | head -n 1)
          yellow "5秒后将删除UDP端口: $udp_port_to_delete (Ctrl+C 可取消)"
          sleep 5
          devil port del udp $udp_port_to_delete
          green "已删除udp端口: $udp_port_to_delete"
      else
          red "UDP端口数不足3个,无法通过删除UDP端口来腾出TCP配额,请手动在devil面板处理后重试"
          exit 1
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
      devil binexec on >/dev/null 2>&1
      red "端口已调整完成! 5秒后将主动断开当前SSH连接以使新端口生效,请重新连接SSH后再次执行本脚本"
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

# ---------------------------------------------------------------
# 统一判断 ARGO_AUTH 属于哪种模式
#   token        : Cloudflare Zero Trust 后台生成的 Tunnel Token(纯 base64 风格长字符串)
#   tunnelsecret : cloudflared tunnel create 生成的 JSON 凭证(含 TunnelSecret 字段)
#   quick        : 未设置 ARGO_AUTH/ARGO_DOMAIN,退回临时隧道
# ---------------------------------------------------------------
detect_argo_mode() {
    if [[ -z $ARGO_AUTH || -z $ARGO_DOMAIN ]]; then
        ARGO_MODE="quick"
    elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
        ARGO_MODE="tunnelsecret"
    elif [[ $ARGO_AUTH =~ ^[A-Za-z0-9=]{120,250}$ ]]; then
        ARGO_MODE="token"
    else
        red "无法识别 ARGO_AUTH 的格式(既不是 Tunnel Token,也不是包含 TunnelSecret 的 JSON 凭证),请检查该值是否正确"
        exit 1
    fi
}

# ---------------------------------------------------------------
# Argo 隧道配置
# ---------------------------------------------------------------
argo_configure() {
  detect_argo_mode
  if [ "$ARGO_MODE" = "quick" ]; then
    green "ARGO_DOMAIN 或 ARGO_AUTH 为空,使用临时隧道(quick tunnel)"
    return
  fi

  if [ "$ARGO_MODE" = "tunnelsecret" ]; then
    echo $ARGO_AUTH > "${CONF_DIR}/tunnel.json"

    if command -v python3 >/dev/null 2>&1; then
        TUNNEL_ID=$(python3 -c "import json,sys; print(json.load(open('${CONF_DIR}/tunnel.json'))['TunnelID'])" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        TUNNEL_ID=$(sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${CONF_DIR}/tunnel.json" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        red "无法从 ARGO_AUTH 中解析出 TunnelID,请检查该 JSON 凭证是否完整(需包含 TunnelID 字段)"
        exit 1
    fi

    cat > "${CONF_DIR}/tunnel.yml" << EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CONF_DIR}/tunnel.json
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
step "配置 Argo 隧道"
argo_configure

# ---------------------------------------------------------------
# 下载核心程序(serv00 FreeBSD 二进制,来源: Joshuagpt/Go_Real release v1)
#   runtime -> 本地保存为 web (xray)
#   serv    -> 本地保存为 bot (cloudflared)
# ---------------------------------------------------------------
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
      green "web 已存在,跳过下载(如需强制重下载,用 update 子命令或设置 FORCE_REDOWNLOAD=1)"
  else
      purple "正在下载 web(xray)..."
      fetch_with_retry "${BASE_URL}/${WEB_ASSET}" "${BIN_DIR}/web" || exit 1
      chmod +x "${BIN_DIR}/web"
  fi
  if [ -x "${BIN_DIR}/bot" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
      green "bot 已存在,跳过下载"
  else
      purple "正在下载 bot(cloudflared)..."
      fetch_with_retry "${BASE_URL}/${BOT_ASSET}" "${BIN_DIR}/bot" || exit 1
      chmod +x "${BIN_DIR}/bot"
  fi
  XRAY_BIN="${BIN_DIR}/web"
  CLOUDFLARED_BIN="${BIN_DIR}/bot"
}
step "下载并校验核心程序(网络耗时最长的一步,请耐心等待)"
download_binaries

# ---------------------------------------------------------------
# WARP 出站: 平台能力检测(只做低成本的配置格式预检)
# ---------------------------------------------------------------
check_warp_supported() {
    [ "$WARP" = "1" ] || return 0

    purple "正在检测当前 serv00 二进制是否认识 WARP(wireguard outbound)配置..."
    local test_conf="${TMP_DIR}/.warp_probe.json" probe_out
    mkdir -p "$TMP_DIR"
    cat > "$test_conf" <<'EOF'
{
  "outbounds": [
    {
      "protocol": "wireguard",
      "tag": "warp-probe",
      "settings": {
        "secretKey": "wIol6i8Wl4Wp+i6PXVXwZBoTr6Ez2FZ3+Rjez7cvvV0=",
        "address": ["172.16.0.2/32"],
        "peers": [
          { "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": "162.159.192.1:2408" }
        ]
      }
    }
  ]
}
EOF
    probe_out=$("${BIN_DIR}/web" -test -c "$test_conf" 2>&1)
    rm -f "$test_conf"

    if echo "$probe_out" | grep -qiE "unknown (outbound )?protocol|not registered|invalid protocol|unknown config"; then
        red "当前 serv00 平台使用的二进制不支持 WARP(wireguard)出站,已自动关闭 WARP,其余部分正常安装"
        export WARP=0
        return 1
    fi
    if echo "$probe_out" | grep -qiE "flag provided but not defined|unknown (flag|command)|no such (flag|command)"; then
        red "当前 serv00 二进制不支持 -test 配置校验模式,无法做后续的真实联通性测试,出于稳妥考虑已自动关闭 WARP"
        export WARP=0
        return 1
    fi
    green "WARP(wireguard outbound)配置格式预检通过,下一步会用真实密钥做实际联通性测试"
}

# ---------------------------------------------------------------
# WARP 出站: 自动注册凭据(仅在 WARP=1 且尚未注册过时执行)
# ---------------------------------------------------------------
warp_register() {
    [ "$WARP" = "1" ] || return 0

    if [ -f "$PROFILE_CONF" ]; then
        purple "检测到已保存的 WARP 账号凭据,直接复用: ${PROFILE_CONF}(不会重新注册)"
        return 0
    fi

    purple "未找到已保存的 WARP 账号,正在自动注册一个新账号..."

    if ! command -v openssl >/dev/null 2>&1; then
        red "未找到 openssl,无法生成 WARP 所需的密钥对,WARP 出站功能已跳过(其余部分正常安装)"
        export WARP=0; return 1
    fi

    local py_bin=""
    if command -v python3 >/dev/null 2>&1; then
        py_bin="python3"
    fi
    if [ -z "$py_bin" ]; then
        red "未找到 python3(解析注册结果需要用到),WARP 出站功能已跳过"
        export WARP=0; return 1
    fi

    local tmpdir priv_pem priv_key_b64 pub_key_b64
    tmpdir=$(mktemp -d 2>/dev/null || echo "${TMP_DIR}/.warp_tmp")
    mkdir -p "$tmpdir"
    priv_pem="${tmpdir}/priv.pem"
    openssl genpkey -algorithm X25519 -out "$priv_pem" >/dev/null 2>&1
    if [ ! -s "$priv_pem" ]; then
        red "生成 WireGuard 密钥对失败(openssl 版本可能过旧,不支持 X25519),WARP 出站功能已跳过"
        rm -rf "$tmpdir"; export WARP=0; return 1
    fi
    priv_key_b64=$(openssl pkey -in "$priv_pem" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
    pub_key_b64=$(openssl pkey -in "$priv_pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
    rm -rf "$tmpdir"
    if [ -z "$priv_key_b64" ] || [ -z "$pub_key_b64" ]; then
        red "提取 WireGuard 密钥失败,WARP 出站功能已跳过"
        export WARP=0; return 1
    fi

    local reg_resp="${TMP_DIR}/.warp_reg_resp.json" tos_ts body
    tos_ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || echo "2024-01-01T00:00:00.000Z")
    body=$(printf '{"key":"%s","tos":"%s","type":"PC","model":"PC","locale":"en_US"}' "$pub_key_b64" "$tos_ts")

    if [ "$HAVE_CURL" = 1 ]; then
        curl -fsSL -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
            -H "Content-Type: application/json" -H "User-Agent: okhttp/3.12.1" \
            -d "$body" -o "$reg_resp" --connect-timeout 10 --max-time 20
    else
        wget -q -T 20 --header="Content-Type: application/json" --header="User-Agent: okhttp/3.12.1" \
            --post-data="$body" -O "$reg_resp" "https://api.cloudflareclient.com/v0a2158/reg"
    fi

    if [ ! -s "$reg_resp" ]; then
        red "WARP 账号注册请求失败(网络问题或接口暂不可达),WARP 出站功能已跳过"
        rm -f "$reg_resp"; export WARP=0; return 1
    fi

    "$py_bin" - "$reg_resp" "$priv_key_b64" > "${PROFILE_CONF}.tmp" <<'PYEOF'
import json, base64, sys
resp_path, priv_key = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(resp_path))
    cfg = d["config"]
    peer = cfg["peers"][0]
    client_id_b64 = cfg.get("client_id", "")
    pad = client_id_b64 + "=" * (-len(client_id_b64) % 4)
    raw = base64.b64decode(pad) if client_id_b64 else b"\x00\x00\x00"
    reserved = ",".join(str(b) for b in raw[:3])
    v4 = cfg.get("interface", {}).get("addresses", {}).get("v4", "")
    v6 = cfg.get("interface", {}).get("addresses", {}).get("v6", "")
    endpoint = peer.get("endpoint", {}).get("host") or "engage.cloudflareclient.com:2408"
    print("WARP_PRIVATE_KEY=%r" % priv_key)
    print("WARP_ADDRESS_V4=%r" % v4)
    print("WARP_ADDRESS_V6=%r" % v6)
    print("WARP_PEER_PUBLIC_KEY=%r" % peer["public_key"])
    print("WARP_ENDPOINT=%r" % endpoint)
    print("WARP_RESERVED=%r" % reserved)
except Exception as e:
    sys.stderr.write("parse_error: %s\n" % e)
    sys.exit(1)
PYEOF
    local parse_rc=$?
    rm -f "$reg_resp"

    if [ "$parse_rc" -ne 0 ] || [ ! -s "${PROFILE_CONF}.tmp" ]; then
        red "解析 WARP 注册返回结果失败(接口返回格式可能已变化),WARP 出站功能已跳过"
        rm -f "${PROFILE_CONF}.tmp"; export WARP=0; return 1
    fi

    mv "${PROFILE_CONF}.tmp" "$PROFILE_CONF"
    chmod 600 "$PROFILE_CONF" >/dev/null 2>&1
    green "WARP 账号注册成功,凭据已保存到 ${PROFILE_CONF}(以后 re/update 会直接复用,不会重新注册)"
}

# ---------------------------------------------------------------
# WARP 出站: 真实联通性测试(用真实注册的密钥)
# ---------------------------------------------------------------
warp_live_test() {
    [ "$WARP" = "1" ] || return 0
    [ -f "$PROFILE_CONF" ] || { export WARP=0; return 1; }

    if ! bash -n "$PROFILE_CONF" 2>/dev/null; then
        red "WARP 凭据文件语法异常,跳过联通性测试并关闭 WARP"
        export WARP=0; return 1
    fi
    # shellcheck disable=SC1090
    source "$PROFILE_CONF"
    if [ -z "$WARP_PRIVATE_KEY" ] || [ -z "$WARP_PEER_PUBLIC_KEY" ]; then
        red "WARP 凭据缺少必要字段,跳过联通性测试并关闭 WARP"
        export WARP=0; return 1
    fi

    local endpoint_host="${WARP_ENDPOINT%%:*}"
    [ -z "$endpoint_host" ] && endpoint_host="engage.cloudflareclient.com"

    local candidate_ports=(2408 500 1701 4500 8854 8886)

    purple "正在用真实密钥对 WARP 做联通性实测(会依次尝试 ${#candidate_ports[@]} 个候选端口,每个约需3-5秒)..."

    local port try_port test_conf test_log test_pid trace_out probe_port ok=1 last_reason="" last_log=""
    test_conf="${TMP_DIR}/.warp_live_test.json"
    test_log="${TMP_DIR}/.warp_live_test.log"

    for try_port in "${candidate_ports[@]}"; do
        probe_port=$PORT

        cat > "$test_conf" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "127.0.0.1", "port": ${probe_port}, "protocol": "http", "settings": {} }
  ],
  "outbounds": [
    {
      "protocol": "wireguard",
      "tag": "warp-out",
      "settings": {
        "secretKey": "${WARP_PRIVATE_KEY}",
        "address": ["${WARP_ADDRESS_V4:-172.16.0.2/32}", "${WARP_ADDRESS_V6:-::/128}"],
        "peers": [
          { "publicKey": "${WARP_PEER_PUBLIC_KEY}", "endpoint": "${endpoint_host}:${try_port}" }
        ],
        "reserved": [${WARP_RESERVED:-0,0,0}],
        "mtu": 1280
      }
    }
  ]
}
EOF

        : > "$test_log"
        ( cd "$BIN_DIR" && ./web -c "$test_conf" > "$test_log" 2>&1 & echo $! > "${TMP_DIR}/.warp_live_test.pid" )

        local waited=0
        while [ "$waited" -lt 5 ]; do
            if command -v timeout >/dev/null 2>&1; then
                timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/${probe_port}" >/dev/null 2>&1 && break
            else
                (exec 3<>"/dev/tcp/127.0.0.1/${probe_port}") >/dev/null 2>&1 && { exec 3>&- 3<&-; break; }
            fi
            sleep 0.5
            waited=$((waited + 1))
        done

        if [ "$HAVE_CURL" = 1 ]; then
            trace_out=$(curl -s -m 8 -x "http://127.0.0.1:${probe_port}" "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null)
        else
            trace_out=$(http_proxy="http://127.0.0.1:${probe_port}" https_proxy="http://127.0.0.1:${probe_port}" wget -qO- -T 8 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null)
        fi

        test_pid=$(cat "${TMP_DIR}/.warp_live_test.pid" 2>/dev/null)
        local proc_alive=0
        [ -n "$test_pid" ] && kill -0 "$test_pid" >/dev/null 2>&1 && proc_alive=1
        [ -n "$test_pid" ] && kill -9 "$test_pid" >/dev/null 2>&1

        if echo "$trace_out" | grep -q "warp=on"; then
            green "WARP 联通性测试通过(端口 ${try_port} 握手成功,已确认流量实际经由 WARP 出口,warp=on)"
            WARP_ENDPOINT="${endpoint_host}:${try_port}"
            sed -i.bak "s|^WARP_ENDPOINT=.*|WARP_ENDPOINT=$(printf '%q' "$WARP_ENDPOINT")|" "$PROFILE_CONF" 2>/dev/null
            rm -f "${PROFILE_CONF}.bak"
            ok=0
            break
        fi

        last_log=$(tail -c 2000 "$test_log" 2>/dev/null)
        if [ "$proc_alive" -eq 0 ] && [ "$waited" -ge 5 ]; then
            last_reason="进程在探测窗口内已经退出,且本地端口全程未监听(启动阶段就失败了,和 WARP 是否可达无关)"
        elif [ "$waited" -ge 5 ]; then
            last_reason="进程还活着,但本地端口一直没监听上(可能是这个版本二进制处理该配置的方式和预期不同)"
        else
            last_reason="端口 ${try_port} 本地已监听,但没拿到 warp=on 响应(更像是 WireGuard 握手本身被拦截/超时)"
        fi
    done

    rm -f "$test_conf" "$test_log" "${TMP_DIR}/.warp_live_test.pid"

    if [ "$ok" -eq 0 ]; then
        return 0
    fi

    red "WARP 联通性测试失败: 已依次尝试 ${candidate_ports[*]} 共 ${#candidate_ports[@]} 个 UDP 端口,全部未能确认 warp=on。"
    red "最后一次失败原因: ${last_reason}"
    if [ -n "$last_log" ]; then
        red "xray 进程最后输出的原始日志(供排查,最多2000字节):"
        echo "$last_log"
    else
        red "xray 进程本次没有任何标准输出/报错(在这个版本二进制上比较反常,值得注意)"
    fi
    red "如果每个端口都是同样的失败表现,大概率是 serv00 这台机器的出站 UDP 被平台整体限制(FreeBSD jail 环境常见),不是配置问题;"
    red "可以登录 SSH 手动执行: nc -u -vz -w3 ${endpoint_host} 2408 (或其它候选端口)做进一步确认。"
    red "已自动关闭 WARP 并回退为直连出站,确保节点其余功能可用;WARP 凭据已保留,以后该限制解除后可直接复用,无需重新注册。"
    export WARP=0
    return 1
}

if [ "$WARP" = "1" ]; then
    step "配置 WARP 出站(平台兼容性检测 + 账号凭据 + 真实联通性测试)"
    check_warp_supported
    warp_register
    warp_live_test
fi

# ---------------------------------------------------------------
# 生成 Xray 配置(协议 vless+ws)
# ---------------------------------------------------------------
generate_config() {
  local uuid_json
  uuid_json=$(json_escape "$UUID")

  local warp_outbound="" warp_routing=""
  if [ "$WARP" = "1" ] && [ -f "$PROFILE_CONF" ]; then
    if bash -n "$PROFILE_CONF" 2>/dev/null; then
        # shellcheck disable=SC1090
        source "$PROFILE_CONF"
    else
        red "WARP 凭据文件语法异常(可能被篡改或损坏),本次跳过 WARP 出站;已将坏文件隔离,下次 re/update 会自动重新注册"
        mv -f "$PROFILE_CONF" "${PROFILE_CONF}.corrupt.$(date +%s)" 2>/dev/null
    fi
    if [ -n "$WARP_PRIVATE_KEY" ] && [ -n "$WARP_PEER_PUBLIC_KEY" ]; then
        warp_outbound=",
        {
            \"protocol\": \"wireguard\",
            \"tag\": \"warp-out\",
            \"settings\": {
                \"secretKey\": \"${WARP_PRIVATE_KEY}\",
                \"address\": [\"${WARP_ADDRESS_V4:-172.16.0.2/32}\", \"${WARP_ADDRESS_V6:-::/128}\"],
                \"peers\": [
                    { \"publicKey\": \"${WARP_PEER_PUBLIC_KEY}\", \"endpoint\": \"${WARP_ENDPOINT:-engage.cloudflareclient.com:2408}\" }
                ],
                \"reserved\": [${WARP_RESERVED:-0,0,0}],
                \"mtu\": 1280
            }
        }"
        warp_routing=",
    \"routing\": {
        \"rules\": [
            { \"type\": \"field\", \"outboundTag\": \"warp-out\", \"network\": \"tcp,udp\" }
        ]
    }"
    fi
  fi

  cat > "$SERVICE_CONF" << EOF
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
                  "path": "/data-sync?ed=2560"
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

# ---------------------------------------------------------------
# 启动服务(serv00 无 systemd 权限,用 nohup 后台进程 + cron 巡检保活)
# ---------------------------------------------------------------
start_services() {
  cd "$BIN_DIR" || exit 1
  nohup ./web -c "$SERVICE_CONF" >/dev/null 2>&1 &
  echo $! > "${RUN_DIR}/web.pid"
  sleep 2
  if pgrep -f "web -c $SERVICE_CONF" >/dev/null; then
      green "xray(web) 运行中"
  else
      red "xray(web) 未运行,重试中..."
      [ -f "${RUN_DIR}/web.pid" ] && kill -9 "$(cat "${RUN_DIR}/web.pid")" >/dev/null 2>&1
      nohup ./web -c "$SERVICE_CONF" >/dev/null 2>&1 &
      echo $! > "${RUN_DIR}/web.pid"
      sleep 2
  fi

  detect_argo_mode
  case "$ARGO_MODE" in
      token)        args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}" ;;
      tunnelsecret) args="tunnel --edge-ip-version auto --config ${CONF_DIR}/tunnel.yml run" ;;
      *)            args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile ${WORKDIR}/boot.log --loglevel info --url http://localhost:$PORT" ;;
  esac
  nohup ./bot $args >/dev/null 2>&1 &
  echo $! > "${RUN_DIR}/bot.pid"
  sleep 2
  if pgrep -f "bot" >/dev/null; then
      green "cloudflared(bot) 运行中"
  else
      red "cloudflared(bot) 未运行,重试中..."
      [ -f "${RUN_DIR}/bot.pid" ] && kill -9 "$(cat "${RUN_DIR}/bot.pid")" >/dev/null 2>&1
      nohup ./bot $args >/dev/null 2>&1 &
      echo $! > "${RUN_DIR}/bot.pid"
      sleep 2
  fi
}
step "启动服务"
start_services
save_state

# ---------------------------------------------------------------
# 获取 Argo 域名
# ---------------------------------------------------------------
get_argodomain() {
  if [[ -n $ARGO_AUTH ]]; then
    echo "$ARGO_DOMAIN"
  else
    purple "正在等待 Cloudflare 分配临时隧道域名(最多等待约 6 秒)..." >&2
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
# 心跳监控: 只要 TG_TOKEN + TG_ID 同时设置就自动启用,无需额外开关
# ---------------------------------------------------------------
install_healthcheck() {
    if [ -z "$TG_TOKEN" ] || [ -z "$TG_ID" ]; then
        yellow "未设置 TG_TOKEN / TG_ID,跳过 TG 通知(健康检查脚本仍会安装,供订阅触发式保活使用;如需 TG 通知,带上这两个环境变量重新执行本脚本即可)"
    else
        purple "检测到 TG_TOKEN/TG_ID,已启用心跳异常的 TG 通知"
    fi

    cat > "$HEALTH_SCRIPT" << 'HEALTHEOF'
#!/bin/bash
# 由 vless-argo 主脚本自动生成,请勿手动编辑;重新执行主脚本会覆盖,de 卸载时会自动删除
export LC_ALL=C
STATE_FILE="__STATE_FILE__"
RUN_DIR="__RUN_DIR__"
HEALTH_STATE_FILE="__HEALTH_STATE__"
BIN_DIR="__BIN_DIR__"
CONF_DIR="__CONF_DIR__"
WORKDIR="__WORKDIR__"

LOCK_DIR="${RUN_DIR}/.health.lock"
if [ -d "$LOCK_DIR" ]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    [ "$lock_age" -gt 120 ] && rm -rf "$LOCK_DIR" 2>/dev/null
fi
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

[ -f "$STATE_FILE" ] || exit 0
# shellcheck disable=SC1090
source "$STATE_FILE"

TG_TOKEN="$SAVED_TG_TOKEN"
TG_ID="$SAVED_TG_ID"

urlencode() {
    local s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%02X' "'$c"
               out+="%${hex}" ;;
        esac
    done
    printf '%s' "$out"
}

tg_send() {
    [ -z "$TG_TOKEN" ] && return 0
    [ -z "$TG_ID" ] && return 0
    local text="$1" attempt=0 ok=1 resp_file
    resp_file="$(mktemp 2>/dev/null || echo "/tmp/.tgresp_$$")"
    while [ $attempt -lt 2 ]; do
        attempt=$((attempt + 1))
        if command -v curl >/dev/null 2>&1; then
            curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${TG_ID}" \
                --data-urlencode "text=${text}" -o "$resp_file" 2>/dev/null
            grep -q '"ok":true' "$resp_file" 2>/dev/null && ok=0
        elif command -v wget >/dev/null 2>&1; then
            wget -q -T 10 -O "$resp_file" \
                "https://api.telegram.org/bot${TG_TOKEN}/sendMessage?chat_id=$(urlencode "$TG_ID")&text=$(urlencode "$text")" \
                >/dev/null 2>&1
            grep -q '"ok":true' "$resp_file" 2>/dev/null && ok=0
        fi
        [ "$ok" -eq 0 ] && break
        sleep 3
    done
    rm -f "$resp_file"
    return $ok
}

is_port_open() {
    local port="$1"
    [ -z "$port" ] && return 1
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
    else
        (exec 3<>"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
    fi
}

is_alive_xray() {
    [ -f "${RUN_DIR}/web.pid" ] && kill -0 "$(cat "${RUN_DIR}/web.pid" 2>/dev/null)" >/dev/null 2>&1 || return 1
    is_port_open "$SAVED_PORT"
}

is_alive_cf() {
    [ -f "${RUN_DIR}/bot.pid" ] && kill -0 "$(cat "${RUN_DIR}/bot.pid" 2>/dev/null)" >/dev/null 2>&1
}

restart_xray() {
    [ -f "${RUN_DIR}/web.pid" ] && kill -9 "$(cat "${RUN_DIR}/web.pid" 2>/dev/null)" >/dev/null 2>&1
    ( cd "$BIN_DIR" && nohup ./web -c "${CONF_DIR}/service.json" >/dev/null 2>&1 & echo $! > "${RUN_DIR}/web.pid" )
    sleep 3
    is_alive_xray
}

restart_cf() {
    [ -f "${RUN_DIR}/bot.pid" ] && kill -9 "$(cat "${RUN_DIR}/bot.pid" 2>/dev/null)" >/dev/null 2>&1
    ( cd "$BIN_DIR" && nohup ./bot ${SAVED_BOT_ARGS} >/dev/null 2>&1 & echo $! > "${RUN_DIR}/bot.pid" )
    sleep 3
    is_alive_cf
}

get_current_domain() {
    local wait_retries="${1:-0}" n=0 d=""
    if [ -n "$SAVED_ARGO_AUTH" ]; then
        echo "$SAVED_ARGO_DOMAIN"
        return
    fi
    while :; do
        d=$(grep -oE 'https://[[:alnum:]+.-]+\.trycloudflare\.com' "${SAVED_WORKDIR}/boot.log" 2>/dev/null | tail -n1 | sed 's@https://@@')
        [ -n "$d" ] && break
        n=$((n + 1))
        [ "$n" -gt "$wait_retries" ] && break
        sleep 1
    done
    echo "$d"
}

prev_xray="up"; prev_cf="up"; prev_domain=""
if [ -f "$HEALTH_STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$HEALTH_STATE_FILE"
fi

cur_xray="down"; is_alive_xray && cur_xray="up"
cur_cf="down"; is_alive_cf && cur_cf="up"
cf_restarted=0
msg=""

if [ "$cur_xray" = "down" ] && [ "$prev_xray" != "down" ]; then
    if restart_xray; then
        cur_xray="up"
        msg="${msg}⚠️ xray(节点) 掉线,已自动重启成功 ✅"$'\n'
    else
        msg="${msg}🔴 xray(节点) 掉线,自动重启失败,请人工检查 ❌"$'\n'
    fi
elif [ "$cur_xray" = "up" ] && [ "$prev_xray" = "down" ]; then
    msg="${msg}✅ xray(节点) 已恢复正常"$'\n'
fi

if [ "$cur_cf" = "down" ] && [ "$prev_cf" != "down" ]; then
    if restart_cf; then
        cur_cf="up"
        cf_restarted=1
        msg="${msg}⚠️ cloudflared(隧道) 掉线,已自动重启成功 ✅"$'\n'
    else
        msg="${msg}🔴 cloudflared(隧道) 掉线,自动重启失败,请人工检查 ❌"$'\n'
    fi
elif [ "$cur_cf" = "up" ] && [ "$prev_cf" = "down" ]; then
    msg="${msg}✅ cloudflared(隧道) 已恢复正常"$'\n'
fi

if [ "$cf_restarted" -eq 1 ]; then
    cur_domain="$(get_current_domain 6)"
else
    cur_domain="$(get_current_domain 0)"
fi
[ -z "$cur_domain" ] && cur_domain="$prev_domain"

if [ -n "$prev_domain" ] && [ -n "$cur_domain" ] && [ "$prev_domain" != "$cur_domain" ]; then
    new_link="vless://${SAVED_UUID}@${SAVED_CFIP}:${SAVED_CFPORT}?encryption=none&security=tls&sni=${cur_domain}&type=ws&host=${cur_domain}&path=%2Fdata-sync%3Fed%3D2560#vless-argo-serv00-$(hostname)"
    msg="${msg}🔄 Argo隧道域名已变化: ${prev_domain} → ${cur_domain}"$'\n'"新节点链接:"$'\n'"${new_link}"$'\n'
    if [ -n "$SAVED_WORKDIR" ] && [ -d "$SAVED_WORKDIR" ]; then
        echo "$new_link" > "${SAVED_WORKDIR}/current_link.txt" 2>/dev/null
        chmod 600 "${SAVED_WORKDIR}/current_link.txt" 2>/dev/null
    fi
fi

if [ -n "$msg" ]; then
    tg_send "$(hostname) vless-argo 状态变化:"$'\n'"${msg}"
fi

cat > "$HEALTH_STATE_FILE" <<EOF2
prev_xray=${cur_xray}
prev_cf=${cur_cf}
prev_domain=${cur_domain}
EOF2
HEALTHEOF

    local health_tmp="${HEALTH_SCRIPT}.tmp.$$"
    local state_file_esc run_dir_esc health_state_esc bin_dir_esc conf_dir_esc workdir_esc
    state_file_esc=$(sed_repl_escape "$STATE_FILE")
    run_dir_esc=$(sed_repl_escape "$RUN_DIR")
    health_state_esc=$(sed_repl_escape "$HEALTH_STATE")
    bin_dir_esc=$(sed_repl_escape "$BIN_DIR")
    conf_dir_esc=$(sed_repl_escape "$CONF_DIR")
    workdir_esc=$(sed_repl_escape "$WORKDIR")
    sed \
        -e "s#__STATE_FILE__#${state_file_esc}#g" \
        -e "s#__RUN_DIR__#${run_dir_esc}#g" \
        -e "s#__HEALTH_STATE__#${health_state_esc}#g" \
        -e "s#__BIN_DIR__#${bin_dir_esc}#g" \
        -e "s#__CONF_DIR__#${conf_dir_esc}#g" \
        -e "s#__WORKDIR__#${workdir_esc}#g" \
        "$HEALTH_SCRIPT" > "$health_tmp" && mv "$health_tmp" "$HEALTH_SCRIPT"
    chmod +x "$HEALTH_SCRIPT"

    cat > "$HEALTH_STATE" <<EOF
prev_xray=up
prev_cf=up
EOF

    remove_healthcheck_schedule
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK"; echo "*/10 * * * * ${HEALTH_SCRIPT} >/dev/null 2>&1 # ${HEALTH_MARK}" ) | crontab -
        green "已通过 crontab 启用内部巡检保活(每10分钟一次)"
    else
        red "未找到 crontab 命令,心跳脚本已生成但未能自动加入定时任务,请手动配置: */10 * * * * ${HEALTH_SCRIPT}"
    fi
}

# ---------------------------------------------------------------
# 伪装主页: 在站点根目录放一个正常网站样式的 index.html
# ---------------------------------------------------------------
install_homepage() {
    local homepage="${FILE_PATH}/index.html"
    cat > "$homepage" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Project Oceanus - Marine Ecology Monitoring</title>
<style>
  :root {
    --deep-blue: #050b14;
    --water: #0a192f;
    --cyan: #64ffda;
    --text-main: #ccd6f6;
    --text-muted: #8892b0;
  }
  body {
    margin: 0;
    padding: 0;
    background-color: var(--deep-blue);
    background-image:
      radial-gradient(circle at 15% 50%, rgba(100, 255, 218, 0.08), transparent 25%),
      radial-gradient(circle at 85% 30%, rgba(10, 25, 47, 0.8), transparent 25%);
    color: var(--text-main);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    display: flex;
    justify-content: center;
    align-items: center;
    min-height: 100vh;
    overflow: hidden;
  }
  .orb {
    position: absolute;
    border-radius: 50%;
    filter: blur(80px);
    opacity: 0.5;
    animation: float 10s infinite alternate ease-in-out;
    z-index: 0;
  }
  .orb-1 { width: 300px; height: 300px; background: #112240; top: -100px; left: -100px; }
  .orb-2 { width: 400px; height: 400px; background: rgba(100, 255, 218, 0.04); bottom: -150px; right: -100px; animation-delay: -5s; }
  .container {
    position: relative;
    z-index: 1;
    width: 90%;
    max-width: 580px;
    background: rgba(10, 25, 47, 0.65);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid rgba(100, 255, 218, 0.1);
    border-radius: 16px;
    padding: 45px 40px;
    box-shadow: 0 20px 40px rgba(0,0,0,0.4);
  }
  .header { text-align: center; margin-bottom: 25px; }
  .logo { display: inline-block; width: 48px; height: 48px; border: 2px solid var(--cyan); border-radius: 50%; margin-bottom: 18px; position: relative; }
  .logo::after { content: ''; position: absolute; top: 10px; left: 10px; right: 10px; bottom: 10px; background: var(--cyan); border-radius: 50%; animation: pulse 2.5s infinite ease-in-out; }
  h1 { margin: 0; font-weight: 600; font-size: 1.7rem; color: #e6f1ff; letter-spacing: 1px; }
  p.subtitle { color: var(--cyan); font-size: 0.85rem; margin-top: 8px; text-transform: uppercase; letter-spacing: 2px; }
  .content { color: var(--text-muted); line-height: 1.65; text-align: justify; font-size: 0.95rem; margin-bottom: 35px; }
  .stats-container { display: grid; grid-template-columns: repeat(3, 1fr); gap: 15px; margin-bottom: 35px; }
  .stat-box { background: rgba(255, 255, 255, 0.02); border: 1px solid rgba(255, 255, 255, 0.04); border-radius: 10px; padding: 16px 10px; text-align: center; }
  .stat-value { display: block; color: var(--text-main); font-size: 1.25rem; font-weight: bold; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
  .stat-label { font-size: 0.7rem; color: var(--text-muted); text-transform: uppercase; margin-top: 6px; letter-spacing: 0.5px; }
  .footer { text-align: center; font-size: 0.8rem; color: rgba(136, 146, 176, 0.5); border-top: 1px solid rgba(136, 146, 176, 0.1); padding-top: 25px; line-height: 1.6; }
  @keyframes float { 0% { transform: translateY(0) scale(1); } 100% { transform: translateY(-30px) scale(1.05); } }
  @keyframes pulse { 0% { transform: scale(0.9); opacity: 0.8; } 50% { transform: scale(1.1); opacity: 0.3; } 100% { transform: scale(0.9); opacity: 0.8; } }
  @media (max-width: 480px) { .stats-container { grid-template-columns: 1fr; } .container { padding: 35px 25px; } }
</style>
</head>
<body>
  <div class="orb orb-1"></div>
  <div class="orb orb-2"></div>
  <div class="container">
    <div class="header">
      <div class="logo"></div>
      <h1>Project Oceanus</h1>
      <p class="subtitle">Global Marine Ecology Initiative</p>
    </div>
    <div class="content">
      Dedicated to the preservation of the world's most fragile deep-sea ecosystems. Our autonomous acoustic sensor network continuously analyzes water quality, thermal currents, and microplastic concentrations across oceanic trenches, providing open-source foundational data for marine biologists worldwide.
    </div>
    <div class="stats-container">
      <div class="stat-box"><span class="stat-value" id="buoy-count">1,024</span><span class="stat-label">Active Sensors</span></div>
      <div class="stat-box"><span class="stat-value">10,984m</span><span class="stat-label">Max Depth</span></div>
      <div class="stat-box"><span class="stat-value" style="color: var(--cyan);">Syncing</span><span class="stat-label">Network Status</span></div>
    </div>
    <div class="footer">
      &copy; 2026 Project Oceanus Non-Profit Foundation.<br>
      <i>Authorized researchers: Append your institutional access token to the URL path.</i>
    </div>
  </div>
  <script>
    setInterval(() => {
      const el = document.getElementById('buoy-count');
      let val = parseInt(el.innerText.replace(',', ''));
      if(Math.random() > 0.6) { val += Math.floor(Math.random() * 3); el.innerText = val.toLocaleString(); }
    }, 4000);
  </script>
</body>
</html>
HTMLEOF
    chmod 644 "$homepage" >/dev/null 2>&1
}

# ---------------------------------------------------------------
# 生成订阅链接(vless://)
#   保活双保险: 1) 内部 crontab 每10分钟巡检
#              2) 订阅 .php 每次被请求时 exec+nohup 唤醒 healthcheck.sh
# ---------------------------------------------------------------
generate_links() {
  argodomain=$(get_argodomain)
  echo -e "\e[1;32mArgoDomain: \e[1;35m${argodomain}\e[0m\n"

  NAME="vless-argo-serv00-${USERNAME}"
  LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&type=ws&host=${argodomain}&path=%2Fdata-sync%3Fed%3D2560#${NAME}"

  devil www add "${USERNAME}.${CURRENT_DOMAIN}" php > /dev/null 2>&1

  LINK_FILE="${WORKDIR}/current_link.txt"
  echo "$LINK" > "$LINK_FILE"
  chmod 600 "$LINK_FILE" >/dev/null 2>&1

  cat > "${FILE_PATH}/${SUB_TOKEN}_sync.php" << 'PHPEOF'
<?php
// 标准订阅 + 刷新即手动保活 by Go_Real_Serv00.sh
header('Content-Type: text/plain; charset=utf-8');
header('Subscription-Userinfo: upload=0; download=0; total=107374182400; expire=0');

$link_file = 'REPLACE_WITH_LINK_FILE';
$fallback_link = 'REPLACE_WITH_LINK';

$link = @file_get_contents($link_file);
$link = ($link !== false) ? trim($link) : '';
if ($link === '') {
    $link = $fallback_link;
}

$nodes = [
    $link,
];

echo implode("\n", array_filter($nodes));

$health_script = 'REPLACE_WITH_HEALTH_SCRIPT';
$disabled = array_map('trim', explode(',', (string) ini_get('disable_functions')));
if (function_exists('exec') && !in_array('exec', $disabled, true)
    && file_exists($health_script) && is_executable($health_script)) {
    exec("nohup " . escapeshellarg($health_script) . " > /dev/null 2>&1 &");
}
?>
PHPEOF

  local php_tmp="${FILE_PATH}/${SUB_TOKEN}_sync.php.tmp.$$"
  local link_esc link_file_esc health_script_esc
  link_esc=$(sed_repl_escape "$LINK")
  link_file_esc=$(sed_repl_escape "$LINK_FILE")
  health_script_esc=$(sed_repl_escape "$HEALTH_SCRIPT")
  sed \
    -e "s|REPLACE_WITH_LINK_FILE|${link_file_esc}|g" \
    -e "s|REPLACE_WITH_LINK|${link_esc}|g" \
    -e "s|REPLACE_WITH_HEALTH_SCRIPT|${health_script_esc}|g" \
    "${FILE_PATH}/${SUB_TOKEN}_sync.php" > "$php_tmp" && mv "$php_tmp" "${FILE_PATH}/${SUB_TOKEN}_sync.php"

  chmod 644 "${FILE_PATH}/${SUB_TOKEN}_sync.php" >/dev/null 2>&1

  install_homepage

  echo "$LINK"

  green "\n订阅链接（唯一入口，带手动保活，域名轮换后自动同步）: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_sync.php"
  rm -rf "${WORKDIR}/boot.log"
}

step "生成订阅链接"
generate_links

purple "\n[附加] 配置心跳监控(内部巡检 + 订阅触发双保险, TG通知可选)"
install_healthcheck

case "$ACTION" in
    re) green "\n重新配置完成! 已用新参数重启服务 (platform: serv00/ct8)\n" ;;
    update) green "\n更新完成! 已重新下载二进制并重启服务 (platform: serv00/ct8)\n" ;;
    *) green "\nRunning done! (platform: serv00/ct8)\n" ;;
esac

green "订阅地址: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_sync.php"
green "站点首页(伪装页,不含节点信息): https://${USERNAME}.${CURRENT_DOMAIN}/"
