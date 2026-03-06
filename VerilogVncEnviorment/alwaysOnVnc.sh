#!/bin/bash
# Enforce persistence and an orinakel-matching VNC service profile for all VNC users.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)."
    exit 1
fi

echo "--- Enforcing VNC persistence and service profile ---"

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

RESTART_UNITS=()

for service_file in /etc/systemd/system/vncserver-*.service; do
    [[ -e "$service_file" ]] || continue

    service_name=$(basename "$service_file")
    username=${service_name#vncserver-}
    username=${username%.service}

    id "$username" >/dev/null 2>&1 || continue

    user_id=$(id -u "$username")
    user_home=$(getent passwd "$username" | cut -d: -f6)

    [[ -n "$user_home" && -d "$user_home" ]] || continue

    display_num=$(grep -Eo 'Environment=DISPLAY=:[0-9]+' "$service_file" | sed -E 's/.*:([0-9]+)/\1/' | head -n 1)
    if [[ -z "$display_num" ]]; then
        echo "Skipping $username: unable to determine display number from $service_file"
        continue
    fi

    echo "Updating $username on :$display_num"
    loginctl enable-linger "$username"

    mkdir -p "$user_home/.vnc"
    printf 'securitytypes=VncAuth\n' > "$user_home/.vnc/config"
    chown -R "$username:$username" "$user_home/.vnc"
    chmod 700 "$user_home/.vnc"
    chmod 600 "$user_home/.vnc/config"

    rebuild_service "$username" "$user_id" "$user_home" "$display_num"
    systemctl enable "vncserver-$username.service" >/dev/null 2>&1 || true
    RESTART_UNITS+=("vncserver-$username.service")
done

systemctl daemon-reload

for unit in "${RESTART_UNITS[@]}"; do
    systemctl restart "$unit" >/dev/null 2>&1 || true
done

echo "--- SUCCESS: Linger enabled and services matched to orinakel profile ---"
