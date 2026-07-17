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

function Get-AllConnectorProcesses {
    $byId = @{}
    $tracked = Get-ConnectorProcess
    if ($tracked) { $byId[$tracked.Id] = $tracked }

    $escapedTunnel = [regex]::Escape([string]$config.TunnelId)
    $matches = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq 'devtunnel.exe' -and
                $_.CommandLine -and
                $_.CommandLine -match "(?i)\bconnect\s+$escapedTunnel(?:\s|$)"
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

function Stop-Connector {
    foreach ($process in Get-AllConnectorProcesses) {
        try {
            Stop-Process -Id $process.Id -ErrorAction Stop
            if (-not $process.WaitForExit(10000)) {
                throw "Connector process $($process.Id) did not stop within 10 seconds."
            }
        }
        catch {
            if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) {
                throw
            }
        }
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

switch ($Action) {
    'pwsh' {
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
        Start-Process (Get-AgentUrl)
    }
    'status' {
        $process = Get-ConnectorProcess
        [pscustomobject]@{
            Profile = $profileName
            TunnelId = $config.TunnelId
            ProcessId = if ($process) { $process.Id } else { $null }
            WindowsSsh = Get-ForwardedPort ([int]$config.WindowsSshPort)
            LinuxSsh = Get-ForwardedPort ([int]$config.LinuxSshPort)
            AgentChat = Get-AgentUrl
        }
    }
    'reconnect' {
        Stop-Connector
        Start-Connector @(
            [int]$config.WindowsSshPort,
            [int]$config.LinuxSshPort
        )
    }
    'disconnect' { Stop-Connector }
}
