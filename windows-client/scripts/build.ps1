Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildDirectory = Join-Path $ProjectRoot "build"
$PackageDirectory = Join-Path $ProjectRoot "dist\MeetingClient-Windows-x64"
$PackageArchive = Join-Path $ProjectRoot "dist\MeetingClient-Windows-x64.zip"
$ProgramFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")

if ([string]::IsNullOrWhiteSpace($ProgramFilesX86)) {
  throw "This build requires 64-bit Windows."
}

$VsWhere = Join-Path $ProgramFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $VsWhere)) {
  throw @"
Visual Studio Build Tools were not found.
Install Visual Studio 2022 Build Tools with the Desktop development with C++ workload, then rerun:
  winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
"@
}

$VisualStudioPath = & $VsWhere `
  -latest `
  -products * `
  -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
  -property installationPath |
  Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($VisualStudioPath)) {
  throw @"
The Visual Studio C++ x64 build tools were not found.
Open Visual Studio Installer and add Desktop development with C++, or run:
  winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
"@
}

$CMakeCommand = Get-Command "cmake.exe" -ErrorAction SilentlyContinue
if ($null -ne $CMakeCommand) {
  $CMakeExecutable = $CMakeCommand.Source
}
else {
  $BundledCMake = Join-Path $VisualStudioPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
  if (Test-Path $BundledCMake) {
    $CMakeExecutable = $BundledCMake
  }
  else {
    throw @"
CMake was not found on PATH or inside Visual Studio.
Install it, refresh PowerShell's PATH, then rerun:
  winget install --id Kitware.CMake --exact --source winget
"@
  }
}

$CTestExecutable = Join-Path (Split-Path -Parent $CMakeExecutable) "ctest.exe"
if (-not (Test-Path $CTestExecutable)) {
  throw "ctest.exe was not found next to CMake: $CMakeExecutable"
}

Write-Host "Using Visual Studio: $VisualStudioPath"
Write-Host "Using CMake:        $CMakeExecutable"

& $CMakeExecutable `
  -S $ProjectRoot `
  -B $BuildDirectory `
  -A x64 `
  -DLIVEKIT_SDK_VERSION=1.4.0 `
  -DBUILD_TESTING=ON
if ($LASTEXITCODE -ne 0) {
  throw "CMake configure failed with exit code $LASTEXITCODE."
}

& $CMakeExecutable --build $BuildDirectory --config Release --parallel
if ($LASTEXITCODE -ne 0) {
  throw "CMake build failed with exit code $LASTEXITCODE."
}

& $CTestExecutable --test-dir $BuildDirectory -C Release --output-on-failure
if ($LASTEXITCODE -ne 0) {
  throw "CTest failed with exit code $LASTEXITCODE."
}

$OutputDirectory = Join-Path $BuildDirectory "Release"
if (Test-Path $PackageDirectory) {
  Remove-Item $PackageDirectory -Recurse -Force
}
New-Item -ItemType Directory -Force $PackageDirectory | Out-Null
Copy-Item (Join-Path $OutputDirectory "MeetingClient.exe") $PackageDirectory -Force
Copy-Item (Join-Path $OutputDirectory "livekit.dll") $PackageDirectory -Force
Copy-Item (Join-Path $OutputDirectory "livekit_ffi.dll") $PackageDirectory -Force
Copy-Item (Join-Path $ProjectRoot "README.md") $PackageDirectory -Force
$RepositoryRoot = Split-Path -Parent $ProjectRoot
$LicenseDirectory = Join-Path $PackageDirectory "Licenses"
New-Item -ItemType Directory -Force $LicenseDirectory | Out-Null
Copy-Item (Join-Path $RepositoryRoot "LICENSE") $LicenseDirectory -Force
Copy-Item (Join-Path $RepositoryRoot "THIRD_PARTY_NOTICES.md") $LicenseDirectory -Force
$SdkDirectory = Join-Path $BuildDirectory "_deps\livekit-sdk"
$LicenseFiles = @(Get-ChildItem $SdkDirectory -Recurse -File | Where-Object {
  $_.Name -match "^(LICENSE|LICENCE|COPYING|NOTICE)"
})
if ($LicenseFiles.Count -eq 0) {
  throw "The LiveKit SDK contains no license notices; refusing to distribute its binaries."
}
foreach ($LicenseFile in $LicenseFiles) {
  $RelativePath = $LicenseFile.FullName.Substring($SdkDirectory.Length).TrimStart('\')
  $Destination = Join-Path $LicenseDirectory $RelativePath
  New-Item -ItemType Directory -Force (Split-Path -Parent $Destination) | Out-Null
  Copy-Item $LicenseFile.FullName $Destination -Force
}
if (Test-Path $PackageArchive) {
  Remove-Item $PackageArchive -Force
}
Compress-Archive -Path (Join-Path $PackageDirectory "*") -DestinationPath $PackageArchive

Write-Host ""
Write-Host "Windows client built successfully:"
Write-Host "  $OutputDirectory\MeetingClient.exe"
Write-Host "Distribution package:"
Write-Host "  $PackageArchive"
