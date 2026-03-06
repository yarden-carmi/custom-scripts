#!/bin/bash
# Usage: sudo ./remove_vnc_user.sh <username> <display_number> 

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)." 
   exit 1
fi

USERNAME=$1
DISPLAY_NUM=$2
PORT=$((5900 + DISPLAY_NUM))

if [ -z "$USERNAME" ] || [ -z "$DISPLAY_NUM" ]; then
    echo "Usage: $0 <username> <display_number>"
    exit 1
fi

echo "--- Step 1: Stopping and disabling VNC service ---"
systemctl stop "vncserver-$USERNAME.service" 2>/dev/null
systemctl disable "vncserver-$USERNAME.service" 2>/dev/null

echo "--- Step 2: Removing systemd service file ---"
rm -f "/etc/systemd/system/vncserver-$USERNAME.service"
systemctl daemon-reload

echo "--- Step 3: Closing Firewall Port $PORT ---"
ufw delete allow "$PORT/tcp" 2>/dev/null

echo "--- Step 4: Cleaning up X11 display locks ---"
rm -f "/tmp/.X$DISPLAY_NUM-lock"
rm -f "/tmp/.X11-unix/X$DISPLAY_NUM"

echo "--- Step 5: Removing User and Home Directory ---"
deluser --remove-home "$USERNAME"

echo "--- Step 6: Disabling Linger ---"
loginctl disable-linger "$USERNAME" 2>/dev/null

echo "--- SUCCESS: User $USERNAME on display :$DISPLAY_NUM has been removed. ---"
