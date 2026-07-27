[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SshdPath,
    [Parameter(Mandatory)]
    [string]$ConfigPath,
    [int]$Port = 22
)

$ErrorActionPreference = 'Stop'
$stateDir = Join-Path $HOME '.cloudpc-tunnel\server'
$hostLog = Join-Path $stateDir 'sshd-host.log'
$outLog = Join-Path $stateDir 'sshd.out.log'
$errLog = Join-Path $stateDir 'sshd.err.log'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

function Rotate-Log([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    if ((Get-Item $Path).Length -lt 5MB) { return }
    $previous = "$Path.1"
    Remove-Item $previous -Force -ErrorAction SilentlyContinue
    Move-Item $Path $previous -Force
}

function Write-Log([string]$Message) {
    Add-Content $hostLog ('[{0:u}] {1}' -f (Get-Date), $Message) -Encoding UTF8
}

function Get-SshdListeners {
    @(
        Get-NetTCPConnection -State Listen -LocalPort $Port `
            -ErrorAction SilentlyContinue
    )
}

function Get-FallbackProcess {
    $escapedSshd = [regex]::Escape($SshdPath)
    $escapedConfig = [regex]::Escape($ConfigPath)
    @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -match $escapedSshd -and
                $_.CommandLine -match '\s-D(?:\s|$)' -and
                $_.CommandLine -match $escapedConfig
            } |
            Select-Object -First 1
    )
}

if (-not (Test-Path $SshdPath)) {
    throw "sshd executable not found: $SshdPath"
}
if (-not (Test-Path $ConfigPath)) {
    throw "sshd configuration not found: $ConfigPath"
}

foreach ($path in @($hostLog, $outLog, $errLog)) {
    Rotate-Log $path
}

$backoff = 2
while ($true) {
    $process = $null
    $startedAt = $null
    $listeners = @(Get-SshdListeners)
    $service = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $listeners -and $service.Status -eq 'Running') {
        Write-Log 'sshd service is running without a listener; waiting 10 seconds'
        Start-Sleep -Seconds 10
        $service.Refresh()
        $listeners = @(Get-SshdListeners)
        if (-not $listeners -and $service.Status -eq 'Running') {
            Write-Log 'stopping unhealthy sshd service before fallback takeover'
            Stop-Service sshd -Force -ErrorAction SilentlyContinue
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10))
        }
    }
    if ($listeners) {
        $nonLoopback = @(
            $listeners |
                Where-Object LocalAddress -NotIn @('127.0.0.1', '::1')
        )
        if ($nonLoopback) {
            throw 'sshd is listening beyond loopback; refusing unsafe fallback.'
        }

        if ($service.Status -eq 'Running') {
            Write-Log 'monitoring healthy Windows sshd service'
            do {
                Start-Sleep -Seconds 2
                $service.Refresh()
                $listeners = @(Get-SshdListeners)
            } while ($service.Status -eq 'Running' -and $listeners)
            Write-Log (
                'Windows sshd service or listener stopped; waiting 10 seconds ' +
                'for Service Control Manager recovery'
            )
            Start-Sleep -Seconds 10
            continue
        }

        $existing = @(Get-FallbackProcess)
        if ($existing.Count -ne 1) {
            throw "TCP $Port is listening but no unique fallback sshd process owns it."
        }
        $process = Get-Process -Id ([int]$existing[0].ProcessId) `
            -ErrorAction SilentlyContinue
        Write-Log "monitoring existing fallback sshd pid=$($existing[0].ProcessId)"
    }
    else {
        Write-Log "starting fallback sshd on loopback port $Port"
        $startedAt = Get-Date
        $process = Start-Process -FilePath $SshdPath `
            -ArgumentList @('-D', '-e', '-f', "`"$ConfigPath`"") `
            -RedirectStandardOutput $outLog `
            -RedirectStandardError $errLog `
            -WindowStyle Hidden -PassThru

        $deadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 500
            if ($process.HasExited) { break }
            $listeners = @(Get-SshdListeners)
        } while (-not $listeners -and (Get-Date) -lt $deadline)

        if (-not $listeners -and -not $process.HasExited) {
            Write-Log 'fallback sshd did not listen within 20 seconds'
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    if ($process -and -not $process.HasExited) {
        $startedAt = Get-Date
        do {
            Start-Sleep -Seconds 2
            $process.Refresh()
        } while (-not $process.HasExited)
    }

    $runtime = if ($startedAt) { (Get-Date) - $startedAt } else {
        [TimeSpan]::Zero
    }
    if ($runtime.TotalMinutes -ge 5) { $backoff = 2 }
    $exitCode = if ($process -and $process.HasExited) {
        $process.ExitCode
    }
    else {
        'unknown'
    }
    Write-Log "fallback sshd exited code=$exitCode; retry in ${backoff}s"
    Start-Sleep -Seconds $backoff
    $backoff = [Math]::Min(60, $backoff * 2)
}
