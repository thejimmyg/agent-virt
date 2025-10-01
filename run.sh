#!/bin/bash
set -e

# Default values - use all available system resources
DEFAULT_CPU=$(nproc)
DEFAULT_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
DEFAULT_RAM=$((DEFAULT_RAM_KB / 1024))  # Convert to MB
AGENT_VIRT_DIR="${AGENT_VIRT_DIR:-$HOME/vms/agent-virt}"

# Function to show usage
show_usage() {
    echo "Usage: $0 [--cpu N] [--ram N] VM_NAME"
    echo ""
    echo "Arguments:"
    echo "  VM_NAME     Name of the VM to run (without .qcow2)"
    echo ""
    echo "Options:"
    echo "  --cpu N     Number of CPUs (default: $DEFAULT_CPU - all available)"
    echo "  --ram N     RAM in GB (default: $((DEFAULT_RAM/1024))GB - all available)"
    echo ""
    echo "Examples:"
    echo "  ./run dev-vm                    # Use all available resources"
    echo "  ./run --cpu 8 --ram 8 dev-vm   # Use specific resources"
    echo "  ./run test-session1             # Updates if already running"
    echo ""
    echo "Notes:"
    echo "  - Resources are dynamically updated on running VMs"
    echo "  - Safe to run multiple times (idempotent)"
    echo "  - To shut down: use shutdown within the VM"
    echo "  - CPU/RAM are shared resources (not dedicated)"
    echo ""
    echo "Environment variables:"
    echo "  AGENT_VIRT_DIR: Directory for VM storage (default: ~/vms/agent-virt)"
    echo "    Current: $AGENT_VIRT_DIR"
    exit 1
}

# Parse command line options using getopt
TEMP=$(getopt -o h --long cpu:,ram:,help -n 'run.sh' -- "$@")
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
            if ! [[ "$VM_VCPUS" =~ ^[0-9]+$ ]] || [ "$VM_VCPUS" -lt 1 ] || [ "$VM_VCPUS" -gt 128 ]; then
                echo "Error: CPU count must be a number between 1 and 128"
                exit 1
            fi
            shift 2
            ;;
        --ram)
            RAM_GB="$2"
            if ! [[ "$RAM_GB" =~ ^[0-9]+$ ]] || [ "$RAM_GB" -lt 1 ] || [ "$RAM_GB" -gt 256 ]; then
                echo "Error: RAM must be a number between 1 and 256 GB"
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
if [ $# -ne 1 ]; then
    echo "Error: Missing VM name"
    echo ""
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
log_info "Target resources: ${VM_VCPUS} CPUs, ${VM_MEMORY}MB RAM"

# Function to update VM resources
update_vm_resources() {
    local vm_name="$1"
    local vcpus="$2"
    local memory="$3"

    # Get current resources
    current_vcpus=$(virsh vcpucount "$vm_name" --current 2>/dev/null || echo "unknown")
    current_mem_kb=$(virsh dommemstat "$vm_name" 2>/dev/null | grep "actual" | awk '{print $2}' || echo "0")
    current_mem_mb=$((current_mem_kb / 1024))

    if [ "$current_mem_mb" -eq 0 ]; then
        # Fallback method to get memory
        current_mem_kb=$(virsh dominfo "$vm_name" 2>/dev/null | grep "Max memory" | awk '{print $3}')
        current_mem_mb=$((current_mem_kb / 1024))
    fi

    log_info "Current resources: ${current_vcpus} CPUs, ${current_mem_mb}MB RAM"

    # Check if update needed
    if [ "$current_vcpus" != "$vcpus" ] || [ "$current_mem_mb" -ne "$memory" ]; then
        log_info "Updating VM resources..."

        local live_updates_failed=false

        # Update vCPUs
        if [ "$current_vcpus" != "$vcpus" ]; then
            # First, ensure maximum is set high enough
            virsh setvcpus "$vm_name" "$vcpus" --config --maximum 2>/dev/null || true

            # Try live update
            if virsh setvcpus "$vm_name" "$vcpus" --live 2>/dev/null; then
                # Also update config for persistence
                virsh setvcpus "$vm_name" "$vcpus" --config 2>/dev/null || true
                log_success "CPUs updated live: $current_vcpus → $vcpus"
            else
                # Try config only for next boot
                if virsh setvcpus "$vm_name" "$vcpus" --config 2>/dev/null; then
                    log_warning "CPUs will update on next reboot: $current_vcpus → $vcpus"
                    live_updates_failed=true
                else
                    log_warning "Failed to update CPUs (VM may need to be recreated)"
                fi
            fi
        fi

        # Update memory (in KB for virsh)
        if [ "$current_mem_mb" -ne "$memory" ]; then
            memory_kb=$((memory * 1024))

            # First, ensure maximum memory is set high enough
            virsh setmaxmem "$vm_name" "$memory_kb" --config 2>/dev/null || true

            # Try live update
            if virsh setmem "$vm_name" "$memory_kb" --live 2>/dev/null; then
                log_success "Memory updated live: ${current_mem_mb}MB → ${memory}MB"
            else
                log_warning "Memory will update on next reboot: ${current_mem_mb}MB → ${memory}MB"
                live_updates_failed=true
            fi
        fi

        # Show restart suggestion if live updates failed
        if [ "$live_updates_failed" = true ]; then
            echo ""
            log_info "💡 For immediate effect, restart the VM:"
            echo "   1. Shut down from within the VM"
            echo "   2. Run: ./run.sh $vm_name"
        fi
    else
        log_success "VM already has requested resources"
    fi
}

# Function to check if virt-viewer is running for this VM
check_virt_viewer() {
    if pgrep -f "virt-viewer.*${VM_NAME}" > /dev/null 2>&1; then
        return 0  # virt-viewer is running
    else
        return 1  # virt-viewer is not running
    fi
}

# Function to launch virt-viewer if not already running
launch_virt_viewer() {
    if check_virt_viewer; then
        log_success "virt-viewer is already running for $VM_NAME"
    else
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
    fi
}

# Check if VM already exists in libvirt
if virsh list --all --name | grep -q "^${VM_NAME}$"; then
    # Check if it's running
    if virsh list --name | grep -q "^${VM_NAME}$"; then
        log_success "VM is already running"

        # Update resources dynamically
        update_vm_resources "$VM_NAME" "$VM_VCPUS" "$VM_MEMORY"

        echo ""
        echo "Connect to VM:"
        echo "  virt-viewer $VM_NAME"
        echo "  virsh console $VM_NAME"
        echo ""

        # Launch virt-viewer if not already running
        launch_virt_viewer

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
        log_info "Starting existing VM with updated resources..."

        # Update resources in config before starting
        virsh setvcpus "$VM_NAME" "$VM_VCPUS" --config --maximum 2>/dev/null || true
        virsh setvcpus "$VM_NAME" "$VM_VCPUS" --config 2>/dev/null || true
        virsh setmaxmem "$VM_NAME" "$((VM_MEMORY * 1024))" --config 2>/dev/null || true

        virsh start "$VM_NAME"
        log_success "VM started with ${VM_VCPUS} CPUs, ${VM_MEMORY}MB RAM"
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

# Launch virt-viewer if not already running
launch_virt_viewer

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
echo "  Stop VM:         Shut down from within the VM (or virsh shutdown $VM_NAME)"
echo "  Force stop:      virsh destroy $VM_NAME"
echo "  VM status:       virsh list --all"
echo "  Update resources: ./run.sh --cpu N --ram N $VM_NAME"
echo ""
echo "📝 Note: Resources (CPU/RAM) are shared with the host, not dedicated."
echo "        KVM efficiently schedules CPU usage and allows memory overcommit."
echo ""