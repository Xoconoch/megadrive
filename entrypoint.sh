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

# Trap SIGTERM and SIGINT to run cleanup.
trap cleanup SIGTERM SIGINT

###############################################################################
# Main setup starts here.
###############################################################################

ACCOUNTS_FILE="/app/accounts.json"

# Verify the accounts file exists.
if [ ! -f "$ACCOUNTS_FILE" ]; then
    echo "Accounts file not found: $ACCOUNTS_FILE"
    exit 1
fi

echo "Reading accounts from $ACCOUNTS_FILE"
# Get the account keys (e.g., "mega1", "mega2", etc.)
accounts=$(jq -r 'keys[]' "$ACCOUNTS_FILE")

# Starting port for the WebDAV servers.
port=8080

# This variable will accumulate rclone config entries.
RCLONE_CONFIG=""

# Loop through each account.
for account in $accounts; do
    user=$(jq -r --arg acc "$account" '.[$acc].user' "$ACCOUNTS_FILE")
    pass=$(jq -r --arg acc "$account" '.[$acc].pass' "$ACCOUNTS_FILE")
    
    echo "----------------------------------------"
    echo "Setting up account: $account"
    echo "User: $user"
    echo "Assigned WebDAV port: $port"
    
    # Create a dedicated temporary directory for MEGAcmd configuration.
    MEGA_CONFIG_DIR="/tmp/mega_${account}"
    mkdir -p "$MEGA_CONFIG_DIR"
    
    # Choose a shared folder to serve for this account.
    if [ "$account" = "mega1" ]; then
        TARGET_FOLDER="/MyMegaFiles"
    elif [ "$account" = "mega2" ]; then
        TARGET_FOLDER="/AnotherMegaFolder"
    else
        TARGET_FOLDER="/MyMegaFiles_${account}"
    fi

    # Define a log file to capture the output of mega-webdav.
    LOG_FILE="/tmp/mega_webdav_${account}.log"
    
    # Run the MEGAcmd commands in a subshell with HOME overridden.
    (
      export HOME="$MEGA_CONFIG_DIR"
      
      echo "Logging into MEGA for account $account..."
      mega-login "$user" "$pass"
      sleep 2  # Give some time for login.
      
      echo "Creating shared folder $TARGET_FOLDER (if it doesn't exist)..."
      # Create the folder; ignore error if it already exists.
      mega-mkdir "$TARGET_FOLDER" 2>/dev/null || true

      echo "Starting MEGA WebDAV for account $account on port $port serving folder $TARGET_FOLDER..."
      # Launch mega-webdav and redirect its output to the log file.
      mega-webdav "$TARGET_FOLDER" --port="$port" --public > "$LOG_FILE" 2>&1
    ) &  # Run the subshell in the background.
    
    # Wait (up to 10 seconds) for the log file to contain the expected output.
    max_wait=10
    elapsed=0
    while [ $elapsed -lt $max_wait ]; do
      if [ -f "$LOG_FILE" ] && grep -q "Serving via webdav" "$LOG_FILE"; then
          break
      fi
      sleep 1
      elapsed=$((elapsed+1))
    done

    # Extract the URL from the log file.
    log_line=$(grep "Serving via webdav" "$LOG_FILE" | head -n 1 || true)
    url=$(echo "$log_line" | awk -F': ' '{print $2}' | tr -d '[:space:]')
    
    if [ -z "$url" ]; then
       echo "WARNING: Failed to extract URL from webdav output for account $account."
       echo "Using fallback URL: http://127.0.0.1:$port"
       url="http://127.0.0.1:$port"
    else
       echo "Extracted WebDAV URL for account $account: $url"
    fi

    # Append an rclone configuration block for this account using the extracted URL.
    RCLONE_CONFIG+=$'\n'"[$account]"$'\n'"type = webdav"$'\n'"url = $url"$'\n'"vendor = other"$'\n'"user = anonymous"$'\n'"pass ="$'\n'
    
    # Increment port for the next account.
    port=$((port+1))
done

# Wait for the WebDAV servers to fully start.
echo "Waiting for WebDAV servers to fully start..."
sleep 5

# Write the accumulated rclone configuration to a file.
RCLONE_CONFIG_FILE="/tmp/rclone.conf"
echo "Writing rclone configuration to $RCLONE_CONFIG_FILE"
echo "$RCLONE_CONFIG" > "$RCLONE_CONFIG_FILE"

# Create a union remote that merges all account remotes.
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

# Use environment variables CRYPTO_PASSWORD and CRYPTO_PASSWORD2 for encryption.
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
