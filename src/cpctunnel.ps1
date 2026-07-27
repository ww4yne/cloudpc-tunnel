[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'pwsh', 'bash', 'agent', 'status', 'reconnect', 'disconnect',
        'logs', 'port', 'open', 'list', 'use', 'remove'
    )]
    [string]$Action = 'pwsh',
    [Parameter(Position = 1)]
    [string]$Target,
    [Parameter(Position = 2)]
    [string]$Profile,
    [string]$Session
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$configDir = Join-Path $HOME '.cloudpc-tunnel'
$profilesDir = Join-Path $configDir 'profiles'
$activeFile = Join-Path $configDir 'active-profile'

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
                Channels = if ($item.Channels) {
                    (@($item.Channels) | ForEach-Object { "$($_.Name):$($_.HostPort)" }) -join ', '
                } else { '' }
            }
        }
    )
    if (-not $rows) {
        Write-Host 'No cloudpc-tunnel profiles are configured.'
    }
    else {
        $rows | Format-Table -AutoSize
    }
    return
}

if ($Action -eq 'use') {
    if (-not $Target) { throw 'Usage: cpct use <profile>' }
    if ($Target -notmatch '^[A-Za-z0-9_.-]+$') {
        throw 'Invalid profile name.'
    }
    $targetFile = Join-Path $profilesDir "$Target.json"
    if (-not (Test-Path $targetFile)) {
        throw "Profile not found: $Target. Run 'cpct list'."
    }
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Set-Content $activeFile $Target -Encoding ASCII
    Write-Host "Active cloudpc-tunnel profile: $Target" -ForegroundColor Green
    return
}

if ($Action -eq 'remove') {
    if (-not $Target) { throw 'Usage: cpct remove <profile>' }
    if ($Target -notmatch '^[A-Za-z0-9_.-]+$') {
        throw 'Invalid profile name.'
    }
}

if ($Action -notin @('port', 'open') -and $Target -and -not $Profile) {
    $Profile = $Target
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
    ''
}
if (-not (Test-Path $configFile)) {
    if ($Action -eq 'remove' -and $profileName) {
        throw "Profile not found: $profileName. Run 'cpct list'."
    }
    throw (
        "No active cloudpc-tunnel profile. Run 'cpct list' or install a Client " +
        'profile with install.ps1 -Client -Name <name>.'
    )
}
$config = Get-Content $configFile -Raw | ConvertFrom-Json
$stateDir = Join-Path $configDir "state\$profileName"
$processFile = Join-Path $stateDir 'connector.json'
$outLog = Join-Path $stateDir 'connector.out.log'
$errLog = Join-Path $stateDir 'connector.err.log'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
# Adopt the log paths the running connector actually uses (Start-Connector may
# have rotated to a fresh file when the canonical log was locked).
if (Test-Path $processFile) {
    try {
        $savedMeta = Get-Content $processFile -Raw | ConvertFrom-Json
        if ($savedMeta.LogOut) { $outLog = [string]$savedMeta.LogOut }
        if ($savedMeta.LogErr) { $errLog = [string]$savedMeta.LogErr }
    }
    catch {}
}

function Resolve-Devtunnel {
    $command = Get-Command devtunnel -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'devtunnel CLI not found.'
}

function Get-DevtunnelLoginCommand {
    switch ([string]$config.DevTunnelLoginProvider) {
        'github' { return 'devtunnel user login -g' }
        'github-device-code' { return 'devtunnel user login -g -d' }
        'microsoft-device-code' { return 'devtunnel user login -d' }
        default { return 'devtunnel user login' }
    }
}

function Assert-DevtunnelLogin {
    $output = @(& (Resolve-Devtunnel) user show 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    if ($text -match
        '(?i)(login token expired|login required|not logged|not authenticated)') {
        throw (
            "Dev Tunnels login is missing or expired; cpct cannot inspect profile '$profileName'. Run: " +
            (Get-DevtunnelLoginCommand)
        )
    }
    if ($exitCode -ne 0) {
        $detail = if ($text) { " $($text.Trim())" } else { '' }
        throw "Could not inspect Dev Tunnels login.$detail"
    }
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
    Assert-DevtunnelLogin
    $currentId = [string]$config.TunnelId
    $current = Get-TunnelDocument $currentId
    if ($current -and [int]$current.tunnel.hostConnections -ge 1) { return }
    $requiredPorts = @(Get-ChannelPorts)
    $requiredPortText = if ($requiredPorts.Count -gt 0) {
        $requiredPorts -join ', '
    } else {
        'none'
    }

    $errFile = [IO.Path]::GetTempFileName()
    try {
        $json = & (Resolve-Devtunnel) list --json 2>$errFile
        $listExitCode = $LASTEXITCODE
        $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    }
    finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
    if ($listExitCode -ne 0 -or -not $json) {
        $detail = if ($stderr) {
            " Dev Tunnels said: $($stderr.Trim())"
        } else { '' }
        throw (
            "Profile '$profileName' is configured for Dev Tunnel '$currentId', " +
            "but that tunnel has no active host and cpct could not list " +
            "replacement tunnels. Required host ports: $requiredPortText.$detail"
        )
    }
    try {
        $catalog = $json | ConvertFrom-Json
    }
    catch {
        throw (
            "Profile '$profileName' is configured for Dev Tunnel '$currentId', " +
            'but that tunnel has no active host and Dev Tunnels returned an ' +
            'invalid replacement tunnel list.'
        )
    }

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
            "Profile '$profileName' is configured for Dev Tunnel '$currentId', " +
            'but that tunnel has no active host. Start or wake the Cloud PC ' +
            'host, then retry. No online replacement tunnel exposes all ' +
            "required ports: $requiredPortText."
        )
    }

    Write-Host (
        "Profile '$profileName' has no active Dev Tunnel host. Choose a target:"
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
        Write-Host "Keeping cloudpc-tunnel profile '$profileName'." `
            -ForegroundColor Yellow
        return
    }

    $selected = $replacements[$selection - 2]
    if ($selected.ProfileNames.Count -gt 0) {
        $targetProfile = [string]$selected.ProfileNames[0]
        Set-Content $activeFile $targetProfile -Encoding ASCII
        Write-Host "Active cloudpc-tunnel profile: $targetProfile" -ForegroundColor Green
        $invokeArgs = @{
            Action = $Action
            Profile = $targetProfile
        }
        if ($Target) { $invokeArgs.Target = $Target }
        if ($Session) { $invokeArgs.Session = $Session }
        & $PSCommandPath @invokeArgs
        exit $LASTEXITCODE
    }

    $replacement = [string]$selected.TunnelId
    Stop-Connector -TunnelIds @($currentId, $replacement)
    $config.TunnelId = $replacement
    $config | ConvertTo-Json | Set-Content $configFile -Encoding UTF8
    Write-Host "cloudpc-tunnel tunnel changed: $currentId -> $replacement" `
        -ForegroundColor Yellow
}

function Get-ConnectorProcess {
    if (-not (Test-Path $processFile)) { return $null }
    try {
        $metadata = Get-Content $processFile -Raw | ConvertFrom-Json
        $process = Get-Process -Id ([int]$metadata.ProcessId) -ErrorAction SilentlyContinue
        if (-not $process) { return $null }
        # devtunnel runs as a protected process: its live Path and StartTime can
        # be unreadable. Reject only on a positive mismatch, never because a
        # field is empty/unreadable, otherwise a live connector becomes
        # invisible and cannot be stopped.
        if ($process.ProcessName -ne 'devtunnel') { return $null }
        $metadataPath = [string]$metadata.ExecutablePath
        $livePath = try { [string]$process.Path } catch { '' }
        if ($metadataPath -and $livePath -and $livePath -ne $metadataPath) {
            return $null
        }
        $liveTicks = $null
        try { $liveTicks = $process.StartTime.ToUniversalTime().Ticks } catch {}
        if ($null -ne $liveTicks -and
            $liveTicks -ne [long]$metadata.StartTimeUtcTicks) {
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

function Get-Channel([string]$Name) {
    $channels = @($config.Channels)
    if (-not $channels) { throw "Profile '$profileName' has no TCP channels." }
    $channel = @($channels | Where-Object Name -eq $Name | Select-Object -First 1)
    if (-not $channel) {
        $available = ($channels | ForEach-Object Name) -join ', '
        throw "Channel not found: $Name. Available channels: $available"
    }
    return $channel[0]
}

function Get-ChannelPorts {
    @(
        @($config.Channels) |
            ForEach-Object { [int]$_.HostPort } |
            Where-Object { $_ -gt 0 } |
            Select-Object -Unique
    )
}

function Test-LogWritable([string]$Path) {
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
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

    # Redirected log handles can release a moment after process exit. Wait
    # briefly, but do not fail the whole command if the old log stays locked
    # (antivirus/indexer/lingering handle) - Start-Connector rotates to a
    # fresh log file in that case.
    $deadline = (Get-Date).AddSeconds(5)
    do {
        if (Test-LogWritable $outLog) { return }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    Write-Warning (
        "Connector log is still locked; a fresh log file will be used: $outLog"
    )
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
    # If the canonical logs are still locked, rotate to fresh timestamped
    # files so a briefly-held handle cannot block reconnect.
    if (-not (Test-LogWritable $outLog) -or -not (Test-LogWritable $errLog)) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $script:outLog = Join-Path $stateDir "connector.out.$stamp.log"
        $script:errLog = Join-Path $stateDir "connector.err.$stamp.log"
    }
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
        ExecutablePath = if ($process.Path) { $process.Path } else { $exe }
        StartTimeUtcTicks = $process.StartTime.ToUniversalTime().Ticks
        LogOut = $outLog
        LogErr = $errLog
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
        'cloudpc-tunnel connector did not expose required host port(s): ' +
        ($RequiredHostPorts -join ', ')
    )
}

function Invoke-Ssh(
    [int]$Port,
    [string]$User,
    [string]$HostAlias,
    [string]$RemoteCommand,
    [string]$IdentityFile = ''
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
        '-o', 'ServerAliveCountMax=3'
    )
    if ($IdentityFile) {
        $args += @('-i', $IdentityFile, '-o', 'IdentitiesOnly=yes')
    }
    else {
        $args += @(
            '-o', 'PubkeyAuthentication=no',
            '-o', 'PreferredAuthentications=password,keyboard-interactive',
            '-o', 'NumberOfPasswordPrompts=3'
        )
    }
    $args += @('127.0.0.1', $RemoteCommand)
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
    if (-not ('CloudPcTunnel.NativeWindow' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace CloudPcTunnel {
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
                $_.MainWindowTitle -like '*Windows 365 Cloud PC*'
            } |
            Sort-Object StartTime -Descending |
            Select-Object -First 1
        if ($window) {
            [CloudPcTunnel.NativeWindow]::SetWindowPos(
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
        $channel = Get-Channel 'windows-ssh'
        if (-not $channel.User -or [int]$channel.HostPort -le 0) {
            throw 'This profile has no Windows PowerShell SSH channel.'
        }
        Ensure-ActiveTunnel
        Start-Connector @([int]$channel.HostPort)
        $port = Get-ForwardedPort ([int]$channel.HostPort)
        $sessionName = if ($Session) { $Session } else { $channel.Session }
        if ($sessionName -notmatch '^[A-Za-z0-9_.-]+$') {
            throw 'Session may contain only letters, digits, dot, underscore, and hyphen.'
        }
        $remote = (
            'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ' +
            '-Command "$shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) ' +
            '{ ''pwsh.exe'' } else { ''powershell.exe'' }; psmux new-session -A -s ' +
            $sessionName + ' -- $shell"'
        )
        Invoke-Ssh $port $channel.User $channel.HostKeyAlias $remote `
            $channel.IdentityFile
    }
    'bash' {
        $channel = Get-Channel 'wsl-ssh'
        if (-not $channel.User -or [int]$channel.HostPort -le 0) {
            throw 'This profile has no WSL Bash SSH channel.'
        }
        Ensure-ActiveTunnel
        Start-Connector @([int]$channel.HostPort)
        $port = Get-ForwardedPort ([int]$channel.HostPort)
        $sessionName = if ($Session) { $Session } else { $channel.Session }
        if ($sessionName -notmatch '^[A-Za-z0-9_.-]+$') {
            throw 'Session may contain only letters, digits, dot, underscore, and hyphen.'
        }
        Invoke-Ssh $port $channel.User $channel.HostKeyAlias `
            "tmux source-file ~/.tmux.conf 2>/dev/null || true; exec env TERM=xterm-256color tmux -u new-session -A -s '$sessionName'" `
            $channel.IdentityFile
    }
    'agent' {
        $channel = Get-Channel 'web-chat'
        if ([int]$channel.HostPort -le 0 -or [int]$config.AgentChatPort -le 0) {
            throw 'This profile has no Web Chat channel.'
        }
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
        $rows = @(
            foreach ($channel in @($config.Channels)) {
                $localPort = Get-ForwardedPort ([int]$channel.HostPort)
                [pscustomobject]@{
                    Profile = $profileName
                    Channel = $channel.Name
                    Kind = $channel.Kind
                    HostPort = [int]$channel.HostPort
                    LocalPort = if ($process -and (Test-Port $localPort)) { $localPort } else { 0 }
                    Ready = [bool]($process -and (Test-Port $localPort))
                }
            }
        )
        [pscustomobject]@{
            Profile = $profileName
            TunnelId = $config.TunnelId
            ProcessId = if ($process) { $process.Id } else { $null }
        }
        $rows | Format-Table -AutoSize
    }
    'reconnect' {
        Ensure-ActiveTunnel
        Stop-Connector
        $ports = @(Get-ChannelPorts)
        if ($ports.Count -gt 0) { Start-Connector $ports }
    }
    'disconnect' { Stop-Connector }
    'remove' {
        Stop-Connector
        Remove-Item $configFile -Force
        Remove-Item $stateDir -Recurse -Force -ErrorAction SilentlyContinue
        if ((Get-ActiveProfile) -eq $profileName) {
            Remove-Item $activeFile -Force -ErrorAction SilentlyContinue
            Write-Host (
                "Removed active cloudpc-tunnel profile '$profileName'. " +
                "Run 'cpct use <profile>' to choose a new default."
            ) -ForegroundColor Yellow
        }
        else {
            Write-Host "Removed cloudpc-tunnel profile '$profileName'." `
                -ForegroundColor Green
        }
        Write-Host "Dev Tunnel '$($config.TunnelId)' was not deleted."
    }
    'logs' {
        Get-Content $outLog, $errLog -Tail 100 -Wait `
            -ErrorAction SilentlyContinue
    }
    'port' {
        if (-not $Target) { throw 'Usage: cpct port <channel> [profile]' }
        $channel = Get-Channel $Target
        Ensure-ActiveTunnel
        Start-Connector @([int]$channel.HostPort)
        $port = Get-ForwardedPort ([int]$channel.HostPort)
        if (-not (Test-Port $port)) {
            throw "Local forwarded port for channel '$($channel.Name)' is not reachable."
        }
        [pscustomobject]@{
            Profile = $profileName
            Channel = $channel.Name
            Kind = $channel.Kind
            HostPort = [int]$channel.HostPort
            LocalPort = $port
            LocalEndpoint = "127.0.0.1:$port"
        }
    }
    'open' {
        if (-not $Target) { throw 'Usage: cpct open <channel> [profile]' }
        $channel = Get-Channel $Target
        Ensure-ActiveTunnel
        Start-Connector @([int]$channel.HostPort)
        $port = Get-ForwardedPort ([int]$channel.HostPort)
        if (-not (Test-Port $port)) {
            throw "Local forwarded port for channel '$($channel.Name)' is not reachable."
        }
        if ($channel.Kind -in @('http', 'web', 'websocket', 'api')) {
            Start-Process "http://127.0.0.1:$port"
        }
        else {
            Write-Host "127.0.0.1:$port"
        }
    }
}
