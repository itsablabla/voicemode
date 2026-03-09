#!/bin/bash
# VoiceMode Railway startup script — permanent edition
#
# Responsibilities:
#   1. Inject credentials from VOICEMODE_CREDENTIALS_JSON env var on startup
#   2. If the access token is expired (or within 5 min of expiry), refresh it
#      via Auth0 and update VOICEMODE_CREDENTIALS_JSON in Railway so future
#      restarts always have a fresh token
#   3. Start a background token-refresh watchdog that re-runs the refresh
#      every 45 minutes so the container never goes stale mid-run
#   4. Start the voicemode MCP server
#
# Required env vars:
#   VOICEMODE_CREDENTIALS_JSON  — JSON blob from ~/.voicemode/credentials
#   RAILWAY_TOKEN               — Railway API token (for updating the env var)
#   RAILWAY_PROJECT_ID          — Set automatically by Railway
#   RAILWAY_SERVICE_ID          — Set automatically by Railway
#   RAILWAY_ENVIRONMENT_ID      — Set automatically by Railway

set -e

CREDENTIALS_DIR="$HOME/.voicemode"
CREDENTIALS_FILE="$CREDENTIALS_DIR/credentials"

AUTH0_DOMAIN="dev-2q681p5hobd1dtmm.us.auth0.com"
AUTH0_CLIENT_ID="1uJR1Q4HMkLkhzOXTg5JFuqBCq0FBsXK"
RAILWAY_GQL="https://backboard.railway.com/graphql/v2"

# ─── helpers ──────────────────────────────────────────────────────────────────

log() { echo "[voicemode-start] $*"; }

# Refresh the Auth0 access token using the stored refresh token.
# Writes the new credentials to $CREDENTIALS_FILE and, if RAILWAY_TOKEN is set,
# updates VOICEMODE_CREDENTIALS_JSON in Railway so future restarts stay fresh.
refresh_token() {
    log "Refreshing Auth0 access token..."

    local refresh_tok
    refresh_tok=$(python3 -c "import json; d=json.load(open('$CREDENTIALS_FILE')); print(d.get('refresh_token',''))")

    if [ -z "$refresh_tok" ]; then
        log "WARNING: No refresh_token found in credentials — skipping refresh."
        return 1
    fi

    # Call Auth0 token endpoint
    local response
    response=$(curl -s -X POST "https://${AUTH0_DOMAIN}/oauth/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=refresh_token" \
        --data-urlencode "client_id=${AUTH0_CLIENT_ID}" \
        --data-urlencode "refresh_token=${refresh_tok}")

    local new_access_token
    new_access_token=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)

    if [ -z "$new_access_token" ]; then
        log "ERROR: Token refresh failed. Response: $response"
        return 1
    fi

    # Build new credentials JSON with updated tokens and expiry
    local new_creds
    new_creds=$(python3 -c "
import json, time, sys

response = json.loads(sys.argv[1])
old = json.load(open('$CREDENTIALS_FILE'))

expires_in = response.get('expires_in', 3600)
new_creds = {
    'access_token': response['access_token'],
    'refresh_token': response.get('refresh_token', old.get('refresh_token', '')),
    'expires_at': time.time() + expires_in,
    'token_type': response.get('token_type', 'Bearer'),
    'user_info': old.get('user_info', {}),
}
print(json.dumps(new_creds))
" "$response")

    if [ -z "$new_creds" ]; then
        log "ERROR: Failed to build new credentials JSON."
        return 1
    fi

    # Write to local credentials file
    echo "$new_creds" > "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    log "Access token refreshed successfully (expires in ~1 hour)."

    # Update VOICEMODE_CREDENTIALS_JSON in Railway so future restarts use the new token
    if [ -n "$RAILWAY_TOKEN" ]; then
        log "Updating VOICEMODE_CREDENTIALS_JSON in Railway environment..."
        python3 << PYEOF
import json, requests, os, sys

new_creds = json.load(open('$CREDENTIALS_FILE'))
creds_json_str = json.dumps(new_creds)

railway_token = os.environ.get('RAILWAY_TOKEN', '')
project_id = os.environ.get('RAILWAY_PROJECT_ID', '')
service_id = os.environ.get('RAILWAY_SERVICE_ID', '')
env_id = os.environ.get('RAILWAY_ENVIRONMENT_ID', '')

mutation = """
mutation UpsertVariable(\$input: VariableUpsertInput!) {
  variableUpsert(input: \$input)
}
"""

resp = requests.post(
    'https://backboard.railway.com/graphql/v2',
    headers={'Authorization': f'Bearer {railway_token}', 'Content-Type': 'application/json'},
    json={
        'query': mutation,
        'variables': {
            'input': {
                'projectId': project_id,
                'serviceId': service_id,
                'environmentId': env_id,
                'name': 'VOICEMODE_CREDENTIALS_JSON',
                'value': creds_json_str,
            }
        }
    },
    timeout=15
)

data = resp.json()
if data.get('data', {}).get('variableUpsert'):
    print('[voicemode-start] Railway VOICEMODE_CREDENTIALS_JSON updated successfully.')
else:
    print(f'[voicemode-start] WARNING: Failed to update Railway env var: {data}', file=sys.stderr)
PYEOF
    else
        log "WARNING: RAILWAY_TOKEN not set — cannot persist refreshed token to Railway env vars."
        log "         Add RAILWAY_TOKEN to Railway service variables to enable auto-persistence."
    fi
}

# Background watchdog: refresh the token every 45 minutes
token_watchdog() {
    log "Token watchdog started (refresh interval: 45 min)."
    while true; do
        sleep 2700  # 45 minutes
        log "Watchdog: checking token freshness..."
        refresh_token || log "Watchdog: refresh attempt failed, will retry in 45 min."
    done
}

# ─── startup sequence ─────────────────────────────────────────────────────────

# 1. Create credentials directory
mkdir -p "$CREDENTIALS_DIR"

# 2. Inject credentials from env var
if [ -n "$VOICEMODE_CREDENTIALS_JSON" ]; then
    echo "$VOICEMODE_CREDENTIALS_JSON" > "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    log "Credentials injected from VOICEMODE_CREDENTIALS_JSON."
else
    log "WARNING: VOICEMODE_CREDENTIALS_JSON not set — Connect may not authenticate."
fi

# 3. Check token expiry and refresh if needed (expired or within 5 min of expiry)
if [ -f "$CREDENTIALS_FILE" ]; then
    TOKEN_STATUS=$(python3 -c "
import json, time
try:
    d = json.load(open('$CREDENTIALS_FILE'))
    expires_at = d.get('expires_at', 0)
    remaining = expires_at - time.time()
    if remaining < 300:
        print('EXPIRED')
    else:
        print(f'OK:{remaining:.0f}')
except Exception as e:
    print(f'ERROR:{e}')
")
    if [[ "$TOKEN_STATUS" == "EXPIRED" ]]; then
        log "Access token is expired or expiring soon — refreshing now..."
        refresh_token || log "WARNING: Initial token refresh failed. Connect may fail until token is refreshed."
    else
        REMAINING=$(echo "$TOKEN_STATUS" | cut -d: -f2)
        log "Access token is valid (expires in ${REMAINING}s)."
    fi
fi

# 4. Start token watchdog in background
token_watchdog &
WATCHDOG_PID=$!
log "Token watchdog running (PID: $WATCHDOG_PID)."

# 5. Start the voicemode MCP server (foreground)
log "Starting VoiceMode MCP server on 0.0.0.0:${PORT:-8080}..."
exec voicemode serve --host 0.0.0.0 --port "${PORT:-8080}"
