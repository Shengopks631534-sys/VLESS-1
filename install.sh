#!/bin/bash
# ==================================================
# 纯净版 Xray 极速部署脚本 (VLESS + Reality + Vision)
# 核心来源: 官方 GitHub (XTLS/Xray-core)
# 适用系统: Ubuntu / Debian / CentOS / AlmaLinux
# ==================================================

# 遇到错误立即停止
set -e

# 1. 权限检查
[[ $EUID -ne 0 ]] && echo -e "\033[31m错误: 请使用 root 用户运行此脚本\033[0m" && exit 1

echo ">>> [1/6] 初始化配置..."

# 随机端口 (使用 10000 以上的高位端口避免冲突)
PORT=$((RANDOM % 10000 + 20000))
# 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
# 伪装域名 (Reality 的目标域名，推荐大厂域名)
DEST_DOMAIN="www.microsoft.com"
# 随机 ShortId
SHORT_ID=$(openssl rand -hex 4)

# 获取本机公网 IP
NODE_IP=$(curl -s4m5 https://api.ipify.org || curl -s4m5 https://ifconfig.me)
if [[ -z "$NODE_IP" ]]; then
    echo "无法获取公网 IP，请检查网络连接。"
    exit 1
fi

echo ">>> [2/6] 优化系统内核 (开启 BBR)..."
# 写入内核参数
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
# 应用参数
sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1

echo ">>> [3/6] 安装依赖与 Xray 核心..."
# 安装基础工具
if command -v apt >/dev/null; then
    apt update -qq && apt install -y -qq curl wget unzip jq openssl >/dev/null
elif command -v yum >/dev/null; then
    yum install -y -q curl wget unzip jq openssl >/dev/null
fi

# 准备目录
mkdir -p /usr/local/bin /var/log/xray /etc/xray

# 获取最新版 Xray 下载链接
echo "正在获取最新 Xray 版本..."
LATEST_URL=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .assets[].browser_download_url | grep 'linux-64.zip')

# 如果 API 获取失败，使用备用链接 (防止 GitHub API 限制)
if [[ -z "$LATEST_URL" ]]; then
    echo "API 获取失败，使用备用版本..."
    LATEST_URL="https://github.com/XTLS/Xray-core/releases/download/v1.8.24/Xray-linux-64.zip"
fi

# 下载并解压
curl -L -s -o xray.zip "$LATEST_URL"
unzip -o -q xray.zip xray -d /usr/local/bin/
chmod +x /usr/local/bin/xray
rm -f xray.zip

echo ">>> [4/6] 生成密钥与配置文件..."

# 使用 Xray 生成 Reality 密钥对
KEYS=$(/usr/local/bin/xray x25519)
PK=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
PUB=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')

# 写入配置文件 (不记录访问日志以保护隐私)
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

echo ">>> [5/6] 配置系统服务与防火墙..."

# 创建 Systemd 服务文件 (崩溃自动重启)
cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service (VLESS+Vision)
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

# 启动服务
systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1
systemctl restart xray

# 开放防火墙端口
if command -v ufw >/dev/null; then
    ufw allow ${PORT}/tcp >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
elif command -v firewall-cmd >/dev/null; then
    firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

echo ">>> [6/6] 部署完成！"

# 生成分享链接
LINK="vless://${UUID}@${NODE_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS_Vision_${NODE_IP}"

echo -e "\n\033[32m====================================================="
echo -e "   Xray 节点信息 (VLESS + Reality + Vision)"
echo -e "=====================================================\033[0m"
echo -e "地址 (IP):     ${NODE_IP}"
echo -e "端口 (Port):   ${PORT}"
echo -e "用户ID (UUID): ${UUID}"
echo -e "流控 (Flow):   xtls-rprx-vision"
echo -e "伪装域名 (SNI): ${DEST_DOMAIN}"
echo -e "公钥 (Public Key): ${PUB}"
echo -e "-----------------------------------------------------"
echo -e "🚀 通用分享链接 (复制到客户端):"
echo -e "\033[36m${LINK}\033[0m"
echo -e "=====================================================\n"
