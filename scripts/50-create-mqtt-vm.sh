#!/usr/bin/env bash
set -euo pipefail

# ---- configurable bits ----
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"

VMID="${VMID:-102}"
NAME="${NAME:-mqtt-01}"
HOSTNAME="${HOSTNAME:-mqtt-01}"

CORES="${CORES:-1}"
MEMORY="${MEMORY:-1024}"
DISK_GB="${DISK_GB:-12}"

BR_LAN="${BR_LAN:-vmbr0}"
LAN_MAC="${LAN_MAC:-02:DE:AD:BE:EF:15}"
LAN_IPCFG="${LAN_IPCFG:-ip=192.168.178.15/24,gw=192.168.178.1}"

SSH_PUB_KEY_FILE="${SSH_PUB_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

MQTT_USERNAME="${MQTT_USERNAME:-homeassistant}"
MQTT_PASSWORD="${MQTT_PASSWORD:-change-me-please}"

USER_DATA_IN="${USER_DATA_IN:-cloud-init/mqtt-user-data.yml}"
SNIPPETS_DIR="${SNIPPETS_DIR:-/var/lib/vz/snippets}"
# ---------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd qm
require_cmd python3

[[ -f "$SSH_PUB_KEY_FILE" ]] || {
  echo "Missing SSH pubkey: $SSH_PUB_KEY_FILE" >&2
  exit 1
}

[[ -f "$USER_DATA_IN" ]] || {
  echo "Missing user-data template: $USER_DATA_IN" >&2
  exit 1
}

if [[ "$MQTT_PASSWORD" == "change-me-please" ]]; then
  echo "Refusing to continue with default MQTT_PASSWORD." >&2
  echo "Run for example:" >&2
  echo "  MQTT_PASSWORD='your-secure-password' ./create-mqtt-vm.sh" >&2
  exit 1
fi

if qm status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID already exists. Refusing to overwrite." >&2
  exit 1
fi

mkdir -p "$SNIPPETS_DIR"

ssh_pub_key="$(cat "$SSH_PUB_KEY_FILE")"
user_data_out="${SNIPPETS_DIR}/${NAME}-user-data.yml"

export SSH_PUB_KEY="$ssh_pub_key"
export MQTT_USERNAME
export MQTT_PASSWORD
export HOSTNAME
export USER_DATA_IN
export USER_DATA_OUT="$user_data_out"

python3 - <<'PY'
import os
from pathlib import Path

template_path = Path(os.environ["USER_DATA_IN"])
output_path = Path(os.environ["USER_DATA_OUT"])

content = template_path.read_text()

replacements = {
    "${SSH_PUB_KEY}": os.environ["SSH_PUB_KEY"],
    "${MQTT_USERNAME}": os.environ["MQTT_USERNAME"],
    "${MQTT_PASSWORD}": os.environ["MQTT_PASSWORD"],
    "${HOSTNAME}": os.environ["HOSTNAME"],
}

for key, value in replacements.items():
    content = content.replace(key, value)

output_path.write_text(content)
PY

echo "Creating VM ${NAME} with VMID ${VMID}"
echo "Bridge: ${BR_LAN}"
echo "MAC:    ${LAN_MAC}"
echo "IPCFG:  ${LAN_IPCFG}"

qm clone "$TEMPLATE_VMID" "$VMID" --name "$NAME" --full 1

qm set "$VMID" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --net0 virtio="${LAN_MAC}",bridge="$BR_LAN" \
  --ipconfig0 "$LAN_IPCFG" \
  --ciuser bmanager \
  --cicustom "user=local:snippets/${NAME}-user-data.yml"

qm resize "$VMID" scsi0 "${DISK_GB}G" >/dev/null || {
  echo "Disk resize failed. This can happen if the disk is already larger than ${DISK_GB}G." >&2
}

qm start "$VMID"

echo "Created and started ${NAME} with VMID ${VMID}"
echo "Hostname: ${HOSTNAME}"
echo "IP:       192.168.178.15"
echo "MAC:      ${LAN_MAC}"
echo "MQTT user: ${MQTT_USERNAME}"
echo "MQTT port: 1883"