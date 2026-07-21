[CmdletBinding()]
param(
    [switch]$Server,
    [switch]$Client,
    [switch]$Status,
    [switch]$WebOnly,

    [string]$TunnelId,
    [string]$Name,
    [string]$Distro = 'Ubuntu',
    [string]$WindowsSshUser,
    [string]$LinuxSshUser,
    [string]$AgentWorkingDirectory = '',
    [switch]$SkipPackageInstall
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = $PSScriptRoot

$selectedActions = @($Server, $Client, $Status) | Where-Object { $_ }
if (@($selectedActions).Count -ne 1) {
    throw 'Specify exactly one action: -Server, -Client, or -Status.'
}

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
        throw 'Host setup must run from an elevated PowerShell.'
    }
}

function Get-WindowsSshUser {
    $upn = (& whoami.exe /upn 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $upn -match '^[^@\s]+@[^@\s]+$') {
        return $upn
    }
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Install-WingetPackage([string]$Id, [string]$CommandName) {
    if (Get-Command $CommandName -ErrorAction SilentlyContinue) { return }
    if ($SkipPackageInstall) {
        throw "$CommandName is required but -SkipPackageInstall was specified."
    }
    Write-Step "Installing $Id"
    & winget install --id $Id -e --accept-package-agreements `
        --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "winget install failed: $Id" }

    # Refresh PATH for packages exposed through WinGet Links.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "$Id installed but $CommandName is not visible. Reopen PowerShell and rerun."
    }
}

function Get-ConfiguredTunnelId {
    if ($TunnelId) { return $TunnelId }
    $webTunnelFile = Join-Path $HOME '.cloudpc-agent\server\web-tunnel-id'
    if ($WebOnly -and (Test-Path $webTunnelFile)) {
        $webTunnel = (Get-Content $webTunnelFile -Raw).Trim()
        if ($webTunnel) { return $webTunnel }
    }
    $serverDir = Join-Path $HOME '.devbox-cli\server'
    if (-not (Test-Path $serverDir)) { return $null }
    $ids = @(
        Get-ChildItem $serverDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'host.log') } |
            ForEach-Object Name
    )
    if ($ids.Count -eq 1) { return $ids[0] }
    if ($ids.Count -gt 1) {
        $summaries = @(
            foreach ($id in $ids) {
                $ports = @()
                $hostConnections = 0
                try {
                    $portDocument = & devtunnel port list $id --json 2>$null |
                        ConvertFrom-Json
                    $ports = @(
                        $portDocument.ports |
                            ForEach-Object { [int]$_.portNumber }
                    )
                } catch {}
                try {
                    $show = & devtunnel show $id --json 2>$null |
                        ConvertFrom-Json
                    $hostConnections = [int]$show.tunnel.hostConnections
                } catch {}
                [pscustomobject]@{
                    TunnelId = $id
                    Ports = $ports
                    HostConnections = $hostConnections
                    CloudPcAgentReady =
                        (2222 -in $ports) -and (8787 -in $ports)
                }
            }
        )

        $ready = @($summaries | Where-Object CloudPcAgentReady)
        if ($ready.Count -eq 1) {
            Write-Host "Using cloudpc-agent tunnel: $($ready[0].TunnelId)"
            return $ready[0].TunnelId
        }

        function Ensure-DevtunnelLogin {
            Install-WingetPackage 'Microsoft.devtunnel' 'devtunnel'
            try {
                $login = & devtunnel user show --json 2>$null | ConvertFrom-Json
            }
            catch {
                $login = $null
            }
            if (-not $login -or $login.status -ne 'Logged in') {
                & devtunnel user login
                if ($LASTEXITCODE -ne 0) { throw 'Dev Tunnel login failed.' }
            }
        }

        function Ensure-WebTunnel {
            Ensure-DevtunnelLogin
            $selectedTunnel = Get-ConfiguredTunnelId
            if ($selectedTunnel) {
                $document = & devtunnel show $selectedTunnel --json 2>$null
                if ($LASTEXITCODE -ne 0 -or -not $document) {
                    throw "Configured Dev Tunnel was not found: $selectedTunnel"
                }
            }
            else {
                Write-Step 'Creating private Web Chat tunnel'
                $created = & devtunnel create `
                    --description 'Windows 365 Agent Web Chat' --json |
                    ConvertFrom-Json
                $selectedTunnel = [string]$created.tunnel.tunnelId
                if (-not $selectedTunnel) {
                    $selectedTunnel = [string]$created.tunnelId
                }
                if (-not $selectedTunnel) {
                    throw 'Dev Tunnel was created but its ID was not returned.'
                }
            }

            $ports = & devtunnel port list $selectedTunnel --json |
                ConvertFrom-Json
            $published = @($ports.ports | ForEach-Object { [int]$_.portNumber })
            if (8787 -notin $published) {
                & devtunnel port create $selectedTunnel `
                    --port-number 8787 `
                    --protocol auto `
                    --description 'Cloud PC Agent Chat' | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw 'Failed to publish the Web Chat tunnel port.'
                }
            }

            $serverDir = Join-Path $HOME '.cloudpc-agent\server'
            New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
            Set-Content (Join-Path $serverDir 'web-tunnel-id') `
                $selectedTunnel -Encoding ASCII
            return $selectedTunnel
        }

        $baseline = @(
            $summaries |
                Where-Object {
                    (22 -in $_.Ports) -and $_.HostConnections -ge 1
                }
        )
        if ($baseline.Count -eq 1) {
            Write-Host "Using active Windows baseline tunnel: $($baseline[0].TunnelId)"
            return $baseline[0].TunnelId
        }

        $summaries |
            Select-Object TunnelId,
                @{ n = 'PublishedPorts'; e = { $_.Ports -join ', ' } },
                HostConnections, CloudPcAgentReady |
            Format-Table -AutoSize
        throw "Multiple ambiguous tunnels found. Rerun with -TunnelId: $($ids -join ', ')"
    }
    return $null
}

function Repair-DevboxCliSource([string]$Source) {
    # Upstream ww4yne/devbox-cli install.ps1 has a known bug (as of the
    # commit this was pinned against): Ensure-Tunnel's `devtunnel port
    # create` call doesn't capture stdout, so its multi-line summary output
    # leaks into the function's return stream alongside $canonicalId.
    # PowerShell's array-to-string conversion then joins them into one
    # polluted TunnelId, which breaks Register-ScheduledTask /
    # Start-ScheduledTask downstream ("The parameter is incorrect"). Patch
    # the fetched source in-memory until upstream carries the fix.
    $buggy = @'
        Write-Step 'Publishing the OpenSSH port'
        & $Devtunnel port create $canonicalId `
            --port-number 22 --protocol auto --description OpenSSH
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to publish SSH port 22.'
        }
'@
    $fixed = @'
        Write-Step 'Publishing the OpenSSH port'
        $portCreateOutput = @(
            & $Devtunnel port create $canonicalId `
                --port-number 22 --protocol auto --description OpenSSH 2>&1
        )
        if ($LASTEXITCODE -ne 0) {
            if ($portCreateOutput) {
                Write-Host ($portCreateOutput -join [Environment]::NewLine)
            }
            throw 'Failed to publish SSH port 22.'
        }
'@
    if ($Source -match [regex]::Escape($buggy)) {
        return $Source.Replace($buggy, $fixed)
    }
    return $Source
}

function Install-WindowsFoundation {
    $configured = Get-ConfiguredTunnelId
    if ($configured) { return $configured }

    Write-Step 'Installing secure Windows terminal foundation'
    $source = Invoke-RestMethod `
        'https://raw.githubusercontent.com/ww4yne/devbox-cli/main/install.ps1'
    $source = Repair-DevboxCliSource $source
    $installer = [scriptblock]::Create($source)
    if ($TunnelId) {
        & $installer -Mode Server -TunnelId $TunnelId
    }
    else {
        & $installer -Mode Server
    }

    $configured = Get-ConfiguredTunnelId
    if (-not $configured) {
        throw 'Windows foundation completed but the tunnel ID could not be discovered.'
    }
    return $configured
}

function Ensure-Wsl {
    Write-Step "Checking WSL distro: $Distro"
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe is unavailable on this Windows version.'
    }
    $distros = @(& wsl.exe -l -q) |
        ForEach-Object { $_.Trim([char]0).Trim() } |
        Where-Object { $_ }
    if ($Distro -in $distros) { return }
    if ($SkipPackageInstall) {
        throw "WSL distro '$Distro' is missing."
    }

    Write-Step "Installing WSL distro: $Distro"
    & wsl.exe --install -d $Distro
    Write-Host ''
    Write-Host 'WSL installation was requested.' -ForegroundColor Yellow
    Write-Host 'Restart Windows if prompted, complete the distro first-run setup,'
    Write-Host 'then rerun this same install.ps1 command.'
    exit 3010
}

function Get-OpenSshCapability {
    # Prefer the Get-WindowsCapability cmdlet, but some Windows images hit a
    # broken DISM PowerShell/COM binding ("Class not registered") even though
    # the classic dism.exe CLI works fine. Fall back to dism.exe in that case.
    try {
        return Get-WindowsCapability -Online -ErrorAction Stop |
            Where-Object Name -Like 'OpenSSH.Server*' |
            Select-Object -First 1
    }
    catch {
        Write-Host (
            'Get-WindowsCapability failed (' + $_.Exception.Message +
            '); falling back to dism.exe.'
        ) -ForegroundColor Yellow
        $dismOutput = & dism.exe /Online /Get-Capabilities 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "dism.exe /Get-Capabilities failed (exit $LASTEXITCODE)."
        }
        $name = ($dismOutput |
            Select-String -Pattern '^Capability Identity\s*:\s*(OpenSSH\.Server\S*)' |
            ForEach-Object { $_.Matches[0].Groups[1].Value } |
            Select-Object -First 1)
        if (-not $name) { return $null }
        $infoOutput = & dism.exe /Online /Get-CapabilityInfo /CapabilityName:$name 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "dism.exe /Get-CapabilityInfo failed (exit $LASTEXITCODE)."
        }
        $state = ($infoOutput |
            Select-String -Pattern '^State\s*:\s*(\S+)' |
            ForEach-Object { $_.Matches[0].Groups[1].Value } |
            Select-Object -First 1)
        [pscustomobject]@{ Name = $name; State = $state }
    }
}

function Add-OpenSshCapability([string]$Name) {
    try {
        Add-WindowsCapability -Online -Name $Name -ErrorAction Stop
        return
    }
    catch {
        Write-Host (
            'Add-WindowsCapability failed (' + $_.Exception.Message +
            '); falling back to dism.exe.'
        ) -ForegroundColor Yellow
        & dism.exe /Online /Add-Capability /CapabilityName:$Name | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "dism.exe /Add-Capability failed (exit $LASTEXITCODE)."
        }
    }
}

function Ensure-WindowsOpenSsh {
    Write-Step 'Checking Windows OpenSSH Server'
    $capability = Get-OpenSshCapability
    if (-not $capability) {
        throw 'OpenSSH.Server Windows capability is unavailable.'
    }
    if ($capability.State -ne 'Installed') {
        Write-Host "Installing $($capability.Name) through Windows Features on Demand..."
        Add-OpenSshCapability $capability.Name
        $capability = Get-OpenSshCapability
        if ($capability.State -ne 'Installed') {
            throw (
                "OpenSSH capability state is '$($capability.State)'. " +
                'Restart Windows if required, then rerun -Server.'
            )
        }
    }

    $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
    if (-not (Test-Path $configPath)) {
        Write-Host 'OpenSSH is installed but not initialized; creating sshd_config.'
        $configDir = Split-Path $configPath -Parent
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $defaultConfig = @(
            (Join-Path $env:WINDIR 'System32\OpenSSH\sshd_config_default'),
            (Join-Path $env:ProgramFiles 'OpenSSH\sshd_config_default')
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($defaultConfig) {
            Copy-Item $defaultConfig $configPath
        }
        else {
            # Minimal safe configuration. Bind loopback before the service ever
            # starts, so first-run initialization cannot expose TCP 22.
            Set-Content $configPath @'
# cloudpc-agent: loopback-only SSH
# Generated minimal OpenSSH Server configuration
Port 22
ListenAddress 127.0.0.1
ListenAddress ::1
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
Subsystem sftp sftp-server.exe
'@ -Encoding ASCII
        }
    }
    $config = @(Get-Content $configPath)
    $activeListeners = @(
        $config |
            Where-Object { $_ -match '^\s*ListenAddress\s+(\S+)' } |
            ForEach-Object { $Matches[1] }
    )
    $unsafe = @(
        $activeListeners |
            Where-Object { $_ -notin @('127.0.0.1', '::1') }
    )
    if ($unsafe) {
        throw "Unsafe OpenSSH ListenAddress values already exist: $($unsafe -join ', ')"
    }

    # Repair prior runs and always place global directives before the first
    # Match block. OpenSSH rejects ListenAddress inside Match context.
    $clean = @(
        $config |
            Where-Object {
                $_ -ne '# cloudpc-agent: loopback-only SSH' -and
                $_ -notmatch '^\s*ListenAddress\s+(127\.0\.0\.1|::1)\s*$'
            }
    )
    $matchIndex = -1
    for ($i = 0; $i -lt $clean.Count; $i++) {
        if ($clean[$i] -match '^\s*Match\s+') {
            $matchIndex = $i
            break
        }
    }
    $loopbackBlock = @(
        '# cloudpc-agent: loopback-only SSH',
        'ListenAddress 127.0.0.1',
        'ListenAddress ::1',
        ''
    )
    if ($matchIndex -ge 0) {
        $before = if ($matchIndex -gt 0) {
            @($clean[0..($matchIndex - 1)])
        } else {
            @()
        }
        $after = @($clean[$matchIndex..($clean.Count - 1)])
        $clean = @($before) + $loopbackBlock + @($after)
    }
    else {
        $clean = @($clean) + @('') + $loopbackBlock
    }
    Set-Content $configPath $clean -Encoding ASCII

    $openSshDir = Join-Path $env:WINDIR 'System32\OpenSSH'
    $sshKeygen = Join-Path $openSshDir 'ssh-keygen.exe'
    $sshd = Join-Path $openSshDir 'sshd.exe'
    if (-not (Test-Path $sshKeygen) -or -not (Test-Path $sshd)) {
        throw "OpenSSH binaries are missing under $openSshDir"
    }
    & $sshKeygen -A
    if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen -A failed.' }

    # Windows sshd runs as SYSTEM and rejects private host keys with inherited
    # or broad ACLs. Half-initialized capability installs commonly leave these
    # files with the elevated user's inherited permissions.
    & icacls $configPath /inheritance:r `
        /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to secure sshd_config ACL.' }
    foreach ($key in Get-ChildItem (Split-Path $configPath -Parent) `
        -Filter 'ssh_host_*_key' -File -ErrorAction SilentlyContinue) {
        & icacls $key.FullName /inheritance:r `
            /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to secure host key ACL: $($key.FullName)"
        }
    }

    & $sshd -t -f $configPath
    if ($LASTEXITCODE -ne 0) {
        throw "Generated OpenSSH configuration failed validation: $configPath"
    }

    Set-Service sshd -StartupType Automatic
    Restart-Service sshd -ErrorAction SilentlyContinue
    if ((Get-Service sshd).Status -ne 'Running') {
        $conflicts = @(
            Get-NetTCPConnection -State Listen -LocalPort 22 `
                -ErrorAction SilentlyContinue
        )
        if ($conflicts) {
            $owners = $conflicts |
                Select-Object LocalAddress, LocalPort, OwningProcess |
                Format-Table -AutoSize |
                Out-String
            throw "TCP 22 is already owned by another process:`n$owners"
        }
        try {
            Start-Service sshd -ErrorAction Stop
        }
        catch {
            $events = @(
                Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 8 `
                    -ErrorAction SilentlyContinue |
                    Select-Object TimeCreated, Id, LevelDisplayName, Message
            )
            $service = Get-CimInstance Win32_Service -Filter "Name='sshd'" |
                Select-Object State, StartMode, ExitCode, PathName
            throw (
                "Failed to start sshd.`nService:`n" +
                ($service | Format-List | Out-String) +
                "`nOpenSSH events:`n" +
                ($events | Format-List | Out-String)
            )
        }
    }
    Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
        -ErrorAction SilentlyContinue
    $listeners = @(
        Get-NetTCPConnection -State Listen -LocalPort 22 `
            -ErrorAction SilentlyContinue
    )
    if (-not $listeners) { throw 'sshd is not listening on TCP 22.' }
    $nonLoopback = @(
        $listeners |
            Where-Object LocalAddress -NotIn @('127.0.0.1', '::1')
    )
    if ($nonLoopback) {
        throw 'sshd is listening beyond loopback; refusing unsafe configuration.'
    }
}

function Ensure-CopilotLogin {
    Write-Step 'Checking Copilot authentication'
    $output = & copilot -p 'Reply with OK only.' --silent --no-remote `
        --no-remote-export --no-color 2>&1
    if ($LASTEXITCODE -eq 0 -and "$output" -match 'OK') { return }

    Write-Host 'Copilot login is required. Complete the browser flow.' -ForegroundColor Yellow
    & copilot login
    if ($LASTEXITCODE -ne 0) { throw 'Copilot login failed.' }
}

function Register-AgentChatTask(
    [string]$WorkingDirectory,
    [string]$SelectedDistro,
    [switch]$SkipWsl
) {
    Write-Step 'Registering Agent Chat background task'
    $taskName = 'CloudPcAgentChat'
    $existingTask = Get-ScheduledTask -TaskName $taskName `
        -ErrorAction SilentlyContinue
    if ($existingTask) {
        $existingTask | Stop-ScheduledTask
        Start-Sleep -Seconds 1
    }
    $projectPattern = (
        [regex]::Escape((Join-Path $projectRoot 'src\server.mjs')) +
        '|(?:^|\s)(?:\.\\)?src[\\/]server\.mjs(?:\s|$)'
    )
    $staleHosts = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -match $projectPattern
            } |
            Select-Object -ExpandProperty ProcessId -Unique
    )
    foreach ($processId in $staleHosts) {
        Stop-Process -Id ([int]$processId) -Force `
            -ErrorAction SilentlyContinue
    }

    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) {
        $pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    $startScript = Join-Path $projectRoot 'scripts\start-host.ps1'
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$startScript`"",
        '-Distro', "`"$SelectedDistro`""
    )
    if ($SkipWsl) { $arguments += '-SkipWsl' }
    if ($WorkingDirectory) {
        $arguments += @('-WorkingDirectory', "`"$WorkingDirectory`"")
    }
    $serverDir = Join-Path $HOME '.cloudpc-agent\server'
    New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
    $launcher = Join-Path $serverDir 'agent-chat-hidden.vbs'
    $hostCommand = ('"{0}" {1}' -f $pwsh, ($arguments -join ' '))
    $escapedCommand = $hostCommand.Replace('"', '""')
    @"
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("$escapedCommand", 0, True)
WScript.Quit exitCode
"@ | Set-Content $launcher -Encoding ASCII

    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    $action = New-ScheduledTaskAction -Execute $wscript `
        -Argument ('//B //NoLogo "{0}"' -f $launcher)
    $trigger = New-ScheduledTaskTrigger -AtLogOn `
        -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 5 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Trigger $trigger -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName

    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        try {
            $health = Invoke-RestMethod 'http://127.0.0.1:8787/api/health' `
                -TimeoutSec 2
            if ($health.ok) { return }
        } catch {}
    } while ((Get-Date) -lt $deadline)

    throw 'Agent Chat task started but its health endpoint did not become ready.'
}

function Restart-SelectedTunnelHost([string]$SelectedTunnel) {
    Write-Step 'Refreshing selected Dev Tunnel host'
    $oldTaskName = "DevboxCliHost-$SelectedTunnel"
    $oldTask = Get-ScheduledTask -TaskName $oldTaskName `
        -ErrorAction SilentlyContinue
    if ($oldTask) { $oldTask | Stop-ScheduledTask }
    Start-Sleep -Seconds 1

    # Task Scheduler can leave the wrapper or its child alive. Match only this
    # tunnel's command lines, collect explicit PIDs, then stop those PIDs.
    $escaped = [regex]::Escape($SelectedTunnel)
    $stale = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -match $escaped -and
                (
                    $_.CommandLine -match '(?i)devtunnel(?:\.exe)?\s+host' -or
                    $_.CommandLine -match '(?i)host\.ps1'
                )
            } |
            Select-Object -ExpandProperty ProcessId -Unique
    )
    foreach ($processId in $stale) {
        try {
            Stop-Process -Id ([int]$processId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not stop stale tunnel process ${processId}: $($_.Exception.Message)"
        }
    }

    if ($oldTask) {
        Disable-ScheduledTask -TaskName $oldTaskName | Out-Null
    }

    $safeId = $SelectedTunnel -replace '[^A-Za-z0-9_.-]', '_'
    $taskName = "CloudPcAgentTunnelHost-$safeId"
    $hostScript = Join-Path $projectRoot 'scripts\tunnel-host.ps1'
    $serverDir = Join-Path $HOME '.cloudpc-agent\server'
    New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
    $launcher = Join-Path $serverDir "tunnel-host-$safeId.vbs"
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) {
        $pwsh = Join-Path $env:SystemRoot `
            'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    $command = (
        '"{0}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
        '-File "{1}" -TunnelId "{2}"'
    ) -f $pwsh, $hostScript, $SelectedTunnel
    $escapedCommand = $command.Replace('"', '""')
    @"
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("$escapedCommand", 0, True)
WScript.Quit exitCode
"@ | Set-Content $launcher -Encoding ASCII

    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    $action = New-ScheduledTaskAction -Execute $wscript `
        -Argument ('//B //NoLogo "{0}"' -f $launcher)
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser `
        -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Hosts cloudpc-agent ports through Microsoft Dev Tunnels.' `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName

    $deadline = (Get-Date).AddSeconds(45)
    do {
        Start-Sleep -Seconds 1
        try {
            $show = & devtunnel show $SelectedTunnel --json 2>$null |
                ConvertFrom-Json
            if ([int]$show.tunnel.hostConnections -ge 1) { return }
        } catch {}
    } while ((Get-Date) -lt $deadline)
    throw "Dev Tunnel host did not recover after restarting task '$taskName'."
}

function Install-Host {
    Assert-Administrator
    Install-WingetPackage 'OpenJS.NodeJS.LTS' 'node'
    Install-WingetPackage 'GitHub.Copilot' 'copilot'

    if ($WebOnly) {
        $selectedTunnel = Ensure-WebTunnel
        Ensure-CopilotLogin
        Restart-SelectedTunnelHost $selectedTunnel
        Register-AgentChatTask -WorkingDirectory $AgentWorkingDirectory `
            -SelectedDistro $Distro -SkipWsl

        Write-Host "`nWeb Chat host is ready." -ForegroundColor Green
        Write-Host "Tunnel ID : $selectedTunnel"
        Write-Host 'Web Chat  : http://127.0.0.1:8787 (private tunnel)'
        Write-Host ''
        Write-Host 'Run this from the client checkout:'
        $profileName = $env:COMPUTERNAME.ToLowerInvariant()
        Write-Host (
            ".\install.ps1 -Client -WebOnly -Name '$profileName' " +
            "-TunnelId '$selectedTunnel'"
        )
        return
    }

    Ensure-Wsl
    Ensure-WindowsOpenSsh

    $selectedTunnel = Install-WindowsFoundation
    Ensure-CopilotLogin

    Write-Step 'Configuring WSL runtime and private web channel'
    & (Join-Path $projectRoot 'scripts\setup-host.ps1') `
        -TunnelId $selectedTunnel -Distro $Distro

    Restart-SelectedTunnelHost $selectedTunnel

    Register-AgentChatTask -WorkingDirectory $AgentWorkingDirectory `
        -SelectedDistro $Distro

    $linuxUser = $LinuxSshUser
    if (-not $linuxUser) {
        $linuxUser = (& wsl.exe -d $Distro -- whoami).Trim()
    }
    $windowsUser = $WindowsSshUser
    if (-not $windowsUser) {
        $windowsUser = Get-WindowsSshUser
    }

    Write-Host "`nCloud PC host is ready." -ForegroundColor Green
    Write-Host "Tunnel ID       : $selectedTunnel"
    Write-Host "Windows SSH user: $windowsUser (corporate domain UPN)"
    Write-Host "WSL SSH user    : $linuxUser"
    Write-Host 'Agent Chat      : http://127.0.0.1:8787 (private tunnel port 8787)'
    Write-Host ''
    Write-Host 'If the WSL user has no SSH password, run:'
    Write-Host "  wsl.exe -d $Distro -u root -- passwd $linuxUser"
    Write-Host ''
    Write-Host 'Run this from the cloudpc-agent checkout on the Windows client:'
    $profileName = $env:COMPUTERNAME.ToLowerInvariant()
    Write-Host (
        ".\install.ps1 -Client -Name '$profileName' " +
        "-TunnelId '$selectedTunnel' " +
        "-WindowsSshUser '$windowsUser' -LinuxSshUser '$linuxUser'"
    )
}

function Install-Client {
    if (-not $TunnelId) { throw '-TunnelId is required in Client mode.' }
    if (-not $WebOnly -and -not $WindowsSshUser) {
        throw '-WindowsSshUser is required unless -WebOnly is specified.'
    }
    if (-not $WebOnly -and -not $LinuxSshUser) {
        throw '-LinuxSshUser is required unless -WebOnly is specified.'
    }

    Ensure-DevtunnelLogin

    & (Join-Path $projectRoot 'scripts\install-client.ps1') `
        -Name $Name `
        -TunnelId $TunnelId `
        -WindowsSshUser $WindowsSshUser `
        -LinuxSshUser $LinuxSshUser `
        -WebOnly:$WebOnly

    Write-Host "`nClient is ready." -ForegroundColor Green
    Write-Host '  cloudpc agent'
    if (-not $WebOnly) {
        Write-Host 'Windows SSH requires the corporate domain account password.'
        Write-Host '  cloudpc pwsh'
        Write-Host '  cloudpc bash'
    }
}

if ($Status) {
    & (Join-Path $projectRoot 'scripts\show-connection.ps1') `
        -TunnelId $TunnelId -Distro $Distro -WebOnly:$WebOnly
}
elseif ($Server) {
    Install-Host
}
else {
    Install-Client
}
