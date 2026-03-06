#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g., sudo ./vscode_verilog_setup.sh)"
  exit 1
fi

EXT1="mshr-h.VerilogHDL"
EXT2="teros-technology.teroshdl"

# Python snippet to safely inject settings into VS Code's JSONC format
UPDATE_JSON_PY=$(cat << 'EOF'
import sys, os

filepath = sys.argv[1]

# Initialize a valid JSON structure if the file doesn't exist
if not os.path.exists(filepath):
    with open(filepath, 'w') as f:
        f.write('{\n}')

with open(filepath, 'r') as f:
    content = f.read()

# Only inject if the setting doesn't already exist
if '"verilog.linting.linter"' not in content:
    last_brace_idx = content.rfind('}')
    
    if last_brace_idx != -1:
        before_brace = content[:last_brace_idx].strip()
        # Check if the preceding line needs a comma
        needs_comma = before_brace != '{' and not before_brace.endswith(',')
        
        # Injecting both the linter choice and the workspace discovery flag
        insertion = '"verilog.linting.linter": "iverilog",\n    "verilog.linting.iverilog.arguments": "-y ${workspaceFolder}"'
        
        if needs_comma:
            insertion = ',\n    ' + insertion + '\n'
        else:
            insertion = '\n    ' + insertion + '\n'
            
        new_content = content[:last_brace_idx] + insertion + content[last_brace_idx:]
        
        with open(filepath, 'w') as f:
            f.write(new_content)
EOF
)

# Loop through all human users in the /home/ directory
for user_home in /home/*; do
    if [ -d "$user_home" ]; then
        username=$(basename "$user_home")
        
        echo "======================================"
        echo "Configuring VS Code for user: $username"
        echo "======================================"

        # 1. Install Extensions as the user
        su - "$username" -c "code --install-extension $EXT1 --force"
        su - "$username" -c "code --install-extension $EXT2 --force"

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
