# SAHAAY — Phase 1

**Project setup, theme, splash, welcome/concept screen, login, registration
(3 roles), role selection, and role-based navigation.**

This phase runs entirely in **DEMO MODE** — no Firebase project, no Supabase
project, no FastAPI backend required yet. Everything is wired through a
mock service so the full auth flow is demonstrable today, and swapping in
real backends later (Phases 8–10) won't require rewriting any screen.

---

## 1. How to merge this into your existing `sahaay` project

You already ran `flutter create sahaay` locally. From this delivery:

1. Copy `lib/` — **replace** your existing `lib/` folder with this one
   (or merge file-by-file if you've already started editing `main.dart`).
2. Copy `pubspec.yaml` — merge the `dependencies:` section into your
   existing file (keep your existing `name:`/`version:` if different).
3. Copy `assets/` into your project root.
4. Copy `analysis_options.yaml`, `env.example.json`, and the `.gitignore`
   additions.
5. Copy `README_PHASE1.md` (this file) for reference.

## 2. Install dependencies

```bash
cd sahaay
flutter pub get
```

## 3. Run the app (demo mode — no backend needed)

```bash
flutter run
```

Demo mode is **on by default** (`DEMO_MODE` defaults to `true` in
`lib/config/env_config.dart`), so this just works.

### Try it end-to-end right now:
- Splash → Welcome ("Turning Surplus Food Into Hope.") → **Get Started**
- Register as **Provider**, **NGO**, or **Volunteer** with any details →
  you'll land straight on that role's dashboard shell.
- Or tap **Login**, then tap one of the demo-account chips
  (Provider / NGO / Volunteer / Admin) to auto-fill credentials, then Login.
  All demo passwords are `demo1234`.
- Try **Forgot password** — it simulates sending a reset email.
- Try **Log out** from any dashboard — you're returned to Welcome.
- Kill and reopen the app while logged in (demo mode keeps you signed in
  only for the current app session — this is expected; persistent
  sessions arrive with the real Firebase wiring in Phase 10).

## 4. Required setup for REAL backends (do this later, not needed now)

You do **not** need to do any of this for Phase 1 to work or to demo it.
Do this when you're ready to move off demo mode:

### Firebase Authentication
1. Create a Firebase project → enable **Email/Password** sign-in.
2. Run `flutterfire configure` (installs `lib/firebase_options.dart` —
   already gitignored).
3. Add `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`
   in `main.dart` once that file exists.

### Supabase
1. Create a Supabase project → grab the Project URL and anon key.
2. You'll pass these via `--dart-define-from-file=env.json` (see below).
3. `supabase_service.dart` (built in Phase 9) will use these.

### Google Maps
- Android: add your key to
  `android/app/src/main/AndroidManifest.xml` inside `<application>`:
  ```xml
  <meta-data android:name="com.google.android.geo.API_KEY" android:value="YOUR_KEY"/>
  ```
- iOS: add to `ios/Runner/AppDelegate.swift`:
  ```swift
  GMSServices.provideAPIKey("YOUR_KEY")
  ```
- Also add location permission strings (needed now, for the
  "Use Current Location" buttons already built in Phase 1):
  - **Android** `android/app/src/main/AndroidManifest.xml`:
    ```xml
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
    ```
  - **iOS** `ios/Runner/Info.plist`:
    ```xml
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>SAHAAY uses your location to find nearby donations and deliveries.</string>
    ```

### Switching out of demo mode
1. Copy `env.example.json` → `env.json` (gitignored) and fill in real values.
2. Run with:
   ```bash
   flutter run --dart-define-from-file=env.json
   ```

## 5. Project structure delivered in this phase

```
lib/
├── main.dart                          # entry point, providers, RoleRouter
├── config/
│   └── env_config.dart                # demo-mode + all env values (no secrets hardcoded)
├── models/
│   └── user_model.dart                # AppUser, UserRole, ProviderType
├── services/
│   ├── auth_service.dart              # AuthService interface + Mock + Firebase impls
│   ├── auth_controller.dart           # ChangeNotifier used by all screens via Provider
│   └── location_service.dart          # geolocator wrapper for "Use Current Location"
├── theme/
│   └── app_theme.dart                 # colors sampled from your logo, Material 3 theme
├── widgets/
│   ├── app_button.dart                # loading-aware primary/outlined button
│   ├── app_text_field.dart            # consistent labeled input
│   └── sahaay_logo.dart               # logo mark + wordmark
└── screens/
    ├── shared/
    │   ├── splash_screen.dart
    │   ├── welcome_screen.dart
    │   └── role_dashboard_scaffold.dart  # shared shell for the 4 dashboard stubs below
    ├── auth/
    │   ├── login_screen.dart
    │   ├── role_selection_screen.dart
    │   ├── register_provider_screen.dart
    │   ├── register_ngo_screen.dart
    │   └── register_volunteer_screen.dart
    ├── provider/provider_dashboard_screen.dart   # Phase 2 builds this out fully
    ├── ngo/ngo_dashboard_screen.dart             # Phase 3 builds this out fully
    ├── volunteer/volunteer_dashboard_screen.dart # Phase 4 builds this out fully
    └── admin/admin_dashboard_screen.dart         # Phase 5 builds this out fully
```

**Why the dashboards are "shells" right now:** they prove real
authentication + role-based routing + working logout — nothing fake. The
stat cards, donation lists, maps, AI results etc. are real feature work
that belongs to Phases 2–5 per the development order, and building them
before the data layer (Supabase) or AI service (FastAPI) exists would
mean throwing that code away later. Nothing here is a "static mockup" —
every button on these screens actually does something (registration
writes a real account into the mock backend, login authenticates against
it, logout actually signs out).

## 6. Phase 1 checklist — confirm before moving to Phase 2

- [ ] `flutter pub get` runs with no errors
- [ ] App launches to Splash → Welcome screen
- [ ] Welcome screen shows the 3 concept cards + Get Started + Login
- [ ] Can register a new Provider / NGO / Volunteer account and land on
      that role's dashboard
- [ ] Can log out and log back in with the same account
- [ ] Demo-account chips (Provider/NGO/Volunteer/Admin) log in correctly
- [ ] Wrong password shows a friendly error (not a crash)
- [ ] Forgot-password flow shows a success message
- [ ] A Provider can never see the NGO/Volunteer/Admin dashboard and vice
      versa (role routing works)
- [ ] Logo renders correctly on Splash, Welcome, and Login screens

Once all boxes are checked, tell me and we'll start **PHASE 2: Provider
dashboard + donation creation workflow**.
