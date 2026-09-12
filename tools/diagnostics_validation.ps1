# Opt-in Medium/High diagnostics validation driver.
# Default / -SelfTest: fail-closed checks plus harmless runner orchestration. No UAC or native hosts.
# -RunNative is parent-owned after safety inspection. This script does not
# start the full daemon, load live config, or fall back to \\.\pipe\leopardwm.
#
# Gap: skip_if_elevation_blocked is cfg(not(test)); this pipeline is not full
# daemon startup/admission E2E.

[CmdletBinding()]
param(
    [switch]$SyntaxOnly,
    [switch]$SelfTest,
    [switch]$RunNative,
    [string]$RepoRoot = $(
        if ($PSScriptRoot) {
            (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        } else {
            (Get-Location).Path
        }
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:TestFailRunnerStartTimeFor = $null

$DailyDriverPipe = '\\.\pipe\leopardwm'
$LocalDiagValPrefix = '\\.\pipe\leopardwm_diagval_'
$MediumRid = [uint32]0x2000
$HighRid = [uint32]0x3000
$Gap = 'skip_if_elevation_blocked is cfg(not(test)); this host is not full daemon startup/admission E2E. It feeds manage_block/window_manage_block into note_elevation_block then handle_command(HealthCheck) through run_ipc_server.'
$FixtureTitle = 'LeopardWM diagnostics validation fixture'
$LeopardWmEnvNames = @(
    'LEOPARDWM_DIAGNOSTICS_VALIDATION',
    'LEOPARDWM_DIAGNOSTICS_ROLE',
    'LEOPARDWM_DIAGNOSTICS_RUN_DIR',
    'LEOPARDWM_DIAGNOSTICS_EVIDENCE_PREFIX',
    'LEOPARDWM_DIAGNOSTICS_OWN_HWND',
    'LEOPARDWM_DIAGNOSTICS_TIMEOUT_SECS',
    'LEOPARDWM_DIAGNOSTICS_PIPE',
    'LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_PID',
    'LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_CREATION',
    'LEOPARDWM_DIAGNOSTICS_TARGET_HWND',
    'LEOPARDWM_DIAGNOSTICS_TARGET_PID',
    'LEOPARDWM_DIAGNOSTICS_TARGET_TITLE',
    'LEOPARDWM_PIPE_SCOPE'
)

function Test-OptInEnabled([string]$Value) {
    return $Value -eq '1'
}

function New-DiagValScope {
    $nsec = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $tag = -join ((1..6) | ForEach-Object { [char](Get-Random -InputObject ([char[]](97..122))) })
    return "diagval_${PID}_${nsec}_$tag"
}

function Get-DiagValPipe([string]$Scope) {
    return "$DailyDriverPipe`_$($Scope.ToLowerInvariant())"
}

function Test-ExactPipe([string]$Requested) {
    if ([string]::IsNullOrWhiteSpace($Requested)) { return $false }
    if ($Requested -eq $DailyDriverPipe) { return $false }
    if (-not $Requested.StartsWith($LocalDiagValPrefix)) { return $false }
    $rest = $Requested.Substring($LocalDiagValPrefix.Length)
    if ([string]::IsNullOrWhiteSpace($rest)) { return $false }
    if ($rest.Contains('\') -or $rest.Contains('/')) { return $false }
    if ($rest -cne $rest.ToLowerInvariant()) { return $false }
    if ($rest -notmatch '^[a-z0-9._-]+$') { return $false }
    return $true
}

function Test-IsolatedPipe([string]$Scope, [string]$Pipe) {
    if ([string]::IsNullOrWhiteSpace($Scope)) { return $false }
    if (-not $Scope.ToLowerInvariant().StartsWith('diagval_')) { return $false }
    if ($Pipe -eq $DailyDriverPipe) { return $false }
    $fromScope = Get-DiagValPipe $Scope
    if ($Pipe -ne $fromScope) { return $false }
    return (Test-ExactPipe $Pipe)
}

function Test-AllowedCommand([string]$Name) {
    return @('HealthCheck', 'QueryStatus') -contains $Name
}

function Test-ShouldStopProcess($Recorded, $Live) {
    if ($null -eq $Recorded -or $null -eq $Live) { return $false }
    if ($null -eq $Recorded.Pid -or $null -eq $Recorded.CreationFileTime) { return $false }
    if ([uint32]$Recorded.Pid -eq 0 -or [uint64]$Recorded.CreationFileTime -eq 0) { return $false }
    if ($Recorded.Pid -ne $Live.Pid) { return $false }
    if ($Recorded.CreationFileTime -ne $Live.CreationFileTime) { return $false }
    if ([string]::IsNullOrWhiteSpace($Recorded.Image) -or [string]::IsNullOrWhiteSpace($Live.Image)) {
        return $false
    }
    $a = [IO.Path]::GetFullPath($Recorded.Image).ToLowerInvariant()
    $b = [IO.Path]::GetFullPath($Live.Image).ToLowerInvariant()
    return $a -eq $b
}

function Test-DeadlineExceeded([double]$Elapsed, [double]$Timeout) {
    return $Elapsed -ge $Timeout
}

function Get-Win32NativeErrorCode([System.Exception]$Exception) {
    $ex = $Exception
    while ($null -ne $ex) {
        if ($ex -is [System.ComponentModel.Win32Exception]) {
            return [int]$ex.NativeErrorCode
        }
        $ex = $ex.InnerException
    }
    return $null
}

function Get-UacLaunchOutcome {
    param($Exception)
    if ($null -eq $Exception) { return 'started' }
    $code = Get-Win32NativeErrorCode $Exception
    if ($code -eq 1223) { return 'cancelled' }
    return 'failed'
}

function Test-UacCancelledIsTerminal([string]$Outcome) {
    return $Outcome -eq 'cancelled'
}

function Get-LauncherRoute($Rid, $ElevationType, $LinkedRid) {
    if ($null -eq $Rid) { return $null }
    if ([uint32]$Rid -eq $MediumRid) {
        return 'medium-runas'
    }
    if ([uint32]$Rid -eq $HighRid -and [int]$ElevationType -eq 2 -and [uint32]$LinkedRid -eq $MediumRid) {
        return 'high-linked-medium'
    }
    return $null
}

function Test-RidPair($Oracle, $Platform, [uint32]$Expected) {
    if ($null -eq $Oracle -or $null -eq $Platform) { return $false }
    return ([uint32]$Oracle -eq $Expected) -and ([uint32]$Platform -eq $Expected)
}

function Get-DaemonIntegrityFromHealth($Health) {
    if ($null -eq $Health) { return $null }
    $status = $null
    if ($Health.PSObject.Properties.Name -contains 'status') { $status = [string]$Health.status }
    if ($status -ne 'health_info') { return $null }
    if ($Health.PSObject.Properties.Name -notcontains 'daemon_integrity') { return $null }
    return $Health.daemon_integrity
}

function Test-FixtureIdentityComplete($Fixture) {
    if ($null -eq $Fixture) { return $false }
    if ($null -eq $Fixture.hwnd -or [uint64]$Fixture.hwnd -eq 0) { return $false }
    if ($null -eq $Fixture.pid -or [uint32]$Fixture.pid -eq 0) { return $false }
    if ($null -eq $Fixture.creation_filetime -or [uint64]$Fixture.creation_filetime -eq 0) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Fixture.image) -or [string]$Fixture.image -eq 'unavailable') { return $false }
    return $true
}

function Test-ClassificationsAgree([string]$Window, [string]$Process) {
    if ([string]::IsNullOrWhiteSpace($Window) -or [string]::IsNullOrWhiteSpace($Process)) { return $false }
    return $Window -eq $Process
}

function Get-ExecutableFromCargoJson {
    param(
        [object[]]$Lines,
        [int]$ExitCode,
        [string]$Bin
    )
    if ($ExitCode -ne 0) {
        throw "cargo test --no-run failed: $ExitCode"
    }
    $exe = $null
    foreach ($line in @($Lines)) {
        $text = [string]$line
        try {
            $obj = $text | ConvertFrom-Json
        } catch {
            continue
        }
        if ($obj.reason -eq 'compiler-artifact' -and $obj.profile.test -and $obj.target.name -eq $Bin -and $obj.executable) {
            $exe = [string]$obj.executable
        }
    }
    if (-not $exe) { throw "could not locate test executable for $Bin" }
    return $exe
}

function Write-JsonAtomic {
    param([string]$Path, $Object)
    $tmp = "$Path.$PID.tmp"
    $Object | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-JsonFile([string]$Path) {
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    return $raw | ConvertFrom-Json
}

function Get-RetainedProcessState($Record) {
    if ($null -eq $Record) { return $null }
    try {
        if ($null -ne $Record.PSObject.Properties['NativeHandle']) {
            $wait = [DiagValToken]::WaitForSingleObject([IntPtr]$Record.NativeHandle, 0)
            if ($wait -eq 0) {
                $code = [uint32]0
                if (-not [DiagValToken]::GetExitCodeProcess([IntPtr]$Record.NativeHandle, [ref]$code)) { throw 'could not read native child exit code' }
                return [pscustomobject]@{ Exited = $true; ExitCode = [int]$code }
            }
            if ($wait -ne 258) { throw 'native retained process handle is unusable' }
            return [pscustomobject]@{ Exited = $false; ExitCode = $null }
        }
        if ($Record.Process.HasExited) { return [pscustomobject]@{ Exited = $true; ExitCode = [int]$Record.Process.ExitCode } }
        return [pscustomobject]@{ Exited = $false; ExitCode = $null }
    } catch [System.InvalidOperationException] {
        throw 'retained process handle lost while waiting for child evidence'
    }
}

function Wait-DiagJson {
    param(
        [string]$Path,
        [int]$TimeoutSec,
        $Process
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $json = $null
        $validJson = $false
        if (Test-Path -LiteralPath $Path) {
            try {
                $json = Read-JsonFile $Path
                $validJson = $true
            } catch {
                # Atomic publication can be observed while the replacement is in progress.
            }
        }
        if ($null -ne $Process) {
            $state = Get-RetainedProcessState $Process
            if ($state.Exited) {
                if ($state.ExitCode -ne 0) { throw "child exited $($state.ExitCode) while waiting for $Path" }
                if ($validJson) { return $json }
                throw "child exited 0 before $Path"
            }
        }
        if ($validJson) { return $json }
        Start-Sleep -Milliseconds 100
    }
    throw "timed out waiting for $Path"
}

function Get-TestExecutable {
    param(
        [string]$Package,
        [string]$Bin,
        [string]$RepoRoot,
        [string]$LogPath
    )
    $manifest = Join-Path $RepoRoot 'Cargo.toml'
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw "RepoRoot Cargo.toml missing: $manifest"
    }
    $lines = & cargo test -p $Package --bin $Bin --no-run --message-format=json --manifest-path $manifest 2>&1
    $exit = $LASTEXITCODE
    if ($LogPath) {
        @($lines | ForEach-Object { [string]$_ }) | Set-Content -LiteralPath $LogPath -Encoding UTF8
    }
    return Get-ExecutableFromCargoJson -Lines $lines -ExitCode $exit -Bin $Bin
}

function Initialize-DiagValTokenNative {
    if ('DiagValToken' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DiagValToken {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle; public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags; public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError; }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool GetTokenInformation(IntPtr token, int tokenClass, IntPtr info, uint len, out uint ret);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool CreateProcessWithTokenW(IntPtr token, int logonFlags, string applicationName, string commandLine, uint creationFlags, IntPtr environment, string currentDirectory, ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr h, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr h, uint exitCode);
    [DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
    [DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    public const int TokenElevationType = 18;
    public const int TokenLinkedToken = 19;
    public const int TokenIntegrityLevel = 25;
    public const uint TOKEN_QUERY = 0x0008;
}
"@
}

function Get-TokenIntegrityRid([IntPtr]$Token) {
    $ret = [uint32]0
    [void][DiagValToken]::GetTokenInformation($Token, [DiagValToken]::TokenIntegrityLevel, [IntPtr]::Zero, 0, [ref]$ret)
    if ($ret -eq 0) { return $null }
    $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal([int]$ret)
    try {
        if (-not [DiagValToken]::GetTokenInformation($Token, [DiagValToken]::TokenIntegrityLevel, $buf, $ret, [ref]$ret)) { return $null }
        $sid = [Runtime.InteropServices.Marshal]::ReadIntPtr($buf)
        if ($sid -eq [IntPtr]::Zero) { return $null }
        $count = [Runtime.InteropServices.Marshal]::ReadByte([DiagValToken]::GetSidSubAuthorityCount($sid))
        if ($count -eq 0) { return $null }
        return [uint32][Runtime.InteropServices.Marshal]::ReadInt32([DiagValToken]::GetSidSubAuthority($sid, [uint32]($count - 1)))
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    }
}

function Get-CurrentTokenInfo {
    Initialize-DiagValTokenNative
    $token = [IntPtr]::Zero
    if (-not [DiagValToken]::OpenProcessToken([DiagValToken]::GetCurrentProcess(), [DiagValToken]::TOKEN_QUERY, [ref]$token)) { return $null }
    try {
        $elevationType = 0
        $size = [uint32]4
        $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        try {
            if (-not [DiagValToken]::GetTokenInformation($token, [DiagValToken]::TokenElevationType, $buffer, $size, [ref]$size)) { return $null }
            $elevationType = [Runtime.InteropServices.Marshal]::ReadInt32($buffer)
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
        }
        return [pscustomobject]@{ Rid = Get-TokenIntegrityRid $token; ElevationType = $elevationType }
    } finally {
        [void][DiagValToken]::CloseHandle($token)
    }
}

function Get-OwnLinkedMediumToken {
    Initialize-DiagValTokenNative
    $current = [IntPtr]::Zero
    if (-not [DiagValToken]::OpenProcessToken([DiagValToken]::GetCurrentProcess(), [DiagValToken]::TOKEN_QUERY, [ref]$current)) { throw 'could not open own process token' }
    try {
        $size = [uint32]4
        $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        try {
            if (-not [DiagValToken]::GetTokenInformation($current, [DiagValToken]::TokenElevationType, $buffer, $size, [ref]$size) -or [Runtime.InteropServices.Marshal]::ReadInt32($buffer) -ne 2) {
                throw 'own token is not Full; refusing linked-token launch'
            }
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
        }
        $linkedBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
        try {
            $linkedSize = [uint32][IntPtr]::Size
            if (-not [DiagValToken]::GetTokenInformation($current, [DiagValToken]::TokenLinkedToken, $linkedBuffer, $linkedSize, [ref]$linkedSize)) {
                throw 'own linked token is unavailable'
            }
            $linked = [Runtime.InteropServices.Marshal]::ReadIntPtr($linkedBuffer)
            if ($linked -eq [IntPtr]::Zero) { throw 'own linked token handle is invalid' }
            if ((Get-TokenIntegrityRid $linked) -ne $MediumRid) {
                [void][DiagValToken]::CloseHandle($linked)
                throw 'own linked token is not Medium; refusing launch'
            }
            return $linked
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($linkedBuffer)
        }
    } finally {
        [void][DiagValToken]::CloseHandle($current)
    }
}

function Get-CurrentIntegrityRid {
    $info = Get-CurrentTokenInfo
    if ($null -eq $info) { return $null }
    return $info.Rid
}

function Test-WindowExists([uint64]$Hwnd) {
    if ($Hwnd -eq 0) { return $false }
    if (-not ('DiagValUser32' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DiagValUser32 {
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);
}
"@
    }
    return [DiagValUser32]::IsWindow([IntPtr]$Hwnd)
}

function Join-ProcessArguments([string[]]$Arguments) {
    $parts = foreach ($argument in $Arguments) {
        $escaped = ([string]$argument -replace '(\\*)"', '$1$1\\"') -replace '(\\+)$', '$1$1'
        '"' + $escaped + '"'
    }
    return $parts -join ' '
}

function New-DotNetProcessRecord([string]$Name, $Process, [string]$AuditPath = $null, [string[]]$ExpectedChildren = @()) {
    return [pscustomobject]@{
        Name             = $Name
        Process          = $Process
        Pid              = $null
        CreationFileTime = $null
        AuditPath        = $AuditPath
        ExpectedChildren = @($ExpectedChildren)
    }
}

function Start-DiagRunner([string]$Name, [string]$Shell, [string]$RunnerPath, [string]$DataPath, [string]$RunDir, [string]$AuditPath, [string[]]$ExpectedChildren, $Owned, [switch]$Elevated) {
    $arguments = Join-ProcessArguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $RunnerPath, '-DataPath', $DataPath)
    if ($Elevated) {
        $process = Start-Process -FilePath $Shell -ArgumentList $arguments -Verb RunAs -PassThru -WindowStyle Hidden -WorkingDirectory $RunDir
    } else {
        $process = Start-Process -FilePath $Shell -ArgumentList $arguments -PassThru -WindowStyle Hidden -WorkingDirectory $RunDir
    }
    if ($null -eq $process) { throw "Start-Process returned no handle for $Name" }
    $record = New-DotNetProcessRecord -Name $Name -Process $process -AuditPath $AuditPath -ExpectedChildren $ExpectedChildren
    $Owned.Add($record) | Out-Null
    $record.Pid = [uint32]$process.Id
    if ($script:TestFailRunnerStartTimeFor -eq $Name) { throw "injected runner StartTime failure for $Name" }
    $record.CreationFileTime = [uint64]$process.StartTime.ToFileTimeUtc()
    return $record
}

function Start-LinkedTokenDiagRunner([string]$Name, [string]$Shell, [string]$RunnerPath, [string]$DataPath, [string]$RunDir, [string]$AuditPath, [string[]]$ExpectedChildren, $Owned) {
    $token = Get-OwnLinkedMediumToken
    try {
        $startup = New-Object DiagValToken+STARTUPINFO
        $startup.cb = [Runtime.InteropServices.Marshal]::SizeOf($startup)
        $startup.dwFlags = 1
        $startup.wShowWindow = 0
        $processInfo = New-Object DiagValToken+PROCESS_INFORMATION
        $arguments = Join-ProcessArguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $RunnerPath, '-DataPath', $DataPath)
        $commandLine = "$(Join-ProcessArguments @($Shell)) $arguments"
        if (-not [DiagValToken]::CreateProcessWithTokenW($token, 0, $Shell, $commandLine, 0x08000000, [IntPtr]::Zero, $RunDir, [ref]$startup, [ref]$processInfo)) {
            throw "CreateProcessWithTokenW for $Name failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        [void][DiagValToken]::CloseHandle($processInfo.hThread)
        $record = [pscustomobject]@{
            Name             = $Name
            NativeHandle     = $processInfo.hProcess
            Pid              = [uint32]$processInfo.dwProcessId
            CreationFileTime = $null
            AuditPath        = $AuditPath
            ExpectedChildren = @($ExpectedChildren)
        }
        $Owned.Add($record) | Out-Null
        if ($script:TestFailRunnerStartTimeFor -eq $Name) { throw "injected runner StartTime failure for $Name" }
        $record.CreationFileTime = [uint64](Get-Process -Id $processInfo.dwProcessId -ErrorAction Stop).StartTime.ToFileTimeUtc()
        return $record
    } finally {
        [void][DiagValToken]::CloseHandle($token)
    }
}

function Stop-RetainedProcess {
    param($Record, [int]$WaitMs)
    if ($null -eq $Record) { throw 'missing retained process handle' }
    if ($null -ne $Record.PSObject.Properties['NativeHandle']) {
        $handle = [IntPtr]$Record.NativeHandle
        $state = Get-RetainedProcessState $Record
        if ($state.Exited) { return [int]$state.ExitCode }
        if ([DiagValToken]::WaitForSingleObject($handle, [uint32]$WaitMs) -eq 0) { return (Get-RetainedProcessState $Record).ExitCode }
        if (-not [DiagValToken]::TerminateProcess($handle, 1)) { throw "could not terminate $($Record.Name) through its retained native handle" }
        if ([DiagValToken]::WaitForSingleObject($handle, [uint32]$WaitMs) -ne 0) { throw "process $($Record.Name) pid $($Record.Pid) did not exit after kill" }
        return (Get-RetainedProcessState $Record).ExitCode
    }
    if ($null -eq $Record.Process) { throw 'missing retained process handle' }
    $process = $Record.Process
    if ($process.HasExited) { return [int]$process.ExitCode }
    if ($process.WaitForExit($WaitMs)) { return [int]$process.ExitCode }
    try { $process.Kill() } catch { if (-not $process.HasExited) { throw } }
    if (-not $process.WaitForExit($WaitMs)) { throw "process $($Record.Name) pid $($Record.Pid) did not exit after kill" }
    return [int]$process.ExitCode
}

function Close-RetainedProcessHandle($Record) {
    if ($null -ne $Record -and $null -ne $Record.PSObject.Properties['NativeHandle'] -and [IntPtr]$Record.NativeHandle -ne [IntPtr]::Zero) {
        [void][DiagValToken]::CloseHandle([IntPtr]$Record.NativeHandle)
        $Record.NativeHandle = [IntPtr]::Zero
    }
}

function Stop-OwnedProcesses($Owned, [int]$WaitMs) {
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($record in $Owned) {
        try {
            $code = Stop-RetainedProcess -Record $record -WaitMs $WaitMs
            if ($code -ne 0) { $errors.Add("$($record.Name) exit $code") | Out-Null }
        } catch {
            $errors.Add("cleanup $($record.Name): $_") | Out-Null
        }
    }
    return @($errors)
}

function Assert-RunnerAudit([string]$Path, [string[]]$ExpectedChildren, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Label audit missing: $Path" }
    try { $audit = Read-JsonFile $Path } catch { throw "$Label audit corrupt: $_" }
    if ([int]$audit.exitCode -ne 0) { throw "$Label audit exit $($audit.exitCode)" }
    if (@($audit.failures).Count -ne 0) { throw "$Label audit reports failures: $(@($audit.failures) -join '; ')" }
    $expected = @($ExpectedChildren | Sort-Object -Unique)
    $declared = @($audit.expectedChildren | Sort-Object -Unique)
    if (($expected -join '|') -ne ($declared -join '|')) { throw "$Label audit expected child set mismatch" }
    $children = @($audit.children)
    if ($children.Count -ne $expected.Count) { throw "$Label audit launched child count mismatch" }
    foreach ($name in $expected) {
        $matches = @($children | Where-Object { [string]$_.name -eq $name })
        if ($matches.Count -ne 1) { throw "$Label audit missing or duplicate child $name" }
        $child = $matches[0]
        if ([uint32]$child.pid -eq 0 -or [uint64]$child.creation_filetime -eq 0) { throw "$Label audit child $name lacks launch identity" }
        if (-not [bool]$child.exited -or [int]$child.exitCode -ne 0) { throw "$Label audit child $name did not exit 0" }
    }
}

function Assert-OwnedRunnerAudits($Owned) {
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($record in $Owned) {
        if (-not [string]::IsNullOrWhiteSpace([string]$record.AuditPath)) {
            try {
                Assert-RunnerAudit -Path $record.AuditPath -ExpectedChildren @($record.ExpectedChildren) -Label $record.Name
            } catch {
                $errors.Add("$($record.Name): $_") | Out-Null
            }
        }
    }
    return @($errors)
}

function Save-ProcessEnv([string[]]$Names) {
    $saved = @{}
    foreach ($name in $Names) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    return $saved
}

function Restore-ProcessEnv($Saved) {
    foreach ($name in @($Saved.Keys)) {
        [Environment]::SetEnvironmentVariable($name, $Saved[$name], 'Process')
    }
}

function Assert-RidObserved($Info, [uint32]$Expected, [string]$Label) {
    if ($null -eq $Info) { throw "$Label evidence missing" }
    if (-not (Test-RidPair $Info.oracle_integrity_rid $Info.platform_integrity_rid $Expected)) {
        throw "$Label oracle/platform RID $($Info.oracle_integrity_rid)/$($Info.platform_integrity_rid) != 0x$($Expected.ToString('X'))"
    }
}

function Assert-HealthDaemonRid($Health, [uint32]$Expected, [string]$Label) {
    $rid = Get-DaemonIntegrityFromHealth $Health
    if ($null -eq $rid) { throw "$Label HealthInfo missing daemon integrity" }
    if ([uint32]$rid -ne $Expected) {
        throw "$Label daemon_integrity $rid != 0x$($Expected.ToString('X'))"
    }
}

function Assert-NoBlocked($Health, [string]$Label) {
    if ($null -eq $Health) { throw "$Label HealthInfo missing" }
    if ($Health.PSObject.Properties.Name -notcontains 'elevation_blocked_records' -or $null -eq $Health.elevation_blocked_records) {
        throw "$Label missing elevation_blocked_records"
    }
    $count = @($Health.elevation_blocked_records).Count
    if ($count -ne 0) { throw "$Label expected no blocked windows, found $count" }
}

function Assert-HigherIntegrityBlock($Health, $Fixture, [string]$Label) {
    if ($null -eq $Health) { throw "$Label HealthInfo missing" }
    $records = @($Health.elevation_blocked_records)
    if ($records.Count -lt 1) { throw "$Label missing blocked records" }
    $match = $false
    foreach ($record in $records) {
        if ([uint64]$record.hwnd -eq [uint64]$Fixture.hwnd -and [string]$record.title -eq [string]$Fixture.title -and [string]$record.reason -eq 'higher_integrity') {
            $match = $true
        }
    }
    if (-not $match) { throw "$Label rich blocked record did not match fixture hwnd/title/reason" }
    $legacy = @($Health.elevation_blocked_windows)
    $legacyMatch = $false
    foreach ($row in $legacy) {
        if (@($row).Count -ge 2 -and [uint64]$row[0] -eq [uint64]$Fixture.hwnd -and [string]$row[1] -eq [string]$Fixture.title) {
            $legacyMatch = $true
        }
    }
    if (-not $legacyMatch) { throw "$Label legacy blocked pair did not match fixture hwnd/title" }
}

function Assert-RenderedIntegrity([string]$Line, [string]$Label, [string]$ExpectedWord) {
    if ([string]::IsNullOrWhiteSpace($Line)) { throw "$Label rendered line missing" }
    if ($Line -notlike "*$ExpectedWord*") { throw "$Label rendered '$Line' missing $ExpectedWord" }
    if ($Line -like '*unavailable*') { throw "$Label rendered unavailable" }
}

function Assert-NativeMatrix {
    param($RunDir)
    $fixture = Read-JsonFile (Join-Path $RunDir 'fixture.json')
    if (-not (Test-FixtureIdentityComplete $fixture)) { throw 'fixture identity incomplete' }
    if ([bool]$fixture.visible) { throw 'fixture was visible' }
    $highHost = Read-JsonFile (Join-Path $RunDir 'high-host.json')
    $mediumHost = Read-JsonFile (Join-Path $RunDir 'medium-host.json')
    $mediumClient = Read-JsonFile (Join-Path $RunDir 'medium-client.json')
    $highClient = Read-JsonFile (Join-Path $RunDir 'high-client.json')
    Assert-RidObserved $highHost $HighRid 'high-host'
    Assert-RidObserved $mediumHost $MediumRid 'medium-host'
    Assert-RidObserved $mediumClient $MediumRid 'medium-client'
    Assert-RidObserved $highClient $HighRid 'high-client'
    if (-not (Test-ClassificationsAgree ([string]$highHost.admission.window_manage_block) ([string]$highHost.admission.manage_block))) {
        throw 'high-host window/process classification disagree'
    }
    if ([string]$highHost.admission.noted -ne 'No') { throw 'high-host/high-fixture should not be blocked' }
    if (-not (Test-ClassificationsAgree ([string]$mediumHost.admission.window_manage_block) ([string]$mediumHost.admission.manage_block))) {
        throw 'medium-host window/process classification disagree'
    }
    if ([string]$mediumHost.admission.noted -ne 'HigherIntegrity') { throw 'medium-host/high-fixture must be HigherIntegrity' }
    if ([uint64]$mediumHost.admission.hwnd -ne [uint64]$fixture.hwnd) { throw 'medium-host admission hwnd mismatch' }
    if ([string]$mediumHost.admission.title -ne [string]$fixture.title) { throw 'medium-host admission title mismatch' }
    Assert-HealthDaemonRid $mediumClient.health $HighRid 'medium-client'
    Assert-HealthDaemonRid $highClient.health $MediumRid 'high-client'
    Assert-NoBlocked $mediumClient.health 'medium-client'
    Assert-HigherIntegrityBlock $highClient.health $fixture 'high-client'
    Assert-RenderedIntegrity ([string]$mediumClient.rendered.daemon) 'medium-client daemon' 'High'
    Assert-RenderedIntegrity ([string]$mediumClient.rendered.cli) 'medium-client cli' 'Medium'
    Assert-RenderedIntegrity ([string]$highClient.rendered.daemon) 'high-client daemon' 'Medium'
    Assert-RenderedIntegrity ([string]$highClient.rendered.cli) 'high-client cli' 'High'
    if ([string]$mediumClient.query_status.status -ne 'status_info') { throw 'medium-client QueryStatus missing' }
    if ([string]$highClient.query_status.status -ne 'status_info') { throw 'high-client QueryStatus missing' }
    if ([uint32]$mediumClient.connected_server_pid -ne [uint32]$highHost.pid) { throw 'medium-client server pid mismatch' }
    if ([uint32]$highClient.connected_server_pid -ne [uint32]$mediumHost.pid) { throw 'high-client server pid mismatch' }
}

function New-HostEnv {
    param([string]$RunDir, [string]$Scope, [string]$Prefix, [string]$OwnHwnd)
    return [ordered]@{
        LEOPARDWM_DIAGNOSTICS_VALIDATION     = '1'
        LEOPARDWM_DIAGNOSTICS_RUN_DIR        = $RunDir
        LEOPARDWM_DIAGNOSTICS_TIMEOUT_SECS   = '90'
        LEOPARDWM_PIPE_SCOPE                 = $Scope
        LEOPARDWM_DIAGNOSTICS_ROLE           = 'host'
        LEOPARDWM_DIAGNOSTICS_OWN_HWND       = $OwnHwnd
        LEOPARDWM_DIAGNOSTICS_EVIDENCE_PREFIX = $Prefix
    }
}

function New-ClientEnv {
    param([string]$RunDir, [string]$Prefix)
    return [ordered]@{
        LEOPARDWM_DIAGNOSTICS_VALIDATION     = '1'
        LEOPARDWM_DIAGNOSTICS_RUN_DIR        = $RunDir
        LEOPARDWM_DIAGNOSTICS_TIMEOUT_SECS   = '30'
        LEOPARDWM_DIAGNOSTICS_ROLE           = 'client'
        LEOPARDWM_DIAGNOSTICS_EVIDENCE_PREFIX = $Prefix
    }
}

function New-RunnerData {
    param(
        [string]$RunDir,
        [string]$StopPath,
        [string]$AuditPath,
        $Children
    )
    return [ordered]@{
        runDir     = $RunDir
        timeoutSec = 90
        stopPath   = $StopPath
        auditPath  = $AuditPath
        children   = @($Children)
    }
}

function Invoke-RunnerOrchestrationSelfTest([string]$Root) {
    $shell = (Get-Process -Id $PID).Path
    if ($shell -notmatch '\s') { throw "SelfTest requires the actual spaced pwsh path: $shell" }
    $runner = Join-Path $Root 'runner with spaces.ps1'
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools\diagnostics_validation_runner.ps1') -Destination $runner
    $selfOwned = New-Object System.Collections.Generic.List[object]
    $child = Join-Path $Root 'harmless child with spaces.ps1'
    @'
param([string]$Mode, [string]$Evidence, [string]$StopPath, [string]$HostEvidence)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'host') {
    @{ pid = $PID } | ConvertTo-Json | Set-Content -LiteralPath $Evidence -Encoding UTF8
    while (-not (Test-Path -LiteralPath $StopPath)) { Start-Sleep -Milliseconds 50 }
    exit 0
}
if ($Mode -eq 'client') {
    $fixtureHost = Get-Content -LiteralPath $HostEvidence -Raw | ConvertFrom-Json
    $alive = $null -ne (Get-Process -Id ([int]$fixtureHost.pid) -ErrorAction SilentlyContinue)
    @{ hostAlive = $alive } | ConvertTo-Json | Set-Content -LiteralPath $Evidence -Encoding UTF8
    exit 0
}
if ($Mode -eq 'fail') { exit 9 }
while ($true) { Start-Sleep -Milliseconds 50 }
'@ | Set-Content -LiteralPath $child -Encoding UTF8
    $stop = Join-Path $Root 'shared stop'
    $hostEvidence = Join-Path $Root 'host evidence.json'
    $mediumEvidence = Join-Path $Root 'medium evidence.json'
    $highEvidence = Join-Path $Root 'high evidence.json'
    $flag = Join-Path $Root 'high client.flag'
    $hostAudit = Join-Path $Root 'host runner audit.json'
    $mediumAudit = Join-Path $Root 'medium runner audit.json'
    $topologyOwned = New-Object System.Collections.Generic.List[object]
    $childSpec = {
        param([string]$Name, [string]$Mode, [string]$Evidence, [string]$Start = 'immediate')
        $spec = [ordered]@{
            name = $Name; exe = $shell; args = @('-NoProfile', '-File', $child, '-Mode', $Mode, '-Evidence', $Evidence, '-StopPath', $stop, '-HostEvidence', $hostEvidence)
            env = [ordered]@{}; start = $Start; stdout = (Join-Path $Root "$Name.out"); stderr = (Join-Path $Root "$Name.err")
        }
        if ($Start -eq 'flag') { $spec.flagPath = $flag }
        return $spec
    }
    $hostData = New-RunnerData -RunDir $Root -StopPath $stop -AuditPath $hostAudit -Children @(
        (& $childSpec 'host' 'host' $hostEvidence),
        (& $childSpec 'high-client' 'client' $highEvidence 'flag')
    )
    $hostData.timeoutSec = 15
    $hostDataPath = Join-Path $Root 'host runner data with spaces.json'
    Write-JsonAtomic $hostDataPath $hostData
    $hostRunner = Start-DiagRunner -Name 'selftest-host-runner' -Shell $shell -RunnerPath $runner -DataPath $hostDataPath -RunDir $Root -AuditPath $hostAudit -ExpectedChildren @('host', 'high-client') -Owned $topologyOwned
    $null = Wait-DiagJson -Path $hostEvidence -TimeoutSec 5 -Process $hostRunner

    $mediumData = New-RunnerData -RunDir $Root -StopPath $stop -AuditPath $mediumAudit -Children @(
        (& $childSpec 'medium-client' 'client' $mediumEvidence)
    )
    $mediumData.timeoutSec = 15
    $mediumDataPath = Join-Path $Root 'medium runner data with spaces.json'
    Write-JsonAtomic $mediumDataPath $mediumData
    $mediumRunner = Start-DiagRunner -Name 'selftest-medium-runner' -Shell $shell -RunnerPath $runner -DataPath $mediumDataPath -RunDir $Root -AuditPath $mediumAudit -ExpectedChildren @('medium-client') -Owned $topologyOwned
    $null = Wait-DiagJson -Path $mediumEvidence -TimeoutSec 5 -Process $mediumRunner
    if ((Stop-RetainedProcess -Record $mediumRunner -WaitMs 10000) -ne 0) { throw 'completed medium runner did not exit 0' }
    if (Test-Path -LiteralPath $stop) { throw 'completed medium runner wrote the shared stop file' }

    Write-JsonAtomic $flag ([ordered]@{ pipe = 'selftest'; expected_pid = 1; expected_creation = 1 })
    $high = Wait-DiagJson -Path $highEvidence -TimeoutSec 5 -Process $hostRunner
    if (-not [bool]$high.hostAlive) { throw 'completed medium runner stopped the host before high client ran' }
    Set-Content -LiteralPath $stop -Value 'stop'
    $topologyCleanupErrors = @(Stop-OwnedProcesses -Owned $topologyOwned -WaitMs 10000)
    if ($topologyCleanupErrors.Count -ne 0) { throw "zero-error coordinator cleanup failed: $($topologyCleanupErrors -join '; ')" }
    $topologyAuditErrors = @(Assert-OwnedRunnerAudits $topologyOwned)
    if ($topologyAuditErrors.Count -ne 0) { throw "successful runner audits failed: $($topologyAuditErrors -join '; ')" }
    foreach ($name in @('host', 'medium-client', 'high-client')) {
        $stderr = Join-Path $Root "$name.err"
        if ((Test-Path -LiteralPath $stderr) -and -not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $stderr -Raw))) {
            throw "$name child stderr was not empty"
        }
    }

    $fastArtifact = Join-Path $Root 'fast complete.json'
    Write-JsonAtomic $fastArtifact ([ordered]@{ complete = $true })
    $fast = Start-Process -FilePath $shell -ArgumentList (Join-ProcessArguments @('-NoProfile', '-Command', 'exit 0')) -PassThru -WindowStyle Hidden
    $fastRecord = New-DotNetProcessRecord -Name 'fast-exit' -Process $fast
    $fast.WaitForExit()
    $fastJson = Wait-DiagJson -Path $fastArtifact -TimeoutSec 5 -Process $fastRecord
    if (-not [bool]$fastJson.complete) { throw 'completed exit-0 artifact was not accepted' }
    $bad = Start-Process -FilePath $shell -ArgumentList (Join-ProcessArguments @('-NoProfile', '-Command', 'exit 7')) -PassThru -WindowStyle Hidden
    $badRecord = New-DotNetProcessRecord -Name 'nonzero-exit' -Process $bad
    $bad.WaitForExit()
    try {
        $null = Wait-DiagJson -Path $fastArtifact -TimeoutSec 5 -Process $badRecord
        throw 'nonzero child artifact was accepted'
    } catch {
        if ("$_" -notlike '*child exited 7 while waiting*') { throw }
    }

    $failureStop = Join-Path $Root 'failure stop'
    $failureAudit = Join-Path $Root 'failure audit.json'
    $failureData = New-RunnerData -RunDir $Root -StopPath $failureStop -AuditPath $failureAudit -Children @(
        (& $childSpec 'fails-first' 'fail' (Join-Path $Root 'fail evidence.json')),
        (& $childSpec 'cleaned-second' 'hang' (Join-Path $Root 'hang evidence.json'))
    )
    $failureData.timeoutSec = 5
    $failureDataPath = Join-Path $Root 'failure data.json'
    Write-JsonAtomic $failureDataPath $failureData
    $failure = Start-DiagRunner -Name 'selftest-failure-runner' -Shell $shell -RunnerPath $runner -DataPath $failureDataPath -RunDir $Root -AuditPath $failureAudit -ExpectedChildren @('fails-first', 'cleaned-second') -Owned $selfOwned
    if ((Stop-RetainedProcess -Record $failure -WaitMs 15000) -eq 0) { throw 'early nonzero child did not fail runner' }
    $failureEvidence = Read-JsonFile $failureAudit
    if (@($failureEvidence.children).Count -ne 2 -or @($failureEvidence.children | Where-Object { $_.name -eq 'cleaned-second' -and $_.exited }).Count -ne 1) { throw 'runner did not continue cleanup after first child failure' }
    if (Test-Path -LiteralPath $failureStop) { throw 'runner failure wrote the parent shared stop file' }

    $metadataStop = Join-Path $Root 'metadata failure stop'
    $metadataAudit = Join-Path $Root 'metadata failure audit.json'
    $metadataData = New-RunnerData -RunDir $Root -StopPath $metadataStop -AuditPath $metadataAudit -Children @(
        (& $childSpec 'metadata-child' 'hang' (Join-Path $Root 'metadata evidence.json'))
    )
    $metadataData.timeoutSec = 5
    $metadataData.testFailStartTimeFor = 'metadata-child'
    $metadataDataPath = Join-Path $Root 'metadata failure data.json'
    Write-JsonAtomic $metadataDataPath $metadataData
    $metadataFailure = Start-DiagRunner -Name 'selftest-metadata-failure-runner' -Shell $shell -RunnerPath $runner -DataPath $metadataDataPath -RunDir $Root -AuditPath $metadataAudit -ExpectedChildren @('metadata-child') -Owned $selfOwned
    if ((Stop-RetainedProcess -Record $metadataFailure -WaitMs 15000) -eq 0) { throw 'StartTime metadata failure did not fail runner' }
    $metadataEvidence = Read-JsonFile $metadataAudit
    if (@($metadataEvidence.children).Count -ne 1 -or -not [bool]$metadataEvidence.children[0].exited) { throw 'StartTime metadata failure lost its launched child cleanup record' }

    $parentMetadataOwned = New-Object System.Collections.Generic.List[object]
    $script:TestFailRunnerStartTimeFor = 'selftest-parent-metadata-failure'
    try {
        $null = Start-DiagRunner -Name 'selftest-parent-metadata-failure' -Shell $shell -RunnerPath $runner -DataPath $metadataDataPath -RunDir $Root -AuditPath $metadataAudit -ExpectedChildren @('metadata-child') -Owned $parentMetadataOwned
        throw 'injected parent StartTime failure was not raised'
    } catch {
        if ("$_" -notlike '*injected runner StartTime failure*') { throw }
    } finally {
        $script:TestFailRunnerStartTimeFor = $null
    }
    if ($parentMetadataOwned.Count -ne 1) { throw 'parent StartTime failure lost its retained wrapper handle' }
    $null = Stop-RetainedProcess -Record $parentMetadataOwned[0] -WaitMs 15000

    $timeoutStop = Join-Path $Root 'timeout stop'
    $timeoutAudit = Join-Path $Root 'timeout audit.json'
    $timeoutData = New-RunnerData -RunDir $Root -StopPath $timeoutStop -AuditPath $timeoutAudit -Children @(
        (& $childSpec 'timed-out-child' 'hang' (Join-Path $Root 'timeout evidence.json'))
    )
    $timeoutData.timeoutSec = 1
    $timeoutDataPath = Join-Path $Root 'timeout data.json'
    Write-JsonAtomic $timeoutDataPath $timeoutData
    $timeout = Start-DiagRunner -Name 'selftest-timeout-runner' -Shell $shell -RunnerPath $runner -DataPath $timeoutDataPath -RunDir $Root -AuditPath $timeoutAudit -ExpectedChildren @('timed-out-child') -Owned $selfOwned
    if ((Stop-RetainedProcess -Record $timeout -WaitMs 15000) -eq 0) { throw 'runner deadline did not fail a hung child' }
    $timeoutEvidence = Read-JsonFile $timeoutAudit
    if (@($timeoutEvidence.failures | Where-Object { $_ -eq 'runner deadline exceeded' }).Count -ne 1) { throw 'runner timeout evidence missing' }
    if (Test-Path -LiteralPath $timeoutStop) { throw 'runner timeout wrote the parent shared stop file' }

    $auditFailureStop = Join-Path $Root 'audit failure stop'
    $auditFailureData = New-RunnerData -RunDir $Root -StopPath $auditFailureStop -AuditPath (Join-Path $Root 'missing audit parent\audit.json') -Children @(
        (& $childSpec 'audit-child' 'client' (Join-Path $Root 'audit child.json'))
    )
    $auditFailureData.timeoutSec = 5
    $auditFailureDataPath = Join-Path $Root 'audit failure data.json'
    Write-JsonAtomic $auditFailureDataPath $auditFailureData
    $auditFailure = Start-DiagRunner -Name 'selftest-audit-failure-runner' -Shell $shell -RunnerPath $runner -DataPath $auditFailureDataPath -RunDir $Root -AuditPath $null -ExpectedChildren @() -Owned $selfOwned
    if ((Stop-RetainedProcess -Record $auditFailure -WaitMs 10000) -eq 0) { throw 'audit write failure did not fail runner' }
    if (Test-Path -LiteralPath $auditFailureStop) { throw 'audit failure wrote the parent shared stop file' }

    $auditCases = @(
        [pscustomobject]@{ Name = 'absent'; Path = (Join-Path $Root 'absent audit.json'); Text = $null; Pattern = '*audit missing*' },
        [pscustomobject]@{ Name = 'corrupt'; Path = (Join-Path $Root 'corrupt audit.json'); Text = '{broken'; Pattern = '*audit corrupt*' },
        [pscustomobject]@{ Name = 'nonzero'; Path = (Join-Path $Root 'nonzero audit.json'); Text = '{"exitCode":1,"failures":[],"expectedChildren":[],"children":[]}'; Pattern = '*audit exit 1*' }
    )
    foreach ($case in $auditCases) {
        if ($null -ne $case.Text) { Set-Content -LiteralPath $case.Path -Value $case.Text -Encoding UTF8 }
        try { Assert-RunnerAudit -Path $case.Path -ExpectedChildren @() -Label $case.Name; throw "$($case.Name) audit was accepted" } catch {
            if ("$_" -notlike $case.Pattern) { throw }
        }
    }
    $auditErrors = @(Assert-OwnedRunnerAudits @(
        [pscustomobject]@{ Name = 'missing-audit-runner'; AuditPath = $auditCases[0].Path; ExpectedChildren = @() },
        [pscustomobject]@{ Name = 'corrupt-audit-runner'; AuditPath = $auditCases[1].Path; ExpectedChildren = @() }
    ))
    if ($auditErrors.Count -ne 2 -or ($auditErrors -join '; ') -notlike '*missing-audit-runner*' -or ($auditErrors -join '; ') -notlike '*corrupt-audit-runner*') {
        throw 'all runner audit failures were not preserved'
    }
}

function Invoke-SelfTest {
    if (-not (Test-OptInEnabled $null) -and -not (Test-OptInEnabled '') -and -not (Test-OptInEnabled '0') -and -not (Test-OptInEnabled 'true') -and (Test-OptInEnabled '1')) {
        # fail-closed
    } else {
        throw 'opt-in fail-closed assertion failed'
    }
    $scope = New-DiagValScope
    $pipe = Get-DiagValPipe $scope
    if (-not (Test-IsolatedPipe $scope $pipe)) { throw 'unique scope was not isolated' }
    if (Test-IsolatedPipe '' $DailyDriverPipe) { throw 'empty scope must be refused' }
    if (Test-IsolatedPipe 'diagval' $DailyDriverPipe) { throw 'daily-driver pipe must be refused' }
    if (Test-ExactPipe '') { throw 'missing exact pipe must be refused' }
    if (Test-ExactPipe $DailyDriverPipe) { throw 'exact daily-driver pipe must be refused' }
    if (-not (Test-ExactPipe $pipe)) { throw 'unique exact pipe must be accepted' }
    if (Test-ExactPipe '\\.\pipe\leopardwm_acme_jose') { throw 'user production pipe must be refused' }
    if (Test-ExactPipe '\\.\pipe\foo_leopardwm_diagval_x') { throw 'substring diagval pipe must be refused' }
    if (Test-ExactPipe '\\server\pipe\leopardwm_diagval_x') { throw 'remote pipe must be refused' }
    if (Test-IsolatedPipe 'acme_jose' '\\.\pipe\leopardwm_acme_jose') { throw 'user-scoped pipe must be refused' }
    if (-not (Test-AllowedCommand 'HealthCheck')) { throw 'HealthCheck must be allowed' }
    if (-not (Test-AllowedCommand 'QueryStatus')) { throw 'QueryStatus must be allowed' }
    if (Test-AllowedCommand 'Stop') { throw 'Stop must be rejected' }
    if (Test-AllowedCommand 'PanicRevert') { throw 'PanicRevert must be rejected' }
    if (Test-AllowedCommand 'Subscribe') { throw 'Subscribe must be rejected' }
    $recorded = [pscustomobject]@{ Pid = 10; CreationFileTime = 99; Image = 'C:\tmp\host.exe' }
    $liveSame = [pscustomobject]@{ Pid = 10; CreationFileTime = 99; Image = 'C:\tmp\host.exe' }
    $liveReuse = [pscustomobject]@{ Pid = 10; CreationFileTime = 100; Image = 'C:\tmp\host.exe' }
    $liveMissingCreation = [pscustomobject]@{ Pid = 10; CreationFileTime = 0; Image = 'C:\tmp\host.exe' }
    if (-not (Test-ShouldStopProcess $recorded $liveSame)) { throw 'matching identity must be stoppable' }
    if (Test-ShouldStopProcess $recorded $liveReuse) { throw 'pid reuse must not be killed' }
    if (Test-ShouldStopProcess $recorded $null) { throw 'missing live process must not be killed' }
    if (Test-ShouldStopProcess $recorded $liveMissingCreation) { throw 'zero creation must not be killed' }
    if (Test-DeadlineExceeded 1 2) { throw 'deadline too early' }
    if (-not (Test-DeadlineExceeded 2 2)) { throw 'deadline inclusive' }
    $cancelled = Get-UacLaunchOutcome (New-Object System.ComponentModel.Win32Exception 1223)
    $failed = Get-UacLaunchOutcome (New-Object System.ComponentModel.Win32Exception 5)
    if ($cancelled -ne 'cancelled') { throw 'UAC 1223 must be cancelled' }
    if ($failed -ne 'failed') { throw 'non-1223 launch error must be failed, not cancelled' }
    if (-not (Test-UacCancelledIsTerminal $cancelled)) { throw 'UAC cancel must be terminal' }
    if (Test-UacCancelledIsTerminal $failed) { throw 'non-cancel failure is not terminal-cancel' }
    if ((Get-UacLaunchOutcome $null) -ne 'started') { throw 'null exception is started' }
    if ($null -ne (Get-LauncherRoute $null 0 0)) { throw 'missing launcher RID must block' }
    if ((Get-LauncherRoute $MediumRid 3 0) -ne 'medium-runas') { throw 'Medium launcher must use one RunAs high runner' }
    if ((Get-LauncherRoute $HighRid 2 $MediumRid) -ne 'high-linked-medium') { throw 'High launcher must use its own verified Medium linked token' }
    if ($null -ne (Get-LauncherRoute $HighRid 2 $HighRid)) { throw 'High launcher must refuse non-Medium linked token' }
    if ($null -ne (Get-LauncherRoute $HighRid 3 $MediumRid)) { throw 'non-Full High launcher must refuse linked-token launch' }
    if ($null -ne (Get-LauncherRoute 0x1000 1 0)) { throw 'Low launcher must block' }
    if ($null -ne (Get-DaemonIntegrityFromHealth $null)) { throw 'missing health must not invent a daemon RID' }
    $missingHealth = [pscustomobject]@{ status = 'ok' }
    if ($null -ne (Get-DaemonIntegrityFromHealth $missingHealth)) { throw 'non-health response must not invent a daemon RID' }
    if (Test-FixtureIdentityComplete $null) { throw 'null fixture must fail' }
    if (Test-FixtureIdentityComplete ([pscustomobject]@{ hwnd = 1; pid = 2; creation_filetime = 0; image = 'C:\x.exe' })) {
        throw 'zero creation fixture must fail'
    }
    if (-not (Test-ClassificationsAgree 'HigherIntegrity' 'HigherIntegrity')) { throw 'matching classifications must agree' }
    if (Test-ClassificationsAgree 'HigherIntegrity' 'No') { throw 'disagreeing classifications must fail' }
    try {
        Get-ExecutableFromCargoJson -Lines @('not json') -ExitCode 1 -Bin 'leopardwm'
        throw 'cargo nonzero exit must fail'
    } catch {
        if ("$_" -notlike '*cargo test --no-run failed: 1*') { throw "unexpected cargo exit error: $_" }
    }
    $artifact = '{"reason":"compiler-artifact","profile":{"test":true},"target":{"name":"leopardwm"},"executable":"C:\\tmp\\leopardwm.exe"}'
    $exe = Get-ExecutableFromCargoJson -Lines @('noise', $artifact) -ExitCode 0 -Bin 'leopardwm'
    if ($exe -ne 'C:\tmp\leopardwm.exe') { throw 'cargo artifact parse failed' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("diagval-selftest-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Write-JsonAtomic (Join-Path $tmp 'ready.json') ([pscustomobject]@{ ready = $true; pid = 7 })
        $ready = Wait-DiagJson -Path (Join-Path $tmp 'ready.json') -TimeoutSec 2 -Process $null
        if ([int]$ready.pid -ne 7) { throw 'atomic json wait failed' }
        try {
            Assert-HealthDaemonRid $null $HighRid 'missing'
            throw 'missing health matrix must fail'
        } catch {
            if ("$_" -notlike '*HealthInfo missing*') { throw "unexpected matrix error: $_" }
        }
        try { Stop-RetainedProcess -Record $null -WaitMs 10; throw 'null retained handle must fail' } catch {
            if ("$_" -notlike '*missing retained process handle*') { throw "unexpected stop error: $_" }
        }
        if (Test-WindowExists 0) { throw 'HWND 0 must not exist' }
        $runner = Join-Path $RepoRoot 'tools\diagnostics_validation_runner.ps1'
        if (-not (Test-Path -LiteralPath $runner)) { throw "bounded runner missing: $runner" }
        Invoke-RunnerOrchestrationSelfTest $tmp
        Write-Host "diagnostics_validation SelfTest ok; evidence left at $tmp"
    } catch {
        Write-Host "diagnostics_validation SelfTest evidence left at $tmp"
        throw
    }
}

function Invoke-NativeValidation {
    Write-Host 'NATIVE VALIDATION IS PARENT-OWNED AFTER SAFETY INSPECTION.'
    Write-Host $Gap
    $savedEnv = Save-ProcessEnv $LeopardWmEnvNames
    $runDir = Join-Path ([IO.Path]::GetTempPath()) ("leopardwm-diagval-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir | Out-Null
    Write-Host "evidence dir: $runDir"
    $owned = New-Object System.Collections.Generic.List[object]
    $nativeError = $null
    try {
        $launcher = Get-CurrentTokenInfo
        $launcherRid = if ($null -eq $launcher) { $null } else { $launcher.Rid }
        $launcherElevationType = if ($null -eq $launcher) { 0 } else { $launcher.ElevationType }
        $linkedRid = $null
        if ($launcherRid -eq $HighRid -and $launcherElevationType -eq 2) {
            $linked = Get-OwnLinkedMediumToken
            try { $linkedRid = Get-TokenIntegrityRid $linked } finally { [void][DiagValToken]::CloseHandle($linked) }
        }
        $route = Get-LauncherRoute $launcherRid $launcherElevationType $linkedRid
        Write-JsonAtomic (Join-Path $runDir 'launcher.json') ([pscustomobject]@{
            oracle_integrity_rid = $launcherRid
            elevation_type       = $launcherElevationType
            linked_integrity_rid = $linkedRid
            route                = $route
            gap                  = $Gap
        })
        if ($null -eq $route) {
            throw "launcher token is neither Medium nor a Full High token with its own verified Medium linked token"
        }

        $scopeHigh = New-DiagValScope
        $scopeMedium = New-DiagValScope
        $pipeHigh = Get-DiagValPipe $scopeHigh
        $pipeMedium = Get-DiagValPipe $scopeMedium
        if (-not (Test-IsolatedPipe $scopeHigh $pipeHigh) -or -not (Test-IsolatedPipe $scopeMedium $pipeMedium)) {
            throw 'generated pipe was not isolated'
        }

        $daemonSrc = Get-TestExecutable -Package 'leopardwm-daemon' -Bin 'leopardwm' -RepoRoot $RepoRoot -LogPath (Join-Path $runDir 'cargo-daemon.json')
        $cliSrc = Get-TestExecutable -Package 'leopardwm-cli' -Bin 'leopardwm-cli' -RepoRoot $RepoRoot -LogPath (Join-Path $runDir 'cargo-cli.json')
        $daemonExe = Join-Path $runDir 'daemon-test.exe'
        $cliExe = Join-Path $runDir 'cli-test.exe'
        Copy-Item -LiteralPath $daemonSrc -Destination $daemonExe
        Copy-Item -LiteralPath $cliSrc -Destination $cliExe

        $testArgs = @(
            '--ignored',
            '--exact',
            'diagnostics_validation::diagnostics_validation_native',
            '--test-threads=1',
            '--nocapture'
        )
        $runnerPath = Join-Path $RepoRoot 'tools\diagnostics_validation_runner.ps1'
        $shell = (Get-Process -Id $PID).Path
        $stopPath = Join-Path $runDir 'stop'

        $elevatedDataPath = Join-Path $runDir 'elevated-data.json'
        Write-JsonAtomic $elevatedDataPath (New-RunnerData -RunDir $runDir -StopPath $stopPath -AuditPath (Join-Path $runDir 'elevated-audit.json') -Children @(
            [ordered]@{
                name   = 'high-host'
                exe    = $daemonExe
                args   = $testArgs
                env    = New-HostEnv -RunDir $runDir -Scope $scopeHigh -Prefix 'high-host' -OwnHwnd '1'
                start  = 'immediate'
                stdout = Join-Path $runDir 'high-host.out'
                stderr = Join-Path $runDir 'high-host.err'
            },
            [ordered]@{
                name     = 'high-client'
                exe      = $cliExe
                args     = $testArgs
                env      = New-ClientEnv -RunDir $runDir -Prefix 'high-client'
                start    = 'flag'
                flagPath = Join-Path $runDir 'run-high-client.flag'
                stdout   = Join-Path $runDir 'high-client.out'
                stderr   = Join-Path $runDir 'high-client.err'
            }
        ))

        $highAudit = Join-Path $runDir 'elevated-audit.json'
        $highRunner = $null
        if ($route -eq 'medium-runas') {
            try {
                $highRunner = Start-DiagRunner -Name 'high-runner' -Shell $shell -RunnerPath $runnerPath -DataPath $elevatedDataPath -RunDir $runDir -AuditPath $highAudit -ExpectedChildren @('high-host', 'high-client') -Owned $owned -Elevated
            } catch {
                $outcome = Get-UacLaunchOutcome $_.Exception
                Write-JsonAtomic (Join-Path $runDir 'uac.json') ([pscustomobject]@{ outcome = $outcome; terminal = [bool](Test-UacCancelledIsTerminal $outcome); native = Get-Win32NativeErrorCode $_.Exception; gap = $Gap })
                if ($outcome -eq 'cancelled') { throw 'UAC cancelled; not retrying' }
                throw "UAC launch failed; not retrying: $_"
            }
        } else {
            $highRunner = Start-DiagRunner -Name 'high-runner' -Shell $shell -RunnerPath $runnerPath -DataPath $elevatedDataPath -RunDir $runDir -AuditPath $highAudit -ExpectedChildren @('high-host', 'high-client') -Owned $owned
        }
        Write-JsonAtomic (Join-Path $runDir 'high-wrapper.json') ([pscustomobject]@{ pid = $highRunner.Pid; creation_filetime = $highRunner.CreationFileTime; image = $shell; route = $route })

        $null = Wait-DiagJson -Path (Join-Path $runDir 'fixture.json') -TimeoutSec 60 -Process $highRunner
        $highHost = Wait-DiagJson -Path (Join-Path $runDir 'high-host.json') -TimeoutSec 60 -Process $highRunner
        $null = Wait-DiagJson -Path (Join-Path $runDir 'high-host-ready.json') -TimeoutSec 30 -Process $highRunner

        $mediumDataPath = Join-Path $runDir 'medium-host-data.json'
        Write-JsonAtomic $mediumDataPath (New-RunnerData -RunDir $runDir -StopPath $stopPath -AuditPath (Join-Path $runDir 'medium-host-audit.json') -Children @(
            [ordered]@{
                name   = 'medium-host'
                exe    = $daemonExe
                args   = $testArgs
                env    = New-HostEnv -RunDir $runDir -Scope $scopeMedium -Prefix 'medium-host' -OwnHwnd '0'
                start  = 'immediate'
                stdout = Join-Path $runDir 'medium-host.out'
                stderr = Join-Path $runDir 'medium-host.err'
            }
        ))
        $mediumHostAudit = Join-Path $runDir 'medium-host-audit.json'
        if ($route -eq 'high-linked-medium') {
            $mediumHostRunner = Start-LinkedTokenDiagRunner -Name 'medium-host-runner' -Shell $shell -RunnerPath $runnerPath -DataPath $mediumDataPath -RunDir $runDir -AuditPath $mediumHostAudit -ExpectedChildren @('medium-host') -Owned $owned
        } else {
            $mediumHostRunner = Start-DiagRunner -Name 'medium-host-runner' -Shell $shell -RunnerPath $runnerPath -DataPath $mediumDataPath -RunDir $runDir -AuditPath $mediumHostAudit -ExpectedChildren @('medium-host') -Owned $owned
        }
        $mediumHost = Wait-DiagJson -Path (Join-Path $runDir 'medium-host.json') -TimeoutSec 60 -Process $mediumHostRunner

        $mediumClientDataPath = Join-Path $runDir 'medium-client-data.json'
        $mediumClientEnv = New-ClientEnv -RunDir $runDir -Prefix 'medium-client'
        $mediumClientEnv['LEOPARDWM_DIAGNOSTICS_PIPE'] = $pipeHigh
        $mediumClientEnv['LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_PID'] = [string]$highHost.pid
        $mediumClientEnv['LEOPARDWM_DIAGNOSTICS_EXPECTED_SERVER_CREATION'] = [string]$highHost.creation_filetime
        Write-JsonAtomic $mediumClientDataPath (New-RunnerData -RunDir $runDir -StopPath $stopPath -AuditPath (Join-Path $runDir 'medium-client-audit.json') -Children @(
            [ordered]@{
                name   = 'medium-client'
                exe    = $cliExe
                args   = $testArgs
                env    = $mediumClientEnv
                start  = 'immediate'
                stdout = Join-Path $runDir 'medium-client.out'
                stderr = Join-Path $runDir 'medium-client.err'
            }
        ))
        $mediumClientAudit = Join-Path $runDir 'medium-client-audit.json'
        if ($route -eq 'high-linked-medium') {
            $mediumClientRunner = Start-LinkedTokenDiagRunner -Name 'medium-client-runner' -Shell $shell -RunnerPath $runnerPath -DataPath $mediumClientDataPath -RunDir $runDir -AuditPath $mediumClientAudit -ExpectedChildren @('medium-client') -Owned $owned
        } else {
            $mediumClientRunner = Start-DiagRunner -Name 'medium-client-runner' -Shell $shell -RunnerPath $runnerPath -DataPath $mediumClientDataPath -RunDir $runDir -AuditPath $mediumClientAudit -ExpectedChildren @('medium-client') -Owned $owned
        }
        $null = Wait-DiagJson -Path (Join-Path $runDir 'medium-client.json') -TimeoutSec 30 -Process $mediumClientRunner

        Write-JsonAtomic (Join-Path $runDir 'run-high-client.flag') ([pscustomobject]@{
            pipe               = $pipeMedium
            expected_pid       = $mediumHost.pid
            expected_creation  = $mediumHost.creation_filetime
        })
        $null = Wait-DiagJson -Path (Join-Path $runDir 'high-client.json') -TimeoutSec 60 -Process $highRunner

        Assert-NativeMatrix -RunDir $runDir
        $fixture = Read-JsonFile (Join-Path $runDir 'fixture.json')
        Set-Content -LiteralPath $stopPath -Value 'stop'
        $successCleanupErrors = @(Stop-OwnedProcesses -Owned $owned -WaitMs 25000)
        if ($successCleanupErrors.Count -ne 0) { throw ($successCleanupErrors -join '; ') }
        $successAuditErrors = @(Assert-OwnedRunnerAudits $owned)
        if ($successAuditErrors.Count -ne 0) { throw ($successAuditErrors -join '; ') }
        if (Test-WindowExists ([uint64]$fixture.hwnd)) { throw 'fixture HWND still exists after stop' }
        Write-Host "native pipeline passed; evidence left at $runDir"
    } catch {
        $nativeError = $_
    } finally {
        $cleanupErrors = New-Object System.Collections.Generic.List[string]
        try {
            if (-not (Test-Path -LiteralPath (Join-Path $runDir 'stop'))) { Set-Content -LiteralPath (Join-Path $runDir 'stop') -Value 'stop' }
        } catch {
            $cleanupErrors.Add("shared stop: $_") | Out-Null
        }
        foreach ($error in @(Stop-OwnedProcesses -Owned $owned -WaitMs 25000)) { $cleanupErrors.Add($error) | Out-Null }
        foreach ($error in @(Assert-OwnedRunnerAudits $owned)) { $cleanupErrors.Add("audit: $error") | Out-Null }
        foreach ($record in $owned) {
            try { Close-RetainedProcessHandle $record } catch { $cleanupErrors.Add("close $($record.Name): $_") | Out-Null }
        }
        try { Restore-ProcessEnv $savedEnv } catch { $cleanupErrors.Add("restore environment: $_") | Out-Null }
        if ($null -ne $nativeError -and $cleanupErrors.Count -ne 0) { throw "native validation failed: $nativeError; cleanup also failed: $($cleanupErrors -join '; ')" }
        if ($null -ne $nativeError) { throw $nativeError }
        if ($cleanupErrors.Count -ne 0) { throw "native validation cleanup failed: $($cleanupErrors -join '; ')" }
    }
}

if ($SyntaxOnly) {
    Write-Host 'diagnostics_validation.ps1 parsed'
    exit 0
}

if ($RunNative) {
    Invoke-NativeValidation
    exit 0
}

Invoke-SelfTest
