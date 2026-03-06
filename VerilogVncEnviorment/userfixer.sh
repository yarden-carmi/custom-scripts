#!/bin/bash
# Ultimate VNC Fixer v2.3 - The "No User Commands" Edition

if [[ $EUID -ne 0 ]]; then
   echo "Please run as root (sudo)." 
   exit 1
fi

# 1. Global Sandbox & Persistence Fix
sysctl -w kernel.apparmor_restrict_unprivileged_unprivileged_userns=0 2>/dev/null
echo "--- Ensuring all VNC users have persistence (Linger) ---"

for user_home in /home/*; do
    if [ -d "$user_home/.vnc" ]; then
        USERNAME=$(basename "$user_home")
        USER_ID=$(id -u "$USERNAME")
        SERVICE_FILE="/etc/systemd/system/vncserver-$USERNAME.service"

        echo "--- Fixing user: $USERNAME (UID: $USER_ID) ---"

        # 2. Kill every single process owned by this user to clear stale D-Bus/GNOME sessions
        echo "-> Force-killing stale sessions..."
        pkill -u "$USERNAME" 2>/dev/null
        loginctl enable-linger "$USERNAME"

        # 3. Clean up VNC Security & Native Config
        mkdir -p "$user_home/.vnc"
        echo "securitytypes=VncAuth" > "$user_home/.vnc/config"
        chown "$USERNAME:$USERNAME" "$user_home/.vnc/config"

        # 4. Extract Display and Rebuild Service
        if [ -f "$SERVICE_FILE" ]; then
            DISPLAY_NUM=$(grep -Eo 'DISPLAY=:[0-9]+' "$SERVICE_FILE" | cut -d':' -f2 | head -n 1)
            
            if [ -n "$DISPLAY_NUM" ]; then
                echo "-> Found Display: :$DISPLAY_NUM. Rebuilding Systemd Service..."
                systemctl stop "vncserver-$USERNAME.service" 2>/dev/null
                
                # Nuke the locks for this specific display
                rm -f "/tmp/.X$DISPLAY_NUM-lock" "/tmp/.X11-unix/X$DISPLAY_NUM"

                cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=TigerVNC-Server for $USERNAME on :$DISPLAY_NUM
After=syslog.target network.target

[Service]
Type=simple
User=$USERNAME
Group=$USERNAME
WorkingDirectory=/home/$USERNAME
Environment=XDG_RUNTIME_DIR=/run/user/$USER_ID
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_ID/bus
Environment=DISPLAY=:$DISPLAY_NUM
Environment=XDG_CURRENT_DESKTOP=Ubuntu:GNOME
Environment=GNOME_SHELL_SESSION_MODE=ubuntu
Environment=LIBGL_ALWAYS_SOFTWARE=1
Environment=GALLIUM_DRIVER=llvmpipe

ExecStartPre=-/usr/bin/vncserver -kill :$DISPLAY_NUM
ExecStartPre=-/usr/bin/rm -f /tmp/.X$DISPLAY_NUM-lock
ExecStartPre=-/usr/bin/rm -f /tmp/.X11-unix/X$DISPLAY_NUM
ExecStart=/usr/bin/vncserver -fg -localhost no -depth 24 -geometry 1920x1080 :$DISPLAY_NUM
ExecStop=/usr/bin/vncserver -kill :$DISPLAY_NUM
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            fi
        fi

        # 5. Rebuild xstartup (Forcing Software Rendering & Stable Xsession)
        echo "-> Overwriting xstartup..."
        cat <<'EOF' > "$user_home/.vnc/xstartup"
#!/bin/sh
unset SESSION_MANAGER

export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP="Ubuntu:GNOME"
export GNOME_SHELL_SESSION_MODE=ubuntu
export MOZ_ENABLE_WAYLAND=0  

(sleep 5 && gsettings set org.gnome.desktop.screensaver lock-enabled false) &
(sleep 5 && gsettings set org.gnome.desktop.session idle-delay 0) &
(sleep 5 && gsettings set org.gnome.desktop.lockdown disable-lock-screen true) &

exec /etc/X11/Xsession
EOF
        chown "$USERNAME:$USERNAME" "$user_home/.vnc/xstartup"
        chmod +x "$user_home/.vnc/xstartup"
    fi
done

echo "--- Finalizing: Reloading systemd and starting all services ---"
systemctl daemon-reload
systemctl restart "vncserver-*" 2>/dev/null

echo "--- SUCCESS: All users are force-patched and cleared. ---"
