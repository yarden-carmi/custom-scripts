#!/bin/bash
# Usage: sudo ./remove_vnc_user.sh <username> <display_number>

set -euo pipefail

extract_display_num() {
    local service_file=$1
    local display_num=""

    # Preferred source: explicit DISPLAY environment in unit file.
    display_num=$(grep -Eo 'Environment=DISPLAY=:[0-9]+' "$service_file" 2>/dev/null | sed -E 's/.*:([0-9]+)/\1/' | head -n 1 || true)

    # Fallback 1: parse display from ExecStart/ExecStartPre/ExecStop entries.
    if [[ -z "$display_num" ]]; then
        display_num=$(grep -Eo ':[0-9]+' "$service_file" 2>/dev/null | sed 's/^://' | head -n 1 || true)
    fi

    # Fallback 2: parse from Description "... on :N".
    if [[ -z "$display_num" ]]; then
        display_num=$(grep -Eo 'on :[0-9]+' "$service_file" 2>/dev/null | sed -E 's/.*:([0-9]+)/\1/' | head -n 1 || true)
    fi

    echo "$display_num"
}

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)."
    exit 1
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <username> [display_number]"
    exit 1
fi

USERNAME=$1
DISPLAY_NUM="${2:-}"

if [[ -z "$DISPLAY_NUM" ]]; then
    SERVICE_FILE="/etc/systemd/system/vncserver-$USERNAME.service"
    if [[ -f "$SERVICE_FILE" ]]; then
        DISPLAY_NUM=$(extract_display_num "$SERVICE_FILE")
    fi
fi

if [[ -z "$DISPLAY_NUM" ]]; then
    echo "Error: Unable to determine display number. Provide it explicitly or ensure service file exists."
    exit 1
fi

if ! [[ "$DISPLAY_NUM" =~ ^[0-9]+$ ]]; then
    echo "Error: display_number must be numeric."
    exit 1
fi

PORT=$((5900 + DISPLAY_NUM))
USER_HOME=""
if id "$USERNAME" >/dev/null 2>&1; then
    USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
fi

echo "--- Step 1: Stopping and disabling VNC service ---"
systemctl stop "vncserver-$USERNAME.service" 2>/dev/null
systemctl disable "vncserver-$USERNAME.service" 2>/dev/null

echo "--- Step 2: Removing systemd service file ---"
rm -f "/etc/systemd/system/vncserver-$USERNAME.service"
systemctl daemon-reload

echo "--- Step 3: Closing Firewall Port $PORT ---"
if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "$PORT/tcp" 2>/dev/null || true
fi

echo "--- Step 4: Cleaning up X11 display locks ---"
rm -f "/tmp/.X$DISPLAY_NUM-lock"
rm -f "/tmp/.X11-unix/X$DISPLAY_NUM"

echo "--- Step 5: Removing user VNC artifacts ---"
if [[ -n "$USER_HOME" && -d "$USER_HOME" ]]; then
    rm -rf "$USER_HOME/.vnc" 2>/dev/null || true
else
    rm -rf "/home/$USERNAME/.vnc" 2>/dev/null || true
fi

echo "--- Step 6: Disabling Linger ---"
loginctl disable-linger "$USERNAME" 2>/dev/null

echo "--- Step 7: Removing User and Home Directory ---"
if id "$USERNAME" &>/dev/null; then
    deluser --remove-home "$USERNAME"
else
    echo "User $USERNAME does not exist, skipping user deletion."
fi

echo "--- SUCCESS: User $USERNAME on display :$DISPLAY_NUM has been removed. ---"
