#!/bin/bash

set -e

VMID=150
VMNAME="proxy-nat"
STORAGE="local-lvm"
DISK_SIZE="20G"
ISO_NAME="debian-12.11.0-amd64-netinst.iso"
ISO_PATH="/var/lib/vz/template/iso/$ISO_NAME"
ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$ISO_NAME"
BRIDGE_EXT="vmbr0"
BRIDGE_INT="vmbr1"

echo "Downloading Debian ISO..."

# Download the ISO if not present
if [ ! -f "$ISO_PATH" ]; then
  echo "Downloading $ISO_NAME..."
  curl -L -o "$ISO_PATH" "$ISO_URL"
else
  echo "ISO already exists at $ISO_PATH"
fi

# Create isolated bridge if missing
if ! brctl show | grep -q "$BRIDGE_INT"; then
  echo "Creating isolated bridge $BRIDGE_INT"
  cat <<EOF >> /etc/network/interfaces

auto $BRIDGE_INT
iface $BRIDGE_INT inet manual
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF
  ifup $BRIDGE_INT || echo "Note: you may need to reboot for bridge to come up"
fi

# Create the VM
echo "Creating VM $VMID ($VMNAME)..."
qm create $VMID \
  --name $VMNAME \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=$BRIDGE_EXT \
  --net1 virtio,bridge=$BRIDGE_INT \
  --ide2 local:iso/$ISO_NAME,media=cdrom \
  --boot order=ide2 \
  --scsihw virtio-scsi-pci \
  --scsi0 ${STORAGE}:size=${DISK_SIZE} \
  --ostype l26

echo "VM created. Open Proxmox Web UI and start VM $VMID to install Debian."

