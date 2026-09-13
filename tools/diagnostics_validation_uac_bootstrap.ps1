# Inspected UAC bootstrap for the High diagnostics side. Its invoking encoded command
# pins this exact instance's SHA-256. Hashes establish byte identity and transfer
# integrity for deliberately user-consented, locally built Medium artifacts; they do
# not establish independent provenance or safety.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace([string]$FrozenSpecPath) -or [string]::IsNullOrWhiteSpace([string]$FrozenSpecHash)) {
    throw 'UAC bootstrap requires FrozenSpecPath and FrozenSpecHash from its pinned instance'
}

function Get-PinSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') } finally { $sha.Dispose() }
}
function Assert-Fresh([string]$Path) { if ([string]::IsNullOrWhiteSpace($Path) -or (Test-Path -LiteralPath $Path)) { throw "protected destination is not fresh: $Path" } }

if (-not ('DiagValPin' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DiagValPin {
 [StructLayout(LayoutKind.Sequential)] public struct SA { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }
 [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string s,uint r,out IntPtr d,out uint n);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateDirectoryW(string p,ref SA a);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string p,uint a,uint s,ref SA x,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern uint GetFileAttributesW(string p);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr p);
 static string Sddl(string sid) { return "D:(A;;FA;;;"+sid+")(A;OICI;FA;;;"+sid+")(A;;FA;;;SY)(A;OICI;FA;;;SY)(A;;FA;;;BA)(A;OICI;FA;;;BA)S:(ML;OICI;NW;;;HI)"; }
 static int Descriptor(string sid,out IntPtr d) { uint n; if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(Sddl(sid),1,out d,out n)) return Marshal.GetLastWin32Error(); return 0; }
 public static int Directory(string p,string sid) { IntPtr d; int e=Descriptor(sid,out d); if(e!=0)return e; try { SA a=new SA { nLength=Marshal.SizeOf(typeof(SA)),lpSecurityDescriptor=d,bInheritHandle=false}; return CreateDirectoryW(p,ref a)?0:Marshal.GetLastWin32Error(); } finally { LocalFree(d); } }
 public static int File(string p,string sid) { IntPtr d; int e=Descriptor(sid,out d); if(e!=0)return e; try { SA a=new SA { nLength=Marshal.SizeOf(typeof(SA)),lpSecurityDescriptor=d,bInheritHandle=false}; IntPtr h=CreateFileW(p,0x40000000,0,ref a,1,0x80,IntPtr.Zero); if(h==new IntPtr(-1))return Marshal.GetLastWin32Error(); CloseHandle(h);return 0; } finally { LocalFree(d); } }
}
'@
}
function Assert-NotReparse([string]$Path) { $attributes = [DiagValPin]::GetFileAttributesW($Path); if ($attributes -eq [uint32]::MaxValue -or ($attributes -band 0x400) -ne 0) { throw "refusing reparse or unreadable path: $Path" } }
function New-HighDirectory([string]$Path, [string]$Sid) { Assert-Fresh $Path; $error = [DiagValPin]::Directory($Path, $Sid); if ($error -ne 0) { throw "could not create High-protected directory ${Path}: $error" }; Assert-NotReparse $Path }
function Test-DescendantPath([string]$Parent, [string]$Candidate) {
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $candidatePath = [IO.Path]::GetFullPath($Candidate)
    return $candidatePath.StartsWith($parentPath + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Write-PinnedBytes([string]$Destination, [byte[]]$PinnedBytes, [string]$ExpectedHash) {
    [IO.File]::WriteAllBytes($Destination, $PinnedBytes)
    if ((Get-PinSha256 ([IO.File]::ReadAllBytes($Destination))) -cne $ExpectedHash) {
        throw "protected copy hash mismatch: $Destination"
    }
}
function Copy-Pinned([string]$Source, [string]$Destination, [string]$ExpectedHash, [string]$Sid) {
    Assert-Fresh $Destination
    $pinnedBytes = [IO.File]::ReadAllBytes($Source)
    if ((Get-PinSha256 $pinnedBytes) -cne $ExpectedHash) { throw "source hash mismatch: $Source" }
    $error = [DiagValPin]::File($Destination, $Sid)
    if ($error -ne 0) { throw "could not create High-protected file ${Destination}: $error" }
    Assert-NotReparse $Destination
    Write-PinnedBytes -Destination $Destination -PinnedBytes $pinnedBytes -ExpectedHash $ExpectedHash
}
function Invoke-BootstrapSelfTest {
    $parent = Join-Path ([IO.Path]::GetTempPath()) 'leopardwm-diagval-owned-high'
    if (-not (Test-DescendantPath $parent (Join-Path $parent 'output'))) { throw 'descendant path was rejected' }
    if (Test-DescendantPath $parent (Join-Path ([IO.Path]::GetTempPath()) 'leopardwm-diagval-owned-high-sibling\output')) { throw 'sibling path was accepted' }
    if (Test-DescendantPath $parent (Join-Path $parent '..\escape')) { throw 'path escape was accepted' }
    $destination = Join-Path ([IO.Path]::GetTempPath()) ("leopardwm-diagval-pinned-bytes-" + [guid]::NewGuid().ToString('N'))
    $bytes = [byte[]]@(0, 65, 255)
    $hash = Get-PinSha256 $bytes
    try {
        Write-PinnedBytes -Destination $destination -PinnedBytes $bytes -ExpectedHash $hash
        if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals([IO.File]::ReadAllBytes($destination), $bytes)) { throw 'pinned bytes did not round-trip' }
        try { Write-PinnedBytes -Destination $destination -PinnedBytes $bytes -ExpectedHash ('0' * 64); throw 'wrong pinned hash was accepted' } catch { if ("$_" -notlike '*protected copy hash mismatch*') { throw } }
    } finally { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
    Write-Host 'diagnostics_validation_uac_bootstrap SelfTest ok'
}

if ((Get-Variable -Name BootstrapTestOnly -ValueOnly -ErrorAction SilentlyContinue) -eq $true) {
    Invoke-BootstrapSelfTest
    return
}

$specBytes = [IO.File]::ReadAllBytes($FrozenSpecPath)
if ((Get-PinSha256 $specBytes) -cne $FrozenSpecHash) { throw 'pinned spec hash mismatch' }
$specText = [Text.Encoding]::UTF8.GetString($specBytes).TrimStart([char]0xFEFF)
$spec = $specText | ConvertFrom-Json
$required = @('version', 'high_exec_dir', 'high_output_dir', 'dependencies', 'main', 'runner', 'daemon', 'cli', 'runner_data')
foreach ($name in $required) { if ($spec.PSObject.Properties.Name -notcontains $name -or $null -eq $spec.$name) { throw "pin spec missing $name" } }
if ([int]$spec.version -ne 1) { throw "unsupported pin spec version $($spec.version)" }
foreach ($artifact in @($spec.main, $spec.runner, $spec.daemon, $spec.cli, $spec.runner_data)) {
    if ([string]::IsNullOrWhiteSpace([string]$artifact.source) -or [string]::IsNullOrWhiteSpace([string]$artifact.sha256)) { throw 'pin spec artifact source/hash missing' }
}
$dependencyNames = @{}
foreach ($dependency in @($spec.dependencies)) {
    if ([string]::IsNullOrWhiteSpace([string]$dependency.source) -or [string]::IsNullOrWhiteSpace([string]$dependency.destination) -or [string]::IsNullOrWhiteSpace([string]$dependency.sha256) -or [IO.Path]::GetFileName([string]$dependency.destination) -cne [string]$dependency.destination -or $dependencyNames.ContainsKey([string]$dependency.destination)) { throw 'pin spec dependency is invalid' }
    $dependencyNames[[string]$dependency.destination] = $true
}
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
if ($null -eq $sid) { throw 'current token user SID is unavailable' }
$execution = [IO.Path]::GetFullPath([string]$spec.high_exec_dir)
$output = [IO.Path]::GetFullPath([string]$spec.high_output_dir)
if (-not (Test-DescendantPath $execution $output)) { throw 'High output must be a fresh child of the protected execution directory' }
New-HighDirectory $execution $sid.Value
Copy-Pinned $FrozenSpecPath (Join-Path $execution 'pinned-spec.json') $FrozenSpecHash $sid.Value
Copy-Pinned ([string]$spec.main.source) (Join-Path $execution 'diagnostics_validation.ps1') ([string]$spec.main.sha256) $sid.Value
Copy-Pinned ([string]$spec.runner.source) (Join-Path $execution 'diagnostics_validation_runner.ps1') ([string]$spec.runner.sha256) $sid.Value
Copy-Pinned ([string]$spec.daemon.source) (Join-Path $execution 'daemon-test.exe') ([string]$spec.daemon.sha256) $sid.Value
Copy-Pinned ([string]$spec.cli.source) (Join-Path $execution 'cli-test.exe') ([string]$spec.cli.sha256) $sid.Value
Copy-Pinned ([string]$spec.runner_data.source) (Join-Path $execution 'high-runner-data.json') ([string]$spec.runner_data.sha256) $sid.Value
foreach ($dependency in @($spec.dependencies)) { Copy-Pinned ([string]$dependency.source) (Join-Path $execution ([string]$dependency.destination)) ([string]$dependency.sha256) $sid.Value }
New-HighDirectory $output $sid.Value
& (Join-Path $execution 'diagnostics_validation.ps1') -HighSide -PinnedSpecPath (Join-Path $execution 'pinned-spec.json')
exit $LASTEXITCODE
