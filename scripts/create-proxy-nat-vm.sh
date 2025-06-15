#!/bin/bash

set -e

VMID=150
VMNAME="proxy-nat"
DISK_SIZE="20G"
MEMORY=2048
CORES=2
STORAGE="local-lvm"
STORAGE_CLOUDINIT="local"
ISO_DIR="/var/lib/vz/template/iso"
IMG_NAME="debian-12-genericcloud-amd64.qcow2"
IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/$IMG_NAME"
IMG_PATH="$ISO_DIR/$IMG_NAME"
CLOUDINIT_SNIPPET="/var/lib/vz/snippets/user-data.yaml"

# Step 1: Download Debian cloud image
echo "📥 Downloading Debian image if not already present..."
mkdir -p "$ISO_DIR"
[ -f "$IMG_PATH" ] || wget -O "$IMG_PATH" "$IMG_URL"

# Step 2: Ensure vmbr1 exists
if ! grep -q "vmbr1" /etc/network/interfaces; then
  echo "🔧 Creating isolated bridge vmbr1..."
  cat <<EOF >> /etc/network/interfaces

auto vmbr1
iface vmbr1 inet manual
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF
  ifup vmbr1 || echo "Note: you may need to reboot for vmbr1 to become active."
fi

# Step 3: Create cloud-init snippet if missing
if [ ! -f "$CLOUDINIT_SNIPPET" ]; then
  echo "⚙️ Creating cloud-init user-data..."
  mkdir -p /var/lib/vz/snippets

  SSH_KEY=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null)
  if [ -z "$SSH_KEY" ]; then
    echo "❌ No SSH public key found in ~/.ssh. Aborting."
    exit 1
  fi

  echo "📥 Downloading cloud-init config from GitHub..."
  wget -q https://raw.githubusercontent.com/danielpalaciosorantes/HomeAutomation/refs/heads/main/scripts/test.yml \
       -O "$CLOUDINIT_SNIPPET"

  # Replace placeholder with actual key safely
  sed -i "s|REPLACE_SSH_KEY|$SSH_KEY|" "$CLOUDINIT_SNIPPET"
fi

echo "=======================CLOUDINIT SNIPPET======================="
cat $CLOUDINIT_SNIPPET
echo "==============================================================="

# Step 4: Create and configure VM
echo "🖥️ Creating Proxmox VM..."
qm create $VMID --name $VMNAME --memory $MEMORY --cores $CORES --net0 virtio,bridge=vmbr0
qm importdisk $VMID "$IMG_PATH" $STORAGE
qm set $VMID --scsihw virtio-scsi-pci --scsi0 ${STORAGE}:vm-${VMID}-disk-0
qm resize $VMID scsi0 $DISK_SIZE
qm set $VMID --boot c --bootdisk scsi0
qm set $VMID --serial0 socket --vga serial0
qm set $VMID --ide2 $STORAGE_CLOUDINIT:cloudinit
qm set $VMID --ipconfig0 ip=dhcp
qm set $VMID --net1 virtio,bridge=vmbr1
qm set $VMID --ipconfig1 ip=10.10.10.1/24
qm set $VMID --cicustom "user=local:snippets/user-data.yaml"

# Step 5: Start the VM
echo "🚀 Starting VM $VMID..."
qm start $VMID

echo "✅ VM $VMID created and started with cloud-init auto setup!"
