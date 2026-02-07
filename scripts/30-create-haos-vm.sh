#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Reproducible HAOS VM creator
# ---------------------------

HAOS_VERSION="${HAOS_VERSION:?Set HAOS_VERSION (e.g. 13.2) to pin an exact HAOS release}"

VMID="${VMID:-102}"
NAME="${NAME:-haos-01}"

# Put HAOS on LAN (router DHCP)
BRIDGE="${BRIDGE:-vmbr0}"

CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"
DISK_GB="${DISK_GB:-32}"

STORAGE="${STORAGE:-local-lvm}"

# Optional deterministic MAC (useful for DHCP reservations on your router)
MAC="${MAC:-52:54:00:12:34:56}"  # empty => auto

ARCH="${ARCH:-generic-x86-64}"
HAOS_ASSET="${HAOS_ASSET:-haos_${ARCH}-${HAOS_VERSION}.img.xz}"

CACHE_DIR="${CACHE_DIR:-/var/lib/vz/template/cache/haos}"
IMG_XZ="${CACHE_DIR}/${HAOS_ASSET}"
IMG_RAW="${IMG_XZ%.xz}"

URL="${URL:-https://github.com/home-assistant/operating-system/releases/download/${HAOS_VERSION}/${HAOS_ASSET}}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
require_cmd qm
require_cmd curl
require_cmd xz

if qm status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID already exists. Refusing to overwrite." >&2
  echo "If you want to recreate: qm destroy $VMID --purge 1" >&2
  exit 1
fi

mkdir -p "$CACHE_DIR"

echo "==> HAOS version pinned: ${HAOS_VERSION}"
echo "==> Asset: ${HAOS_ASSET}"
echo "==> Download: ${URL}"

http_code="$(curl -sIL -o /dev/null -w '%{http_code}' "$URL" || true)"
if [[ "$http_code" != "200" && "$http_code" != "206" ]]; then
  echo "ERROR: HAOS asset not reachable (HTTP ${http_code})" >&2
  echo "Tried URL: ${URL}" >&2
  exit 1
fi

if [[ ! -f "$IMG_XZ" ]]; then
  echo "==> Downloading to cache..."
  curl -L --fail --retry 3 --retry-delay 2 -o "$IMG_XZ" "$URL"
else
  echo "==> Using cached file: $IMG_XZ"
fi

if [[ ! -f "$IMG_RAW" ]]; then
  echo "==> Decompressing image..."
  xz -dk "$IMG_XZ"
else
  echo "==> Using cached file: $IMG_RAW"
fi

NET0="virtio,bridge=${BRIDGE}"
if [[ -n "$MAC" ]]; then
  NET0="virtio=${MAC},bridge=${BRIDGE}"
fi

echo "==> Creating VM ${VMID} (${NAME}) on ${BRIDGE}..."
qm create "$VMID" \
  --name "$NAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --net0 "$NET0" \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --vga std \
  --agent enabled=1,fstrim_cloned_disks=1

echo "==> Importing HAOS disk into storage: ${STORAGE}"
qm importdisk "$VMID" "$IMG_RAW" "$STORAGE"

# The imported disk will appear as "unused0" initially; attach it as virtio0.
# We don't assume disk numbers; we read them from qm config to be safe.
imported_vol="$(qm config "$VMID" | awk -F'[:, ]+' '/^unused0:/ {print $2 ":" $3; exit}')"
if [[ -z "${imported_vol}" ]]; then
  echo "ERROR: Could not find unused0 after importdisk. qm config output:" >&2
  qm config "$VMID" >&2
  exit 1
fi

echo "==> Attaching imported disk as virtio0: ${imported_vol}"
qm set "$VMID" --virtio0 "${imported_vol}"

echo "==> Resizing virtio0 to ${DISK_GB}G"
qm resize "$VMID" virtio0 "${DISK_GB}G" >/dev/null

# IMPORTANT: add EFI disk AFTER import so it doesn't steal disk-0 numbering
# Keep it tiny; 4M or 8M is enough.
echo "==> Adding efidisk0 (secure boot disabled)"
qm set "$VMID" --efidisk0 "${STORAGE},efitype=4m,pre-enrolled-keys=0,size=4M"

echo "==> Boot from virtio0"
qm set "$VMID" --boot order=virtio0

echo "==> Starting VM..."
qm start "$VMID"

echo
echo "Done."
echo "VMID:   $VMID"
echo "Name:   $NAME"
echo "Bridge: $BRIDGE (LAN DHCP)"
if [[ -n "$MAC" ]]; then
  echo "MAC:    $MAC"
  echo "TIP:    Create a DHCP reservation on your router for this MAC."
fi
echo
echo "Access: http://<HAOS-IP>:8123  (find IP in router DHCP leases)"
