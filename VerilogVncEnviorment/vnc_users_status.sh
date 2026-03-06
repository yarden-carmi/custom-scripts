#!/bin/bash
# Show VNC status for all users:
# - whether they are connected now
# - when the current/last VNC service session started
# - when the last VNC service session ended

set -euo pipefail

STATE_FILE="/tmp/vnc_users_status.state.$(id -u)"

declare -A PREV_STATUS
declare -A PREV_END

if [[ -f "$STATE_FILE" ]]; then
    while IFS='|' read -r u s e; do
        [[ -n "$u" ]] || continue
        PREV_STATUS["$u"]="$s"
        PREV_END["$u"]="$e"
    done < "$STATE_FILE"
fi

extract_display_num() {
    local unit_file=$1
    local display_num=""

    # Preferred source: explicit DISPLAY environment in unit file.
    display_num=$(grep -Eo 'Environment=DISPLAY=:[0-9]+' "$unit_file" 2>/dev/null | sed -E 's/.*:([0-9]+)/\1/' | head -n 1 || true)

    # Fallback 1: parse display from ExecStart/ExecStartPre/ExecStop entries.
    if [[ -z "$display_num" ]]; then
        display_num=$(grep -Eo ':[0-9]+' "$unit_file" 2>/dev/null | sed 's/^://' | head -n 1 || true)
    fi

    # Fallback 2: parse from Description "... on :N".
    if [[ -z "$display_num" ]]; then
        display_num=$(grep -Eo 'on :[0-9]+' "$unit_file" 2>/dev/null | sed -E 's/.*:([0-9]+)/\1/' | head -n 1 || true)
    fi

    echo "$display_num"
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

get_start_ts() {
    local unit=$1
    local ts=""

    # Prefer the main service process start time (updates on restart).
    ts=$(systemctl show "$unit" -p ExecMainStartTimestamp --value 2>/dev/null || true)
    if [[ -z "$ts" || "$ts" == "n/a" ]]; then
        # Fallback to unit active-enter timestamp.
        ts=$(systemctl show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null || true)
    fi

    echo "$ts"
}

current_vnc_log_file() {
    local user_home=$1
    local display=$2
    local host

    host=$(hostname)
    echo "$user_home/.vnc/${host}:${display}.log"
}

log_has_accepted_connections() {
    local log_file=$1

    [[ -f "$log_file" ]] || return 1
    grep -q 'Connections: accepted' "$log_file" 2>/dev/null
}

get_last_vnc_activity_ts() {
    local unit=$1
    local user_home=$2
    local display=$3
    local line=""
    local latest_log=""
    local ts=""
    local current_log=""

    current_log=$(current_vnc_log_file "$user_home" "$display")
    if ! log_has_accepted_connections "$current_log"; then
        echo ""
        return
    fi

    # Preferred source: journal lines that indicate the previous session ended.
    line=$(journalctl -b -u "$unit" --no-pager -o short-iso 2>/dev/null | grep -Ei 'X connection to :[0-9]+ broken|Xtigervnc server cleanly exited|Stopping vncserver-.*service|Deactivated successfully|Connections: closed|closed connection|client gone|disconnected' | tail -n 1 || true)
    if [[ -n "$line" ]]; then
        echo "$line" | awk '{print $1" "$2}'
        return
    fi

    latest_log=$(ls -1t "$user_home"/.vnc/*.log 2>/dev/null | head -n 1 || true)
    if [[ -z "$latest_log" ]]; then
        echo ""
        return
    fi

    # TigerVNC logs often lack inline timestamps; use log mtime as best available activity marker.
    ts=$(stat -c '%y' "$latest_log" 2>/dev/null | cut -d'.' -f1 || true)
    echo "$ts"
}

get_last_vnc_session_start_ts() {
    local unit=$1
    local user_home=$2
    local display=$3
    local line=""
    local current_log=""

    current_log=$(current_vnc_log_file "$user_home" "$display")
    if ! log_has_accepted_connections "$current_log"; then
        echo ""
        return
    fi

    # Use the latest server/session start event from the current boot.
    line=$(journalctl -b -u "$unit" --no-pager -o short-iso 2>/dev/null | grep -Ei 'New Xtigervnc server|Starting vncserver-.*service|Started vncserver-.*service' | tail -n 1 || true)
    if [[ -n "$line" ]]; then
        echo "$line" | awk '{print $1" "$2}'
        return
    fi

    echo ""
}

get_last_vnc_session_start_before_ts() {
    local unit=$1
    local user_home=$2
    local display=$3
    local cutoff_ts=$4
    local current_log=""

    if [[ -z "$cutoff_ts" || "$cutoff_ts" == "-" ]]; then
        echo ""
        return
    fi

    current_log=$(current_vnc_log_file "$user_home" "$display")
    if ! log_has_accepted_connections "$current_log"; then
        echo ""
        return
    fi

    journalctl -b -u "$unit" --no-pager -o short-iso 2>/dev/null \
        | grep -Ei 'New Xtigervnc server|Starting vncserver-.*service|Started vncserver-.*service' \
        | awk -v cutoff="$cutoff_ts" '
            {
                ts=$1
                gsub("T", " ", ts)
                sub(/[+-][0-9]{2}:[0-9]{2}$/, "", ts)
                if (ts <= cutoff) {
                    last=ts
                }
            }
            END {
                print last
            }
        '
}

compact_ts() {
    local ts=${1:-}
    if [[ -z "$ts" || "$ts" == "-" ]]; then
        echo "-"
        return
    fi

    # Extract canonical timestamp from mixed sources (systemctl, journalctl, stat).
    local extracted
    extracted=$(echo "$ts" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}' | head -n 1 || true)
    if [[ -n "$extracted" ]]; then
        echo "${extracted/T/ }"
    else
        echo "-"
    fi
}

printf '%-14s %-5s %-4s %-5s %-33s %-19s %-19s\n' \
    "USER" "UID" "DSP" "PORT" "STATUS" "START" "END"
printf '%s\n' "-----------------------------------------------------------------------------------------------------"

while IFS=: read -r user uid; do
    unit="vncserver-$user.service"
    unit_file="/etc/systemd/system/$unit"
    user_home=$(getent passwd "$user" | cut -d: -f6)

    display="-"
    port="-"
    connected="no"
    status="no-unit"
    active_state="-"
    started="-"
    ended="-"

    if systemctl cat "$unit" >/dev/null 2>&1 || [[ -f "$unit_file" ]]; then
        if [[ -f "$unit_file" ]]; then
            display=$(extract_display_num "$unit_file")
        else
            display=$(extract_display_num <(systemctl cat "$unit" 2>/dev/null || true))
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

        started=$(fmt_ts "$(get_last_vnc_session_start_ts "$unit" "$user_home" "$display")")
        if [[ "$started" == "-" && "$status" == "yes" ]]; then
            # If we cannot find a connect log line, fall back for active sessions.
            started=$(fmt_ts "$(get_start_ts "$unit")")
        fi

        if [[ "$active_state" == "active" ]]; then
            if [[ "$status" == "no" ]]; then
                ended=$(fmt_ts "$(get_last_vnc_activity_ts "$unit" "$user_home" "$display")")
            else
                ended="-"
            fi
        else
            ended=$(fmt_ts "$(systemctl show "$unit" -p InactiveEnterTimestamp --value 2>/dev/null || true)")
        fi

        # Disconnected session rows should report the latest start that happened before END.
        if [[ "$status" == "no" && "$ended" != "-" ]]; then
            started_before_end=$(fmt_ts "$(get_last_vnc_session_start_before_ts "$unit" "$user_home" "$display" "$(compact_ts "$ended")")")
            if [[ "$started_before_end" != "-" ]]; then
                started="$started_before_end"
            fi
        fi

    fi

    # If no timestamp source exists, infer disconnect time from yes->no transition.
    if [[ "$status" == "no" && "$ended" == "-" ]]; then
        if [[ "${PREV_STATUS[$user]:-}" == "yes" ]]; then
            ended="$(date '+%Y-%m-%d %H:%M:%S')"
            PREV_END["$user"]="$ended"
        elif [[ -n "${PREV_END[$user]:-}" ]]; then
            ended="${PREV_END[$user]}"
        fi
    fi

    if [[ "$status" == "yes" ]]; then
        PREV_END["$user"]=""
    fi
    PREV_STATUS["$user"]="$status"

    started_compact=$(compact_ts "$started")
    ended_compact=$(compact_ts "$ended")

    printf '%-14s %-5s %-4s %-5s %-33s %-19s %-19s\n' \
        "$user" "$uid" "$display" "$port" "$status" "$started_compact" "$ended_compact"
done < <(getent passwd | awk -F: '$3>=1000 && $1!="nobody" && $7 !~ /(nologin|false)$/ {print $1":"$3}')

tmp_state="${STATE_FILE}.tmp.$$"
: > "$tmp_state"
for u in "${!PREV_STATUS[@]}"; do
    printf '%s|%s|%s\n' "$u" "${PREV_STATUS[$u]}" "${PREV_END[$u]:-}" >> "$tmp_state"
done
if ! command mv -f "$tmp_state" "$STATE_FILE" 2>/dev/null; then
    rm -f "$tmp_state" 2>/dev/null || true
fi
