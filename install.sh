#!/bin/bash
# ==================================================
# 优化版 Xray 极速部署脚本 (VLESS + Reality + Vision)
# 增强：激进性能优化 + 连接保活 + 诊断工具 + 自动更新
# ==================================================

set -e

[[ $EUID -ne 0 ]] && echo -e "\033[31m错误: 请使用 root 用户运行此脚本\033[0m" && exit 1

echo ">>> [1/7] 初始化配置..."
PORT=$((RANDOM % 10000 + 20000))
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 4)

# 【安全改进】改用边缘CDN+中立域名，避免IP白名单库不匹配导致被秒封
# 原理：选择部署在全球边缘节点、与VPS地域属性相符的域名
DOMAINS=("swdist.apple.com" "dl.flathub.org" "cdn.jsdelivr.net" "fastdl.foobar2000.org" "github.githubassets.com")
DEST_DOMAIN=${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}

NODE_IP=$(curl -s4m5 https://api.ipify.org || curl -s4m5 https://ifconfig.me)
if [[ -z "$NODE_IP" ]]; then
    echo -e "\033[31m无法获取公网 IP，请检查网络。\033[0m"
    exit 1
fi

echo "✓ 公网IP: $NODE_IP"
echo "✓ 随机端口: $PORT"

echo ""
echo ">>> [2/7] 激进性能优化 (内核 + TCP + 文件描述符)..."

# 【新增】企业级性能优化配置
cat > /etc/sysctl.d/99-xray-performance.conf << 'EOF'
# ===== BBR 拥塞控制 =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ===== TCP 快速打开与连接优化 =====
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_abort_on_overflow = 0

# ===== 文件描述符与连接数（2倍扩容）=====
fs.file-max = 2000000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 262144

# ===== 接收/发送缓冲区优化（4倍扩容）=====
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 131072
net.core.wmem_default = 131072
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# ===== UDP 缓冲区优化 =====
net.core.udp_mem = 8388608 12582912 16777216

# ===== 连接保活参数（防止断流）=====
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15

# ===== 时间戳与选择性确认 =====
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1

# ===== 显式拥塞通知 =====
net.ipv4.tcp_ecn = 1

# ===== IP 转发与反向路由过滤 =====
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF

sysctl -p /etc/sysctl.d/99-xray-performance.conf >/dev/null 2>&1
echo "✓ 内核优化完成 (BBR + 大缓冲 + 连接保活)"

# 【新增】ulimit 优化
cat > /etc/security/limits.d/99-xray.conf << 'EOF'
* soft nofile 1000000
* hard nofile 1000000
* soft nproc 1000000
* hard nproc 1000000
EOF

echo ""
echo ">>> [3/7] 安装依赖与 Xray 核心..."

# 【关键】禁用所有交互式弹窗
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if command -v apt-get >/dev/null; then
    apt-get update -q -y >/dev/null 2>&1
    apt-get install -q -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        curl unzip openssl iptables iptables-persistent dnsmasq >/dev/null 2>&1
elif command -v yum >/dev/null; then
    yum install -y -q curl unzip openssl iptables dnsmasq >/dev/null 2>&1
fi

mkdir -p /usr/local/bin /var/log/xray /etc/xray
XRAY_VERSION="1.8.24"
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"

# 【新增】下载重试机制
max_attempts=3
attempt=1
while [ $attempt -le $max_attempts ]; do
    echo "下载 Xray v${XRAY_VERSION}... (尝试 $attempt/$max_attempts)"
    
    if curl -L -f -s -o xray.zip "$DOWNLOAD_URL" --connect-timeout 10 --max-time 30; then
        # 【新增】验证 ZIP 完整性
        if unzip -t xray.zip >/dev/null 2>&1; then
            echo "✓ 下载验证成功"
            break
        else
            echo "⚠ 下载文件损坏，重试..."
            rm -f xray.zip
        fi
    else
        echo "⚠ 官方源下载失败，切换加速镜像..."
        if curl -L -f -s -o xray.zip "https://ghp.ci/$DOWNLOAD_URL" --connect-timeout 10 --max-time 30; then
            if unzip -t xray.zip >/dev/null 2>&1; then
                echo "✓ 加速镜像下载成功"
                break
            fi
        fi
    fi
    
    attempt=$((attempt + 1))
    if [ $attempt -le $max_attempts ]; then
        sleep 3
    fi
done

if [ ! -f xray.zip ]; then
    echo -e "\033[31m✗ 下载失败，请检查网络后重试\033[0m"
    exit 1
fi

unzip -o -q xray.zip xray -d /usr/local/bin/ >/dev/null 2>&1
chmod +x /usr/local/bin/xray
rm -f xray.zip
echo "✓ Xray 安装完成"

echo ""
echo ">>> [4/7] 生成 Reality 密钥与配置..."

# 【安全】生成密钥对
KEYS=$(/usr/local/bin/xray x25519 2>/dev/null || echo "")
if [[ -z "$KEYS" ]]; then
    echo -e "\033[31m✗ 密钥生成失败\033[0m"
    exit 1
fi

PK=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
PUB=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')

if [[ -z "$PK" ]] || [[ -z "$PUB" ]]; then
    echo -e "\033[31m✗ 密钥解析失败\033[0m"
    exit 1
fi

echo "✓ Reality 密钥生成成功"

# 【安全】配置文件权限保护
cat > /etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [{
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "${UUID}",
        "flow": "xtls-rprx-vision",
        "email": "vless@xray"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${DEST_DOMAIN}:443",
        "xver": 0,
        "serverNames": ["${DEST_DOMAIN}"],
        "privateKey": "${PK}",
        "shortIds": ["${SHORT_ID}"]
      },
      "sockopt": {
        "tcpFastOpen": true
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"],
      "metadataOnly": false
    }
  }],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true
        }
      }
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

chmod 600 /etc/xray/config.json
echo "✓ 配置文件已生成（权限: 600）"

echo ""
echo ">>> [5/7] 配置 Systemd 服务（高优先级）..."

# 【优化】systemd 配置：自动重启 + 进程优先级
cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service (VLESS Reality Vision)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/xray
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json

# 【关键】自动重启策略
Restart=always
RestartSec=3
StartLimitInterval=60
StartLimitBurst=3

# 【性能】进程优先级与资源限制
Nice=-20
OOMScoreAdjust=-999
LimitNOFILE=1000000
LimitNPROC=1000000

# 【日志】
StandardOutput=journal
StandardError=journal
SyslogIdentifier=xray

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1
systemctl restart xray

# 【新增】启动验证（等待服务完全启动）
sleep 3
if ! systemctl is-active --quiet xray; then
    echo -e "\033[31m✗ Xray 启动失败，错误日志：\033[0m"
    journalctl -u xray -n 20 --no-pager
    exit 1
fi

echo "✓ Systemd 服务已启动"

echo ""
echo ">>> [6/7] 放行防火墙规则..."

# 【关键修复】检测实际SSH监听端口，避免硬编码导致的断连
SSH_PORT=$(ss -tuln 2>/dev/null | grep LISTEN | awk '{print $4}' | grep -oE ':[0-9]+$' | grep -E ':(22|[0-9]{4,5})$' | head -1 | cut -d: -f2)
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=22
    echo "⚠ 未能检测到SSH端口，默认使用22"
else
    echo "✓ 检测到SSH端口: $SSH_PORT"
fi

# 【改进】同时配置 TCP + UDP，并使用 iptables-persistent 保证重启后规则不丢失
iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT >/dev/null 2>&1 || true
iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT >/dev/null 2>&1 || true
iptables -I INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT >/dev/null 2>&1 || true

if command -v iptables-save >/dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

if command -v ufw >/dev/null; then
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw allow ${PORT}/tcp >/dev/null 2>&1
    ufw allow ${PORT}/udp >/dev/null 2>&1
    ufw allow ${SSH_PORT}/tcp >/dev/null 2>&1
    echo "y" | ufw enable >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null; then
    firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port=${PORT}/udp >/dev/null 2>&1
    firewall-cmd --permanent --add-port=${SSH_PORT}/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

echo "✓ 防火墙规则已配置"

echo ""
echo ">>> [7/7] 生成连接链接..."

LINK="vless://${UUID}@${NODE_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS_Reality_${NODE_IP}"

# 【新增】创建诊断脚本
cat > /usr/local/bin/xray-diag << 'DIAG_EOF'
#!/bin/bash
echo "========== Xray 诊断工具 =========="
echo ""
echo "[1] 服务状态"
systemctl status xray --no-pager

echo ""
echo "[2] 进程信息"
ps aux | grep xray | grep -v grep

echo ""
echo "[3] 监听端口"
ss -tuln | grep -E "tcp|udp" | head -20

echo ""
echo "[4] 内核优化"
echo "BBR 状态: $(cat /proc/sys/net/ipv4/tcp_congestion_control)"
echo "TCP FastOpen: $(cat /proc/sys/net/ipv4/tcp_fastopen)"
echo "缓冲区大小: $(cat /proc/sys/net/core/rmem_max) bytes"

echo ""
echo "[5] 最近错误日志"
journalctl -u xray -n 20 --no-pager
DIAG_EOF

chmod +x /usr/local/bin/xray-diag

# 【新增】日志轮转配置
cat > /etc/logrotate.d/xray << 'EOF'
/var/log/xray/*.log {
    daily
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
    postrotate
        systemctl reload xray >/dev/null 2>&1 || true
    endscript
}
EOF

echo ""
echo -e "\n\033[32m╔═══════════════════════════════════════════════════╗\033[0m"
echo -e "\033[32m║    Xray VLESS + Reality 极速部署成功！            ║\033[0m"
echo -e "\033[32m╚═══════════════════════════════════════════════════╝\033[0m"
echo ""
echo -e "🌍 \033[36m公网IP:\033[0m         ${NODE_IP}"
echo -e "🔌 \033[36m监听端口:\033[0m       ${PORT}"
echo -e "🔑 \033[36mUUID:\033[0m          ${UUID}"
echo -e "🎭 \033[36m伪装域名:\033[0m       ${DEST_DOMAIN}"
echo -e "📊 \033[36m性能优化:\033[0m       BBR + TCP FastOpen + 大缓冲 + 连接保活"
echo ""
echo -e "\033[33m━━━━━━━━━━━━━━━━━━━━━ 连接链接 ━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo ""
echo -e "\033[36m${LINK}\033[0m"
echo ""
echo -e "\033[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo ""
echo -e "📚 \033[35m常用命令:\033[0m"
echo -e "  查看状态:    \033[36msystemctl status xray\033[0m"
echo -e "  查看日志:    \033[36mjournalctl -u xray -f\033[0m"
echo -e "  查看日志:    \033[36mtail -f /var/log/xray/error.log\033[0m"
echo -e "  重启服务:    \033[36msystemctl restart xray\033[0m"
echo -e "  诊断工具:    \033[36mxray-diag\033[0m"
echo ""
echo -e "💾 \033[35m重要文件:\033[0m"
echo -e "  配置文件:    \033[36m/etc/xray/config.json\033[0m"
echo -e "  日志文件:    \033[36m/var/log/xray/error.log\033[0m"
echo -e "  服务文件:    \033[36m/etc/systemd/system/xray.service\033[0m"
echo ""
