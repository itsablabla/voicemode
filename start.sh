#!/bin/bash
# VoiceMode Railway startup script
# Injects credentials from VOICEMODE_CREDENTIALS_JSON env var if set

set -e

# Create credentials dir
mkdir -p "$HOME/.voicemode"

# If VOICEMODE_CREDENTIALS_JSON is set, write it to the credentials file
if [ -n "$VOICEMODE_CREDENTIALS_JSON" ]; then
    echo "$VOICEMODE_CREDENTIALS_JSON" > "$HOME/.voicemode/credentials"
    chmod 600 "$HOME/.voicemode/credentials"
    echo "VoiceMode: Credentials injected from VOICEMODE_CREDENTIALS_JSON"
fi

# Start the voicemode server
exec voicemode serve --host 0.0.0.0 --port "${PORT:-8080}"
