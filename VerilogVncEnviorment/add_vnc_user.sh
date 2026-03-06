#!/bin/bash
# Add a VNC-enabled user with a systemd service matching the orinakel profile.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo)."
  exit 1
fi

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <username> <display_number>"
  exit 1
fi

USERNAME=$1
DISPLAY_NUM=$2

if ! [[ "$DISPLAY_NUM" =~ ^[0-9]+$ ]]; then
  echo "Error: display_number must be numeric."
  exit 1
fi

PORT=$((5900 + DISPLAY_NUM))

echo "--- Step 1: User Setup ---"
id "$USERNAME" &>/dev/null || adduser --gecos "" "$USERNAME"
loginctl enable-linger "$USERNAME"

USER_ID=$(id -u "$USERNAME")
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
RUNTIME_DIR="/run/user/$USER_ID"
USER_VNC_DIR="$USER_HOME/.vnc"

echo "--- Step 2: VNC Password ---"
sudo -u "$USERNAME" vncpasswd

echo "--- Step 3: Configuring VNC profile files ---"
mkdir -p "$USER_VNC_DIR"

cat <<'EOF' > "$USER_VNC_DIR/config"
securitytypes=VncAuth
EOF

cat <<'EOF' > "$USER_VNC_DIR/xstartup"
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

export XDG_CURRENT_DESKTOP="Ubuntu:GNOME"
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_SESSION_TYPE=x11
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export DISPLAY=$DISPLAY

(sleep 4 && gsettings set org.gnome.desktop.screensaver lock-enabled false) &
(sleep 4 && gsettings set org.gnome.desktop.session idle-delay 0) &
(sleep 4 && gsettings set org.gnome.desktop.lockdown disable-lock-screen true) &

if [ -x /usr/bin/gnome-session ]; then
  exec dbus-run-session -- gnome-session --session=ubuntu --disable-acceleration-check
fi

exec /etc/X11/Xsession
EOF

chown -R "$USERNAME:$USERNAME" "$USER_VNC_DIR"
chmod 700 "$USER_VNC_DIR"
chmod 600 "$USER_VNC_DIR/config"
chmod +x "$USER_VNC_DIR/xstartup"

echo "--- Step 4: Writing systemd service ---"
SERVICE_FILE="/etc/systemd/system/vncserver-$USERNAME.service"
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=TigerVNC-Server for $USERNAME on :$DISPLAY_NUM
After=syslog.target network.target

[Service]
Type=simple
User=$USERNAME
Group=$USERNAME
WorkingDirectory=$USER_HOME
Environment=XDG_RUNTIME_DIR=$RUNTIME_DIR
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME_DIR/bus
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

echo "--- Step 5: Finalize ---"
systemctl daemon-reload
systemctl enable --now "vncserver-$USERNAME.service"

if command -v ufw >/dev/null 2>&1; then
  ufw allow "$PORT/tcp" || true
fi

echo "--- SUCCESS: User $USERNAME configured on :$DISPLAY_NUM (port $PORT) ---"
