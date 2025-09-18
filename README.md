# proxmox-lxc-cifs-mount
**AI generated** bash script to mount CIFS to LXC container in Proxmox. Based on TheHellSite's guide: https://forum.proxmox.com/threads/tutorial-unprivileged-lxcs-mount-cifs-shares.101795/

 - Goal: Maintain a single CIFS mount on the Proxmox host to the root NAS share (for example "//10.0.0.x/main"), and bind only specific folders under that host mount into one or more LXC containers.
 - Autofs is supported as an optional host mount mechanism for on-demand mounting and automatic reconnection when the NAS link drops.
 - This script is interactive, idempotent, and uses a credentials file for CIFS so passwords are not stored directly in /etc/fstab.
 - It will display existing CIFS mounts from /etc/fstab and currently mounted CIFS filesystems before asking what to do.
 - It allows you to skip creating the host mount if it already exists, and go straight to binding a subdirectory into an LXC container.
 - It chooses the next available mpX entry in the LXC config so multiple binds can be added without overwriting existing ones.
- NOT TESTED!! You can export and import host mount definitions between nodes using the script menu. Exports include base64-encoded credentials so the target node can recreate identical mounts without additional prompts.

``bash <(curl -s https://raw.githubusercontent.com/miska347/proxmox-lxc-cifs-mount/refs/heads/main/script.sh)``
