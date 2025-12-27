#!/bin/bash

# Variables
MAINTENANCE_SCRIPT_URL="https://raw.githubusercontent.com/Lyttle-Development/Tools/main/Maintenance/maintenance.sh"
CRONTAB_URL="https://raw.githubusercontent.com/Lyttle-Development/Tools/main/Maintenance/crontab"
USER_HOME="$HOME"
INSTALL_PATH="$USER_HOME/maintenance.sh"

# Download the maintenance script
echo "Downloading maintenance script..."
curl -H 'Cache-Control: no-cache' -fsSL "$MAINTENANCE_SCRIPT_URL" -o "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
echo "Maintenance script downloaded to $INSTALL_PATH and made executable."

# Download and set the cronjob
echo "Downloading crontab and setting it for the user..."
curl -H 'Cache-Control: no-cache' -fsSL "$CRONTAB_URL" | crontab -
echo "Crontab updated successfully."

echo "Installation completed."