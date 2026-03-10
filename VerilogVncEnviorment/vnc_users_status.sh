#!/bin/bash
# Show VNC status for all users:
# - whether they are connected now
# - when the current/last VNC service session started
# - when the last VNC service session ended

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo) to access all users' VNC logs and services."
    exit 1
fi

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

current_vnc_log_file() {
    local user_home=$1
    local display=$2
    local host

    host=$(hostname)
    echo "$user_home/.vnc/${host}:${display}.log"
}

BOOT_EPOCH=$(awk '/^btime / { print $2; exit }' /proc/stat 2>/dev/null || true)

resolve_vnc_log_file() {
    local user_home=$1
    local display=$2
    local current_log=""
    local fallback_log=""

    current_log=$(current_vnc_log_file "$user_home" "$display")
    if [[ -f "$current_log" ]]; then
        echo "$current_log"
        return
    fi

    fallback_log=$(find "$user_home/.vnc" -maxdepth 1 -type f -name "*:${display}.log" 2>/dev/null | sort | tail -n 1 || true)
    echo "$fallback_log"
}

get_last_vnc_connection_window() {
    local user_home=$1
    local display=$2
    local log_file=""

    [[ -n "$display" && "$display" != "-" ]] || {
        echo "|"
        return
    }

    log_file=$(resolve_vnc_log_file "$user_home" "$display")
    if [[ -z "$log_file" || ! -f "$log_file" ]]; then
        echo "|"
        return
    fi

    awk -v boot_epoch="${BOOT_EPOCH:-0}" '
        BEGIN {
            month_num["Jan"] = 1
            month_num["Feb"] = 2
            month_num["Mar"] = 3
            month_num["Apr"] = 4
            month_num["May"] = 5
            month_num["Jun"] = 6
            month_num["Jul"] = 7
            month_num["Aug"] = 8
            month_num["Sep"] = 9
            month_num["Oct"] = 10
            month_num["Nov"] = 11
            month_num["Dec"] = 12
            current_ts = ""
            current_epoch = 0
            last_start = ""
            last_end = ""
        }

        function set_textual_ts(mon_name, day, time_part, year, time_bits, mon, hh, mm, ss) {
            split(time_part, time_bits, ":")
            mon = month_num[mon_name]
            hh = time_bits[1] + 0
            mm = time_bits[2] + 0
            ss = time_bits[3] + 0
            current_ts = sprintf("%04d-%02d-%02d %02d:%02d:%02d", year, mon, day, hh, mm, ss)
            current_epoch = mktime(sprintf("%04d %02d %02d %02d %02d %02d", year, mon, day, hh, mm, ss))
        }

        function set_numeric_ts(date_part, time_part, date_bits, time_bits, year, mon, day, hh, mm, ss) {
            split(date_part, date_bits, "/")
            split(time_part, time_bits, ":")
            year = 2000 + date_bits[3]
            mon = date_bits[2] + 0
            day = date_bits[1] + 0
            hh = time_bits[1] + 0
            mm = time_bits[2] + 0
            ss = time_bits[3] + 0
            current_ts = sprintf("%04d-%02d-%02d %02d:%02d:%02d", year, mon, day, hh, mm, ss)
            current_epoch = mktime(sprintf("%04d %02d %02d %02d %02d %02d", year, mon, day, hh, mm, ss))
        }

        NF == 5 && $1 ~ /^(Sun|Mon|Tue|Wed|Thu|Fri|Sat)$/ && ($2 in month_num) && $3 ~ /^[0-9]{1,2}$/ && $4 ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/ && $5 ~ /^[0-9]{4}$/ {
            set_textual_ts($2, $3 + 0, $4, $5 + 0)
            next
        }

        NF == 2 && $1 ~ /^[0-9]{2}\/[0-9]{2}\/[0-9]{2}$/ && $2 ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/ {
            set_numeric_ts($1, $2)
            next
        }

        current_ts == "" || (boot_epoch > 0 && current_epoch < boot_epoch) {
            next
        }

        /Connections: accepted/ {
            last_start = current_ts
            last_end = ""
            next
        }

        /VNCSConnST:  closing|X connection to :[0-9]+ broken|Connections: closed|closed connection|client gone|disconnected|server.*exited/ {
            if (last_start != "") {
                last_end = current_ts
            }
        }

        END {
            printf "%s|%s\n", last_start, last_end
        }
    ' "$log_file"
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

        IFS='|' read -r last_connection_start last_connection_end <<< "$(get_last_vnc_connection_window "$user_home" "$display")"
        started=$(fmt_ts "$last_connection_start")
        ended=$(fmt_ts "$last_connection_end")

        if [[ "$status" == "yes" ]]; then
            ended="-"
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
