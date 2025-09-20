# agent-virt - Ubuntu VM Manager

A standalone tool for creating and managing Ubuntu 24.04 VMs with flexible directory mounting support. Perfect for testing applications in isolated environments with access to multiple host directories.

The VM uses a multi-layered approach to handle network changes:

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

### 2. Setup Directory Structure

```bash
# Create a directory for VM images (outside any git repos)
mkdir -p ~/vms/agent-virt
```

### 3. Create Base Image

```bash
# Download Ubuntu 24.04 ISO first
# Then create a base image (one-time setup, ~20 minutes)
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh ~/vms/agent-virt/base-ubuntu24.qcow2

# During installation: create user 'vm' with password 'vm'
```

### 4. Create and Use Test VMs

```bash
# Basic VM (no mounts)
./local-vm.sh ~/vms/agent-virt/base-ubuntu24.qcow2 ~/vms/agent-virt/test-session1.qcow2

# VM with project mounts
./local-vm.sh ~/vms/agent-virt/base-ubuntu24.qcow2 ~/vms/agent-virt/test-dev.qcow2 \
  --mount /home/user/myproject:myapp \
  --mount /data/shared:shared
```

### 5. Inside the VM

After VM starts (login as vm/vm):

```bash
# Set up fstab (replaces any previous agent-virt mounts)
sudo sed -i '/# agent-virt mounts/,$d' /etc/fstab
sudo tee -a /etc/fstab << 'EOF'
# agent-virt mounts
network-setup /opt/network-setup virtiofs defaults 0 0
myapp /opt/myapp virtiofs defaults 0 0
shared /opt/shared virtiofs defaults 0 0
EOF
sudo systemctl daemon-reload

# Create directories and mount all
sudo mkdir -p /opt/network-setup /opt/myapp /opt/shared
sudo mount -a

# Run network setup
sudo /opt/network-setup/network-setup.sh
```

## Architecture & Safety

### Design Principles

- **Standalone Operation**: No git repository dependencies
- **Multiple Mounts**: Mount any number of host directories into VMs
- **Fast VM Creation**: Test VMs created in seconds from base images
- **Network Resilience**: NAT networking survives WiFi/network changes
- **Local Storage**: All VM images stored in your chosen directory

### Safety Features

- **Image Isolation**: Keep VM images outside mounted directories to prevent recursion
- **Explicit Paths**: All mount paths must be explicitly specified
- **Permission Preservation**: virtiofs maintains host file permissions
- **Non-destructive**: Test VMs are copies, base images remain pristine

### Two-Stage Workflow

1. **Base Images** (`base-*.qcow2`): Created once with full Ubuntu installation
2. **Test VMs** (`test-*.qcow2`): Fast copies from base images for testing

### VM Recreation on Mount Changes

When you run `local-vm.sh` with different `--mount` options:

- **Disk preserved**: Your VM's disk file (`.qcow2`) and all data is kept
- **VM recreated**: The VM definition is destroyed and recreated with new mounts
- **Clean state**: Running processes are lost, but installed software and files remain
- **Predictable mounts**: Ensures exactly the mounts you specify are attached

This design prioritizes reliability and simplicity over preserving temporary VM state.

## Mount System

The `--mount` flag uses `SRC:DST` format:
- `SRC`: Absolute path on the host system
- `DST`: Simple name (no slashes) - mounts to `/opt/DST` in VM

Examples:
```bash
# Initial VM with project mount
./local-vm.sh base.qcow2 test.qcow2 \
  --mount /home/user/project:myproject

# Later, change mounts (VM will be recreated)
./local-vm.sh base.qcow2 test.qcow2 \
  --mount /home/user/project:myproject \
  --mount /data/shared:shared \
  --mount /opt/configs:configs

# Access in VM at:
# /opt/myproject
# /opt/shared
# /opt/configs
```

**Note**: Changing mounts recreates the VM (preserving disk data) to ensure clean mount state.

## Network Setup

Every VM automatically has network-setup.sh available. The setup commands shown by the script include both the network setup and your custom mounts in a single copy-pastable block.

This configures the network resilience layer shown in the architecture diagram.

### Persistent Mounts

Mounts are configured to persist across VM reboots by default:
- Mount instructions use a marker system in `/etc/fstab`
- The `# agent-virt mounts` marker allows clean replacement of mount entries
- When mounts change, all entries after the marker are removed and new ones added
- Use `sudo mount -a` to mount all configured filesystems
- Mounts survive VM restarts automatically

### What if Host Paths Move?

If a host directory is moved or deleted:
- **VM boots normally** - mount failures don't prevent boot
- **Affected mount unavailable** - only that specific mount fails
- **Other mounts work fine** - unaffected mounts continue to function
- **To fix**: Update mount configuration and recreate VM with new paths

## VM Management

### Essential Commands

```bash
# Start/Stop VMs
virsh start test-vm
virsh shutdown test-vm
virsh destroy test-vm        # Force stop

# View VMs
virsh list --all
virt-viewer test-vm          # GUI console

# Clean up
virsh undefine test-vm       # Remove VM definition
rm test-vm.qcow2            # Remove disk image
```

## Tips

- **Performance**: Allocate at least 4GB RAM for good performance
- **Display**: Adjust resolution inside VM using Ubuntu's display settings
- **Clipboard**: Works automatically via spice-vdagent
- **Persistence**: Test VMs preserve state between restarts until deleted

## Troubleshooting

**VM won't start**: Check `virsh list --all` and `sudo journalctl -u libvirtd -n 50`

**Mount not working**: Ensure virtiofsd is installed and the host path exists

**Network issues**: Wait 10-15 seconds after network change, or `sudo systemctl restart NetworkManager` in VM

**Permission denied**: VM user needs appropriate permissions for mounted directories
