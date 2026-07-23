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
    [string]$CommandName = 'cpctunnel',
    [string]$WindowsSession = 'cpctunnel',
    [string]$LinuxSession = 'cpctunnel',
    [int]$WindowsSshPort = 22,
    [int]$LinuxSshPort = 2222,
    [int]$AgentChatPort = 8787,
    [string]$WindowsIdentityFile = '',
    [string]$LinuxIdentityFile = '',
    [ValidateSet('devtunnel', 'ssh-jump')]
    [string[]]$Transport = @('devtunnel'),
    [string[]]$TcpChannel = @(),
    [string]$AgentWorkingDirectory = '~',
    [switch]$SkipPackageInstall
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = $PSScriptRoot
$stateRoot = Join-Path $HOME '.cloudpc-tunnel'
$scriptBoundParameterNames = @($PSBoundParameters.Keys)

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Read-Text([string]$Prompt, [string]$Default = '') {
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $value = Read-Host "$Prompt$suffix"
    if (-not $value -and $Default) { return $Default }
    return $value
}

function Read-YesNo([string]$Prompt, [bool]$Default = $false) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    do {
        $value = Read-Host "$Prompt [$hint]"
        if (-not $value) { return $Default }
        switch -Regex ($value) {
            '^(y|yes)$' { return $true }
            '^(n|no)$' { return $false }
            default { Write-Warning 'Enter y or n.' }
        }
    } while ($true)
}

function Get-WindowsSshUser {
    $whoami = (& whoami.exe 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $whoami) {
        return $whoami
    }
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Read-Menu([string]$Prompt, [string[]]$Choices, [int]$Default = 1) {
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Cyan
    for ($i = 0; $i -lt $Choices.Count; $i++) {
        $marker = if (($i + 1) -eq $Default) { '*' } else { ' ' }
        Write-Host ("  {0}{1}. {2}" -f $marker, ($i + 1), $Choices[$i])
    }
    do {
        $answer = Read-Host "Select [1-$($Choices.Count), default $Default]"
        if (-not $answer) { return $Default }
        $selection = 0
        if ([int]::TryParse($answer, [ref]$selection) -and
            $selection -ge 1 -and $selection -le $Choices.Count) {
            return $selection
        }
        Write-Warning 'Enter one of the listed numbers.'
    } while ($true)
}

function Invoke-InstallWizard {
    Write-Host ''
    Write-Host 'cloudpc-tunnel setup' -ForegroundColor Green
    Write-Host 'Build a private, reliable TCP link between this client and a Cloud PC.'

    $choice = Read-Menu 'What do you want to configure?' @(
        'Cloud PC host: configure this Windows 365 Cloud PC as the tunnel host',
        'Client device: configure this device to connect to a Cloud PC',
        'Status: inspect a Cloud PC tunnel'
    ) 1
    $script:Server = $choice -eq 1
    $script:Client = $choice -eq 2
    $script:Status = $choice -eq 3

    if ($script:Server -or $script:Client) {
        $transportChoice = Read-Menu 'Which private transport should be configured?' @(
            'Microsoft Dev Tunnels private access (recommended)',
            'SSH jump host (planned, not implemented in this preview)'
        ) 1
        $script:Transport = switch ($transportChoice) {
            1 { @('devtunnel') }
            2 { @('ssh-jump') }
        }

        $mode = Read-Menu 'Which application set should be enabled?' @(
            'Recommended: Windows SSH, Web Chat, and optional custom TCP channels',
            'Full: Windows SSH, WSL SSH, Web Chat, and optional custom TCP channels',
            'Web-only: Web Chat plus optional custom TCP channels',
            'Custom: choose each capability'
        ) 1
        $script:WebOnly = $mode -eq 3
        if ($mode -eq 1) {
            $script:LinuxSshPort = 0
        }
        elseif ($mode -eq 4) {
            $enableWindows = Read-YesNo 'Enable Windows OpenSSH channel?' $true
            $enableWsl = Read-YesNo 'Enable WSL OpenSSH channel?' $false
            $enableWeb = Read-YesNo 'Enable Web Chat channel?' $true
            if (-not $enableWindows) { $script:WindowsSshPort = 0 }
            if (-not $enableWsl) { $script:LinuxSshPort = 0 }
            if (-not $enableWeb) { $script:AgentChatPort = 0 }
            $script:WebOnly = (-not $enableWindows) -and (-not $enableWsl) -and $enableWeb
        }
    }

    if (-not $script:Status) {
        $script:CommandName = Read-Text 'CLI command name' $CommandName
    }
    $script:TunnelId = Read-Text 'Existing Dev Tunnel ID with cluster suffix, or blank to create/use one' $TunnelId

    if ($script:Client) {
        $defaultName = if ($Name) { $Name } elseif ($TunnelId) { $TunnelId.Split('.')[0] } else { $env:COMPUTERNAME.ToLowerInvariant() }
        $script:Name = Read-Text 'Client profile name' $defaultName
    }
    elseif ($script:Server) {
        $defaultName = if ($Name) { $Name } else { $env:COMPUTERNAME.ToLowerInvariant() }
        $script:Name = Read-Text 'Cloud PC profile name for client setup' $defaultName
    }

    if (-not $script:WebOnly -and $script:WindowsSshPort -ne 0) {
        $script:WindowsSshPort = [int](Read-Text 'Windows SSH host port' "$WindowsSshPort")
        $script:WindowsSession = Read-Text 'Default Windows psmux session' $WindowsSession
        if ($script:Client) {
            $script:WindowsSshUser = Read-Text 'Windows SSH user, for example DOMAIN\user' $WindowsSshUser
            $script:WindowsIdentityFile = Read-Text 'Windows SSH private key path, blank for password auth' $WindowsIdentityFile
        }
        elseif ($script:Server) {
            $defaultSshUser = if ($WindowsSshUser) { $WindowsSshUser } else { Get-WindowsSshUser }
            $script:WindowsSshUser = Read-Text 'Windows SSH user for client setup' $defaultSshUser
        }

    }

    if (-not $script:WebOnly -and $script:LinuxSshPort -ne 0) {
        $script:LinuxSshPort = [int](Read-Text 'WSL SSH host port' "$LinuxSshPort")
        $script:LinuxSession = Read-Text 'Default WSL tmux session' $LinuxSession
        if ($script:Server) {
            $script:Distro = Read-Text 'WSL distro name' $Distro
        }
        if ($script:Client) {
            $script:LinuxSshUser = Read-Text 'WSL SSH user' $LinuxSshUser
            $script:LinuxIdentityFile = Read-Text 'WSL SSH private key path, blank for password auth' $LinuxIdentityFile
        }
    }

    $script:AgentChatPort = [int](Read-Text 'Web Chat host port, 0 to disable' "$AgentChatPort")
    if ($script:Server -and $script:AgentChatPort -gt 0) {
        $script:AgentWorkingDirectory = Read-Text 'Default agent working directory' $AgentWorkingDirectory
    }

    $channels = [Collections.Generic.List[string]]::new()
    while (Read-YesNo 'Add another custom TCP channel?' $false) {
        $channelName = Read-Text 'Channel name, for example websocket or api'
        $channelPort = Read-Text 'Cloud PC host port'
        $channelKind = Read-Text 'Channel kind label' 'tcp'
        $channels.Add("${channelName}=${channelPort}:$channelKind")
    }
    $script:TcpChannel = $channels.ToArray()
}

$selectedActions = @($Server, $Client, $Status) | Where-Object { $_ }
if (@($selectedActions).Count -eq 0) {
    Invoke-InstallWizard
}
elseif (@($selectedActions).Count -gt 1) {
    throw 'Specify only one action: -Server, -Client, or -Status.'
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

function Assert-TunnelId([string]$Value) {
    if ($Value -and $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*[.][A-Za-z0-9-]+$') {
        throw 'TunnelId must be the full canonical Dev Tunnel ID, including cluster suffix.'
    }
}

function Normalize-TunnelId($Value) {
    foreach ($item in @($Value)) {
        if (-not $item) { continue }
        $candidates = @()
        if ($item -is [string]) {
            $candidates += $item
        }
        else {
            $candidates += @(
                [string]$item.tunnel.tunnelId,
                [string]$item.tunnelId,
                [string]$item.TunnelId
            )
        }
        foreach ($candidate in $candidates) {
            $candidate = "$candidate".Trim()
            if ($candidate -match '^[A-Za-z0-9][A-Za-z0-9.-]*[.][A-Za-z0-9-]+$') {
                return $candidate
            }
        }
    }
    return ''
}

function Assert-Port([int]$Port, [string]$Label) {
    if ($Port -lt 0 -or $Port -gt 65535) {
        throw "$Label must be between 0 and 65535."
    }
}

function Get-ExtraTcpChannels {
    @(
        foreach ($entry in $TcpChannel) {
            if ($entry -notmatch '^([A-Za-z0-9_.-]+)[:=](\d{1,5})(?::([A-Za-z0-9_.-]+))?$') {
                throw "TcpChannel must use name=port or name:port[:kind], got: $entry"
            }
            [pscustomobject]@{
                Name = $Matches[1]
                Port = [int]$Matches[2]
                Kind = if ($Matches[3]) { $Matches[3] } else { 'tcp' }
            }
        }
    )
}

function Ensure-DevtunnelLogin {
    if ('devtunnel' -notin $Transport) { return }
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

function Get-CreatedTunnelId($Created) {
    $selectedTunnel = Normalize-TunnelId $Created
    if (-not $selectedTunnel) {
        throw 'Dev Tunnel was created but its ID was not returned.'
    }
    return $selectedTunnel
}

function ConvertFrom-DevtunnelJsonOutput([object[]]$Output) {
    $text = ($Output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) {
        throw 'Dev Tunnel command did not return a JSON object.'
    }
    $json = $text.Substring($start, $end - $start + 1)
    return $json | ConvertFrom-Json
}

function Ensure-LinkTunnel([int[]]$Ports) {
    if ('ssh-jump' -in $Transport) {
        throw 'SSH jump host transport is planned but not implemented in this preview. Select Microsoft Dev Tunnels for this version.'
    }
    if ('devtunnel' -notin $Transport) {
        throw 'SSH jump host transport is planned but not implemented in this preview. Select Microsoft Dev Tunnels for this version.'
    }
    Ensure-DevtunnelLogin
    Assert-TunnelId $TunnelId
    $serverDir = Join-Path $stateRoot 'server'
    $savedTunnelFile = Join-Path $serverDir 'tunnel-id'
    $selectedTunnel = Normalize-TunnelId $TunnelId
    if (-not $selectedTunnel -and (Test-Path $savedTunnelFile)) {
        $savedTunnel = Normalize-TunnelId (Get-Content $savedTunnelFile -Raw)
        if ($savedTunnel) {
            Assert-TunnelId $savedTunnel
            $selectedTunnel = $savedTunnel
            Write-Host "Reusing saved cloudpc-tunnel tunnel: $selectedTunnel" `
                -ForegroundColor Green
        }
    }
    if ($selectedTunnel) {
        $document = & devtunnel show $selectedTunnel --json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $document) {
            if ($TunnelId) {
                throw "Configured Dev Tunnel was not found: $selectedTunnel"
            }
            throw (
                "Saved cloudpc-tunnel Dev Tunnel was not found: $selectedTunnel. " +
                "Pass -TunnelId to select a different tunnel or remove $savedTunnelFile."
            )
        }
    }
    else {
        Write-Step 'Creating private cloudpc-tunnel'
        $createOutput = @(
            & devtunnel create --description 'cloudpc-tunnel private TCP tunnel' --json 2>&1
        )
        if ($LASTEXITCODE -ne 0) {
            if ($createOutput) { Write-Host ($createOutput -join [Environment]::NewLine) }
            throw 'Failed to create Dev Tunnel.'
        }
        $created = ConvertFrom-DevtunnelJsonOutput $createOutput
        $selectedTunnel = Normalize-TunnelId (Get-CreatedTunnelId $created)
    }
    $selectedTunnel = Normalize-TunnelId $selectedTunnel
    Assert-TunnelId $selectedTunnel

    $portDocument = & devtunnel port list $selectedTunnel --json |
        ConvertFrom-Json
    $published = @(
        $portDocument.ports | ForEach-Object { [int]$_.portNumber }
    )
    foreach ($port in @($Ports | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        Assert-Port $port "Tunnel port $port"
        if ($port -notin $published) {
            $description = switch ($port) {
                $WindowsSshPort { 'Windows OpenSSH' }
                $LinuxSshPort { 'WSL OpenSSH' }
                $AgentChatPort { 'cloudpc-tunnel Web Chat' }
                default { 'cloudpc-tunnel TCP channel' }
            }
            & devtunnel port create $selectedTunnel `
                --port-number $port `
                --protocol auto `
                --description $description | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to publish tunnel port $port."
            }
        }
    }

    New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
    Set-Content (Join-Path $serverDir 'tunnel-id') `
        $selectedTunnel -Encoding ASCII
    return $selectedTunnel
}

function Quote-InstallArgument([string]$Value) {
    "'" + $Value.Replace("'", "''") + "'"
}

function New-ClientInstallCommand(
    [string]$SelectedTunnel,
    [string]$ProfileName,
    [string]$SelectedWindowsUser,
    [string]$SelectedLinuxUser
) {
    $args = [Collections.Generic.List[string]]::new()
    $args.Add('.\install.ps1')
    $args.Add('-Client')
    if ($WebOnly) { $args.Add('-WebOnly') }
    $args.Add('-Name')
    $args.Add((Quote-InstallArgument $ProfileName))
    $args.Add('-CommandName')
    $args.Add((Quote-InstallArgument $CommandName))
    $args.Add('-TunnelId')
    $args.Add((Quote-InstallArgument $SelectedTunnel))

    if (-not $WebOnly -and $WindowsSshPort -gt 0 -and $SelectedWindowsUser) {
        $args.Add('-WindowsSshUser')
        $args.Add((Quote-InstallArgument $SelectedWindowsUser))
        if ($WindowsSession -ne 'cpctunnel') {
            $args.Add('-WindowsSession')
            $args.Add((Quote-InstallArgument $WindowsSession))
        }
    }
    if ($WindowsSshPort -ne 22) {
        $args.Add('-WindowsSshPort')
        $args.Add("$WindowsSshPort")
    }

    if (-not $WebOnly -and $LinuxSshPort -gt 0 -and $SelectedLinuxUser) {
        $args.Add('-LinuxSshUser')
        $args.Add((Quote-InstallArgument $SelectedLinuxUser))
        if ($LinuxSession -ne 'cpctunnel') {
            $args.Add('-LinuxSession')
            $args.Add((Quote-InstallArgument $LinuxSession))
        }
    }
    if ($LinuxSshPort -ne 2222) {
        $args.Add('-LinuxSshPort')
        $args.Add("$LinuxSshPort")
    }

    if ($AgentChatPort -ne 8787) {
        $args.Add('-AgentChatPort')
        $args.Add("$AgentChatPort")
    }

    if ($TcpChannel.Count -gt 0) {
        $args.Add('-TcpChannel')
        $args.Add((@($TcpChannel | ForEach-Object { Quote-InstallArgument $_ }) -join ','))
    }

    return ($args -join ' ')
}

function New-PosixClientInstallCommand(
    [string]$SelectedTunnel,
    [string]$ProfileName,
    [string]$SelectedWindowsUser,
    [string]$SelectedLinuxUser
) {
    $args = [Collections.Generic.List[string]]::new()
    $args.Add('sh ./install.sh')
    $args.Add('--name')
    $args.Add((Quote-InstallArgument $ProfileName))
    $args.Add('--tunnel-id')
    $args.Add((Quote-InstallArgument $SelectedTunnel))
    if (-not $WebOnly -and $WindowsSshPort -gt 0 -and $SelectedWindowsUser) {
        $args.Add('--windows-ssh-user')
        $args.Add((Quote-InstallArgument $SelectedWindowsUser))
    }
    if (-not $WebOnly -and $LinuxSshPort -gt 0 -and $SelectedLinuxUser) {
        $args.Add('--linux-ssh-user')
        $args.Add((Quote-InstallArgument $SelectedLinuxUser))
    }
    if ($AgentChatPort -ne 8787) {
        $args.Add('--agent-chat-port')
        $args.Add("$AgentChatPort")
    }
    foreach ($channel in $TcpChannel) {
        $args.Add('--tcp-channel')
        $args.Add((Quote-InstallArgument $channel))
    }
    return ($args -join ' ')
}

function Write-ClientInstallHints(
    [string]$SelectedTunnel,
    [string]$ProfileName,
    [string]$SelectedWindowsUser,
    [string]$SelectedLinuxUser
) {
    Write-Host ''
    Write-Host 'Windows client:' -ForegroundColor Cyan
    Write-Host (New-ClientInstallCommand $SelectedTunnel $ProfileName $SelectedWindowsUser $SelectedLinuxUser)
    Write-Host ''
    Write-Host 'macOS/Linux client:' -ForegroundColor Cyan
    Write-Host 'git clone https://github.com/ww4yne/cloudpc-tunnel.git'
    Write-Host 'cd cloudpc-tunnel'
    Write-Host (New-PosixClientInstallCommand $SelectedTunnel $ProfileName $SelectedWindowsUser $SelectedLinuxUser)
}

function Save-HostConfig(
    [string]$SelectedTunnel,
    [string]$ProfileName,
    [string]$SelectedWindowsUser,
    [string]$SelectedLinuxUser
) {
    $serverDir = Join-Path $stateRoot 'server'
    New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
    [ordered]@{
        SchemaVersion = 1
        Name = $ProfileName
        TunnelId = $SelectedTunnel
        CommandName = $CommandName
        WebOnly = [bool]$WebOnly
        Transport = @($Transport)
        Distro = $Distro
        WindowsSshPort = [int]$WindowsSshPort
        LinuxSshPort = [int]$LinuxSshPort
        AgentChatPort = [int]$AgentChatPort
        WindowsSshUser = $SelectedWindowsUser
        LinuxSshUser = $SelectedLinuxUser
        WindowsSession = $WindowsSession
        LinuxSession = $LinuxSession
        TcpChannel = @($TcpChannel)
    } | ConvertTo-Json -Depth 4 |
        Set-Content (Join-Path $serverDir 'config.json') -Encoding UTF8
}

function Import-HostConfigForStatus {
    $configFile = Join-Path $stateRoot 'server\config.json'
    if (-not (Test-Path $configFile)) { return }
    $hostConfig = Get-Content $configFile -Raw | ConvertFrom-Json

    if ($scriptBoundParameterNames -notcontains 'TunnelId' -and
        -not $TunnelId -and
        $hostConfig.TunnelId) {
        $script:TunnelId = [string]$hostConfig.TunnelId
    }
    if ($scriptBoundParameterNames -notcontains 'Distro' -and $hostConfig.Distro) {
        $script:Distro = [string]$hostConfig.Distro
    }
    if ($scriptBoundParameterNames -notcontains 'WebOnly' -and $null -ne $hostConfig.WebOnly) {
        $script:WebOnly = [bool]$hostConfig.WebOnly
    }
    if ($scriptBoundParameterNames -notcontains 'WindowsSshPort' -and $null -ne $hostConfig.WindowsSshPort) {
        $script:WindowsSshPort = [int]$hostConfig.WindowsSshPort
    }
    if ($scriptBoundParameterNames -notcontains 'LinuxSshPort' -and $null -ne $hostConfig.LinuxSshPort) {
        $script:LinuxSshPort = [int]$hostConfig.LinuxSshPort
    }
    if ($scriptBoundParameterNames -notcontains 'AgentChatPort' -and $null -ne $hostConfig.AgentChatPort) {
        $script:AgentChatPort = [int]$hostConfig.AgentChatPort
    }
    if ($scriptBoundParameterNames -notcontains 'WindowsSshUser' -and $hostConfig.WindowsSshUser) {
        $script:WindowsSshUser = [string]$hostConfig.WindowsSshUser
    }
    if ($scriptBoundParameterNames -notcontains 'LinuxSshUser' -and $hostConfig.LinuxSshUser) {
        $script:LinuxSshUser = [string]$hostConfig.LinuxSshUser
    }
    if ($scriptBoundParameterNames -notcontains 'TcpChannel' -and $hostConfig.TcpChannel) {
        $script:TcpChannel = @($hostConfig.TcpChannel | ForEach-Object { [string]$_ })
    }
    if ($scriptBoundParameterNames -notcontains 'Name' -and $hostConfig.Name) {
        $script:Name = [string]$hostConfig.Name
    }
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
    Write-Host 'Inspecting Windows capability list with dism.exe...' `
        -ForegroundColor DarkCyan
    $dismOutput = & dism.exe /Online /Get-Capabilities 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "dism.exe /Get-Capabilities failed (exit $LASTEXITCODE)."
    }
    $name = ($dismOutput |
        Select-String -Pattern '^Capability Identity\s*:\s*(OpenSSH\.Server\S*)' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Select-Object -First 1)
    if (-not $name) { return $null }

    Write-Host "Reading OpenSSH capability state: $name" `
        -ForegroundColor DarkCyan
    $infoOutput = & dism.exe /Online /Get-CapabilityInfo /CapabilityName:$name 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "dism.exe /Get-CapabilityInfo failed (exit $LASTEXITCODE)."
    }
    $state = ($infoOutput |
        Select-String -Pattern '^State\s*:\s*(\S+)' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Select-Object -First 1)
    Write-Host "OpenSSH capability state: $state" -ForegroundColor DarkCyan
    [pscustomobject]@{ Name = $name; State = $state }
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
    Write-Host "Checking sshd_config: $configPath" -ForegroundColor DarkCyan
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
# cloudpc-tunnel: loopback-only SSH
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
                $_ -ne '# cloudpc-tunnel: loopback-only SSH' -and
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
        '# cloudpc-tunnel: loopback-only SSH',
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
    Write-Host 'Ensuring OpenSSH host keys...' -ForegroundColor DarkCyan
    & $sshKeygen -A
    if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen -A failed.' }

    # Windows sshd runs as SYSTEM and rejects private host keys with inherited
    # or broad ACLs. Half-initialized capability installs commonly leave these
    # files with the elevated user's inherited permissions.
    Write-Host 'Securing OpenSSH config and host key ACLs...' -ForegroundColor DarkCyan
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

    Write-Host 'Validating OpenSSH configuration...' -ForegroundColor DarkCyan
    & $sshd -t -f $configPath
    if ($LASTEXITCODE -ne 0) {
        throw "Generated OpenSSH configuration failed validation: $configPath"
    }

    Write-Host 'Starting Windows OpenSSH service...' -ForegroundColor DarkCyan
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
    $taskName = 'CloudPcTunnelWeb'
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
    if ($AgentChatPort -gt 0) {
        $arguments += @('-Port', "$AgentChatPort")
    }
    if ($WorkingDirectory) {
        $arguments += @('-WorkingDirectory', "`"$WorkingDirectory`"")
    }
    $serverDir = Join-Path $stateRoot 'server'
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
            $health = Invoke-RestMethod "http://127.0.0.1:$AgentChatPort/api/health" `
                -TimeoutSec 2
            if ($health.ok) { return }
        } catch {}
    } while ((Get-Date) -lt $deadline)

    throw 'Agent Chat task started but its health endpoint did not become ready.'
}

function Restart-SelectedTunnelHost([string]$SelectedTunnel) {
    Write-Step 'Refreshing selected Dev Tunnel host'
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

    $safeId = $SelectedTunnel -replace '[^A-Za-z0-9_.-]', '_'
    $taskName = "CloudPcTunnelHost-$safeId"
    $existingTask = Get-ScheduledTask -TaskName $taskName `
        -ErrorAction SilentlyContinue
    if ($existingTask) {
        $existingTask | Stop-ScheduledTask
        Start-Sleep -Seconds 1
    }
    $hostScript = Join-Path $projectRoot 'scripts\tunnel-host.ps1'
    $serverDir = Join-Path $stateRoot 'server'
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
        -Description 'Hosts cloudpc-tunnel ports through Microsoft Dev Tunnels.' `
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
    if (-not $WebOnly -and $WindowsSshPort -gt 0 -and $WindowsSshPort -ne 22) {
        throw 'Windows OpenSSH channel currently requires WindowsSshPort 22.'
    }
    if ($AgentChatPort -gt 0) {
        Install-WingetPackage 'OpenJS.NodeJS.LTS' 'node'
        Install-WingetPackage 'GitHub.Copilot' 'copilot'
    }
    if (-not $WebOnly -and $WindowsSshPort -gt 0) {
        Install-WingetPackage 'marlocarlo.psmux' 'psmux'
    }

    $extraPorts = @((Get-ExtraTcpChannels) | ForEach-Object Port)
    $selectedPorts = @($extraPorts)
    if (-not $WebOnly -and $WindowsSshPort -gt 0) { $selectedPorts += $WindowsSshPort }
    if (-not $WebOnly -and $LinuxSshPort -gt 0) { $selectedPorts += $LinuxSshPort }
    if ($AgentChatPort -gt 0) { $selectedPorts += $AgentChatPort }
    if ($selectedPorts.Count -eq 0) {
        throw 'Select at least one channel port to publish.'
    }
    $selectedTunnel = Ensure-LinkTunnel $selectedPorts

    if ($WebOnly) {
        if ($AgentChatPort -gt 0) { Ensure-CopilotLogin }
        Restart-SelectedTunnelHost $selectedTunnel
        if ($AgentChatPort -gt 0) {
            Register-AgentChatTask -WorkingDirectory $AgentWorkingDirectory `
                -SelectedDistro $Distro -SkipWsl
        }

        Write-Host "`ncloudpc-tunnel host is ready." -ForegroundColor Green
        Write-Host "Profile name: $profileName"
        Write-Host "Tunnel ID : $selectedTunnel"
        if ($AgentChatPort -gt 0) {
            Write-Host "Web Chat  : http://127.0.0.1:$AgentChatPort (private tunnel)"
        }
        $profileName = if ($Name) { $Name } else { $env:COMPUTERNAME.ToLowerInvariant() }
        Save-HostConfig $selectedTunnel $profileName '' ''
        Write-ClientInstallHints $selectedTunnel $profileName '' ''
        return
    }

    if ($WindowsSshPort -gt 0) { Ensure-WindowsOpenSsh }
    if ($LinuxSshPort -gt 0) { Ensure-Wsl }
    if ($AgentChatPort -gt 0) { Ensure-CopilotLogin }

    if ($LinuxSshPort -gt 0) {
        Write-Step 'Configuring WSL runtime'
        & (Join-Path $projectRoot 'scripts\setup-host.ps1') `
            -TunnelId $selectedTunnel -Distro $Distro `
            -WslSshPort $LinuxSshPort -AgentChatPort $AgentChatPort
    }

    Restart-SelectedTunnelHost $selectedTunnel

    if ($AgentChatPort -gt 0) {
        Register-AgentChatTask -WorkingDirectory $AgentWorkingDirectory `
            -SelectedDistro $Distro -SkipWsl:($LinuxSshPort -le 0)
    }

    $linuxUser = $LinuxSshUser
    if (-not $linuxUser -and $LinuxSshPort -gt 0) {
        $linuxUser = (& wsl.exe -d $Distro -- whoami).Trim()
    }
    $windowsUser = $WindowsSshUser
    if (-not $windowsUser) {
        $windowsUser = Get-WindowsSshUser
    }
    $profileName = if ($Name) { $Name } else { $env:COMPUTERNAME.ToLowerInvariant() }
    Save-HostConfig $selectedTunnel $profileName $windowsUser $linuxUser

    Write-Host "`ncloudpc-tunnel host is ready." -ForegroundColor Green
    Write-Host "Profile name    : $profileName"
    Write-Host "Tunnel ID       : $selectedTunnel"
    if ($WindowsSshPort -gt 0) { Write-Host "Windows SSH user: $windowsUser" }
    if ($LinuxSshPort -gt 0) { Write-Host "WSL SSH user    : $linuxUser" }
    if ($AgentChatPort -gt 0) { Write-Host "Web Chat        : http://127.0.0.1:$AgentChatPort (private tunnel)" }
    if ($LinuxSshPort -gt 0) {
        Write-Host ''
        Write-Host 'If the WSL user has no SSH password, run:'
        Write-Host "  wsl.exe -d $Distro -u root -- passwd $linuxUser"
    }
    Write-ClientInstallHints $selectedTunnel $profileName $windowsUser $linuxUser
}

function Install-Client {
    if (-not $TunnelId) { throw '-TunnelId is required in Client mode.' }
    if ('ssh-jump' -in $Transport -or 'devtunnel' -notin $Transport) {
        throw 'SSH jump host transport is planned but not implemented in this preview. Select Microsoft Dev Tunnels for this version.'
    }
    if (-not $WebOnly -and $WindowsSshPort -gt 0 -and -not $WindowsSshUser) {
        throw '-WindowsSshUser is required unless -WebOnly is specified.'
    }
    if (-not $WebOnly -and $LinuxSshPort -gt 0 -and -not $LinuxSshUser) {
        throw '-LinuxSshUser is required unless -WebOnly is specified.'
    }

    Ensure-DevtunnelLogin

    & (Join-Path $projectRoot 'scripts\install-client.ps1') `
        -Name $Name `
        -TunnelId $TunnelId `
        -WindowsSshUser $WindowsSshUser `
        -LinuxSshUser $LinuxSshUser `
        -WebOnly:$WebOnly `
        -CommandName $CommandName `
        -WindowsSession $WindowsSession `
        -LinuxSession $LinuxSession `
        -WindowsSshPort $WindowsSshPort `
        -LinuxSshPort $LinuxSshPort `
        -AgentChatPort $AgentChatPort `
        -WindowsIdentityFile $WindowsIdentityFile `
        -LinuxIdentityFile $LinuxIdentityFile `
        -Transport $Transport `
        -TcpChannel $TcpChannel

    Write-Host "`nClient is ready." -ForegroundColor Green
    if ($AgentChatPort -gt 0) { Write-Host "  $CommandName agent" }
    if (-not $WebOnly -and $WindowsSshPort -gt 0) { Write-Host "  $CommandName pwsh" }
    if (-not $WebOnly -and $LinuxSshPort -gt 0) { Write-Host "  $CommandName bash" }
}

if ($Status) {
    Import-HostConfigForStatus
    & (Join-Path $projectRoot 'scripts\show-connection.ps1') `
        -TunnelId $TunnelId `
        -Name $Name `
        -Distro $Distro `
        -WindowsSshPort $WindowsSshPort `
        -LinuxSshPort $LinuxSshPort `
        -AgentChatPort $AgentChatPort `
        -WindowsSshUser $WindowsSshUser `
        -LinuxSshUser $LinuxSshUser `
        -TcpChannel $TcpChannel `
        -WebOnly:$WebOnly
}
elseif ($Server) {
    Install-Host
}
else {
    Install-Client
}
