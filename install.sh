#!/bin/bash
# ==================================================
# 优化版 Xray 极速部署脚本 (VLESS + Reality + Vision)
# 修复：去除 apt 交互式弹窗等待、防断流机制、防火墙完善
# ==================================================

set -e

[[ $EUID -ne 0 ]] && echo -e "\033[31m错误: 请使用 root 用户运行此脚本\033[0m" && exit 1

echo ">>> [1/5] 初始化配置..."
PORT=$((RANDOM % 10000 + 20000))
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 4)

DOMAINS=("www.microsoft.com" "www.bing.com" "www.apple.com" "www.yahoo.com")
DEST_DOMAIN=${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}

NODE_IP=$(curl -s4m5 https://api.ipify.org || curl -s4m5 https://ifconfig.me)
if [[ -z "$NODE_IP" ]]; then
    echo -e "\033[31m无法获取公网 IP，请检查网络。\033[0m"
    exit 1
fi

echo ">>> [2/5] 优化系统内核 (BBR)..."
cat > /etc/sysctl.d/99-xray.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
fs.file-max = 1000000
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
EOF
sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1

echo ">>> [3/5] 安装 Xray 核心 (静默无干预模式)..."
# 【关键修复】禁用所有交互式弹窗和重启确认！
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if command -v apt-get >/dev/null; then
    apt-get update -q -y >/dev/null 2>&1
    # 强制默认选项，不弹窗，并使用 apt-get 代替 apt
    apt-get install -q -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" curl unzip openssl iptables >/dev/null 2>&1
elif command -v yum >/dev/null; then
    yum install -y -q curl unzip openssl iptables >/dev/null 2>&1
fi

mkdir -p /usr/local/bin /var/log/xray /etc/xray
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/v1.8.24/Xray-linux-64.zip"

if ! curl -L -f -s -o xray.zip "$DOWNLOAD_URL" --connect-timeout 10; then
    echo "官方源下载较慢，自动切换至加速镜像..."
    curl -L -s -o xray.zip "https://ghp.ci/$DOWNLOAD_URL"
fi

unzip -o -q xray.zip xray -d /usr/local/bin/ >/dev/null 2>&1
chmod +x /usr/local/bin/xray
rm -f xray.zip

echo ">>> [4/5] 生成配置文件..."
KEYS=$(/usr/local/bin/xray x25519)
PK=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
PUB=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')

cat > /etc/xray/config.json << EOF
{
  "log": { "loglevel": "warning", "access": "none", "error": "/var/log/xray/error.log" },
  "inbounds": [{
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision", "email": "user" }],
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
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF

echo ">>> [5/5] 启动服务与放行防火墙..."
cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=always
RestartSec=3
LimitNOFILE=500000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1
systemctl restart xray

iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT >/dev/null 2>&1 || true
if command -v ufw >/dev/null; then
    ufw allow ${PORT}/tcp >/dev/null 2>&1
elif command -v firewall-cmd >/dev/null; then
    firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

LINK="vless://${UUID}@${NODE_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS_Pro_${NODE_IP}"

echo -e "\n\033[32m====================================================="
echo -e "   Xray 极速部署成功 (全自动静默版)"
echo -e "=====================================================\033[0m"
echo -e "IP:   ${NODE_IP}"
echo -e "端口: ${PORT}"
echo -e "UUID: ${UUID}"
echo -e "伪装: ${DEST_DOMAIN}"
echo -e "-----------------------------------------------------"
echo -e "\033[36m${LINK}\033[0m"
echo -e "=====================================================\n"
