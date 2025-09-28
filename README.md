# Agent Virt - VM Manager

A standalone tool for creating and managing VMs with fixed directory mounting. Perfect for testing applications in isolated environments with predictable access to read and write directories.

The system uses a simplified, robust approach that eliminates manual mount configuration:

```
┌─────────────────────────────────────────┐
│            Host System                  │
│                                         │
│  WiFi Changes ←→ NetworkManager         │
│       ↓                                 │
│  libvirt NAT Network (virbr0)           │
│       ↓                                 │
├─────────────────────────────────────────┤
│            VM Guest                     │
│                                         │
│  virtio NIC (DHCP from libvirt)         │
│       ↓                                 │
│  systemd-resolved (DNS caching)         │
│       ↓                                 │
│  NetworkManager (resilient config)      │
│       ↓                                 │
│  Applications (e.g. podman containers)  │
└─────────────────────────────────────────┘
```

## Quick Start

### 1. Install Dependencies

```bash
sudo apt update
sudo apt install -y virt-manager libvirt-daemon-system qemu-kvm virtiofsd virt-viewer
sudo usermod -a -G libvirt $USER
# Log out and back in for group changes to take effect
```

### 2. Create Base Image

```bash
# Download your OS ISO first (e.g., Ubuntu 24.04)
# Then create a base image (one-time setup, ~20 minutes)
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-ubuntu24

# During installation: create user 'vm' with password 'vm'
```

### 3. Create and Use VMs

```bash
# Create a new VM
./create.sh base-ubuntu24 /home/user/read-data /home/user/write-data my-vm

# Run the VM
./run.sh my-vm
```

### 4. Inside the VM

After VM starts (login as vm/vm), run the setup script:

```bash
sudo /opt/setup/setup.sh
```

This automatically:
- Configures persistent mounts at `/opt/read`, `/opt/write`, `/opt/setup`
- Sets up network resilience for WiFi changes
- Enables clipboard sharing

## Architecture & Design

### Design Principles

- **Simplified Interface**: Fixed mount points eliminate configuration complexity
- **Predictable Mounts**: Always `/opt/read` (read-only) and `/opt/write` (read-write)
- **Fast VM Creation**: VMs created in seconds from base images
- **Network Resilience**: NAT networking survives WiFi/network changes
- **Organized Storage**: Separate base and runtime VM storage

### Directory Structure

```
$AGENT_VIRT_DIR/          # Default: ~/vms/agent-virt
├── base/                 # Base images
│   └── base-ubuntu24.qcow2
└── run/                  # Runtime VMs
    ├── my-vm.qcow2
    └── my-vm.mount       # Mount configuration
```

### Environment Variables

- `AGENT_VIRT_DIR`: VM storage directory (default: `~/vms/agent-virt`)

### Two-Stage Workflow

1. **Base Images**: Created once with full OS installation (`create-base-image.sh`)
2. **VM Creation**: Fast copies from base images with specific mounts (`create.sh`)
3. **VM Usage**: Simple execution with automatic mount setup (`run`)

## Commands

### create-base-image.sh

Creates a new base image from an OS ISO.

```bash
# Basic usage
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-ubuntu24

# Creates: $AGENT_VIRT_DIR/base/base-ubuntu24.qcow2
```

### create.sh

Creates a new VM from a base image with specific read/write directories.

```bash
# Basic usage (4 CPUs, 6GB RAM)
./create.sh base-ubuntu24 /path/to/read /path/to/write vm-name

# Custom resources
./create.sh --cpu 8 --ram 12 base-ubuntu24 /path/to/read /path/to/write vm-name

# Creates:
#   $AGENT_VIRT_DIR/run/vm-name.qcow2
#   $AGENT_VIRT_DIR/run/vm-name.mount
```

Arguments:
- `BASE_NAME`: Name of base image (without .qcow2)
- `READ_DIR`: Host directory mounted read-only at `/opt/read`
- `WRITE_DIR`: Host directory mounted read-write at `/opt/write`
- `VM_NAME`: Name for new VM (without .qcow2)

Options:
- `--cpu N`: Number of CPUs (default: 4)
- `--ram N`: RAM in GB (default: 6)

### run

Starts and connects to an existing VM.

```bash
./run.sh vm-name
```

Automatically:
- Starts the VM if stopped
- Launches virt-viewer for GUI access
- Shows setup instructions

## Fixed Mount Points

Every VM has three mount points:

- `/opt/setup` - Setup scripts (read-only)
- `/opt/read` - Your read directory (read-only)
- `/opt/write` - Your write directory (read-write)

No manual mount configuration needed - the `setup.sh` script handles everything.

## VM Management

### Essential Commands

```bash
# VM lifecycle
./run.sh vm-name              # Start and connect to VM
virsh shutdown vm-name     # Graceful shutdown
virsh destroy vm-name      # Force stop

# Status and cleanup
virsh list --all           # List all VMs
virt-viewer vm-name        # GUI console
virsh undefine vm-name     # Remove VM definition
rm $AGENT_VIRT_DIR/run/vm-name.qcow2  # Remove disk image
```

### Examples

```bash
# Create base image
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-ubuntu24

# Development VM
./create.sh base-ubuntu24 /home/user/docs /home/user/projects dev-vm
./run.sh dev-vm

# Testing VM with more resources
./create.sh --cpu 8 --ram 12 base-ubuntu24 /data/test-inputs /data/test-outputs test-vm
./run.sh test-vm

# Inside any VM (after login as vm/vm):
sudo /opt/setup/setup.sh
```

## Safety Features

- **Image Isolation**: Base images are read-only, VMs are copies
- **Explicit Paths**: All mount paths must be explicitly specified
- **Permission Preservation**: virtiofs maintains host file permissions
- **Non-destructive**: VM disk images persist independently

## Troubleshooting

**VM won't start**: Check `virsh list --all` and `sudo journalctl -u libvirtd -n 50`

**Mount not working**: Ensure host directories exist and run `sudo /opt/setup/setup.sh` in VM

**Network issues**: Wait 10-15 seconds after network change, or `sudo systemctl restart NetworkManager` in VM

**Permission denied**: Ensure VM user has appropriate permissions for mounted directories

## Migration from Old System

If you have VMs created with the old `local-vm.sh` system:

1. Stop the old VM: `virsh destroy vm-name`
2. Remove the VM definition: `virsh undefine vm-name`
3. Recreate with new system: `./create.sh base-name /read/path /write/path vm-name`

The new system is much simpler and eliminates the brittle mount configuration process.
