#!/bin/bash

set -e

echo "📦 Checking for root partition resize..."

apt update
apt install -y cloud-guest-utils e2fsprogs

ROOT_DEV=$(df / | awk 'NR==2 {print $1}')
DISK_DEV=$(lsblk -no pkname "$ROOT_DEV")
PART_NUM=$(echo "$ROOT_DEV" | grep -o '[0-9]*$')

growpart "/dev/$DISK_DEV" "$PART_NUM"
resize2fs "$ROOT_DEV"

# Detect interfaces
echo "🔍 Detecting interfaces..."
ALL_INTERFACES=($(ls /sys/class/net | grep -v lo))
EXT_IF=""
INT_IF=""

for IF in "${ALL_INTERFACES[@]}"; do
  if dhclient -v $IF | grep -q "192.168"; then
    EXT_IF=$IF
  else
    INT_IF=$IF
  fi
done

[[ -z "$EXT_IF" || -z "$INT_IF" ]] && echo "❌ Interface detection failed." && exit 1

echo "✅ External: $EXT_IF | Internal: $INT_IF"

# Configure networking
systemctl disable --now NetworkManager 2>/dev/null || true
systemctl disable --now networking 2>/dev/null || true
systemctl enable --now systemd-networkd
systemctl enable --now systemd-resolved
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

cat <<EOF > /etc/systemd/network/10-$EXT_IF.network
[Match]
Name=$EXT_IF
[Network]
DHCP=yes
EOF

cat <<EOF > /etc/systemd/network/20-$INT_IF.network
[Match]
Name=$INT_IF
[Network]
Address=10.10.10.1/24
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF

systemctl restart systemd-networkd

# Install Docker + Compose
apt install -y procps curl docker.io docker-compose
systemctl enable --now docker

# Enable NAT
echo "🌐 Enabling NAT..."
sysctl -w net.ipv4.ip_forward=1
grep -q net.ipv4.ip_forward /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

iptables -t nat -A POSTROUTING -o $EXT_IF -j MASQUERADE
iptables-save > /etc/iptables.rules

cat <<'EOF' > /etc/network/if-up.d/iptables-restore
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF

chmod +x /etc/network/if-up.d/iptables-restore

# NGINX Proxy Manager
echo "🚀 Deploying NGINX Proxy Manager..."
mkdir -p /opt/npm && cd /opt/npm

cat <<EOF > docker-compose.yml
version: '3'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF

docker-compose up -d

echo -e "\n✅ Setup complete!"
echo "Access NGINX Proxy Manager at http://<your-lan-ip>:81 (admin@example.com / changeme)"
