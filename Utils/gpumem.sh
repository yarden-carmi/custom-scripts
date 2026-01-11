#!/bin/bash

# 1. Get GPU total/used memory (MiB) and GPU utilization (%)
# We use IFS=, to correctly handle the output format
IFS=, read -r total_mem_mib used_mem_mib gpu_util < <(nvidia-smi --query-gpu=memory.total,memory.used,utilization.gpu --format=csv,noheader,nounits)

# --- SANITIZATION STEP ---
# Strip whitespace
total_mem_mib=$(echo "${total_mem_mib}" | tr -d '[:space:]')
used_mem_mib=$(echo "${used_mem_mib}" | tr -d '[:space:]')
gpu_util=$(echo "${gpu_util}" | tr -d '[:space:]')

# Check if values are valid numbers. If "Not Supported" or empty, force to 0.
re='^[0-9]+$'
if ! [[ $total_mem_mib =~ $re ]]; then total_mem_mib=0; fi
if ! [[ $used_mem_mib =~ $re ]]; then used_mem_mib=0; fi
if ! [[ $gpu_util =~ $re ]]; then gpu_util=0; fi
# -------------------------

# 2. Get PID, memory, user, and container short ID for all GPU processes
pid_data=$(nvidia-smi --query-compute-apps=pid,used_gpu_memory --format=csv,noheader,nounits | while IFS=, read -r pid mem; do
    pid=$(echo "$pid" | tr -d '[:space:]')
    mem=$(echo "$mem" | tr -d '[:space:]')
    
    # If mem is "Not Supported" or empty for a process, treat as 0
    if ! [[ $mem =~ $re ]]; then mem=0; fi
    
    if [ -z "$pid" ]; then continue; fi
    
    # Get the 12-char container ID from cgroup
    short_id=$(cat /proc/"$pid"/cgroup 2>/dev/null | grep -o -E '[0-9a-f]{64}' | head -n 1 | cut -c 1-12)
    
    # Get the user who owns the host process
    user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    
    if [ -n "$short_id" ]; then
        echo "$short_id $pid $mem $user"
    fi
done)

# 3. Get the mapping of container IDs to names
id_to_name_map=$(docker ps --format "{{.ID}} {{.Names}}")

# 4. Process all data in awk
echo "$pid_data" | awk \
    -v total_mib="$total_mem_mib" \
    -v used_mib="$used_mem_mib" \
    -v util="$gpu_util" \
    -v name_map_str="$id_to_name_map" '
    
    BEGIN {
        # --- Handle Global Stats ---
        total_gib = total_mib / 1024
        used_gib = used_mib / 1024
        
        percent = 0
        if (total_mib > 0) {
            percent = (used_mib / total_mib) * 100
        }

        printf "\n"
        printf "GPU Summary:\n"
        printf "========================================\n"
        
        # Display "N/A" if total_mib is 0 (caused by "Not Supported")
        if (total_mib == 0) {
            printf "Total GPU Memory: N/A (Driver reported: Not Supported)\n"
            printf "Used GPU Memory:  N/A\n"
        } else {
            printf "Total GPU Memory: %.2f GiB\n", total_gib
            printf "Used GPU Memory:  %.2f GiB (%.1f%%)\n", used_gib, percent
        }
        
        printf "GPU Utilization:  %d%%\n", util
        printf "========================================\n\n"
        
        # Process Name Map
        split(name_map_str, lines, "\n")
        for (i in lines) {
            split_pos = index(lines[i], " ")
            if (split_pos == 0) continue;
            full_id = substr(lines[i], 1, split_pos - 1)
            name = substr(lines[i], split_pos + 1)
            name_map[substr(full_id, 1, 12)] = name
        }
    }
    
    {
        if ($1 != "") {
            container_id=$1
            memory=$3
            user=$4
            
            total_mem[container_id] += memory
            if (users[container_id] == "") {
                users[container_id] = user
            }
        }
    }
    
    END {
        printf "%-40s %-12s %-15s %-12s\n", "Container Name", "User", "Total", "Share (%)"
        print "---------------------------------------------------------------------------------"

        for (id in total_mem) {
            container_name = name_map[id] ? name_map[id] : id
            container_user = users[id] ? users[id] : "unknown"
            mem_gib = total_mem[id] / 1024
            
            # Only calculate share if we have a valid Used MIB from global stats
            if (used_mib > 0) { 
                share_percent = (total_mem[id] / used_mib) * 100
                percent_str = sprintf("%.1f%%", share_percent)
            } else {
                percent_str = "N/A"
            }
            
            mem_gib_str = sprintf("%.2f GiB", mem_gib)
            
            printf "%-40s %-12s %-15s %-12s\n", container_name, container_user, mem_gib_str, percent_str
        }
        printf "---------------------------------------------------------------------------------\n\n"
    }
'
