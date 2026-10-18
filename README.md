# SAHAAY

SAHAAY is a food-surplus redistribution platform with a Flutter Android app,
a Firebase-authenticated FastAPI backend, and a separate AI service.

## Repository layout

- `sahaay/` — Flutter application and Android native integrations.
- `sahaay_backend/` — authenticated FastAPI API and ordered Supabase migrations.
- `sahaay-ai-service/` — FastAPI prediction, matching, and related AI endpoints.

## Windows prerequisites

Install and configure the following before building:

- Git.
- Flutter SDK (stable) on `PATH`; `flutter doctor` should report no Android
  toolchain blockers.
- Android Studio with the Android SDK, platform tools, and an SDK platform
  installed for the Flutter version in use.
- JDK 17.
- Python 3.11 (recommended for both Python services).
- `uv` for the backend (`winget install --id astral-sh.uv -e` or follow the
  installation instructions at <https://docs.astral.sh/uv/>).

Accept Android SDK licenses in PowerShell:

```powershell
flutter doctor --android-licenses
flutter doctor
```

The Gradle wrapper files are tracked, so a fresh clone does not need a local
Gradle installation. Android SDK and Flutter SDK paths remain machine-local.
The Android Gradle settings require `sahaay/android/local.properties`; create
it locally before using the release build script:

```powershell
$flutterCommand = Get-Command flutter -ErrorAction Stop
$flutterSdk = Split-Path -Parent (Split-Path -Parent $flutterCommand.Source)
$androidSdk = if ($env:ANDROID_HOME) {
  $env:ANDROID_HOME
} elseif ($env:ANDROID_SDK_ROOT) {
  $env:ANDROID_SDK_ROOT
} else {
  Join-Path $env:LOCALAPPDATA "Android\Sdk"
}
$properties = "flutter.sdk=$($flutterSdk -replace '\\', '/')`nsdk.dir=$($androidSdk -replace '\\', '/')`n"
Set-Content -LiteralPath .\sahaay\android\local.properties `
  -Value $properties -Encoding ascii
```

If Android Studio installed the SDK elsewhere, set `ANDROID_HOME` to that SDK
directory before running these commands. `local.properties` is ignored and
must not be committed.

## Clone

```powershell
git clone https://github.com/PanchalGouri09/SAHAAY.git
Set-Location .\SAHAAY
```

## Configure and run the Flutter Android app

### Firebase and Maps setup

1. Use an authorized Firebase project and register the Android application ID
   `com.example.sahaay`.
2. Install FlutterFire CLI once if needed, then generate the client options:

   ```powershell
   dart pub global activate flutterfire_cli
   flutterfire configure --project YOUR_FIREBASE_PROJECT_ID --platforms android
   ```

   Confirm this creates `sahaay/lib/firebase_options.dart` and
   `sahaay/android/app/google-services.json`. If your organization provides
   these files directly, place them at those paths instead. They are
   intentionally ignored and must not be committed.
3. In Google Cloud for the same project, enable the Maps SDK for Android and
   Places API, configure billing, and restrict the key to this Android package
   and the signing certificate fingerprints used by your build.
4. Create the local Maps configuration from its placeholder template:

   ```powershell
   Copy-Item .\sahaay\android\secrets.properties.example `
     .\sahaay\android\secrets.properties
   notepad .\sahaay\android\secrets.properties
   ```

   Replace the placeholder with the restricted key. Do not commit
   `secrets.properties` or paste a key into source code.

### App API configuration and dependencies

Create the ignored Flutter build configuration from the tracked template:

```powershell
Copy-Item .\sahaay\env.example.json .\sahaay\env.json
notepad .\sahaay\env.json
```

Set `API_BASE_URL` to the deployed FastAPI **HTTPS origin** (no path, query,
or trailing slash is needed). The example value is only a placeholder. For a
phone build, do not use `localhost` or `127.0.0.1`. Set `SUPABASE_URL` and
`SUPABASE_ANON_KEY` only if the app's optional direct Supabase client
integration is configured for your project; a public anon/publishable key is
not a substitute for the backend's service-role key.

Install Flutter packages and start the app on a connected Android device or
emulator:

```powershell
Set-Location .\sahaay
flutter pub get
flutter run --dart-define-from-file=env.json
```

### Build a release-variant test APK

With a valid HTTPS `API_BASE_URL`, Firebase files, Maps key, JDK 17, and Android
SDK configured, run:

```powershell
Set-Location .\sahaay
.\scripts\build_release.ps1
```

The script validates the API URL, builds `build\app\outputs\flutter-apk\app-release.apk`,
and reports its size and SHA-256 hash. The current release variant is signed
with the debug signing configuration for demo/testing only; it is **not**
production-distribution signed. Production signing requires a separately
managed private keystore and reviewed signing configuration.

For an explicit private-LAN HTTP test build only, set `API_BASE_URL` to an
RFC1918 private IPv4 address and opt in:

```powershell
.\scripts\build_release.ps1 -AllowInsecureLanForTesting
```

Do not use that option for deployed or production builds.

## Run the backend

Open a PowerShell window at the repository root:

```powershell
Set-Location .\sahaay_backend
uv sync --extra test
Copy-Item .env.example .env
notepad .env
```

Fill in the backend's server-side `SUPABASE_URL`,
`SUPABASE_SERVICE_ROLE_KEY`, Firebase Admin project/client/private-key
credentials, and other required deployment settings. Never put these values
in Flutter configuration or commit `.env`. Keep the AI service local at its
default `http://127.0.0.1:8001` for local development, or set `AI_SERVICE_URL`
to its private deployment address.

Start the backend:

```powershell
uv run uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

Check `http://127.0.0.1:8000/health` and API docs at
`http://127.0.0.1:8000/docs`. Supabase migrations in
`sahaay_backend/supabase/migrations/` are not applied at startup; review and
apply them only through the authorized database migration workflow.

## Run the AI service

Open a second PowerShell window at the repository root:

```powershell
Set-Location .\sahaay-ai-service
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python -m app.ml.train_model
python -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8001
```

The service health endpoint is `http://127.0.0.1:8001/health`; interactive API
docs are at `/docs`. The model files and generated PDFs are local/generated
artifacts and are not tracked. Do not expose this unauthenticated service
publicly; deploy it on a private network reachable by the backend.
Optional OSRM settings shown in `.env.example` are environment-variable
examples; for local PowerShell sessions set them directly, for example:

```powershell
$env:OSRM_BASE_URL = "https://router.project-osrm.org"
$env:ROAD_DISTANCE_TIMEOUT_SECONDS = "3"
```

## Tests

Backend:

```powershell
Set-Location .\sahaay_backend
uv run pytest
```

AI service (activate its `.venv` first):

```powershell
Set-Location .\sahaay-ai-service
.\.venv\Scripts\Activate.ps1
python -m pytest
```

Flutter:

```powershell
Set-Location .\sahaay
flutter analyze
flutter test
```

## Deployment and secret handling

- Store Supabase service-role and Firebase Admin credentials in the backend
  host's secret manager, never in Git or the app.
- Keep `sahaay_backend/.env`, `sahaay-ai-service/.env`,
  `sahaay/env.json`, `sahaay/android/secrets.properties`,
  `sahaay/android/local.properties`, Firebase client configuration, signing
  keys, local databases, generated model files, build output, logs, and
  backups out of source control.
- Keep one backend replica while the in-process offer/escalation schedulers
  are enabled. Configure `AI_SERVICE_URL` to the private AI-service address.
- Verify both service health endpoints and the actual Supabase migration
  history/schema before enabling a deployment. Application startup does not
  deploy migrations.
