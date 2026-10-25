# Builds GRID with the git commit count as the build number, so every build
# from a newer commit gets a higher Android versionCode. The version name
# (e.g. 2.0.0) still comes from `version:` in pubspec.yaml.
#
# Usage, from flutter_mobile_ui:
#   ./tool/build.ps1 apk --release
#   ./tool/build.ps1 apk --debug --target-platform android-x64
$ErrorActionPreference = 'Stop'

Push-Location (Join-Path $PSScriptRoot '..')
try {
    $build = (git rev-list --count HEAD).Trim()
    Write-Host "Building GRID with build number $build"
    [string[]]$extra = @("--build-number=$build")
    if (Test-Path (Join-Path (Get-Location) "secrets.json")) { $extra += "--dart-define-from-file=secrets.json" }
    $buildArgs = @($args) + $extra
    flutter build $buildArgs
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $code
