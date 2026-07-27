#!/bin/sh
set -eu

CONFIG_DIR="${CLOUDPC_TUNNEL_HOME:-$HOME/.cloudpc-tunnel}"
PROFILES_DIR="$CONFIG_DIR/profiles"
ACTIVE_FILE="$CONFIG_DIR/active-profile"
BIN_DIR="${CLOUDPC_TUNNEL_BIN:-$HOME/.local/bin}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
name=""
tunnel_id=""
windows_user=""
linux_user=""
windows_identity_file=""
linux_identity_file=""
agent_port="8787"
tcp_channels=""
devtunnel_login="microsoft"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --tunnel-id) tunnel_id="$2"; shift 2 ;;
    --windows-ssh-user) windows_user="$2"; shift 2 ;;
    --linux-ssh-user) linux_user="$2"; shift 2 ;;
    --windows-identity-file) windows_identity_file="$2"; shift 2 ;;
    --linux-identity-file) linux_identity_file="$2"; shift 2 ;;
    --agent-chat-port) agent_port="$2"; shift 2 ;;
    --devtunnel-login) devtunnel_login="$2"; shift 2 ;;
    --tcp-channel) tcp_channels="${tcp_channels}${tcp_channels:+
}$2"; shift 2 ;;
    -h|--help)
      echo "Usage: sh ./install.sh [--name NAME] [--tunnel-id ID] [--windows-ssh-user USER] [--windows-identity-file PATH] [--linux-ssh-user USER] [--linux-identity-file PATH] [--agent-chat-port PORT] [--devtunnel-login github|microsoft|github-device-code|microsoft-device-code] [--tcp-channel name=port[:kind]]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

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

ensure_devtunnel() {
  if command -v devtunnel >/dev/null 2>&1; then
    return
  fi

  echo "Microsoft Dev Tunnels CLI (devtunnel) is required for this client."
  if ! read_yes_no 'Install devtunnel now?' y; then
    echo "Install devtunnel and rerun this script." >&2
    echo "macOS: brew install --cask devtunnel" >&2
    echo "macOS/Linux: curl -sL https://aka.ms/DevTunnelCliInstall | bash" >&2
    exit 1
  fi

  if command -v brew >/dev/null 2>&1; then
    brew install --cask devtunnel
  else
    require curl
    curl -sL https://aka.ms/DevTunnelCliInstall | bash
  fi

  if ! command -v devtunnel >/dev/null 2>&1; then
    echo "devtunnel was installed but is not on PATH. Open a new shell or add it to PATH, then rerun this script." >&2
    exit 1
  fi
}

ensure_devtunnel_login() {
  user_output="$(devtunnel user show 2>&1 || true)"
  provider_ok=0
  case "$devtunnel_login" in
    github|github-device-code)
      printf '%s\n' "$user_output" | grep -Eiq 'using GitHub|GitHub' && provider_ok=1
      ;;
    microsoft|microsoft-device-code)
      if printf '%s\n' "$user_output" | grep -Eiq 'using Microsoft|Microsoft|Entra'; then
        provider_ok=1
      fi
      ;;
  esac
  case "$user_output" in
    *"login required"*|*"Login required"*|*"not logged"*|*"Not logged"*|*"not authenticated"*|*"Not authenticated"*) ;;
    *)
      if printf '%s\n' "$user_output" | grep -Eiq 'logged in|user|username|account|entra|github|microsoft'; then
        if [ "$provider_ok" = "1" ]; then
          return
        fi
        echo "Current Dev Tunnels login does not match requested provider '$devtunnel_login'. Switching login."
        devtunnel user logout >/dev/null 2>&1 || true
      fi
      ;;
  esac

  if devtunnel user show --json >/dev/null 2>&1; then
    return
  fi

  echo "Dev Tunnels login is required. Complete the browser login flow."
  case "$devtunnel_login" in
    github) devtunnel user login -g ;;
    microsoft) devtunnel user login ;;
    github-device-code) devtunnel user login -g -d ;;
    microsoft-device-code) devtunnel user login -d ;;
    *) echo "Unknown devtunnel login provider: $devtunnel_login" >&2; exit 1 ;;
  esac
}

echo "cloudpc-tunnel client setup"
echo "This installer configures a macOS/Linux client profile."

require python3
require ssh
ensure_devtunnel
ensure_devtunnel_login

name="${name:-$(read_text 'Profile name' "${HOSTNAME:-cloudpc}")}"
tunnel_id="${tunnel_id:-$(read_text 'Full Dev Tunnel ID with cluster suffix')}"
windows_user="${windows_user:-$(read_text 'Windows SSH user, blank to skip Windows SSH')}"
if [ -n "$windows_user" ] && [ -z "$windows_identity_file" ]; then
  windows_identity_file="$(read_text 'Windows SSH private key path, blank for password auth')"
fi
linux_user="${linux_user:-$(read_text 'WSL SSH user, blank to skip WSL SSH')}"
if [ -n "$linux_user" ] && [ -z "$linux_identity_file" ]; then
  linux_identity_file="$(read_text 'WSL SSH private key path, blank for password auth')"
fi
agent_port="${agent_port:-$(read_text 'Web Chat host port, 0 to disable' '8787')}"

tmp_base="${TMPDIR:-/tmp}"
channels_file="$(mktemp "${tmp_base%/}/cpctunnel.XXXXXX")"
trap 'rm -f "$channels_file"' EXIT
python3 - "$channels_file" "$name" "$tunnel_id" "$windows_user" "$linux_user" "$agent_port" "$windows_identity_file" "$linux_identity_file" <<'PY'
import json, sys
path, name, tunnel_id, windows_user, linux_user, agent_port, windows_identity_file, linux_identity_file = sys.argv[1:]
channels = []
if windows_user:
    channels.append({
        "Name": "windows-ssh",
        "Kind": "ssh-windows",
        "HostPort": 22,
        "User": windows_user,
        "Session": "cpctunnel",
        "IdentityFile": windows_identity_file,
        "HostKeyAlias": f"cpctunnel-{name}-windows-ssh",
    })
if linux_user:
    channels.append({
        "Name": "wsl-ssh",
        "Kind": "ssh-linux",
        "HostPort": 2222,
        "User": linux_user,
        "Session": "cpctunnel",
        "IdentityFile": linux_identity_file,
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

if [ -n "$tcp_channels" ]; then
  printf '%s\n' "$tcp_channels" | while IFS= read -r channel; do
    [ -n "$channel" ] || continue
    channel_name="$(printf '%s' "$channel" | sed -E 's/^([^:=]+).*/\1/')"
    channel_port="$(printf '%s' "$channel" | sed -E 's/^[^:=]+[:=]([0-9]+).*/\1/')"
    channel_kind="$(printf '%s' "$channel" | sed -nE 's/^[^:=]+[:=][0-9]+:([^:]+)$/\1/p')"
    channel_kind="${channel_kind:-tcp}"
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
else
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
fi

mkdir -p "$PROFILES_DIR" "$BIN_DIR"
profile_file="$PROFILES_DIR/$name.json"
python3 - "$profile_file" "$channels_file" "$name" "$tunnel_id" "$windows_user" "$linux_user" "$agent_port" "$devtunnel_login" "$windows_identity_file" "$linux_identity_file" <<'PY'
import json, sys
profile_file, channels_file, name, tunnel_id, windows_user, linux_user, agent_port, devtunnel_login, windows_identity_file, linux_identity_file = sys.argv[1:]
channels = json.load(open(channels_file, encoding="utf-8"))
profile = {
    "SchemaVersion": 2,
    "Name": name,
    "TunnelId": tunnel_id,
    "CommandName": "cpct",
    "DevTunnelLoginProvider": devtunnel_login,
    "HostKeyAliasPrefix": "cpctunnel",
    "Transports": ["devtunnel"],
    "WindowsSshUser": windows_user,
    "LinuxSshUser": linux_user,
    "WindowsSession": "cpctunnel",
    "LinuxSession": "cpctunnel",
    "WindowsSshPort": 22 if windows_user else 0,
    "LinuxSshPort": 2222 if linux_user else 0,
    "AgentChatPort": int(agent_port or "0"),
    "WindowsIdentityFile": windows_identity_file,
    "LinuxIdentityFile": linux_identity_file,
    "Channels": channels,
}
json.dump(profile, open(profile_file, "w", encoding="utf-8"), indent=2)
PY
python3 - "$profile_file" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
if not isinstance(data, dict) or not data.get("Name") or not data.get("TunnelId"):
    raise SystemExit(f"invalid profile written: {path}")
if not isinstance(data.get("Channels"), list):
    raise SystemExit(f"profile has no channel list: {path}")
PY
printf '%s\n' "$name" >"$ACTIVE_FILE"
cp "$SCRIPT_DIR/src/cpctunnel.sh" "$BIN_DIR/cpct"
chmod +x "$BIN_DIR/cpct"

echo "Installed cpct to $BIN_DIR"
echo "Active profile: $name"
echo "If needed, add $BIN_DIR to PATH."
