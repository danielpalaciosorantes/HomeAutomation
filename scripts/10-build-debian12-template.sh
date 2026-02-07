#!/usr/bin/env bash
set -euo pipefail

# ---- configurable bits ----
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
TEMPLATE_NAME="${TEMPLATE_NAME:-debian12-ci-template}"
STORAGE="${STORAGE:-local-lvm}"   # change if you use different storage
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-2048}"
DISK_GB="${DISK_GB:-8}"
# ---------------------------

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
require_cmd qm
require_cmd pvesm
require_cmd wget

img="/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2"
mkdir -p "$(dirname "$img")"

if [[ ! -f "$img" ]]; then
  echo "Downloading Debian 12 generic cloud image..."
  wget -O "$img" "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
fi

# Delete existing VMID if it exists? We keep safe by refusing.
if qm status "$TEMPLATE_VMID" >/dev/null 2>&1; then
  echo "VMID $TEMPLATE_VMID already exists. Refusing to overwrite." >&2
  echo "If you want to rebuild, delete it first: qm destroy $TEMPLATE_VMID --purge 1" >&2
  exit 1
fi

echo "Creating template VMID $TEMPLATE_VMID ($TEMPLATE_NAME)..."
qm create "$TEMPLATE_VMID" --name "$TEMPLATE_NAME" --memory "$MEMORY" --cores "$CORES" \
  --net0 virtio,bridge="$BRIDGE"

# Import disk
qm importdisk "$TEMPLATE_VMID" "$img" "$STORAGE"

# Attach as scsi0 + set boot
qm set "$TEMPLATE_VMID" --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:vm-${TEMPLATE_VMID}-disk-0"
qm set "$TEMPLATE_VMID" --boot c --bootdisk scsi0

# Cloud-init drive
qm set "$TEMPLATE_VMID" --ide2 "${STORAGE}:cloudinit"

# Serial console + agent (recommended; you can install qemu-guest-agent via cloud-init later)
qm set "$TEMPLATE_VMID" --serial0 socket --vga serial0

# Resize disk if requested
qm resize "$TEMPLATE_VMID" scsi0 "${DISK_GB}G" >/dev/null

# Convert to template
qm template "$TEMPLATE_VMID"

echo "Template created: VMID=$TEMPLATE_VMID name=$TEMPLATE_NAME storage=$STORAGE"
