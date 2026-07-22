# cloudpc-agent

Prototype for adding CLI and Web Chat entry points to an existing Windows 365
Cloud PC:

```text
cloudpc pwsh  -> Azure Dev Tunnel -> Windows OpenSSH -> psmux -> PowerShell
cloudpc bash  -> Azure Dev Tunnel -> WSL OpenSSH     -> tmux  -> Bash
cloudpc agent -> Azure Dev Tunnel -> Web Chat        -> Copilot CLI
```

The graphical Windows 365 session remains available. These additional paths let
developers use native Windows and Linux terminals, and let other users delegate
work through a browser.

> [!WARNING]
> This is a single-user demo prototype, not a production service. Azure Dev
> Tunnels is a development transport, Web Chat auto-approves Copilot CLI tool
> calls, and Web Chat history is stored only in memory. Use a test Cloud PC and
> do not expose the tunnel anonymously.

## Choose a test path

Most testers only need Web Chat. Use the Web Chat-only path unless terminal
access is part of the evaluation.

| Path | Installs |
| --- | --- |
| **Web Chat-only (recommended)** | Node.js, Copilot CLI, Azure Dev Tunnel, Web Chat |
| Full CLI + Web Chat | Everything above plus OpenSSH, WSL, psmux, and tmux |

**Web Chat-only does not install or require OpenSSH, WSL, psmux, or tmux.**

### Fast Web Chat-only setup

On the Cloud PC:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1 -Server -WebOnly
```

On the client, use the command printed by the Cloud PC:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1 -Client -WebOnly `
  -Name '<cloud-pc-name>' `
  -TunnelId '<full-tunnel-id.cluster>'

cloudpc agent
```

Continue with the full setup below only when PowerShell or WSL terminal access
must also be tested.

## What the test covers

- selecting a configured Cloud PC profile;
- connecting from a local terminal without streaming the full desktop;
- persistent PowerShell sessions through psmux;
- persistent WSL/Bash sessions through tmux;
- Web Chat backed by Copilot CLI on the Cloud PC;
- experimental Entra-gated Web Terminal backed by persistent PowerShell;
- multiple independent Cloud PC profiles.

## Prerequisites

### Windows 365 Cloud PC (full CLI + Web Chat)

- Windows 11 Cloud PC with administrator access;
- a corporate tenant domain account and password for Windows SSH;
- Windows PowerShell 5.1 or PowerShell 7;
- WinGet;
- permission to install Windows OpenSSH, Node.js, Copilot CLI, WSL, Ubuntu,
  tmux, and the Azure Dev Tunnels CLI;
- a Microsoft or GitHub identity that can create a private Azure Dev Tunnel;
- a GitHub Copilot subscription and permission to authenticate Copilot CLI;
- outbound access to GitHub, WinGet, Azure Dev Tunnels, and Copilot services.

### Client PC (full CLI + Web Chat)

- Windows 10 or Windows 11;
- PowerShell;
- OpenSSH Client;
- WinGet;
- the same Microsoft or GitHub identity used to access the private Dev Tunnel.

The Cloud PC and client can be the same machine for initial validation, but the
intended test uses a separate Windows client.

> [!IMPORTANT]
> The full CLI path requires Windows SSH authentication with the corporate
> domain account and password. Configure the Windows SSH user as its UPN, such as
> `user@tenant.example`. Do not use a local Windows account, SSH key, or personal
> Microsoft account. WSL authentication is separate and uses the selected Linux
> user's password.

## Get the source

The tester must first accept the invitation to the private GitHub repository.
Clone the repository on both the Cloud PC and client:

```powershell
git clone https://github.com/ww4yne/cloudpc-agent.git
Set-Location .\cloudpc-agent
```

Do not place secrets, tunnel tokens, or profile files in the repository.
Runtime state is written under `%USERPROFILE%\.cloudpc-agent`.

## Configure the Cloud PC

Open an **elevated PowerShell** in the repository checkout:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1 -Server -Distro Ubuntu
```

The installer is resumable. It:

- installs Node.js and Copilot CLI when missing;
- installs and configures Windows OpenSSH on loopback only;
- installs psmux;
- installs or detects WSL and Ubuntu;
- configures WSL OpenSSH and tmux;
- creates or reuses a private Azure Dev Tunnel;
- publishes the Windows SSH, WSL SSH, and Web Chat channels;
- authenticates Copilot CLI;
- registers background tasks for the tunnel host and Web Chat;
- verifies the required services.

If WSL requests a reboot:

1. Restart the Cloud PC.
2. Launch Ubuntu once and complete its first-run user setup.
3. Return to the repository in an elevated PowerShell.
4. Run the same server command again.

If the WSL user does not have a password, set one from elevated PowerShell:

```powershell
$linuxUser = (wsl.exe -d Ubuntu -- whoami).Trim()
wsl.exe -d Ubuntu -u root -- passwd $linuxUser
```

At completion, record the values printed by the installer:

```text
Tunnel ID
Windows SSH user
WSL SSH user
Suggested client install command
```

The Windows SSH user must be the corporate tenant account in UPN form, for
example `user@tenant.example`, rather than a local account or SSH key.

## Verify the Cloud PC

Run:

```powershell
.\install.ps1 -Status
```

Expected:

```text
PublishedPorts    : 22, 2222, 8787
HostConnections   : 1
CloudPcAgentReady : True
```

Optional component checks:

```powershell
Get-Service sshd
Get-NetTCPConnection -State Listen -LocalPort 22,8787
Test-NetConnection 127.0.0.1 -Port 2222
wsl.exe -d Ubuntu -- sh -lc "systemctl is-active ssh; tmux -V"
Invoke-RestMethod http://127.0.0.1:8787/api/health
```

Windows OpenSSH and Web Chat should listen only on loopback. Do not add a public
inbound firewall rule for these services.

## Configure the client

Open PowerShell in the client checkout and run the command printed by the
Cloud PC installer:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1 -Client `
  -Name '<cloud-pc-name>' `
  -TunnelId '<full-tunnel-id.cluster>' `
  -WindowsSshUser '<user@tenant.example>' `
  -LinuxSshUser '<wsl-user>'
```

The installer:

- installs Azure Dev Tunnels CLI when missing;
- signs in to Azure Dev Tunnels when required;
- creates an isolated client profile;
- installs the `cloudpc` command under `%USERPROFILE%\bin`;
- makes the new profile active.

If `%USERPROFILE%\bin` is not already on `PATH`, reopen PowerShell after the
installer completes.

## Test flow

### Confirm the profile and connection

```powershell
cloudpc list
cloudpc status
```

`cloudpc status` displays the active profile and local forwarded ports. The
local ports can change between connector sessions; callers should not assume
fixed client-side port numbers.

### Test PowerShell and psmux

```powershell
cloudpc pwsh -Session demo
```

After entering the Windows SSH password:

```powershell
$env:COMPUTERNAME
copilot
```

Start a visible Copilot task, close the local Terminal window, then reconnect:

```powershell
cloudpc pwsh -Session demo
```

The same psmux-owned PowerShell and Copilot CLI session should reappear.

### Test WSL, Bash, and tmux

```powershell
cloudpc bash -Session demo
```

After entering the WSL SSH password:

```bash
hostname
uname -a
git --version
node --version
python3 --version
copilot
```

Close the client terminal and rerun the same `cloudpc bash -Session demo`
command. The tmux-owned Bash and Copilot CLI session should reappear.

### Test Web Chat

```powershell
cloudpc agent
```

The command opens Web Chat in an Edge app window. Create a task such as:

```text
Collect the Cloud PC hostname, Windows version, current time, and free disk
space. Create a self-contained HTML report in my OneDrive folder. Do not include
usernames, tenant information, tunnel IDs, URLs, or secrets.
```

The task runs on the Cloud PC. If the Cloud PC and client use the same OneDrive
account, the generated artifact should synchronize naturally to the client.

### Test Web Terminal

Open `cloudpc agent`, then select **Terminal**. The browser is authenticated by
the private Azure Dev Tunnel and sends PowerShell commands over HTTPS/SSE to a
persistent PowerShell process on the Cloud PC.

This dependency-free demo supports normal PowerShell commands and noninteractive
Copilot CLI prompt mode. It doesn't yet provide ConPTY, full terminal escape
handling, or the interactive Copilot CLI TUI.

## Multiple Cloud PCs

Each Cloud PC is stored as an independent local profile:

```powershell
cloudpc list
cloudpc use <profile>
cloudpc pwsh
cloudpc bash
cloudpc agent
```

An action can also target a profile without changing the active profile:

```powershell
cloudpc pwsh <profile> -Session project-a
cloudpc bash <profile> -Session project-a
cloudpc agent <profile>
```

If the active profile's tunnel is offline, the client presents profile-aware
target choices. It does not silently rebind a profile to another Cloud PC.

## Commands

| Command | Purpose |
| --- | --- |
| `cloudpc pwsh [-Session name]` | Open or reattach a Windows psmux session |
| `cloudpc bash [-Session name]` | Open or reattach a WSL tmux session |
| `cloudpc agent` | Open Web Chat |
| `cloudpc status` | Show active profile and connector status |
| `cloudpc list` | List configured Cloud PC profiles |
| `cloudpc use <profile>` | Change the active profile |
| `cloudpc reconnect` | Restart only the local Dev Tunnel connector |
| `cloudpc disconnect` | Stop only the local Dev Tunnel connector |

`reconnect` and `disconnect` do not restart the Cloud PC or stop remote
psmux/tmux sessions.

## Troubleshooting

### `cloudpc` is not recognized

Reopen PowerShell. Confirm `%USERPROFILE%\bin` is on `PATH` and contains
`cloudpc.cmd` and `cloudpc.ps1`.

### Windows SSH login fails

- Confirm the Windows SSH user is the corporate tenant UPN.
- Enter the corporate domain-account password when prompted.
- Do not use a local account, personal account, or SSH key.
- Run `.\install.ps1 -Status` on the Cloud PC.
- Confirm `Get-Service sshd` reports `Running`.
- The client intentionally disables public-key authentication and requests
  password or keyboard-interactive authentication to match tenant policy.

### WSL SSH login fails

```powershell
Test-NetConnection 127.0.0.1 -Port 2222
wsl.exe -d Ubuntu -- systemctl status ssh
```

Set the WSL user's password if required, then retry.

### Web Chat does not open

On the Cloud PC:

```powershell
Invoke-RestMethod http://127.0.0.1:8787/api/health
Get-ScheduledTask -TaskName CloudPcAgentChat
```

Then run `cloudpc reconnect` on the client.

### The configured tunnel is offline

Run the requested `cloudpc` command again. The client checks the configured
tunnel and presents explicit target choices when another known Cloud PC is
online.

## Security and limitations

- single-user, single-tenant prototype;
- private Azure Dev Tunnel only; never enable anonymous access;
- Azure Dev Tunnels is preview/dev-test technology without a production SLA;
- Web Chat has no separate application-level identity or RBAC layer;
- Web Terminal is a controlled demo shell with arbitrary command execution;
- Web Chat uses Copilot CLI `--allow-all-tools` for the controlled demo;
- Web Chat session history is lost when the Node host restarts;
- psmux and tmux protect against client disconnects, not a Cloud PC reboot;
- no durable audit, enterprise policy, permission approval, or recovery plane;
- current bootstrap depends on `ww4yne/devbox-cli` for the Windows foundation.

Use only test repositories and non-sensitive data when evaluating this
prototype.

## Development checks

```powershell
npm run check
```

The project has no runtime npm dependencies. `npm run check` validates the Node
server syntax.
