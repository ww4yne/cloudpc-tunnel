# cloudpc-agent

Fast prototype for three Windows 365 Cloud PC channels:

```text
cloudpc pwsh  -> Dev Tunnel -> Windows OpenSSH -> psmux
cloudpc bash  -> Dev Tunnel -> WSL OpenSSH     -> tmux
cloudpc agent -> private web chat -> Copilot CLI on the Cloud PC
```

The prototype is single-user and uses an existing private Microsoft Dev Tunnel.
It is intended for demos and development, not production.

## One-hour demo setup

The preferred path is the root installer.

Show the existing Cloud PC connection information at any time:

```powershell
.\install.ps1 -Status
```

On the new Cloud PC, from an **elevated** PowerShell in the synced project:

```powershell
.\install.ps1 -Server -Distro Ubuntu
```

If WSL requires a reboot, restart Windows, finish Ubuntu's first-run user setup,
then run the same command again. The script is resumable and skips completed
steps.

On the client:

```powershell
.\install.ps1 -Client -Name '<cloud-pc-name>' `
  -TunnelId '<full-id.cluster>' -WindowsSshUser 'DOMAIN\user' `
  -LinuxSshUser '<wsl-user>'
```

The detailed manual sequence below is retained for troubleshooting.

### 1. Prepare the Cloud PC

Open an elevated PowerShell:

```powershell
winget install --id OpenJS.NodeJS.LTS -e
winget install --id GitHub.Copilot -e
wsl --install -d Ubuntu
```

Restart Windows if WSL requests it, then update WSL:

```powershell
wsl --update
```

Install the current secure Windows terminal foundation:

```powershell
irm https://raw.githubusercontent.com/ww4yne/devbox-cli/main/install.ps1 | iex
```

Choose **Server** and record the complete private tunnel ID, including its
cluster suffix.

This bootstrap installs/configures Windows OpenSSH, psmux, and Dev Tunnel. On a
Windows 365 Cloud PC it currently disables guest hibernation so the tunnel
remains reachable without Windows App. This is a demo/personal-tool behavior,
not the intended long-term product lifecycle model.

Authenticate Copilot CLI on the Cloud PC:

```powershell
copilot login
```

### 2. Configure WSL and Agent Chat

From the local source checkout:

```powershell
.\scripts\setup-host.ps1 -TunnelId <full-tunnel-id> -Distro Ubuntu
.\scripts\start-host.ps1 -Distro Ubuntu
```

The setup script:

- configures WSL OpenSSH on port 2222;
- installs/enables tmux and sshd inside the selected WSL distro;
- publishes tunnel ports 2222 and 8787;
- verifies Node.js and Copilot CLI for Agent Chat.

If the WSL user does not already have an SSH password:

```powershell
$linuxUser = wsl.exe -d Ubuntu -- whoami
wsl.exe -d Ubuntu -u root -- passwd $linuxUser
```

After adding ports, restart the existing Dev Tunnel host task so it reloads the
port set:

```powershell
$task = Get-ScheduledTask -TaskName 'DevboxCliHost-*'
$task | Stop-ScheduledTask
$task | Start-ScheduledTask
```

### 3. Verify the Cloud PC

```powershell
.\scripts\show-connection.ps1
Get-NetTCPConnection -State Listen -LocalPort 22,8787
Test-NetConnection 127.0.0.1 -Port 2222
wsl.exe -d Ubuntu -- sh -lc "systemctl is-active ssh; tmux -V; ss -ltn | grep ':2222 '"
Invoke-RestMethod http://127.0.0.1:8787/api/health
devtunnel port list <full-tunnel-id>
devtunnel show <full-tunnel-id>
```

Expected ports:

| Port | Service |
|---:|---|
| 22 | Windows OpenSSH |
| 2222 | WSL OpenSSH |
| 8787 | Agent Chat |

### 4. Configure the client

On the client:

```powershell
.\scripts\install-client.ps1 -TunnelId <full-tunnel-id> `
  -WindowsSshUser 'DOMAIN\user' -LinuxSshUser '<wsl-user>'

cloudpc pwsh
cloudpc bash
cloudpc agent
cloudpc status
cloudpc reconnect
cloudpc disconnect
cloudpc list
cloudpc use <name>
```

On Windows, `cloudpc agent` opens Agent Chat in Edge app mode for a clean,
browser-chrome-free workspace.

`reconnect` and `disconnect` affect only the local Dev Tunnel connector. They
never restart or stop the Cloud PC, remote agent, or persistent sessions.

Multiple Cloud PCs are stored as independent profiles:

```powershell
cloudpc list
cloudpc use engineering
cloudpc pwsh
cloudpc bash testbox
cloudpc agent testbox
cloudpc pwsh -Session project-a
cloudpc bash -Session project-a
```

## Agent Chat implementation

The web service has no npm dependencies. It runs Copilot CLI in prompt mode:

```text
copilot --prompt ... --session-id ... --output-format json --stream on
```

The browser composes text locally, submits one request, receives structured
events over SSE, and can reconnect to the in-memory session history. Copilot
remote export/control is explicitly disabled.

For the demo, tool calls are auto-approved with `--allow-all-tools`. This is not
the final enterprise permission model.

## Current limitations

- Single Cloud PC and single user.
- Dev Tunnel preview/dev-test transport.
- Agent Chat history is retained only while the Node host process is running.
- No Entra/RBAC control plane beyond private Dev Tunnel access.
- No terminal/web handoff for the same Copilot session.
- WSL lifecycle still depends on the Windows host starting the distro.

The selected WSL user must have either a password or an authorized SSH key.
For the fastest clean-machine demo, set a password from an elevated PowerShell:

```powershell
wsl.exe -d Ubuntu -u root -- passwd <wsl-user>
```
