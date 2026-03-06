#!/bin/bash
# Enforces background persistence for all VNC users

if [[ $EUID -ne 0 ]]; then
   echo "Please run as root (sudo)." 
   exit 1
fi

echo "--- Enabling persistent background sessions (Lingering) ---"

for user_home in /home/*; do
    if [ -d "$user_home/.vnc" ]; then
        USERNAME=$(basename "$user_home")
        USER_ID=$(id -u "$USERNAME")
        echo "Updating: $USERNAME (UID: $USER_ID)"

        # Enable Linger to allow VNC without physical login
        loginctl enable-linger "$USERNAME"

        # Check and update the Systemd Service if it exists
        SERVICE_FILE="/etc/systemd/system/vncserver-$USERNAME.service"
        if [ -f "$SERVICE_FILE" ]; then
            # Check if DBUS_SESSION_BUS_ADDRESS is missing and inject it if necessary
            if ! grep -q "DBUS_SESSION_BUS_ADDRESS" "$SERVICE_FILE"; then
                sed -i "/\[Service\]/a Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_ID/bus" "$SERVICE_FILE"
                sed -i "/\[Service\]/a Environment=XDG_RUNTIME_DIR=/run/user/$USER_ID" "$SERVICE_FILE" 2>/dev/null
            fi
        fi
    fi
done

systemctl daemon-reload
systemctl restart systemd-logind

echo "--- SUCCESS: Linger enabled and service files verified ---"
