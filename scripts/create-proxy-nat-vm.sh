#!/bin/bash

set -e

VMID=150
VMNAME="proxy-nat"
DISK_SIZE="20G"
MEMORY=2048
CORES=2
STORAGE="local-lvm"
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
  cat <<'EOF' > "$CLOUDINIT_SNIPPET"
#cloud-config
hostname: proxy-nat
timezone: Europe/Berlin
manage_etc_hosts: true
users:
  - name: admin
    gecos: Admin User
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    passwd: "$6$TyiFXrjq$MPMEJGV4gGFV1JGHZ6v3hsN6U7PgxPKvK/sTpCMBfdLJ7MRZmW9AZj5H0G3gGRi0OvWxk3YMdUpb4ChvYOekv0"

chpasswd:
  expire: false
ssh_pwauth: true

package_update: true
package_upgrade: true
packages:
  - curl
  - cloud-guest-utils
  - e2fsprogs
  - docker.io
  - docker-compose
  - iptables
runcmd:
  - curl -o /root/setup.sh https://raw.githubusercontent.com/danielpalaciosorantes/HomeAutomation/refs/heads/main/scripts/setup-proxy-nat.sh
  - chmod +x /root/setup.sh
  - /root/setup.sh
EOF
fi

# Step 4: Create and configure VM
echo "🖥️ Creating Proxmox VM..."
qm create $VMID --name $VMNAME --memory $MEMORY --cores $CORES --net0 virtio,bridge=vmbr0
qm importdisk $VMID "$IMG_PATH" $STORAGE
qm set $VMID --scsihw virtio-scsi-pci --scsi0 ${STORAGE}:vm-${VMID}-disk-0
qm resize $VMID scsi0 $DISK_SIZE
qm set $VMID --boot c --bootdisk scsi0
qm set $VMID --serial0 socket --vga serial0
qm set $VMID --ide2 $STORAGE:cloudinit
qm set $VMID --ipconfig0 ip=dhcp
qm set $VMID --net1 virtio,bridge=vmbr1
qm set $VMID --ipconfig1 ip=10.10.10.1/24
qm set $VMID --cicustom "user=local:snippets/user-data.yaml"

# Step 5: Start the VM
echo "🚀 Starting VM $VMID..."
qm start $VMID

echo "✅ VM $VMID created and started with cloud-init auto setup!"
