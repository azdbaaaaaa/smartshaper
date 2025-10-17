#!/bin/bash
set -e

# === 配置参数 ===
DEV=$(ip route get 1.1.1.1 | awk '{print $5; exit}')  # 自动检测主网卡
UP="1000mbit"
DOWN="100mbit"
BACKUP_DIR="/etc/ssh_qos_backup"
LOG_FILE="/var/log/ssh_qos.log"
SCRIPT_PATH="/usr/local/bin/ssh_qos.sh"
SERVICE_PATH="/etc/systemd/system/ssh-qos.service"

echo "============================"
echo "SSH QoS Auto Setup Script"
echo "网卡: $DEV"
echo "上行限速: $UP"
echo "下行限速: $DOWN"
echo "============================"

# === 环境检查 ===
echo "[*] 检查依赖..."
for cmd in tc iptables journalctl systemctl; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "未找到命令: $cmd, 请安装后重试"
    exit 1
  fi
done

# === 创建主限速脚本 ===
echo "[*] 创建主脚本 $SCRIPT_PATH ..."
sudo tee "$SCRIPT_PATH" >/dev/null <<EOF
#!/bin/bash
DEV="$DEV"
UP="$UP"
DOWN="$DOWN"
BACKUP_DIR="$BACKUP_DIR"
LOG_FILE="$LOG_FILE"
TC_BIN="/sbin/tc"
IPTABLES_BIN="/sbin/iptables"

mkdir -p "\$BACKUP_DIR"

log() {
  echo "\$(date '+%F %T') \$*" | tee -a "\$LOG_FILE"
}

# === 备份规则 ===
log "[*] 备份现有规则..."
\$TC_BIN -s qdisc show dev \$DEV > "\$BACKUP_DIR/qdisc_\$(date +%F_%H%M%S).bak" 2>/dev/null || true
\$IPTABLES_BIN -t mangle -S > "\$BACKUP_DIR/iptables_\$(date +%F_%H%M%S).bak" 2>/dev/null || true

# === 清理旧规则 ===
log "[*] 重置 tc 规则..."
\$TC_BIN qdisc del dev \$DEV root 2>/dev/null || true
\$TC_BIN qdisc add dev \$DEV root handle 1: htb default 30
\$TC_BIN class add dev \$DEV parent 1: classid 1:1 htb rate \${UP}

add_ip_limit() {
  local ip="\$1"
  local mark
  mark=\$(printf "%d" 0x\$(echo "\$ip" | md5sum | cut -c1-4))
  if \$IPTABLES_BIN -t mangle -C PREROUTING -s \$ip -j MARK --set-mark \$mark 2>/dev/null; then
    return
  fi
  \$IPTABLES_BIN -t mangle -A PREROUTING -s \$ip -j MARK --set-mark \$mark
  \$TC_BIN class add dev \$DEV parent 1:1 classid 1:\$mark htb rate \${UP}
  \$TC_BIN filter add dev \$DEV parent 1: protocol ip handle \$mark fw flowid 1:\$mark
  log "[+] 已为 \$ip 添加限速 (\$UP / \$DOWN)"
}

# === 初始化：对当前 SSH 连接应用限速 ===
log "[*] 检测当前 SSH 会话..."
for ip in \$(ss -tn sport = :22 | awk 'NR>1{print \$6}' | cut -d':' -f1 | sort -u); do
  [ -n "\$ip" ] && add_ip_limit "\$ip"
done

# === 动态监控 SSH 登录 ===
log "[*] 启动 SSH 登录监听..."
journalctl -u sshd -f -n0 --no-pager | while read -r line; do
  if [[ "\$line" =~ "Accepted" && "\$line" =~ "from" ]]; then
    ip=\$(echo "\$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    [ -n "\$ip" ] && add_ip_limit "\$ip"
  fi
done
EOF

chmod +x "$SCRIPT_PATH"

# === 创建 systemd 服务 ===
echo "[*] 创建 systemd 服务 ..."
sudo tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=Per-IP SSH QoS Service
After=network.target

[Service]
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=5
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

# === 启用并启动服务 ===
echo "[*] 启动 ssh-qos 服务..."
systemctl daemon-reload
systemctl enable --now ssh-qos

echo "============================"
echo "[✅] SSH QoS 已部署完成"
echo "日志文件: $LOG_FILE"
echo "规则备份目录: $BACKUP_DIR"
echo "检查服务状态: systemctl status ssh-qos"
echo "查看日志: tail -f $LOG_FILE"
echo "============================"
EOF

