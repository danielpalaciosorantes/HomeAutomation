#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Reproducible HAOS VM creator
# ---------------------------

# REQUIRED: pin HAOS version for reproducibility (example: 13.2)
HAOS_VERSION="${HAOS_VERSION:-17.0}"
MAC="${MAC:-52:54:00:ha:01:02}"
# VM settings (override via env if needed)
VMID="${VMID:-102}"
NAME="${NAME:-haos-01}"
BRIDGE="${BRIDGE:-vmbr0}"

CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"

# Storage where the VM disk should live
STORAGE="${STORAGE:-local-lvm}"

# Disk interface settings
SCSIHW="${SCSIHW:-virtio-scsi-pci}"

# HAOS image choice:
# Most Proxmox setups use the "generic x86-64" qcow2 image.
# If your release asset naming differs, override HAOS_ASSET via env.
HAOS_ASSET="${HAOS_ASSET:-haos_generic-x86-64-${HAOS_VERSION}.qcow2.xz}"

# Download location and cache
CACHE_DIR="${CACHE_DIR:-/var/lib/vz/template/cache/haos}"
IMG_XZ="${CACHE_DIR}/${HAOS_ASSET}"
IMG_QCOW2="${IMG_XZ%.xz}"

# URL (GitHub releases)
URL="${URL:-https://github.com/home-assistant/operating-system/releases/download/${HAOS_VERSION}/${HAOS_ASSET}}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
require_cmd qm
require_cmd pvesm
require_cmd curl
require_cmd xz

# Safety: do not overwrite existing VMID
if qm status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID already exists. Refusing to overwrite." >&2
  echo "If you want to recreate: qm destroy $VMID --purge 1" >&2
  exit 1
fi

mkdir -p "$CACHE_DIR"

echo "==> HAOS version pinned: ${HAOS_VERSION}"
echo "==> Download: ${URL}"

# Download (resume supported)
if [[ ! -f "$IMG_XZ" ]]; then
  curl -L --fail --retry 3 --retry-delay 2 -o "$IMG_XZ" "$URL"
else
  echo "==> Using cached file: $IMG_XZ"
fi

# Decompress to qcow2 (keep .xz for caching)
if [[ ! -f "$IMG_QCOW2" ]]; then
  echo "==> Decompressing qcow2..."
  xz -dk "$IMG_XZ"  # produces .qcow2
else
  echo "==> Using cached file: $IMG_QCOW2"
fi

echo "==> Creating VM ${VMID} (${NAME})..."
qm create "$VMID" \
  --name "$NAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --net0 "virtio=${MAC},bridge=${BRIDGE}" \
  --ostype l26 \
  --scsihw "$SCSIHW" \
  --serial0 socket \
  --vga serial0

echo "==> Importing disk into storage: ${STORAGE}"
qm importdisk "$VMID" "$IMG_QCOW2" "$STORAGE"

# Attach imported disk as scsi0.
# Proxmox typically names it: ${STORAGE}:vm-${VMID}-disk-0
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0"

# Boot from scsi0
qm set "$VMID" --boot order=scsi0

# Recommended: enable QEMU guest agent (HAOS supports it via add-on/agent in many setups;
# harmless if not active)
qm set "$VMID" --agent enabled=1,fstrim_cloned_disks=1

echo "==> Starting VM..."
qm start "$VMID"

echo
echo "Done."
echo "VMID: $VMID"
echo "Name: $NAME"
echo "Bridge: $BRIDGE"
echo
echo "Next:"
echo "  1) Find the VM's IP in your router/DHCP leases or Proxmox 'Summary' tab"
echo "  2) Open: http://<VM_IP>:8123"
echo
echo "Pinned release asset:"
echo "  ${HAOS_ASSET}"
