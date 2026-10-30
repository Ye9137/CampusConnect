# Only run on a disposable CI machine: remove the machine Desktop 10.0 runtime
# so the real generated setup must deploy its bundled prerequisite.
param([Parameter(Mandatory=$true)][string]$Installer)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'This destructive prerequisite test is restricted to disposable Windows CI runners.'
}
$Installer = (Resolve-Path $Installer).Path
. (Join-Path $PSScriptRoot 'install-desktop-runtime.ps1')
$metadata = Get-Content (Join-Path $PSScriptRoot 'desktop-runtime.json') -Raw | ConvertFrom-Json
$minimum = [version]$metadata.version
$roots = @(Get-DesktopRuntimeRoots 'x64' | Select-Object -Unique)
foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    foreach ($entry in @(Get-ItemProperty $key -ErrorAction SilentlyContinue)) {
        if ($entry.DisplayName -notmatch '^Microsoft Windows Desktop Runtime - 10\.0\.\d+ \(x64\)$') { continue }
        if ($entry.QuietUninstallString -notmatch '^"([^"]+\.exe)"\s+(.*)$') {
            throw "Cannot silently remove Desktop Runtime: $($entry.DisplayName)"
        }
        $path = $Matches[1]
        $arguments = $Matches[2] + ' /norestart'
        $process = Start-Process $path -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010)) { throw 'Desktop Runtime removal failed.' }
    }
}
# Hosted images also install SDK/runtime ZIPs without uninstall registration.
foreach ($root in $roots) {
    $directory = Join-Path $root 'shared\Microsoft.WindowsDesktop.App'
    foreach ($folder in @(Get-ChildItem $directory -Directory -ErrorAction SilentlyContinue)) {
        if ($folder.Name -match '^10\.0\.\d+$') { Remove-Item $folder.FullName -Recurse -Force }
    }
}
if (Test-DesktopRuntime 'x64' $minimum) { throw 'Clean-machine prerequisite was not established.' }
Write-Host 'CONFIRMED: no compatible .NET Desktop 10.0 runtime is available before setup.'
$target = Join-Path ([IO.Path]::GetTempPath()) ('CampusConnect clean runtime ' + [guid]::NewGuid().ToString('N'))
try {
    # WebView2 is already installed on the runner. No runtime download is needed.
    $process = Start-Process $Installer -ArgumentList "/S /SKIPWEBVIEW2 /D=$target" -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "Clean-machine setup failed: $($process.ExitCode)" }
    if (-not (Test-DesktopRuntime 'x64' $minimum)) { throw 'Bundled Desktop Runtime was not installed.' }
    $report = Join-Path $target 'runtime-ui-report.json'
    $app = Start-Process (Join-Path $target 'CampusConnect.exe') -ArgumentList ('--verify-ui "' + $report + '"') -PassThru
    if (-not $app.WaitForExit(60000)) { $app.Kill(); throw 'Newly installed app did not start.' }
    if (-not (Test-Path $report)) { throw 'App startup did not produce a native UI report.' }
    $ui = Get-Content $report -Raw | ConvertFrom-Json
    if ($ui.pageCount -ne 3) { throw 'Native application UI did not initialize.' }
    $uninstaller = Join-Path $target 'Uninstall.exe'
    $process = Start-Process $uninstaller -ArgumentList "/S _?=$target" -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw 'Clean-machine app uninstall failed.' }
    if (-not (Test-DesktopRuntime 'x64' $minimum)) { throw 'App uninstall removed the shared Desktop Runtime.' }
    Write-Host 'PASS: real missing-runtime setup, official offline installation, native app startup, and shared runtime preserved after uninstall.'
} finally {
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
}
