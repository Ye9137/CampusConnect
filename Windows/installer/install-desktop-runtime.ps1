param(
    [ValidateSet('x64', 'arm64')][string]$RuntimeArch = 'x64',
    [string]$InstallerPath = (Join-Path $PSScriptRoot 'windowsdesktop-runtime.exe'),
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

function Get-DesktopRuntimeRoots([string]$Architecture) {
    # Use explicit registry views: the setup executable itself is 32 bit.
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            $key = $base.OpenSubKey("SOFTWARE\dotnet\Setup\InstalledVersions\$Architecture")
            if ($null -ne $key) {
                try {
                    $location = [string]$key.GetValue('InstallLocation', '')
                    if ($location) { $location }
                } finally { $key.Dispose() }
            }
        } finally { $base.Dispose() }
    }
    # SDK/zip deployments may have no registry entry. Use the architecture-specific
    # machine location too; PATH and DOTNET_ROOT could name a different runtime.
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if ($env:ProgramW6432) { $programFiles = $env:ProgramW6432 }
    if ($Architecture -eq 'x64' -and $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        Join-Path $programFiles 'dotnet\x64'
    } else {
        Join-Path $programFiles 'dotnet'
    }
}

function Test-DesktopRuntime([string]$Architecture, [version]$Minimum) {
    foreach ($root in @(Get-DesktopRuntimeRoots $Architecture | Select-Object -Unique)) {
        $directory = Join-Path $root 'shared\Microsoft.WindowsDesktop.App'
        foreach ($folder in @(Get-ChildItem -LiteralPath $directory -Directory -ErrorAction SilentlyContinue)) {
            $version = $null
            if (-not [version]::TryParse($folder.Name, [ref]$version)) { continue }
            # .NET major/minor versions do not replace the requested 10.0 runtime.
            if ($version.Major -eq $Minimum.Major -and $version.Minor -eq $Minimum.Minor -and $version -ge $Minimum -and
                (Test-Path -LiteralPath (Join-Path $folder.FullName 'System.Windows.Forms.dll')) -and
                (Test-Path -LiteralPath (Join-Path $root "shared\Microsoft.NETCore.App\$version\coreclr.dll"))) {
                return $true
            }
        }
    }
    return $false
}

function Start-DesktopRuntimeInstaller([string]$Path, [switch]$Silent) {
    $mode = if ($Silent) { '/quiet' } else { '/passive' }
    # Microsoft's signed bootstrapper requests UAC only for its machine components;
    # CampusConnect itself stays installed for the original, unelevated user.
    $process = Start-Process -FilePath $Path -ArgumentList '/install', $mode, '/norestart' -Wait -PassThru
    return $process.ExitCode
}

function Install-DesktopRuntime([string]$Architecture, [string]$Path, [switch]$Silent) {
    $metadata = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'desktop-runtime.json') -Raw | ConvertFrom-Json
    $minimum = [version]$metadata.version
    if (Test-DesktopRuntime $Architecture $minimum) {
        Write-Host "Compatible .NET Desktop Runtime $minimum or later is installed; skipping."
        return 0
    }
    $expected = $metadata.files."win-$Architecture".sha512
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA512).Hash -ne $expected) {
        throw 'Bundled Microsoft Desktop Runtime SHA512 verification failed.'
    }
    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw 'Microsoft Desktop Runtime signature verification failed.'
    }
    Write-Host "Installing bundled .NET Desktop Runtime $minimum ($Architecture), without downloading."
    $result = Start-DesktopRuntimeInstaller $Path -Silent:$Silent
    if ($result -notin @(0, 3010, 1641) -or -not (Test-DesktopRuntime $Architecture $minimum)) {
        throw "Desktop Runtime installation failed or was cancelled (exit $result)."
    }
    if ($result -in @(3010, 1641)) { return 3010 }
    return 0
}

# Dot sourcing exposes the functions to the prerequisite regression tests.
if ($MyInvocation.InvocationName -ne '.') {
    try { exit (Install-DesktopRuntime $RuntimeArch $InstallerPath -Silent:$Quiet) }
    catch {
        Write-Host $_.Exception.Message
        exit 1
    }
}
