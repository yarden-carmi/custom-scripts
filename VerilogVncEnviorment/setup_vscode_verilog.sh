#!/bin/bash

set -euo pipefail

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (e.g., sudo ./setup_vscode_verilog.sh)"
    exit 1
fi

if ! command -v code >/dev/null 2>&1; then
    echo "Error: 'code' command not found. Enable VS Code shell command first."
    exit 1
fi

EXT1="mshr-h.VerilogHDL"
EXT2="teros-technology.teroshdl"

# Python snippet to safely update VS Code settings while tolerating JSONC comments.
UPDATE_JSON_PY=$(cat << 'EOF'
import json
import os
import re
import sys

filepath = sys.argv[1]

if not os.path.exists(filepath):
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write('{}\n')

with open(filepath, 'r', encoding='utf-8') as f:
    raw = f.read().strip()

if not raw:
    raw = '{}'

# Strip // and /* */ comments to parse JSONC-like settings.json.
stripped = re.sub(r'/\*.*?\*/', '', raw, flags=re.S)
stripped = re.sub(r'(^|\s)//.*$', '', stripped, flags=re.M)

try:
    data = json.loads(stripped)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}

data['verilog.linting.linter'] = 'iverilog'
data['verilog.linting.iverilog.arguments'] = '-y ${workspaceFolder}'

with open(filepath, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, sort_keys=True)
    f.write('\n')
EOF
)

# Loop through users that have VNC configured, to match this environment's VNC-focused setup.
for user_home in /home/*; do
    if [ -d "$user_home/.vnc" ]; then
        username=$(basename "$user_home")
        id "$username" >/dev/null 2>&1 || continue
        
        echo "======================================"
        echo "Configuring VS Code for user: $username"
        echo "======================================"

        # 1. Install Extensions as the user
        su - "$username" -c "code --install-extension $EXT1 --force" || true
        su - "$username" -c "code --install-extension $EXT2 --force" || true

        # 2. Configure Settings
        CONFIG_DIR="$user_home/.config/Code/User"
        SETTINGS_FILE="$CONFIG_DIR/settings.json"

        # Create the config directory if the user hasn't opened VS Code yet
        mkdir -p "$CONFIG_DIR"
        chown "$username:$username" "$CONFIG_DIR"

        # 3. Inject the linter settings safely
        python3 -c "$UPDATE_JSON_PY" "$SETTINGS_FILE"
        
        # Ensure the user retains ownership of their settings file
        chown "$username:$username" "$SETTINGS_FILE"
        
        echo "Done for $username."
    fi
done

echo "======================================"
echo "Global installation complete!"
