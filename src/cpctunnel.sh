#!/bin/sh
set -eu

CONFIG_DIR="${CLOUDPC_TUNNEL_HOME:-$HOME/.cloudpc-tunnel}"
PROFILES_DIR="$CONFIG_DIR/profiles"
ACTIVE_FILE="$CONFIG_DIR/active-profile"

usage() {
  cat <<'EOF'
Usage:
  cpctunnel list
  cpctunnel use <profile>
  cpctunnel status [profile]
  cpctunnel reconnect [profile]
  cpctunnel disconnect [profile]
  cpctunnel logs [profile]
  cpctunnel pwsh [profile]
  cpctunnel bash [profile]
  cpctunnel agent [profile]
  cpctunnel port <channel> [profile]
  cpctunnel open <channel> [profile]

macOS/Linux client support requires devtunnel and OpenSSH tools.
EOF
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

active_profile() {
  [ -f "$ACTIVE_FILE" ] && sed -n '1p' "$ACTIVE_FILE" || true
}

profile_file() {
  printf '%s/profiles/%s.json\n' "$CONFIG_DIR" "$1"
}

json_value() {
  python3 -c 'import json,sys
data=json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2].split("."):
    data=data[key]
print(data)' "$1" "$2"
}

channel_value() {
  python3 -c 'import json,sys
data=json.load(open(sys.argv[1], encoding="utf-8"))
name=sys.argv[2]
field=sys.argv[3]
for channel in data.get("Channels", []):
    if channel.get("Name") == name:
        print(channel.get(field, ""))
        raise SystemExit(0)
print("", file=sys.stderr)
raise SystemExit(2)' "$1" "$2" "$3"
}

profile_or_default() {
  profile="${1:-}"
  if [ -z "$profile" ]; then
    profile="$(active_profile)"
  fi
  if [ -z "$profile" ]; then
    count="$(find "$PROFILES_DIR" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" = "1" ]; then
      profile="$(basename "$(find "$PROFILES_DIR" -name '*.json' -type f | sed -n '1p')" .json)"
    fi
  fi
  [ -n "$profile" ] || {
    echo "No active cloudpc-tunnel profile. Run 'cpctunnel list' or install a client profile." >&2
    exit 1
  }
  [ -f "$(profile_file "$profile")" ] || {
    echo "Profile not found: $profile" >&2
    exit 1
  }
  printf '%s\n' "$profile"
}

state_dir() {
  printf '%s/state/%s\n' "$CONFIG_DIR" "$1"
}

pid_file() {
  printf '%s/connector.pid\n' "$(state_dir "$1")"
}

out_log() {
  printf '%s/connector.out.log\n' "$(state_dir "$1")"
}

err_log() {
  printf '%s/connector.err.log\n' "$(state_dir "$1")"
}

is_running() {
  profile="$1"
  pid_path="$(pid_file "$1")"
  [ -f "$pid_path" ] || return 1
  pid="$(cat "$pid_path")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  profile_json="$(profile_file "$profile")"
  tunnel_id="$(json_value "$profile_json" TunnelId 2>/dev/null || true)"
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in
    *devtunnel*connect*"$tunnel_id"*) return 0 ;;
  esac
  rm -f "$pid_path"
  return 1
}

stop_connector() {
  profile="$1"
  if is_running "$profile"; then
    kill "$(cat "$(pid_file "$profile")")" 2>/dev/null || true
  fi
  rm -f "$(pid_file "$profile")"
}

start_connector() {
  profile="$1"
  require devtunnel
  connector_profile_json="$(profile_file "$profile")"
  tunnel_id="$(json_value "$connector_profile_json" TunnelId)"
  mkdir -p "$(state_dir "$profile")"
  if is_running "$profile"; then
    return
  fi
  : >"$(out_log "$profile")"
  : >"$(err_log "$profile")"
  devtunnel connect "$tunnel_id" >"$(out_log "$profile")" 2>"$(err_log "$profile")" &
  echo "$!" >"$(pid_file "$profile")"
  i=0
  while [ "$i" -lt 120 ]; do
    grep -Eq 'Forwarding from[[:space:]]+127\.0\.0\.1:[0-9]+' "$(out_log "$profile")" "$(err_log "$profile")" 2>/dev/null && return
    if grep -Eiq 'login required|not logged|not authenticated' "$(out_log "$profile")" "$(err_log "$profile")" 2>/dev/null; then
      echo "Dev Tunnels login is required. Run: devtunnel user login" >&2
      exit 1
    fi
    sleep 0.5
    i=$((i + 1))
  done
  tail -n 60 "$(out_log "$profile")" "$(err_log "$profile")" 2>/dev/null || true
  echo "Connector did not become ready." >&2
  exit 1
}

local_port() {
  profile="$1"
  host_port="$2"
  sed -nE "s/.*Forwarding from[[:space:]]+127\\.0\\.0\\.1:([0-9]+)[[:space:]]+to host port[[:space:]]+$host_port([^0-9].*)?$/\\1/p" \
    "$(out_log "$profile")" "$(err_log "$profile")" 2>/dev/null | tail -n 1
}

ensure_channel_port() {
  profile="$1"
  channel="$2"
  file="$(profile_file "$profile")"
  host_port="$(channel_value "$file" "$channel" HostPort)"
  start_connector "$profile"
  i=0
  while [ "$i" -lt 120 ]; do
    port="$(local_port "$profile" "$host_port")"
    if [ -n "$port" ]; then
      printf '%s\n' "$port"
      return
    fi
    sleep 0.5
    i=$((i + 1))
  done
  echo "No local port found for channel: $channel" >&2
  exit 1
}

ssh_channel() {
  profile="$1"
  channel="$2"
  remote="$3"
  port="$(ensure_channel_port "$profile" "$channel")"
  ssh_profile_json="$(profile_file "$profile")"
  user="$(channel_value "$ssh_profile_json" "$channel" User)"
  alias="$(channel_value "$ssh_profile_json" "$channel" HostKeyAlias)"
  identity="$(channel_value "$ssh_profile_json" "$channel" IdentityFile || true)"
  [ -n "$user" ] || { echo "Channel has no SSH user: $channel" >&2; exit 1; }
  known_hosts="$(state_dir "$profile")/known_hosts"
  args="-tt -p $port -l $user -o HostKeyAlias=$alias -o CheckHostIP=no -o UserKnownHostsFile=$known_hosts -o StrictHostKeyChecking=ask -o ServerAliveInterval=15 -o ServerAliveCountMax=3"
  if [ -n "$identity" ]; then
    # shellcheck disable=SC2086
    ssh $args -i "$identity" -o IdentitiesOnly=yes 127.0.0.1 "$remote"
  else
    # shellcheck disable=SC2086
    ssh $args -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=3 127.0.0.1 "$remote"
  fi
}

cmd="${1:-pwsh}"
shift 2>/dev/null || true

case "$cmd" in
  help|-h|--help)
    usage
    ;;
  list)
    active="$(active_profile)"
    for file in "$PROFILES_DIR"/*.json; do
      [ -f "$file" ] || continue
      name="$(basename "$file" .json)"
      mark=" "
      [ "$name" = "$active" ] && mark="*"
      tunnel="$(json_value "$file" TunnelId)"
      printf '%s %s %s\n' "$mark" "$name" "$tunnel"
    done
    ;;
  use)
    profile="${1:-}"
    [ -n "$profile" ] || { echo "Usage: cpctunnel use <profile>" >&2; exit 1; }
    [ -f "$(profile_file "$profile")" ] || { echo "Profile not found: $profile" >&2; exit 1; }
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' "$profile" >"$ACTIVE_FILE"
    echo "Active cloudpc-tunnel profile: $profile"
    ;;
  reconnect)
    profile="$(profile_or_default "${1:-}")"
    stop_connector "$profile"
    start_connector "$profile"
    ;;
  disconnect)
    profile="$(profile_or_default "${1:-}")"
    stop_connector "$profile"
    ;;
  logs)
    profile="$(profile_or_default "${1:-}")"
    tail -n 100 -f "$(out_log "$profile")" "$(err_log "$profile")"
    ;;
  status)
    profile="$(profile_or_default "${1:-}")"
    start_connector "$profile"
    status_profile_json="$(profile_file "$profile")"
    python3 -c 'import json,sys
path=sys.argv[1]
data=json.load(open(path, encoding="utf-8"))
if not isinstance(data, dict):
    raise SystemExit(f"invalid profile file: {path}. Remove ~/.cloudpc-tunnel and rerun install.sh.")
print("Profile:", data["Name"])
print("TunnelId:", data["TunnelId"])
for ch in data.get("Channels", []):
    print("{} {} host:{}".format(ch.get("Name"), ch.get("Kind"), ch.get("HostPort")))' "$status_profile_json"
    ;;
  pwsh)
    profile="$(profile_or_default "${1:-}")"
    ssh_channel "$profile" windows-ssh 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { '\''pwsh.exe'\'' } else { '\''powershell.exe'\'' }; psmux new-session -A -s cpctunnel -- $shell"'
    ;;
  bash)
    profile="$(profile_or_default "${1:-}")"
    ssh_channel "$profile" wsl-ssh "tmux source-file ~/.tmux.conf 2>/dev/null || true; exec env TERM=xterm-256color tmux -u new-session -A -s cpctunnel"
    ;;
  agent)
    profile="$(profile_or_default "${1:-}")"
    endpoint="$("$0" port web-chat "$profile")"
    url="http://$endpoint"
    if command -v open >/dev/null 2>&1; then open "$url"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url"
    else echo "$url"
    fi
    ;;
  port)
    channel="${1:-}"
    profile="$(profile_or_default "${2:-}")"
    [ -n "$channel" ] || { echo "Usage: cpctunnel port <channel> [profile]" >&2; exit 1; }
    port="$(ensure_channel_port "$profile" "$channel")"
    printf '127.0.0.1:%s\n' "$port"
    ;;
  open)
    channel="${1:-}"
    profile="$(profile_or_default "${2:-}")"
    endpoint="$("$0" port "$channel" "$profile")"
    url="http://$endpoint"
    if command -v open >/dev/null 2>&1; then open "$url"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url"
    else echo "$url"
    fi
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
