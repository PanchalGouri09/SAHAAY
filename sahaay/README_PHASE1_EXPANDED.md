# SAHAAY — Expanded Phase 1 (Single-File Build)

## 1. What changed vs. your existing project

**Modified file:** `lib/main.dart` — completely replaced with a single,
self-contained implementation as requested. It now contains, in one file:
app entry point, dual light/dark theme (3-blue hierarchy), typography
system, ~20 reusable widgets, mock domain data, and every screen from
splash through all four role dashboards.

**Preserved, not deleted:** your previous multi-file Phase 1 screens are
kept for reference at `reference_phase1_multifile/` inside this zip (not
part of the compiled app — nothing imports them, so they don't affect the
build). Delete that folder whenever you're comfortable it's no longer
needed.

**Unchanged:** `pubspec.yaml`, `assets/` folder, `analysis_options.yaml`.

## 2. Assets required

Already included in `assets/images/`:
- `sahaay_icon.png` — the icon mark cropped from your logo (used on
  Splash, Welcome, Login, and small nav/profile areas)
- `sahaay_logo.png` — the full logo with wordmark, kept for any full-size
  branding use

No new assets are required for this phase. If you'd like the AI-cropped
icon adjusted (tighter/looser crop), just say so.

## 3. pubspec.yaml — no new dependencies needed

This phase only uses `flutter`, `provider`, and Material widgets — all
already in your `pubspec.yaml` from Phase 1. Firebase/Supabase/Maps
packages remain listed for later phases but are **not called** anywhere
in this file yet (no `Firebase.initializeApp()`, no Supabase client) —
everything runs on an in-memory `AppState`, so there's nothing to
configure to run this today.

## 4. Run it

```bash
cd sahaay
flutter pub get
flutter run
```

That's it — no Firebase/Supabase/API keys needed for this phase.

## 5. How to test everything

### Switch roles quickly (no need to keep re-registering)
On the **Login** screen, demo shortcut chips let you jump straight into
any role:
- Provider → `provider@demo.com`
- NGO → `ngo@demo.com`
- Volunteer → `volunteer@demo.com`
- Admin → `admin@demo.com`
(password for all: `demo1234`, prefilled when you tap a chip)

Or go the full route: Welcome → Get Started → pick a role → fill the
registration form → you're dropped straight into that role's dashboard.

### Provider
- Home tab → stat cards, AI surplus prediction card (marked as demo data)
- **+ CREATE NEW DONATION** → opens a real form (food name, category,
  quantity, servings, safe-consumption-hours slider) → submitting shows
  a mock "Food Safety Analysis" result, then adds the donation to your
  list and switches you to the Donations tab
- Donations tab → status chips (Available/Claimed/In Transit/Delivered)
- Impact tab, Alerts (notifications), Profile (with theme toggle + logout)

### NGO
- Home → "Nearby Food" cards + a recommended-match card with a mock match
  score, distance, and quantity fit
- Tap a card → Donation Details → **Claim** → confirmation dialog → status
  updates and the donation moves into your Claims tab
- Find Food tab, Claims tab, Impact tab, Profile

### Volunteer
- Home → available delivery opportunities
- Tap **I'll Deliver** → Delivery Details screen with a step tracker:
  Accepted → Picked Up → In Transit → Delivered, each step is a real
  button press that advances local state
- Deliveries tab (in-progress/completed), Impact/Rewards tab, Profile

### Admin
- Overview tab → platform-wide stat cards
- Management tab → user/provider/NGO/volunteer/donation monitoring
  sections
- Reports tab → a weekly redistribution bar chart (demo data, clearly
  labeled) + a link to the **Public Impact Leaderboard**

### Leaderboard
Reachable from Admin → Reports, and from any Profile screen. Shows
city/organization/impact-points ranking — clearly demo entities, not
claimed as real SAHAAY partners.

### Light / Dark theme
Toggle from any **Profile** tab (sun/moon icon) or the toggle button on
Welcome/Login. Confirm:
- Light: white/very-light-blue surfaces, dark text
- Dark: dark **grey** (not black) surfaces, light text, same 3-blue
  hierarchy carried through correctly

## 6. What's real vs. what's mock (read before wiring backends)

| Area | Status |
|---|---|
| Navigation, routing by role, forms & validation, state transitions | **Real** — fully working locally |
| Login / Registration | Local in-memory demo session (`AppState`) — swap point clearly marked in code for Firebase Auth |
| Donations, deliveries, notifications, leaderboard | Mock data, explicitly labeled in-UI as demo where it matters (e.g. "DEMO DATA" chip on the admin chart) |
| AI results (surplus prediction, food quality/freshness, NGO match score) | Mock/demo values with a visible "demo result" note — UI is built to the exact shape a FastAPI response will need, so swapping in the real call is a data-source change, not a UI rewrite |
| Maps | Styled placeholder, never presented as a live map |

## 7. Checklist before Phase 2

- [ ] `flutter pub get` + `flutter run` works with no errors
- [ ] All 4 demo-role logins work and route to the correct dashboard
- [ ] Provider: Create Donation form validates and adds a real entry
- [ ] NGO: Claim flow updates status and appears in Claims tab
- [ ] Volunteer: Delivery step tracker advances through all 5 states
- [ ] Admin: all three tabs render without overflow
- [ ] Theme toggle switches the entire app, dark mode is dark grey not black
- [ ] No screen overflows on a small phone width

Tell me once this is confirmed and I'll move to the next phase (wiring
real Firebase Auth + Supabase, or deepening any specific dashboard —
your call).
