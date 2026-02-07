#!/usr/bin/env bash
set -euo pipefail

# ---- configurable bits (can be overridden via env) ----
LAN_IP_CIDR="${LAN_IP_CIDR:-192.168.178.50/24}"
LAN_GW="${LAN_GW:-192.168.178.1}"
ROLLBACK_SECONDS="${ROLLBACK_SECONDS:-120}"
ENABLE_VMBR1="${ENABLE_VMBR1:-1}"
# ------------------------------------------------------

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
require_cmd ip
require_cmd ifreload
require_cmd bridge
require_cmd systemd-run

stamp="$(date +%Y%m%d-%H%M%S)"
backup="/etc/network/interfaces.bak.${stamp}"
newcfg="/etc/network/interfaces.new.${stamp}"

# 1) Determine uplink NIC:
# Prefer: physical port enslaved to vmbr0
uplink_nic="$(bridge link show 2>/dev/null | awk '/master vmbr0/ {gsub(":", "", $2); print $2; exit}')"

# Fallback: try to guess a non-vmbr interface with carrier
if [[ -z "${uplink_nic}" ]]; then
  uplink_nic="$(ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^(lo|vmbr[0-9]+|tap|fwbr|fwln|veth|docker|br-|virbr|bond|eno|enx.*:)' | head -n1 || true)"
fi

if [[ -z "${uplink_nic}" ]]; then
  echo "Could not determine uplink NIC. Run: bridge link show" >&2
  exit 1
fi

echo "Uplink NIC detected: ${uplink_nic}"

# 2) Check current config for the exact bug we hit (bridge-ports vmbr0)
needs_fix=0
if grep -qE '^\s*bridge-ports\s+vmbr0\b' /etc/network/interfaces; then
  echo "Detected bad config: bridge-ports vmbr0"
  needs_fix=1
fi

# Also fix if vmbr0 is defined as both manual + static in the same file (common mistake)
if grep -qE '^\s*iface\s+vmbr0\s+inet\s+manual\b' /etc/network/interfaces; then
  echo "Detected redundant stanza: iface vmbr0 inet manual"
  needs_fix=1
fi

# If vmbr0 doesn't exist as a link, we must create it (rare on Proxmox, but supported)
if ! ip link show vmbr0 >/dev/null 2>&1; then
  echo "vmbr0 does not exist; will (re)create config."
  needs_fix=1
fi

# If only vmbr1 is missing and vmbr0 is fine, we can do minimal change
needs_vmbr1=0
if [[ "${ENABLE_VMBR1}" == "1" ]] && ! ip link show vmbr1 >/dev/null 2>&1; then
  needs_vmbr1=1
fi

if [[ "${needs_fix}" -eq 0 && "${needs_vmbr1}" -eq 0 ]]; then
  echo "Networking already looks good. Nothing to do."
  exit 0
fi

echo "Will update /etc/network/interfaces (fix=${needs_fix}, add_vmbr1=${needs_vmbr1})."

cp /etc/network/interfaces "${backup}"
echo "Backup saved: ${backup}"

# 3) Write a clean, canonical interfaces file
# Note: This is opinionated. It becomes the single source of truth.
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
EOF

if [[ "${ENABLE_VMBR1}" == "1" ]]; then
cat >> "${newcfg}" <<'EOF'

auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
fi

# 4) Rollback unit
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
echo "Scheduled rollback in ${ROLLBACK_SECONDS}s: ${rollback_unit}"

# 5) Apply
cp "${newcfg}" /etc/network/interfaces
echo "Applying new network config..."
ifreload -a

echo
echo "Validate:"
echo "  ip a show vmbr0"
echo "  ip route | head"
echo
echo "If OK, cancel rollback:"
echo "  systemctl stop ${rollback_unit}.timer ${rollback_unit}.service 2>/dev/null || true"
