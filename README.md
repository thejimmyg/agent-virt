# VM Setup for Agent

## Overview

This directory contains scripts to create and manage Ubuntu 24.04 VMs for testing podman containers with GUI support and network resilience. The system uses a two-stage approach:

1. **Base Image Creation**: Create reusable base images with full Ubuntu setup
2. **Test VM Creation**: Fast creation of test VMs from base images

**Note**: All commands in this README assume you're running from the `vm/` directory.

## Safety

It is better not to leave the images in the git directory, otherwise they would
be mounted in the VM and modifiable by an agent, which defeats the purpose.

## Host Dependencies

Before creating VMs, install these packages on your host system:

```bash
# Ubuntu/Debian host:
sudo apt update
sudo apt install -y virt-manager libvirt-daemon-system qemu-kvm qemu-system-x86 virt-viewer
sudo usermod -a -G libvirt $USER

# For virtiofs filesystem sharing (required):
sudo apt install -y virtiofsd
# If virtiofsd package doesn't exist, try:
# sudo apt install -y qemu-utils

# Log out and back in for group membership to take effect
```

**Verify installation:**
```bash
# Check virtualization support
virt-host-validate

# Check libvirt is running
sudo systemctl status libvirtd

# Check virtiofsd is available
which virtiofsd || ls -la /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd

# Check virt-viewer is available
which virt-viewer
```

## Quick Start

```bash
# 1. Create a base image (once, includes Ubuntu installation + setup)
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-ubuntu24-podman.qcow2

# 2. Create test VMs from the base (fast)
./local-vm.sh base-ubuntu24-podman.qcow2 test-session1.qcow2

# 3. Inside the test VM (login as vm/vm):
mkdir ~/git
sudo mount -t virtiofs gitshare ~/git
cd ~/git/podman/testing
./local-containers.sh
```

### virt-viewer Usage Tips

When the VM GUI opens, you may see: **"Allow inhibiting shortcuts?"**

**✅ Recommended: Click "Allow"** - This lets the VM capture keyboard shortcuts:
- `Ctrl+Alt+Del` → VM login/task manager
- `Alt+Tab` → Switch between VM applications
- `Windows key` → VM start menu
- `Ctrl+C/V` → Copy/paste within VM

**🔓 How to release control back to host:**
- **Click outside** the virt-viewer window
- **Press `Ctrl+Alt`** (magic key combo)
- **Close virt-viewer**: `Alt+F4` or click X
- **Reconnect**: `virt-viewer simpler-test`

**If you choose "Don't Allow":** VM works fine, but some shortcuts may go to your host instead of the VM.

**💡 Display Resolution Tip:** Use the "Displays" tool inside the VM to adjust screen resolution to match your setup for better visibility.

## Two-Stage VM Workflow

### Stage 1: Base Image Creation

Use `create-base-image.sh` to create a reusable base image:

```bash
# Create base image with Ubuntu installation + full setup
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-ubuntu24-podman.qcow2
```

This script:
- Creates a VM from Ubuntu ISO
- Launches virt-viewer for manual Ubuntu installation
- During installation: create user 'vm' with password 'vm', computer name 'vm'
- Automatically runs setup-vm.sh after installation
- Creates a base image ready for testing

**Do this once** for each configuration you want (minimal, full podman setup, etc.)

### Stage 2: Test VM Creation

Use `local-vm.sh` to create fast test VMs from base images:

```bash
# Create test VM from base image (fast - just copies disk)
./local-vm.sh base-ubuntu24-podman.qcow2 test-session1.qcow2

# Create another test VM for different testing
./local-vm.sh base-ubuntu24-podman.qcow2 test-feature-x.qcow2

# Reuse existing test VM
./local-vm.sh base-ubuntu24-podman.qcow2 test-session1.qcow2
```

### Benefits

- **Fast testing**: Test VMs create in seconds vs. minutes
- **Multiple configurations**: Maintain different base images
- **Parallel testing**: Run multiple test VMs simultaneously
- **Clean state**: Each test starts from known good base
- **Explicit naming**: Full control over disk names and VM names

### Disk Management

All disk images are stored locally in the `vm/` directory:

- Base images: `base-*.qcow2` (created once, reused many times)
- Test images: `test-*.qcow2` (fast copies, disposable)
- VM names: Derived from test image name (minus .qcow2)

## Architecture

### Network Resilience Design

The VM uses a multi-layered approach to handle network changes:

```
┌─────────────────────────────────────────┐
│            Host System                   │
│                                         │
│  WiFi Changes ←→ NetworkManager         │
│       ↓                                 │
│  libvirt NAT Network (virbr0)          │
│       ↓                                 │
├─────────────────────────────────────────┤
│            VM Guest                     │
│                                         │
│  virtio NIC (DHCP from libvirt)        │
│       ↓                                 │
│  systemd-resolved (DNS caching)         │
│       ↓                                 │
│  NetworkManager (resilient config)      │
│       ↓                                 │
│  Applications (podman containers)       │
└─────────────────────────────────────────┘
```

#### How Network Resilience Works

1. **NAT Network Isolation**: The VM uses libvirt's default NAT network which shields the VM from direct WiFi changes. When the host switches networks, the VM maintains its connection through the NAT bridge.

2. **systemd-resolved**: Provides DNS caching and resilience:
   - Caches DNS queries to survive brief network interruptions
   - Uses DHCP-provided DNS servers (typically your router)
   - No hardcoded external DNS servers for privacy

3. **NetworkManager Integration**: Configured to work with systemd-resolved for automatic recovery after network disruptions.

### Filesystem Sharing (virtiofs)

The VM uses virtiofs (virtio filesystem) to share directories between host and guest:

```
Host git repository → (virtiofs) → VM ~/git (read-write)
```

#### Why virtiofs?
- Simple and reliable
- Works while VM is running
- No additional daemons required
- Good enough performance for code viewing
- Easy to add more mounts using the same pattern

## Features

### Included
- ✅ **Network resilience** - Handles WiFi/network changes gracefully
- ✅ **Clipboard sharing** - Copy/paste between host and VM via spice-vdagent
- ✅ **Directory sharing** - Mount host git repo via virtiofs with hot-plug
- ✅ **GUI support** - Full desktop with virt-viewer/virt-manager
- ✅ **Idempotent scripts** - Run multiple times safely
- ✅ **Minimal setup** - No pre-installed development tools

### Network Resilience Mechanisms

1. **DNS Resilience**:
   ```bash
   # Configured in /etc/systemd/resolved.conf.d/99-dhcp-only.conf
   [Resolve]
   DNSStubListener=yes    # Local DNS stub resolver
   Cache=yes              # Cache DNS queries
   ```

2. **NetworkManager Configuration**:
   ```bash
   # Configured in /etc/NetworkManager/conf.d/dns-resolved.conf
   [main]
   dns=systemd-resolved   # Use systemd-resolved for DNS
   rc-manager=symlink     # Manage /etc/resolv.conf as symlink
   ```

3. **DHCP Configuration**:
   - Uses DHCP from libvirt NAT network
   - Accepts DNS servers from DHCP
   - No fallback to external DNS servers

## Usage

### Creating Base Images

```bash
# Create base image for podman testing
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-ubuntu24-podman.qcow2

# Create minimal base image
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-ubuntu24-minimal.qcow2

# The script will:
# 1. Create VM with new disk
# 2. Launch virt-viewer for Ubuntu installation
# 3. During install: create user 'vm', password 'vm', computer name 'vm'
# 4. Wait for you to install Ubuntu and run setup
# 5. Clean up temporary VM, leaving base image
```

### Creating Test VMs

```bash
# Create test VM from base image
./local-vm.sh base-ubuntu24-podman.qcow2 test-session1.qcow2

# Start existing test VM
./local-vm.sh base-ubuntu24-podman.qcow2 test-session1.qcow2

# Or use virsh directly
virsh start test-session1
virt-viewer test-session1  # For GUI
```

### Managing Multiple Test VMs

```bash
# Create different test environments
./local-vm.sh base-ubuntu24-podman.qcow2 test-feature-a.qcow2
./local-vm.sh base-ubuntu24-podman.qcow2 test-feature-b.qcow2
./local-vm.sh base-ubuntu24-minimal.qcow2 test-minimal.qcow2

# List all VMs
virsh list --all

# Clean up test VM
virsh destroy test-feature-a && virsh undefine test-feature-a
rm test-feature-a.qcow2
```

### Mounting Host Directory

After VM creation, the host git repository is available via virtiofs:

```bash
# Inside any VM - mount git repository
mkdir ~/git
sudo mount -t virtiofs gitshare ~/git

# Make permanent (edit /etc/fstab)
gitshare /home/vm/git virtiofs defaults,noauto,user 0 0
```

### Clipboard Sharing

Clipboard sharing works automatically after installing spice-vdagent:

```bash
# Inside VM (already in setup-vm.sh)
sudo apt install spice-vdagent
sudo systemctl enable --now spice-vdagentd
```

Then copy/paste works between host and VM!

### Adding More virtiofs Mounts

To share additional directories, create an XML file:

```xml
<!-- mount-documents.xml -->
<filesystem type='mount' accessmode='mapped'>
  <driver type='path' wrpolicy='immediate'/>
  <source dir='/home/user/Documents'/>
  <target dir='documents'/>
</filesystem>
```

Then attach it:

```bash
virsh attach-device simpler-test mount-documents.xml --persistent

# Inside VM
sudo mount -t 9p documents /mnt/documents -o trans=virtio,version=9p2000.L
```

## Troubleshooting

### Network Issues

**VM has no internet after WiFi change:**
1. Wait 10-15 seconds for NetworkManager to reconnect
2. If still broken: `sudo systemctl restart NetworkManager`
3. Check DNS: `resolvectl status`

**DNS not working:**
```bash
# Check systemd-resolved status
systemctl status systemd-resolved
resolvectl status

# Restart if needed
sudo systemctl restart systemd-resolved
```

### virtiofs Mount Issues

**Permission denied when mounting:**
- Check that virtiofsd daemon is running on host
- Ensure VM has shared memory enabled

**Mount not working:**
```bash
# Check if virtiofs module is loaded
lsmod | grep virtiofs

# Check if filesystem is attached
virsh dumpxml simpler-test | grep filesystem

# Check virtiofsd process on host
ps aux | grep virtiofsd
```

### Clipboard Not Working

```bash
# Inside VM, check spice-vdagent
systemctl status spice-vdagentd

# Restart if needed
sudo systemctl restart spice-vdagentd
```

### VM Won't Start

```bash
# Check VM status
virsh list --all

# Check for errors
virsh domstate simpler-test --reason

# View logs
sudo journalctl -u libvirtd -n 50
```

## VM Management Commands

```bash
# Start VM (VM name = test image name without .qcow2)
virsh start test-session1

# Graceful shutdown
virsh shutdown test-session1

# Force stop
virsh destroy test-session1

# Delete VM (keeps disk image)
virsh undefine test-session1

# Delete VM and disk image
virsh destroy test-session1 && virsh undefine test-session1
rm test-session1.qcow2

# Take snapshot
virsh snapshot-create-as test-session1 --name "before-testing"

# Restore snapshot
virsh snapshot-revert test-session1 "before-testing"

# List snapshots
virsh snapshot-list test-session1

# List all base images
ls -la *.qcow2 | grep "^.*base-"

# List all test images
ls -la *.qcow2 | grep -v "^.*base-"
```

## Safety Notes

1. **Local Disk Storage**: All VM images stored in `vm/` directory (not system directories)
2. **No Root Operations on Host**: All privileged operations are inside the VM
3. **Explicit File Control**: You control all disk image names and locations
4. **Confirmation Prompts**: Scripts ask before destructive operations
5. **Disk Space Checks**: Verifies adequate space before creation
6. **Isolated VMs**: Each test VM uses separate disk image

## Performance Tips

1. **For better GUI performance**:
   - Use virt-viewer instead of VNC
   - Allocate at least 4GB RAM to VM
   - Use QXL video with SPICE

2. **For better virtiofs performance**:
   - virtiofs already provides near-native performance
   - No additional tuning needed

3. **For network performance**:
   - virtio network driver is already optimal
   - NAT adds minimal overhead

## Why This Architecture?

**Why KVM/libvirt instead of VirtualBox?**
- Better Linux integration
- Native performance with KVM
- No kernel module issues
- Better systemd support

**Why NAT instead of Bridged networking?**
- Survives WiFi network changes
- No MAC address issues with WiFi
- Works on all networks (corporate, home, coffee shop)
- More secure (VM is isolated)

**Why virtiofs instead of SSHFS/NFS?**
- No network configuration required
- Works immediately after VM creation
- Hot-pluggable filesystem sharing
- Near-native performance
- Simple to add more mounts

**Why two-stage workflow?**
- Fast test VM creation (seconds vs. minutes)
- Reusable base configurations
- Multiple parallel test environments
- Explicit disk image management
- Clean testing state each time

**Why systemd-resolved?**
- Modern DNS resolver with caching
- Integrates well with NetworkManager
- Handles network changes gracefully
- Standard in Ubuntu 24.04

## Example Workflows

### Daily Development

```bash
# One-time setup (create user vm/vm during installation)
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-dev.qcow2

# Daily testing (fast) - login as vm/vm
./local-vm.sh base-dev.qcow2 today.qcow2
# Test inside VM, then clean up
virsh destroy today && virsh undefine today && rm today.qcow2
```

### Feature Development

```bash
# Create base for feature work
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-feature-x.qcow2

# Create persistent test environment
./local-vm.sh base-feature-x.qcow2 feature-x-work.qcow2
# Work persists across reboots until you delete the test image
```

### Multiple Test Configurations

```bash
# Create different base configurations
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-minimal.qcow2
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-full.qcow2

# Test against both configurations
./local-vm.sh base-minimal.qcow2 test-minimal.qcow2
./local-vm.sh base-full.qcow2 test-full.qcow2
```
