# Agent Virt - Safe AI Agent Environment

A VM manager designed to safely run AI agents like Claude Code in isolated environments with controlled file access.

## Why Use Agent Virt?

AI agents can execute code, modify files, and make system changes. Agent Virt provides:

- **Safe isolation**: Agents run in VMs, not your host system
- **Controlled access**: Only specified directories are accessible
- **Easy setup**: VMs created in seconds with predictable mounts
- **Full resources**: VMs can use all available CPU/RAM when needed

## Quick Start

### 1. Install Dependencies
```bash
sudo apt update
sudo apt install -y virt-manager libvirt-daemon-system qemu-kvm virt-viewer
sudo usermod -a -G libvirt $USER
# Log out and back in
```

### 2. Create Base Image
```bash
# Download OS ISO, then create base (one-time, ~20 minutes)
UBUNTU_ISO=~/Downloads/ubuntu-24.04.3-desktop-amd64.iso ./create-base-image.sh base-ubuntu24
# During install: create user 'vm' with password 'vm', use single partition, 30GB recommended
```

### 3. Create Agent VM
```bash
# Create VM with controlled directory access
./create.sh base-ubuntu24 /safe/read/path /safe/write/path agent-vm

# Start VM
./run.sh agent-vm
```

### 4. Setup Inside VM
```bash
# Login as vm/vm, then run:
sudo /opt/setup/setup.sh
```

Your directories are now mounted at:
- `/opt/read` - Read-only access to safe files
- `/opt/write` - Write access for agent outputs
- `/opt/setup` - Setup scripts

## Usage Patterns

### Safe Agent Development
```bash
# Create isolated environment for Claude Code
./create.sh base-ubuntu24 /home/user/safe-projects /home/user/agent-outputs claude-vm
./run.sh claude-vm

# Inside VM: install tools, run Claude Code, develop safely
# Agent can only access /opt/read and /opt/write
```

### Resource Scaling
```bash
# Give agent more resources for complex tasks
./run.sh --cpu 16 --ram 16 claude-vm

# Scale back for lighter work
./run.sh --cpu 4 --ram 4 claude-vm
```

### Container Isolation
```bash
# Inside VM: run agent in containers for extra isolation
podman run -v /opt/read:/data:ro -v /opt/write:/output your-agent-image
# Containers automatically inherit VM resource limits
```

## Key Features

- **Instant VMs**: Create new agent environments in seconds
- **Live resource updates**: Adjust CPU/RAM without restarting
- **Predictable mounts**: Always `/opt/read`, `/opt/write`, `/opt/setup`
- **Network isolation**: VMs use NAT, protected from host network
- **Easy cleanup**: Delete VMs without affecting host
- **Optimized performance**: VirtIO drivers and disk caching for speed

## Commands

### create.sh - Create new agent VM
```bash
./create.sh [--cpu N] [--ram N] BASE_NAME READ_DIR WRITE_DIR VM_NAME
```

### run.sh - Start and manage VM
```bash
./run.sh [--cpu N] [--ram N] VM_NAME
```

### VM Management
```bash
virsh list --all                    # List VMs
virsh shutdown vm-name             # Shutdown (or use VM's shutdown)
virsh undefine vm-name             # Remove VM definition
rm ~/vms/agent-virt/run/vm-name.*  # Remove VM files
```

## Safety by Design

- **File isolation**: Agents only access specified directories
- **VM isolation**: Host system protected from agent actions
- **Resource limits**: VMs use shared resources, can't monopolize host
- **Easy rollback**: Snapshot or recreate VMs as needed
- **Container ready**: Run agents in containers within VMs for layered isolation

## Directory Structure
```
~/vms/agent-virt/
├── base/                    # Base OS images
│   └── base-ubuntu24.qcow2
└── run/                     # Agent VMs
    ├── claude-vm.qcow2
    ├── agent-vm.qcow2
    └── *.mount              # Mount configurations
```

## Troubleshooting

**VM won't start**: Check `virsh list --all` and `sudo journalctl -u libvirtd -n 50`

**Mounts not working**: Run `sudo /opt/setup/setup.sh` inside VM

**Need more resources**: Use `./run.sh --cpu N --ram N vm-name` (live update)

**Recreate for live updates**: Old VMs need recreation for dynamic resource support

**Slow disk performance**: Recreate VM for optimized VirtIO disk drivers and caching

## Migration from Older Versions

If you have existing VMs without live update support:
```bash
virsh shutdown vm-name
virsh undefine vm-name  # Keeps disk
./create.sh base /read/path /write/path vm-name  # Recreate with new features
```

The disk is preserved and reused automatically.