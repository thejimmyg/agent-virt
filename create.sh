#!/bin/bash
set -e

echo "🚀 Agent Virt - Create VM from Base Image"
echo "========================================="
echo ""

# Default values
DEFAULT_CPU=4
DEFAULT_RAM=6144  # 6GB in MB
AGENT_VIRT_DIR="${AGENT_VIRT_DIR:-$HOME/vms/agent-virt}"

# Function to show usage
show_usage() {
    echo "Usage: $0 [--cpu N] [--ram N] BASE_NAME READ_DIR WRITE_DIR VM_NAME"
    echo ""
    echo "Arguments:"
    echo "  BASE_NAME   Name of base image (without .qcow2)"
    echo "  READ_DIR    Host directory to mount read-only at /opt/read"
    echo "  WRITE_DIR   Host directory to mount read-write at /opt/write"
    echo "  VM_NAME     Name for the new VM (without .qcow2)"
    echo ""
    echo "Options:"
    echo "  --cpu N     Number of CPUs (default: $DEFAULT_CPU)"
    echo "  --ram N     RAM in GB (default: $((DEFAULT_RAM/1024)))"
    echo ""
    echo "Examples:"
    echo "  ./create.sh base-ubuntu24 /home/user/docs /home/user/projects dev-vm"
    echo "  ./create.sh --cpu 8 --ram 8 base-ubuntu24 /data/read /data/write test-vm"
    echo ""
    echo "Environment variables:"
    echo "  AGENT_VIRT_DIR: Directory for VM storage (default: ~/vms/agent-virt)"
    echo "    Current: $AGENT_VIRT_DIR"
    exit 1
}

# Parse command line options using getopt
TEMP=$(getopt -o h --long cpu:,ram:,help -n 'create.sh' -- "$@")
if [ $? != 0 ]; then
    echo "Invalid arguments. Use --help for usage." >&2
    exit 1
fi

eval set -- "$TEMP"

VM_VCPUS=$DEFAULT_CPU
VM_MEMORY=$DEFAULT_RAM

while true; do
    case "$1" in
        --cpu)
            VM_VCPUS="$2"
            if ! [[ "$VM_VCPUS" =~ ^[0-9]+$ ]] || [ "$VM_VCPUS" -lt 1 ] || [ "$VM_VCPUS" -gt 32 ]; then
                echo "Error: CPU count must be a number between 1 and 32"
                exit 1
            fi
            shift 2
            ;;
        --ram)
            RAM_GB="$2"
            if ! [[ "$RAM_GB" =~ ^[0-9]+$ ]] || [ "$RAM_GB" -lt 1 ] || [ "$RAM_GB" -gt 64 ]; then
                echo "Error: RAM must be a number between 1 and 64 GB"
                exit 1
            fi
            VM_MEMORY=$((RAM_GB * 1024))
            shift 2
            ;;
        -h|--help)
            show_usage
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Internal error parsing arguments" >&2
            exit 1
            ;;
    esac
done

# Check required arguments
if [ $# -ne 4 ]; then
    echo "Error: Missing required arguments"
    echo ""
    show_usage
fi

BASE_NAME="$1"
READ_DIR="$2"
WRITE_DIR="$3"
VM_NAME="$4"

# Set up directory structure
BASE_DIR="$AGENT_VIRT_DIR/base"
RUN_DIR="$AGENT_VIRT_DIR/run"
BASE_IMAGE_PATH="$BASE_DIR/${BASE_NAME}.qcow2"
VM_IMAGE_PATH="$RUN_DIR/${VM_NAME}.qcow2"
MOUNT_CONFIG_FILE="$RUN_DIR/${VM_NAME}.mount"

# Create directories
mkdir -p "$BASE_DIR" "$RUN_DIR"

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

# Validate base image exists
if [ ! -f "$BASE_IMAGE_PATH" ]; then
    log_error "Base image not found: $BASE_IMAGE_PATH"
    echo ""
    echo "Available base images:"
    if [ -d "$BASE_DIR" ] && [ "$(ls -A "$BASE_DIR"/*.qcow2 2>/dev/null)" ]; then
        for img in "$BASE_DIR"/*.qcow2; do
            basename=$(basename "$img" .qcow2)
            echo "  $basename"
        done
    else
        echo "  No base images found in $BASE_DIR"
    fi
    echo ""
    echo "Create a base image first:"
    echo "  UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh $BASE_NAME"
    exit 1
fi

# Validate directories exist
if [ ! -d "$READ_DIR" ]; then
    log_error "Read directory not found: $READ_DIR"
    exit 1
fi

if [ ! -d "$WRITE_DIR" ]; then
    log_error "Write directory not found: $WRITE_DIR"
    exit 1
fi

# Convert to absolute paths
READ_DIR=$(cd "$READ_DIR" && pwd)
WRITE_DIR=$(cd "$WRITE_DIR" && pwd)

log_success "Found base image: $BASE_IMAGE_PATH"
log_success "Read directory: $READ_DIR"
log_success "Write directory: $WRITE_DIR"

# Check if VM already exists
if virsh list --all --name | grep -q "^${VM_NAME}$"; then
    log_warning "VM '$VM_NAME' already exists"

    # Stop and remove existing VM
    if virsh list --name | grep -q "^${VM_NAME}$"; then
        log_info "Stopping running VM..."
        virsh destroy "$VM_NAME" 2>/dev/null || true
    fi

    log_info "Removing VM definition (preserving disk)..."
    virsh undefine "$VM_NAME" 2>/dev/null || true
fi

# Check if VM image exists, create it if not
if [ ! -f "$VM_IMAGE_PATH" ]; then
    log_info "Creating VM image from base..."
    if cp "$BASE_IMAGE_PATH" "$VM_IMAGE_PATH"; then
        log_success "VM image created: $VM_IMAGE_PATH"
    else
        log_error "Failed to create VM image"
        exit 1
    fi
else
    log_info "Using existing VM image: $VM_IMAGE_PATH"
fi

# Create mount configuration
log_info "Creating mount configuration..."
cat > "$MOUNT_CONFIG_FILE" << EOF
# VM Mount Configuration for $VM_NAME
READ_DIR=$READ_DIR
WRITE_DIR=$WRITE_DIR
EOF
log_success "Mount configuration saved: $MOUNT_CONFIG_FILE"

# Quick dependency check
if ! command -v virt-install >/dev/null 2>&1 || ! command -v virsh >/dev/null 2>&1; then
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

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_DIR="$SCRIPT_DIR/setup"

# Create VM
log_info "Creating VM with ${VM_MEMORY}MB RAM, ${VM_VCPUS} CPUs..."

virt-install \
    --name "$VM_NAME" \
    --ram "$VM_MEMORY" \
    --vcpus "$VM_VCPUS" \
    --disk "path=$VM_IMAGE_PATH,format=qcow2" \
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

# Wait for VM to be ready
log_info "Waiting for VM to be ready for device attachment..."
sleep 5

# Attach setup directory (read-only)
if [ -d "$SETUP_DIR" ]; then
    log_info "Attaching setup directory (read-only)..."

    MOUNT_XML="/tmp/mount-setup.xml"
    cat > "$MOUNT_XML" << EOF
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='$SETUP_DIR'/>
  <target dir='setup'/>
  <readonly/>
</filesystem>
EOF

    if virsh attach-device "$VM_NAME" "$MOUNT_XML" --live --persistent; then
        log_success "Setup directory attached as '/opt/setup' (read-only)"
    else
        log_warning "Live attach failed, trying persistent-only..."
        if virsh attach-device "$VM_NAME" "$MOUNT_XML" --persistent; then
            log_success "Setup directory attached (available after reboot)"
        else
            log_error "Failed to attach setup directory"
        fi
    fi
    rm -f "$MOUNT_XML"
else
    log_warning "Setup directory not found at $SETUP_DIR"
fi

# Attach read directory (read-only)
log_info "Attaching read directory..."
MOUNT_XML="/tmp/mount-read.xml"
cat > "$MOUNT_XML" << EOF
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='$READ_DIR'/>
  <target dir='read'/>
  <readonly/>
</filesystem>
EOF

if virsh attach-device "$VM_NAME" "$MOUNT_XML" --live --persistent; then
    log_success "Read directory attached as '/opt/read' (read-only)"
else
    log_warning "Live attach failed, trying persistent-only..."
    if virsh attach-device "$VM_NAME" "$MOUNT_XML" --persistent; then
        log_success "Read directory attached (available after reboot)"
    else
        log_error "Failed to attach read directory"
    fi
fi
rm -f "$MOUNT_XML"

# Attach write directory (read-write)
log_info "Attaching write directory..."
MOUNT_XML="/tmp/mount-write.xml"
cat > "$MOUNT_XML" << EOF
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='$WRITE_DIR'/>
  <target dir='write'/>
</filesystem>
EOF

if virsh attach-device "$VM_NAME" "$MOUNT_XML" --live --persistent; then
    log_success "Write directory attached as '/opt/write' (read-write)"
else
    log_warning "Live attach failed, trying persistent-only..."
    if virsh attach-device "$VM_NAME" "$MOUNT_XML" --persistent; then
        log_success "Write directory attached (available after reboot)"
    else
        log_error "Failed to attach write directory"
    fi
fi
rm -f "$MOUNT_XML"

echo ""
echo "========================================"
echo "  VM Creation Complete!"
echo "========================================"
echo ""
echo "📋 VM Configuration:"
echo "  Name:        $VM_NAME"
echo "  Memory:      ${VM_MEMORY}MB"
echo "  CPUs:        $VM_VCPUS"
echo "  Base Image:  $BASE_NAME"
echo "  VM Image:    $VM_IMAGE_PATH"
echo "  Read Dir:    $READ_DIR → /opt/read"
echo "  Write Dir:   $WRITE_DIR → /opt/write"
echo ""
echo "🚀 VM is ready!"
echo ""
echo "Connect to VM:"
echo "  ./run.sh $VM_NAME"
echo ""
echo "Or manually:"
echo "  virt-viewer $VM_NAME"
echo "  virsh console $VM_NAME"
echo ""
echo "💡 Helpful Commands:"
echo "  Start VM:        virsh start $VM_NAME"
echo "  Stop VM:         virsh shutdown $VM_NAME"
echo "  Force stop:      virsh destroy $VM_NAME"
echo "  Delete VM:       virsh undefine $VM_NAME"
echo "  Delete VM img:   rm \"$VM_IMAGE_PATH\""
echo ""
