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

# Download and set the cronjob for root
echo "Downloading crontab file..."
TEMP_CRONTAB=$(mktemp)
curl -H 'Cache-Control: no-cache' -fsSL "$CRONTAB_URL" -o "$TEMP_CRONTAB"

# Ensure the crontab file ends with a newline
sed -i -e '$a\' "$TEMP_CRONTAB"

echo "Setting the cronjob for the root user..."
sudo crontab "$TEMP_CRONTAB"
rm "$TEMP_CRONTAB"
echo "Root crontab updated successfully."

echo "Installation completed."