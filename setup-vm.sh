#!/bin/bash
set -e

echo "⚙️  Setting up VM for Git Gateway and cmd/serve Testing"
echo "======================================================"

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

# Check if we're in a VM (optional check)
if [ -f /.dockerenv ]; then
    log_warning "Detected container environment - this script is designed for VMs"
fi

log_info "Starting VM setup for Ubuntu 24.04..."

# Check if already set up to make script idempotent
if [ -f ~/.vm-setup-complete ]; then
    log_warning "Setup already completed. To re-run, delete ~/.vm-setup-complete"
    exit 0
fi

# Update system packages
log_info "Updating system packages..."
sudo apt update && sudo apt upgrade -y
log_success "System packages updated"

# Configure network resilience
log_info "Configuring network resilience..."

# Enable and configure systemd-resolved for DNS resilience
if ! systemctl is-active --quiet systemd-resolved; then
    sudo systemctl enable --now systemd-resolved
    log_success "systemd-resolved enabled"
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
    log_success "DNS configured for DHCP-only resolution"
fi

# Configure NetworkManager to use systemd-resolved
if [ ! -f /etc/NetworkManager/conf.d/dns-resolved.conf ]; then
    cat << 'EOF' | sudo tee /etc/NetworkManager/conf.d/dns-resolved.conf > /dev/null
[main]
dns=systemd-resolved
rc-manager=symlink
EOF
    sudo systemctl restart NetworkManager
    log_success "NetworkManager configured for network resilience"
fi

# Install essential tools if not already installed
log_info "Installing essential tools..."
sudo apt update
sudo apt install -y git curl
log_success "Essential tools installed"

# Install podman if not already installed
log_info "Checking for podman..."
if ! command -v podman; then
    log_info "Installing podman..."
    sudo apt update
    sudo apt install -y podman
    log_success "Podman installed"
else
    log_info "Podman already installed: $(podman --version)"
fi

# Install spice-vdagent for clipboard sharing (optional)
if ! dpkg -l | grep -q spice-vdagent; then
    log_info "Installing spice-vdagent for clipboard sharing..."
    sudo apt install -y spice-vdagent
    log_success "Clipboard sharing enabled"
else
    log_info "spice-vdagent already installed"
fi

# Configure podman for rootless operation
log_info "Configuring podman for rootless containers..."

# Set up subuid/subgid if not already configured
if ! grep -q "^${USER}:" /etc/subuid; then
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
    log_success "Subuid/subgid configured for $USER"
fi

# Podman will use its default registry configuration
log_info "Using default podman registry configuration"

# Set up containers.conf for better systemd support
mkdir -p ~/.config/containers
cat << 'EOF' > ~/.config/containers/containers.conf
[containers]
# Enable systemd support in containers
init_path = "/usr/libexec/podman/catatonit"

[engine]
# Improve networking for systemd containers
network_cmd_options = ["enable_ipv6=false"]

[network]
# Use CNI for networking
network_backend = "netavark"
EOF
log_success "Podman containers.conf created"

# Enable podman user socket for systemd integration
systemctl --user enable --now podman.socket || log_warning "Podman socket already enabled or not available"

# Enable user services to run without login (linger)
sudo loginctl enable-linger $USER
log_success "User linger enabled for systemd user services"

# Create systemd user directory if needed
log_info "Setting up user directories..."
mkdir -p ~/.config/systemd/user
log_success "User directories created"


log_success "VM setup completed"


# Enable spice-vdagent for clipboard sharing
if systemctl list-unit-files | grep -q spice-vdagent; then
    sudo systemctl enable --now spice-vdagentd 2>/dev/null || true
    log_success "Clipboard sharing enabled"
fi

# Mark setup as complete
touch ~/.vm-setup-complete
log_success "Setup completed"