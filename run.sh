#!/bin/bash
set -e

# Default values
AGENT_VIRT_DIR="${AGENT_VIRT_DIR:-$HOME/vms/agent-virt}"

# Function to show usage
show_usage() {
    echo "Usage: $0 VM_NAME"
    echo ""
    echo "Arguments:"
    echo "  VM_NAME     Name of the VM to run (without .qcow2)"
    echo ""
    echo "Examples:"
    echo "  ./run dev-vm"
    echo "  ./run test-session1"
    echo ""
    echo "Environment variables:"
    echo "  AGENT_VIRT_DIR: Directory for VM storage (default: ~/vms/agent-virt)"
    echo "    Current: $AGENT_VIRT_DIR"
    exit 1
}

# Check arguments
if [ $# -ne 1 ]; then
    show_usage
fi

VM_NAME="$1"

# Set up directory structure
RUN_DIR="$AGENT_VIRT_DIR/run"
VM_IMAGE_PATH="$RUN_DIR/${VM_NAME}.qcow2"
MOUNT_CONFIG_FILE="$RUN_DIR/${VM_NAME}.mount"

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

echo "🚀 Running VM: $VM_NAME"
echo "========================"
echo ""

# Check if VM files exist
if [ ! -f "$VM_IMAGE_PATH" ]; then
    log_error "VM image not found: $VM_IMAGE_PATH"
    echo ""
    echo "Available VMs:"
    if [ -d "$RUN_DIR" ] && [ "$(ls -A "$RUN_DIR"/*.qcow2 2>/dev/null)" ]; then
        for img in "$RUN_DIR"/*.qcow2; do
            basename=$(basename "$img" .qcow2)
            echo "  $basename"
        done
    else
        echo "  No VMs found in $RUN_DIR"
    fi
    echo ""
    echo "Create a VM first:"
    echo "  ./create.sh base-name /path/to/read /path/to/write $VM_NAME"
    exit 1
fi

if [ ! -f "$MOUNT_CONFIG_FILE" ]; then
    log_error "Mount configuration not found: $MOUNT_CONFIG_FILE"
    echo ""
    echo "This VM may have been created with an older version of the tools."
    echo "Recreate the VM with:"
    echo "  ./create.sh base-name /path/to/read /path/to/write $VM_NAME"
    exit 1
fi

# Load mount configuration
source "$MOUNT_CONFIG_FILE"

log_success "Found VM: $VM_IMAGE_PATH"
log_info "Read directory: $READ_DIR"
log_info "Write directory: $WRITE_DIR"

# Check if VM already exists in libvirt
if virsh list --all --name | grep -q "^${VM_NAME}$"; then
    # Check if it's running
    if virsh list --name | grep -q "^${VM_NAME}$"; then
        log_success "VM is already running"
        echo ""
        echo "Connect to VM:"
        echo "  virt-viewer $VM_NAME"
        echo "  virsh console $VM_NAME"
        echo ""

        # Launch virt-viewer
        log_info "Launching virt-viewer..."
        if command -v virt-viewer >/dev/null 2>&1; then
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

        # Show setup instructions
        echo ""
        echo "📁 Inside the VM (login as vm/vm):"
        echo ""
        echo "If mounts are already configured, directories are at:"
        echo "   /opt/read  (read-only:  $READ_DIR)"
        echo "   /opt/write (read-write: $WRITE_DIR)"
        echo "   /opt/setup (read-only:  setup scripts)"
        echo ""
        echo "If /opt is empty, run the bootstrap:"
        echo "   sudo mkdir -p /opt/setup /opt/read /opt/write"
        echo "   sudo mount -t virtiofs setup /opt/setup"
        echo "   sudo /opt/setup/setup.sh"
        echo ""
        exit 0
    else
        log_info "Starting existing VM..."
        virsh start "$VM_NAME"
        log_success "VM started"
    fi
else
    log_error "VM '$VM_NAME' not found in libvirt"
    echo ""
    echo "The VM image exists but libvirt doesn't know about it."
    echo "This can happen if the VM was created with an older version."
    echo ""
    echo "Recreate the VM with:"
    echo "  ./create.sh base-name /path/to/read /path/to/write $VM_NAME"
    exit 1
fi

echo ""
echo "Waiting for VM to boot..."
sleep 5

echo ""
echo "Connect to VM:"
echo "  virt-viewer $VM_NAME"
echo "  virsh console $VM_NAME"
echo ""

# Launch virt-viewer
log_info "Launching virt-viewer..."
if command -v virt-viewer >/dev/null 2>&1; then
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
        log_warning "Failed to launch virt-viewer automatically"
        echo "   Try manually: virt-viewer $VM_NAME"
    fi
else
    log_warning "virt-viewer not found"
    echo "   Install with: sudo apt install virt-viewer"
fi

echo ""
echo "📁 Inside the VM (login as vm/vm), run these commands:"
echo ""
echo "   # First-time mount bootstrap (only needed once):"
echo "   sudo mkdir -p /opt/setup /opt/read /opt/write"
echo "   sudo mount -t virtiofs setup /opt/setup"
echo "   "
echo "   # Then run the setup script:"
echo "   sudo /opt/setup/setup.sh"
echo ""
echo "📂 After setup, your directories will be at:"
echo "   /opt/read  (read-only:  $READ_DIR)"
echo "   /opt/write (read-write: $WRITE_DIR)"
echo "   /opt/setup (read-only:  setup scripts)"
echo ""
echo "💡 Helpful Commands:"
echo "  Stop VM:         virsh shutdown $VM_NAME"
echo "  Force stop:      virsh destroy $VM_NAME"
echo "  VM status:       virsh list --all"
echo ""