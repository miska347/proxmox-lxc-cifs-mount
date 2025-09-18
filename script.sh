#!/bin/bash

# =========================================
# Proxmox LXC CIFS Bind Mount Automation
# =========================================
# This script automates mounting a NAS/CIFS share to the Proxmox host
# and bind-mounting it into an unprivileged LXC container.
# It also sets up the necessary LXC group for correct permissions.
#
# The script performs the following steps:
# 1) Ask the user for NAS details, host mount points, and LXC configuration
# 2) Create the mount point on the host
# 3) Add a CIFS mount entry to /etc/fstab
# 4) Mount the share on the host
# 5) Add a bind mount to the selected LXC container
# 6) Create an LXC group for access control
# =========================================

echo "===== Proxmox LXC CIFS Bind Mount Automation ====="

# 1) Prompt for NAS information
read -p "NAS share address (e.g. //10.0.0.1/share): " NAS_SHARE
read -p "NAS username: " NAS_USER
read -sp "NAS password: " NAS_PASS
echo

# 2) Prompt for host mount point
read -p "Host mount point (e.g. /mnt/lxc_shares/nas_rwx): " HOST_MOUNT

# 3) Prompt for LXC container ID
read -p "LXC container ID: " LXC_ID

# 4) Prompt for LXC mount point
read -p "Mount point inside the LXC (e.g. /mnt/nas): " LXC_MOUNT

# 5) Prompt for access type
read -p "Do you want read-write or read-only access inside the LXC? (rw/ro): " ACCESS

# 6) Define LXC group GID and corresponding host GID
LXC_GID=10000
HOST_GID=110000  # mapped GID on the Proxmox host

# =========================================
# Display a summary of actions
# =========================================
echo
echo "========== Summary =========="
echo "NAS share: $NAS_SHARE"
echo "Host mount point: $HOST_MOUNT"
echo "LXC container ID: $LXC_ID"
echo "LXC mount point: $LXC_MOUNT"
echo "Access type: $ACCESS"
echo "LXC group GID: $LXC_GID -> Host GID: $HOST_GID"
echo "Host UID for LXC root: 100000"
echo "================================"
echo "Press Enter to continue or Ctrl+C to abort"
read

# =========================================
# 1) Create the host mount point
# =========================================
echo "-> Creating host mount point: $HOST_MOUNT"
mkdir -p "$HOST_MOUNT"

# =========================================
# 2) Add CIFS mount entry to /etc/fstab
# =========================================
echo "-> Adding CIFS mount entry to /etc/fstab"
FSTAB_LINE="$NAS_SHARE $HOST_MOUNT cifs _netdev,x-systemd.automount,noatime,uid=100000,gid=$HOST_GID,dir_mode=0770,file_mode=0770,user=$NAS_USER,pass=$NAS_PASS 0 0"
grep -qxF "$FSTAB_LINE" /etc/fstab || echo "$FSTAB_LINE" >> /etc/fstab
echo "-> /etc/fstab updated"

# =========================================
# 3) Mount the share on the host
# =========================================
echo "-> Mounting CIFS share on host: $HOST_MOUNT"
mount "$HOST_MOUNT"

# =========================================
# 4) Add bind mount to the LXC container
# =========================================
echo "-> Adding bind mount to LXC container"
if [ "$ACCESS" == "ro" ]; then
    MP_LINE="mp0: $HOST_MOUNT,mp=$LXC_MOUNT,ro=1"
else
    MP_LINE="mp0: $HOST_MOUNT,mp=$LXC_MOUNT"
fi
grep -qxF "$MP_LINE" /etc/pve/lxc/$LXC_ID.conf || echo "$MP_LINE" >> /etc/pve/lxc/$LXC_ID.conf
echo "-> LXC configuration updated"

# =========================================
# 5) Create a group inside the LXC container
# =========================================
echo "-> Creating LXC group 'lxc_shares' and instructing to add users"
pct exec $LXC_ID -- groupadd -g $LXC_GID lxc_shares 2>/dev/null
echo "-> Remember to add the necessary users to 'lxc_shares' inside the LXC (e.g. jellyfin, plex)"

# =========================================
# Completion message
# =========================================
echo
echo "===== Setup Complete! ====="
echo "Host CIFS mount: $HOST_MOUNT"
echo "LXC bind mount: $LXC_MOUNT"
echo "LXC group: lxc_shares (GID $LXC_GID)"
echo "You can now start the LXC and access the NAS share from inside."
