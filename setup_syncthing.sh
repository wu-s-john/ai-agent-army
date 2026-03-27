#!/bin/bash
set -euo pipefail

# ─── Config ───
OP_ITEM_NAME="syncthing-network"
OP_VAULT="Personal"
SYNC_FOLDER="$HOME/sync-files"
SYNCTHING_API="http://localhost:8384"

# ─── Helpers ───
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "▸ $*"; }

get_api_key() {
  syncthing cli config gui apikey get 2>/dev/null
}

api() {
  local method="$1" endpoint="$2" api_key
  api_key="$(get_api_key)"
  shift 2
  curl -sf -X "$method" \
    -H "X-API-Key: $api_key" \
    -H "Content-Type: application/json" \
    "${SYNCTHING_API}${endpoint}" "$@"
}

get_device_id() {
  syncthing cli show system 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['myID'])"
}

get_hostname() {
  hostname -s 2>/dev/null || hostname
}

# ─── Ensure op is signed in ───
info "Checking 1Password CLI..."
if ! op whoami &>/dev/null; then
  echo ""
  echo "  1Password CLI is not signed in. Run:"
  echo ""
  echo "    eval \$(op signin)"
  echo ""
  echo "  Then re-run this script."
  exit 1
fi

# ─── Install syncthing ───
info "Checking syncthing installation..."
if [[ "$OSTYPE" == darwin* ]]; then
  if ! brew list syncthing &>/dev/null; then
    info "Installing syncthing via Homebrew..."
    brew install syncthing
  else
    info "syncthing: already installed"
  fi

  if ! brew services list | grep -q "syncthing.*started"; then
    info "Starting syncthing service..."
    brew services start syncthing
    sleep 3  # give it time to generate config and start API
  else
    info "syncthing: already running"
  fi
else
  # Linux
  if ! command -v syncthing &>/dev/null; then
    info "Installing syncthing..."
    sudo apt-get update -qq && sudo apt-get install -y syncthing
  else
    info "syncthing: already installed"
  fi

  if ! systemctl --user is-active syncthing &>/dev/null; then
    info "Starting syncthing service..."
    systemctl --user enable --now syncthing
    sleep 3
  else
    info "syncthing: already running"
  fi
fi

# ─── Ensure sync folder exists ───
mkdir -p "$SYNC_FOLDER"

# ─── Get this device's info ───
MY_DEVICE_ID="$(get_device_id)"
MY_NAME="$(get_hostname)"
info "This device: $MY_NAME ($MY_DEVICE_ID)"

# ─── Read or create the 1Password config ───
info "Reading syncthing network config from 1Password..."
if op item get "$OP_ITEM_NAME" --vault "$OP_VAULT" &>/dev/null; then
  NETWORK_CONFIG="$(op item get "$OP_ITEM_NAME" --vault "$OP_VAULT" --fields notesPlain)"
else
  info "No existing config found. Creating new one..."
  NETWORK_CONFIG='{
  "devices": {},
  "folders": {
    "sync-files": {
      "path_default": "~/sync-files"
    }
  }
}'
  op item create --category=SecureNote \
    --title="$OP_ITEM_NAME" \
    --vault="$OP_VAULT" \
    "notesPlain=${NETWORK_CONFIG}"
  info "Created '$OP_ITEM_NAME' in 1Password ($OP_VAULT vault)"
fi

# ─── Register this device in the config ───
info "Registering this device in network config..."
UPDATED_CONFIG="$(echo "$NETWORK_CONFIG" | python3 -c "
import sys, json
config = json.load(sys.stdin)
config.setdefault('devices', {})
config['devices']['$MY_NAME'] = '$MY_DEVICE_ID'
print(json.dumps(config, indent=2))
")"

op item edit "$OP_ITEM_NAME" --vault "$OP_VAULT" \
  "notesPlain=${UPDATED_CONFIG}"
info "Updated network config in 1Password"

# ─── Add all other devices from the config ───
info "Adding remote devices from network config..."
DEVICE_PAIRS="$(echo "$UPDATED_CONFIG" | python3 -c "
import sys, json
config = json.load(sys.stdin)
my_id = '$MY_DEVICE_ID'
for name, dev_id in config.get('devices', {}).items():
    if dev_id != my_id:
        print(f'{name}\t{dev_id}')
")"

if [[ -z "$DEVICE_PAIRS" ]]; then
  info "No other devices in the network yet."
else
  while IFS=$'\t' read -r name device_id; do
    info "Adding device: $name ($device_id)"
    # Check if device already exists
    if api GET "/rest/config/devices/${device_id}" &>/dev/null; then
      info "  $name: already configured, skipping"
    else
      api PUT "/rest/config/devices/${device_id}" \
        -d "{\"deviceID\":\"${device_id}\",\"name\":\"${name}\",\"addresses\":[\"dynamic\"],\"autoAcceptFolders\":true}"
      info "  $name: added"
    fi
  done <<< "$DEVICE_PAIRS"
fi

# ─── Configure the sync-files folder ───
info "Configuring sync-files folder..."
FOLDER_ID="sync-files"

# Build the device list for the folder (all devices including self)
DEVICE_JSON="$(echo "$UPDATED_CONFIG" | python3 -c "
import sys, json
config = json.load(sys.stdin)
devices = [{'deviceID': dev_id, 'introducedBy': '', 'encryptionPassword': ''}
           for dev_id in config.get('devices', {}).values()]
print(json.dumps(devices))
")"

# Check if folder already exists
if api GET "/rest/config/folders/${FOLDER_ID}" &>/dev/null; then
  # Update existing folder to include all devices
  EXISTING_FOLDER="$(api GET "/rest/config/folders/${FOLDER_ID}")"
  UPDATED_FOLDER="$(echo "$EXISTING_FOLDER" | python3 -c "
import sys, json
folder = json.load(sys.stdin)
new_devices = json.loads('${DEVICE_JSON}')
existing_ids = {d['deviceID'] for d in folder.get('devices', [])}
for d in new_devices:
    if d['deviceID'] not in existing_ids:
        folder['devices'].append(d)
print(json.dumps(folder))
")"
  api PUT "/rest/config/folders/${FOLDER_ID}" -d "$UPDATED_FOLDER"
  info "  sync-files: updated with all devices"
else
  # Create new folder
  api PUT "/rest/config/folders/${FOLDER_ID}" \
    -d "{
      \"id\": \"${FOLDER_ID}\",
      \"label\": \"sync-files\",
      \"path\": \"${SYNC_FOLDER}\",
      \"type\": \"sendreceive\",
      \"devices\": ${DEVICE_JSON},
      \"fsWatcherEnabled\": true,
      \"fsWatcherDelayS\": 10
    }"
  info "  sync-files: created and shared with all devices"
fi

# ─── Summary ───
echo ""
echo "═══════════════════════════════════════════════"
echo "  Syncthing setup complete!"
echo ""
echo "  Device:    $MY_NAME"
echo "  Device ID: $MY_DEVICE_ID"
echo "  Folder:    $SYNC_FOLDER"
echo "  Web UI:    $SYNCTHING_API"
echo ""
echo "  Network config stored in 1Password:"
echo "    Vault: $OP_VAULT"
echo "    Item:  $OP_ITEM_NAME"
echo ""
echo "  NOTE: Remote devices must also accept this"
echo "  device. Run this script on each device or"
echo "  accept in the web UI."
echo "═══════════════════════════════════════════════"
