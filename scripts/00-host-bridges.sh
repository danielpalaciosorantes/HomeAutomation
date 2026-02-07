#!/usr/bin/env bash
set -euo pipefail

# ---- configurable bits (override via env) ----
LAN_IP_CIDR="${LAN_IP_CIDR:-192.168.178.50/24}"
LAN_GW="${LAN_GW:-192.168.178.1}"
ROLLBACK_SECONDS="${ROLLBACK_SECONDS:-120}"
# ---------------------------------------------

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
require_cmd ip
require_cmd ifreload
require_cmd bridge
require_cmd systemd-run

stamp="$(date +%Y%m%d-%H%M%S)"
backup="/etc/network/interfaces.bak.${stamp}"
newcfg="/etc/network/interfaces.new.${stamp}"

# Detect physical NIC that is currently enslaved to vmbr0.
# Example output: "2: enp1s0: ... master vmbr0 ..."
uplink_nic="$(bridge link show 2>/dev/null | awk '/master vmbr0/ {gsub(":", "", $2); print $2; exit}')"
if [[ -z "${uplink_nic}" ]]; then
  echo "Could not detect uplink NIC from 'bridge link show'." >&2
  echo "Make sure vmbr0 exists, then run: bridge link show" >&2
  exit 1
fi

echo "Uplink NIC detected: ${uplink_nic}"

# Decide whether we need to touch the config at all.
needs_fix=0

# Fix the exact issue you hit: vmbr0 bridged to itself
if grep -qE '^\s*bridge-ports\s+vmbr0\b' /etc/network/interfaces; then
  echo "Detected bad config: 'bridge-ports vmbr0'"
  needs_fix=1
fi

# Fix redundant/incorrect stanza that causes dependency issues
if grep -qE '^\s*iface\s+vmbr0\s+inet\s+manual\b' /etc/network/interfaces; then
  echo "Detected redundant stanza: 'iface vmbr0 inet manual'"
  needs_fix=1
fi

# Ensure vmbr1 exists in config; if not, we’ll add it
if ! grep -qE '^\s*auto\s+vmbr1\b' /etc/network/interfaces; then
  echo "vmbr1 not present in /etc/network/interfaces"
  needs_fix=1
fi

# If everything looks fine, do nothing (idempotent)
if [[ "${needs_fix}" -eq 0 ]]; then
  echo "Networking config looks good. Nothing to do."
  exit 0
fi

echo "Updating /etc/network/interfaces (rollback in ${ROLLBACK_SECONDS}s if needed)."

cp /etc/network/interfaces "${backup}"
echo "Backup saved: ${backup}"

# Write canonical config:
# - vmbr0 static (LAN)
# - uplink NIC manual
# - vmbr1 manual (isolated, no IP on host)
cat > "${newcfg}" <<EOF
auto lo
iface lo inet loopback

iface ${uplink_nic} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${LAN_IP_CIDR}
    gateway ${LAN_GW}
    bridge-ports ${uplink_nic}
    bridge-stp off
    bridge-fd 0

auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0

source /etc/network/interfaces.d/*
EOF

# Rollback unit: restore backup + reload
rollback_script="/root/net-rollback-${stamp}.sh"
cat > "${rollback_script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "ROLLBACK: restoring ${backup}"
cp "${backup}" /etc/network/interfaces
ifreload -a || true
EOF
chmod +x "${rollback_script}"

rollback_unit="net-rollback-${stamp}"
systemd-run --unit="${rollback_unit}" --on-active="${ROLLBACK_SECONDS}" "${rollback_script}" >/dev/null
echo "Scheduled rollback: ${rollback_unit} (in ${ROLLBACK_SECONDS}s)"

# Apply
cp "${newcfg}" /etc/network/interfaces
echo "Applying new config..."
ifreload -a

echo
echo "Validate:"
echo "  ip a show vmbr0"
echo "  ip link show vmbr1"
echo "  ip route | head"
echo
echo "If OK, cancel rollback:"
echo "  systemctl stop ${rollback_unit}.timer ${rollback_unit}.service 2>/dev/null || true"
