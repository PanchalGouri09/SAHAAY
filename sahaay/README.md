# Sahaay Flutter app

## Configure the FastAPI URL

The app reads `API_BASE_URL` at compile time. `env.json` is intentionally
gitignored. Create it from the tracked placeholder template, then set the
verified deployed HTTPS backend origin:

```json
{
  "DEMO_MODE": "false",
  "SUPABASE_URL": "https://YOUR-PROJECT.supabase.co",
  "SUPABASE_ANON_KEY": "YOUR-SUPABASE-ANON-KEY",
  "API_BASE_URL": "https://your-deployed-fastapi.example.com"
}
```

From the repository root, create the local file with:

```powershell
Copy-Item .\sahaay\env.example.json .\sahaay\env.json
```

Replace all placeholders before building. `SUPABASE_URL` and
`SUPABASE_ANON_KEY` are needed only if the optional direct Supabase client
integration is configured. Never put a Supabase service-role key or Firebase
Admin credentials in this file.

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
.\scripts\build_release.ps1
```

Flutter must be installed and available on `PATH` (or pass its executable
explicitly with `-FlutterExecutable`). Android SDK and Flutter SDK locations
are machine-specific and stay in ignored `android\local.properties`; the
build script can also use `ANDROID_HOME` for SDK discovery.

The Maps/Places key is supplied separately through
`android\secrets.properties`, copied from the tracked
`android\secrets.properties.example` placeholder. Restrict the key in Google
Cloud and never commit the local properties file. The current Android release
variant uses the debug signing configuration and is for demo/testing, not
production distribution.
