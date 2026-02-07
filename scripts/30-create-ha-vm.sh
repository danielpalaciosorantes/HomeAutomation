#!/usr/bin/env bash
set -euo pipefail

# ---- configurable bits ----
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"

VMID="${VMID:-102}"
NAME="${NAME:-ha-01}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"
DISK_GB="${DISK_GB:-32}"

BR_LAN="${BR_LAN:-vmbr0}"

# Home Assistant LAN IP (static)
LAN_IPCFG="${LAN_IPCFG:-ip=192.168.178.11/24,gw=192.168.178.1}"

# Reverse proxy LAN IP (allowed inbound source)
RP_LAN_IP="${RP_LAN_IP:-192.168.178.10}"

SSH_PUB_KEY_FILE="${SSH_PUB_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

USER_DATA_IN="${USER_DATA_IN:-cloud-init/ha-user-data.yml}"
SNIPPETS_DIR="${SNIPPETS_DIR:-/var/lib/vz/snippets}"
# ---------------------------

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
require_cmd qm
require_cmd sed

if [[ ! -f "$SSH_PUB_KEY_FILE" ]]; then
  echo "Missing SSH pubkey: $SSH_PUB_KEY_FILE" >&2
  echo "Fix options:" >&2
  echo "  1) Generate on host: ssh-keygen -t ed25519 -a 64 -f /root/.ssh/homelab_ed25519 -N ''" >&2
  echo "     then: SSH_PUB_KEY_FILE=/root/.ssh/homelab_ed25519.pub bash scripts/30-create-ha-vm.sh" >&2
  echo "  2) Copy from your laptop: scp ~/.ssh/id_ed25519.pub root@<pve>:/root/.ssh/id_ed25519.pub" >&2
  exit 1
fi

if [[ ! -f "$USER_DATA_IN" ]]; then
  echo "Missing user-data: $USER_DATA_IN" >&2
  exit 1
fi

mkdir -p "$SNIPPETS_DIR"

ssh_pub_key="$(cat "$SSH_PUB_KEY_FILE")"
user_data_out="${SNIPPETS_DIR}/${NAME}-user-data.yml"

# Render placeholders into snippet
# - ${SSH_PUB_KEY}
# - ${RP_LAN_IP}
# Use sed with a safe delimiter
sed \
  -e "s|\${SSH_PUB_KEY}|${ssh_pub_key}|g" \
  -e "s|\${RP_LAN_IP}|${RP_LAN_IP}|g" \
  "$USER_DATA_IN" > "$user_data_out"

if qm status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID already exists. Refusing to overwrite." >&2
  exit 1
fi

# Clone VM from template
qm clone "$TEMPLATE_VMID" "$VMID" --name "$NAME" --full 1

# CPU/RAM/Disk
qm set "$VMID" --cores "$CORES" --memory "$MEMORY"
qm resize "$VMID" scsi0 "${DISK_GB}G" >/dev/null

# NIC: LAN only
qm set "$VMID" --net0 virtio,bridge="$BR_LAN"
qm set "$VMID" --ipconfig0 "$LAN_IPCFG"

# cloud-init snippet
qm set "$VMID" --cicustom "user=local:snippets/${NAME}-user-data.yml"
qm set "$VMID" --ciuser daniel

qm start "$VMID"
echo "Created + started $NAME (VMID $VMID)"
echo "Firewall policy: inbound only from ${RP_LAN_IP} to 8123/tcp; outbound only DNS+80/443."
