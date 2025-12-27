#!/bin/bash

# Script for Server Maintenance

echo "Starting APT cleanup..."
sudo apt-get autoclean -y
sudo apt-get clean -y
echo "APT cleanup completed."

echo "Starting Docker cleanup..."
# Remove dangling images
sudo docker image prune -f
# Remove all unused images
sudo docker image prune -a -f
# Remove unused volumes
sudo docker volume prune -f
# Remove unused build cache
sudo docker builder prune -f
echo "Docker cleanup completed."

echo "Server maintenance completed."