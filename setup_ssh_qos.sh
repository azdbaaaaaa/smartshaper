#!/bin/bash
set -e

# === Configuration Parameters ===
DEV=$(ip route get 1.1.1.1 | awk '{print $5; exit}')  # Automatically detect main network interface
UP="1000mbit"
DOWN="100mbit"
BACKUP_DIR="/etc/ssh_qos_backup"
LOG_FILE="/var/log/ssh_qos.log"
SCRIPT_PATH="/usr/local/bin/ssh_qos.sh"
SERVICE_PATH="/etc/systemd/system/ssh-qos.service"

echo "============================"
echo "SSH QoS Auto Setup Script"
echo "Interface: $DEV"
echo "Upload limit: $UP"
echo "Download limit: $DOWN"
echo "============================"

# === Environment Check ===
echo "[*] Checking dependencies..."
for cmd in tc iptables journalctl systemctl ss; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "Command not found: $cmd, please install it first"
    exit 1
  fi
done

# === Create main QoS script ===
echo "[*] Creating main script $SCRIPT_PATH ..."
sudo tee "$SCRIPT_PATH" >/dev/null <<'EOSCRIPT'
#!/bin/bash
DEV="{{DEV}}"
UP="{{UP}}"
DOWN="{{DOWN}}"
BACKUP_DIR="{{BACKUP_DIR}}"
LOG_FILE="{{LOG_FILE}}"
TC_BIN="/sbin/tc"
IPTABLES_BIN="/sbin/iptables"

mkdir -p "$BACKUP_DIR"

log() {
  echo "$(date '+%F %T') $*" | tee -a "$LOG_FILE"
}

# === Backup existing rules ===
log "[*] Backing up existing rules..."
$TC_BIN -s qdisc show dev $DEV > "$BACKUP_DIR/qdisc_$(date +%F_%H%M%S).bak" 2>/dev/null || true
$IPTABLES_BIN -t mangle -S > "$BACKUP_DIR/iptables_$(date +%F_%H%M%S).bak" 2>/dev/null || true

# === Reset old rules ===
log "[*] Resetting tc rules..."
$TC_BIN qdisc del dev $DEV root 2>/dev/null || true
$TC_BIN qdisc add dev $DEV root handle 1: htb default 30 r2q 1000
$TC_BIN class add dev $DEV parent 1: classid 1:1 htb rate ${UP}

# === Function to add per-IP limit ===
add_ip_limit() {
  local ip="$1"
  local mark
  mark=$(printf "%d" 0x$(echo "$ip" | md5sum | cut -c1-4))
  if $IPTABLES_BIN -t mangle -C PREROUTING -s $ip -j MARK --set-mark $mark 2>/dev/null; then
    return
  fi
  $IPTABLES_BIN -t mangle -A PREROUTING -s $ip -j MARK --set-mark $mark
  $TC_BIN class add dev $DEV parent 1:1 classid 1:$mark htb rate ${UP}
  $TC_BIN filter add dev $DEV parent 1: protocol ip handle $mark fw flowid 1:$mark
  log "[+] Applied limit for $ip ($UP / $DOWN)"
}

# === Initialize: apply limits to current SSH sessions ===
log "[*] Detecting current SSH sessions..."
for ip in $(ss -tn sport = :22 | awk 'NR>1{print $6}' | cut -d':' -f1 | sort -u); do
  [ -n "$ip" ] && add_ip_limit "$ip"
done

# === Dynamic SSH login monitoring ===
log "[*] Starting SSH login monitoring..."
journalctl -u sshd -f -n0 --no-pager | while read -r line; do
  if [[ "$line" =~ "Accepted" && "$line" =~ "from" ]]; then
    ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    [ -n "$ip" ] && add_ip_limit "$ip"
  fi
done
EOSCRIPT

# Replace placeholders with actual values
sudo sed -i "s|{{DEV}}|$DEV|g" "$SCRIPT_PATH"
sudo sed -i "s|{{UP}}|$UP|g" "$SCRIPT_PATH"
sudo sed -i "s|{{DOWN}}|$DOWN|g" "$SCRIPT_PATH"
sudo sed -i "s|{{BACKUP_DIR}}|$BACKUP_DIR|g" "$SCRIPT_PATH"
sudo sed -i "s|{{LOG_FILE}}|$LOG_FILE|g" "$SCRIPT_PATH"

sudo chmod +x "$SCRIPT_PATH"

# === Create systemd service ===
echo "[*] Creating systemd service ..."
sudo tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=Per-IP SSH QoS Service
After=network.target

[Service]
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# === Enable and start service ===
echo "[*] Starting ssh-qos service..."
systemctl daemon-reload
systemctl enable --now ssh-qos

echo "============================"
echo "[✅] SSH QoS has been deployed"
echo "Log file: $LOG_FILE"
echo "Backup directory: $BACKUP_DIR"
echo "Check service status: systemctl status ssh-qos"
echo "View log: tail -f $LOG_FILE"
echo "============================"

