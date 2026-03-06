#!/bin/bash
# Fully Corrected 2026 Ubuntu VNC Multi-User Script

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

echo "--- Step 1: User Setup ---"
id "$USERNAME" &>/dev/null || adduser --gecos "" "$USERNAME"
loginctl enable-linger "$USERNAME"
USER_ID=$(id -u "$USERNAME")
RUNTIME_DIR="/run/user/$USER_ID"

echo "--- Step 2: VNC Password ---"
sudo -u "$USERNAME" vncpasswd

echo "--- Step 3: Configuring xstartup (Foreground Mode) ---"
USER_VNC_DIR="/home/$USERNAME/.vnc"
mkdir -p "$USER_VNC_DIR"

cat <<'EOF' > "$USER_VNC_DIR/xstartup"
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

export XDG_CURRENT_DESKTOP="Ubuntu:GNOME"
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_SESSION_TYPE=x11
export LIBGL_ALWAYS_SOFTWARE=1
export DISPLAY=$DISPLAY

# Delay the anti-lock commands so they fire after D-Bus initializes
(sleep 4 && gsettings set org.gnome.desktop.screensaver lock-enabled false) &
(sleep 4 && gsettings set org.gnome.desktop.session idle-delay 0) &
(sleep 4 && gsettings set org.gnome.desktop.lockdown disable-lock-screen true) &

if [ -x /usr/bin/gnome-session ]; then
  exec dbus-run-session -- gnome-session --session=ubuntu --disable-acceleration-check
fi
EOF

chown -R "$USERNAME:$USERNAME" "$USER_VNC_DIR"
chmod +x "$USER_VNC_DIR/xstartup"

echo "--- Step 4: Systemd Service (Simple Type) ---"
SERVICE_FILE="/etc/systemd/system/vncserver-$USERNAME.service"
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=TigerVNC-Server for $USERNAME on :$DISPLAY_NUM
After=syslog.target network.target

[Service]
Type=simple
User=$USERNAME
Group=$USERNAME
WorkingDirectory=/home/$USERNAME
Environment=XDG_RUNTIME_DIR=$RUNTIME_DIR
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME_DIR/bus
Environment=DISPLAY=:$DISPLAY_NUM
Environment=XDG_CURRENT_DESKTOP=Ubuntu:GNOME
Environment=GNOME_SHELL_SESSION_MODE=ubuntu
Environment=LIBGL_ALWAYS_SOFTWARE=1

ExecStartPre=-/usr/bin/vncserver -kill :$DISPLAY_NUM
ExecStartPre=-/usr/bin/rm -f /tmp/.X$DISPLAY_NUM-lock
ExecStartPre=-/usr/bin/rm -f /tmp/.X11-unix/X$DISPLAY_NUM
# Added -SecurityTypes VncAuth to fix Viewer connection drops
ExecStart=/usr/bin/vncserver -fg -localhost no -depth 24 -geometry 1920x1080 :$DISPLAY_NUM -SecurityTypes VncAuth
ExecStop=/usr/bin/vncserver -kill :$DISPLAY_NUM
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "--- Step 5: Finalize ---"
systemctl daemon-reload
systemctl enable --now "vncserver-$USERNAME.service"
ufw allow "$PORT/tcp"
echo "--- SUCCESS: Connect to port $PORT ---"
