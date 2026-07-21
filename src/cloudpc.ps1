[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'pwsh', 'bash', 'agent', 'status', 'reconnect', 'disconnect',
        'list', 'use'
    )]
    [string]$Action = 'pwsh',
    [Parameter(Position = 1)]
    [string]$Profile,
    [string]$Session
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$configDir = Join-Path $HOME '.cloudpc-agent'
$profilesDir = Join-Path $configDir 'profiles'
$activeFile = Join-Path $configDir 'active-profile'
$legacyConfig = Join-Path $configDir 'config.json'

function Get-ProfileNames {
    if (-not (Test-Path $profilesDir)) { return @() }
    return @(
        Get-ChildItem $profilesDir -Filter '*.json' -File `
            -ErrorAction SilentlyContinue |
            ForEach-Object BaseName |
            Sort-Object
    )
}

function Get-ActiveProfile {
    if (Test-Path $activeFile) {
        return (Get-Content $activeFile -Raw).Trim()
    }
    return ''
}

if ($Action -eq 'list') {
    $active = Get-ActiveProfile
    $rows = @(
        foreach ($name in Get-ProfileNames) {
            $item = Get-Content (Join-Path $profilesDir "$name.json") -Raw |
                ConvertFrom-Json
            [pscustomobject]@{
                Active = if ($name -eq $active) { '*' } else { ''
                }
                Name = $name
                TunnelId = $item.TunnelId
                WindowsUser = $item.WindowsSshUser
                LinuxUser = $item.LinuxSshUser
            }
        }
    )
    if (-not $rows) {
        Write-Host 'No Cloud PC profiles are configured.'
    }
    else {
        $rows | Format-Table -AutoSize
    }
    return
}

if ($Action -eq 'use') {
    if (-not $Profile) { throw 'Usage: cloudpc use <profile>' }
    if ($Profile -notmatch '^[A-Za-z0-9_.-]+$') {
        throw 'Invalid profile name.'
    }
    $target = Join-Path $profilesDir "$Profile.json"
    if (-not (Test-Path $target)) {
        throw "Profile not found: $Profile. Run 'cloudpc list'."
    }
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Set-Content $activeFile $Profile -Encoding ASCII
    Write-Host "Active Cloud PC: $Profile" -ForegroundColor Green
    return
}

$profileName = $Profile
if (-not $profileName) { $profileName = Get-ActiveProfile }
$names = @(Get-ProfileNames)
if (-not $profileName -and $names.Count -eq 1) {
    $profileName = $names[0]
}

$configFile = if ($profileName) {
    Join-Path $profilesDir "$profileName.json"
}
else {
    $legacyConfig
}
if (-not (Test-Path $configFile)) {
    throw (
        "No active Cloud PC profile. Run 'cloudpc list' or install a Client " +
        'profile with install.ps1 -Client -Name <name>.'
    )
}
$config = Get-Content $configFile -Raw | ConvertFrom-Json
if (-not $profileName) {
    $profileName = if ($config.Name) { $config.Name } else { 'legacy' }
}
$stateDir = Join-Path $configDir "state\$profileName"
$processFile = Join-Path $stateDir 'connector.json'
$outLog = Join-Path $stateDir 'connector.out.log'
$errLog = Join-Path $stateDir 'connector.err.log'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

function Resolve-Devtunnel {
    $command = Get-Command devtunnel -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'devtunnel CLI not found.'
}

function Get-TunnelDocument([string]$TunnelId) {
    $json = & (Resolve-Devtunnel) show $TunnelId --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    try {
        return $json | ConvertFrom-Json
    }
    catch {
        throw "Dev Tunnel returned invalid status for '$TunnelId'."
    }
}

function Ensure-ActiveTunnel {
    $currentId = [string]$config.TunnelId
    $current = Get-TunnelDocument $currentId
    if ($current -and [int]$current.tunnel.hostConnections -ge 1) { return }

    $json = & (Resolve-Devtunnel) list --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        throw "Could not inspect Dev Tunnels while '$currentId' has no active host."
    }
    try {
        $catalog = $json | ConvertFrom-Json
    }
    catch {
        throw 'Dev Tunnel returned an invalid tunnel list.'
    }

    $requiredPorts = @(
        [int]$config.WindowsSshPort,
        [int]$config.LinuxSshPort,
        [int]$config.AgentChatPort
    ) | Where-Object { $_ -gt 0 } | Select-Object -Unique
    $replacements = @(
        foreach ($candidate in @($catalog.tunnels)) {
            if ([int]$candidate.hostConnections -lt 1) { continue }
            $document = Get-TunnelDocument ([string]$candidate.tunnelId)
            if (-not $document) { continue }
            $ports = @(
                $document.tunnel.ports |
                    ForEach-Object { [int]$_.portNumber }
            )
            $missing = @($requiredPorts | Where-Object { $_ -notin $ports })
            if ($missing.Count -eq 0) {
                $owners = @(
                    foreach ($name in Get-ProfileNames) {
                        if ($name -eq $profileName) { continue }
                        $profileFile = Join-Path $profilesDir "$name.json"
                        $item = Get-Content $profileFile -Raw | ConvertFrom-Json
                        if ($item.TunnelId -eq $candidate.tunnelId) {
                            $name
                        }
                    }
                )
                [pscustomobject]@{
                    TunnelId = [string]$candidate.tunnelId
                    Description = [string]$candidate.description
                    ProfileNames = $owners
                }
            }
        }
    )

    if ($replacements.Count -eq 0) {
        throw (
            "Configured tunnel '$currentId' has no active host, and no online " +
            'replacement exposes all required ports.'
        )
    }

    Write-Host (
        "Cloud PC '$profileName' has no active host. Choose a target:"
    ) -ForegroundColor Yellow
    Write-Host "  1. Keep $profileName - $currentId (offline)"
    for ($i = 0; $i -lt $replacements.Count; $i++) {
        $item = $replacements[$i]
        $label = if ($item.ProfileNames.Count -gt 0) {
            "$($item.ProfileNames -join '/') - $($item.TunnelId)"
        }
        else {
            "unassigned - $($item.TunnelId)"
        }
        $suffix = if ($item.Description) {
            " - $($item.Description)"
        }
        else {
            ''
        }
        Write-Host "  $($i + 2). $label (online)$suffix"
    }
    $maxSelection = $replacements.Count + 1
    do {
        $answer = Read-Host "Selection [1-$maxSelection]"
        $selection = 0
        $valid = [int]::TryParse($answer, [ref]$selection) -and
            $selection -ge 1 -and
            $selection -le $maxSelection
        if (-not $valid) {
            Write-Warning 'Enter one of the listed numbers.'
        }
    } while (-not $valid)

    if ($selection -eq 1) {
        Write-Host "Keeping Cloud PC profile '$profileName'." `
            -ForegroundColor Yellow
        return
    }

    $selected = $replacements[$selection - 2]
    if ($selected.ProfileNames.Count -gt 0) {
        $targetProfile = [string]$selected.ProfileNames[0]
        Set-Content $activeFile $targetProfile -Encoding ASCII
        Write-Host "Active Cloud PC: $targetProfile" -ForegroundColor Green
        $invokeArgs = @{
            Action = $Action
            Profile = $targetProfile
        }
        if ($Session) { $invokeArgs.Session = $Session }
        & $PSCommandPath @invokeArgs
        exit $LASTEXITCODE
    }

    $replacement = [string]$selected.TunnelId
    Stop-Connector -TunnelIds @($currentId, $replacement)
    $config.TunnelId = $replacement
    $config | ConvertTo-Json | Set-Content $configFile -Encoding UTF8
    Write-Host "Cloud PC tunnel changed: $currentId -> $replacement" `
        -ForegroundColor Yellow
}

function Get-ConnectorProcess {
    if (-not (Test-Path $processFile)) { return $null }
    try {
        $metadata = Get-Content $processFile -Raw | ConvertFrom-Json
        $process = Get-Process -Id ([int]$metadata.ProcessId) -ErrorAction SilentlyContinue
        if (-not $process) { return $null }
        if ($process.Path -ne $metadata.ExecutablePath) { return $null }
        if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$metadata.StartTimeUtcTicks) {
            return $null
        }
        return $process
    } catch { return $null }
}

function Get-AllConnectorProcesses(
    [string[]]$TunnelIds = @([string]$config.TunnelId)
) {
    $byId = @{}
    $tracked = Get-ConnectorProcess
    if ($tracked) { $byId[$tracked.Id] = $tracked }

    $escapedTunnels = @(
        $TunnelIds |
            Where-Object { $_ } |
            ForEach-Object { [regex]::Escape($_) }
    )
    $matches = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                if ($_.Name -ne 'devtunnel.exe' -or -not $_.CommandLine) {
                    return $false
                }
                foreach ($escapedTunnel in $escapedTunnels) {
                    if ($_.CommandLine -match
                        "(?i)\bconnect\s+$escapedTunnel(?:\s|$)") {
                        return $true
                    }
                }
                return $false
            }
    )
    foreach ($match in $matches) {
        $process = Get-Process -Id ([int]$match.ProcessId) `
            -ErrorAction SilentlyContinue
        if ($process) { $byId[$process.Id] = $process }
    }
    return @($byId.Values)
}

function Get-ForwardedPort([int]$HostPort) {
    foreach ($file in @($outLog, $errLog)) {
        if (-not (Test-Path $file)) { continue }
        $pattern = "Forwarding from\s+127\.0\.0\.1:(\d+)\s+to host port\s+$HostPort\b"
        # Forwarding-map lines are emitted once at connector startup. Health
        # probes can later add thousands of relay diagnostic lines, so tailing
        # the log eventually loses the only authoritative mapping.
        $match = Select-String -Path $file -Pattern $pattern |
            Select-Object -Last 1
        if ($match) { return [int]$match.Matches[0].Groups[1].Value }
    }
    return 0
}

function Test-Port([int]$Port) {
    if (-not $Port) { return $false }
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $result = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        return $result.AsyncWaitHandle.WaitOne(500) -and $client.Connected
    } catch { return $false }
    finally { $client.Dispose() }
}

function Stop-Connector(
    [string[]]$TunnelIds = @([string]$config.TunnelId)
) {
    $stopDeadline = (Get-Date).AddSeconds(15)
    do {
        $processes = @(Get-AllConnectorProcesses -TunnelIds $TunnelIds)
        foreach ($process in $processes) {
            try {
                Stop-Process -Id $process.Id -ErrorAction Stop
            }
            catch {
                if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) {
                    throw
                }
            }
        }
        if ($processes.Count -gt 0) {
            Start-Sleep -Milliseconds 200
        }
    } while (
        (Get-Date) -lt $stopDeadline -and
        @(Get-AllConnectorProcesses -TunnelIds $TunnelIds).Count -gt 0
    )
    $remaining = @(Get-AllConnectorProcesses -TunnelIds $TunnelIds)
    if ($remaining.Count -gt 0) {
        throw (
            'Connector process(es) did not stop within 15 seconds: ' +
            (($remaining | ForEach-Object Id) -join ', ')
        )
    }
    Remove-Item $processFile -ErrorAction SilentlyContinue

    # Redirected log handles can release a moment after process exit.
    $deadline = (Get-Date).AddSeconds(5)
    do {
        try {
            $stream = [IO.File]::Open(
                $outLog,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
            $stream.Dispose()
            return
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    } while ((Get-Date) -lt $deadline)
    throw "Connector log is still locked after stopping matching processes: $outLog"
}

function Start-Connector([int[]]$RequiredHostPorts) {
    $process = Get-ConnectorProcess
    $ready = $true
    foreach ($hostPort in $RequiredHostPorts) {
        $localPort = Get-ForwardedPort $hostPort
        if (-not $localPort) {
            $ready = $false
            break
        }
    }
    if ($process -and $ready) { return }

    Stop-Connector
    Set-Content $outLog ''
    Set-Content $errLog ''
    $exe = Resolve-Devtunnel
    $process = Start-Process -FilePath $exe `
        -ArgumentList @('connect', $config.TunnelId) `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError $errLog `
        -WindowStyle Hidden -PassThru
    $process.Refresh()
    [ordered]@{
        ProcessId = $process.Id
        ExecutablePath = $process.Path
        StartTimeUtcTicks = $process.StartTime.ToUniversalTime().Ticks
    } | ConvertTo-Json | Set-Content $processFile -Encoding UTF8

    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $ready = $true
        foreach ($hostPort in $RequiredHostPorts) {
            $localPort = Get-ForwardedPort $hostPort
            if (-not $localPort) {
                $ready = $false
                break
            }
        }
        if ($ready) { return }
        if ($process.HasExited) { break }
        Start-Sleep -Milliseconds 300
    }
    Get-Content $outLog, $errLog -Tail 60 -ErrorAction SilentlyContinue
    throw (
        'Cloud PC connector did not expose required host port(s): ' +
        ($RequiredHostPorts -join ', ')
    )
}

function Invoke-Ssh(
    [int]$Port,
    [string]$User,
    [string]$HostAlias,
    [string]$RemoteCommand
) {
    $knownHosts = Join-Path $stateDir 'known_hosts'
    $args = @(
        '-tt',
        '-p', "$Port",
        '-l', $User,
        '-o', "HostKeyAlias=$HostAlias",
        '-o', 'CheckHostIP=no',
        '-o', "UserKnownHostsFile=$knownHosts",
        '-o', 'StrictHostKeyChecking=ask',
        '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=3',
        '-o', 'PubkeyAuthentication=no',
        '-o', 'PreferredAuthentications=password,keyboard-interactive',
        '-o', 'NumberOfPasswordPrompts=3',
        '127.0.0.1',
        $RemoteCommand
    )
    & ssh @args
    exit $LASTEXITCODE
}

function Get-AgentUrl {
    try {
        $document = & (Resolve-Devtunnel) show $config.TunnelId --json 2>$null |
            ConvertFrom-Json
        $port = @(
            $document.tunnel.ports |
                Where-Object {
                    [int]$_.portNumber -eq [int]$config.AgentChatPort
                }
        ) | Select-Object -First 1
        if ($port.portUri) { return [string]$port.portUri }
    }
    catch {}

    # Fallback for CLI versions that omit portUri.
    $parts = "$($config.TunnelId)".Split('.')
    if ($parts.Count -lt 2) {
        throw 'Tunnel ID must include its cluster suffix.'
    }
    $cluster = $parts[-1]
    $name = ($parts[0..($parts.Count - 2)] -join '.')
    return "https://$name-$($config.AgentChatPort).$cluster.devtunnels.ms"
}

function Set-AgentWindowBounds {
    if (-not ('CloudPcAgent.NativeWindow' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace CloudPcAgent {
    public static class NativeWindow {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetWindowPos(
            IntPtr hWnd,
            IntPtr hWndInsertAfter,
            int x,
            int y,
            int width,
            int height,
            uint flags
        );
    }
}
'@
    }

    $deadline = (Get-Date).AddSeconds(8)
    do {
        $window = Get-Process msedge -ErrorAction SilentlyContinue |
            Where-Object {
                $_.MainWindowHandle -ne 0 -and
                $_.MainWindowTitle -like '*Windows 365 Agent*'
            } |
            Sort-Object StartTime -Descending |
            Select-Object -First 1
        if ($window) {
            [CloudPcAgent.NativeWindow]::SetWindowPos(
                $window.MainWindowHandle,
                [IntPtr]::Zero,
                60,
                60,
                1080,
                700,
                0x0040
            ) | Out-Null
            return
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
}

switch ($Action) {
    'pwsh' {
        if (-not $config.WindowsSshUser -or
            [int]$config.WindowsSshPort -le 0) {
            throw 'This profile is Web Chat-only and has no PowerShell channel.'
        }
        Ensure-ActiveTunnel
        Start-Connector @([int]$config.WindowsSshPort)
        $port = Get-ForwardedPort ([int]$config.WindowsSshPort)
        $sessionName = if ($Session) { $Session } else { $config.WindowsSession }
        if ($sessionName -notmatch '^[A-Za-z0-9_.-]+$') {
            throw 'Session may contain only letters, digits, dot, underscore, and hyphen.'
        }
        $remote = (
            'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ' +
            '-Command "$shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) ' +
            '{ ''pwsh.exe'' } else { ''powershell.exe'' }; psmux new-session -A -s ' +
            $sessionName + ' -- $shell"'
        )
        Invoke-Ssh $port $config.WindowsSshUser `
            "cloudpc-$profileName-windows" $remote
    }
    'bash' {
        if (-not $config.LinuxSshUser -or
            [int]$config.LinuxSshPort -le 0) {
            throw 'This profile is Web Chat-only and has no Bash channel.'
        }
        Ensure-ActiveTunnel
        Start-Connector @([int]$config.LinuxSshPort)
        $port = Get-ForwardedPort ([int]$config.LinuxSshPort)
        $sessionName = if ($Session) { $Session } else { $config.LinuxSession }
        if ($sessionName -notmatch '^[A-Za-z0-9_.-]+$') {
            throw 'Session may contain only letters, digits, dot, underscore, and hyphen.'
        }
        Invoke-Ssh $port $config.LinuxSshUser `
            "cloudpc-$profileName-linux" `
            "tmux source-file ~/.tmux.conf 2>/dev/null || true; exec env TERM=xterm-256color tmux -u new-session -A -s '$sessionName'"
    }
    'agent' {
        Ensure-ActiveTunnel
        $url = Get-AgentUrl
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            $edge = @(
                (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
            ) | Where-Object { $_ -and (Test-Path $_) } |
                Select-Object -First 1
            if ($edge) {
                Start-Process $edge -ArgumentList @(
                    "--app=$url",
                    '--window-size=1050,620',
                    '--disable-gpu'
                )
                Set-AgentWindowBounds
                return
            }
        }
        Start-Process $url
    }
    'status' {
        Ensure-ActiveTunnel
        $process = Get-ConnectorProcess
        $windowsPort = Get-ForwardedPort ([int]$config.WindowsSshPort)
        $linuxPort = Get-ForwardedPort ([int]$config.LinuxSshPort)
        [pscustomobject]@{
            Profile = $profileName
            TunnelId = $config.TunnelId
            ProcessId = if ($process) { $process.Id } else { $null }
            WindowsSsh = if ($process -and (Test-Port $windowsPort)) {
                $windowsPort
            } else { 0 }
            LinuxSsh = if ($process -and (Test-Port $linuxPort)) {
                $linuxPort
            } else { 0 }
            AgentChat = Get-AgentUrl
        }
    }
    'reconnect' {
        Ensure-ActiveTunnel
        Stop-Connector
        $ports = @(
            [int]$config.WindowsSshPort,
            [int]$config.LinuxSshPort
        ) | Where-Object { $_ -gt 0 }
        if ($ports.Count -gt 0) { Start-Connector $ports }
    }
    'disconnect' { Stop-Connector }
}
