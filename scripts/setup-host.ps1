[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TunnelId,
    [string]$Distro = 'Ubuntu',
    [int]$WslSshPort = 2222,
    [int]$AgentChatPort = 8787
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

function Invoke-WslRoot([string]$Script) {
    # Pass a single ASCII-safe argument to WSL. Direct multiline `bash -lc`
    # invocation from Windows PowerShell can preserve CRLFs and split quoting.
    $normalized = $Script.Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    $encoded = [Convert]::ToBase64String($bytes)
    $command = "printf '%s' '$encoded' | base64 -d | bash"
    & wsl.exe -d $Distro -u root -- bash -lc $command
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed with exit code $LASTEXITCODE"
    }
}

Write-Host 'Checking host prerequisites...' -ForegroundColor Cyan
if (-not (Get-Command devtunnel -ErrorAction SilentlyContinue)) {
    throw 'devtunnel CLI is required. Install it with devbox-cli first.'
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js 20+ is required for Agent Chat.'
}
if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
    throw 'GitHub Copilot CLI is required for Agent Chat.'
}

$distros = @(& wsl.exe -l -q) | ForEach-Object { $_.Trim([char]0).Trim() } |
    Where-Object { $_ }
if ($Distro -notin $distros) {
    throw "WSL distro '$Distro' was not found. Installed: $($distros -join ', ')"
}

Write-Host "Configuring $Distro OpenSSH and tmux..." -ForegroundColor Cyan
$linuxSetup = @"
set -e
if [ "`$(ps -p 1 -o comm= | tr -d ' ')" != "systemd" ]; then
  echo "WSL systemd is not active. Update WSL or enable systemd, terminate the distro, and rerun." >&2
  exit 42
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openssh-server tmux
mkdir -p /run/sshd /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/cloudpc-agent.conf <<'EOF'
Port $WslSshPort
ListenAddress 0.0.0.0
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
systemctl enable ssh
systemctl restart ssh
cat >/usr/local/bin/cloudpc-clear-da-input <<'EOF'
#!/bin/sh
sleep 0.5
pane="`$(tmux display-message -p -t '!' '#{pane_id}' 2>/dev/null || true)"
[ -n "`$pane" ] || exit 0
command="`$(tmux display-message -p -t "`$pane" '#{pane_current_command}' 2>/dev/null || true)"
case "`$command" in
  bash|zsh|sh) tmux send-keys -t "`$pane" C-u ;;
esac
EOF
chmod 755 /usr/local/bin/cloudpc-clear-da-input
linux_user="`$(getent passwd 1000 | cut -d: -f1)"
linux_home="`$(getent passwd 1000 | cut -d: -f6)"
if [ -n "`$linux_user" ] && [ -d "`$linux_home" ]; then
  touch "`$linux_home/.tmux.conf"
  if ! grep -q 'cloudpc-clear-da-input' "`$linux_home/.tmux.conf"; then
    printf '\n# cloudpc-agent: clear delayed terminal DA replies at shell prompt\n' >>"`$linux_home/.tmux.conf"
    printf "set-hook -g client-attached 'run-shell -b /usr/local/bin/cloudpc-clear-da-input'\n" >>"`$linux_home/.tmux.conf"
  fi
  chown "`$linux_user:`$linux_user" "`$linux_home/.tmux.conf"
  touch "`$linux_home/.inputrc"
  if ! grep -q 'cloudpc-agent: ignore Windows Terminal DA replies' "`$linux_home/.inputrc"; then
    cat >>"`$linux_home/.inputrc" <<'EOF'

# cloudpc-agent: ignore Windows Terminal DA replies
"\e[?61;4;6;7;14;21;22;23;24;28;32;42;52c": ""
"\e[>0;10;1c": ""
EOF
  fi
  chown "`$linux_user:`$linux_user" "`$linux_home/.inputrc"
fi
ss -ltn | grep ':$WslSshPort '
"@
Invoke-WslRoot $linuxSetup

if (-not (Test-NetConnection 127.0.0.1 -Port $WslSshPort `
        -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    throw (
        "Windows cannot reach WSL sshd on localhost:$WslSshPort. " +
        'Update WSL and enable mirrored networking or localhost forwarding, then rerun.'
    )
}

Write-Host 'Publishing WSL SSH and Agent Chat ports...' -ForegroundColor Cyan
$portDocument = & devtunnel port list $TunnelId --json 2>$null | ConvertFrom-Json
$existing = @($portDocument.ports | ForEach-Object { [int]$_.portNumber })
foreach ($port in @($WslSshPort, $AgentChatPort)) {
    if ($port -notin $existing) {
        & devtunnel port create $TunnelId --port-number $port --protocol auto `
            --description $(if ($port -eq $WslSshPort) { 'WSL OpenSSH' } else { 'Cloud PC Agent Chat' })
        if ($LASTEXITCODE -ne 0) { throw "Failed to publish port $port" }
    }
}

Write-Host ''
Write-Host 'Host setup complete.' -ForegroundColor Green
Write-Host "Start Agent Chat:"
Write-Host "  Set-Location '$projectRoot'"
Write-Host "  node .\src\server.mjs"
Write-Host ''
Write-Host 'Restart the existing Dev Tunnel host if the new ports are not picked up.'
