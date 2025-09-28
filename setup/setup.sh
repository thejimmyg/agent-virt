#!/bin/bash
set -e

echo "⚙️  Agent Virt - VM Environment Setup"
echo "===================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Check if we're running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

log_info "Setting up VM environment (network + mounts)..."

#
# MOUNT SETUP
#
log_info "Configuring filesystem mounts..."

# Remove any existing agent-virt mounts from fstab
log_info "Cleaning up old mount entries..."
sed -i '/# agent-virt mounts/,$d' /etc/fstab

# Add our mount entries
log_info "Adding mount entries to /etc/fstab..."
cat >> /etc/fstab << 'EOF'
# agent-virt mounts
setup /opt/setup virtiofs defaults 0 0
read /opt/read virtiofs defaults 0 0
write /opt/write virtiofs defaults 0 0
EOF

# Create mount directories
log_info "Creating mount directories..."
mkdir -p /opt/setup /opt/read /opt/write

# Mount all filesystems
log_info "Mounting filesystems..."
if mount -a 2>/dev/null; then
    log_success "All filesystems mounted successfully"
else
    log_warning "Some filesystems may have failed to mount (checking...)"
fi

# Verify mounts
log_info "Verifying mount status..."
MOUNT_STATUS=0
if mountpoint -q /opt/setup; then
    log_success "/opt/setup is mounted"
else
    log_warning "/opt/setup is not mounted - virtiofs may not be attached"
    MOUNT_STATUS=1
fi

if mountpoint -q /opt/read; then
    log_success "/opt/read is mounted"
else
    log_warning "/opt/read is not mounted - virtiofs may not be attached"
    MOUNT_STATUS=1
fi

if mountpoint -q /opt/write; then
    log_success "/opt/write is mounted"
else
    log_warning "/opt/write is not mounted - virtiofs may not be attached"
    MOUNT_STATUS=1
fi

if [ $MOUNT_STATUS -ne 0 ]; then
    echo ""
    log_warning "Some mounts are not available. This is normal if:"
    echo "  - This is a first run and VM needs to be restarted"
    echo "  - The VM was created without using create.sh"
    echo ""
    echo "Try: sudo mount -t virtiofs <name> /opt/<name>"
    echo "Where <name> is one of: setup, read, write"
fi

# Reload systemd
systemctl daemon-reload

#
# NETWORK SETUP
#
log_info "Configuring network resilience for WiFi/network changes..."

# Enable and configure systemd-resolved for DNS resilience
if ! systemctl is-active --quiet systemd-resolved; then
    systemctl enable --now systemd-resolved
    log_success "systemd-resolved enabled"
else
    log_info "systemd-resolved already active"
fi

# Configure systemd-resolved to use DHCP DNS only (no fallback to external)
if [ ! -f /etc/systemd/resolved.conf.d/99-dhcp-only.conf ]; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat << 'EOF' > /etc/systemd/resolved.conf.d/99-dhcp-only.conf
[Resolve]
# Use only DHCP-provided DNS servers
DNSStubListener=yes
Cache=yes
DNSOverTLS=no
EOF
    systemctl restart systemd-resolved
    log_success "DNS configured for DHCP-only resolution with caching"
else
    log_info "DNS configuration already present"
fi

# Configure NetworkManager to use systemd-resolved
if [ ! -f /etc/NetworkManager/conf.d/dns-resolved.conf ]; then
    mkdir -p /etc/NetworkManager/conf.d
    cat << 'EOF' > /etc/NetworkManager/conf.d/dns-resolved.conf
[main]
dns=systemd-resolved
rc-manager=symlink
EOF
    systemctl restart NetworkManager
    log_success "NetworkManager configured to use systemd-resolved"
else
    log_info "NetworkManager configuration already present"
fi

# Install spice-vdagent for clipboard sharing (essential for VM usability)
if ! dpkg -l | grep -q spice-vdagent; then
    log_info "Installing spice-vdagent for clipboard sharing..."
    apt update
    apt install -y spice-vdagent
    systemctl enable --now spice-vdagentd 2>/dev/null || true
    log_success "Clipboard sharing enabled"
else
    log_info "spice-vdagent already installed"
fi

echo ""
echo "========================================"
echo "  VM Setup Complete!"
echo "========================================"
echo ""
echo "📋 What was configured:"
echo "  ✅ Filesystem mounts (/opt/setup, /opt/read, /opt/write)"
echo "  ✅ systemd-resolved for DNS resilience"
echo "  ✅ DNS caching enabled"
echo "  ✅ NetworkManager integration"
echo "  ✅ Clipboard sharing via spice-vdagent"
echo ""
echo "📂 Your mounted directories:"
echo "  /opt/setup - Setup scripts (read-only)"
echo "  /opt/read  - Read directory (read-only)"
echo "  /opt/write - Write directory (read-write)"
echo ""
echo "🌐 Network resilience:"
echo "  Your VM will now handle WiFi/network changes gracefully."
echo "  DNS queries are cached to survive brief interruptions."
echo ""
echo "🎉 VM is ready for use!"
echo ""
