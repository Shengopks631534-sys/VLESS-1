#!/bin/bash
# ==================================================
# 纯净版 Xray 极速部署脚本 (VLESS + Reality + Vision)
# 版本: 稳定直连版 (跳过 API 查询，防止断连)
# ==================================================

# 遇到错误立即停止
set -e

# 1. 权限检查
[[ $EUID -ne 0 ]] && echo -e "\033[31m错误: 请使用 root 用户运行此脚本\033[0m" && exit 1

echo ">>> [1/5] 初始化配置..."
PORT=$((RANDOM % 10000 + 20000))
UUID=$(cat /proc/sys/kernel/random/uuid)
DEST_DOMAIN="www.microsoft.com"
SHORT_ID=$(openssl rand -hex 4)

# 获取本机公网 IP
NODE_IP=$(curl -s4m5 https://api.ipify.org || curl -s4m5 https://ifconfig.me)
if [[ -z "$NODE_IP" ]]; then
    echo "无法获取公网 IP，请检查网络连接。"
    exit 1
fi

echo ">>> [2/5] 优化系统内核..."
cat > /etc/sysctl.d/99-xray.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
fs.file-max = 1000000
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
EOF
sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1

echo ">>> [3/5] 安装 Xray 核心..."
# 安装基础工具
if command -v apt >/dev/null; then
    apt update -qq && apt install -y -qq curl unzip openssl >/dev/null
elif command -v yum >/dev/null; then
    yum install -y -q curl unzip openssl >/dev/null
fi

# 准备目录
mkdir -p /usr/local/bin /var/log/xray /etc/xray

# 【关键修改】直接使用固定版本链接，不再查询 API，解决卡顿问题
echo "正在下载 Xray 核心..."
# 这里使用的是目前的稳定版 v1.8.24
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/v1.8.24/Xray-linux-64.zip"

# 下载并解压
curl -L -o xray.zip "$DOWNLOAD_URL"
unzip -o -q xray.zip xray -d /usr/local/bin/
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

echo ">>> [5/5] 启动服务..."
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

# 开放防火墙
if command -v ufw >/dev/null; then
    ufw allow ${PORT}/tcp >/dev/null 2>&1
elif command -v firewall-cmd >/dev/null; then
    firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

LINK="vless://${UUID}@${NODE_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS_Vision_${NODE_IP}"

echo -e "\n\033[32m====================================================="
echo -e "   Xray 部署成功 (稳定直连版)"
echo -e "=====================================================\033[0m"
echo -e "IP:   ${NODE_IP}"
echo -e "端口: ${PORT}"
echo -e "UUID: ${UUID}"
echo -e "SNI:  ${DEST_DOMAIN}"
echo -e "PBK:  ${PUB}"
echo -e "-----------------------------------------------------"
echo -e "\033[36m${LINK}\033[0m"
echo -e "=====================================================\n"
