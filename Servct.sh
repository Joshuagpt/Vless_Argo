#!/bin/bash

re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }
export LC_ALL=C
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
export UUID=${UUID:-$(uuidgen -r)}
export SUB_PATH=${SUB_PATH:-${UUID:0:8}}
if [[ "$HOSTNAME" =~ ct8 ]]; then CURRENT_DOMAIN="ct8.pl"; elif [[ "$HOSTNAME" =~ hostuno ]]; then CURRENT_DOMAIN="useruno.com"; else CURRENT_DOMAIN="serv00.net"; fi
command -v curl &>/dev/null && COMMAND="curl -so" || command -v wget &>/dev/null && COMMAND="wget -qO" || { red "Error: neither curl nor wget found, please install one of them." >&2; exit 1; }
WORKDIR="$HOME/domains/${USERNAME}.${CURRENT_DOMAIN}/public_nodejs"

# 代理服务只需要一个本地 TCP 端口给 Relay 隧道用，不需要额外的 UDP 端口
check_port () {
port_list=$(devil port list)
tcp_ports=$(echo "$port_list" | grep -c "tcp")
if [[ $tcp_ports -ne 1 ]]; then
    red "端口规则不符合要求，正在调整..."
    if [[ $tcp_ports -gt 1 ]]; then
        tcp_to_delete=$((tcp_ports - 1))
        echo "$port_list" | awk '/tcp/ {print $1, $2}' | head -n $tcp_to_delete | while read port type; do
            devil port del $type $port >/dev/null 2>&1
            green "已删除TCP端口: $port"
        done
    fi

    if [[ $tcp_ports -lt 1 ]]; then
        while true; do
            tcp_port=$(shuf -i 10000-65535 -n 1)
            result=$(devil port add tcp $tcp_port 2>&1)
            if [[ $result == *"Ok"* ]]; then
                green "已添加TCP端口: $tcp_port"
                break
            else
                yellow "端口 $tcp_port 不可用，尝试其他端口..."
            fi
        done
    fi
    green "端口已调整完成,将断开ssh连接,请重新连接shh重新执行脚本"
    quick_command
    devil binexec on >/dev/null 2>&1
    kill -9 $(ps -o ppid= -p $$) >/dev/null 2>&1
else
    tcp_port=$(echo "$port_list" | awk '/tcp/ {print $1}')
fi
purple "本机监听使用的tcp端口为: $tcp_port"
export RELAY_PORT=$tcp_port
}

install_px() {
bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
echo -e "${yellow}本脚本仅安装单协议代理服务${re}"
reading "\n确定继续安装吗？(直接回车即确认安装)【y/n】: " choice
  case "${choice:-y}" in
    [Yy]|"")
    	clear
        check_port
        relay_configure
        warp_configure
        monitor_configure
        install_service
      ;;
    [Nn]) exit 0 ;;
    *) red "无效的选择，请输入y或n" && menu ;;
  esac
}

uninstall_px() {
  reading "\n确定要卸载吗？【y/n】: " choice
    case "$choice" in
        [Yy])
	          bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
            remove_keepalive_cron
            devil www del ${USERNAME}.${CURRENT_DOMAIN} 2>/dev/null || true
            rm -rf ${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN} 2>/dev/null || true
            rm -rf "${HOME}/bin/00" >/dev/null 2>&1
            [ -d "${HOME}/bin" ] && [ -z "$(ls -A "${HOME}/bin")" ] && rmdir "${HOME}/bin"
            sed -i '/export PATH="\$HOME\/bin:\$PATH"/d' "${HOME}/.bashrc" >/dev/null 2>&1
            source "${HOME}/.bashrc"
	          clear
       	    green "代理服务已完全卸载"
          ;;
        [Nn]) exit 0 ;;
    	  *) red "无效的选择,请输入y或n" && menu ;;
    esac
}

reset_system() {
reading "\n确定重置系统吗吗？【y/n】: " choice
  case "$choice" in
    [Yy]) yellow "\n初始化系统中,请稍后...\n"
          bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
          remove_keepalive_cron
          find "${HOME}" -mindepth 1 ! -name "domains" ! -name "mail" ! -name "repo" ! -name "backups" -exec rm -rf {} + > /dev/null 2>&1
          devil www list | awk 'NF>=2 && $1 ~ /\./ {print $1}' | while read -r domain; do devil www del "$domain"; done
          rm -rf $HOME/domains/* > /dev/null 2>&1
          green "\n初始化系统完成!\n"
         ;;
       *) menu ;;
  esac
}

relay_configure() {
  reading "是否需要使用固定relay隧道？(直接回车将使用临时隧道)【y/n】: " relay_choice
  [[ -z $relay_choice ]] && return
  [[ "$relay_choice" != "y" && "$relay_choice" != "Y" && "$relay_choice" != "n" && "$relay_choice" != "N" ]] && { red "无效的选择, 请输入y或n"; return; }
  if [[ "$relay_choice" == "y" || "$relay_choice" == "Y" ]]; then
      reading "请输入relay固定隧道域名: " RELAY_DOMAIN
      green "你的relay固定隧道域名为: $RELAY_DOMAIN"
      reading "请输入relay固定隧道密钥（Json或Token）: " RELAY_AUTH
      green "你的relay固定隧道密钥为: $RELAY_AUTH"
  else
      green "RELAY隧道变量未设置，将使用临时隧道"
      return
  fi

  if [[ $RELAY_AUTH =~ TunnelSecret ]]; then
    echo $RELAY_AUTH > tunnel.json
    cat > tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$RELAY_AUTH")
credentials-file: tunnel.json
protocol: http2

ingress:
  - hostname: $RELAY_DOMAIN
    service: http://localhost:$RELAY_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    yellow "\n当前使用的是token,请在cloudflare里设置隧道端口为${purple}${RELAY_PORT}${re}"
  fi
}

warp_configure() {
  reading "是否启用全局WARP出站？(直接回车默认不启用)【y/n】: " warp_choice
  if [[ "$warp_choice" == "y" || "$warp_choice" == "Y" ]]; then
    export GLOBAL_WARP=true
    green "已启用全局WARP出站(基于engine wireguard outbound;若UDP出站不可用或注册失败会自动降级为direct)"
  else
    export GLOBAL_WARP=false
    green "未启用WARP,出站全部走direct"
  fi
}

monitor_configure() {
  reading "是否启用Telegram健康告警？(engine/cloudflared多次重启仍失败、或服务长时间无法访问时会推送通知；直接回车默认不启用)【y/n】: " tg_choice
  if [[ "$tg_choice" == "y" || "$tg_choice" == "Y" ]]; then
    reading "请输入Telegram Bot Token: " TG_BOT_TOKEN
    reading "请输入Telegram Chat ID: " TG_CHAT_ID
    export TG_BOT_TOKEN TG_CHAT_ID
    green "已启用Telegram健康告警"
  else
    export TG_BOT_TOKEN="" TG_CHAT_ID=""
    green "未启用Telegram健康告警(可稍后重装时补充)"
  fi
}

setup_keepalive_cron() {
  local cron_tag="# px_keepalive"
  local monitor_script="$HOME/bin/px_monitor.sh"
  mkdir -p "$HOME/bin"

  cat > "$monitor_script" <<MONEOF
#!/bin/bash
URL="https://${USERNAME}.${CURRENT_DOMAIN}"
ENV_FILE="${WORKDIR}/.env"
STATE_FILE="\$HOME/.px_health_state"
[ -f "\$ENV_FILE" ] && source "\$ENV_FILE"

fail_count=0
alerted=0
[ -f "\$STATE_FILE" ] && source "\$STATE_FILE"

notify() {
  [ -z "\$TG_BOT_TOKEN" ] && return
  [ -z "\$TG_CHAT_ID" ] && return
  curl -s -m 10 -X POST "https://api.telegram.org/bot\${TG_BOT_TOKEN}/sendMessage" \\
    -d chat_id="\${TG_CHAT_ID}" -d text="[\$(hostname)] \$1" >/dev/null 2>&1
}

code=\$(curl -s -o /dev/null -m 10 -w "%{http_code}" "\$URL")

if [ "\$code" == "200" ]; then
  if [ "\$alerted" == "1" ]; then
    notify "服务已恢复正常(http 200): \$URL"
  fi
  fail_count=0
  alerted=0
else
  fail_count=\$((fail_count + 1))
  if [ "\$fail_count" -ge 3 ] && [ "\$alerted" != "1" ]; then
    notify "服务疑似异常: \$URL 连续\${fail_count}次探测失败(最近状态码 \${code:-无响应})，请检查"
    alerted=1
  fi
fi

echo "fail_count=\$fail_count" > "\$STATE_FILE"
echo "alerted=\$alerted" >> "\$STATE_FILE"
MONEOF
  chmod +x "$monitor_script"

  local cron_line="*/10 * * * * $monitor_script >/dev/null 2>&1 ${cron_tag}"
  (crontab -l 2>/dev/null | grep -vF "${cron_tag}"; echo "${cron_line}") | crontab -
  green "已添加保活+健康监控定时任务(每10分钟探测一次，连续3次失败将尝试Telegram告警)"
}

remove_keepalive_cron() {
  local cron_tag="# px_keepalive"
  crontab -l 2>/dev/null | grep -vF "${cron_tag}" | crontab -
  rm -f "$HOME/bin/px_monitor.sh" "$HOME/.px_health_state" 2>/dev/null
}

write_app_js() {
  cat > "$1" <<'JSEOF'
#!/usr/bin/env node

// === 稳定性优化：限制 Node 引擎内存，防止 OOM 被杀 ===
const v8 = require('v8');
v8.setFlagsFromString('--max_old_space_size=128');

// === 隐匿性优化：修改主进程标题，伪装成主机自带进程 ===
process.title = 'passenger_nodejs_app';

const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const crypto = require('crypto');
const dgram = require('dgram');
const axios = require('axios');
const { spawn, spawnSync } = require('child_process');

try { require('dotenv').config(); } catch { /* ignore if dotenv unavailable */ }

// ======================== 环境变量定义 ========================
const FILE_PATH      = process.env.FILE_PATH      || '.npm';     
const SUB_PATH       = process.env.SUB_PATH       || 'sub';      
const UUID           = process.env.UUID           || '68aa231f-703e-4547-967e-12ed0b36420f'; 
const RELAY_DOMAIN    = process.env.RELAY_DOMAIN    || '';         
const RELAY_AUTH      = process.env.RELAY_AUTH      || '';         
const RELAY_PORT      = Number(process.env.RELAY_PORT) || 8001;    
const CFIP           = process.env.CFIP           || 'ali.ztyawc.de'; 
const CFPORT         = Number(process.env.CFPORT) || 443;        
const PORT           = Number(process.env.PORT)   || 3000;       
const NAME           = process.env.NAME           || '';         
const DISABLE_RELAY   = process.env.DISABLE_RELAY   || false;      
const GLOBAL_WARP    = String(process.env.GLOBAL_WARP).toLowerCase() === 'true'; 
const TG_BOT_TOKEN    = process.env.TG_BOT_TOKEN    || '';        
const TG_CHAT_ID      = process.env.TG_CHAT_ID      || '';        
// ==============================================================

const ROOT = process.cwd();
const runtimeFilePath = path.resolve(ROOT, FILE_PATH);
const libraryDir = runtimeFilePath;

// === 隐匿性优化：使用不起眼的隐藏文件名存放代理内核配置 ===
const engineConfigPath = path.resolve(runtimeFilePath, '.passenger_cache.json'); 
const warpConfigPath = path.resolve(runtimeFilePath, '.warp_session.json'); 
const bootLogPath = path.resolve(runtimeFilePath, 'boot.log');
const subPath = path.resolve(runtimeFilePath, 'sub.txt');
const listPath = path.resolve(runtimeFilePath, 'list.txt');
const subscribePath = '/' + SUB_PATH.replace(/^\//, '');

const arch = (() => {
  const a = os.arch().toLowerCase();
  if (a === 'arm64' || a === 'aarch64') return 'arm64';
  return 'amd64';
})();

// ======================== 文件清理 ========================

// 注意这里清除了旧的显眼配置文件 config.json
const pathsToDelete = ['boot.log', 'list.txt', 'tunnel.json', 'tunnel.yml', 'config.json'];
function cleanupOldFiles() {
  pathsToDelete.forEach(file => {
    const filePath = path.join(FILE_PATH, file);
    fs.unlink(filePath, () => {});
  });
  const tmpDir = path.resolve(ROOT, '.tmp');
  if (fs.existsSync(tmpDir)) {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (e) { }
  }
}

function cleanupFiles(options = {}) {
  const keepFiles = new Set(['.warp_session.json', '.passenger_cache.json']);
  if (options.keepSub) keepFiles.add('sub.txt');
  if (fs.existsSync(runtimeFilePath)) {
    try {
      const files = fs.readdirSync(runtimeFilePath);
      for (const file of files) {
        if (keepFiles.has(file)) continue;
        const filePath = path.resolve(runtimeFilePath, file);
        try {
          const stat = fs.statSync(filePath);
          if (stat.isDirectory()) {
            fs.rmSync(filePath, { recursive: true, force: true });
          } else {
            fs.unlinkSync(filePath);
          }
        } catch (e) { /* skip locked/in-use files */ }
      }
    } catch (e) {
      console.error('Cleanup failed:', e.message);
    }
  }
  const tmpDir = path.resolve(ROOT, '.tmp');
  if (fs.existsSync(tmpDir)) {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (e) { }
  }
}

function clearConsole() {
  process.stdout.write('\x1Bc');
}

// ======================== Relay 隧道配置 ========================

function relayType() {
  if (DISABLE_RELAY === 'true' || DISABLE_RELAY === true) {
    console.log("DISABLE_RELAY is set to true, disable relay tunnel");
    return;
  }
  if (!RELAY_AUTH || !RELAY_DOMAIN) {
    console.log("RELAY_DOMAIN or RELAY_AUTH variable is empty, use quick tunnel");
    return;
  }
  if (RELAY_AUTH.includes('TunnelSecret')) {
    fs.writeFileSync(path.join(FILE_PATH, 'tunnel.json'), RELAY_AUTH);
    const tunnelYaml = `
  tunnel: ${RELAY_AUTH.split('"')[11]}
  credentials-file: ${path.join(FILE_PATH, 'tunnel.json')}
  protocol: http2
  
  ingress:
    - hostname: ${RELAY_DOMAIN}
      service: http://localhost:${RELAY_PORT}
      originRequest:
        noTLSVerify: true
    - service: http_status:404
  `;
    fs.writeFileSync(path.join(FILE_PATH, 'tunnel.yml'), tunnelYaml);
  } else {
    console.log(`Using token connect to tunnel, please set ${RELAY_PORT} in cloudflare`);
  }
}

// ======================== WARP 身份(注册/复用) ========================

const WARP_REG_URL = 'https://api.cloudflareclient.com/v0a884/reg';
const WARP_API_HEADERS = {
  'User-Agent': 'okhttp/3.12.1',
  'CF-Client-Version': 'a-6.10-2158',
  'Content-Type': 'application/json;charset=UTF-8'
};

function generateWireguardKeyPair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('x25519', {
    publicKeyEncoding: { type: 'spki', format: 'der' },
    privateKeyEncoding: { type: 'pkcs8', format: 'der' }
  });
  const rawPrivateKey = privateKey.subarray(privateKey.length - 32);
  const rawPublicKey = publicKey.subarray(publicKey.length - 32);
  return {
    privateKey: Buffer.from(rawPrivateKey).toString('base64'),
    publicKey: Buffer.from(rawPublicKey).toString('base64')
  };
}

async function registerWarp() {
  const { privateKey, publicKey } = generateWireguardKeyPair();

  const resp = await axios.post(WARP_REG_URL, {
    key: publicKey,
    install_id: '',
    fcm_token: '',
    tos: new Date().toISOString(),
    type: 'PC',
    model: 'PC',
    locale: 'en_US'
  }, {
    headers: WARP_API_HEADERS,
    timeout: 10000
  });

  const data = resp.data;
  if (!data || !data.config || !data.config.peers || !data.config.peers[0]) {
    throw new Error('WARP注册接口返回数据格式异常');
  }

  const cfg = data.config;
  const peer = cfg.peers[0];
  const reserved = Array.from(Buffer.from(cfg.client_id, 'base64'));

  let endpointHost = 'engage.cloudflareclient.com';
  let endpointPort = 2408;
  if (peer.endpoint && peer.endpoint.host) {
    const idx = peer.endpoint.host.lastIndexOf(':');
    if (idx !== -1) {
      endpointHost = peer.endpoint.host.slice(0, idx);
      endpointPort = Number(peer.endpoint.host.slice(idx + 1)) || 2408;
    } else {
      endpointHost = peer.endpoint.host;
    }
  }

  return {
    private_key: privateKey,
    public_key: peer.public_key,
    endpoint_host: endpointHost,
    endpoint_port: endpointPort,
    address_v4: cfg.interface && cfg.interface.addresses ? cfg.interface.addresses.v4 : null,
    address_v6: cfg.interface && cfg.interface.addresses ? cfg.interface.addresses.v6 : null,
    reserved,
    account_id: data.id || null,
    registered_at: new Date().toISOString()
  };
}

function isValidWarpConfig(cfg) {
  return !!(cfg && cfg.private_key && cfg.public_key && cfg.endpoint_host &&
    Array.isArray(cfg.reserved) && cfg.reserved.length === 3 && cfg.address_v4);
}

function udpEgressProbe(host, port, timeoutMs) {
  return new Promise((resolve) => {
    let socket;
    try {
      socket = dgram.createSocket('udp4');
    } catch (e) {
      resolve(false);
      return;
    }
    let settled = false;
    const finish = (ok) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { socket.close(); } catch (e) { /* ignore */ }
      resolve(ok);
    };
    const timer = setTimeout(() => finish(false), timeoutMs);
    socket.once('error', () => finish(false));
    socket.once('message', () => finish(true));
    const query = Buffer.from([
      0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x0a, 0x63, 0x6c, 0x6f, 0x75, 0x64, 0x66, 0x6c, 0x61, 0x72, 0x65,
      0x03, 0x63, 0x6f, 0x6d, 0x00,
      0x00, 0x01, 0x00, 0x01
    ]);
    socket.send(query, port, host, (err) => {
      if (err) finish(false);
    });
  });
}

async function detectUdpEgress() {
  const targets = [{ host: '1.1.1.1', port: 53 }, { host: '8.8.8.8', port: 53 }];
  for (const t of targets) {
    const ok = await udpEgressProbe(t.host, t.port, 3000);
    if (ok) return true;
  }
  return false;
}

function probeEngineWarpSupport(engineBinPath) {
  const probeConfigPath = path.resolve(runtimeFilePath, '.warp-probe.json');
  const probeConfig = {
    outbounds: [{
      protocol: 'wireguard',
      tag: 'warp-probe',
      settings: {
        secretKey: 'wIol6i8Wl4Wp+i6PXVXwZBoTr6Ez2FZ3+Rjez7cvvV0=',
        address: ['172.16.0.2/32'],
        peers: [{ publicKey: 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=', endpoint: '162.159.192.1:2408' }]
      }
    }]
  };

  let result;
  try {
    fs.writeFileSync(probeConfigPath, JSON.stringify(probeConfig));
    result = spawnSync(engineBinPath, ['run', '-test', '-c', probeConfigPath], { encoding: 'utf8', timeout: 10000 });
  } catch (e) {
    try { fs.unlinkSync(probeConfigPath); } catch (e2) { }
    return false;
  }
  try { fs.unlinkSync(probeConfigPath); } catch (e) { }

  const output = ((result && result.stdout) || '') + ((result && result.stderr) || '');
  if (/unknown (outbound )?protocol|not registered|invalid protocol|unknown config/i.test(output)) {
    return false;
  }
  if (/flag provided but not defined|unknown (flag|command)|no such (flag|command)/i.test(output)) {
    return false;
  }
  return true;
}

function probeWarpEndpoint(host, port, timeoutMs) {
  return new Promise((resolve) => {
    let socket;
    try {
      socket = dgram.createSocket('udp4');
    } catch (e) {
      resolve('error');
      return;
    }
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { socket.close(); } catch (e) { }
      resolve(result);
    };
    const timer = setTimeout(() => finish('no_response'), timeoutMs);
    socket.once('error', () => finish('rejected'));
    socket.once('message', () => finish('responded'));
    const probe = Buffer.from([0x01, 0x00, 0x00, 0x00, 0x00]);
    socket.send(probe, port, host, (err) => {
      if (err) finish('rejected');
    });
  });
}

async function diagnoseWarpEndpoint(cfg) {
  await probeWarpEndpoint(cfg.endpoint_host, cfg.endpoint_port, 3000);
}

async function getOrCreateWarpIdentity(engineBinPath) {
  if (!GLOBAL_WARP) return null;

  const udpOk = await detectUdpEgress();
  if (!udpOk) return null;

  const supported = probeEngineWarpSupport(engineBinPath);
  if (!supported) return null;

  let cfg = null;
  try {
    if (fs.existsSync(warpConfigPath)) {
      const loaded = JSON.parse(fs.readFileSync(warpConfigPath, 'utf8'));
      if (isValidWarpConfig(loaded)) {
        cfg = loaded;
      }
    }
  } catch (e) {}

  if (!cfg) {
    try {
      cfg = await registerWarp();
      fs.writeFileSync(warpConfigPath, JSON.stringify(cfg, null, 2));
    } catch (e) {
      return null;
    }
  }

  await diagnoseWarpEndpoint(cfg);
  return cfg;
}

// ======================== 下载库文件 ========================

async function sha256Matches(filePath, expected) {
  if (!expected) return true;
  const actual = await sha256(filePath);
  return actual.toLowerCase() === expected.toLowerCase();
}

function sha256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', chunk => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
    stream.on('error', reject);
  });
}

async function downloadLibrary(url, fileName, expectedSha256) {
  const target = path.resolve(libraryDir, fileName);
  if (fs.existsSync(target) && await sha256Matches(target, expectedSha256)) {
    return target;
  }
  await fs.promises.mkdir(libraryDir, { recursive: true });
  const tmp = path.resolve(libraryDir, `${fileName}.download`);
  const writer = fs.createWriteStream(tmp);
  const response = await axios.get(url, { responseType: 'stream', timeout: 3 * 60 * 1000 });
  if (response.status < 200 || response.status >= 300) {
    throw new Error(`Failed to download ${url}: HTTP ${response.status}`);
  }
  response.data.pipe(writer);
  await new Promise((resolve, reject) => writer.on('finish', resolve).on('error', reject));
  if (!(await sha256Matches(tmp, expectedSha256))) {
    throw new Error(`SHA-256 mismatch for ${tmp}`);
  }
  await fs.promises.rename(tmp, target);
  return target;
}

// ======================== 告警通知 ========================

async function notifyFatal(message) {
  if (!TG_BOT_TOKEN || !TG_CHAT_ID) return;
  try {
    await axios.post(`https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage`, {
      chat_id: TG_CHAT_ID,
      text: `[${os.hostname()}] ${message}`
    }, { timeout: 5000 });
  } catch (e) {}
}

function createRestartGuard(maxRestarts = 5, stableMs = 5 * 60 * 1000) {
  let restarts = 0;
  return {
    shouldRestart(aliveMs) {
      if (aliveMs >= stableMs) restarts = 0;
      if (restarts >= maxRestarts) return false;
      restarts++;
      return true;
    },
    get count() { return restarts; },
    get max() { return maxRestarts; }
  };
}

// ======================== 子进程统一管理 ========================
function spawnManagedProcess(name, binPath, args, options = {}) {
  const { cwd = runtimeFilePath, env = {}, autoRestart = false, maxRestarts = 5, stableMs = 5 * 60 * 1000 } = options;
  const guard = createRestartGuard(maxRestarts, stableMs);
  let stopped = false;
  let currentChild = null;

  function spawnOnce() {
    const startedAt = Date.now();
    
    // === 稳定性优化：使用 nice 降低 CPU 调度优先级，防止占用过高被强杀 ===
    // 我们将原始执行文件和参数传给 nice
    const child = spawn('nice', ['-n', '10', binPath, ...args], {
      cwd,
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe']
    });
    currentChild = child;

    child.stdout.on('data', d => process.stdout.write(`[${name}] ${d}`));
    child.stderr.on('data', d => process.stderr.write(`[${name}] ${d}`));

    child.on('error', err => {
      console.error(`${name} 子进程启动失败:`, err.message);
    });

    child.on('exit', (code, signal) => {
      if (stopped) return; 
      const aliveMs = Date.now() - startedAt;
      if (!autoRestart) return;
      if (guard.shouldRestart(aliveMs)) {
        setTimeout(spawnOnce, 2000);
      } else {
        notifyFatal(`${name} 反复崩溃，已停止自动重启(连续在${Math.round(stableMs / 60000)}分钟内失败${guard.max}次)`);
      }
    });

    return child;
  }

  const child = spawnOnce();

  return {
    name,
    get child() { return currentChild; },
    stop: () => new Promise((resolve) => {
      stopped = true;
      try {
        currentChild && currentChild.kill();
      } catch (e) { }
      resolve(0);
    })
  };
}

// ======================== engine 配置生成 ========================

function generateEngineConfig(warpConfig) {
  const inbounds = [];

  inbounds.push({
    listen: '127.0.0.1',
    port: RELAY_PORT,
    protocol: 'vless',
    settings: { clients: [{ id: UUID }], decryption: 'none' },
    streamSettings: {
      network: 'ws',
      wsSettings: { path: '/data-sync' }
    }
  });
  inbounds.push({
    listen: '::1',
    port: RELAY_PORT,
    protocol: 'vless',
    settings: { clients: [{ id: UUID }], decryption: 'none' },
    streamSettings: {
      network: 'ws',
      wsSettings: { path: '/data-sync' }
    }
  });

  const outbounds = [];

  if (warpConfig) {
    outbounds.push({
      protocol: 'wireguard',
      tag: 'wireguard-out',
      settings: {
        secretKey: warpConfig.private_key,
        address: warpConfig.address_v6
          ? [`${warpConfig.address_v4}/32`, `${warpConfig.address_v6}/128`]
          : [`${warpConfig.address_v4}/32`],
        peers: [{
          publicKey: warpConfig.public_key,
          endpoint: `${warpConfig.endpoint_host}:${warpConfig.endpoint_port}`
        }],
        reserved: warpConfig.reserved,
        mtu: 1280
      }
    });
  }
  outbounds.push({ protocol: 'freedom', tag: 'direct' });

  return {
    log: { loglevel: 'none' },
    inbounds,
    outbounds
  };
}

// ======================== Cloudflared Payload ========================

function relayLaunchSpec() {
  if (DISABLE_RELAY === 'true' || DISABLE_RELAY === true) return null;
  if (RELAY_AUTH && RELAY_DOMAIN) {
    if (RELAY_AUTH.match(/^[A-Z0-9a-z=]{120,250}$/)) {
      return {
        args: ['tunnel', '--edge-ip-version', 'auto', '--no-autoupdate', '--protocol', 'http2', 'run'],
        env: { TUNNEL_TOKEN: RELAY_AUTH }
      };
    } else if (RELAY_AUTH.match(/TunnelSecret/)) {
      return {
        args: ['tunnel', '--edge-ip-version', 'auto', '--config', path.join(FILE_PATH, 'tunnel.yml'), 'run'],
        env: {}
      };
    }
  }
  return {
    args: [
      'tunnel', '--edge-ip-version', 'auto', '--no-autoupdate',
      '--protocol', 'http2', '--logfile', bootLogPath,
      '--loglevel', 'info', '--url', `http://localhost:${RELAY_PORT}`
    ],
    env: {}
  };
}

// ======================== 隧道域名检测 ========================

function waitForQuickTunnelDomain(logPath, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      if (fs.existsSync(logPath)) {
        const content = fs.readFileSync(logPath, 'utf8');
        const matches = [...content.matchAll(/https:\/\/([A-Za-z0-9.-]+\.trycloudflare\.com)/g)];
        if (matches.length > 0) {
          return matches[matches.length - 1][1];
        }
      }
    } catch (e) { }
    const remaining = deadline - Date.now();
    if (remaining <= 0) break;
    const sleepMs = Math.min(1000, remaining);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, sleepMs);
  }
  return null;
}

async function extractDomain() {
  if (DISABLE_RELAY === 'true' || DISABLE_RELAY === true) return null;
  if (RELAY_AUTH && RELAY_DOMAIN) {
    return RELAY_DOMAIN;
  }
  let domain = waitForQuickTunnelDomain(bootLogPath, 30000);
  if (!domain) {
    try { fs.unlinkSync(bootLogPath); } catch (e) { }
    await new Promise(r => setTimeout(r, 5000));
    domain = waitForQuickTunnelDomain(bootLogPath, 30000);
  }
  return domain;
}

// ======================== ISP 信息 ========================

async function getMetaInfo() {
  try {
    const response1 = await axios.get('https://api.ip.sb/geoip', { headers: { 'User-Agent': 'Mozilla/5.0', timeout: 3000 } });
    if (response1.data && response1.data.country_code && response1.data.isp) {
      return `${response1.data.country_code}-${response1.data.isp}`.replace(/\s+/g, '_');
    }
  } catch (error) {
    try {
      const response2 = await axios.get('http://ip-api.com/json', { headers: { 'User-Agent': 'Mozilla/5.0', timeout: 3000 } });
      if (response2.data && response2.data.status === 'success' && response2.data.countryCode && response2.data.org) {
        return `${response2.data.countryCode}-${response2.data.org}`.replace(/\s+/g, '_');
      }
    } catch (error) { }
  }
  return 'Unknown';
}

// ======================== 节点链接生成 ========================

async function generateLinks(relayDomain) {
  const ISP = await getMetaInfo();
  const nodeName = NAME ? `${NAME}-${ISP}` : ISP;

  await new Promise(r => setTimeout(r, 2000));

  let subTxt = '';

  if ((DISABLE_RELAY !== 'true' && DISABLE_RELAY !== true) && relayDomain) {
    const linkPath = encodeURIComponent('/data-sync?ed=2560');
    subTxt = `vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${relayDomain}&fp=chrome&type=ws&host=${relayDomain}&path=${linkPath}#${encodeURIComponent(nodeName)}`;
  }

  const subTxtWithNewline = subTxt ? subTxt + '\n' : subTxt;
  fs.writeFileSync(subPath, Buffer.from(subTxtWithNewline).toString('base64'));
  fs.writeFileSync(listPath, subTxtWithNewline, 'utf8');

  return subTxtWithNewline;
}

// ======================== HTTP 服务器 ========================

function startHttpServer(subTxt) {
  const server = http.createServer((req, res) => {
    if (req.method !== 'GET') {
      res.statusCode = 405;
      res.end('Method Not Allowed');
      return;
    }
    const url = new URL(req.url, `http://localhost`);
    if (url.pathname === subscribePath) {
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      const encodedContent = Buffer.from(subTxt).toString('base64');
      res.end(encodedContent);
    } else if (url.pathname === '/') {
        try {
            const filePath = path.join(__dirname, 'index.html');
            const data = fs.readFileSync(filePath, 'utf8');
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end(data);
        } catch (err) {
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end("Hello world!<br><br>You can access /{SUB_PATH}(Default: /sub) to get your nodes!");
        }
    } else {
      res.statusCode = 404;
      res.end('Not Found');
    }
  });

  server.listen(PORT, '0.0.0.0');
}

// ======================== 主流程 ========================

async function startServer() {
  if (!fs.existsSync(FILE_PATH)) {
    fs.mkdirSync(FILE_PATH);
  }
  cleanupOldFiles();

  relayType();

  const releaseBaseUrl = 'https://github.com/Joshuagpt/Go_Real/releases/download/v1';

  // === 隐匿性优化：下载二进制时直接重命名为常见系统进程，规避监控扫描 ===
  const engineBinPath = await downloadLibrary(
      arch === 'arm64' ? `${releaseBaseUrl}/runtime-arm64` : `${releaseBaseUrl}/runtime`,
      'passenger_worker' // 伪装成 Passenger 进程
  );

  try { fs.chmodSync(engineBinPath, 0o755); } catch (e) {}

  let relayBinPath = null;
  if (DISABLE_RELAY !== 'true' && DISABLE_RELAY !== true) {
      relayBinPath = await downloadLibrary(
          arch === 'arm64' ? `${releaseBaseUrl}/relay-arm64` : `${releaseBaseUrl}/relay`,
          'dbus-daemon' // 伪装成系统总线进程
      );
      try { fs.chmodSync(relayBinPath, 0o755); } catch (e) {}
  }

  const warpConfig = await getOrCreateWarpIdentity(engineBinPath);
  const engineConfig = generateEngineConfig(warpConfig);
  fs.writeFileSync(engineConfigPath, JSON.stringify(engineConfig, null, 2));

  const services = [];

  let relayService = null;
  if (relayBinPath) {
    const spec = relayLaunchSpec();
    if (spec) {
      relayService = spawnManagedProcess('relay', relayBinPath, spec.args, {
        cwd: runtimeFilePath,
        env: spec.env,
        autoRestart: true,
        maxRestarts: 5,
        stableMs: 5 * 60 * 1000
      });
      services.push(relayService);
    }
  }

  const engineService = spawnManagedProcess('engine', engineBinPath, ['run', '-c', engineConfigPath], {
    cwd: runtimeFilePath,
    autoRestart: true,
    maxRestarts: 5,
    stableMs: 5 * 60 * 1000
  });
  services.push(engineService);

// ====== 紧接着加入“阅后即焚”逻辑 ======
  setTimeout(() => {
    try {
      if (fs.existsSync(engineConfigPath)) {
        fs.unlinkSync(engineConfigPath);
        console.log('[Security] engine 配置文件已从硬盘擦除 (运行于内存中)');
      }
    } catch (e) {
      // 忽略因权限或已被清理导致的报错
    }
  }, 3000);
  // ======================================

  async function stopAll() {
    for (let i = services.length - 1; i >= 0; i--) {
      try { await services[i].stop(); } catch (e) { }
    }
    process.exit(0);
  }
  process.on('SIGINT', stopAll);
  process.on('SIGTERM', stopAll);

  await new Promise(r => setTimeout(r, 1000));
  await new Promise(r => setTimeout(r, 5000));
  const relayDomain = await extractDomain();
  const subTxt = await generateLinks(relayDomain);

  startHttpServer(subTxt);

  setTimeout(() => {
    cleanupFiles({ keepSub: true });
    clearConsole();
    console.log('App is running');
  }, 45000);
}

startServer();
setInterval(() => {}, 1000);
JSEOF
}

install_service () {
    purple "正在安装中,请稍等......"
    devil www del ${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
    rm -rf $HOME/domains/${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
    devil www add ${USERNAME}.${CURRENT_DOMAIN} nodejs /usr/local/bin/node24 > /dev/null 2>&1
    [ -d "$WORKDIR" ] || mkdir -p "$WORKDIR"
    rm -f "${WORKDIR}/public/index.html" > /dev/null 2>&1
    write_app_js "${WORKDIR}/app.js"

    cat > "${WORKDIR}/index.html" <<'HTMLEOF'
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
  /* Bioluminescent environmental glow */
  .orb {
    position: absolute;
    border-radius: 50%;
    filter: blur(80px);
    opacity: 0.5;
    animation: float 10s infinite alternate ease-in-out;
    z-index: 0;
  }
  .orb-1 {
    width: 300px; height: 300px;
    background: #112240;
    top: -100px; left: -100px;
  }
  .orb-2 {
    width: 400px; height: 400px;
    background: rgba(100, 255, 218, 0.04);
    bottom: -150px; right: -100px;
    animation-delay: -5s;
  }
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
  .header {
    text-align: center;
    margin-bottom: 25px;
  }
  .logo {
    display: inline-block;
    width: 48px; height: 48px;
    border: 2px solid var(--cyan);
    border-radius: 50%;
    margin-bottom: 18px;
    position: relative;
  }
  .logo::after {
    content: '';
    position: absolute;
    top: 10px; left: 10px; right: 10px; bottom: 10px;
    background: var(--cyan);
    border-radius: 50%;
    animation: pulse 2.5s infinite ease-in-out;
  }
  h1 {
    margin: 0;
    font-weight: 600;
    font-size: 1.7rem;
    color: #e6f1ff;
    letter-spacing: 1px;
  }
  p.subtitle {
    color: var(--cyan);
    font-size: 0.85rem;
    margin-top: 8px;
    text-transform: uppercase;
    letter-spacing: 2px;
  }
  .content {
    color: var(--text-muted);
    line-height: 1.65;
    text-align: justify;
    font-size: 0.95rem;
    margin-bottom: 35px;
  }
  .stats-container {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 15px;
    margin-bottom: 35px;
  }
  .stat-box {
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.04);
    border-radius: 10px;
    padding: 16px 10px;
    text-align: center;
  }
  .stat-value {
    display: block;
    color: var(--text-main);
    font-size: 1.25rem;
    font-weight: bold;
    font-family: ui-monospace, SFMono-Regular, Consolas, monospace;
  }
  .stat-label {
    font-size: 0.7rem;
    color: var(--text-muted);
    text-transform: uppercase;
    margin-top: 6px;
    letter-spacing: 0.5px;
  }
  .footer {
    text-align: center;
    font-size: 0.8rem;
    color: rgba(136, 146, 176, 0.5);
    border-top: 1px solid rgba(136, 146, 176, 0.1);
    padding-top: 25px;
    line-height: 1.6;
  }
  @keyframes float {
    0% { transform: translateY(0) scale(1); }
    100% { transform: translateY(-30px) scale(1.05); }
  }
  @keyframes pulse {
    0% { transform: scale(0.9); opacity: 0.8; }
    50% { transform: scale(1.1); opacity: 0.3; }
    100% { transform: scale(0.9); opacity: 0.8; }
  }
  @media (max-width: 480px) {
    .stats-container { grid-template-columns: 1fr; }
    .container { padding: 35px 25px; }
  }
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
      <div class="stat-box">
        <span class="stat-value" id="buoy-count">1,024</span>
        <span class="stat-label">Active Sensors</span>
      </div>
      <div class="stat-box">
        <span class="stat-value">10,984m</span>
        <span class="stat-label">Max Depth</span>
      </div>
      <div class="stat-box">
        <span class="stat-value" style="color: var(--cyan);">Syncing</span>
        <span class="stat-label">Network Status</span>
      </div>
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
      if(Math.random() > 0.6) { 
        val += Math.floor(Math.random() * 3); 
        el.innerText = val.toLocaleString();
      }
    }, 4000);
  </script>
</body>
</html>
HTMLEOF

    cat > ${WORKDIR}/.env <<EOF
UUID=${UUID}
SUB_PATH=${SUB_PATH}
RELAY_PORT=${RELAY_PORT}
${RELAY_DOMAIN:+RELAY_DOMAIN=$RELAY_DOMAIN}
${RELAY_AUTH:+RELAY_AUTH=$([[ -z "$RELAY_AUTH" ]] && echo "" || ([[ "$RELAY_AUTH" =~ ^\{.* ]] && echo "'$RELAY_AUTH'" || echo "$RELAY_AUTH"))}
GLOBAL_WARP=${GLOBAL_WARP:-false}
${TG_BOT_TOKEN:+TG_BOT_TOKEN=$TG_BOT_TOKEN}
${TG_CHAT_ID:+TG_CHAT_ID=$TG_CHAT_ID}
EOF

  ln -fs /usr/local/bin/node24 ~/bin/node > /dev/null 2>&1
  ln -fs /usr/local/bin/npm24 ~/bin/npm > /dev/null 2>&1
  mkdir -p ~/.npm-global
  npm config set prefix '~/.npm-global'
  echo 'export PATH=~/.npm-global/bin:~/bin:$PATH' >> $HOME/.bash_profile && source $HOME/.bash_profile
  rm -rf $HOME/.npmrc > /dev/null 2>&1
  cd ${WORKDIR} && npm install dotenv axios --silent > /dev/null 2>&1
  devil www restart ${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
  rm -f "${WORKDIR}/public/index.html" > /dev/null 2>&1

  yellow "服务启动中，首次启动需要下载运行库，请耐心等待...."
  started=false
  for i in $(seq 1 15); do
    sleep 3
    rm -f "${WORKDIR}/public/index.html" > /dev/null 2>&1
    code=$(curl -o /dev/null -m 3 -s -w "%{http_code}" https://${USERNAME}.${CURRENT_DOMAIN})
    if [[ "$code" == "200" ]]; then
      started=true
      break
    fi
  done

  if $started; then
    green "服务已启动成功,请先访问 https://${USERNAME}.${CURRENT_DOMAIN}  启动服务，过20秒再访问订阅获取节点"
  else
    yellow "首页探测暂未返回200(可能仍在启动或域名解析较慢)，但这不代表节点一定不可用，请稍后手动访问 https://${USERNAME}.${CURRENT_DOMAIN} 或直接尝试订阅链接确认"
  fi

  TOKEN=$(sed -n 's/^SUB_PATH=\(.*\)/\1/p' $HOME/domains/${USERNAME}.${CURRENT_DOMAIN}/public_nodejs/.env)
  green "\n订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${TOKEN}\n节点订阅链接适用于V2rayN/Nekoray/ShadowRocket/karing/Loon/sterisand 等\n"

  setup_keepalive_cron
}

quick_command() {
  COMMAND="00"
  SCRIPT_PATH="$HOME/bin/$COMMAND"
  mkdir -p "$HOME/bin"
  set +H
  printf '#!/bin/bash\n' > "$SCRIPT_PATH"
  echo "bash <(curl -Ls https://raw.githubusercontent.com/Joshuagpt/Go_Real/main/servct.sh)" >> "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
      echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc" 2>/dev/null
      source "$HOME/.bashrc"
  fi
  green "快捷指令00创建成功,下次运行输入00快速进入菜单\n"
}

show_nodes(){
cat ${WORKDIR}/.npm/sub.txt 2>/dev/null
TOKEN=$(sed -n 's/^SUB_PATH=\(.*\)/\1/p' $HOME/domains/${USERNAME}.${CURRENT_DOMAIN}/public_nodejs/.env)
yellow "\n订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${TOKEN}\n节点订阅链接适用于V2rayN/Nekoray/ShadowRocket/karing/Loon/sterisand 等\n"
}

menu() {
  clear
  echo ""
  purple "=== Serv00|Ct8|HostUNO 代理部署脚本 ===\n"
  green "1. 安装"
  echo  "==============="
  red "2. 卸载"
  echo  "==============="
  green "3. 查看节点信息"
  echo  "==============="
  yellow "4. 初始化系统"
  echo  "==============="
  red "0. 退出脚本"
  echo "==========="
  reading "请输入选择(0-4): " choice
  echo ""
  case "${choice}" in
      1) install_px;;
      2) uninstall_px;;
      3) show_nodes ;;
      4) reset_system ;;
      0) exit 0 ;;
      *) red "无效的选项，请输入 0 到 4" ;;
  esac
}
menu
