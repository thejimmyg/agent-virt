# ⚠️ VM Accessible Directory

**WARNING**: The contents of this directory are mounted read-only into VMs for network configuration setup.

## Contents

- `network-setup.sh` - Essential network resilience configuration script
- This README file

## Security Notes

- This directory is mounted **read-only** into VMs
- VMs cannot modify these files
- Contains only essential network configuration scripts
- No sensitive data should be placed here

## Usage in VM

After mounting this directory in a VM:

```bash
sudo mkdir -p /opt/network-setup
sudo mount -t virtiofs network-setup /opt/network-setup
sudo /opt/network-setup/network-setup.sh
```

This configures the network resilience layer for handling WiFi/network changes gracefully.