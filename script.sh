#!/bin/bash

set -Eeuo pipefail

# =========================================
# Proxmox - LXC CIFS Mount and Bind Automation
# =========================================
# - Goal: Maintain a single CIFS mount on the Proxmox host to the root NAS
#   share (for example "//10.0.0.x/main"), and bind only specific folders
#   under that host mount into one or more LXC containers.
# - This script is interactive, idempotent, and uses a credentials file for CIFS
#   so passwords are not stored directly in /etc/fstab.
# - It will display existing CIFS mounts from /etc/fstab and currently mounted
#   CIFS filesystems before asking what to do.
# - It allows you to skip creating the host mount if it already exists, and go
#   straight to binding a subdirectory into an LXC container.
# - It chooses the next available mpX entry in the LXC config so multiple binds
#   can be added without overwriting existing ones.
# =========================================

echo "===== Proxmox LXC CIFS Bind Mount Automation ====="

# -----------------------------------------
# Pre-flight checks
# -----------------------------------------
if [ "${EUID}" -ne 0 ]; then
    echo "- Please run this script as root"
    exit 1
fi

# - GID mapping for unprivileged containers
LXC_GID=10000
HOST_GID=110000  # mapped GID on the Proxmox host for the LXC group

# -----------------------------------------
# Helper functions
# -----------------------------------------
show_existing_cifs() {
    echo
    echo "- CIFS entries in /etc/fstab (uncommented):"
    if awk 'BEGIN{found=0} $0 !~ /^#/ && $3=="cifs" {found=1; printf "  %-30s -> %-30s  [opts: %s]\n", $1, $2, $4} END{if(!found) print "  (none)"}' /etc/fstab; then
        :
    else
        echo "  (unable to read /etc/fstab)"
    fi

    echo
    echo "- Currently mounted CIFS filesystems:"
    if mount | awk '/ type cifs / {printf "  %-30s -> %-30s\n", $1, $3} END{if(NR==0) print "  (none)"}'; then
        :
    else
        echo "  (unable to query mount state)"
    fi
}

next_mp_index() {
    local cfg="$1"
    if [ ! -f "$cfg" ]; then
        echo 0
        return
    fi
    local last
    last=$(awk -F: '/^mp[0-9]+:/ {gsub(/^mp/,"",$1); print $1}' "$cfg" | sort -n | tail -1 || true)
    if [ -z "${last:-}" ]; then
        echo 0
    else
        echo $((last + 1))
    fi
}

has_cifs_for_mountpoint() {
    local mp="$1"
    awk -v mp="$mp" 'BEGIN{found=1} $0 !~ /^#/ && $2==mp && $3=="cifs" {found=0} END{exit found}' /etc/fstab
}

ensure_dir() {
    local d="$1"
    if [ ! -d "$d" ]; then
        echo "- Creating directory: $d"
        mkdir -p "$d"
    fi
}

create_credentials_file() {
    local cred_path="$1"; local user="$2"; local pass="$3"
    echo "- Writing credentials file: $cred_path"
    umask 077
    printf "username=%s\npassword=%s\n" "$user" "$pass" > "$cred_path"
}

detect_autofs() {
    command -v automount >/dev/null 2>&1
}

ensure_autofs_installed() {
    if detect_autofs; then
        return 0
    fi
    echo "- autofs is not installed"
    read -p "Install autofs now? (y/N): " DO_AUTOINSTALL
    DO_AUTOINSTALL=${DO_AUTOINSTALL:-N}
    if [[ "$DO_AUTOINSTALL" =~ ^[Yy]$ ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y autofs || {
                echo "- Failed to install autofs"
                return 1
            }
        else
            echo "- apt-get not available - please install autofs manually"
            return 1
        fi
    else
        echo "- autofs will not be installed"
        return 1
    fi
}

setup_fstab_mount() {
    local nas_share="$1"; local host_mount="$2"; local cred_path="$3"
    local fstab_line
    fstab_line="$nas_share $host_mount cifs _netdev,x-systemd.automount,noatime,uid=100000,gid=$HOST_GID,dir_mode=0770,file_mode=0770,credentials=$cred_path,iocharset=utf8,noperm 0 0"
    echo "- Ensuring CIFS entry exists in /etc/fstab for $host_mount"
    if has_cifs_for_mountpoint "$host_mount"; then
        echo "  - CIFS entry already present for $host_mount - leaving as is"
    else
        echo "$fstab_line" >> /etc/fstab
        echo "  - Added entry to /etc/fstab"
    fi
    echo "- Mounting host path: $host_mount"
    mount "$host_mount" || echo "  - Mount attempt returned non-zero - check logs if not mounted"
}

setup_autofs_mount() {
    local nas_share="$1"; local host_mount="$2"; local cred_path="$3"; local cred_name="$4"
    ensure_autofs_installed || return 1
    # - Create autofs master include and map for a direct mount
    local master_file="/etc/auto.master.d/proxmox-lxc-cifs-${cred_name}.autofs"
    local map_file="/etc/auto.cifs-proxmox-lxc-${cred_name}.map"
    echo "- Writing autofs master file: $master_file"
    printf "/- %s --timeout=60 --ghost\n" "$map_file" > "$master_file"
    echo "- Writing autofs map file: $map_file"
    printf "%s -fstype=cifs,credentials=%s,uid=100000,gid=%s,dir_mode=0770,file_mode=0770,iocharset=utf8,noperm :%s\n" \
        "$host_mount" "$cred_path" "$HOST_GID" "$nas_share" > "$map_file"
    systemctl enable --now autofs >/dev/null 2>&1 || true
    systemctl reload autofs >/dev/null 2>&1 || true
    # - Trigger mount lazily
    ls -1 "$host_mount" >/dev/null 2>&1 || true
    echo "- Autofs configured for $host_mount"
}

export_host_mounts() {
    echo
    echo "- Exporting host CIFS mount definitions created by this script"
    echo "- Copy everything between the BEGIN and END markers"
    echo "BEGIN_EXPORT"

    # - Export fstab-based definitions
    awk '$0 !~ /^#/ && $3=="cifs" && $4 ~ /credentials=\/root\/\.cifs-credentials-/ { print $0 }' /etc/fstab | \
    while IFS= read -r line; do
        nas=$(echo "$line" | awk '{print $1}')
        mp=$(echo "$line" | awk '{print $2}')
        cred=$(echo "$line" | sed -n 's/.*credentials=\([^, ]*\).*/\1/p')
        name=$(basename "$cred" | sed 's/^\.cifs-credentials-//')
        echo "BEGIN"
        echo "method=fstab"
        echo "nas_share=$nas"
        echo "host_mount=$mp"
        echo "cred_name=$name"
        echo "END"
    done

    # - Export autofs-based definitions
    for master in /etc/auto.master.d/proxmox-lxc-cifs-*.autofs; do
        [ -f "$master" ] || continue
        map_file=$(awk 'NF>=2 {print $2; exit}' "$master")
        [ -f "$map_file" ] || continue
        while IFS= read -r mline; do
            [ -z "$mline" ] && continue
            case "$mline" in \#*) continue ;; esac
            mp=$(echo "$mline" | awk '{print $1}')
            opts=$(echo "$mline" | awk '{print $2}')
            share=$(echo "$mline" | awk '{print $3}')
            share=${share#:}
            cred=$(echo "$opts" | sed -n 's/.*credentials=\([^, ]*\).*/\1/p')
            name=$(basename "$cred" | sed 's/^\.cifs-credentials-//')
            echo "BEGIN"
            echo "method=autofs"
            echo "nas_share=$share"
            echo "host_mount=$mp"
            echo "cred_name=$name"
            echo "END"
        done < "$map_file"
    done

    echo "END_EXPORT"
}

import_host_mounts() {
    echo
    echo "- Paste exported blocks, then type END_IMPORT on a new line"
    tmp=$(mktemp)
    while IFS= read -r line; do
        [ "$line" = "END_IMPORT" ] && break
        echo "$line" >> "$tmp"
    done
    # - Parse blocks
    awk 'BEGIN{inb=0}
         /^BEGIN$/ {inb=1; method=""; nas=""; mp=""; cred=""; next}
         /^END$/ {inb=0; if(nas!="" && mp!=""){ printf "%s\t%s\t%s\t%s\n", method,nas,mp,cred }}
         {if(inb){ split($0,a,"="); k=a[1]; v=substr($0,length(k)+2); if(k=="method") method=v; else if(k=="nas_share") nas=v; else if(k=="host_mount") mp=v; else if(k=="cred_name") cred=v; }}' "$tmp" | \
    while IFS=$'\t' read -r method nas mp cred; do
        [ -z "$nas" ] && continue
        ensure_dir "$mp"
        CRED_PATH="/root/.cifs-credentials-${cred}"
        echo
        echo "- Importing $method mount: $nas -> $mp"
        read -p "NAS username for ${nas}: " NAS_USER
        read -sp "NAS password for ${nas}: " NAS_PASS; echo
        create_credentials_file "$CRED_PATH" "$NAS_USER" "$NAS_PASS"
        if [ "$method" = "autofs" ]; then
            setup_autofs_mount "$nas" "$mp" "$CRED_PATH" "$cred" || echo "- Failed to configure autofs for $mp"
        else
            setup_fstab_mount "$nas" "$mp" "$CRED_PATH"
        fi
    done
    rm -f "$tmp"
    echo "- Import completed"
}

configure_flow() {
    # -----------------------------------------
    # Show current state before prompting
    # -----------------------------------------
    show_existing_cifs

    echo
    read -p "Do you want to create or update a host CIFS mount? (y/N): " DO_HOST
    DO_HOST=${DO_HOST:-N}

    HOST_MOUNT=""
    NAS_SHARE=""

    if [[ "$DO_HOST" =~ ^[Yy]$ ]]; then
        echo
        read -p "NAS share address (e.g. //10.0.0.1/main): " NAS_SHARE
        read -p "Host mount point (e.g. /mnt/lxc_shares/TNAS01): " HOST_MOUNT
read -p "NAS username: " NAS_USER
        read -sp "NAS password: " NAS_PASS; echo

        ensure_dir "$HOST_MOUNT"

        CRED_NAME=$(basename "$HOST_MOUNT" | tr '[:upper:]' '[:lower:]')
        CRED_PATH="/root/.cifs-credentials-${CRED_NAME}"
        create_credentials_file "$CRED_PATH" "$NAS_USER" "$NAS_PASS"

        echo
        echo "- Choose host mount mechanism"
        echo "  1) systemd automount via /etc/fstab (default)"
        echo "  2) autofs (mount on access and re-mount if disconnected)"
        read -p "Select [1-2]: " METH
        case "${METH:-1}" in
            2) setup_autofs_mount "$NAS_SHARE" "$HOST_MOUNT" "$CRED_PATH" "$CRED_NAME" || {
                   echo "- Falling back to systemd automount"
                   setup_fstab_mount "$NAS_SHARE" "$HOST_MOUNT" "$CRED_PATH"
               } ;;
            *) setup_fstab_mount "$NAS_SHARE" "$HOST_MOUNT" "$CRED_PATH" ;;
        esac
    else
        echo "- Skipping host CIFS mount creation"
        echo
        read -p "Path to existing host mount to use (e.g. /mnt/lxc_shares/TNAS01): " HOST_MOUNT
    fi

    if [ -z "${HOST_MOUNT:-}" ]; then
        echo "- Host mount path is required"
        exit 1
    fi

    echo
read -p "LXC container ID: " LXC_ID
    read -p "Relative subfolder under host mount to bind (e.g. media or media/movies): " SUBFOLDER
    read -p "Mount point inside the LXC (e.g. /mnt/media): " LXC_MOUNT
    read -p "Access inside the LXC (rw/ro): " ACCESS

    BIND_SOURCE="${HOST_MOUNT%/}/${SUBFOLDER#./}"
    ensure_dir "$BIND_SOURCE"

    CFG_FILE="/etc/pve/lxc/${LXC_ID}.conf"
    if [ ! -f "$CFG_FILE" ]; then
        echo "- LXC config not found: $CFG_FILE"
        exit 1
    fi

    IDX=$(next_mp_index "$CFG_FILE")
    if [ "$ACCESS" = "ro" ]; then
        MP_LINE="mp${IDX}: $BIND_SOURCE,mp=$LXC_MOUNT,ro=1"
    else
        MP_LINE="mp${IDX}: $BIND_SOURCE,mp=$LXC_MOUNT"
    fi

    if grep -qxF "$MP_LINE" "$CFG_FILE"; then
        echo "- Bind already present in $CFG_FILE - nothing to change"
    else
        echo "$MP_LINE" >> "$CFG_FILE"
        echo "- Added bind to $CFG_FILE as mp${IDX}"
    fi

    echo "- Ensuring mount point exists inside LXC: $LXC_MOUNT"
    pct exec "$LXC_ID" -- mkdir -p "$LXC_MOUNT" >/dev/null 2>&1 || true

    echo "- Ensuring group 'lxc_shares' exists inside LXC (GID $LXC_GID)"
    pct exec "$LXC_ID" -- getent group lxc_shares >/dev/null 2>&1 || \
    pct exec "$LXC_ID" -- groupadd -g "$LXC_GID" lxc_shares >/dev/null 2>&1 || true
    echo "  - Remember to add application users to 'lxc_shares' inside the LXC (for example jellyfin, plex)"

    echo
    echo "===== Setup complete ====="
    echo "- Host CIFS mount: $HOST_MOUNT"
    echo "- Bound source on host: $BIND_SOURCE"
    echo "- LXC: $LXC_ID"
    echo "- LXC target mount: $LXC_MOUNT ($ACCESS)"
    echo "- LXC group: lxc_shares (GID $LXC_GID)"
}

main_menu() {
    echo
    echo "- Choose an action"
    echo "  1) Configure host mount and LXC bind"
    echo "  2) Export host mount definitions"
    echo "  3) Import host mount definitions"
    echo "  q) Quit"
    read -p "Select [1-3/q]: " CH
    case "${CH:-1}" in
        2) export_host_mounts ; exit 0 ;;
        3) import_host_mounts ; exit 0 ;;
        q|Q) exit 0 ;;
        *) configure_flow ;;
    esac
}

main_menu
