#!/bin/bash
set -e

echo "🚀 Create Ubuntu 24.04 Base Image for Podman Testing"
echo "===================================================="
echo ""

# Check arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 BASE_IMAGE_NAME"
    echo ""
    echo "Examples:"
    echo "  $0 base-ubuntu24-podman.qcow2"
    echo "  $0 base-ubuntu24-minimal.qcow2"
    echo ""
    echo "This script creates a base VM image that includes:"
    echo "  - Fresh Ubuntu 24.04 installation"
    echo "  - Podman and development tools setup"
    echo "  - Network resilience configuration"
    echo ""
    echo "The base image can then be used with local-vm.sh to create fast test VMs."
    exit 1
fi

BASE_IMAGE_NAME="$1"

# Validate base image name
if [[ ! "$BASE_IMAGE_NAME" =~ \.qcow2$ ]]; then
    echo "Error: Base image name must end with .qcow2"
    echo "Example: base-ubuntu24-podman.qcow2"
    exit 1
fi

# Configuration
VM_NAME="base-builder"
VM_MEMORY="4096"
VM_VCPUS="2"
VM_DISK_SIZE="20"

# Find the git repository root
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [ -z "$GIT_ROOT" ] || [ ! -d "$GIT_ROOT/.git" ]; then
    # Fallback: assume we're in podman/testing/vm/
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [[ "$SCRIPT_DIR" == */podman/testing/vm ]]; then
        GIT_ROOT="${SCRIPT_DIR%/podman/testing/vm}"
    fi
    if [ ! -d "$GIT_ROOT/.git" ]; then
        echo "Error: Not in a git repository. Please run from within the git repo."
        exit 1
    fi
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Check if base image already exists
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_IMAGE_PATH="$SCRIPT_DIR/$BASE_IMAGE_NAME"

if [ -f "$BASE_IMAGE_PATH" ]; then
    log_error "Base image already exists: $BASE_IMAGE_PATH"
    echo ""
    echo "Options:"
    echo "  1. Use a different name: $0 base-ubuntu24-v2.qcow2"
    echo "  2. Remove existing: rm \"$BASE_IMAGE_PATH\""
    echo "  3. Use existing with: ./local-vm.sh \"$BASE_IMAGE_NAME\" test.qcow2"
    exit 1
fi

# Check if builder VM already exists
if virsh list --all --name | grep -q "^${VM_NAME}$"; then
    log_warning "Builder VM '$VM_NAME' already exists. Removing it..."
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
    log_success "Old builder VM removed"
fi

# Check for Ubuntu ISO
if [ -z "$UBUNTU_ISO" ]; then
    log_error "UBUNTU_ISO environment variable not set!"
    echo ""
    echo "Please specify the path to Ubuntu 24.04 ISO:"
    echo "  UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso $0 $BASE_IMAGE_NAME"
    echo ""
    echo "Download from: https://ubuntu.com/download/desktop"
    exit 1
fi

if [ ! -f "$UBUNTU_ISO" ]; then
    log_error "ISO file not found: $UBUNTU_ISO"
    exit 1
fi

log_success "Found ISO: $UBUNTU_ISO"

# Check dependencies
log_info "Checking dependencies..."
MISSING_DEPS=()

if ! command -v virt-install; then
    MISSING_DEPS+=("virt-manager")
fi

if ! command -v virsh; then
    MISSING_DEPS+=("libvirt-clients")
fi

# Check for virtiofsd
VIRTIOFSD_FOUND=false
if command -v virtiofsd >/dev/null 2>&1; then
    VIRTIOFSD_FOUND=true
else
    for path in /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd /usr/bin/virtiofsd /usr/sbin/virtiofsd; do
        if [ -x "$path" ]; then
            VIRTIOFSD_FOUND=true
            break
        fi
    done
fi

if [ "$VIRTIOFSD_FOUND" = false ]; then
    MISSING_DEPS+=("virtiofsd")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    log_error "Missing dependencies: ${MISSING_DEPS[*]}"
    echo ""
    echo "Install with:"
    echo "  sudo apt update"
    echo "  sudo apt install -y virt-manager libvirt-daemon-system qemu-kvm virtiofsd"
    echo "  sudo usermod -a -G libvirt $USER"
    echo ""
    echo "Then log out and back in for group changes to take effect."
    exit 1
fi

# Check libvirt group membership
if ! groups | grep -q libvirt; then
    log_warning "You're not in the libvirt group"
    echo "Run: sudo usermod -a -G libvirt $USER"
    echo "Then log out and back in."
    exit 1
fi

# Check disk space (need at least 25GB free)
AVAILABLE_SPACE=$(df "$SCRIPT_DIR" --output=avail -B1 | tail -1)
REQUIRED_SPACE=$((25 * 1024 * 1024 * 1024))  # 25GB in bytes

if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
    log_error "Insufficient disk space!"
    echo "Required: 25GB"
    echo "Available: $(numfmt --to=iec-i --suffix=B $AVAILABLE_SPACE)"
    exit 1
fi

log_success "All dependencies found"
log_success "Sufficient disk space available"

# Create VM with disk in local directory
log_info "Creating base VM with ${VM_MEMORY}MB RAM, ${VM_VCPUS} CPUs, ${VM_DISK_SIZE}GB disk..."

virt-install \
    --name "$VM_NAME" \
    --ram "$VM_MEMORY" \
    --vcpus "$VM_VCPUS" \
    --disk "path=$BASE_IMAGE_PATH,size=$VM_DISK_SIZE,format=qcow2" \
    --cdrom "$UBUNTU_ISO" \
    --os-variant ubuntu24.04 \
    --network network=default \
    --graphics spice,listen=127.0.0.1 \
    --video model=qxl \
    --channel spicevmc,target_type=virtio,name=com.redhat.spice.0 \
    --console pty,target_type=serial \
    --noautoconsole \
    --memorybacking source.type=memfd,access.mode=shared

if [ $? -eq 0 ]; then
    log_success "VM '$VM_NAME' created successfully!"
else
    log_error "Failed to create VM"
    exit 1
fi



echo ""
echo "========================================"
echo "  Base Image Creation Started!"
echo "========================================"
echo ""
echo "📋 VM Configuration:"
echo "  Name:     $VM_NAME"
echo "  Memory:   ${VM_MEMORY}MB"
echo "  CPUs:     $VM_VCPUS"
echo "  Disk:     ${VM_DISK_SIZE}GB"
echo "  Base Image: $BASE_IMAGE_PATH"
echo ""
echo "🚀 Next Steps:"
echo ""
echo "1. Install Ubuntu (virt-viewer should open automatically):"

# Launch virt-viewer
log_info "Launching virt-viewer to connect to VM..."
if command -v virt-viewer; then
    if virt-viewer "$VM_NAME" &
    then
        VIEWER_PID=$!
        log_success "virt-viewer launched (PID: $VIEWER_PID)"
        sleep 2
        if kill -0 $VIEWER_PID 2>/dev/null; then
            log_success "virt-viewer is running successfully"
        else
            log_error "virt-viewer exited immediately"
            log_info "You can manually connect with: virt-viewer $VM_NAME"
        fi
    else
        log_error "Failed to launch virt-viewer"
        log_info "Try manually: virt-viewer $VM_NAME"
    fi
else
    log_warning "virt-viewer not found"
    log_info "Connect with: virt-manager"
fi

echo ""
echo "2. During Ubuntu installation:"
echo "   - Create user: username 'vm', password 'vm', computer name 'vm'"
echo "   - Enable 'Install OpenSSH server' if offered"
echo ""
echo "3. After installation and first boot:"
echo "   a. Login as user 'vm' with password 'vm'"
echo "   b. Optionally adjust display resolution using the Displays tool"
echo "   c. The VM will shutdown automatically after installation"
echo ""
echo "Note: No additional setup needed - test VMs will access setup scripts via git mount"
echo "   b. Wait for VM to stop completely"
echo ""
echo "5. Your base image will be ready at:"
echo "   $BASE_IMAGE_PATH"
echo ""
echo "6. Create test VMs from this base:"
echo "   ./local-vm.sh \"$BASE_IMAGE_NAME\" test.qcow2"
echo ""
echo "💡 Helpful Commands During Setup:"
echo "  VM Status:       virsh list --all"
echo "  Force Stop:      virsh destroy $VM_NAME"
echo "  VM Console:      virsh console $VM_NAME"
echo "  GUI Console:     virt-viewer $VM_NAME"
echo ""

# Wait for the installation process
echo "⏳ Waiting for Ubuntu installation and setup..."
echo "   This VM will be removed automatically after you shut it down."
echo "   The base image ($BASE_IMAGE_NAME) will remain for future use."
echo ""

# Monitor VM until it's shut down
echo "📊 Monitoring VM status (Ctrl+C to stop monitoring):"
while virsh list --name | grep -q "^${VM_NAME}$"; do
    echo "   VM is running... ($(date '+%H:%M:%S'))"
    sleep 30
done

log_success "VM has been shut down!"
log_info "Cleaning up builder VM definition..."

# Remove the VM definition but keep the disk
virsh undefine "$VM_NAME" 2>/dev/null || true

# Fix ownership of the base image so user can read it
log_info "Fixing ownership of base image..."
if [ -f "$BASE_IMAGE_PATH" ]; then
    # Try to fix ownership without sudo first
    if chown "$USER:$USER" "$BASE_IMAGE_PATH" 2>/dev/null; then
        log_success "Base image ownership fixed"
    else
        # Fall back to sudo if needed
        if command -v sudo >/dev/null 2>&1; then
            if sudo chown "$USER:$USER" "$BASE_IMAGE_PATH"; then
                log_success "Base image ownership fixed with sudo"
            else
                log_warning "Could not fix base image ownership"
                echo "  Run manually: sudo chown $USER:$USER \"$BASE_IMAGE_PATH\""
            fi
        else
            log_warning "Could not fix base image ownership (no sudo available)"
            echo "  Run manually: chown $USER:$USER \"$BASE_IMAGE_PATH\""
        fi
    fi
fi

echo ""
echo "🎉 Base Image Creation Complete!"
echo "================================="
echo ""
log_success "Base image created: $BASE_IMAGE_PATH"
echo ""
echo "📋 What's included in this base image:"
echo "  ✅ Fresh Ubuntu 24.04 installation"
echo "  ✅ Podman with rootless configuration"
echo "  ✅ Development tools and setup"
echo "  ✅ Network resilience configuration"
echo "  ✅ SSH server enabled"
echo "  ✅ User services configured"
echo ""
echo "🚀 Create test VMs from this base:"
echo "  ./local-vm.sh \"$BASE_IMAGE_NAME\" test-session1.qcow2"
echo "  ./local-vm.sh \"$BASE_IMAGE_NAME\" test-feature-x.qcow2"
echo ""
echo "💾 Base image size: $(du -h "$BASE_IMAGE_PATH" | cut -f1)"
echo ""
