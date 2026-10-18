# Sahaay Flutter app

## Configure the FastAPI URL

The app reads `API_BASE_URL` at compile time. `env.json` is intentionally
gitignored and must contain the real backend base URL, for example:

```json
{
  "API_BASE_URL": "https://<your-deployed-fastapi-host>"
}
```

Do not use `localhost` or `127.0.0.1` for a phone build. The release build
script reads this file, validates the URL, passes the complete JSON file to
Flutter using `--dart-define-from-file`, and verifies the APK output without
printing configuration values:

```powershell
.\scripts\build_release.ps1
```

HTTPS is required by default. For a development backend available at a private
IPv4 LAN address, explicitly opt in to an HTTP test build:

```powershell
.\scripts\build_release.ps1 -AllowInsecureLanForTesting
```

This opt-in only accepts private IPv4 addresses and is not suitable for public
or production builds. Keep `env.json` out of source control and do not put
service-role keys or other server secrets in Flutter configuration.
Android cleartext access is enabled only for this explicit LAN test build;
without the opt-in, release manifests keep cleartext traffic disabled.

For the final APK, set `API_BASE_URL` in the ignored `env.json` to the
verified deployed **HTTPS** backend origin, then run from `sahaay`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_release.ps1 `
  -ConfigFile env.json `
  -FlutterExecutable 'C:\Users\admin\Downloads\Flutter\flutter\bin\flutter.bat'
```

The Maps key is supplied separately through the ignored
`android\secrets.properties`; neither value belongs in source control. The
current Android release variant uses the debug signing configuration and is
for demo/testing, not production distribution.
