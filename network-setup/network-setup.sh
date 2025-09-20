#!/bin/bash
set -e

echo "⚙️  Setting up Network Resilience for Ubuntu VM"
echo "=============================================="

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

log_info "Configuring network resilience for WiFi/network changes..."

# Enable and configure systemd-resolved for DNS resilience
if ! systemctl is-active --quiet systemd-resolved; then
    sudo systemctl enable --now systemd-resolved
    log_success "systemd-resolved enabled"
else
    log_info "systemd-resolved already active"
fi

# Configure systemd-resolved to use DHCP DNS only (no fallback to external)
if [ ! -f /etc/systemd/resolved.conf.d/99-dhcp-only.conf ]; then
    sudo mkdir -p /etc/systemd/resolved.conf.d
    cat << 'EOF' | sudo tee /etc/systemd/resolved.conf.d/99-dhcp-only.conf > /dev/null
[Resolve]
# Use only DHCP-provided DNS servers
DNSStubListener=yes
Cache=yes
DNSOverTLS=no
EOF
    sudo systemctl restart systemd-resolved
    log_success "DNS configured for DHCP-only resolution with caching"
else
    log_info "DNS configuration already present"
fi

# Configure NetworkManager to use systemd-resolved
if [ ! -f /etc/NetworkManager/conf.d/dns-resolved.conf ]; then
    cat << 'EOF' | sudo tee /etc/NetworkManager/conf.d/dns-resolved.conf > /dev/null
[main]
dns=systemd-resolved
rc-manager=symlink
EOF
    sudo systemctl restart NetworkManager
    log_success "NetworkManager configured to use systemd-resolved"
else
    log_info "NetworkManager configuration already present"
fi

# Install spice-vdagent for clipboard sharing (essential for VM usability)
if ! dpkg -l | grep -q spice-vdagent; then
    log_info "Installing spice-vdagent for clipboard sharing..."
    sudo apt update
    sudo apt install -y spice-vdagent
    sudo systemctl enable --now spice-vdagentd 2>/dev/null || true
    log_success "Clipboard sharing enabled"
else
    log_info "spice-vdagent already installed"
fi

echo ""
echo "========================================"
echo "  Network Setup Complete!"
echo "========================================"
echo ""
echo "📋 What was configured:"
echo "  ✅ systemd-resolved for DNS resilience"
echo "  ✅ DNS caching enabled"
echo "  ✅ NetworkManager integration"
echo "  ✅ Clipboard sharing via spice-vdagent"
echo ""
echo "🌐 Network resilience:"
echo "  Your VM will now handle WiFi/network changes gracefully."
echo "  DNS queries are cached to survive brief interruptions."
echo ""
