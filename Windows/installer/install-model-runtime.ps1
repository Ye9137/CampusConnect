param([ValidateSet('x64', 'arm64')][string]$RuntimeArch = 'x64')
$ErrorActionPreference = 'Stop'

function Test-ModelRuntime {
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
      $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
      try {
        $key = $baseKey.OpenSubKey("SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$RuntimeArch")
        if ($null -eq $key) { continue }
        try {
            $version = [version](([string]$key.GetValue('Version', '0.0')) -replace '^[vV]', '')
            if ($key.GetValue('Installed', 0) -eq 1 -and $version -ge [version]'14.44.35211.0') { return $true }
        } finally { $key.Dispose() }
      } finally { $baseKey.Dispose() }
    }
    return $false
}

$download = $null
try {
    if (Test-ModelRuntime) { exit 0 }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $download = Join-Path ([IO.Path]::GetTempPath()) ('CampusConnect-VC-' + [guid]::NewGuid().ToString('N') + '.exe')
    # Download directly from Microsoft only when the prerequisite is missing.
    Invoke-WebRequest -UseBasicParsing -Uri "https://aka.ms/vs/17/release/vc_redist.$RuntimeArch.exe" `
        -OutFile $download -TimeoutSec 60
    $signature = Get-AuthenticodeSignature -FilePath $download
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw 'Microsoft runtime signature verification failed.'
    }
    # The Microsoft installer handles any required Windows UAC prompt. Never restart.
    $process = Start-Process -FilePath $download -ArgumentList '/install', '/passive', '/norestart' -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010, 1638) -or -not (Test-ModelRuntime)) {
        throw 'Microsoft runtime installation did not complete.'
    }
    exit 0
} catch {
    Write-Output 'Model runtime unavailable. Manual captcha entry remains available.'
    exit 1
} finally {
    if ($download -and (Test-Path -LiteralPath $download)) { Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue }
}
