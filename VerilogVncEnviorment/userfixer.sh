#!/bin/bash
# VNC fixer to align existing user services with the known-good orinakel profile.
# Usage: sudo ./userfixer.sh [username]

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)."
    exit 1
fi

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

TARGET_USER="${1:-}"
if [[ -n "$TARGET_USER" ]] && ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "Error: user '$TARGET_USER' does not exist."
    exit 1
fi

echo "--- Ensuring all VNC users match orinakel profile ---"
ensure_vnc_runtime_deps

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

rebuild_service() {
    local username=$1
    local user_id=$2
    local user_home=$3
    local display_num=$4
    local runtime_dir="/run/user/$user_id"
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

for service_file in /etc/systemd/system/vncserver-*.service; do
    [[ -e "$service_file" ]] || continue

    service_name=$(basename "$service_file")
    username=${service_name#vncserver-}
    username=${username%.service}

    if [[ -n "$TARGET_USER" && "$username" != "$TARGET_USER" ]]; then
        continue
    fi

    id "$username" >/dev/null 2>&1 || continue

    user_id=$(id -u "$username")
    user_home=$(getent passwd "$username" | cut -d: -f6)
    display_num=$(extract_display_num "$service_file")

    if [[ -z "$display_num" ]]; then
        echo "Skipping $username: display number not found"
        continue
    fi

    echo "-> Fixing $username on :$display_num"

    loginctl enable-linger "$username"

    mkdir -p "$user_home/.vnc"
    printf 'securitytypes=VncAuth\n' > "$user_home/.vnc/config"
    cat <<'EOF' > "$user_home/.vnc/xstartup"
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

    chown -R "$username:$username" "$user_home/.vnc"
    chmod 700 "$user_home/.vnc"
    chmod 600 "$user_home/.vnc/config"
    chmod +x "$user_home/.vnc/xstartup"

    systemctl stop "vncserver-$username.service" 2>/dev/null || true
    rm -f "/tmp/.X$display_num-lock" "/tmp/.X11-unix/X$display_num"
    rebuild_service "$username" "$user_id" "$user_home" "$display_num"
done

echo "--- Finalizing: Reloading systemd and restarting services ---"
systemctl daemon-reload

for service_file in /etc/systemd/system/vncserver-*.service; do
    [[ -e "$service_file" ]] || continue
    service_name=$(basename "$service_file")
    username=${service_name#vncserver-}
    username=${username%.service}

    if [[ -n "$TARGET_USER" && "$username" != "$TARGET_USER" ]]; then
        continue
    fi

    systemctl enable "vncserver-$username.service" >/dev/null 2>&1 || true
    systemctl restart "vncserver-$username.service" >/dev/null 2>&1 || true
done

echo "--- SUCCESS: All VNC users patched to orinakel profile. ---"
