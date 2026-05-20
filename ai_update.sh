#!/bin/bash

# Define the path to your git repository
REPO_PATH="/home/wof/.sopel/plugins/aibot"
AI_BOT="/home/wof/.sopel/plugins/aibot/gwen3_bot.py"

# Navigate to the repository directory
cd "$REPO_PATH" || { echo "Failed to enter directory $REPO_PATH"; exit 1; }

# Pull the latest changes
echo "Pulling latest changes for $(basename "$PWD")..."
git pull

if [ $? -eq 0 ]; then
    echo "Successfully pulled latest changes."
else
    echo "Failed to pull changes. Check for local modifications or network issues."
fi
