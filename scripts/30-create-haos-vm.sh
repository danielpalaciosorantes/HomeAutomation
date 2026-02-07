#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Reproducible HAOS VM creator
# ---------------------------

# REQUIRED: pin HAOS version for reproducibility (example: 17.0)
HAOS_VERSION="${HAOS_VERSION:?Set HAOS_VERSION (e.g. 17.0) to pin an exact HAOS release}"

# VM settings (override via env)
VMID="${VMID:-102}"
NAME="${NAME:-haos-01}"
BRIDGE="${BRIDGE:-vmbr0}"

CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"

# Storage where the VM disk should live
STORAGE="${STORAGE:-local-lvm}"

# Optional: Set a deterministic MAC to make DHCP reservation reproducible
# Example:
#   MAC="52:54:00:12:34:56"
MAC="${MAC:-52:54:00:ha:34:56}"  # leave empty to let Proxmox auto-generate

# QEMU / disk settings
SCSIHW="${SCSIHW:-virtio-scsi-pci}"

# HAOS Generic x86-64 image asset naming:
# For HAOS releases, the common asset is an .img.xz (raw disk image compressed)
ARCH="${ARCH:-generic-x86-64}"
HAOS_ASSET="${HAOS_ASSET:-haos_${ARCH}-${HAOS_VERSION}.img.xz}"

# Download/cache paths
CACHE_DIR="${CACHE_DIR:-/var/lib/vz/template/cache/haos}"
IMG_XZ="${CACHE_DIR}/${HAOS_ASSET}"
IMG_RAW="${IMG_XZ%.xz}"

# GitHub release download URL
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
echo "==> Asset: ${HAOS_ASSET}"
echo "==> Download: ${URL}"

# Fail fast if the asset doesn't exist
status_line="$(curl -sI "$URL" | head -n1 || true)"
if ! echo "$status_line" | grep -qE ' 200 '; then
  echo "ERROR: HAOS asset not found (HTTP HEAD: ${status_line})" >&2
  echo "Tried URL: ${URL}" >&2
  echo "Notes:" >&2
  echo "  - HAOS assets for Generic x86-64 are typically: haos_generic-x86-64-<ver>.img.xz" >&2
  echo "  - RC tags may exist but not always publish all assets." >&2
  exit 1
fi

# Download (resume supported)
if [[ ! -f "$IMG_XZ" ]]; then
  echo "==> Downloading to cache..."
  curl -L --fail --retry 3 --retry-delay 2 -o "$IMG_XZ" "$URL"
else
  echo "==> Using cached file: $IMG_XZ"
fi

# Decompress to raw .img (keep .xz cached)
if [[ ! -f "$IMG_RAW" ]]; then
  echo "==> Decompressing image..."
  xz -dk "$IMG_XZ"  # produces .img
else
  echo "==> Using cached file: $IMG_RAW"
fi

# Create VM (network with optional deterministic MAC)
NET0="virtio,bridge=${BRIDGE}"
if [[ -n "$MAC" ]]; then
  NET0="virtio=${MAC},bridge=${BRIDGE}"
fi

echo "==> Creating VM ${VMID} (${NAME})..."
qm create "$VMID" \
  --name "$NAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --net0 "$NET0" \
  --ostype l26 \
  --scsihw "$SCSIHW" \
  --serial0 socket \
  --vga serial0

echo "==> Importing disk into storage: ${STORAGE}"
qm importdisk "$VMID" "$IMG_RAW" "$STORAGE"

# Attach imported disk as scsi0.
# Proxmox typically names it: ${STORAGE}:vm-${VMID}-disk-0
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0"

# Boot from scsi0
qm set "$VMID" --boot order=scsi0

# Enable guest agent flag (HAOS can support it; harmless if not active)
qm set "$VMID" --agent enabled=1,fstrim_cloned_disks=1

echo "==> Starting VM..."
qm start "$VMID"

echo
echo "Done."
echo "VMID:   $VMID"
echo "Name:   $NAME"
echo "Bridge: $BRIDGE"
if [[ -n "$MAC" ]]; then
  echo "MAC:    $MAC (use this for DHCP reservation / 'static' IP)"
fi
echo
echo "Next:"
echo "  1) Find the VM's IP in your router/DHCP leases or Proxmox Summary"
echo "  2) Open: http://<VM_IP>:8123"
