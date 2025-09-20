#!/bin/bash
set -e

echo "🚀 Ubuntu 24.04 VM for Podman Testing"
echo "====================================="
echo ""

# Check arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 BASE_IMAGE_NAME TEST_IMAGE_NAME"
    echo ""
    echo "Examples:"
    echo "  $0 base-ubuntu24-podman.qcow2 test-session1.qcow2"
    echo "  $0 base-ubuntu24-podman.qcow2 test-feature-x.qcow2"
    echo ""
    echo "This script creates a test VM from a base image."
    echo "Use create-base-image.sh first to create base images."
    exit 1
fi

BASE_IMAGE_NAME="$1"
TEST_IMAGE_NAME="$2"

# Validate image names
if [[ ! "$BASE_IMAGE_NAME" =~ \.qcow2$ ]]; then
    echo "Error: Base image name must end with .qcow2"
    exit 1
fi

if [[ ! "$TEST_IMAGE_NAME" =~ \.qcow2$ ]]; then
    echo "Error: Test image name must end with .qcow2"
    exit 1
fi

# Extract VM name from test image (remove .qcow2 extension)
VM_NAME="${TEST_IMAGE_NAME%.qcow2}"
VM_MEMORY="4096"
VM_VCPUS="2"

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

# Set up image paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_IMAGE_PATH="$SCRIPT_DIR/$BASE_IMAGE_NAME"
TEST_IMAGE_PATH="$SCRIPT_DIR/$TEST_IMAGE_NAME"

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

# Check if base image exists
if [ ! -f "$BASE_IMAGE_PATH" ]; then
    log_error "Base image not found: $BASE_IMAGE_PATH"
    echo ""
    echo "Create a base image first:"
    echo "  ./create-base-image.sh \"$BASE_IMAGE_NAME\""
    exit 1
fi

log_success "Found base image: $BASE_IMAGE_PATH"

# Check if test image exists, create it if not
if [ ! -f "$TEST_IMAGE_PATH" ]; then
    log_info "Creating test image from base..."
    if cp "$BASE_IMAGE_PATH" "$TEST_IMAGE_PATH"; then
        log_success "Test image created: $TEST_IMAGE_PATH"
    else
        log_error "Failed to create test image"
        exit 1
    fi
else
    log_info "Using existing test image: $TEST_IMAGE_PATH"
fi

# Check if VM already exists
if virsh list --all --name | grep -q "^${VM_NAME}$"; then
    log_info "VM '$VM_NAME' already exists"

    # Check if it's running
    if virsh list --name | grep -q "^${VM_NAME}$"; then
        log_success "VM is already running"
        echo ""
        echo "Connect to VM:"
        echo "  GUI:     virt-viewer $VM_NAME"
        echo "  Console: virsh console $VM_NAME"
        echo ""

        # Launch virt-viewer for already running VM
        log_info "Launching virt-viewer to connect to running VM..."
        if command -v virt-viewer; then
            if virt-viewer "$VM_NAME" &
            then
                VIEWER_PID=$!
                log_success "virt-viewer launched (PID: $VIEWER_PID)"
            else
                log_warning "Failed to launch virt-viewer automatically"
                echo "   Try manually: virt-viewer $VM_NAME"
            fi
        else
            log_warning "virt-viewer not found"
            echo "   Install with: sudo apt install virt-viewer"
        fi
        echo ""
        exit 0
    else
        log_info "Starting existing VM..."
        virsh start "$VM_NAME"
        log_success "VM started"

        echo ""
        echo "Waiting for VM to boot..."
        sleep 5

        echo ""
        echo "Connect to VM:"
        echo "  GUI:     virt-viewer $VM_NAME"
        echo "  Console: virsh console $VM_NAME"
        echo ""

        # Launch virt-viewer for restarted VM
        log_info "Launching virt-viewer to connect to VM..."
        if command -v virt-viewer; then
            if virt-viewer "$VM_NAME" &
            then
                VIEWER_PID=$!
                log_success "virt-viewer launched (PID: $VIEWER_PID)"
            else
                log_warning "Failed to launch virt-viewer automatically"
                echo "   Try manually: virt-viewer $VM_NAME"
            fi
        else
            log_warning "virt-viewer not found"
            echo "   Install with: sudo apt install virt-viewer"
        fi

        echo ""
        echo "Mount git repository inside VM:"
        echo "  mkdir ~/git"
        echo "  sudo mount -t virtiofs gitshare ~/git"
        echo ""
        exit 0
    fi
fi

# If we get here, we need to create the VM
log_info "Creating new VM '$VM_NAME' from test image"

# Quick dependency check
if ! command -v virt-install || ! command -v virsh; then
    log_error "Missing dependencies. Please install:"
    echo "  sudo apt install -y virt-manager libvirt-daemon-system qemu-kvm"
    echo "  sudo usermod -a -G libvirt $USER"
    exit 1
fi

if ! groups | grep -q libvirt; then
    log_error "You're not in the libvirt group"
    echo "Run: sudo usermod -a -G libvirt $USER"
    echo "Then log out and back in."
    exit 1
fi

# Create VM using existing test image
log_info "Creating VM with ${VM_MEMORY}MB RAM, ${VM_VCPUS} CPUs..."

virt-install \
    --name "$VM_NAME" \
    --ram "$VM_MEMORY" \
    --vcpus "$VM_VCPUS" \
    --disk "path=$TEST_IMAGE_PATH,format=qcow2" \
    --os-variant ubuntu24.04 \
    --network network=default \
    --graphics spice,listen=127.0.0.1 \
    --video model=qxl \
    --channel spicevmc,target_type=virtio,name=com.redhat.spice.0 \
    --console pty,target_type=serial \
    --noautoconsole \
    --memorybacking source.type=memfd,access.mode=shared \
    --boot hd

if [ $? -eq 0 ]; then
    log_success "VM '$VM_NAME' created successfully!"
else
    log_error "Failed to create VM"
    exit 1
fi

# Create virtiofs filesystem mount XML
log_info "Preparing virtiofs filesystem mount for $GIT_ROOT..."

cat > /tmp/mount-git.xml << EOF
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='$GIT_ROOT'/>
  <target dir='gitshare'/>
</filesystem>
EOF

# Hot-attach virtiofs filesystem to running VM
log_info "Hot-attaching virtiofs filesystem to running VM..."
# Wait for VM to be fully running
log_info "Waiting for VM to be fully started..."
sleep 5

# Hot-attach filesystem to running VM (this is the key advantage of virtiofs!)
log_info "Executing: virsh attach-device $VM_NAME /tmp/mount-git.xml --live --persistent"
if virsh attach-device "$VM_NAME" /tmp/mount-git.xml --live --persistent; then
    log_success "virtiofs filesystem hot-attached to running VM!"
    rm /tmp/mount-git.xml
else
    log_warning "Hot-attach failed, trying persistent-only attach..."
    log_info "Executing: virsh attach-device $VM_NAME /tmp/mount-git.xml --persistent"
    if virsh attach-device "$VM_NAME" /tmp/mount-git.xml --persistent; then
        log_success "virtiofs filesystem added (will be available after next reboot)"
        rm /tmp/mount-git.xml
    else
        log_error "Failed to attach virtiofs filesystem"
        log_info "You can manually add it later with: virsh attach-device $VM_NAME vm/mount-git.xml --live --persistent"
        rm /tmp/mount-git.xml
    fi
fi

echo ""
echo "========================================"
echo "  Test VM Creation Complete!"
echo "========================================"
echo ""
echo "📋 VM Configuration:"
echo "  Name:        $VM_NAME"
echo "  Memory:      ${VM_MEMORY}MB"
echo "  CPUs:        $VM_VCPUS"
echo "  Base Image:  $BASE_IMAGE_NAME"
echo "  Test Image:  $TEST_IMAGE_NAME"
echo "  Network:     NAT (WiFi resilient)"
echo ""
echo "🚀 VM is ready for testing!"
echo ""
echo "Waiting for VM to boot..."
sleep 8
echo ""
echo "1. Connect to VM:"
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
            log_warning "virt-viewer exited immediately"
            echo "   Try manually: virt-viewer $VM_NAME"
        fi
    else
        log_error "Failed to launch virt-viewer"
        echo "   Try manually: virt-viewer $VM_NAME"
    fi
else
    log_warning "virt-viewer not found"
    echo "   Install with: sudo apt install virt-viewer"
    echo "   Or use: virt-manager"
fi
echo ""
echo "2. Inside the VM:"
echo "   a. Create git directory and mount the host git repository:"
echo "      mkdir ~/git"
echo "      sudo mount -t virtiofs gitshare ~/git"
echo "   b. Run container tests:"
echo "      cd ~/git/podman/testing"
echo "      ./local-containers.sh"
echo ""
echo "💡 Helpful Commands:"
echo "  Start VM:        virsh start $VM_NAME"
echo "  Stop VM:         virsh shutdown $VM_NAME"
echo "  Force stop:      virsh destroy $VM_NAME"
echo "  Delete VM:       virsh undefine $VM_NAME"
echo "  Delete test img: rm \"$TEST_IMAGE_PATH\""
echo "  List VMs:        virsh list --all"
echo "  GUI console:     virt-viewer $VM_NAME"
echo "  Text console:    virsh console $VM_NAME (Ctrl+] to exit)"
echo ""
echo "📁 Host Git Repository:"
echo "  Available as 'gitshare' mount inside VM"
echo "  Mount: sudo mount -t virtiofs gitshare ~/git"
echo ""
echo "🔄 To recreate test VM:"
echo "  virsh destroy $VM_NAME && virsh undefine $VM_NAME"
echo "  rm \"$TEST_IMAGE_PATH\""
echo "  $0 \"$BASE_IMAGE_NAME\" \"$TEST_IMAGE_NAME\""
echo ""
