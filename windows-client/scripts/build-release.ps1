[CmdletBinding()]
param(
  [ValidatePattern("^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$")]
  [string]$Version = "0.1.0",
  [switch]$InstallInnoSetup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildScript = Join-Path $PSScriptRoot "build.ps1"
$DistDirectory = Join-Path $ProjectRoot "dist"
$PackageDirectory = Join-Path $DistDirectory "MeetingClient-Windows-x64"
$PackageArchive = Join-Path $DistDirectory "MeetingClient-Windows-x64.zip"
$InstallerDefinition = Join-Path $ProjectRoot "installer\MeetingClient.iss"
$SetupFile = Join-Path $DistDirectory "MeetingClient-Setup-$Version-x64.exe"
$ChecksumFile = Join-Path $DistDirectory "SHA256SUMS.txt"
$CacheDirectory = Join-Path $ProjectRoot "build-cache"
$RedistCache = Join-Path $CacheDirectory "vc_redist.x64.exe"
$RedistDownload = "$RedistCache.download"
$ProgramFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
$ProgramFilesDirectory = [Environment]::GetEnvironmentVariable("ProgramFiles")
$LocalAppData = [Environment]::GetEnvironmentVariable("LOCALAPPDATA")

function Find-InnoCompiler {
  $Command = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
  if ($null -ne $Command) {
    return $Command.Source
  }

  $Candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($script:ProgramFilesX86)) {
    $Candidates += Join-Path $script:ProgramFilesX86 "Inno Setup 7\ISCC.exe"
    $Candidates += Join-Path $script:ProgramFilesX86 "Inno Setup 6\ISCC.exe"
  }
  if (-not [string]::IsNullOrWhiteSpace($script:ProgramFilesDirectory)) {
    $Candidates += Join-Path $script:ProgramFilesDirectory "Inno Setup 7\ISCC.exe"
    $Candidates += Join-Path $script:ProgramFilesDirectory "Inno Setup 6\ISCC.exe"
  }
  if (-not [string]::IsNullOrWhiteSpace($script:LocalAppData)) {
    $Candidates += Join-Path $script:LocalAppData "Programs\Inno Setup 7\ISCC.exe"
    $Candidates += Join-Path $script:LocalAppData "Programs\Inno Setup 6\ISCC.exe"
  }

  foreach ($Candidate in $Candidates) {
    if (Test-Path $Candidate) {
      return $Candidate
    }
  }

  return $null
}

function Find-SignTool {
  $Command = Get-Command "signtool.exe" -ErrorAction SilentlyContinue
  if ($null -ne $Command) {
    return $Command.Source
  }

  if ([string]::IsNullOrWhiteSpace($script:ProgramFilesX86)) {
    return $null
  }

  $KitsDirectory = Join-Path $script:ProgramFilesX86 "Windows Kits\10\bin"
  if (-not (Test-Path $KitsDirectory)) {
    return $null
  }

  $Candidates = @(
    Get-ChildItem $KitsDirectory -Filter "signtool.exe" -File -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match "\\x64\\signtool\.exe$" } |
      Sort-Object FullName -Descending
  )
  if ($Candidates.Count -gt 0) {
    return $Candidates[0].FullName
  }

  return $null
}

$SigningThumbprint = [Environment]::GetEnvironmentVariable("MEETING_SIGN_CERT_SHA1")
$TimestampUrl = [Environment]::GetEnvironmentVariable("MEETING_SIGN_TIMESTAMP_URL")
if ([string]::IsNullOrWhiteSpace($TimestampUrl)) {
  $TimestampUrl = "http://timestamp.digicert.com"
}
$SignTool = $null

function Sign-ReleaseFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([string]::IsNullOrWhiteSpace($script:SigningThumbprint)) {
    return
  }
  if ([string]::IsNullOrWhiteSpace($script:SignTool)) {
    throw "MEETING_SIGN_CERT_SHA1 is set, but signtool.exe was not found."
  }

  & $script:SignTool sign `
    /sha1 $script:SigningThumbprint `
    /fd SHA256 `
    /td SHA256 `
    /tr $script:TimestampUrl `
    $Path
  if ($LASTEXITCODE -ne 0) {
    throw "Code signing failed for $Path with exit code $LASTEXITCODE."
  }

  $Signature = Get-AuthenticodeSignature -FilePath $Path
  if ($Signature.Status.ToString() -ne "Valid") {
    throw "The generated signature is not valid for ${Path}: $($Signature.Status)."
  }
}

& $BuildScript

New-Item -ItemType Directory -Force $CacheDirectory | Out-Null
if (Test-Path $RedistDownload) {
  Remove-Item $RedistDownload -Force
}

Write-Host ""
Write-Host "Downloading the official Microsoft Visual C++ x64 runtime..."
Invoke-WebRequest `
  -Uri "https://aka.ms/vc14/vc_redist.x64.exe" `
  -OutFile $RedistDownload

$RedistSignature = Get-AuthenticodeSignature -FilePath $RedistDownload
if (
  $RedistSignature.Status.ToString() -ne "Valid" -or
  $null -eq $RedistSignature.SignerCertificate -or
  $RedistSignature.SignerCertificate.Subject -notmatch "Microsoft Corporation"
) {
  Remove-Item $RedistDownload -Force
  throw "The downloaded Visual C++ runtime does not have a valid Microsoft signature."
}

Move-Item $RedistDownload $RedistCache -Force
Copy-Item $RedistCache (Join-Path $PackageDirectory "vc_redist.x64.exe") -Force

if (-not [string]::IsNullOrWhiteSpace($SigningThumbprint)) {
  $SignTool = Find-SignTool
  Sign-ReleaseFile (Join-Path $PackageDirectory "MeetingClient.exe")
}
else {
  Write-Warning "No code-signing certificate is configured. The release will work, but Windows SmartScreen may warn users."
}

if (Test-Path $PackageArchive) {
  Remove-Item $PackageArchive -Force
}
Compress-Archive -Path (Join-Path $PackageDirectory "*") -DestinationPath $PackageArchive

$InnoCompiler = Find-InnoCompiler
if ($null -eq $InnoCompiler -and $InstallInnoSetup) {
  $Winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue
  if ($null -eq $Winget) {
    throw "winget.exe was not found. Install Inno Setup manually, then rerun this script."
  }

  Write-Host ""
  Write-Host "Installing Inno Setup with winget..."
  & $Winget.Source install `
    --id JRSoftware.InnoSetup `
    --exact `
    --source winget `
    --silent `
    --accept-package-agreements `
    --accept-source-agreements
  if ($LASTEXITCODE -ne 0) {
    throw "winget could not install Inno Setup (exit code $LASTEXITCODE)."
  }
  $InnoCompiler = Find-InnoCompiler
}

if ($null -eq $InnoCompiler) {
  throw "Inno Setup was not found. Rerun with -InstallInnoSetup or install JRSoftware.InnoSetup first."
}

if (Test-Path $SetupFile) {
  Remove-Item $SetupFile -Force
}

& $InnoCompiler `
  "/DAppVersion=$Version" `
  "/DSourceDir=$PackageDirectory" `
  "/DOutputDir=$DistDirectory" `
  $InstallerDefinition
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path $SetupFile)) {
  throw "Inno Setup completed, but the expected installer was not created: $SetupFile"
}

Sign-ReleaseFile $SetupFile

$ChecksumLines = @(
  $PackageArchive
  $SetupFile
) | ForEach-Object {
  $Hash = Get-FileHash -Path $_ -Algorithm SHA256
  "{0}  {1}" -f $Hash.Hash.ToLowerInvariant(), (Split-Path -Leaf $_)
}
$ChecksumLines | Set-Content -Path $ChecksumFile -Encoding ascii

Write-Host ""
Write-Host "Windows release created successfully:"
Write-Host "  Portable ZIP: $PackageArchive"
Write-Host "  Installer:    $SetupFile"
Write-Host "  Checksums:    $ChecksumFile"
