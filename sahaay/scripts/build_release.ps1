param(
    [string]$ConfigFile = "env.json",
    [string]$FlutterExecutable,
    [switch]$AllowInsecureLanForTesting
)

$ErrorActionPreference = "Stop"
$appRoot = Split-Path -Parent $PSScriptRoot
$configPath = if ([System.IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile
} else {
    Join-Path $appRoot $ConfigFile
}

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Flutter config file not found: $configPath. Create env.json from env.example.json and set API_BASE_URL."
}

try {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
} catch {
    throw "Flutter config file is not valid JSON: $configPath"
}

$googleServicesPath = Join-Path $appRoot "android\app\google-services.json"
$androidGradlePath = Join-Path $appRoot "android\app\build.gradle.kts"
if (-not (Test-Path -LiteralPath $googleServicesPath -PathType Leaf)) {
    throw "Android Firebase configuration is missing: $googleServicesPath"
}
try {
    $googleServices = Get-Content -LiteralPath $googleServicesPath -Raw | ConvertFrom-Json
} catch {
    throw "Android Firebase configuration is not valid JSON: $googleServicesPath"
}
$applicationIdMatch = [regex]::Match(
    (Get-Content -LiteralPath $androidGradlePath -Raw),
    'applicationId\s*=\s*"([^"]+)"'
)
if (-not $applicationIdMatch.Success) {
    throw "Could not determine the Android application ID from $androidGradlePath."
}
$applicationId = $applicationIdMatch.Groups[1].Value
$androidClients = @(
    $googleServices.client |
        Where-Object {
            $_.client_info.android_client_info.package_name -eq $applicationId
        }
)
if ($androidClients.Count -ne 1) {
    throw "Android Firebase configuration must contain exactly one matching application client."
}
$webOAuthClients = @(
    $androidClients[0].oauth_client |
        Where-Object { $_.client_type -eq 3 }
)
if (
    $webOAuthClients.Count -ne 1 -or
    $webOAuthClients[0].client_id -notmatch '^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$'
) {
    throw "Android Firebase configuration must contain exactly one valid Web OAuth client."
}
$googleServerClientId = $webOAuthClients[0].client_id
$androidOAuthClients = @(
    $androidClients[0].oauth_client |
        Where-Object {
            $_.client_type -eq 1 -and
            $_.android_info.package_name -eq $applicationId
        }
)
if ($androidOAuthClients.Count -eq 0) {
    throw "Android Firebase configuration has no matching Android OAuth client."
}
$firebaseOptionsPath = Join-Path $appRoot "lib\firebase_options.dart"
if (-not (Test-Path -LiteralPath $firebaseOptionsPath -PathType Leaf)) {
    throw "Firebase Dart options are missing: $firebaseOptionsPath"
}
$firebaseOptions = Get-Content -LiteralPath $firebaseOptionsPath -Raw
$dartProjectIds = @(
    [regex]::Matches($firebaseOptions, "projectId:\s*'([^']+)'") |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique
)
if (
    $dartProjectIds.Count -ne 1 -or
    $dartProjectIds[0] -ne $googleServices.project_info.project_id
) {
    throw "Android Firebase project does not match lib\firebase_options.dart."
}
$androidOptionsMatch = [regex]::Match(
    $firebaseOptions,
    'static const FirebaseOptions android = FirebaseOptions\((.*?)\);',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$androidAppIdMatch = [regex]::Match(
    $androidOptionsMatch.Groups[1].Value,
    "appId:\s*'([^']+)'"
)
if (
    -not $androidOptionsMatch.Success -or
    -not $androidAppIdMatch.Success -or
    $androidAppIdMatch.Groups[1].Value -ne
    $androidClients[0].client_info.mobilesdk_app_id
) {
    throw "Android Firebase app metadata does not match lib\firebase_options.dart."
}

$apiBaseUrl = $config.API_BASE_URL
if ($apiBaseUrl -isnot [string] -or [string]::IsNullOrWhiteSpace($apiBaseUrl)) {
    throw "API_BASE_URL is missing from $configPath."
}

$parsedUrl = $null
if (-not [Uri]::TryCreate($apiBaseUrl, [System.UriKind]::Absolute, [ref]$parsedUrl)) {
    throw "API_BASE_URL must be an absolute HTTP(S) URL."
}
if (
    $parsedUrl.Scheme -notin @("https", "http") -or
    [string]::IsNullOrWhiteSpace($parsedUrl.Host) -or
    -not [string]::IsNullOrEmpty($parsedUrl.UserInfo) -or
    -not [string]::IsNullOrEmpty($parsedUrl.Query) -or
    -not [string]::IsNullOrEmpty($parsedUrl.Fragment) -or
    $parsedUrl.IsLoopback -or
    $parsedUrl.Host -in @("0.0.0.0", "::") -or
    $parsedUrl.Host -match "your-fastapi-host|your-deployed-fastapi|example\.com|your-project"
) {
    throw "API_BASE_URL is invalid or is still an example/loopback URL."
}

if ($parsedUrl.Scheme -eq "http") {
    if (-not $AllowInsecureLanForTesting) {
        throw "Release builds require HTTPS. HTTP is allowed only for a private-LAN test build with -AllowInsecureLanForTesting."
    }
    $address = $null
    if (
        -not [System.Net.IPAddress]::TryParse($parsedUrl.Host, [ref]$address) -or
        $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork
    ) {
        throw "The HTTP test-build exception only accepts a private IPv4 address."
    }
    $bytes = $address.GetAddressBytes()
    $isPrivateLanAddress = (
        $bytes[0] -eq 10 -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    )
    if (-not $isPrivateLanAddress) {
        throw "The HTTP test-build exception only accepts RFC1918 private IPv4 addresses."
    }
}

if ([string]::IsNullOrWhiteSpace($FlutterExecutable)) {
    $flutterSdkLine = Get-Content -LiteralPath (Join-Path $appRoot "android\local.properties") |
        Where-Object { $_ -match "^flutter\.sdk=" } |
        Select-Object -First 1
    if ($flutterSdkLine) {
        $flutterSdk = $flutterSdkLine.Substring("flutter.sdk=".Length).Replace("\\", "\")
        $FlutterExecutable = Join-Path $flutterSdk "bin\flutter.bat"
    } else {
        $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
        if ($flutterCommand) {
            $FlutterExecutable = $flutterCommand.Source
        }
    }
}

if (-not $FlutterExecutable -or -not (Test-Path -LiteralPath $FlutterExecutable -PathType Leaf)) {
    throw "Flutter executable not found. Set -FlutterExecutable or add Flutter to PATH."
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $configPath).Path
Write-Output "Building release APK using API_BASE_URL host '$($parsedUrl.Host)' (configuration values are not logged)."
$expectedCleartextTraffic = $parsedUrl.Scheme -eq "http"
$allowCleartextValue = $expectedCleartextTraffic.ToString().ToLowerInvariant()
$releaseManifestPropertiesPath = Join-Path $appRoot "build\release-manifest.properties"
if (Test-Path -LiteralPath $releaseManifestPropertiesPath -PathType Container) {
    throw "Expected a file but found a directory: $releaseManifestPropertiesPath"
}
$hadReleaseManifestProperties = Test-Path -LiteralPath $releaseManifestPropertiesPath -PathType Leaf
$previousReleaseManifestProperties = if ($hadReleaseManifestProperties) {
    Get-Content -LiteralPath $releaseManifestPropertiesPath -Raw
} else {
    $null
}
if ($parsedUrl.Scheme -eq "http") {
    Write-Output "Android cleartext is enabled only for this explicit private-LAN test build."
}
Push-Location $appRoot
try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $releaseManifestPropertiesPath) -Force |
        Out-Null
    $manifestProperties = @(
        "allowInsecureLanForTesting=$allowCleartextValue",
        "apiScheme=$($parsedUrl.Scheme)",
        "apiHost=$($parsedUrl.Host)"
    ) -join "`n"
    [IO.File]::WriteAllText(
        $releaseManifestPropertiesPath,
        "$manifestProperties`n",
        [Text.UTF8Encoding]::new($false)
    )

    $gradleWrapper = Join-Path $appRoot "android\gradlew.bat"
    if (-not (Test-Path -LiteralPath $gradleWrapper -PathType Leaf)) {
        throw "Android Gradle wrapper not found: $gradleWrapper"
    }
    Push-Location (Join-Path $appRoot "android")
    try {
        & $gradleWrapper :app:processReleaseManifestForPackage --rerun-tasks --quiet
        $manifestExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($manifestExitCode -ne 0) {
        throw "Release manifest generation failed with exit code $manifestExitCode."
    }

    $packagedManifestPath = Join-Path $appRoot "build\app\intermediates\packaged_manifests\release\processReleaseManifestForPackage\AndroidManifest.xml"
    if (-not (Test-Path -LiteralPath $packagedManifestPath -PathType Leaf)) {
        throw "Packaged release manifest is missing: $packagedManifestPath"
    }
    $packagedManifest = Get-Content -LiteralPath $packagedManifestPath -Raw
    $manifestAllowsCleartext = $packagedManifest -match 'android:usesCleartextTraffic="true"'
    if ($manifestAllowsCleartext -ne $expectedCleartextTraffic) {
        throw "Packaged release manifest cleartext policy does not match API_BASE_URL scheme."
    }

    & $FlutterExecutable build apk --release `
        "--dart-define-from-file=$resolvedConfigPath" `
        "--dart-define=GOOGLE_SERVER_CLIENT_ID=$googleServerClientId"
    $buildExitCode = $LASTEXITCODE
} finally {
    Pop-Location
    if ($hadReleaseManifestProperties) {
        [IO.File]::WriteAllText(
            $releaseManifestPropertiesPath,
            $previousReleaseManifestProperties,
            [Text.UTF8Encoding]::new($false)
        )
    } else {
        Remove-Item -LiteralPath $releaseManifestPropertiesPath -Force
    }
}
if ($buildExitCode -ne 0) {
    throw "Flutter release build failed with exit code $buildExitCode."
}

$apkPath = Join-Path $appRoot "build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
    throw "Flutter reported success but the release APK is missing: $apkPath"
}

$localPropertiesPath = Join-Path $appRoot "android\local.properties"
$sdkLine = Get-Content -LiteralPath $localPropertiesPath |
    Where-Object { $_ -match "^sdk\.dir=" } |
    Select-Object -First 1
$androidSdk = if ($sdkLine) {
    $sdkLine.Substring("sdk.dir=".Length).Replace("\\", "\")
} else {
    $env:ANDROID_HOME
}
if ([string]::IsNullOrWhiteSpace($androidSdk)) {
    throw "Android SDK path was not found in android\local.properties or ANDROID_HOME."
}

$apksigner = Get-ChildItem -LiteralPath (Join-Path $androidSdk "build-tools") -Directory |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName "apksigner.bat" } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $apksigner) {
    throw "Android apksigner was not found in the configured SDK."
}
$signingOutput = & $apksigner verify --print-certs $apkPath 2>$null
$signerSha1Line = $signingOutput |
    Select-String -Pattern "Signer #1 certificate SHA-1 digest: ([A-Fa-f0-9: ]+)" |
    Select-Object -First 1
if (-not $signerSha1Line) {
    throw "Could not verify the APK signing certificate SHA-1."
}
$signerSha1 = [regex]::Match(
    $signerSha1Line.Line,
    "Signer #1 certificate SHA-1 digest: ([A-Fa-f0-9: ]+)"
).Groups[1].Value -replace "[: ]", ""
$configuredCertificateHashes = @(
    $androidOAuthClients |
        ForEach-Object { $_.android_info.certificate_hash -replace "[: ]", "" }
)
if (
    $configuredCertificateHashes.Count -eq 0 -or
    $configuredCertificateHashes -notcontains $signerSha1
) {
    throw "APK signing certificate is not registered for this Android OAuth client in google-services.json."
}

$apk = Get-Item -LiteralPath $apkPath
if ($apk.Length -le 0) {
    throw "Flutter created an empty release APK: $apkPath"
}

$aapt = Get-ChildItem -LiteralPath (Join-Path $androidSdk "build-tools") -Directory |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName "aapt.exe" } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $aapt) {
    throw "aapt.exe was not found in Android SDK build-tools."
}
$apkManifest = & $aapt dump xmltree $apkPath AndroidManifest.xml
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect the release APK manifest."
}
$cleartextAttribute = $apkManifest | Where-Object { $_ -match "android:usesCleartextTraffic" } |
    Select-Object -First 1
$apkAllowsCleartext = $cleartextAttribute -match "\(type 0x12\)0x(?:1|ffffffff)\s*$"
if ($apkAllowsCleartext -ne $expectedCleartextTraffic) {
    throw "Release APK cleartext policy does not match API_BASE_URL scheme."
}

$hash = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash
Write-Output "Release APK: $($apk.FullName)"
Write-Output "Size: $($apk.Length) bytes"
Write-Output "APK cleartext traffic: $($apkAllowsCleartext.ToString().ToLowerInvariant())"
Write-Output "SHA-256: $hash"
