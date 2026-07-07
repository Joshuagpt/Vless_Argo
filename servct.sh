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

# VLESS-WS-Argo 只需要一个本地 TCP 端口给 Argo 隧道用，不需要额外的 UDP 端口
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
purple "vless-ws-argo使用的tcp端口为: $tcp_port"
export ARGO_PORT=$tcp_port
}

install_vless() {
bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
echo -e "${yellow}本脚本仅安装单协议${purple}vless-ws-tls(argo)${re}"
reading "\n确定继续安装吗？(直接回车即确认安装)【y/n】: " choice
  case "${choice:-y}" in
    [Yy]|"")
    	clear
        check_port
        argo_configure
        install_service
      ;;
    [Nn]) exit 0 ;;
    *) red "无效的选择，请输入y或n" && menu ;;
  esac
}

uninstall_vless() {
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

argo_configure() {
  reading "是否需要使用固定argo隧道？(直接回车将使用临时隧道)【y/n】: " argo_choice
  [[ -z $argo_choice ]] && return
  [[ "$argo_choice" != "y" && "$argo_choice" != "Y" && "$argo_choice" != "n" && "$argo_choice" != "N" ]] && { red "无效的选择, 请输入y或n"; return; }
  if [[ "$argo_choice" == "y" || "$argo_choice" == "Y" ]]; then
      reading "请输入argo固定隧道域名: " ARGO_DOMAIN
      green "你的argo固定隧道域名为: $ARGO_DOMAIN"
      reading "请输入argo固定隧道密钥（Json或Token）: " ARGO_AUTH
      green "你的argo固定隧道密钥为: $ARGO_AUTH"
  else
      green "ARGO隧道变量未设置，将使用临时隧道"
      return
  fi

  if [[ $ARGO_AUTH =~ TunnelSecret ]]; then
    echo $ARGO_AUTH > tunnel.json
    cat > tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$ARGO_AUTH")
credentials-file: tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$ARGO_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    yellow "\n当前使用的是token,请在cloudflare里设置隧道端口为${purple}${ARGO_PORT}${re}"
  fi
}

setup_keepalive_cron() {
  local cron_tag="# vless_argo_keepalive"
  local cron_line="*/10 * * * * curl -s -o /dev/null -m 10 https://${USERNAME}.${CURRENT_DOMAIN} >/dev/null 2>&1 ${cron_tag}"
  (crontab -l 2>/dev/null | grep -vF "${cron_tag}"; echo "${cron_line}") | crontab -
  green "已添加保活定时任务(每10分钟访问一次自身域名)"
}

remove_keepalive_cron() {
  local cron_tag="# vless_argo_keepalive"
  crontab -l 2>/dev/null | grep -vF "${cron_tag}" | crontab -
}

write_app_js() {
  cat > "$1" <<'JSEOF'
#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const crypto = require('crypto');
const axios = require('axios');
const koffi = require('koffi');
const { execSync } = require('child_process');

try { require('dotenv').config(); } catch { /* ignore if dotenv unavailable */ }

// ======================== 环境变量定义 ========================
const FILE_PATH      = process.env.FILE_PATH      || '.npm';     // sub.txt订阅文件路径
const SUB_PATH       = process.env.SUB_PATH       || 'sub';      // 订阅sub路径，默认为sub
const UUID           = process.env.UUID           || '68aa231f-703e-4547-967e-12ed0b36420f'; // UUID
const ARGO_DOMAIN    = process.env.ARGO_DOMAIN    || '';         // argo固定隧道域名,留空即使用临时隧道
const ARGO_AUTH      = process.env.ARGO_AUTH      || '';         // argo固定隧道token或json,留空即使用临时隧道
const ARGO_PORT      = Number(process.env.ARGO_PORT) || 8001;    // argo固定隧道端口(本地vless-ws监听端口)
const CFIP           = process.env.CFIP           || 'saas.sin.fan'; // 优选域名或优选IP
const CFPORT         = Number(process.env.CFPORT) || 443;        // 优选域名或优选IP对应端口
const PORT           = Number(process.env.PORT)   || 3000;       // http订阅端口
const NAME           = process.env.NAME           || '';         // 节点名称
const DISABLE_ARGO   = process.env.DISABLE_ARGO   || false;      // 设置为true时禁用argo
// ==============================================================

const ROOT = process.cwd();
const runtimeFilePath = path.resolve(ROOT, FILE_PATH);
const libraryDir = runtimeFilePath;
const singBoxConfigPath = path.resolve(runtimeFilePath, 'config.json');
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

const pathsToDelete = ['boot.log', 'list.txt', 'config.json', 'tunnel.json', 'tunnel.yml'];
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
  const keepFiles = new Set();
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

// ======================== Argo 隧道配置 ========================

function argoType() {
  if (DISABLE_ARGO === 'true' || DISABLE_ARGO === true) {
    console.log("DISABLE_ARGO is set to true, disable argo tunnel");
    return;
  }
  if (!ARGO_AUTH || !ARGO_DOMAIN) {
    console.log("ARGO_DOMAIN or ARGO_AUTH variable is empty, use quick tunnel");
    return;
  }
  if (ARGO_AUTH.includes('TunnelSecret')) {
    fs.writeFileSync(path.join(FILE_PATH, 'tunnel.json'), ARGO_AUTH);
    const tunnelYaml = `
  tunnel: ${ARGO_AUTH.split('"')[11]}
  credentials-file: ${path.join(FILE_PATH, 'tunnel.json')}
  protocol: http2
  
  ingress:
    - hostname: ${ARGO_DOMAIN}
      service: http://localhost:${ARGO_PORT}
      originRequest:
        noTLSVerify: true
    - service: http_status:404
  `;
    fs.writeFileSync(path.join(FILE_PATH, 'tunnel.yml'), tunnelYaml);
  } else {
    console.log(`Using token connect to tunnel, please set ${ARGO_PORT} in cloudflare`);
  }
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
    console.log(`Using cached native library: ${target}`);
    return target;
  }
  await fs.promises.mkdir(libraryDir, { recursive: true });
  const tmp = path.resolve(libraryDir, `${fileName}.download`);
  const writer = fs.createWriteStream(tmp);
  console.log(`Downloading ${url} -> ${target}`);
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

// ======================== Koffi 服务管理 ========================

function createService(name, libraryPath, startSymbol, stopSymbol, payload) {
  const lib = koffi.load(libraryPath);
  const startFn = lib.func(`int ${startSymbol}(str)`);
  const stopFn = lib.func(`int ${stopSymbol}()`);
  return {
    name,
    start: () => {
      startFn.async(payload || '', (err, code) => {
        if (err) {
          console.error(`${name} native service failed: ${err.message}`);
        } else if (code !== 0) {
          console.warn(`${name} native service exited with code ${code}`);
        }
      });
    },
    stop: () => new Promise((resolve, reject) => {
      try {
        stopFn.async((err, code) => {
          if (err) return reject(err);
          resolve(code);
        });
      } catch (error) {
        resolve(-1);
      }
    })
  };
}

// ======================== sing-box 配置生成 ========================

function generateSingBoxConfig() {
  const inbounds = [];

  // VLESS+WS inbound (for argo reverse proxy)
  inbounds.push({
    type: 'vless',
    tag: 'vless-ws-in',
    listen: '::',
    listen_port: ARGO_PORT,
    users: [{ uuid: UUID }],
    transport: {
      type: 'ws',
      path: '/vless-argo',
      early_data_header_name: 'Sec-WebSocket-Protocol'
    }
  });

  const outbounds = [{ type: 'direct', tag: 'direct' }];

  const route = {
    default_http_client: 'http-client-direct',
    final: 'direct'
  };

  return {
    log: { disabled: true, level: 'error', timestamp: true },
    http_clients: [{ tag: 'http-client-direct' }],
    inbounds,
    outbounds,
    route
  };
}

// ======================== Cloudflared Payload ========================

function cloudflaredPayload() {
  if (DISABLE_ARGO === 'true' || DISABLE_ARGO === true) return null;
  if (ARGO_AUTH && ARGO_DOMAIN) {
    if (ARGO_AUTH.match(/^[A-Z0-9a-z=]{120,250}$/)) {
      return JSON.stringify({
        args: ['tunnel', '--edge-ip-version', 'auto', '--no-autoupdate', '--protocol', 'http2', 'run', '--token', ARGO_AUTH]
      });
    } else if (ARGO_AUTH.match(/TunnelSecret/)) {
      return JSON.stringify({
        args: ['tunnel', '--edge-ip-version', 'auto', '--config', path.join(FILE_PATH, 'tunnel.yml'), 'run']
      });
    }
  }
  // Quick tunnel
  return JSON.stringify({
    args: [
      'tunnel', '--edge-ip-version', 'auto', '--no-autoupdate',
      '--protocol', 'http2', '--logfile', bootLogPath,
      '--loglevel', 'info', '--url', `http://localhost:${ARGO_PORT}`
    ]
  });
}

function singBoxPayload() {
  return JSON.stringify({ config: singBoxConfigPath, workingDir: '.', disableColor: true });
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
    } catch (e) { /* file may not exist yet */ }
    const remaining = deadline - Date.now();
    if (remaining <= 0) break;
    const sleepMs = Math.min(1000, remaining);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, sleepMs);
  }
  return null;
}

async function extractDomain() {
  if (DISABLE_ARGO === 'true' || DISABLE_ARGO === true) return null;
  if (ARGO_AUTH && ARGO_DOMAIN) {
    console.log('ARGO_DOMAIN:', ARGO_DOMAIN + '\n');
    return ARGO_DOMAIN;
  }
  // Quick tunnel
  console.log('Waiting for quick tunnel domain in log...');
  let domain = waitForQuickTunnelDomain(bootLogPath, 30000);
  if (!domain) {
    console.log('Quick tunnel domain not found, retrying...');
    try { fs.unlinkSync(bootLogPath); } catch (e) { }
    await new Promise(r => setTimeout(r, 5000));
    domain = waitForQuickTunnelDomain(bootLogPath, 30000);
  }
  if (domain) {
    console.log('ArgoDomain:', domain + '\n');
  } else {
    console.log('ArgoDomain not found');
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
    } catch (error) { /* backup also failed */ }
  }
  return 'Unknown';
}

// ======================== 节点链接生成 ========================

async function generateLinks(argoDomain) {
  const ISP = await getMetaInfo();
  const nodeName = NAME ? `${NAME}-${ISP}` : ISP;

  await new Promise(r => setTimeout(r, 2000));

  let subTxt = '';

  // VLESS+WS (argo)
  if ((DISABLE_ARGO !== 'true' && DISABLE_ARGO !== true) && argoDomain) {
    const vlessPath = encodeURIComponent('/vless-argo?ed=2560');
    subTxt = `vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argoDomain}&fp=chrome&type=ws&host=${argoDomain}&path=${vlessPath}#${encodeURIComponent(nodeName)}`;
  }

  // 打印绿色 base64 编码
  console.log('\x1b[32m' + Buffer.from(subTxt).toString('base64') + '\x1b[0m');
  console.log('\n\x1b[35m' + 'Logs will be deleted in 45 seconds, you can copy the above nodes' + '\x1b[0m');

  const subTxtWithNewline = subTxt ? subTxt + '\n' : subTxt;
  fs.writeFileSync(subPath, Buffer.from(subTxtWithNewline).toString('base64'));
  fs.writeFileSync(listPath, subTxtWithNewline, 'utf8');
  console.log(`${FILE_PATH}/sub.txt saved successfully`);

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

  server.listen(PORT, '0.0.0.0', () => {
    console.log(`HTTP server is listening on ${PORT}`);
  });

  server.on('error', err => {
    if (err.code === 'EADDRINUSE') {
      console.error(`Port ${PORT} is already in use.`);
    } else {
      console.error('HTTP server error:', err.message);
    }
  });
}

// ======================== 主流程 ========================

async function startServer() {
  // 1. 创建运行目录 + 清理文件
  if (!fs.existsSync(FILE_PATH)) {
    fs.mkdirSync(FILE_PATH);
    console.log(`${FILE_PATH} is created`);
  }
  cleanupOldFiles();

  // 2. 生成 Argo 隧道配置
  argoType();

  // 3. 下载 .so 库文件
  const baseUrl = `https://00.ssss.nyc.mn`;
  const singBoxLib = await downloadLibrary(`${baseUrl}/freebsd-sbx.so`, 'sbx.so');
  let cloudflaredLib = null;

  if (DISABLE_ARGO !== 'true' && DISABLE_ARGO !== true) {
    cloudflaredLib = await downloadLibrary(`${baseUrl}/freebsd-bot.so`, 'bot.so');
  }

  // 4. 生成 sing-box config.json
  const sbxConfig = generateSingBoxConfig();
  fs.writeFileSync(singBoxConfigPath, JSON.stringify(sbxConfig, null, 2));

  // 5. 启动服务
  const services = [];

  // sing-box
  const singBoxService = createService('sing-box', singBoxLib, 'StartSingBox', 'StopSingBox', singBoxPayload());
  services.push(singBoxService);

  // cloudflared
  let cloudflaredService = null;
  if (cloudflaredLib) {
    const cfPayload = cloudflaredPayload();
    if (cfPayload) {
      cloudflaredService = createService('cloudflared', cloudflaredLib, 'StartCloudflared', 'StopCloudflared', cfPayload);
      services.push(cloudflaredService);
    }
  }

  // 信号监听
  async function stopAll() {
    for (let i = services.length - 1; i >= 0; i--) {
      try { await services[i].stop(); } catch (e) { }
    }
    process.exit(0);
  }
  process.on('SIGINT', stopAll);
  process.on('SIGTERM', stopAll);

  services.forEach(service => service.start());
  await new Promise(r => setTimeout(r, 1000));
  console.log('web is running');
  if (cloudflaredService) console.log('bot is running');

  // 6. 等待并检测隧道域名
  await new Promise(r => setTimeout(r, 5000));
  const argoDomain = await extractDomain();

  // 7. 生成节点链接
  const subTxt = await generateLinks(argoDomain);

  // 8. 启动 HTTP 服务器
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
    # devil 在 add 时会自动在 public/ 下放一个默认占位 index.html；
    # Passenger 对该目录下的静态文件优先级高于应用本身，不清掉的话根路径请求
    # 永远会被这个占位页拦截，走不到 Node app.js
    rm -f "${WORKDIR}/public/index.html" > /dev/null 2>&1
    write_app_js "${WORKDIR}/app.js"
    cat > "${WORKDIR}/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Willowmere Bird Conservancy</title>
<style>
  :root {
    --ink: #2f3226;
    --paper: #f6f4ee;
    --line: #d8d3c4;
    --moss: #4c5c3f;
    --rust: #8a5a3b;
    --muted: #6b6558;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--paper);
    color: var(--ink);
    font-family: Georgia, 'Times New Roman', serif;
    font-size: 16px;
    line-height: 1.65;
  }
  a { color: var(--moss); }
  a:hover { color: var(--rust); }
  .topbar {
    background: var(--ink);
    color: var(--paper);
    font-family: Arial, Helvetica, sans-serif;
    font-size: 0.8rem;
    padding: 0.4rem 1rem;
    text-align: center;
    letter-spacing: 0.02em;
  }
  header.masthead {
    border-bottom: 3px double var(--ink);
    padding: 2rem 1rem 1.4rem;
    text-align: center;
  }
  header.masthead h1 {
    margin: 0;
    font-size: 2.1rem;
    font-weight: normal;
    letter-spacing: 0.03em;
  }
  header.masthead p.tagline {
    margin: 0.4rem 0 0;
    color: var(--muted);
    font-style: italic;
    font-size: 0.95rem;
  }
  nav.main {
    background: #ece8dc;
    border-bottom: 1px solid var(--line);
    font-family: Arial, Helvetica, sans-serif;
    font-size: 0.85rem;
  }
  nav.main ul {
    list-style: none;
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 1.6rem;
    margin: 0;
    padding: 0.7rem 1rem;
  }
  nav.main a {
    text-decoration: none;
    color: var(--ink);
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }
  main {
    max-width: 760px;
    margin: 0 auto;
    padding: 2.2rem 1.4rem 3rem;
  }
  section { margin-bottom: 2.6rem; }
  h2 {
    font-size: 1.35rem;
    font-weight: normal;
    border-bottom: 1px solid var(--line);
    padding-bottom: 0.35rem;
    margin: 0 0 1rem;
  }
  h3 {
    font-size: 1.05rem;
    font-weight: bold;
    margin: 1.2rem 0 0.3rem;
    color: var(--rust);
  }
  p { margin: 0 0 0.9rem; }
  .lede {
    font-size: 1.05rem;
    color: var(--ink);
  }
  .callout {
    background: #ece8dc;
    border-left: 3px solid var(--moss);
    padding: 0.8rem 1rem;
    font-size: 0.92rem;
    color: var(--muted);
  }
  ul.plain, ol.plain {
    padding-left: 1.3rem;
    margin: 0 0 1rem;
  }
  ul.plain li, ol.plain li {
    margin-bottom: 0.4rem;
  }
  table.species {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.9rem;
    margin: 0.6rem 0 1rem;
  }
  table.species th, table.species td {
    border: 1px solid var(--line);
    padding: 0.45rem 0.6rem;
    text-align: left;
    vertical-align: top;
  }
  table.species th {
    background: #ece8dc;
    font-weight: normal;
    font-family: Arial, Helvetica, sans-serif;
    font-size: 0.78rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .notes-entry {
    border-top: 1px solid var(--line);
    padding-top: 1rem;
    margin-top: 1rem;
  }
  .notes-entry:first-child { border-top: none; padding-top: 0; margin-top: 0; }
  .notes-entry .date {
    font-family: Arial, Helvetica, sans-serif;
    font-size: 0.75rem;
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin-bottom: 0.25rem;
  }
  footer {
    border-top: 3px double var(--ink);
    padding: 1.6rem 1.4rem;
    font-family: Arial, Helvetica, sans-serif;
    font-size: 0.78rem;
    color: var(--muted);
    text-align: center;
  }
  footer p { margin: 0.2rem 0; }
</style>
</head>
<body>

<div class="topbar">Volunteer-run &middot; field notes updated irregularly &middot; no tracking, no ads</div>

<header class="masthead">
  <h1>Willowmere Bird Conservancy</h1>
  <p class="tagline">Notes on habitat, migration, and the birds that pass through the valley</p>
</header>

<nav class="main">
  <ul>
    <li><a href="#about">About</a></li>
    <li><a href="#threats">Threats</a></li>
    <li><a href="#species">Species Notes</a></li>
    <li><a href="#help">Get Involved</a></li>
    <li><a href="#notes">Field Notes</a></li>
  </ul>
</nav>

<main>

  <section id="about">
    <p class="lede">Willowmere is a small, volunteer-run effort to document and protect the birds that breed, winter,
    or pass through the Willowmere valley and the wetlands along its lower reach. We keep counts, restore small
    patches of habitat, and write up what we see so that the record outlasts any one of us.</p>
    <p>We are not a large organisation and we do not claim to be. Most of what appears on this page comes from
    volunteers walking the same transects year after year, comparing notes, and slowly building a picture of how
    the valley's bird life is changing. If you are looking for a national body with paid staff and a press office,
    this is not that. If you are looking for a place to read plain notes about birds and the pressures on them,
    you are in the right place.</p>
  </section>

  <section id="threats">
    <h2>Why bird populations are declining</h2>
    <p>Across most of the temperate world, long-term counts point the same direction: fewer birds, in fewer places,
    than a few decades ago. The causes are rarely a single event. More often it is a slow accumulation of smaller
    pressures, each survivable on its own, that together tip a population from stable to declining.</p>

    <h3>Habitat loss and fragmentation</h3>
    <p>Wetland drainage, hedgerow removal, and the conversion of mixed farmland into single-crop fields all reduce
    the number of places a bird can nest, feed, or shelter from weather. Fragmentation matters as much as outright
    loss: a woodland cut into small isolated blocks can support far fewer breeding pairs than the same area left
    whole, because edge habitat exposes nests to more predators and because birds that need interior forest
    conditions simply have nowhere left to go.</p>

    <h3>Collisions and everyday hazards</h3>
    <p>Windows are a significant and mostly invisible cause of death for birds moving through towns and cities,
    especially during migration when tired birds travel at night and are drawn off course by artificial light.
    Roads, powerlines, and outdoor domestic cats each add to the toll in ways that rarely make the news but add up
    over a breeding season.</p>

    <h3>Pesticides and food supply</h3>
    <p>Many farmland and garden birds feed insects to their chicks even if the adults eat seed the rest of the
    year. Where insect abundance falls, sharply, nesting success falls with it, even in habitat that otherwise
    looks intact. This is one reason a hedgerow full of green leaves can still be a poor place to raise a brood.</p>

    <h3>A shifting climate</h3>
    <p>Migratory birds time their journeys to arrive when food is at its peak. As spring arrives earlier in many
    regions, the timing between migration, breeding, and the seasonal insect flush has in some cases pulled apart,
    so that chicks hatch after the best feeding window has already passed. Range shifts are also underway, with
    some species moving north or upslope as conditions change, which can put them into competition with birds
    already living there.</p>

    <div class="callout">None of this is offered as a reason for despair. Populations that are given room, time,
    and a reduction in the sharpest pressures do recover, sometimes faster than expected. The purpose of a record
    like this one is to notice the change early enough that something can still be done about it locally.</div>
  </section>

  <section id="species">
    <h2>Species we watch closely</h2>
    <p>The valley sees well over a hundred species across the year. The table below is not exhaustive; it lists
    a handful that volunteers pay particular attention to, either because the valley holds a meaningful share of
    a declining population, or because the species is a useful early indicator of habitat condition.</p>
    <table class="species">
      <tr><th>Species</th><th>Status locally</th><th>Why we watch it</th></tr>
      <tr><td>Common Cuckoo</td><td>Declining</td><td>Depends on host nests and caterpillar abundance; an early
      warning for insect decline.</td></tr>
      <tr><td>Eurasian Curlew</td><td>Declining</td><td>Ground-nesting wader, highly sensitive to disturbance and
      wet-meadow drainage.</td></tr>
      <tr><td>Spotted Flycatcher</td><td>Sharp decline</td><td>Late migrant, aerial insectivore; sensitive to both
      breeding and wintering habitat.</td></tr>
      <tr><td>Willow Tit</td><td>Local decline</td><td>Needs standing dead wood for nest excavation; a marker of
      unmanaged, structurally messy woodland.</td></tr>
      <tr><td>Sand Martin</td><td>Variable</td><td>Colonial nester in river banks; numbers swing with bank erosion
      and winter conditions in the Sahel.</td></tr>
      <tr><td>Grey Wagtail</td><td>Stable</td><td>Good indicator of clean, fast-flowing water and healthy stream
      invertebrate life.</td></tr>
    </table>
    <p>Counts for each of these are logged on standard transect walks, usually early morning, at roughly the same
    dates each year so that the numbers can be compared honestly across seasons.</p>
  </section>

  <section id="help">
    <h2>How to help, wherever you are</h2>
    <p>Most of what keeps a bird population healthy has very little to do with money and a great deal to do with
    ordinary decisions made by ordinary people living near where the birds live.</p>
    <ul class="plain">
      <li><strong>Keep some mess.</strong> A corner of long grass, a pile of brush, a dead branch left standing –
      these untidy features are often more valuable to birds than a manicured equivalent.</li>
      <li><strong>Reduce window strikes.</strong> Breaking up reflections with film, decals, or external screens
      on the worst-offending panes prevents a surprising share of collision deaths, particularly during migration.</li>
      <li><strong>Keep cats indoors, or supervised, during the breeding season.</strong> Even well-fed cats hunt,
      and fledglings on the ground are especially vulnerable in the weeks after leaving the nest.</li>
      <li><strong>Plant for insects, not just for flowers.</strong> Native plant species support far more of the
      insect life that nestlings actually need than ornamental exotics do.</li>
      <li><strong>Take part in a count.</strong> Long-running citizen science projects rely entirely on volunteers
      walking the same route year after year. A single observer with a notebook, repeated reliably, is worth more
      than a single expert visit.</li>
      <li><strong>Report what you see, accurately.</strong> Under-recording common species is as damaging to the
      long-term picture as missing a rarity; consistent records of ordinary birds are what make trends visible.</li>
    </ul>
  </section>

  <section id="notes">
    <h2>Field notes</h2>

    <div class="notes-entry">
      <div class="date">Late spring</div>
      <p>Curlew back on the lower meadow for a fourth consecutive year, though the pair seems to be nesting later
      than the early records suggest was once typical. Water levels held up better than last year, which may be
      the difference.</p>
    </div>

    <div class="notes-entry">
      <div class="date">Mid spring</div>
      <p>First Spotted Flycatcher of the year, later than the ten-year average by almost a week. Whether that
      reflects conditions on the wintering grounds or simply a slow spring further south is not something a single
      sighting can answer, but it is worth noting all the same.</p>
    </div>

    <div class="notes-entry">
      <div class="date">Early spring</div>
      <p>Sand Martins prospecting the eroded bank near the old mill again. Numbers down on the peak years but
      steady compared with last season. Left the bank undisturbed rather than clearing the fallen willow in
      front of it, on the theory that a little cover does the colony no harm.</p>
    </div>

    <div class="notes-entry">
      <div class="date">Winter</div>
      <p>Quiet count this month, mostly resident finches and a small mixed flock working the alders along the
      stream. Nothing unusual, which in a record like this is itself a small kind of good news.</p>
    </div>
  </section>

</main>

<footer>
  <p>Willowmere Bird Conservancy &middot; an informal, volunteer-maintained record</p>
  <p>Counts and notes are kept for their own sake and shared here in case they are useful to someone else.</p>
</footer>

</body>
</html>
HTMLEOF
    cat > ${WORKDIR}/.env <<EOF
UUID=${UUID}
SUB_PATH=${SUB_PATH}
ARGO_PORT=${ARGO_PORT}
${ARGO_DOMAIN:+ARGO_DOMAIN=$ARGO_DOMAIN}
${ARGO_AUTH:+ARGO_AUTH=$([[ -z "$ARGO_AUTH" ]] && echo "" || ([[ "$ARGO_AUTH" =~ ^\{.* ]] && echo "'$ARGO_AUTH'" || echo "$ARGO_AUTH"))}
EOF

  ln -fs /usr/local/bin/node24 ~/bin/node > /dev/null 2>&1
  ln -fs /usr/local/bin/npm24 ~/bin/npm > /dev/null 2>&1
  mkdir -p ~/.npm-global
  npm config set prefix '~/.npm-global'
  echo 'export PATH=~/.npm-global/bin:~/bin:$PATH' >> $HOME/.bash_profile && source $HOME/.bash_profile
  rm -rf $HOME/.npmrc > /dev/null 2>&1
  cd ${WORKDIR} && npm install dotenv axios koffi --silent > /dev/null 2>&1
  devil www restart ${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
  # devil www restart 会重新生成 public/ 下的默认占位 index.html，覆盖掉我们之前删的那次；
  # 这里再清一次，确保根路径请求最终落到 app.js 而不是被这个占位页拦截
  rm -f "${WORKDIR}/public/index.html" > /dev/null 2>&1

  yellow "服务启动中，首次启动需要下载运行库，请耐心等待...."
  started=false
  for i in $(seq 1 15); do
    sleep 3
    # devil 每次 restart 都可能重新放回占位页，起服务的这段时间里持续清理，
    # 避免探测阶段命中占位页而不是真实的 app.js 响应
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
  echo "bash <(curl -Ls https://raw.githubusercontent.com/Joshuagpt/Vless_Argo_Reality/main/servct.sh)" >> "$SCRIPT_PATH"
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
  purple "=== Serv00|Ct8|HostUNO VLESS+Argo 安装脚本 ===\n"
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
      1) install_vless;;
      2) uninstall_vless;;
      3) show_nodes ;;
      4) reset_system ;;
      0) exit 0 ;;
      *) red "无效的选项，请输入 0 到 4" ;;
  esac
}
menu
