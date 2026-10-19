param([ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'source/CampusConnect.csproj'
$output = Join-Path $PSScriptRoot "dist/$Runtime"
$staging = Join-Path $PSScriptRoot ("work/publish-" + [guid]::NewGuid().ToString('N'))
dotnet publish $project -c Release -r $Runtime --self-contained true -p:PublishReadyToRun=true -o $staging
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
$files = @(Get-ChildItem $staging -Recurse -File)
$expected = @('CampusConnect.exe', 'onnxruntime.dll', 'onnxruntime_providers_shared.dll',
    'models/captcha-common.onnx', 'models/captcha-digits.json', 'models/SOURCE.json')
$actual = @($files | ForEach-Object { [IO.Path]::GetRelativePath($staging, $_.FullName).Replace('\', '/') })
if (@(Compare-Object ($expected | Sort-Object) ($actual | Sort-Object)).Count -ne 0) {
    throw 'Published app, native libraries or model files differ from the expected payload.'
}
# The directory is a generated build output; stage first to avoid stale DLLs on subsequent builds.
if (Test-Path $output) { Remove-Item $output -Recurse -Force }
New-Item -ItemType Directory -Path (Split-Path $output) -Force | Out-Null
Move-Item $staging $output
Write-Host "Built app with local captcha model: $output/CampusConnect.exe"
