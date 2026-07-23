# cloudpc-tunnel

`cloudpc-tunnel` creates private developer TCP tunnels to a Windows 365 Cloud
PC. It lets a client device use local tools against services running on the
Cloud PC, including SSH, SCP, SFTP, WebSocket servers, local web apps, APIs, and
the optional Web Chat experience.

The CLI command installed by this project is:

```powershell
cpctunnel
```

## What this is for

Windows 365 gives users a Cloud PC: a complete Windows desktop experience hosted
in the Microsoft Cloud and accessible from supported client devices. The normal
Windows App or browser-based desktop connection remains the primary interactive
desktop experience.

`cloudpc-tunnel` adds a developer-oriented companion path: private TCP channels
from your client device to selected loopback services on your Cloud PC.

```text
client device
  -> private transport
  -> Windows 365 Cloud PC
  -> selected local TCP service
```

Typical uses:

- `ssh` into the Cloud PC without opening inbound firewall rules.
- Use `scp` or `sftp` through the Cloud PC's Windows or WSL OpenSSH channel.
- Open a web app, WebSocket server, API, or dev server running on the Cloud PC.
- Keep long-running PowerShell or Bash sessions alive with `psmux` or `tmux`.
- Use the optional Web Chat surface backed by tools running on the Cloud PC.

## Status

This project is intended for developer evaluation. It is not a replacement for
Windows App, Remote Desktop, Microsoft Intune management, or the Windows 365
service access model.

The implemented transport in this preview is Microsoft Dev Tunnels private
access. SSH jump host support is exposed as a planned configuration path in the
wizard, but it intentionally has no hard-coded jump host defaults.

## Architecture

```text
client device
  cpctunnel
    |
    | private TCP transport
    |   - Microsoft Dev Tunnels private access
    |   - planned SSH jump host configuration
    v
Windows 365 Cloud PC
  cloudpc-tunnel host watchdog
    |
    +-- Windows OpenSSH on loopback
    +-- WSL OpenSSH on selected port
    +-- Web Chat on loopback
    +-- custom TCP channels
```

`cloudpc-tunnel` models access as **channels**:

| Channel | Default port | Typical use |
| --- | ---: | --- |
| `windows-ssh` | `22` | PowerShell, SSH, SCP, SFTP |
| `wsl-ssh` | `2222` | Bash, SSH, SCP, SFTP |
| `web-chat` | `8787` | Browser Web Chat and Web Terminal |
| custom channel | user-selected | Web apps, WebSocket, APIs, databases, other TCP services |

SCP and SFTP do not require separate ports. They use an SSH channel.

## System requirements

`cloudpc-tunnel` has two sides: a **Cloud PC host** and a **client device**.
Install only the capabilities you plan to use.

### Supported Cloud PC host

Required for every Cloud PC host setup:

| Requirement | Details |
| --- | --- |
| Windows 365 Cloud PC | Windows 10 or Windows 11 Cloud PC. |
| Permissions | Local administrator rights are required for host setup. |
| Shell | Windows PowerShell 5.1 or PowerShell 7. |
| Package installer | WinGet is required when the installer needs to add missing tools. |
| Network | Outbound access to the selected private transport, such as Microsoft Dev Tunnels. |

Feature-specific Cloud PC requirements:

| Feature | Additional requirements |
| --- | --- |
| Microsoft Dev Tunnels transport | Microsoft Dev Tunnels CLI and an account allowed to create or access a private tunnel. |
| Windows SSH channel | Windows OpenSSH Server on port 22. The installer configures it loopback-only. |
| Windows persistent shell | `psmux`. The installer can add it when package installation is allowed. |
| WSL SSH channel | WSL, a Linux distribution such as Ubuntu, OpenSSH Server in that distribution, and a Linux user password or SSH key. |
| WSL persistent shell | `tmux` in the selected WSL distribution. |
| Web Chat | Node.js 20 or later and GitHub Copilot CLI authenticated on the Cloud PC. |
| Custom TCP channel | A service listening on the selected port on the Cloud PC. |

### Supported client device

Required for every client setup:

| Requirement | Details |
| --- | --- |
| Operating system | Windows 10/11, macOS, or Linux. |
| Shell | PowerShell on Windows; POSIX `sh` on macOS/Linux. |
| Local install path | `%USERPROFILE%\bin` on Windows; `~/.local/bin` on macOS/Linux by default. |
| Network | Outbound access to the selected private transport. |

Feature-specific client requirements:

| Scenario | Additional requirements |
| --- | --- |
| Microsoft Dev Tunnels transport | Microsoft Dev Tunnels CLI and access to the same private tunnel as the Cloud PC. The Windows installer installs the CLI with WinGet when missing; the macOS/Linux installer prompts before installing it. Microsoft/Entra device-code login is the default because it avoids stale embedded-browser token caches on Cloud PCs; browser and GitHub login are explicit options. |
| SSH / SCP / SFTP | OpenSSH client tools: `ssh`, `scp`, and `sftp`. |
| Web or WebSocket channel | A browser or client tool that can connect to `127.0.0.1:<local-port>`. |
| Web Chat | A browser. Microsoft Edge is used when available. |
| SSH jump host transport | Planned. It will require a user-provided jump host, SSH user, port, and authentication method. |

### Not required

These are intentionally not required:

- Public inbound firewall rules on the Cloud PC.
- Router port forwarding.
- Anonymous Dev Tunnel access.
- A public IP address for the Cloud PC.
- WSL, if you only need Windows SSH, Web Chat, or custom Windows TCP ports.
- Node.js or GitHub Copilot CLI, if you do not enable Web Chat.

## Quick start

Clone or download this repository on both the Cloud PC and the client device:

```powershell
git clone https://github.com/ww4yne/cloudpc-tunnel.git
Set-Location .\cloudpc-tunnel
```

Run the guided installer:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

The wizard asks what you want to configure and walks through the required
choices.

## Guided setup on the Cloud PC

Open an elevated PowerShell in the repository checkout on the Cloud PC:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

Choose:

1. **Windows 365 Cloud PC host**
2. Transport:
   - **Microsoft Dev Tunnels private access** for the recommended path.
   - **SSH jump host** only if you have your own jump host details.
3. Capabilities:
   - **Windows OpenSSH** for PowerShell, SSH, SCP, and SFTP.
   - **WSL OpenSSH** for Bash, Linux tools, SCP, and SFTP.
   - **Web Chat** for the browser-based Cloud PC work surface.
   - **Custom TCP ports** for web apps, WebSocket servers, APIs, or any other TCP service.
4. Ports:
   - Keep defaults unless you already use those ports on the Cloud PC.
   - The Windows OpenSSH channel currently uses port 22.
   - Add custom channels with a name, remote port, and kind label.

At the end, record the values printed by the installer:

```text
Cloud PC profile name
Tunnel ID
Windows SSH user
WSL SSH user
Suggested client install command
```

The tunnel ID should include its cluster suffix.
The host installer prints separate setup commands for Windows clients and
macOS/Linux clients.

## Guided setup on a Windows client device

Open PowerShell in the repository checkout on the client device:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

Choose:

1. **Client device**
2. Microsoft Dev Tunnels private access.
3. A profile name, such as `work-cloudpc`.
4. The tunnel ID printed by the Cloud PC setup.
5. SSH users and key paths if you enabled SSH channels.
The installer writes the `cpctunnel` command under `%USERPROFILE%\bin`.
Reopen PowerShell if your PATH was updated during installation.

## Multiple Cloud PCs

Each Cloud PC host keeps its own local host configuration. Hosts are not shared
between users. On a client device, install one profile per Cloud PC:

```powershell
.\install.ps1 -Client -Name cpcn3y -TunnelId <cpcn3y-tunnel> ...
.\install.ps1 -Client -Name dbxn3y -TunnelId <dbxn3y-tunnel> ...
```

Then switch the default profile or pass a profile name to a command:

```powershell
cpctunnel list
cpctunnel use cpcn3y
cpctunnel status
cpctunnel pwsh dbxn3y
cpctunnel agent cpcn3y
```

## Guided setup on a macOS or Linux client device

The Cloud PC host setup still runs on the Windows 365 Cloud PC. The client side
can run from macOS or Linux when these tools are available:

- `sh`
- `ssh`, `scp`, and `sftp`
- Microsoft Dev Tunnels CLI (`devtunnel`) for Dev Tunnels transport. If it is
  missing, the installer prompts before installing it.

From the repository checkout:

```sh
sh ./install.sh
```

The installer writes `cpctunnel` to `~/.local/bin` by default and stores profile
state under `~/.cloudpc-tunnel`.

If `~/.local/bin` is not on your `PATH`, add it in your shell profile.

The client installer also checks Dev Tunnels login and runs
`devtunnel user login` when needed.

## Common commands

```powershell
cpctunnel list
cpctunnel use <profile>
cpctunnel status
cpctunnel reconnect
cpctunnel disconnect
cpctunnel logs
```

| Command | Purpose |
| --- | --- |
| `cpctunnel list` | List configured Cloud PC profiles |
| `cpctunnel use <profile>` | Make a profile the default |
| `cpctunnel status` | Show tunnel and channel readiness |
| `cpctunnel reconnect` | Restart the local connector |
| `cpctunnel disconnect` | Stop the local connector |
| `cpctunnel logs` | Follow local connector logs |
| `cpctunnel pwsh [-Session name]` | Open or reattach a Windows PowerShell session |
| `cpctunnel bash [-Session name]` | Open or reattach a WSL Bash session |
| `cpctunnel agent` | Open the Web Chat surface |
| `cpctunnel port <channel>` | Print the local endpoint for a named channel |
| `cpctunnel open <channel>` | Open a web-like channel in the default browser |

## Using Windows PowerShell over SSH

```powershell
cpctunnel pwsh
```

With a custom persistent session name:

```powershell
cpctunnel pwsh -Session project-a
```

The remote session is hosted by `psmux` on the Cloud PC, so closing the local
terminal does not automatically stop the remote shell.

## Using WSL Bash over SSH

```powershell
cpctunnel bash
```

With a custom persistent session name:

```powershell
cpctunnel bash -Session project-a
```

The remote session is hosted by `tmux` inside WSL.

## Using SCP and SFTP

SCP and SFTP use the local forwarded port for an SSH channel.

First resolve the channel:

```powershell
cpctunnel port windows-ssh
```

Example output:

```text
LocalEndpoint : 127.0.0.1:51234
```

Then use that port with OpenSSH tools:

```powershell
scp -P 51234 .\file.txt user@127.0.0.1:/C:/Users/user/Desktop/
sftp -P 51234 user@127.0.0.1
```

For WSL:

```powershell
cpctunnel port wsl-ssh
sftp -P <local-port> linuxuser@127.0.0.1
```

## Opening a web app or WebSocket server

During setup, add a custom TCP channel. For example:

```text
name: webapp
remote port: 3000
kind: web
```

Then on the client:

```powershell
cpctunnel open webapp
```

or:

```powershell
cpctunnel port webapp
```

Use the printed `127.0.0.1:<port>` endpoint with your browser, API client, or
WebSocket client.

## Web Chat

If Web Chat is enabled:

```powershell
cpctunnel agent
```

The browser opens the private Web Chat surface through the selected transport.
Work runs on the Cloud PC.

The default Web Chat working directory is the Cloud PC user's home directory.
When the installer asks for a working directory, `~` and paths such as
`~/source` are supported.

## Automated setup

The wizard is recommended for first-time use. You can also pass parameters
directly for repeatable setup.

### Cloud PC host

```powershell
.\install.ps1 -Server `
  -CommandName cpctunnel `
  -WindowsSshPort 22 `
  -LinuxSshPort 2222 `
  -AgentChatPort 8787 `
  -TcpChannel webapp=3000:web
```

### Client device

```powershell
.\install.ps1 -Client `
  -Name work-cloudpc `
  -TunnelId <full-tunnel-id.cluster> `
  -WindowsSshUser <DOMAIN\user> `
  -LinuxSshUser <linux-user> `
  -CommandName cpctunnel `
  -TcpChannel webapp=3000:web
```

### Web Chat only

```powershell
.\install.ps1 -Server -WebOnly -AgentChatPort 8787
.\install.ps1 -Client -WebOnly -Name work-cloudpc -TunnelId <full-tunnel-id.cluster>
```

## Security model

Recommended defaults:

- Use private Microsoft Dev Tunnels. Do not enable anonymous tunnel access.
- Keep Windows OpenSSH bound to loopback on the Cloud PC.
- Do not add broad inbound firewall rules for Cloud PC SSH ports.
- Treat Dev Tunnels authentication and SSH authentication as separate layers.
- Use SSH password authentication only when appropriate for your environment.
- Use SSH keys when your environment supports them.
- Keep profile files free of passwords, tokens, and private key material.
- SSH jump host support must be configured explicitly when implemented; never rely on hard-coded private jump hosts.

## Limitations

- This project is for developer evaluation and personal productivity workflows.
- It does not replace Windows App, browser-based Windows 365 access, Remote
  Desktop, Intune, Conditional Access, or endpoint security policy.
- `psmux` and `tmux` protect shell continuity across client disconnects, not a
  full Cloud PC reboot.
- Microsoft Dev Tunnels availability and policy depend on your environment.
- Custom TCP channels expose only the ports you configure.
- Web Chat is optional and should be used only in environments where running
  tools on the Cloud PC through a browser surface is acceptable.

## Troubleshooting

### `cpctunnel` is not recognized

Reopen PowerShell and confirm `%USERPROFILE%\bin` is on `PATH`.

```powershell
Get-Command cpctunnel
```

### The configured tunnel has no active host

Open the Cloud PC through Windows App or browser access, sign in, and confirm
the `cloudpc-tunnel` host task is running. Then reconnect from the client:

```powershell
cpctunnel reconnect
cpctunnel status
```

### SSH login fails

Check the selected channel:

```powershell
cpctunnel port windows-ssh
```

Then confirm the Cloud PC user, password or key, and host key prompt. For WSL,
confirm the WSL distribution is running and that the Linux user has a password or
authorized key configured.

### Web channel opens but the app is unavailable

Confirm the app is listening on the configured Cloud PC port and bound to an
address reachable from the Cloud PC host process. Then run:

```powershell
cpctunnel reconnect
cpctunnel port <channel>
```

## Development checks

```powershell
npm run check
```

The project has no runtime npm dependencies. The check validates the Node server
syntax.
