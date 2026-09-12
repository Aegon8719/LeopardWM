# Bounded diagnostics validation child runner.
# Reads a JSON data file; cleans only children it started via retained Process objects.
# The parent is the sole coordinator of the shared session stop file.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DataPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DataPath)) {
    throw "runner data file missing: $DataPath"
}

$Data = Get-Content -LiteralPath $DataPath -Raw | ConvertFrom-Json
if ($null -eq $Data.runDir -or $null -eq $Data.stopPath -or $null -eq $Data.children) {
    throw 'runner data missing runDir, stopPath, or children'
}

$WorkingDir = [string]$Data.runDir
if ($Data.PSObject.Properties.Name -contains 'workingDir' -and -not [string]::IsNullOrWhiteSpace([string]$Data.workingDir)) {
    $WorkingDir = [string]$Data.workingDir
}
if (-not (Test-Path -LiteralPath $WorkingDir)) { throw "runner working directory missing: $WorkingDir" }

$TimeoutSec = 90
if ($null -ne $Data.timeoutSec) { $TimeoutSec = [int]$Data.timeoutSec }
if ($TimeoutSec -lt 1) { $TimeoutSec = 1 }
if ($TimeoutSec -gt 120) { $TimeoutSec = 120 }

$Deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
$Started = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]

function Convert-EnvMap($EnvObject) {
    $map = @{}
    if ($null -eq $EnvObject) { return $map }
    foreach ($p in $EnvObject.PSObject.Properties) {
        $map[$p.Name] = [string]$p.Value
    }
    return $map
}

function Join-ProcessArguments([string[]]$Arguments) {
    $parts = foreach ($argument in $Arguments) {
        $escaped = ([string]$argument -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1'
        '"' + $escaped + '"'
    }
    return $parts -join ' '
}

function Merge-FlagEnv($EnvMap, [string]$FlagPath) {
    if (-not (Test-Path -LiteralPath $FlagPath)) {
        throw "client flag missing: $FlagPath"
    }
    $flag = (Get-Content -LiteralPath $FlagPath -Raw) | ConvertFrom-Json
    if ($null -eq $flag.pipe -or $null -eq $flag.expected_pid -or $null -eq $flag.expected_creation) {
        throw 'client flag missing pipe/expected_pid/expected_creation'
    }
    if ([uint32]$flag.expected_pid -eq 0) { throw 'client flag expected_pid is 0' }
    if ([uint64]$flag.expected_creation -eq 0) { throw 'client flag expected_creation is 0' }
    $EnvMap['LEOPARDWM_DIAGNOSTICS_PIPE'] = [string]$flag.pipe
    $EnvMap['LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_PID'] = [string]$flag.expected_pid
    $EnvMap['LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_CREATION'] = [string]$flag.expected_creation
    return $EnvMap
}

function New-ChildRecord($Spec, $Process) {
    $record = [pscustomobject]@{
        Name             = [string]$Spec.name
        Process          = $Process
        Pid              = $null
        CreationFileTime = $null
    }
    $Started.Add($record) | Out-Null
    $record.Pid = [uint32]$Process.Id
    if ($Data.PSObject.Properties.Name -contains 'testFailStartTimeFor' -and [string]$Data.testFailStartTimeFor -eq $record.Name) {
        throw "injected StartTime failure for $($record.Name)"
    }
    $record.CreationFileTime = [uint64]$Process.StartTime.ToFileTimeUtc()
    return $record
}

function Start-ChildSpec($Spec) {
    if ($null -eq $Spec.exe -or -not (Test-Path -LiteralPath ([string]$Spec.exe))) {
        throw "child exe missing: $($Spec.exe)"
    }
    $envMap = Convert-EnvMap $Spec.env
    if ($Spec.start -eq 'flag') {
        $envMap = Merge-FlagEnv $envMap ([string]$Spec.flagPath)
    }
    $saved = @{}
    try {
        foreach ($name in @($envMap.Keys)) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, [string]$envMap[$name], 'Process')
        }
        $arguments = Join-ProcessArguments @($Spec.args)
        $process = Start-Process -FilePath ([string]$Spec.exe) -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput ([string]$Spec.stdout) -RedirectStandardError ([string]$Spec.stderr) -WorkingDirectory $WorkingDir
        if ($null -eq $process) {
            throw "Start-Process returned no handle for $($Spec.name)"
        }
        return New-ChildRecord $Spec $process
    } finally {
        foreach ($name in @($saved.Keys)) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
}

function Stop-RetainedProcess {
    param($Record, [int]$WaitMs)
    if ($null -eq $Record -or $null -eq $Record.Process) {
        throw 'missing retained process handle'
    }
    $process = $Record.Process
    try {
        if ($process.HasExited) { return [int]$process.ExitCode }
    } catch {
        throw "retained handle for $($Record.Name) is unusable: $_"
    }
    if ($process.WaitForExit($WaitMs)) {
        return [int]$process.ExitCode
    }
    try {
        $process.Kill()
    } catch {
        if (-not $process.HasExited) { throw }
    }
    if (-not $process.WaitForExit($WaitMs)) {
        throw "process $($Record.Name) pid $($Record.Pid) did not exit after kill"
    }
    return [int]$process.ExitCode
}

function Get-AuditChildren {
    $children = @()
    foreach ($record in $Started) {
        $exited = $false
        $code = $null
        try {
            $exited = [bool]$record.Process.HasExited
            if ($exited) { $code = [int]$record.Process.ExitCode }
        } catch {
            $Failures.Add("audit handle $($record.Name): $_") | Out-Null
        }
        $children += [pscustomobject]@{
            name             = $record.Name
            pid              = $record.Pid
            creation_filetime = $record.CreationFileTime
            exited           = $exited
            exitCode         = $code
        }
    }
    return $children
}

function Write-Audit([int]$ExitCode, $Children) {
    if ([string]::IsNullOrWhiteSpace([string]$Data.auditPath)) { return }
    $audit = [pscustomobject]@{
        exitCode         = $ExitCode
        failures         = @($Failures)
        expectedChildren = @($Data.children | ForEach-Object { [string]$_.name })
        children         = @($Children)
        gap              = 'skip_if_elevation_blocked is cfg(not(test)); this host is not full daemon startup/admission E2E.'
    }
    $tmp = "$($Data.auditPath).$PID.tmp"
    $audit | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination ([string]$Data.auditPath) -Force
}

$script:RunnerExit = 1
try {
    foreach ($spec in @($Data.children)) {
        if ([string]$spec.start -eq 'immediate') {
            $null = Start-ChildSpec $spec
        }
    }

    $flagSpecs = @($Data.children | Where-Object { [string]$_.start -eq 'flag' })
    $flagsStarted = $false
    while ([datetime]::UtcNow -lt $Deadline) {
        if (Test-Path -LiteralPath ([string]$Data.stopPath)) { break }
        foreach ($record in $Started) {
            if ($record.Process.HasExited -and [int]$record.Process.ExitCode -ne 0) {
                $Failures.Add("$($record.Name) exited $($record.Process.ExitCode)") | Out-Null
                break
            }
        }
        if ($Failures.Count -gt 0) { break }
        if (-not $flagsStarted -and $flagSpecs.Count -gt 0) {
            $ready = $true
            foreach ($spec in $flagSpecs) {
                if (-not (Test-Path -LiteralPath ([string]$spec.flagPath))) { $ready = $false }
            }
            if ($ready) {
                foreach ($spec in $flagSpecs) {
                    $null = Start-ChildSpec $spec
                }
                $flagsStarted = $true
            }
        }
        $allExited = $Started.Count -gt 0
        foreach ($record in $Started) {
            if (-not $record.Process.HasExited) { $allExited = $false }
        }
        if ($allExited -and ($flagSpecs.Count -eq 0 -or $flagsStarted)) { break }
        Start-Sleep -Milliseconds 100
    }

    if ([datetime]::UtcNow -ge $Deadline) {
        $Failures.Add('runner deadline exceeded') | Out-Null
    }
} catch {
    $Failures.Add("$_") | Out-Null
} finally {
    foreach ($record in $Started) {
        try {
            $code = Stop-RetainedProcess -Record $record -WaitMs 8000
            if ($code -ne 0) {
                $Failures.Add("$($record.Name) exit $code") | Out-Null
            }
        } catch {
            $Failures.Add("cleanup $($record.Name): $_") | Out-Null
        }
    }
    $auditChildren = @(Get-AuditChildren)
    if ($Failures.Count -eq 0) { $script:RunnerExit = 0 }
    try {
        Write-Audit $script:RunnerExit $auditChildren
    } catch {
        $Failures.Add("audit write: $_") | Out-Null
        $script:RunnerExit = 1
        [Console]::Error.WriteLine("diagnostics validation audit write failed: $_")
    }
}

exit $script:RunnerExit
