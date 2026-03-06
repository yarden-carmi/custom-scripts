#!/bin/bash
# Show VNC status for all users:
# - whether they are connected now
# - when the current/last VNC service session started
# - when the last VNC service session ended

set -euo pipefail

get_display_from_unit_file() {
    local unit_file=$1
    grep -E '^Environment=DISPLAY=:[0-9]+' "$unit_file" 2>/dev/null | sed -E 's/.*:([0-9]+)/\1/' | head -n 1 || true
}

connected_count_for_port() {
    local port=$1

    if command -v ss >/dev/null 2>&1; then
        ss -Htn state established "( sport = :$port )" 2>/dev/null | wc -l
        return
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -tn 2>/dev/null | awk -v p=":$port" '$4 ~ p && $6 == "ESTABLISHED" {c++} END {print c+0}'
        return
    fi

    echo 0
}

fmt_ts() {
    local ts=${1:-}
    if [[ -z "$ts" || "$ts" == "n/a" ]]; then
        echo "-"
    else
        echo "$ts"
    fi
}

compact_ts() {
    local ts=${1:-}
    if [[ -z "$ts" || "$ts" == "-" ]]; then
        echo "-"
        return
    fi
    # Keep only "YYYY-MM-DD HH:MM:SS" for narrow output.
    echo "$ts" | awk '{print $2" "$3}'
}

printf '%-14s %-5s %-4s %-5s %-33s %-19s %-19s\n' \
    "USER" "UID" "DSP" "PORT" "STATUS" "START" "END"
printf '%s\n' "-----------------------------------------------------------------------------------------------------"

getent passwd | awk -F: '$3>=1000 && $1!="nobody" && $7 !~ /(nologin|false)$/ {print $1":"$3}' | while IFS=: read -r user uid; do
    unit="vncserver-$user.service"
    unit_file="/etc/systemd/system/$unit"

    display="-"
    port="-"
    connected="no"
    status="no-unit"
    active_state="-"
    started="-"
    ended="-"

    if systemctl cat "$unit" >/dev/null 2>&1 || [[ -f "$unit_file" ]]; then
        if [[ -f "$unit_file" ]]; then
            display=$(get_display_from_unit_file "$unit_file")
        else
            display=$(systemctl cat "$unit" 2>/dev/null | grep -E '^Environment=DISPLAY=:[0-9]+' | sed -E 's/.*:([0-9]+)/\1/' | head -n 1 || true)
        fi

        if [[ -n "${display:-}" ]]; then
            port=$((5900 + display))
            conn_count=$(connected_count_for_port "$port")
            if [[ "$conn_count" -gt 0 ]]; then
                connected="yes($conn_count)"
            fi
        else
            display="-"
            port="-"
        fi

        active_state=$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || echo unknown)

        health="ok"
        reasons=""

        if [[ -f "$unit_file" ]]; then
            if ! grep -qE '^Environment=DISPLAY=:[0-9]+' "$unit_file"; then
                health="invalid"
                reasons="${reasons}missing-display-env,"
            fi
            if ! grep -qE '^ExecStart=/usr/bin/vncserver ' "$unit_file"; then
                health="invalid"
                reasons="${reasons}missing-execstart,"
            fi
            if grep -qE 'Exec(Start|Stop|StartPre)=.*-fg -fg' "$unit_file"; then
                health="invalid"
                reasons="${reasons}duplicated-fg-flags,"
            fi
        else
            health="invalid"
            reasons="${reasons}unit-file-missing,"
        fi

        if [[ "$health" != "ok" ]]; then
            status="invalid"
        elif [[ "$connected" == "no" ]]; then
            status="no"
        else
            status="yes"
        fi

        started=$(fmt_ts "$(systemctl show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null || true)")
        if [[ "$active_state" == "active" ]]; then
            ended="-"
        else
            ended=$(fmt_ts "$(systemctl show "$unit" -p InactiveEnterTimestamp --value 2>/dev/null || true)")
        fi
    fi

    started_compact=$(compact_ts "$started")
    ended_compact=$(compact_ts "$ended")

    printf '%-14s %-5s %-4s %-5s %-33s %-19s %-19s\n' \
        "$user" "$uid" "$display" "$port" "$status" "$started_compact" "$ended_compact"
done
