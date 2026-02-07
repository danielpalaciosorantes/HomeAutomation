#!/usr/bin/env bash
set -euo pipefail

# ---- configurable bits ----
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"

VMID="${VMID:-101}"
NAME="${NAME:-rp-01}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-2048}"
DISK_GB="${DISK_GB:-20}"

BR_LAN="${BR_LAN:-vmbr0}"
BR_SVC="${BR_SVC:-vmbr1}"          # optional second NIC
ENABLE_SVC_NIC="${ENABLE_SVC_NIC:-1}"

LAN_IPCFG="${LAN_IPCFG:-ip=192.168.178.10/24,gw=192.168.178.1}"
SVC_IPCFG="${SVC_IPCFG:-ip=10.10.10.1/24}"   # no gw

SSH_PUB_KEY_FILE="${SSH_PUB_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

USER_DATA_IN="${USER_DATA_IN:-cloud-init/rp-user-data.yml}"
SNIPPETS_DIR="${SNIPPETS_DIR:-/var/lib/vz/snippets}"
# ---------------------------

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
require_cmd qm
require_cmd sed

[[ -f "$SSH_PUB_KEY_FILE" ]] || { echo "Missing SSH pubkey: $SSH_PUB_KEY_FILE" >&2; exit 1; }
[[ -f "$USER_DATA_IN" ]] || { echo "Missing user-data: $USER_DATA_IN" >&2; exit 1; }

mkdir -p "$SNIPPETS_DIR"

ssh_pub_key="$(cat "$SSH_PUB_KEY_FILE")"
user_data_out="${SNIPPETS_DIR}/${NAME}-user-data.yml"
sed "s|\${SSH_PUB_KEY}|${ssh_pub_key}|g" "$USER_DATA_IN" > "$user_data_out"

if qm status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID already exists. Refusing to overwrite." >&2
  exit 1
fi

qm clone "$TEMPLATE_VMID" "$VMID" --name "$NAME" --full 1
qm set "$VMID" --cores "$CORES" --memory "$MEMORY"
qm resize "$VMID" scsi0 "${DISK_GB}G" >/dev/null

# NIC0: LAN
qm set "$VMID" --net0 virtio,bridge="$BR_LAN"
qm set "$VMID" --ipconfig0 "$LAN_IPCFG"

# Optional NIC1: service network
if [[ "$ENABLE_SVC_NIC" == "1" ]]; then
  qm set "$VMID" --net1 virtio,bridge="$BR_SVC"
  qm set "$VMID" --ipconfig1 "$SVC_IPCFG"
fi

# cloud-init snippet
qm set "$VMID" --cicustom "user=local:snippets/${NAME}-user-data.yml"
qm set "$VMID" --ciuser bmanager

qm start "$VMID"
echo "Created + started $NAME (VMID $VMID)"
