#!/bin/bash
set -e

echo "🚀 Ubuntu 24.04 VM Manager"
echo "=========================="
echo ""

# Function to show usage
show_usage() {
    echo "Usage: $0 BASE_IMAGE_PATH TEST_IMAGE_PATH [OPTIONS]"
    echo ""
    echo "Examples:"
    echo "  # Basic usage"
    echo "  ./local-vm.sh base-ubuntu24.qcow2 test-session1.qcow2"
    echo ""
    echo "  # With mounts"
    echo "  ./local-vm.sh base-ubuntu24.qcow2 test-dev.qcow2 \\"
    echo "    --mount /home/user/project:myapp \\"
    echo "    --mount /data/shared:shared"
    echo ""
    echo "Options:"
    echo "  --mount SRC:DST   Mount host directory SRC to /opt/DST in VM"
    echo "                    DST must be a simple name (no slashes)"
    echo ""
    echo "This script creates a test VM from a base image."
    echo "Use create-base-image.sh first to create base images."
    exit 1
}

# Check minimum arguments
if [ $# -lt 2 ]; then
    show_usage
fi

BASE_IMAGE_PATH="$1"
TEST_IMAGE_PATH="$2"
shift 2

# Parse mount arguments
declare -a MOUNTS
while [ $# -gt 0 ]; do
    case "$1" in
        --mount)
            if [ -z "$2" ]; then
                echo "Error: --mount requires an argument (SRC:DST)"
                exit 1
            fi
            # Validate mount format
            if ! echo "$2" | grep -q ":"; then
                echo "Error: --mount format must be SRC:DST"
                exit 1
            fi
            IFS=':' read -r src dst <<< "$2"
            # Validate dst doesn't contain slashes
            if echo "$dst" | grep -q "/"; then
                echo "Error: Mount destination name cannot contain slashes: $dst"
                echo "DST should be a simple name like 'myapp' or 'shared'"
                exit 1
            fi
            MOUNTS+=("$2")
            shift 2
            ;;
        *)
            echo "Error: Unknown option: $1"
            show_usage
            ;;
    esac
done

# Validate image paths
if [[ ! "$BASE_IMAGE_PATH" =~ \.qcow2$ ]]; then
    echo "Error: Base image path must end with .qcow2"
    exit 1
fi

if [[ ! "$TEST_IMAGE_PATH" =~ \.qcow2$ ]]; then
    echo "Error: Test image path must end with .qcow2"
    exit 1
fi

# Extract VM name from test image path (basename without .qcow2 extension)
VM_NAME="$(basename "${TEST_IMAGE_PATH%.qcow2}")"
VM_MEMORY="4096"
VM_VCPUS="2"

# Function to normalize mount paths for comparison
normalize_mount() {
    local mount_spec="$1"
    IFS=':' read -r src dst <<< "$mount_spec"
    # Convert to absolute path and remove trailing slashes
    src=$(cd "$(dirname "$src")" 2>/dev/null && echo "$(pwd)/$(basename "$src")" || echo "$src")
    src=${src%/}  # Remove trailing slash
    echo "$src:$dst"
}

# Function to create sorted mount signature
create_mount_signature() {
    local -n mounts_ref=$1
    local signature=""
    local normalized_mounts=()

    # Normalize all mounts
    for mount in "${mounts_ref[@]}"; do
        normalized_mounts+=("$(normalize_mount "$mount")")
    done

    # Sort for consistent comparison
    IFS=$'\n' sorted_mounts=($(sort <<< "${normalized_mounts[*]}"))
    unset IFS

    # Create signature
    for mount in "${sorted_mounts[@]}"; do
        signature="${signature}${mount}\n"
    done
    echo -n "$signature"
}

# Mount configuration file
MOUNT_CONFIG_FILE="${TEST_IMAGE_PATH%.qcow2}.vm-mounts"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NETWORK_SETUP_DIR="$SCRIPT_DIR/network-setup"

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
    echo "  UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-ubuntu24.qcow2"
    exit 1
fi

log_success "Found base image: $1"

# Check if test image exists, create it if not
if [ ! -f "$TEST_IMAGE_PATH" ]; then
    log_info "Creating test image from base..."
    TARGET_DIR=$(dirname "$TEST_IMAGE_PATH")
    mkdir -p "$TARGET_DIR"
    if cp "$BASE_IMAGE_PATH" "$TEST_IMAGE_PATH"; then
        log_success "Test image created: $2"
    else
        log_error "Failed to create test image"
        exit 1
    fi
else
    log_info "Using existing test image: $2"
fi

# Check if VM already exists and compare mounts
VM_EXISTS=false
MOUNTS_CHANGED=false
RECREATE_REASON=""

if virsh list --all --name | grep -q "^${VM_NAME}$"; then
    VM_EXISTS=true
    log_info "VM '$VM_NAME' already exists"

    # Check if mounts have changed
    CURRENT_MOUNT_SIG=$(create_mount_signature MOUNTS)
    if [ -f "$MOUNT_CONFIG_FILE" ]; then
        STORED_MOUNT_SIG=$(cat "$MOUNT_CONFIG_FILE")
        if [ "$CURRENT_MOUNT_SIG" != "$STORED_MOUNT_SIG" ]; then
            MOUNTS_CHANGED=true
            RECREATE_REASON="mount configuration changed"
        fi
    else
        # No stored config but VM exists - treat as changed if we have mounts
        if [ ${#MOUNTS[@]} -gt 0 ]; then
            MOUNTS_CHANGED=true
            RECREATE_REASON="no previous mount configuration found"
        fi
    fi

    if [ "$MOUNTS_CHANGED" = true ]; then
        log_info "Mount configuration has changed ($RECREATE_REASON)"

        # Check if any mounts have been removed
        if [ -f "$MOUNT_CONFIG_FILE" ]; then
            # Extract mount destinations from stored and current signatures
            STORED_DSTS=$(echo -n "$STORED_MOUNT_SIG" | grep -o '[^:]*$' | sort 2>/dev/null || true)
            CURRENT_DSTS=$(echo -n "$CURRENT_MOUNT_SIG" | grep -o '[^:]*$' | sort 2>/dev/null || true)

            # Find removed mounts (in stored but not in current)
            REMOVED_MOUNTS=$(comm -23 <(echo "$STORED_DSTS") <(echo "$CURRENT_DSTS") 2>/dev/null || true)

            if [ -n "$REMOVED_MOUNTS" ]; then
                log_warning "Detected removed mount(s): $(echo "$REMOVED_MOUNTS" | tr '\n' ' ')"
                log_warning "You may need to manually edit /etc/fstab in the VM to remove old mount entries"
                log_warning "Use 'vi /etc/fstab' from the emergency console if needed"
            else
                # If we can't detect specific removals, use general warning for any changes
                log_warning "Mount configuration changed - check /etc/fstab for old entries if needed"
            fi
        fi

        log_info "Recreating VM to apply new mount configuration..."

        # Stop and remove existing VM
        if virsh list --name | grep -q "^${VM_NAME}$"; then
            log_info "Stopping running VM..."
            virsh destroy "$VM_NAME" 2>/dev/null || true
        fi

        log_info "Removing VM definition (preserving disk)..."
        virsh undefine "$VM_NAME" 2>/dev/null || true

        # Clear the exists flag so we recreate
        VM_EXISTS=false
    fi
fi

if [ "$VM_EXISTS" = true ]; then
    log_info "VM '$VM_NAME' exists with matching mount configuration"

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

        # Show mount status
        echo ""
        if [ "$MOUNTS_CHANGED" = false ] && [ "$VM_EXISTS" = true ]; then
            echo "📁 Mount Instructions (run if not already configured):"
        else
            echo "📁 Mount Instructions (persistent across reboots):"
        fi
        echo ""
        echo "1. Set up fstab (replaces any previous agent-virt mounts):"
        echo "sudo sed -i '/# agent-virt mounts/,\$d' /etc/fstab"
        echo "sudo tee -a /etc/fstab << 'EOF'"
        echo "# agent-virt mounts"
        echo "network-setup /opt/network-setup virtiofs defaults 0 0"
        if [ ${#MOUNTS[@]} -gt 0 ]; then
            for mount in "${MOUNTS[@]}"; do
                IFS=':' read -r src dst <<< "$mount"
                echo "$dst /opt/$dst virtiofs defaults 0 0"
            done
        fi
        echo "EOF"
        echo "sudo systemctl daemon-reload"
        echo ""
        echo "2. Create directories and mount all:"
        echo -n "sudo mkdir -p /opt/network-setup"
        if [ ${#MOUNTS[@]} -gt 0 ]; then
            for mount in "${MOUNTS[@]}"; do
                IFS=':' read -r src dst <<< "$mount"
                echo -n " /opt/$dst"
            done
        fi
        echo ""
        echo "sudo mount -a"
        echo ""
        echo "3. Run network setup:"
        echo "sudo /opt/network-setup/network-setup.sh"
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

        # Show mount status
        echo ""
        if [ "$MOUNTS_CHANGED" = false ] && [ "$VM_EXISTS" = true ]; then
            echo "📁 Mount Instructions (run if not already configured):"
        else
            echo "📁 Mount Instructions (persistent across reboots):"
        fi
        echo ""
        echo "1. Set up fstab (replaces any previous agent-virt mounts):"
        echo "sudo sed -i '/# agent-virt mounts/,\$d' /etc/fstab"
        echo "sudo tee -a /etc/fstab << 'EOF'"
        echo "# agent-virt mounts"
        echo "network-setup /opt/network-setup virtiofs defaults 0 0"
        if [ ${#MOUNTS[@]} -gt 0 ]; then
            for mount in "${MOUNTS[@]}"; do
                IFS=':' read -r src dst <<< "$mount"
                echo "$dst /opt/$dst virtiofs defaults 0 0"
            done
        fi
        echo "EOF"
        echo "sudo systemctl daemon-reload"
        echo ""
        echo "2. Create directories and mount all:"
        echo -n "sudo mkdir -p /opt/network-setup"
        if [ ${#MOUNTS[@]} -gt 0 ]; then
            for mount in "${MOUNTS[@]}"; do
                IFS=':' read -r src dst <<< "$mount"
                echo -n " /opt/$dst"
            done
        fi
        echo ""
        echo "sudo mount -a"
        echo ""
        echo "3. Run network setup:"
        echo "sudo /opt/network-setup/network-setup.sh"
        echo ""
        exit 0
    fi
fi

# If we get here, we need to create the VM
log_info "Creating new VM '$VM_NAME' from test image"

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

    # Store mount configuration
    CURRENT_MOUNT_SIG=$(create_mount_signature MOUNTS)
    echo -n "$CURRENT_MOUNT_SIG" > "$MOUNT_CONFIG_FILE"
    log_info "Mount configuration saved to $MOUNT_CONFIG_FILE"
else
    log_error "Failed to create VM"
    exit 1
fi

# Wait for VM to be fully running
log_info "Waiting for VM to be fully started..."
log_info "Checking VM state..."
VM_READY_TIMEOUT=60
VM_READY_COUNT=0

while [ $VM_READY_COUNT -lt $VM_READY_TIMEOUT ]; do
    VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
    if [ "$VM_STATE" = "running" ]; then
        # VM is running, now check if libvirt can communicate properly
        if timeout 5 virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
            log_success "VM is ready for device attachment"
            break
        fi
    fi

    if [ $((VM_READY_COUNT % 10)) -eq 0 ]; then
        log_info "VM state: $VM_STATE (waiting for ready state...)"
    fi

    sleep 1
    VM_READY_COUNT=$((VM_READY_COUNT + 1))
done

if [ $VM_READY_COUNT -ge $VM_READY_TIMEOUT ]; then
    log_warning "VM ready timeout reached, proceeding anyway..."
fi

# Always attach network-setup directory (read-only)
if [ -d "$NETWORK_SETUP_DIR" ]; then
    log_info "Attaching network-setup directory (read-only)..."

    MOUNT_XML="/tmp/mount-network-setup.xml"
    cat > "$MOUNT_XML" << EOF
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='$NETWORK_SETUP_DIR'/>
  <target dir='network-setup'/>
  <readonly/>
</filesystem>
EOF

    log_info "Executing: virsh attach-device $VM_NAME $MOUNT_XML --live --persistent"
    if virsh attach-device "$VM_NAME" "$MOUNT_XML" --live --persistent; then
        log_success "network-setup directory attached as 'network-setup' (read-only)"
    else
        log_warning "Live attach failed, trying persistent-only..."
        if virsh attach-device "$VM_NAME" "$MOUNT_XML" --persistent; then
            log_success "network-setup directory attached (available after reboot) as 'network-setup' (read-only)"
        else
            log_error "Failed to attach network-setup directory"
            cat "$MOUNT_XML"
        fi
    fi
    rm -f "$MOUNT_XML"
else
    log_warning "network-setup directory not found at $NETWORK_SETUP_DIR"
fi

# Attach user mounts if specified
if [ ${#MOUNTS[@]} -gt 0 ]; then
    log_info "Attaching ${#MOUNTS[@]} mount(s) to VM..."

    for mount in "${MOUNTS[@]}"; do
        IFS=':' read -r src dst <<< "$mount"

        # Validate host path exists
        if [ ! -e "$src" ]; then
            log_warning "Host path does not exist: $src"
            continue
        fi

        # Create temporary XML for this mount
        MOUNT_XML="/tmp/mount-${dst}.xml"
        cat > "$MOUNT_XML" << EOF
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='$src'/>
  <target dir='$dst'/>
</filesystem>
EOF

        log_info "Attaching mount: $src -> $dst (tag: $dst)"
        log_info "Executing: virsh attach-device $VM_NAME $MOUNT_XML --live --persistent"
        if virsh attach-device "$VM_NAME" "$MOUNT_XML" --live --persistent; then
            log_success "Mount attached: $dst (use: sudo mount -t virtiofs $dst /opt/$dst)"
        else
            log_warning "Live attach failed for $dst, trying persistent-only..."
            if virsh attach-device "$VM_NAME" "$MOUNT_XML" --persistent; then
                log_success "Mount added (available after reboot): $dst (use: sudo mount -t virtiofs $dst /opt/$dst)"
            else
                log_error "Failed to attach mount: $dst"
                cat "$MOUNT_XML"
            fi
        fi

        rm -f "$MOUNT_XML"
    done
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
echo "  Base Image:  $1"
echo "  Test Image:  $2"
echo "  Network:     NAT (WiFi resilient)"
if [ ${#MOUNTS[@]} -gt 0 ]; then
    echo "  Mounts:      ${#MOUNTS[@]} configured"
fi
echo ""
echo "🚀 VM is ready for testing!"
echo ""
echo "Waiting for VM to boot..."
sleep 8
echo ""
echo "1. Connect to VM:"
log_info "Launching virt-viewer to connect to VM..."
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
        log_error "Failed to launch virt-viewer"
        echo "   Try manually: virt-viewer $VM_NAME"
    fi
else
    log_warning "virt-viewer not found"
    echo "   Install with: sudo apt install virt-viewer"
    echo "   Or use: virt-manager"
fi
echo ""
echo "2. Inside the VM (login as vm/vm):"
echo ""
if [ "$MOUNTS_CHANGED" = false ] && [ "$VM_EXISTS" = true ]; then
    echo "   Copy-paste this command (if not already configured):"
else
    echo "   Copy-paste this command to set up persistent mounts:"
fi
echo ""
echo "   # Set up fstab (replaces any previous agent-virt mounts)"
echo "sudo sed -i '/# agent-virt mounts/,\$d' /etc/fstab"
echo "sudo tee -a /etc/fstab << 'EOF'"
echo "# agent-virt mounts"
echo "network-setup /opt/network-setup virtiofs defaults 0 0"
if [ ${#MOUNTS[@]} -gt 0 ]; then
    for mount in "${MOUNTS[@]}"; do
        IFS=':' read -r src dst <<< "$mount"
        echo "$dst /opt/$dst virtiofs defaults 0 0"
    done
fi
echo "EOF"
echo "sudo systemctl daemon-reload"
echo ""
echo "   # Create directories and mount all"
echo -n "   sudo mkdir -p /opt/network-setup"
if [ ${#MOUNTS[@]} -gt 0 ]; then
    for mount in "${MOUNTS[@]}"; do
        IFS=':' read -r src dst <<< "$mount"
        echo -n " /opt/$dst"
    done
fi
echo ""
echo "   sudo mount -a"
echo ""
echo "   # Run network setup"
echo "   sudo /opt/network-setup/network-setup.sh"

echo ""
echo "💡 Helpful Commands:"
echo "  Start VM:        virsh start $VM_NAME"
echo "  Stop VM:         virsh shutdown $VM_NAME"
echo "  Force stop:      virsh destroy $VM_NAME"
echo "  Delete VM:       virsh undefine $VM_NAME"
echo "  Delete test img: rm \"$TEST_IMAGE_PATH\""
echo "  List VMs:        virsh list --all"
echo ""
echo "🔄 To recreate test VM:"
echo "  virsh destroy $VM_NAME && virsh undefine $VM_NAME"
echo "  rm \"$TEST_IMAGE_PATH\""
echo "  $0 \"$BASE_IMAGE_PATH\" \"$TEST_IMAGE_PATH\" [--mount options]"
echo ""
