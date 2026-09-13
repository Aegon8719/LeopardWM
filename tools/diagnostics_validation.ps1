# Opt-in isolated Medium/High diagnostics validation.
# -SelfTest uses only non-desktop subprocess simulations from the current Medium shell.
# -RunNative is deliberately parent-owned: it builds exact test artifacts in Medium,
# requests one UAC elevation for an inspected pinned High side, and never starts the
# ordinary daemon or uses the daily-driver pipe.

[CmdletBinding()]
param(
    [switch]$SyntaxOnly,
    [switch]$SelfTest,
    [switch]$RunNative,
    [switch]$HighSide,
    [string]$PinnedSpecPath,
    [string]$RepoRoot = $(if ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { (Get-Location).Path })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$DailyDriverPipe = '\\.\pipe\leopardwm'
$DiagPrefix = '\\.\pipe\leopardwm_diagval_'
$MediumRid = [uint32]0x2000
$HighRid = [uint32]0x3000
$Gap = 'skip_if_elevation_blocked is cfg(not(test)); this is platform admission state plus isolated HealthCheck/QueryStatus IPC, not full daemon startup E2E.'
$TestArgs = @('--ignored', '--exact', 'diagnostics_validation::diagnostics_validation_native', '--test-threads=1', '--nocapture')

function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
function Test-ExactPipe([string]$Pipe) {
    if ([string]::IsNullOrWhiteSpace($Pipe) -or $Pipe -eq $DailyDriverPipe -or -not $Pipe.StartsWith($DiagPrefix)) { return $false }
    return $Pipe.Substring($DiagPrefix.Length) -cmatch '^[a-z0-9._-]+$'
}
function New-RunId { return ([guid]::NewGuid().ToString('N')) }
function New-Scope { return "diagval_$PID`_$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())_$((New-RunId).Substring(0, 8))" }
function Get-Pipe([string]$Scope) { return "$DailyDriverPipe`_$($Scope.ToLowerInvariant())" }
function Assert-IsolatedPipe([string]$Scope, [string]$Pipe) {
    if ([string]::IsNullOrWhiteSpace($Scope) -or $Pipe -ne (Get-Pipe $Scope) -or -not (Test-ExactPipe $Pipe)) { throw 'generated pipe is not an exact isolated diagnostics pipe' }
}
function New-FreshDirectory([string]$Root, [string]$Name) {
    $path = Join-Path $Root $Name
    if (Test-Path -LiteralPath $path) { throw "fresh destination already exists: $path" }
    New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
    return $path
}
function Write-JsonFresh([string]$Path, $Value) {
    if (Test-Path -LiteralPath $Path) { throw "JSON destination already exists: $Path" }
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8 -NoNewline
}
function Read-Json([string]$Path) { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json) }
function Get-ExecutableFromCargoJson { param([object[]]$Lines, [int]$ExitCode, [string]$Bin)
    if ($ExitCode -ne 0) { throw "cargo test --no-run failed: $ExitCode" }
    $exe = $null
    foreach ($line in @($Lines)) { try { $json = ([string]$line | ConvertFrom-Json) } catch { continue }; if ($json.reason -eq 'compiler-artifact' -and $json.profile.test -and $json.target.name -eq $Bin -and $json.executable) { $exe = [string]$json.executable } }
    if ([string]::IsNullOrWhiteSpace($exe)) { throw "could not locate test executable for $Bin" }
    return $exe
}
function Get-TestExecutable { param([string]$Package, [string]$Bin, [string]$LogPath)
    $manifest = Join-Path $RepoRoot 'Cargo.toml'
    if (-not (Test-Path -LiteralPath $manifest)) { throw "RepoRoot Cargo.toml missing: $manifest" }
    $lines = & cargo test -p $Package --bin $Bin --no-run --message-format=json --manifest-path $manifest 2>&1
    $exit = $LASTEXITCODE
    foreach ($line in @($lines)) { Write-Host ([string]$line) }
    @($lines | ForEach-Object { [string]$_ }) | Set-Content -LiteralPath $LogPath -Encoding UTF8
    return Get-ExecutableFromCargoJson -Lines $lines -ExitCode $exit -Bin $Bin
}
function Initialize-TokenNative {
    if ('DiagValIntegrity' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DiagValIntegrity {
 [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr p,uint a,out IntPtr t);
 [DllImport("advapi32.dll", SetLastError=true)] public static extern bool GetTokenInformation(IntPtr t,int c,IntPtr b,uint n,out uint r);
 [DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthority(IntPtr s,uint i);
 [DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthorityCount(IntPtr s);
 [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
 public const uint Query=0x0008; public const int ElevationType=18; public const int Integrity=25;
}
'@
}
function Get-CurrentTokenInfo {
    Initialize-TokenNative
    $token = [IntPtr]::Zero
    if (-not [DiagValIntegrity]::OpenProcessToken([DiagValIntegrity]::GetCurrentProcess(), [DiagValIntegrity]::Query, [ref]$token)) { return $null }
    try {
        $value = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        try {
            $size = [uint32]4
            if (-not [DiagValIntegrity]::GetTokenInformation($token, [DiagValIntegrity]::ElevationType, $value, 4, [ref]$size)) { return $null }
            $elevation = [Runtime.InteropServices.Marshal]::ReadInt32($value)
        } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($value) }
        $size = [uint32]0
        [void][DiagValIntegrity]::GetTokenInformation($token, [DiagValIntegrity]::Integrity, [IntPtr]::Zero, 0, [ref]$size)
        if ($size -eq 0) { return $null }
        $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal([int]$size)
        try {
            if (-not [DiagValIntegrity]::GetTokenInformation($token, [DiagValIntegrity]::Integrity, $buffer, $size, [ref]$size)) { return $null }
            $sid = [Runtime.InteropServices.Marshal]::ReadIntPtr($buffer)
            $count = [Runtime.InteropServices.Marshal]::ReadByte([DiagValIntegrity]::GetSidSubAuthorityCount($sid))
            if ($count -eq 0) { return $null }
            return [pscustomobject]@{ rid = [uint32][Runtime.InteropServices.Marshal]::ReadInt32([DiagValIntegrity]::GetSidSubAuthority($sid, [uint32]($count - 1))); elevation_type = $elevation }
        } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
    } finally { [void][DiagValIntegrity]::CloseHandle($token) }
}
function Join-ProcessArguments([string[]]$Arguments) {
    $parts = foreach ($argument in $Arguments) { $escaped = ([string]$argument -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1'; '"' + $escaped + '"' }
    return $parts -join ' '
}
$script:TestFailProcessMetadataFor = $null
function Test-DescendantPath([string]$Parent, [string]$Candidate) {
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $candidatePath = [IO.Path]::GetFullPath($Candidate)
    return $candidatePath.StartsWith($parentPath + '\', [StringComparison]::OrdinalIgnoreCase)
}
function New-ProcessRecord([string]$Name, $Process, [string]$AuditPath = $null) {
    return [pscustomobject]@{ name = $Name; process = $Process; pid = [uint32]$Process.Id; creation_filetime = $null; image = $null; audit_path = $AuditPath }
}
function Complete-ProcessRecord($Record) {
    if ($script:TestFailProcessMetadataFor -eq $Record.name) { throw "injected process metadata failure for $($Record.name)" }
    $Record.creation_filetime = [uint64]$Record.process.StartTime.ToFileTimeUtc()
    try { $Record.image = [string]$Record.process.Path } catch { $Record.image = (Get-Process -Id $PID).Path }
    return $Record
}
function Start-Runner([string]$Name, [string]$Shell, [string]$Runner, [string]$DataPath, [string]$WorkingDirectory, [string]$AuditPath, $Owned) {
    $process = Start-Process -FilePath $Shell -ArgumentList (Join-ProcessArguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Runner, '-DataPath', $DataPath)) -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
    if ($null -eq $process) { throw "runner did not start: $Name" }
    $record = New-ProcessRecord $Name $process $AuditPath
    $Owned.Add($record) | Out-Null
    return Complete-ProcessRecord $record
}
function Stop-Retained([object]$Record, [int]$WaitMs = 12000) {
    if ($null -eq $Record -or $null -eq $Record.process) { throw 'missing retained process record' }
    $process = $Record.process
    if ($process.HasExited) { return [int]$process.ExitCode }
    if ($process.WaitForExit($WaitMs)) { return [int]$process.ExitCode }
    $process.Kill()
    if (-not $process.WaitForExit($WaitMs)) { throw "process $($Record.name) pid $($Record.pid) did not exit after kill" }
    return [int]$process.ExitCode
}
function Stop-Owned($Owned, [int]$WaitMs = 12000) {
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($record in $Owned) { try { $code = Stop-Retained $record $WaitMs; if ($code -ne 0) { $errors.Add("$($record.name) exit $code") | Out-Null } } catch { $errors.Add("cleanup $($record.name): $_") | Out-Null } }
    return @($errors)
}
function Wait-Json([string]$Path, $Process, [datetime]$Deadline, [string]$Phase) {
    while ([datetime]::UtcNow -lt $Deadline) {
        if (Test-Path -LiteralPath $Path) { try { return Read-Json $Path } catch {} }
        if ($null -ne $Process -and $Process.process.HasExited) { throw "$Phase child exited $($Process.process.ExitCode) before $Path" }
        Start-Sleep -Milliseconds 100
    }
    throw "$Phase timed out waiting for $Path"
}
function Assert-Audit([string]$Path, [string[]]$Children, [string]$Label) {
    $audit = Read-Json $Path
    if ([int]$audit.exitCode -ne 0 -or @($audit.failures).Count -ne 0) { throw "$Label runner audit failed: $(@($audit.failures) -join '; ')" }
    foreach ($name in $Children) {
        $child = @($audit.children | Where-Object { [string]$_.name -eq $name })
        if ($child.Count -ne 1 -or [uint32]$child[0].pid -eq 0 -or [uint64]$child[0].creation_filetime -eq 0 -or -not [bool]$child[0].exited -or [int]$child[0].exitCode -ne 0) { throw "$Label audit lacks successful retained child $name" }
    }
}
function New-HostEnv([string]$RunDir, [string]$Scope, [string]$Prefix, [string]$OwnHwnd) { return [ordered]@{ LEOPARDWM_DIAGNOSTICS_VALIDATION='1'; LEOPARDWM_DIAGNOSTICS_RUN_DIR=$RunDir; LEOPARDWM_DIAGNOSTICS_TIMEOUT_SECS='90'; LEOPARDWM_PIPE_SCOPE=$Scope; LEOPARDWM_DIAGNOSTICS_ROLE='host'; LEOPARDWM_DIAGNOSTICS_OWN_HWND=$OwnHwnd; LEOPARDWM_DIAGNOSTICS_EVIDENCE_PREFIX=$Prefix } }
function New-ClientEnv([string]$RunDir, [string]$Prefix) { return [ordered]@{ LEOPARDWM_DIAGNOSTICS_VALIDATION='1'; LEOPARDWM_DIAGNOSTICS_RUN_DIR=$RunDir; LEOPARDWM_DIAGNOSTICS_TIMEOUT_SECS='30'; LEOPARDWM_DIAGNOSTICS_ROLE='client'; LEOPARDWM_DIAGNOSTICS_EVIDENCE_PREFIX=$Prefix } }
function New-RunnerData([string]$RunDir, [string]$WorkingDir, [string]$StopPath, [string]$AuditPath, $Children, $Controller = $null, $Handoff = $null, [int]$TimeoutSec = 90) { return [ordered]@{ runDir=$RunDir; workingDir=$WorkingDir; stopPath=$StopPath; auditPath=$AuditPath; timeoutSec=$TimeoutSec; environment_policy='clear_diagnostics'; controller=$Controller; handoff=$Handoff; children=@($Children) } }
function New-HandoffControlServer([string]$Pipe) {
    if (-not (Test-ExactPipe $Pipe)) { throw 'refusing malformed handoff control pipe' }
    $options = [IO.Pipes.PipeOptions]::Asynchronous -bor [IO.Pipes.PipeOptions]::CurrentUserOnly
    return [IO.Pipes.NamedPipeServerStream]::new(
        $Pipe.Substring('\\.\pipe\'.Length),
        [IO.Pipes.PipeDirection]::Out,
        1,
        [IO.Pipes.PipeTransmissionMode]::Byte,
        $options,
        0,
        4096
    )
}
function Wait-HandoffReceiver($Server, $Receiver, [datetime]$Deadline) {
    $connect = $Server.BeginWaitForConnection($null, $null)
    while (-not $connect.AsyncWaitHandle.WaitOne(100)) {
        if ([datetime]::UtcNow -ge $Deadline) { throw 'handoff receiver did not connect before deadline' }
        if ($null -ne $Receiver -and $Receiver.process.HasExited) { throw "handoff receiver exited $($Receiver.process.ExitCode) before connection" }
    }
    $Server.EndWaitForConnection($connect)
}
function Send-HandoffPayload($Server, [string]$Payload, $Receiver = $null) {
    try {
        if ($null -eq $Server -or -not $Server.IsConnected) { throw 'handoff receiver is not connected' }
        if ($null -ne $Receiver -and $Receiver.process.HasExited) { throw "handoff receiver exited $($Receiver.process.ExitCode) before payload" }
        $bytes = [Text.Encoding]::UTF8.GetBytes($Payload)
        if ($bytes.Length -eq 0 -or $bytes.Length -gt 4096) { throw 'handoff payload is not within the fixed 4096-byte limit' }
        $Server.Write($bytes, 0, $bytes.Length)
        $Server.Flush()
    } finally { if ($null -ne $Server) { $Server.Dispose() } }
}
function Send-ServerIdentity($Server, [string]$RunId, [string]$ServerPipe, [uint32]$ServerPid, [uint64]$Creation, $Receiver = $null) {
    if (-not (Test-ExactPipe $ServerPipe) -or $RunId -notmatch '^[a-f0-9]{32}$' -or $ServerPid -eq 0 -or $Creation -eq 0) { throw 'refusing malformed bounded server-identity handoff' }
    $payload = @{ kind='server_identity'; run_id=$RunId; pipe=$ServerPipe; expected_pid=$ServerPid; expected_creation=$Creation } | ConvertTo-Json -Compress
    Send-HandoffPayload $Server $payload $Receiver
}
function ConvertTo-PsLiteral([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }
function Get-ArtifactDependencies([string[]]$Executables) {
    $dependencies = New-Object System.Collections.Generic.List[object]
    $byName = @{}
    foreach ($executable in $Executables) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Split-Path -Parent $executable) -Filter '*.dll' -File)) {
            $hash = Get-Sha256 $file.FullName
            if ($byName.ContainsKey($file.Name)) {
                if ($byName[$file.Name] -cne $hash) { throw "conflicting DLL dependency bytes: $($file.Name)" }
                continue
            }
            $byName[$file.Name] = $hash
            $dependencies.Add([ordered]@{ source = $file.FullName; destination = $file.Name; sha256 = $hash }) | Out-Null
        }
    }
    return ,([object[]]$dependencies.ToArray())
}
function Start-PinnedBootstrap([string]$Shell, [string]$BootstrapPath, [string]$SpecPath, [string]$SpecHash, [string]$WorkingDirectory, $Owned) {
    $bootstrapHash = Get-Sha256 $BootstrapPath
    $command = "`$p=$(ConvertTo-PsLiteral $BootstrapPath);`$h=$(ConvertTo-PsLiteral $bootstrapHash);`$b=[IO.File]::ReadAllBytes(`$p);`$s=[Security.Cryptography.SHA256]::Create();try {`$a=([BitConverter]::ToString(`$s.ComputeHash(`$b))).Replace('-','');if(`$a -cne `$h){throw 'pinned bootstrap hash mismatch'};& ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString(`$b)))} finally {`$s.Dispose()}"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    try { $process = Start-Process -FilePath $Shell -Verb RunAs -ArgumentList (Join-ProcessArguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)) -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru } catch { throw "UAC bootstrap was cancelled or failed: $_" }
    if ($null -eq $process) { throw 'UAC bootstrap returned no process; no retry is attempted' }
    $record = New-ProcessRecord 'high-bootstrap' $process
    $Owned.Add($record) | Out-Null
    return Complete-ProcessRecord $record
}
function Test-WindowExists([uint64]$Hwnd) {
    if ($Hwnd -eq 0) { return $false }
    if (-not ('DiagValWindow' -as [type])) { Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DiagValWindow { [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd); }
'@ }
    return [DiagValWindow]::IsWindow([IntPtr]$Hwnd)
}
function Assert-NativeMatrix($HighDir, $MediumHostDir, $MediumClientDir) {
    $fixture = Read-Json (Join-Path $HighDir 'fixture.json')
    if ([uint64]$fixture.hwnd -eq 0 -or [uint32]$fixture.pid -eq 0 -or [uint64]$fixture.creation_filetime -eq 0 -or [string]::IsNullOrWhiteSpace([string]$fixture.image) -or [bool]$fixture.visible) { throw 'High fixture identity is incomplete or visible' }
    $highHost = Read-Json (Join-Path $HighDir 'high-host.json'); $mediumHost = Read-Json (Join-Path $MediumHostDir 'medium-host.json'); $mediumClient = Read-Json (Join-Path $MediumClientDir 'medium-client.json'); $highClient = Read-Json (Join-Path $HighDir 'high-client.json')
    foreach ($pair in @(@($highHost,$HighRid,'high host'), @($mediumHost,$MediumRid,'medium host'), @($mediumClient,$MediumRid,'medium client'), @($highClient,$HighRid,'high client'))) { if ([uint32]$pair[0].oracle_integrity_rid -ne $pair[1] -or [uint32]$pair[0].platform_integrity_rid -ne $pair[1]) { throw "$($pair[2]) RID matrix mismatch" } }
    if ([string]$highHost.admission.noted -ne 'No' -or [string]$mediumHost.admission.noted -ne 'HigherIntegrity') { throw 'admission matrix does not demonstrate High fixture versus Medium host' }
    if ([uint64]$mediumHost.admission.hwnd -ne [uint64]$fixture.hwnd -or [string]$mediumHost.admission.title -ne [string]$fixture.title) { throw 'Medium host did not admit the verified High fixture' }
    if ([uint32]$mediumClient.health.daemon_integrity -ne $HighRid -or [uint32]$highClient.health.daemon_integrity -ne $MediumRid) { throw 'HealthCheck integrity matrix mismatch' }
    $blocked = @($highClient.health.elevation_blocked_records | Where-Object { [uint64]$_.hwnd -eq [uint64]$fixture.hwnd -and [string]$_.reason -eq 'higher_integrity' })
    if ($blocked.Count -ne 1) { throw 'High client HealthCheck lacks higher_integrity admission record' }
    $legacy = @($highClient.health.elevation_blocked_windows | Where-Object { @($_).Count -ge 2 -and [uint64]$_[0] -eq [uint64]$fixture.hwnd })
    if ($legacy.Count -ne 1 -or [string]$mediumClient.query_status.status -ne 'status_info' -or [string]$highClient.query_status.status -ne 'status_info') { throw 'legacy compatibility or QueryStatus evidence missing' }
    if ([uint32]$mediumClient.connected_server_pid -ne [uint32]$highHost.pid -or [uint64]$mediumClient.expected_server_creation -ne [uint64]$highHost.creation_filetime -or [uint32]$highClient.connected_server_pid -ne [uint32]$mediumHost.pid -or [uint64]$highClient.expected_server_creation -ne [uint64]$mediumHost.creation_filetime) { throw 'actual pipe server identity evidence mismatch' }
    foreach ($rendered in @([string]$mediumClient.rendered.daemon, [string]$mediumClient.rendered.cli, [string]$highClient.rendered.daemon, [string]$highClient.rendered.cli)) { if ([string]::IsNullOrWhiteSpace($rendered) -or $rendered -like '*unavailable*') { throw 'doctor output evidence missing' } }
    return $fixture
}
function Assert-PinnedHighSpec([string]$SpecPath) {
    $spec = Read-Json $SpecPath
    if ([int]$spec.version -ne 1) { throw 'unsupported pinned High specification' }
    $execution = Split-Path -Parent $SpecPath
    foreach ($item in @(@('diagnostics_validation.ps1',$spec.main.sha256), @('diagnostics_validation_runner.ps1',$spec.runner.sha256), @('daemon-test.exe',$spec.daemon.sha256), @('cli-test.exe',$spec.cli.sha256), @('high-runner-data.json',$spec.runner_data.sha256))) {
        $path = Join-Path $execution $item[0]
        if (-not (Test-Path -LiteralPath $path) -or (Get-Sha256 $path) -cne [string]$item[1]) { throw "pinned High artifact hash mismatch: $($item[0])" }
    }
    $names = @{}
    foreach ($dependency in @($spec.dependencies)) {
        $name = [string]$dependency.destination
        if ([string]::IsNullOrWhiteSpace($name) -or [IO.Path]::GetFileName($name) -cne $name -or $names.ContainsKey($name) -or -not (Test-Path -LiteralPath (Join-Path $execution $name)) -or (Get-Sha256 (Join-Path $execution $name)) -cne [string]$dependency.sha256) { throw "pinned High dependency hash mismatch: $name" }
        $names[$name] = $true
    }
    return $spec
}
function Assert-HighRunnerData($Data, [string]$ExecutionDir, [string]$OutputDir) {
    if ([string]$Data.runDir -ne $OutputDir -or [string]$Data.workingDir -ne $ExecutionDir -or [string]$Data.stopPath -ne (Join-Path $OutputDir 'stop') -or [string]$Data.auditPath -ne (Join-Path $OutputDir 'high-runner-audit.json') -or [string]$Data.environment_policy -ne 'clear_diagnostics') { throw 'pinned High runner data has mutable paths or environment policy' }
    $controller = $Data.controller
    if ($null -eq $controller -or [uint32]$controller.pid -eq 0 -or [uint64]$controller.creation_filetime -eq 0 -or [string]::IsNullOrWhiteSpace([string]$controller.image)) { throw 'pinned High runner data lacks controller identity' }
    if ($null -eq $Data.handoff -or -not (Test-ExactPipe ([string]$Data.handoff.pipe)) -or -not (Test-ExactPipe ([string]$Data.handoff.server_pipe)) -or [string]$Data.handoff.run_id -notmatch '^[a-f0-9]{32}$') { throw 'pinned High runner handoff is invalid' }
    $children = @($Data.children)
    if ($children.Count -ne 2) { throw 'pinned High runner child set is invalid' }
    $expected = @{ 'high-host' = 'daemon-test.exe'; 'high-client' = 'cli-test.exe' }
    foreach ($child in $children) {
        $name = [string]$child.name
        if (-not $expected.ContainsKey($name) -or [string]$child.exe -ne (Join-Path $ExecutionDir $expected[$name]) -or ((@($child.args) -join "`n") -cne ($TestArgs -join "`n"))) { throw "pinned High child specification is invalid: $name" }
        foreach ($path in @([string]$child.stdout, [string]$child.stderr)) {
            if (-not (Test-DescendantPath $OutputDir $path)) {
                throw "pinned High child output escapes protected output: $name"
            }
        }
    }
    if ([string](@($children | Where-Object { $_.name -eq 'high-host' })[0].start) -ne 'immediate' -or [string](@($children | Where-Object { $_.name -eq 'high-client' })[0].start) -ne 'handoff' -or -not [bool](@($children | Where-Object { $_.name -eq 'high-client' })[0].stopAfterExit)) { throw 'pinned High child ordering is invalid' }
}
function Complete-HighSideState($State, [int]$RunnerExit) {
    $State.status = 'exited'
    $State.runner_exit = $RunnerExit
    return $State
}
function Invoke-HighSide {
    if ([string]::IsNullOrWhiteSpace($PinnedSpecPath) -or -not (Test-Path -LiteralPath $PinnedSpecPath)) { throw 'High side requires its protected pinned specification' }
    $token = Get-CurrentTokenInfo
    if ($null -eq $token -or [uint32]$token.rid -ne $HighRid) { throw 'High side is not High integrity' }
    $spec = Assert-PinnedHighSpec $PinnedSpecPath
    $exec = Split-Path -Parent $PinnedSpecPath
    $output = [string]$spec.high_output_dir
    if (-not (Test-Path -LiteralPath $output) -or -not $output.StartsWith($exec, [StringComparison]::OrdinalIgnoreCase)) { throw 'High output path is not the protected execution destination' }
    $data = Read-Json (Join-Path $exec 'high-runner-data.json')
    Assert-HighRunnerData $data $exec $output
    $runner = Join-Path $exec 'diagnostics_validation_runner.ps1'
    $shell = (Get-Process -Id $PID).Path
    $side = Join-Path $output 'high-side.json'
    Write-JsonFresh $side ([ordered]@{ pid=$PID; creation_filetime=[uint64](Get-Process -Id $PID).StartTime.ToFileTimeUtc(); integrity=$token.rid; status='starting'; runner_exit=$null })
    $runnerProcess = Start-Process -FilePath $shell -ArgumentList (Join-ProcessArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-DataPath',(Join-Path $exec 'high-runner-data.json'))) -WorkingDirectory $exec -WindowStyle Hidden -PassThru
    $runnerProcess.WaitForExit()
    $sideState = Complete-HighSideState (Read-Json $side) ([int]$runnerProcess.ExitCode)
    $sideState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $side -Encoding UTF8
    exit $runnerProcess.ExitCode
}
function Invoke-SelfTest {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("leopardwm-diagval-selftest-" + (New-RunId))
    New-Item -ItemType Directory -Path $root | Out-Null
    Write-Host "SelfTest simulates Medium and High roles; it does not request UAC or claim actual High evidence: $root"
    if (-not (Test-ExactPipe (Get-Pipe (New-Scope))) -or (Test-ExactPipe $DailyDriverPipe) -or (Test-ExactPipe '\\server\pipe\leopardwm_diagval_x')) { throw 'exact pipe validation failed' }
    if (-not (Test-DescendantPath 'C:\Temp\owned-high' 'C:\Temp\owned-high\output') -or (Test-DescendantPath 'C:\Temp\owned-high' 'C:\Temp\owned-high-sibling\output') -or (Test-DescendantPath 'C:\Temp\owned-high' 'C:\Temp\owned-high\..\escape')) { throw 'High destination boundary validation failed' }
    $sideState = Complete-HighSideState ([pscustomobject]@{ status='starting'; runner_exit=$null }) 0
    if ([string]$sideState.status -ne 'exited' -or [int]$sideState.runner_exit -ne 0) { throw 'High side-state finalization failed' }
    $sample = Join-Path $root 'pinned.txt'; [IO.File]::WriteAllText($sample, 'pinned'); $hash = Get-Sha256 $sample; if ($hash -ne (Get-Sha256 $sample)) { throw 'pin integrity baseline failed' }; [IO.File]::WriteAllText($sample, 'substituted'); if ($hash -eq (Get-Sha256 $sample)) { throw 'substituted immutable input was accepted' }
    $dependencyRoot = New-FreshDirectory $root 'dependency-fixtures'
    $zeroDirectory = New-FreshDirectory $dependencyRoot 'zero'
    $zeroExecutable = Join-Path $zeroDirectory 'zero.exe'
    [IO.File]::WriteAllText($zeroExecutable, 'zero')
    $zeroDependencies = Get-ArtifactDependencies @($zeroExecutable)
    if ($zeroDependencies.GetType() -ne [object[]] -or $zeroDependencies.Count -ne 0) { throw 'empty dependency set did not remain an array' }
    $emptyDependencySpec = @{ dependencies = $zeroDependencies } | ConvertTo-Json -Compress | ConvertFrom-Json
    if ($null -eq $emptyDependencySpec.dependencies -or @($emptyDependencySpec.dependencies).Count -ne 0) { throw 'empty dependency set became null in the frozen specification' }
    $oneDirectory = New-FreshDirectory $dependencyRoot 'one'
    $oneExecutable = Join-Path $oneDirectory 'one.exe'
    [IO.File]::WriteAllText($oneExecutable, 'one')
    [IO.File]::WriteAllText((Join-Path $oneDirectory 'one.dll'), 'one dependency')
    $oneDependencies = Get-ArtifactDependencies @($oneExecutable)
    if ($oneDependencies.GetType() -ne [object[]] -or $oneDependencies.Count -ne 1 -or [string]$oneDependencies[0].destination -ne 'one.dll') { throw 'single dependency discovery failed' }
    $multipleDirectory = New-FreshDirectory $dependencyRoot 'multiple'
    $firstExecutable = Join-Path $multipleDirectory 'first.exe'
    $secondExecutable = Join-Path $multipleDirectory 'second.exe'
    [IO.File]::WriteAllText($firstExecutable, 'first')
    [IO.File]::WriteAllText($secondExecutable, 'second')
    [IO.File]::WriteAllText((Join-Path $multipleDirectory 'alpha.dll'), 'alpha')
    [IO.File]::WriteAllText((Join-Path $multipleDirectory 'beta.dll'), 'beta')
    $multipleDependencies = Get-ArtifactDependencies @($firstExecutable, $secondExecutable)
    $multipleNames = @($multipleDependencies | ForEach-Object { [string]$_.destination } | Sort-Object)
    if ($multipleDependencies.GetType() -ne [object[]] -or $multipleDependencies.Count -ne 2 -or ($multipleNames -join '|') -cne 'alpha.dll|beta.dll') { throw 'multiple or duplicate-samehash dependency discovery failed' }
    $conflictOne = New-FreshDirectory $dependencyRoot 'conflict-one'
    $conflictTwo = New-FreshDirectory $dependencyRoot 'conflict-two'
    $conflictExecutableOne = Join-Path $conflictOne 'one.exe'
    $conflictExecutableTwo = Join-Path $conflictTwo 'two.exe'
    [IO.File]::WriteAllText($conflictExecutableOne, 'one')
    [IO.File]::WriteAllText($conflictExecutableTwo, 'two')
    [IO.File]::WriteAllText((Join-Path $conflictOne 'shared.dll'), 'first bytes')
    [IO.File]::WriteAllText((Join-Path $conflictTwo 'shared.dll'), 'second bytes')
    try { Get-ArtifactDependencies @($conflictExecutableOne, $conflictExecutableTwo); throw 'conflicting dependency basename was accepted' } catch { if ("$_" -notlike '*conflicting DLL dependency bytes*') { throw } }
    Write-Host 'SelfTest verified empty, single, multiple, duplicate-samehash, and conflicting dependency discovery'
    $child = Join-Path $root 'child.ps1'
    @'
param([string]$Mode,[string]$Evidence,[string]$StopPath)
if($Mode -eq 'host') { @{pid=$PID;ready=$true}|ConvertTo-Json|Set-Content -LiteralPath $Evidence; while(-not(Test-Path -LiteralPath $StopPath)){Start-Sleep -Milliseconds 25}; exit 0 }
if($Mode -eq 'client') { @{pid=$PID;client=$true}|ConvertTo-Json|Set-Content -LiteralPath $Evidence; exit 0 }
if($Mode -eq 'fail'){exit 9}; while($true){Start-Sleep -Milliseconds 25}
'@ | Set-Content -LiteralPath $child -Encoding UTF8
    $runner = Join-Path $RepoRoot 'tools\diagnostics_validation_runner.ps1'
    $shell = (Get-Process -Id $PID).Path
    $bootstrap = Join-Path $RepoRoot 'tools\diagnostics_validation_uac_bootstrap.ps1'
    $bootstrapCommand = "`$FrozenSpecPath='selftest';`$FrozenSpecHash='selftest';`$BootstrapTestOnly=`$true;. $(ConvertTo-PsLiteral $bootstrap)"
    & $shell -NoProfile -Command $bootstrapCommand
    if ($LASTEXITCODE -ne 0) { throw 'bootstrap helper self-test failed' }
    $owned = New-Object System.Collections.Generic.List[object]
    try {
    $highOut=New-FreshDirectory $root 'simulated-high-evidence'; $mediumOut=New-FreshDirectory $root 'simulated-medium-evidence'; if ($highOut -eq $mediumOut) { throw 'role evidence separation failed' }
    $handoffPipe=Get-Pipe ("diagval_handoff_"+(New-RunId)); $runId=New-RunId; $expectedServerPipe=Get-Pipe (New-Scope); $stop=Join-Path $highOut 'stop'; $audit=Join-Path $highOut 'audit.json'; $hostEvidence=Join-Path $highOut 'host.json'; $clientEvidence=Join-Path $highOut 'client.json'
    $controller=[ordered]@{pid=$PID;creation_filetime=[uint64](Get-Process -Id $PID).StartTime.ToFileTimeUtc();image=$shell}
    function Invoke-RejectedHandoffSelfTest([string]$Label, $PayloadFactory) {
        $caseRoot = New-FreshDirectory $root ("handoff-$Label-evidence")
        $casePipe = Get-Pipe ("diagval_handoff_" + (New-RunId))
        $caseRunId = New-RunId
        $caseServerPipe = Get-Pipe (New-Scope)
        $caseStop = Join-Path $caseRoot 'stop'
        $caseAudit = Join-Path $caseRoot 'audit.json'
        $caseHost = Join-Path $caseRoot 'host.json'
        $caseClient = Join-Path $caseRoot 'client.json'
        $caseHostSpec = [ordered]@{ name='rejected-host'; exe=$shell; args=@('-NoProfile','-File',$child,'-Mode','host','-Evidence',$caseHost,'-StopPath',$caseStop); env=@{}; start='immediate'; stdout=(Join-Path $caseRoot 'host.out'); stderr=(Join-Path $caseRoot 'host.err') }
        $caseClientSpec = [ordered]@{ name='rejected-client'; exe=$shell; args=@('-NoProfile','-File',$child,'-Mode','client','-Evidence',$caseClient,'-StopPath',$caseStop); env=@{}; start='handoff'; stopAfterExit=$true; stdout=(Join-Path $caseRoot 'client.out'); stderr=(Join-Path $caseRoot 'client.err') }
        $caseData = New-RunnerData $caseRoot $root $caseStop $caseAudit @($caseHostSpec,$caseClientSpec) $controller ([ordered]@{pipe=$casePipe;run_id=$caseRunId;server_pipe=$caseServerPipe}) 15
        $caseDataPath = Join-Path $root "handoff-$Label.json"
        Write-JsonFresh $caseDataPath $caseData
        $caseControl = New-HandoffControlServer $casePipe
        try {
            $caseRunner = Start-Runner "handoff-$Label" $shell $runner $caseDataPath $root $caseAudit $owned
            $null = Wait-Json $caseHost $caseRunner ([datetime]::UtcNow.AddSeconds(8)) "$Label host readiness"
            Wait-HandoffReceiver $caseControl $caseRunner ([datetime]::UtcNow.AddSeconds(8))
            $casePayload = & $PayloadFactory $caseRunId $caseServerPipe
            if ($Label -eq 'oversize') {
                $caseBytes = [Text.Encoding]::UTF8.GetBytes($casePayload)
                $caseControl.Write($caseBytes, 0, $caseBytes.Length)
                $caseControl.Flush()
                $caseControl.Dispose()
                $caseControl = $null
            } else { Send-HandoffPayload $caseControl $casePayload $caseRunner }
            $null = Wait-Json $caseAudit $caseRunner ([datetime]::UtcNow.AddSeconds(12)) "$Label cleanup audit"
            $caseEvidence = Read-Json $caseAudit
            $hostAudit = @($caseEvidence.children | Where-Object { [string]$_.name -eq 'rejected-host' })
            $clientAudit = @($caseEvidence.children | Where-Object { [string]$_.name -eq 'rejected-client' })
            if ([int]$caseEvidence.exitCode -eq 0 -or @($caseEvidence.failures).Count -eq 0 -or $hostAudit.Count -ne 1 -or -not [bool]$hostAudit[0].exited -or (Test-Path -LiteralPath $caseClient) -or $clientAudit.Count -ne 0) { throw "$Label handoff was accepted, launched its client, or did not clean its retained host" }
            Write-Host "SelfTest rejected $Label handoff without launching its client and cleaned its retained host"
        } finally { if ($null -ne $caseControl) { $caseControl.Dispose() } }
    }
    function Invoke-CancelledHandoffSelfTest {
        $caseRoot = New-FreshDirectory $root 'handoff-cancelled-evidence'
        $casePipe = Get-Pipe ("diagval_handoff_" + (New-RunId))
        $caseRunId = New-RunId
        $caseServerPipe = Get-Pipe (New-Scope)
        $caseStop = Join-Path $caseRoot 'stop'
        $caseAudit = Join-Path $caseRoot 'audit.json'
        $caseHost = Join-Path $caseRoot 'host.json'
        $caseHostSpec = [ordered]@{ name='cancelled-host'; exe=$shell; args=@('-NoProfile','-File',$child,'-Mode','host','-Evidence',$caseHost,'-StopPath',$caseStop); env=@{}; start='immediate'; stdout=(Join-Path $caseRoot 'host.out'); stderr=(Join-Path $caseRoot 'host.err') }
        $caseClientSpec = [ordered]@{ name='cancelled-client'; exe=$shell; args=@('-NoProfile','-File',$child,'-Mode','client','-Evidence',(Join-Path $caseRoot 'client.json'),'-StopPath',$caseStop); env=@{}; start='handoff'; stopAfterExit=$true; stdout=(Join-Path $caseRoot 'client.out'); stderr=(Join-Path $caseRoot 'client.err') }
        $caseData = New-RunnerData $caseRoot $root $caseStop $caseAudit @($caseHostSpec,$caseClientSpec) $controller ([ordered]@{pipe=$casePipe;run_id=$caseRunId;server_pipe=$caseServerPipe}) 15
        $caseDataPath = Join-Path $root 'handoff-cancelled.json'
        Write-JsonFresh $caseDataPath $caseData
        $caseControl = New-HandoffControlServer $casePipe
        try {
            $caseRunner = Start-Runner 'handoff-cancelled' $shell $runner $caseDataPath $root $caseAudit $owned
            $null = Wait-Json $caseHost $caseRunner ([datetime]::UtcNow.AddSeconds(8)) 'cancelled host readiness'
            Wait-HandoffReceiver $caseControl $caseRunner ([datetime]::UtcNow.AddSeconds(8))
            $caseControl.Dispose()
            $caseControl = $null
            $null = Wait-Json $caseAudit $caseRunner ([datetime]::UtcNow.AddSeconds(12)) 'cancelled handoff audit'
            $caseEvidence = Read-Json $caseAudit
            if ([int]$caseEvidence.exitCode -eq 0 -or @($caseEvidence.failures).Count -eq 0) { throw 'cancelled handoff was accepted' }
            Write-Host 'SelfTest rejected a cancelled Medium control server'
        } finally { if ($null -ne $caseControl) { $caseControl.Dispose() } }
    }
    $specHost=[ordered]@{name='simulated-high-host';exe=$shell;args=@('-NoProfile','-File',$child,'-Mode','host','-Evidence',$hostEvidence,'-StopPath',$stop);env=@{};start='immediate';stdout=(Join-Path $highOut 'host.out');stderr=(Join-Path $highOut 'host.err')}
    $specClient=[ordered]@{name='simulated-high-client';exe=$shell;args=@('-NoProfile','-File',$child,'-Mode','client','-Evidence',$clientEvidence,'-StopPath',$stop);env=@{};start='handoff';stopAfterExit=$true;stdout=(Join-Path $highOut 'client.out');stderr=(Join-Path $highOut 'client.err')}
    $data=New-RunnerData $highOut $root $stop $audit @($specHost,$specClient) $controller ([ordered]@{pipe=$handoffPipe;run_id=$runId;server_pipe=$expectedServerPipe}) 15; $dataPath=Join-Path $root 'runner.json'; Write-JsonFresh $dataPath $data
    $handoffControl = New-HandoffControlServer $handoffPipe
    try {
        $record=Start-Runner 'simulated-high-runner' $shell $runner $dataPath $root $audit $owned; $deadline=[datetime]::UtcNow.AddSeconds(8); $null=Wait-Json $hostEvidence $record $deadline 'simulated High host'; if(Test-Path $clientEvidence){throw 'High client started before ready/server-identity handoff'}
        Wait-HandoffReceiver $handoffControl $record ([datetime]::UtcNow.AddSeconds(8))
        try { Send-ServerIdentity $handoffControl ('0'*32) (Get-Pipe (New-Scope)) 1 1 $record } catch { throw "wrong-run handoff transport failed: $_" }
        # The rejected runner proves malformed/wrong-run handling; a fresh runner proves valid ordering.
        $null=Wait-Json $audit $record ([datetime]::UtcNow.AddSeconds(12)) 'wrong-run cleanup audit'
        $badAudit=Read-Json $audit; if([int]$badAudit.exitCode -eq 0 -or @($badAudit.failures).Count -eq 0){throw 'wrong-run handoff did not fail and clean simulated High children'}
        Write-Host 'SelfTest rejected wrong-run handoff and cleaned its retained host'
    } finally { $handoffControl.Dispose() }
    Invoke-RejectedHandoffSelfTest 'wrong-server-pipe' { param($run, $pipe) @{kind='server_identity';run_id=$run;pipe=(Get-Pipe (New-Scope));expected_pid=1;expected_creation=1} | ConvertTo-Json -Compress }
    Invoke-RejectedHandoffSelfTest 'extra-field' { param($run, $pipe) @{kind='server_identity';run_id=$run;pipe=$pipe;expected_pid=1;expected_creation=1;unexpected='no'} | ConvertTo-Json -Compress }
    Invoke-RejectedHandoffSelfTest 'missing-identity' { param($run, $pipe) @{kind='server_identity';run_id=$run;pipe=$pipe;expected_pid=1} | ConvertTo-Json -Compress }
    Invoke-RejectedHandoffSelfTest 'null-identity' { param($run, $pipe) return 'null' }
    Invoke-RejectedHandoffSelfTest 'oversize' { param($run, $pipe) return ('x' * 4097) }
    Invoke-CancelledHandoffSelfTest
    $receiverControl = New-HandoffControlServer (Get-Pipe ("diagval_handoff_" + (New-RunId)))
    try {
        $receiverProcess = Start-Process -FilePath $shell -ArgumentList (Join-ProcessArguments @('-NoProfile','-Command','exit 0')) -PassThru
        $receiverRecord = New-ProcessRecord 'dead-handoff-receiver' $receiverProcess
        $owned.Add($receiverRecord) | Out-Null
        $null = Complete-ProcessRecord $receiverRecord
        $receiverProcess.WaitForExit() | Out-Null
        try { Wait-HandoffReceiver $receiverControl $receiverRecord ([datetime]::UtcNow.AddSeconds(2)); throw 'dead receiver was accepted' } catch { if ("$_" -notlike '*handoff receiver exited*') { throw } }
        Write-Host 'SelfTest detected a dead High handoff receiver'
    } finally { $receiverControl.Dispose() }
    $unavailableOut = New-FreshDirectory $root 'handoff-unavailable-evidence'
    $unavailablePipe = Get-Pipe ("diagval_handoff_" + (New-RunId))
    $unavailableStop = Join-Path $unavailableOut 'stop'
    $unavailableAudit = Join-Path $unavailableOut 'audit.json'
    $unavailableHost = [ordered]@{name='unavailable-host';exe=$shell;args=@('-NoProfile','-File',$child,'-Mode','host','-Evidence',(Join-Path $unavailableOut 'host.json'),'-StopPath',$unavailableStop);env=@{};start='immediate';stdout=(Join-Path $unavailableOut 'host.out');stderr=(Join-Path $unavailableOut 'host.err')}
    $unavailableClient = [ordered]@{name='unavailable-client';exe=$shell;args=@('-NoProfile','-File',$child,'-Mode','client','-Evidence',(Join-Path $unavailableOut 'client.json'),'-StopPath',$unavailableStop);env=@{};start='handoff';stopAfterExit=$true;stdout=(Join-Path $unavailableOut 'client.out');stderr=(Join-Path $unavailableOut 'client.err')}
    $unavailableData = New-RunnerData $unavailableOut $root $unavailableStop $unavailableAudit @($unavailableHost,$unavailableClient) $controller ([ordered]@{pipe=$unavailablePipe;run_id=(New-RunId);server_pipe=(Get-Pipe (New-Scope))}) 1
    $unavailablePath = Join-Path $root 'handoff-unavailable.json'
    Write-JsonFresh $unavailablePath $unavailableData
    $unavailable = Start-Runner 'handoff-unavailable' $shell $runner $unavailablePath $root $unavailableAudit $owned
    $null = Wait-Json $unavailableAudit $unavailable ([datetime]::UtcNow.AddSeconds(10)) 'unavailable handoff audit'
    $unavailableEvidence = Read-Json $unavailableAudit
    if ([int]$unavailableEvidence.exitCode -eq 0 -or (@($unavailableEvidence.failures) -join '; ') -notlike '*connecting for server identity*') { throw 'unavailable Medium control server did not time out truthfully' }
    Write-Host 'SelfTest timed out when the Medium control server disappeared'
    $successOut=New-FreshDirectory $root 'simulated-high-success-evidence'; $successPipe=Get-Pipe ("diagval_handoff_"+(New-RunId)); $successRun=New-RunId; $successServerPipe=Get-Pipe (New-Scope); $successStop=Join-Path $successOut 'stop'; $successAudit=Join-Path $successOut 'audit.json'; $successHost=Join-Path $successOut 'host.json'; $successClient=Join-Path $successOut 'client.json'
    $successHostSpec=[ordered]@{name='successful-high-host';exe=$shell;args=@('-NoProfile','-File',$child,'-Mode','host','-Evidence',$successHost,'-StopPath',$successStop);env=@{};start='immediate';stdout=(Join-Path $successOut 'host.out');stderr=(Join-Path $successOut 'host.err')}
    $successClientSpec=[ordered]@{name='successful-high-client';exe=$shell;args=@('-NoProfile','-File',$child,'-Mode','client','-Evidence',$successClient,'-StopPath',$successStop);env=@{};start='handoff';stopAfterExit=$true;stdout=(Join-Path $successOut 'client.out');stderr=(Join-Path $successOut 'client.err')}
    $successData=New-RunnerData $successOut $root $successStop $successAudit @($successHostSpec,$successClientSpec) $controller ([ordered]@{pipe=$successPipe;run_id=$successRun;server_pipe=$successServerPipe}) 15; $successDataPath=Join-Path $root 'successful-runner.json'; Write-JsonFresh $successDataPath $successData
    $successControl = New-HandoffControlServer $successPipe
    try {
        $success=Start-Runner 'successful-high-runner' $shell $runner $successDataPath $root $successAudit $owned
        $null=Wait-Json $successHost $success ([datetime]::UtcNow.AddSeconds(8)) 'simulated High host readiness'; if(Test-Path $successClient){throw 'successful High client ran before host readiness'}
        Wait-HandoffReceiver $successControl $success ([datetime]::UtcNow.AddSeconds(8))
        Send-ServerIdentity $successControl $successRun $successServerPipe 1 1 $success
        $null=Wait-Json $successClient $success ([datetime]::UtcNow.AddSeconds(8)) 'simulated High client'; $null=Wait-Json $successAudit $success ([datetime]::UtcNow.AddSeconds(12)) 'successful High cleanup audit'; Assert-Audit $successAudit @('successful-high-host','successful-high-client') 'successful simulated High'
    } finally { $successControl.Dispose() }
    $failedChildOut = New-FreshDirectory $root 'failed-child-audit-evidence'
    $failedChildAudit = Join-Path $failedChildOut 'audit.json'
    $failedChildData = New-RunnerData $failedChildOut $root (Join-Path $failedChildOut 'stop') $failedChildAudit @([ordered]@{name='failing-child';exe=$shell;args=@('-NoProfile','-File',$child,'-Mode','fail','-Evidence',(Join-Path $failedChildOut 'unused.json'),'-StopPath',(Join-Path $failedChildOut 'stop'));env=@{};start='immediate';stdout=(Join-Path $failedChildOut 'child.out');stderr=(Join-Path $failedChildOut 'child.err')}) $null $null 5
    $failedChildPath = Join-Path $root 'failed-child-audit.json'
    Write-JsonFresh $failedChildPath $failedChildData
    $failedChildRunner = Start-Runner 'failed-child-audit' $shell $runner $failedChildPath $root $failedChildAudit $owned
    $null = Wait-Json $failedChildAudit $failedChildRunner ([datetime]::UtcNow.AddSeconds(8)) 'failed-child audit'
    $failedChildEvidence = Read-Json $failedChildAudit
    $failingChild = @($failedChildEvidence.children | Where-Object { [string]$_.name -eq 'failing-child' })
    if ([int]$failedChildEvidence.exitCode -eq 0 -or $failingChild.Count -ne 1 -or -not [bool]$failingChild[0].exited -or [int]$failingChild[0].exitCode -ne 9) { throw 'failed child audit did not preserve aggregate and child failure separately' }
    $failedRunnerOut = New-FreshDirectory $root 'failed-runner-audit-evidence'
    $failedRunnerAudit = Join-Path $failedRunnerOut 'audit.json'
    $failedRunnerData = New-RunnerData $failedRunnerOut $root (Join-Path $failedRunnerOut 'stop') $failedRunnerAudit @([ordered]@{name='successful-child';exe=$shell;args=@('-NoProfile','-File',$child,'-Mode','client','-Evidence',(Join-Path $failedRunnerOut 'client.json'),'-StopPath',(Join-Path $failedRunnerOut 'stop'));env=@{};start='immediate';stdout=(Join-Path $failedRunnerOut 'child.out');stderr=(Join-Path $failedRunnerOut 'child.err')}) ([ordered]@{pid=429496729;creation_filetime=1;image=$shell}) $null 5
    $failedRunnerPath = Join-Path $root 'failed-runner-audit.json'
    Write-JsonFresh $failedRunnerPath $failedRunnerData
    $failedRunner = Start-Runner 'failed-runner-audit' $shell $runner $failedRunnerPath $root $failedRunnerAudit $owned
    $null = Wait-Json $failedRunnerAudit $failedRunner ([datetime]::UtcNow.AddSeconds(8)) 'failed-runner audit'
    $failedRunnerEvidence = Read-Json $failedRunnerAudit
    $successfulChild = @($failedRunnerEvidence.children | Where-Object { [string]$_.name -eq 'successful-child' })
    if ([int]$failedRunnerEvidence.exitCode -eq 0 -or $failedRunnerEvidence.failures -notcontains 'controller identity lost' -or $successfulChild.Count -ne 1 -or -not [bool]$successfulChild[0].exited -or [int]$successfulChild[0].exitCode -ne 0) { throw 'failed runner audit did not retain its successful child truthfully' }
    Write-Host 'SelfTest verified truthful success, failed-child, and failed-runner audits'
    $auditProbeOut = New-FreshDirectory $root 'audit-probe-failure-evidence'
    $auditProbeAudit = Join-Path $auditProbeOut 'audit.json'
    $auditProbeData = New-RunnerData $auditProbeOut $root (Join-Path $auditProbeOut 'stop') $auditProbeAudit @([ordered]@{name='audit-probe-child';exe=$shell;args=@('-NoProfile','-File',$child,'-Mode','client','-Evidence',(Join-Path $auditProbeOut 'client.json'),'-StopPath',(Join-Path $auditProbeOut 'stop'));env=@{};start='immediate';stdout=(Join-Path $auditProbeOut 'child.out');stderr=(Join-Path $auditProbeOut 'child.err')}) $null $null 5
    $auditProbeData.testFailAuditProbeFor = 'audit-probe-child'
    $auditProbePath = Join-Path $root 'audit-probe-failure.json'
    Write-JsonFresh $auditProbePath $auditProbeData
    $auditProbe = Start-Runner 'audit-probe-failure' $shell $runner $auditProbePath $root $auditProbeAudit $owned
    $null = Wait-Json $auditProbeAudit $auditProbe ([datetime]::UtcNow.AddSeconds(8)) 'audit-probe failure audit'
    $auditProbe.process.WaitForExit(8000) | Out-Null
    $auditProbeEvidence = Read-Json $auditProbeAudit
    $auditProbeChild = @($auditProbeEvidence.children | Where-Object { [string]$_.name -eq 'audit-probe-child' })
    if ($auditProbe.process.ExitCode -eq 0 -or [int]$auditProbeEvidence.exitCode -eq 0 -or (@($auditProbeEvidence.failures) -join '; ') -notlike '*injected audit handle failure*' -or $auditProbeChild.Count -ne 1 -or -not [bool]$auditProbeChild[0].exited -or [int]$auditProbeChild[0].exitCode -ne 0) { throw 'audit probe failure did not preserve a successful child and nonzero aggregate result' }
    Write-Host 'SelfTest verified audit-probe failure makes the audit and runner nonzero without changing the successful child exit'
    $launchOut=New-FreshDirectory $root 'launch-failure-evidence'; $launchData=New-RunnerData $launchOut $root (Join-Path $launchOut 'stop') (Join-Path $launchOut 'audit.json') @([ordered]@{name='missing';exe=(Join-Path $root 'missing.exe');args=@();env=@{};start='immediate';stdout=(Join-Path $launchOut 'o');stderr=(Join-Path $launchOut 'e')}) $controller $null 5; $launchPath=Join-Path $root 'launch.json'; Write-JsonFresh $launchPath $launchData; $launch=Start-Runner 'launch-failure' $shell $runner $launchPath $root (Join-Path $launchOut 'audit.json') $owned; $null=Wait-Json (Join-Path $launchOut 'audit.json') $launch ([datetime]::UtcNow.AddSeconds(8)) 'launch-failure audit'; if((Read-Json (Join-Path $launchOut 'audit.json')).exitCode -eq 0){throw 'launch failure was accepted'}
    $script:TestFailProcessMetadataFor = 'metadata-retention'
    try {
        $null = Start-Runner 'metadata-retention' $shell $runner $launchPath $root (Join-Path $launchOut 'audit.json') $owned
        throw 'injected process metadata failure was accepted'
    } catch {
        if ("$_" -notlike '*injected process metadata failure*') { throw }
    } finally { $script:TestFailProcessMetadataFor = $null }
    $metadataRecord = $owned[$owned.Count - 1]
    if ($metadataRecord.name -ne 'metadata-retention' -or $null -eq $metadataRecord.process) { throw 'metadata failure lost the retained runner record' }
    $null = Stop-Retained $metadataRecord 12000
    Write-Host 'SelfTest retained and cleaned the runner after injected metadata failure'
    $timeoutOut=New-FreshDirectory $root 'timeout-evidence'; $timeoutData=New-RunnerData $timeoutOut $root (Join-Path $timeoutOut 'stop') (Join-Path $timeoutOut 'audit.json') @([ordered]@{name='hang';exe=$shell;args=@('-NoProfile','-File',$child,'-Mode','hang','-Evidence',(Join-Path $timeoutOut 'x'),' -StopPath',(Join-Path $timeoutOut 'stop'));env=@{};start='immediate';stdout=(Join-Path $timeoutOut 'o');stderr=(Join-Path $timeoutOut 'e')}) $controller $null 1; $timeoutPath=Join-Path $root 'timeout.json'; Write-JsonFresh $timeoutPath $timeoutData; $timeout=Start-Runner 'timeout' $shell $runner $timeoutPath $root (Join-Path $timeoutOut 'audit.json') $owned; $timeout.process.WaitForExit(12000)|Out-Null; if($timeout.process.ExitCode -eq 0 -or -not (Test-Path -LiteralPath (Join-Path $timeoutOut 'audit.json'))){throw 'timeout cleanup/audit failed'}
    $lossOut=New-FreshDirectory $root 'controller-loss-evidence'
    $lossStop=Join-Path $lossOut 'stop'
    $lossAudit=Join-Path $lossOut 'audit.json'
    $lossChild=[ordered]@{name='controller-loss-child';exe=$shell;args=@('-NoProfile','-File',$child,'-Mode','hang','-Evidence',(Join-Path $lossOut 'unused.json'),'-StopPath',$lossStop);env=@{};start='immediate';stdout=(Join-Path $lossOut 'child.out');stderr=(Join-Path $lossOut 'child.err')}
    $lossData=New-RunnerData $lossOut $root $lossStop $lossAudit @($lossChild) ([ordered]@{pid=429496729;creation_filetime=1;image=$shell}) $null 5
    $lossPath=Join-Path $root 'loss.json'
    Write-JsonFresh $lossPath $lossData
    $loss=Start-Runner 'controller-loss' $shell $runner $lossPath $root $lossAudit $owned
    $null=Wait-Json $lossAudit $loss ([datetime]::UtcNow.AddSeconds(15)) 'controller-loss audit'
    $lossEvidence=Read-Json $lossAudit
    $lossChildAudit=@($lossEvidence.children | Where-Object { [string]$_.name -eq 'controller-loss-child' })
    if($loss.process.ExitCode -eq 0 -or $lossEvidence.failures -notcontains 'controller identity lost' -or $lossChildAudit.Count -ne 1 -or -not [bool]$lossChildAudit[0].exited){throw 'controller-loss did not clean its retained child'}
    Write-Host 'SelfTest controller loss cleaned its retained child'
    Write-Host "diagnostics_validation SelfTest ok; simulated evidence retained at $root"
    } finally {
        $cleanupErrors = New-Object System.Collections.Generic.List[string]
        foreach ($record in $owned) {
            try { $null = Stop-Retained $record 12000 } catch { $cleanupErrors.Add("SelfTest cleanup $($record.name): $_") | Out-Null }
        }
        if ($cleanupErrors.Count -ne 0) { throw ($cleanupErrors -join '; ') }
    }
}
function Invoke-NativeValidation {
    $token=Get-CurrentTokenInfo
    if($null -eq $token -or [uint32]$token.rid -ne $MediumRid){throw 'native validation requires a Medium controller; do not run it from High'}
    Write-Host 'NATIVE VALIDATION IS PARENT-OWNED AFTER SOURCE INSPECTION.'; Write-Host $Gap
    $owned=New-Object System.Collections.Generic.List[object]; $mediumStopPaths=New-Object System.Collections.Generic.List[string]; $root=Join-Path ([IO.Path]::GetTempPath()) ('leopardwm-diagval-controller-'+(New-RunId)); New-Item -ItemType Directory -Path $root|Out-Null
    $handoffControl=$null
    $failure=$null
    try {
        $daemon=Get-TestExecutable 'leopardwm-daemon' 'leopardwm' (Join-Path $root 'cargo-daemon.json'); $cli=Get-TestExecutable 'leopardwm-cli' 'leopardwm-cli' (Join-Path $root 'cargo-cli.json')
        $scopeHigh=New-Scope; $scopeMedium=New-Scope; $pipeHigh=Get-Pipe $scopeHigh; $pipeMedium=Get-Pipe $scopeMedium; Assert-IsolatedPipe $scopeHigh $pipeHigh; Assert-IsolatedPipe $scopeMedium $pipeMedium
        $runId=New-RunId; $handoffPipe=Get-Pipe ("diagval_handoff_$runId"); Assert-IsolatedPipe ("diagval_handoff_$runId") $handoffPipe
        $handoffControl=New-HandoffControlServer $handoffPipe
        $highExec=Join-Path ([IO.Path]::GetTempPath()) ('leopardwm-diagval-high-'+(New-RunId)); $highOut=Join-Path $highExec 'output'; $highStop=Join-Path $highOut 'stop'
        $controller=[ordered]@{pid=$PID;creation_filetime=[uint64](Get-Process -Id $PID).StartTime.ToFileTimeUtc();image=(Get-Process -Id $PID).Path}
        $highData=[ordered]@{runDir=$highOut;workingDir=$highExec;stopPath=$highStop;auditPath=(Join-Path $highOut 'high-runner-audit.json');timeoutSec=90;environment_policy='clear_diagnostics';controller=$controller;handoff=[ordered]@{pipe=$handoffPipe;run_id=$runId;server_pipe=$pipeMedium};children=@(
          [ordered]@{name='high-host';exe=(Join-Path $highExec 'daemon-test.exe');args=$TestArgs;env=(New-HostEnv $highOut $scopeHigh 'high-host' '1');start='immediate';stdout=(Join-Path $highOut 'high-host.out');stderr=(Join-Path $highOut 'high-host.err')},
          [ordered]@{name='high-client';exe=(Join-Path $highExec 'cli-test.exe');args=$TestArgs;env=(New-ClientEnv $highOut 'high-client');start='handoff';stopAfterExit=$true;stdout=(Join-Path $highOut 'high-client.out');stderr=(Join-Path $highOut 'high-client.err')}
        )}
        $highDataSource=Join-Path $root 'high-runner-data.json'; Write-JsonFresh $highDataSource $highData
        $mainSource=$PSCommandPath; $runnerSource=Join-Path $RepoRoot 'tools\diagnostics_validation_runner.ps1'; $bootstrapSource=Join-Path $RepoRoot 'tools\diagnostics_validation_uac_bootstrap.ps1'; $dependencies=Get-ArtifactDependencies @($daemon,$cli)
        $spec=[ordered]@{version=1;high_exec_dir=$highExec;high_output_dir=$highOut;dependencies=$dependencies;main=[ordered]@{source=$mainSource;sha256=(Get-Sha256 $mainSource)};runner=[ordered]@{source=$runnerSource;sha256=(Get-Sha256 $runnerSource)};daemon=[ordered]@{source=$daemon;sha256=(Get-Sha256 $daemon)};cli=[ordered]@{source=$cli;sha256=(Get-Sha256 $cli)};runner_data=[ordered]@{source=$highDataSource;sha256=(Get-Sha256 $highDataSource)}}
        $specPath=Join-Path $root 'high-pin-spec.json'; Write-JsonFresh $specPath $spec; $specHash=Get-Sha256 $specPath
        $bootstrapPath=Join-Path $root 'pinned-uac-bootstrap.ps1'; "`$FrozenSpecPath = $(ConvertTo-PsLiteral $specPath)`n`$FrozenSpecHash = $(ConvertTo-PsLiteral $specHash)`n" + [IO.File]::ReadAllText($bootstrapSource) | Set-Content -LiteralPath $bootstrapPath -Encoding UTF8 -NoNewline
        $shell=(Get-Process -Id $PID).Path; $high=Start-PinnedBootstrap $shell $bootstrapPath $specPath $specHash $root $owned; Write-JsonFresh (Join-Path $root 'controller.json') ([ordered]@{controller=$controller;high_bootstrap=[ordered]@{pid=$high.pid;creation_filetime=$high.creation_filetime;image=$high.image};high_output=$highOut;medium_root=(Join-Path $root 'medium');gap=$Gap})
        $deadline=[datetime]::UtcNow.AddSeconds(110); $fixture=Wait-Json (Join-Path $highOut 'fixture.json') $high $deadline 'High fixture'; $highHost=Wait-Json (Join-Path $highOut 'high-host.json') $high $deadline 'High host'; $null=Wait-Json (Join-Path $highOut 'high-host-ready.json') $high $deadline 'High host readiness'; Wait-HandoffReceiver $handoffControl $high $deadline
        $mediumRoot=New-FreshDirectory $root 'medium'; $mediumHost=New-FreshDirectory $mediumRoot 'host'; $mediumClient=New-FreshDirectory $mediumRoot 'client'; $mediumStopPaths.Add((Join-Path $mediumHost 'stop')) | Out-Null; $mediumStopPaths.Add((Join-Path $mediumClient 'stop')) | Out-Null; [IO.File]::Copy((Join-Path $highOut 'fixture.json'),(Join-Path $mediumHost 'fixture.json'),$false)
        $mediumHostData=New-RunnerData $mediumHost $root (Join-Path $mediumHost 'stop') (Join-Path $mediumHost 'audit.json') @([ordered]@{name='medium-host';exe=$daemon;args=$TestArgs;env=(New-HostEnv $mediumHost $scopeMedium 'medium-host' '0');start='immediate';stdout=(Join-Path $mediumHost 'medium-host.out');stderr=(Join-Path $mediumHost 'medium-host.err')}) $null $null 90; $mediumHostDataPath=Join-Path $mediumRoot 'host-runner.json'; Write-JsonFresh $mediumHostDataPath $mediumHostData; $mh=Start-Runner 'medium-host-runner' $shell $runnerSource $mediumHostDataPath $root (Join-Path $mediumHost 'audit.json') $owned; $mediumHostEvidence=Wait-Json (Join-Path $mediumHost 'medium-host.json') $mh $deadline 'Medium host'; $null=Wait-Json (Join-Path $mediumHost 'medium-host-ready.json') $mh $deadline 'Medium host readiness'
        $clientEnv=New-ClientEnv $mediumClient 'medium-client'; $clientEnv.LEOPARDWM_DIAGNOSTICS_PIPE=$pipeHigh; $clientEnv.LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_PID=[string]$highHost.pid; $clientEnv.LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_CREATION=[string]$highHost.creation_filetime
        $mediumClientData=New-RunnerData $mediumClient $root (Join-Path $mediumClient 'stop') (Join-Path $mediumClient 'audit.json') @([ordered]@{name='medium-client';exe=$cli;args=$TestArgs;env=$clientEnv;start='immediate';stdout=(Join-Path $mediumClient 'medium-client.out');stderr=(Join-Path $mediumClient 'medium-client.err')}) $null $null 60; $mediumClientDataPath=Join-Path $mediumRoot 'client-runner.json'; Write-JsonFresh $mediumClientDataPath $mediumClientData; $mc=Start-Runner 'medium-client-runner' $shell $runnerSource $mediumClientDataPath $root (Join-Path $mediumClient 'audit.json') $owned; $null=Wait-Json (Join-Path $mediumClient 'medium-client.json') $mc $deadline 'Medium client'
        Send-ServerIdentity $handoffControl $runId $pipeMedium ([uint32]$mediumHostEvidence.pid) ([uint64]$mediumHostEvidence.creation_filetime) $high; $handoffControl.Dispose(); $handoffControl=$null; $null=Wait-Json (Join-Path $highOut 'high-client.json') $high $deadline 'High client'
        $fixture=Assert-NativeMatrix $highOut $mediumHost $mediumClient
        Set-Content -LiteralPath (Join-Path $mediumHost 'stop') -Value 'stop'
        $null=Stop-Retained $mh 25000; $null=Stop-Retained $mc 25000; if(-not $high.process.WaitForExit(30000)){throw 'High bootstrap did not exit after its owned client completed'}; if($high.process.ExitCode -ne 0){throw "High bootstrap exit $($high.process.ExitCode)"}; $highSide=Read-Json (Join-Path $highOut 'high-side.json'); if([string]$highSide.status -ne 'exited' -or [int]$highSide.runner_exit -ne 0){throw 'High side exit audit failed'}; if(Test-WindowExists ([uint64]$fixture.hwnd)){throw 'High fixture HWND remains after High cleanup'}; Assert-Audit (Join-Path $highOut 'high-runner-audit.json') @('high-host','high-client') 'High'; Assert-Audit (Join-Path $mediumHost 'audit.json') @('medium-host') 'Medium host'; Assert-Audit (Join-Path $mediumClient 'audit.json') @('medium-client') 'Medium client'; Write-Host "native pipeline passed; High evidence: $highOut; Medium evidence: $mediumRoot; controller evidence: $root"
    } catch { $failure=$_ } finally {
        $errors=New-Object System.Collections.Generic.List[string]
        if($null -ne $handoffControl) { try { $handoffControl.Dispose() } catch { $errors.Add("handoff control disposal: $_") | Out-Null } }
        foreach($stopPath in $mediumStopPaths) { try { if(-not(Test-Path -LiteralPath $stopPath)){Set-Content -LiteralPath $stopPath -Value 'stop'} } catch { $errors.Add("Medium stop ${stopPath}: $_") | Out-Null } }
        $mediumOwned=New-Object System.Collections.Generic.List[object]
        $highRecord=$null
        foreach($record in $owned) { if($record.name -eq 'high-bootstrap'){$highRecord=$record}else{$mediumOwned.Add($record)|Out-Null} }
        foreach($error in @(Stop-Owned $mediumOwned 25000)){$errors.Add($error)|Out-Null}
        if($null -ne $highRecord -and -not $highRecord.process.HasExited) {
            if(-not $highRecord.process.WaitForExit(100000)) { $errors.Add('High bootstrap did not exit through its own timeout/controller-loss cleanup') | Out-Null }
        }
        if($null -ne $failure -and $errors.Count -ne 0){throw "native validation failed: $failure; cleanup also failed: $($errors -join '; ')"}; if($null -ne $failure){throw $failure}; if($errors.Count -ne 0){throw "native validation cleanup failed: $($errors -join '; ')"}
    }
}
if($SyntaxOnly){Write-Host 'diagnostics_validation.ps1 parsed';exit 0}
if($HighSide){Invoke-HighSide;exit $LASTEXITCODE}
if($RunNative){Invoke-NativeValidation;exit 0}
Invoke-SelfTest
