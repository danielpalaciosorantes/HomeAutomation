#!/usr/bin/env bash
set -euo pipefail

LAN_IP_CIDR="${LAN_IP_CIDR:-192.168.178.50/24}"
LAN_GW="${LAN_GW:-192.168.178.1}"
ROLLBACK_SECONDS="${ROLLBACK_SECONDS:-120}"

if ! command -v ifreload >/dev/null 2>&1; then
  echo "Install ifupdown2 first: apt-get update && apt-get install -y ifupdown2" >&2
  exit 1
fi

NIC="$(ip route show default | awk '{print $5}' | head -n1)"
[[ -n "$NIC" ]] || { echo "Could not detect default NIC" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/etc/network/interfaces.bak.${STAMP}"
NEWCFG="/etc/network/interfaces.new"

cp /etc/network/interfaces "$BACKUP"

cat > "$NEWCFG" <<EOF
auto lo
iface lo inet loopback

iface ${NIC} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${LAN_IP_CIDR}
    gateway ${LAN_GW}
    bridge-ports ${NIC}
    bridge-stp off
    bridge-fd 0

auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF

ROLLBACK_SCRIPT="/root/net-rollback-${STAMP}.sh"
cat > "$ROLLBACK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cp "${BACKUP}" /etc/network/interfaces
ifreload -a || true
EOF
chmod +x "$ROLLBACK_SCRIPT"

ROLLBACK_UNIT="net-rollback-${STAMP}"
systemd-run --unit="${ROLLBACK_UNIT}" --on-active="${ROLLBACK_SECONDS}" "${ROLLBACK_SCRIPT}" >/dev/null

cp "$NEWCFG" /etc/network/interfaces
ifreload -a

echo "If all good, cancel rollback:"
echo "  systemctl stop ${ROLLBACK_UNIT}"
