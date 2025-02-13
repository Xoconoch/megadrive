#!/bin/bash
set -euo pipefail

###############################################################################
# If running as root and PUID/PGID are provided, create (or use) a custom user and re‑exec
###############################################################################
if [ "$(id -u)" -eq 0 ] && [ -n "${PUID:-}" ] && [ -n "${PGID:-}" ] && [ -z "${DROPPED_PRIV:-}" ]; then
    echo "Running as root, but PUID and PGID are set. Creating a custom user..."

    # Check if a group with PGID already exists.
    if getent group "$PGID" > /dev/null 2>&1; then
        group_name=$(getent group "$PGID" | cut -d: -f1)
        echo "Group with GID $PGID already exists: $group_name"
    else
        group_name="customgroup"
        groupadd -g "$PGID" "$group_name"
        echo "Created group $group_name with GID $PGID"
    fi

    # Check if a user with the provided PUID already exists.
    existing_user=$(getent passwd "$PUID" | cut -d: -f1 || true)
    if [ -n "$existing_user" ]; then
        echo "User with UID $PUID already exists: $existing_user"
        custom_username="$existing_user"
    else
        custom_username="customuser"
        useradd -u "$PUID" -g "$group_name" -m "$custom_username"
        echo "Created user $custom_username with UID $PUID and group $group_name"
    fi

    # Ensure the fuse group exists before adding the user.
    if ! getent group fuse >/dev/null 2>&1; then
        echo "Fuse group does not exist. Creating fuse group..."
        groupadd fuse
    fi

    # Add the user to the fuse group.
    usermod -aG fuse "$custom_username" || true

    # Adjust ownership of directories that need to be writable.
    # We avoid changing ownership on the read-only bind mount (/app/accounts.json).
    chown -R "$custom_username":"$group_name" /app/main /tmp || true

    # Mark that we already dropped privileges to avoid recursion.
    export DROPPED_PRIV=1
    echo "Dropping privileges to $custom_username (UID=$PUID, GID=$PGID -> group: $group_name)."
    exec gosu "$custom_username" "$0" "$@"
fi

###############################################################################
# Cleanup function: unmount /app/main on termination
###############################################################################
cleanup() {
    echo "Caught termination signal. Unmounting /app/main..."
    # Use fusermount (for FUSE-based mounts), falling back to umount if needed.
    if command -v fusermount &>/dev/null; then
        fusermount -u /app/main || umount /app/main
    else
        umount /app/main
    fi
    echo "Unmounted /app/main. Exiting."
    exit 0
}
trap cleanup SIGTERM SIGINT

###############################################################################
# Main setup starts here.
###############################################################################

ACCOUNTS_FILE="/app/accounts.json"
if [ ! -f "$ACCOUNTS_FILE" ]; then
    echo "Accounts file not found: $ACCOUNTS_FILE"
    exit 1
fi

echo "Reading accounts from $ACCOUNTS_FILE"
accounts=$(jq -r 'keys[]' "$ACCOUNTS_FILE")

# This function performs the per-account work.
# It logs into MEGA, creates the shared folder, and launches mega-webdav in background.
# Once the log file shows that the server is ready, it writes the extracted URL to a temp file.
start_account() {
    local account="$1"
    local port="$2"
    local ACCOUNTS_FILE="/app/accounts.json"
    local user pass
    user=$(jq -r --arg acc "$account" '.[$acc].user' "$ACCOUNTS_FILE")
    pass=$(jq -r --arg acc "$account" '.[$acc].pass' "$ACCOUNTS_FILE")
    
    echo "----------------------------------------"
    echo "Setting up account: $account"
    echo "User: $user"
    echo "Assigned WebDAV port: $port"
    
    local MEGA_CONFIG_DIR="/tmp/mega_${account}"
    mkdir -p "$MEGA_CONFIG_DIR"
    local TARGET_FOLDER="/MyMegaFiles_${account}"
    local LOG_FILE="/tmp/mega_webdav_${account}.log"
    
    export HOME="$MEGA_CONFIG_DIR"
    
    echo "Logging into MEGA for account $account..."
    mega-login "$user" "$pass"
    sleep 2  # Allow time for login.
    
    echo "Creating shared folder $TARGET_FOLDER (if it doesn't exist)..."
    mega-mkdir "$TARGET_FOLDER" 2>/dev/null || true

    echo "Starting MEGA WebDAV for account $account on port $port serving folder $TARGET_FOLDER..."
    # Launch mega-webdav in background. (It will keep running even after this function ends.)
    mega-webdav "$TARGET_FOLDER" --port="$port" --public > "$LOG_FILE" 2>&1 &
    
    # Wait (up to 10 seconds) for the log file to show that the server is serving.
    local max_wait=10
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if [ -f "$LOG_FILE" ] && grep -q "Serving via webdav" "$LOG_FILE"; then
            break
        fi
        sleep 1
        elapsed=$((elapsed+1))
    done

    # Extract the URL from the log.
    local log_line url
    log_line=$(grep "Serving via webdav" "$LOG_FILE" | head -n 1 || true)
    url=$(echo "$log_line" | awk -F': ' '{print $2}' | tr -d '[:space:]')
    
    if [ -z "$url" ]; then
       echo "WARNING: Failed to extract URL from webdav output for account $account."
       echo "Using fallback URL: http://127.0.0.1:$port"
       url="http://127.0.0.1:$port"
    else
       echo "Extracted WebDAV URL for account $account: $url"
    fi
    
    # Save the URL for later rclone configuration.
    echo "$url" > "/tmp/mega_url_${account}.txt"
}

# -----------------------------------------------------------------------------
# Initiate all accounts concurrently, but no more than 5 at a time.
# -----------------------------------------------------------------------------
port=8080
max_concurrent=100
for account in $accounts; do
    start_account "$account" "$port" &
    port=$((port+1))
    
    # If we already have 5 background jobs running, wait a bit.
    while [ "$(jobs -p | wc -l)" -ge "$max_concurrent" ]; do
        sleep 1
    done
done
# Wait for all account setups to finish.
wait

# -----------------------------------------------------------------------------
# Accumulate rclone configuration entries from the gathered URLs.
# -----------------------------------------------------------------------------
RCLONE_CONFIG=""
for account in $accounts; do
    url=$(cat "/tmp/mega_url_${account}.txt")
    RCLONE_CONFIG+=$'\n'"[$account]"$'\n'"type = webdav"$'\n'"url = $url"$'\n'"vendor = other"$'\n'"user = anonymous"$'\n'"pass ="$'\n'
done

echo "Waiting for WebDAV servers to fully start..."
sleep 5

RCLONE_CONFIG_FILE="/tmp/rclone.conf"
echo "Writing rclone configuration to $RCLONE_CONFIG_FILE"
echo "$RCLONE_CONFIG" > "$RCLONE_CONFIG_FILE"

# Build a union remote configuration string (all accounts as upstreams).
union_remotes=""
for account in $accounts; do
    if [ -z "$union_remotes" ]; then
        union_remotes="${account}:"
    else
        union_remotes="${union_remotes} ${account}:"
    fi
done
echo "Creating union remote 'mega_union' with upstreams: $union_remotes"
rclone config create mega_union union upstreams="$union_remotes" --config "$RCLONE_CONFIG_FILE"

###############################################################################
# Create an encrypted (crypt) remote on top of the union remote.
###############################################################################
echo "Creating crypt remote 'encrypted' on top of union remote 'mega_union'..."
CRYPTO_PASSWORD="${CRYPTO_PASSWORD:-changeme}"
CRYPTO_PASSWORD2="${CRYPTO_PASSWORD2:-changeme2}"
rclone config create encrypted crypt remote mega_union: \
    password "$(rclone obscure "$CRYPTO_PASSWORD")" \
    password2 "$(rclone obscure "$CRYPTO_PASSWORD2")" \
    --config "$RCLONE_CONFIG_FILE"

###############################################################################
# Mount the encrypted remote.
###############################################################################
echo "Mounting crypt remote 'encrypted' to /app/main ..."
rclone mount encrypted: /app/main --config "$RCLONE_CONFIG_FILE" --vfs-cache-mode full --allow-non-empty &

echo "----------------------------------------"
echo "Setup complete. The encrypted union mount is available at /app/main."
echo "Press Ctrl+C to stop the container."

# Keep the container running.
tail -f /dev/null
