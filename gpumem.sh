#!/bin/bash

# 1. Get GPU total/used memory (MiB) and GPU utilization (%)
read -r total_mem_mib used_mem_mib gpu_util < <(nvidia-smi --query-gpu=memory.total,memory.used,utilization.gpu --format=csv,noheader,nounits)

# 2. Get PID, memory, user, and container short ID for all GPU processes
pid_data=$(nvidia-smi --query-compute-apps=pid,used_gpu_memory --format=csv,noheader,nounits | while IFS=, read -r pid mem; do
    pid=$(echo $pid | tr -d '[:space:]')
    mem=$(echo $mem | tr -d '[:space:]') # Clean memory value too
    if [ -z "$pid" ]; then continue; fi
    
    # Get the 12-char container ID
    short_id=$(cat /proc/$pid/cgroup 2>/dev/null | grep -o -E '[0-9a-f]{64}' | head -n 1 | cut -c 1-12)
    
    # Get the user who owns the host process
    user=$(ps -o user= -p $pid 2>/dev/null | tr -d '[:space:]')
    
    if [ -n "$short_id" ]; then
        # Pass all four values to awk
        echo "$short_id $pid $mem $user"
    fi
done)

# 3. Get the mapping of container IDs to names (format: "full_id container_name")
id_to_name_map=$(docker ps --format "{{.ID}} {{.Names}}")

# 4. Process all data in awk. Pass totals and name map as variables.
echo "$pid_data" | awk \
    -v total_mib="$total_mem_mib" \
    -v used_mib="$used_mem_mib" \
    -v util="$gpu_util" \
    -v name_map_str="$id_to_name_map" '
    
    # BEGIN block: Runs once before processing any input
    BEGIN {
        # --- Print overall GPU summary ---
        total_gib = total_mib / 1024
        used_gib = used_mib / 1024
        if (total_mib > 0) {
            percent = (used_mib / total_mib) * 100
        } else {
            percent = 0
        }
        printf "\n"
        printf "GPU Summary:\n"
        printf "========================================\n"
        printf "Total GPU Memory: %.2f GiB\n", total_gib
        printf "Used GPU Memory:  %.2f GiB (%.1f%%)\n", used_gib, percent
        printf "GPU Utilization:  %d%%\n", util
        printf "========================================\n\n"
        
        # --- Process the name map ---
        split(name_map_str, lines, "\n")
        for (i in lines) {
            split_pos = index(lines[i], " ")
            if (split_pos == 0) continue;
            
            full_id = substr(lines[i], 1, split_pos - 1)
            name = substr(lines[i], split_pos + 1)
            name_map[substr(full_id, 1, 12)] = name
        }
    }
    
    # MAIN block: Runs for each line of pid_data from stdin
    {
        # $1=short_id, $2=pid, $3=memory, $4=user
        container_id=$1
        memory=$3
        user=$4
        
        total_mem[container_id] += memory
        
        if (users[container_id] == "") {
            users[container_id] = user
        }
    }
    
    # END block: Runs after all data is processed
    END {
        # Changed header "Total (GiB)" to "Total"
        printf "%-40s %-12s %-15s %-12s\n", "Container Name", "User", "Total", "Share (%)"
        print "---------------------------------------------------------------------------------"

        for (id in total_mem) {
            container_name = name_map[id] ? name_map[id] : id
            container_user = users[id] ? users[id] : "unknown"
            mem_gib = total_mem[id] / 1024
            
            percent = 0
            if (used_mib > 0) { 
                percent = (total_mem[id] / used_mib) * 100
            }
            
            # Format percentage as a string with '%'
            percent_str = sprintf("%.1f%%", percent)
            
            # Format memory as a string with " GiB"
            mem_gib_str = sprintf("%.2f GiB", mem_gib)
            
            # Print the string, left-aligned in a 15-char width
            printf "%-40s %-12s %-15s %-12s\n", container_name, container_user, mem_gib_str, percent_str
        }
        printf "---------------------------------------------------------------------------------\n\n"

    }
'