# Bounded diagnostics-validation runner.
# It accepts only an immutable runner data file. A High instance cleans only its
# retained children when stopped, timed out, or its identity-bound controller exits.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DataPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DailyDriverPipe = '\\.\pipe\leopardwm'
$LocalDiagValPrefix = '\\.\pipe\leopardwm_diagval_'
$DiagnosticEnvNames = @(
    'LEOPARDWM_DIAGNOSTICS_VALIDATION', 'LEOPARDWM_DIAGNOSTICS_RUN_DIR',
    'LEOPARDWM_DIAGNOSTICS_TIMEOUT_SECS', 'LEOPARDWM_PIPE_SCOPE',
    'LEOPARDWM_DIAGNOSTICS_ROLE', 'LEOPARDWM_DIAGNOSTICS_OWN_HWND',
    'LEOPARDWM_DIAGNOSTICS_EVIDENCE_PREFIX', 'LEOPARDWM_DIAGNOSTICS_PIPE',
    'LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_PID', 'LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_CREATION'
)

function Test-ExactDiagValPipe([string]$Pipe) {
    if ([string]::IsNullOrWhiteSpace($Pipe) -or $Pipe -eq $DailyDriverPipe) { return $false }
    if (-not $Pipe.StartsWith($LocalDiagValPrefix)) { return $false }
    $suffix = $Pipe.Substring($LocalDiagValPrefix.Length)
    return -not [string]::IsNullOrWhiteSpace($suffix) -and $suffix -cmatch '^[a-z0-9._-]+$'
}

function Get-PipeName([string]$Pipe) {
    if (-not (Test-ExactDiagValPipe $Pipe)) { throw "not an exact diagnostics pipe: $Pipe" }
    return $Pipe.Substring('\\.\pipe\'.Length)
}

function Join-ProcessArguments([string[]]$Arguments) {
    $parts = foreach ($argument in $Arguments) {
        $escaped = ([string]$argument -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1'
        '"' + $escaped + '"'
    }
    return $parts -join ' '
}

function Test-ImagesMatch([string]$Left, [string]$Right) {
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    return ($Left.Replace('/', '\').TrimEnd('\')).Equals(($Right.Replace('/', '\').TrimEnd('\')), [StringComparison]::OrdinalIgnoreCase)
}

function Test-ControllerIdentityAlive($Identity) {
    $process = Get-Process -Id ([int]$Identity.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        if ([uint64]$process.StartTime.ToFileTimeUtc() -ne [uint64]$Identity.creation_filetime) { return $false }
        try { return Test-ImagesMatch ([string]$process.Path) ([string]$Identity.image) } catch { return $false }
    } catch { return $false }
}

function Assert-Controller($Data) {
    if ($Data.PSObject.Properties.Name -notcontains 'controller' -or $null -eq $Data.controller) { return $null }
    $controller = $Data.controller
    $names = @($controller.PSObject.Properties.Name)
    if ($names -notcontains 'pid' -or $names -notcontains 'creation_filetime' -or $names -notcontains 'image') {
        throw 'runner controller identity must include pid, creation_filetime, and image'
    }
    if ([uint32]$controller.pid -eq 0 -or [uint64]$controller.creation_filetime -eq 0 -or [string]::IsNullOrWhiteSpace([string]$controller.image)) {
        throw 'runner controller identity incomplete'
    }
    return $controller
}

function Convert-EnvMap($EnvObject) {
    $map = @{}
    if ($null -eq $EnvObject) { return $map }
    foreach ($property in $EnvObject.PSObject.Properties) { $map[$property.Name] = [string]$property.Value }
    return $map
}

function Merge-ServerIdentity($EnvMap, $Value, $Handoff) {
    $properties = @($Value.PSObject.Properties.Name)
    $allowed = @('kind', 'run_id', 'pipe', 'expected_pid', 'expected_creation')
    foreach ($name in $properties) {
        if ($allowed -notcontains $name) { throw "handoff has unsupported property $name" }
    }
    foreach ($name in $allowed) {
        if ($properties -notcontains $name) { throw "handoff missing $name" }
    }
    if ([string]$Value.kind -ne 'server_identity' -or [string]$Value.run_id -cne [string]$Handoff.run_id) { throw 'handoff run binding is invalid' }
    if ([string]$Value.pipe -cne [string]$Handoff.server_pipe) { throw 'handoff server pipe does not match the pinned target' }
    if (-not (Test-ExactDiagValPipe ([string]$Value.pipe))) { throw 'handoff pipe is not an exact diagnostics pipe' }
    if ([uint32]$Value.expected_pid -eq 0 -or [uint64]$Value.expected_creation -eq 0) { throw 'handoff server identity is incomplete' }
    $EnvMap['LEOPARDWM_DIAGNOSTICS_PIPE'] = [string]$Value.pipe
    $EnvMap['LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_PID'] = [string]$Value.expected_pid
    $EnvMap['LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_CREATION'] = [string]$Value.expected_creation
    return $EnvMap
}

function Receive-ServerIdentity($Handoff, $Controller, [datetime]$Deadline) {
    $properties = @($Handoff.PSObject.Properties.Name)
    if ($properties.Count -ne 3 -or $properties -notcontains 'pipe' -or $properties -notcontains 'run_id' -or $properties -notcontains 'server_pipe') { throw 'runner handoff configuration is not fixed schema' }
    $pipe = [string]$Handoff.pipe
    $runId = [string]$Handoff.run_id
    $serverPipe = [string]$Handoff.server_pipe
    if (-not (Test-ExactDiagValPipe $pipe) -or -not (Test-ExactDiagValPipe $serverPipe) -or $runId -notmatch '^[a-f0-9]{32}$') { throw 'runner handoff configuration is invalid' }
    $client = [IO.Pipes.NamedPipeClientStream]::new('.', (Get-PipeName $pipe), [IO.Pipes.PipeDirection]::In, [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        while (-not $client.IsConnected) {
            if ([datetime]::UtcNow -ge $Deadline) { throw 'runner deadline exceeded while connecting for server identity' }
            if ($null -ne $Controller -and -not (Test-ControllerIdentityAlive $Controller)) { throw 'controller identity lost' }
            try { $client.Connect(100) } catch [TimeoutException] {} catch [IO.IOException] {}
        }
        $bytes = New-Object byte[] 4097
        $count = 0
        while ($true) {
            $read = $client.ReadAsync($bytes, $count, 4097 - $count)
            while (-not $read.Wait(100)) {
                if ([datetime]::UtcNow -ge $Deadline) { throw 'runner deadline exceeded while reading server identity' }
                if ($null -ne $Controller -and -not (Test-ControllerIdentityAlive $Controller)) { throw 'controller identity lost' }
            }
            $received = $read.Result
            if ($received -eq 0) { break }
            $count += $received
            if ($count -eq 4097) { throw 'server identity handoff exceeds 4096 bytes' }
        }
        if ($count -eq 0) { throw 'server identity handoff is empty' }
        return ([Text.Encoding]::UTF8.GetString($bytes, 0, $count) | ConvertFrom-Json)
    } finally { $client.Dispose() }
}

if (-not (Test-Path -LiteralPath $DataPath)) { throw "runner data file missing: $DataPath" }
$Data = Get-Content -LiteralPath $DataPath -Raw | ConvertFrom-Json
foreach ($name in @('runDir', 'workingDir', 'stopPath', 'auditPath', 'children', 'environment_policy')) {
    if ($Data.PSObject.Properties.Name -notcontains $name -or $null -eq $Data.$name) { throw "runner data missing $name" }
}
if ([string]$Data.environment_policy -ne 'clear_diagnostics') { throw 'runner environment policy is not fixed' }
$RunDir = [string]$Data.runDir
$WorkingDir = [string]$Data.workingDir
if (-not (Test-Path -LiteralPath $WorkingDir)) { throw "runner working directory missing: $WorkingDir" }
if ($Data.PSObject.Properties.Name -contains 'createRunDir' -and [bool]$Data.createRunDir) {
    if (Test-Path -LiteralPath $RunDir) { throw "runner output directory already exists: $RunDir" }
    New-Item -ItemType Directory -Path $RunDir -ErrorAction Stop | Out-Null
} elseif (-not (Test-Path -LiteralPath $RunDir)) { throw "runner output directory missing: $RunDir" }

$Controller = Assert-Controller $Data
$TimeoutSec = if ($Data.PSObject.Properties.Name -contains 'timeoutSec') { [int]$Data.timeoutSec } else { 90 }
if ($TimeoutSec -lt 1 -or $TimeoutSec -gt 120) { throw 'runner timeout must be between 1 and 120 seconds' }
$Deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
$Started = New-Object System.Collections.Generic.List[object]
$Failures = New-Object System.Collections.Generic.List[string]

function Start-Child($Spec, $Identity, [bool]$RequireIdentity = $false) {
    if ([string]::IsNullOrWhiteSpace([string]$Spec.name) -or -not (Test-Path -LiteralPath ([string]$Spec.exe))) { throw "child executable missing for $($Spec.name)" }
    $env = Convert-EnvMap $Spec.env
    if ($RequireIdentity) {
        if ($null -eq $Identity) { throw 'handoff child is missing server identity' }
        $env = Merge-ServerIdentity $env $Identity $Data.handoff
    } elseif ($null -ne $Identity) { $env = Merge-ServerIdentity $env $Identity $Data.handoff }
    $saved = @{}
    try {
        foreach ($name in $DiagnosticEnvNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process'); [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
        foreach ($name in $env.Keys) { [Environment]::SetEnvironmentVariable($name, $env[$name], 'Process') }
        $process = Start-Process -FilePath ([string]$Spec.exe) -ArgumentList (Join-ProcessArguments @($Spec.args)) -PassThru -WindowStyle Hidden -RedirectStandardOutput ([string]$Spec.stdout) -RedirectStandardError ([string]$Spec.stderr) -WorkingDirectory $WorkingDir
        if ($null -eq $process) { throw "Start-Process returned no handle for $($Spec.name)" }
        $record = [pscustomobject]@{ Name = [string]$Spec.name; Process = $process; Pid = [uint32]$process.Id; CreationFileTime = $null; Image = [string]$Spec.exe; StopAfterExit = [bool]($Spec.PSObject.Properties.Name -contains 'stopAfterExit' -and $Spec.stopAfterExit) }
        $Started.Add($record) | Out-Null
        if ($Data.PSObject.Properties.Name -contains 'testFailStartTimeFor' -and [string]$Data.testFailStartTimeFor -eq $record.Name) { throw "injected StartTime failure for $($record.Name)" }
        $record.CreationFileTime = [uint64]$process.StartTime.ToFileTimeUtc()
        try { $record.Image = [string]$process.Path } catch {}
    } finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') } }
}

function Stop-Child($Record) {
    if ($Record.Process.HasExited) { return [int]$Record.Process.ExitCode }
    if ($Record.Process.WaitForExit(8000)) { return [int]$Record.Process.ExitCode }
    $Record.Process.Kill()
    if (-not $Record.Process.WaitForExit(8000)) { throw "process $($Record.Name) pid $($Record.Pid) did not exit after kill" }
    return [int]$Record.Process.ExitCode
}

function Write-Audit([int]$RunnerExitCode) {
    $children = foreach ($record in $Started) {
        $exited = $false; $childExitCode = $null
        try {
            $exited = $record.Process.HasExited
            if ($exited) { $childExitCode = [int]$record.Process.ExitCode }
            if ($Data.PSObject.Properties.Name -contains 'testFailAuditProbeFor' -and [string]$Data.testFailAuditProbeFor -eq $record.Name) { throw "injected audit handle failure for $($record.Name)" }
        } catch { $Failures.Add("audit handle $($record.Name): $_") | Out-Null }
        [pscustomobject]@{ name = $record.Name; pid = $record.Pid; creation_filetime = $record.CreationFileTime; image = $record.Image; exited = $exited; exitCode = $childExitCode }
    }
    if ($Failures.Count -ne 0) { $RunnerExitCode = 1 }
    $audit = [pscustomobject]@{ exitCode = $RunnerExitCode; failures = @($Failures); expectedChildren = @($Data.children | ForEach-Object { [string]$_.name }); children = @($children); controller = $Controller }
    $tmp = "$($Data.auditPath).$PID.tmp"
    $audit | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination ([string]$Data.auditPath) -Force
    return $RunnerExitCode
}

$exitCode = 1
try {
    foreach ($spec in @($Data.children | Where-Object { [string]$_.start -eq 'immediate' })) { Start-Child $spec $null }
    $handoffSpecs = @($Data.children | Where-Object { [string]$_.start -eq 'handoff' })
    if ($handoffSpecs.Count -gt 1) { throw 'runner permits one handoff child' }
    $handoffStarted = $handoffSpecs.Count -eq 0
    while ([datetime]::UtcNow -lt $Deadline) {
        if ($null -ne $Controller -and -not (Test-ControllerIdentityAlive $Controller)) { throw 'controller identity lost' }
        if (-not $handoffStarted) {
            $identity = Receive-ServerIdentity $Data.handoff $Controller $Deadline
            Start-Child $handoffSpecs[0] $identity $true
            $handoffStarted = $true
        }
        foreach ($record in $Started) {
            if ($record.Process.HasExited) {
                if ([int]$record.Process.ExitCode -ne 0) { throw "$($record.Name) exited $($record.Process.ExitCode)" }
                if ($record.StopAfterExit -and -not (Test-Path -LiteralPath ([string]$Data.stopPath))) { Set-Content -LiteralPath ([string]$Data.stopPath) -Value 'stop' }
            }
        }
        if (Test-Path -LiteralPath ([string]$Data.stopPath)) { break }
        $allExited = $Started.Count -gt 0
        foreach ($record in $Started) { if (-not $record.Process.HasExited) { $allExited = $false } }
        if ($allExited -and $handoffStarted) { break }
        Start-Sleep -Milliseconds 100
    }
    if ([datetime]::UtcNow -ge $Deadline) { throw 'runner deadline exceeded' }
} catch { $Failures.Add("$_") | Out-Null } finally {
    foreach ($record in $Started) { try { $code = Stop-Child $record; if ($code -ne 0) { $Failures.Add("$($record.Name) exit $code") | Out-Null } } catch { $Failures.Add("cleanup $($record.Name): $_") | Out-Null } }
    if ($Failures.Count -eq 0) { $exitCode = 0 }
    try { $exitCode = Write-Audit $exitCode } catch { $Failures.Add("audit write: $_") | Out-Null; $exitCode = 1; [Console]::Error.WriteLine("diagnostics validation audit write failed: $_") }
}
exit $exitCode
