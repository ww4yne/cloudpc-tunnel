#!/bin/sh
set -eu

CONFIG_DIR="${CLOUDPC_TUNNEL_HOME:-$HOME/.cloudpc-tunnel}"
PROFILES_DIR="$CONFIG_DIR/profiles"
ACTIVE_FILE="$CONFIG_DIR/active-profile"
BIN_DIR="${CLOUDPC_TUNNEL_BIN:-$HOME/.local/bin}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

read_text() {
  prompt="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
  else
    printf '%s: ' "$prompt" >/dev/tty
  fi
  IFS= read -r value </dev/tty || value=""
  [ -n "$value" ] && printf '%s\n' "$value" || printf '%s\n' "$default"
}

read_yes_no() {
  prompt="$1"
  default="${2:-n}"
  while :; do
    printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
    IFS= read -r value </dev/tty || value=""
    [ -z "$value" ] && value="$default"
    case "$value" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) echo "Enter y or n." >/dev/tty ;;
    esac
  done
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

echo "cloudpc-tunnel client setup"
echo "This installer configures a macOS/Linux client profile."

require python3
require ssh
require devtunnel

name="$(read_text 'Profile name' "${HOSTNAME:-cloudpc}")"
tunnel_id="$(read_text 'Full Dev Tunnel ID with cluster suffix')"
windows_user="$(read_text 'Windows SSH user, blank to skip Windows SSH')"
linux_user="$(read_text 'WSL SSH user, blank to skip WSL SSH')"
agent_port="$(read_text 'Web Chat host port, 0 to disable' '8787')"

tmp_base="${TMPDIR:-/tmp}"
channels_file="$(mktemp "${tmp_base%/}/cpctunnel.XXXXXX")"
trap 'rm -f "$channels_file"' EXIT
python3 - "$channels_file" "$name" "$tunnel_id" "$windows_user" "$linux_user" "$agent_port" <<'PY'
import json, sys
path, name, tunnel_id, windows_user, linux_user, agent_port = sys.argv[1:]
channels = []
if windows_user:
    channels.append({
        "Name": "windows-ssh",
        "Kind": "ssh-windows",
        "HostPort": 22,
        "User": windows_user,
        "Session": "cpctunnel",
        "IdentityFile": "",
        "HostKeyAlias": f"cpctunnel-{name}-windows-ssh",
    })
if linux_user:
    channels.append({
        "Name": "wsl-ssh",
        "Kind": "ssh-linux",
        "HostPort": 2222,
        "User": linux_user,
        "Session": "cpctunnel",
        "IdentityFile": "",
        "HostKeyAlias": f"cpctunnel-{name}-wsl-ssh",
    })
if int(agent_port or "0") > 0:
    channels.append({
        "Name": "web-chat",
        "Kind": "http",
        "HostPort": int(agent_port),
        "User": "",
        "Session": "",
        "IdentityFile": "",
        "HostKeyAlias": f"cpctunnel-{name}-web-chat",
    })
json.dump(channels, open(path, "w", encoding="utf-8"))
PY

while read_yes_no 'Add a custom TCP channel?' n; do
  channel_name="$(read_text 'Channel name')"
  channel_port="$(read_text 'Cloud PC host port')"
  channel_kind="$(read_text 'Kind label' 'tcp')"
  python3 - "$channels_file" "$name" "$channel_name" "$channel_port" "$channel_kind" <<'PY'
import json, sys
path, profile, name, port, kind = sys.argv[1:]
channels = json.load(open(path, encoding="utf-8"))
channels.append({
    "Name": name,
    "Kind": kind,
    "HostPort": int(port),
    "User": "",
    "Session": "",
    "IdentityFile": "",
    "HostKeyAlias": f"cpctunnel-{profile}-{name}",
})
json.dump(channels, open(path, "w", encoding="utf-8"))
PY
done

mkdir -p "$PROFILES_DIR" "$BIN_DIR"
profile_file="$PROFILES_DIR/$name.json"
python3 - "$profile_file" "$channels_file" "$name" "$tunnel_id" "$windows_user" "$linux_user" "$agent_port" <<'PY'
import json, sys
profile_file, channels_file, name, tunnel_id, windows_user, linux_user, agent_port = sys.argv[1:]
channels = json.load(open(channels_file, encoding="utf-8"))
profile = {
    "SchemaVersion": 2,
    "Name": name,
    "TunnelId": tunnel_id,
    "CommandName": "cpctunnel",
    "HostKeyAliasPrefix": "cpctunnel",
    "Transports": ["devtunnel"],
    "WindowsSshUser": windows_user,
    "LinuxSshUser": linux_user,
    "WindowsSession": "cpctunnel",
    "LinuxSession": "cpctunnel",
    "WindowsSshPort": 22 if windows_user else 0,
    "LinuxSshPort": 2222 if linux_user else 0,
    "AgentChatPort": int(agent_port or "0"),
    "WindowsIdentityFile": "",
    "LinuxIdentityFile": "",
    "Channels": channels,
}
json.dump(profile, open(profile_file, "w", encoding="utf-8"), indent=2)
PY
printf '%s\n' "$name" >"$ACTIVE_FILE"
cp "$SCRIPT_DIR/src/cpctunnel.sh" "$BIN_DIR/cpctunnel"
chmod +x "$BIN_DIR/cpctunnel"

echo "Installed cpctunnel to $BIN_DIR"
echo "Active profile: $name"
echo "If needed, add $BIN_DIR to PATH."
