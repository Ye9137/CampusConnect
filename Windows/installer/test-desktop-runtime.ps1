param([Parameter(Mandatory=$true)][string]$RuntimeInstaller)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install-desktop-runtime.ps1')
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('CampusConnect runtime tests ' + [guid]::NewGuid().ToString('N'))
$script:roots = @{x64 = (Join-Path $sandbox 'x64'); arm64 = (Join-Path $sandbox 'arm64')}
function Get-DesktopRuntimeRoots([string]$Architecture) { $script:roots[$Architecture] }
function Add-Runtime([string]$Version, [string]$Arch = 'x64', [switch]$NoCore) {
    $desktop = Join-Path $script:roots[$Arch] "shared\Microsoft.WindowsDesktop.App\$Version"
    New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $desktop 'System.Windows.Forms.dll') 'fixture'
    if (-not $NoCore) {
        $core = Join-Path $script:roots[$Arch] "shared\Microsoft.NETCore.App\$Version"
        New-Item -ItemType Directory -Path $core -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $core 'coreclr.dll') 'fixture'
    }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Fails([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert $failed 'Expected failure was accepted.'
}
$script:starts = 0
$script:exitCode = 0
$script:installFiles = $true
$script:cancel = $false
function Start-DesktopRuntimeInstaller([string]$Path, [switch]$Silent) {
    $script:starts++
    if ($script:cancel) { throw (New-Object ComponentModel.Win32Exception 1223) }
    if ($script:installFiles) { Add-Runtime '10.0.14' }
    return $script:exitCode
}
try {
    $minimum = [version]'10.0.14'
    Assert (-not (Test-DesktopRuntime 'x64' $minimum)) 'Missing runtime was accepted.'
    foreach ($version in @('8.0.30', '9.0.20', '11.0.0', '10.0.14-preview.1', '10.0.13')) { Add-Runtime $version }
    Assert (-not (Test-DesktopRuntime 'x64' $minimum)) 'An incompatible major, preview or old patch was accepted.'
    Add-Runtime '10.0.14' -Arch arm64
    Assert (-not (Test-DesktopRuntime 'x64' $minimum)) 'Wrong architecture was accepted.'
    Add-Runtime '10.0.14' -NoCore
    Assert (-not (Test-DesktopRuntime 'x64' $minimum)) 'Desktop-only partial installation was accepted.'
    Add-Runtime '10.0.14'
    Assert (Test-DesktopRuntime 'x64' $minimum) 'Compatible runtime was not detected.'
    Assert ((Install-DesktopRuntime 'x64' 'not-needed.exe') -eq 0) 'Installed runtime did not skip.'
    Assert ($script:starts -eq 0) 'Compatible installation was run again.'
    Add-Runtime '10.0.15'
    Remove-Item -LiteralPath (Join-Path $script:roots.x64 'shared\Microsoft.WindowsDesktop.App\10.0.14') -Recurse -Force
    Assert (Test-DesktopRuntime 'x64' $minimum) 'A newer compatible patch was not detected.'
    Remove-Item -LiteralPath $script:roots.x64 -Recurse -Force
    Assert ((Install-DesktopRuntime 'x64' $RuntimeInstaller -Silent) -eq 0) 'Missing runtime installation failed.'
    Assert ($script:starts -eq 1) 'Missing runtime did not invoke the installer exactly once.'
    Remove-Item -LiteralPath $script:roots.x64 -Recurse -Force
    $script:exitCode = 3010
    Assert ((Install-DesktopRuntime 'x64' $RuntimeInstaller -Silent) -eq 3010) 'Reboot-required result was lost.'
    Remove-Item -LiteralPath $script:roots.x64 -Recurse -Force
    $script:exitCode = 1603
    $script:installFiles = $false
    Assert-Fails { Install-DesktopRuntime 'x64' $RuntimeInstaller -Silent }
    $script:exitCode = 0
    Assert-Fails { Install-DesktopRuntime 'x64' $RuntimeInstaller -Silent }
    $script:cancel = $true
    Assert-Fails { Install-DesktopRuntime 'x64' $RuntimeInstaller -Silent }
    $tampered = Join-Path $sandbox 'tampered.exe'
    Set-Content -LiteralPath $tampered 'MZ tampered'
    $before = $script:starts
    Assert-Fails { Install-DesktopRuntime 'x64' $tampered -Silent }
    Assert ($before -eq $script:starts) 'Tampered installer was executed.'
    Write-Host 'PASS: missing/old/newer/preview/wrong-architecture/partial runtimes, skip, install, reboot, failure, cancellation, and tampering.'
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
