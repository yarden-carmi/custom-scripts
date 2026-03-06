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

ensure_vnc_runtime_deps() {
  local pkgs=(dbus-x11 libsecret-tools gnome-keyring)
  local missing=()

  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done

  if (( ${#missing[@]} > 0 )); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${missing[@]}"
  fi
}

write_xstartup() {
  local user_vnc_dir=$1

  cat <<'EOF' > "$user_vnc_dir/xstartup"
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

export XDG_CURRENT_DESKTOP="Ubuntu:GNOME"
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_SESSION_TYPE=x11
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export DISPLAY=$DISPLAY

# Ensure one per-session D-Bus bus and unlocked Secret Service.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-launch >/dev/null 2>&1; then
  eval "$(dbus-launch --sh-syntax)"
fi

if command -v gnome-keyring-daemon >/dev/null 2>&1; then
  eval "$(echo '\n' | gnome-keyring-daemon --unlock 2>/dev/null)" || true
  eval "$(gnome-keyring-daemon --start --components=secrets,pkcs11,ssh,gpg 2>/dev/null)" || true
  export SSH_AUTH_SOCK
fi

(sleep 4 && gsettings set org.gnome.desktop.screensaver lock-enabled false) &
(sleep 4 && gsettings set org.gnome.desktop.session idle-delay 0) &
(sleep 4 && gsettings set org.gnome.desktop.lockdown disable-lock-screen true) &

if [ -x /usr/bin/gnome-session ]; then
  exec gnome-session --session=ubuntu --disable-acceleration-check
fi

exec /etc/X11/Xsession
EOF
}

rebuild_service() {
  local username=$1
  local user_home=$2
  local runtime_dir=$3
  local display_num=$4
  local service_file="/etc/systemd/system/vncserver-$username.service"

  cat <<EOF > "$service_file"
[Unit]
Description=TigerVNC-Server for $username on :$display_num
After=syslog.target network.target

[Service]
Type=simple
User=$username
Group=$username
WorkingDirectory=$user_home
Environment=XDG_RUNTIME_DIR=$runtime_dir
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime_dir/bus
Environment=DISPLAY=:$display_num
Environment=XDG_CURRENT_DESKTOP=Ubuntu:GNOME
Environment=GNOME_SHELL_SESSION_MODE=ubuntu
Environment=LIBGL_ALWAYS_SOFTWARE=1
Environment=GALLIUM_DRIVER=llvmpipe

ExecStartPre=-/usr/bin/vncserver -kill :$display_num
ExecStartPre=-/usr/bin/rm -f /tmp/.X$display_num-lock
ExecStartPre=-/usr/bin/rm -f /tmp/.X11-unix/X$display_num
ExecStart=/usr/bin/vncserver -fg -localhost no -depth 24 -geometry 1920x1080 :$display_num
ExecStop=/usr/bin/vncserver -kill :$display_num
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

echo "--- Step 1: User Setup ---"
ensure_vnc_runtime_deps
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

write_xstartup "$USER_VNC_DIR"

chown -R "$USERNAME:$USERNAME" "$USER_VNC_DIR"
chmod 700 "$USER_VNC_DIR"
chmod 600 "$USER_VNC_DIR/config"
chmod +x "$USER_VNC_DIR/xstartup"

echo "--- Step 4: Writing systemd service ---"
rebuild_service "$USERNAME" "$USER_HOME" "$RUNTIME_DIR" "$DISPLAY_NUM"

echo "--- Step 5: Finalize ---"
systemctl daemon-reload
systemctl enable --now "vncserver-$USERNAME.service"

if command -v ufw >/dev/null 2>&1; then
  ufw allow "$PORT/tcp" || true
fi

echo "--- SUCCESS: User $USERNAME configured on :$DISPLAY_NUM (port $PORT) ---"
