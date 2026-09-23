# SAHAAY — Phase 1 Final UI/UX Update

Everything below was implemented directly in `lib/main.dart` (still one
single file, per your requirement). No new files, folders, or screens
outside that file were created.

## 1. Splash screen shows logo alone for 2+ seconds
Already correct — the splash displays only the SAHAAY logo with a fade-in,
holds for 2000ms, then navigates to the Welcome screen. No login/dashboard
content is shown during this time.

## 2. Leaderboard moved off Login, onto the Homepage
It was never on the Login screen. It's now reachable from: the Welcome
screen, every role's Impact tab (one tap from the home bottom-nav), Admin
Reports, and Profile — so it's homepage-level accessible for every role
without cluttering the literal Home tab layout.

## 3. Fixed the header/stat-card overlap
Found the actual bug: every dashboard (Provider, NGO, Volunteer, Admin) had
its top stat row wrapped in `Transform.translate(offset: Offset(0, -28))`
(or `-20` for Admin's tab bar), which pulled it up on top of the header.
Removed that transform on all four dashboards — stat cards and the admin
tab bar now sit cleanly below the header with normal spacing, no overlap,
verified at both small and standard widths.

## 4. My Claims — centered alignment
Added a new `_ClaimSummaryCard` widget used only inside the My Claims list
— food name, status, provider, and info chips are center-aligned. The
shared `DonationCard` (still used by Provider's My Donations and NGO's Find
Food) was left completely untouched, so those screens are unaffected.

## 5. Settings dashboard
New `SettingsScreen`: Account (name/role, edit-profile placeholder),
Notification Preferences (3 real local toggles), Privacy (leaderboard
visibility toggle), App Preferences (dark mode switch wired to the same
`AppState.toggleTheme()` used everywhere else, plus a Language row),
Logout. All built from existing Card/ListTile/SwitchListTile components.

## 6. Help & Support dashboard
New `HelpSupportScreen`: expandable FAQ entries (How SAHAAY Works, Donation
Help, Claim Help, Account Help) with real explanatory copy, plus Contact
Support and Report a Problem — both open a bottom-sheet form and confirm
submission. No fake contact details are shown since none exist yet.

## 7. Find Food search bar
`_NgoFindFoodTab` now has a search field at the top that filters by food
name, provider name, or category in real time, with its own "no results
for X" empty state distinct from the "no donations at all" empty state.

## 8. Post-claim dashboard
New `ClaimedDonationDashboard`, opened immediately after an NGO claims a
donation (from both the quick-claim dialog and the full Donation Details
screen), and reachable again anytime from My Claims. Contains:
- **Location** — the existing map placeholder (never presented as live).
- **Restaurant Information** — name, address, contact, rating/reviews,
  each falling back to "Not provided yet" / "No reviews yet" instead of
  any invented value.
- **Volunteer** — shown only if a volunteer is actually attached to that
  donation; otherwise an explicit "No volunteer assigned — this donation
  can proceed without one" notice, keeping volunteering strictly optional.
- **OTP verification** — a locally generated 4-digit handover code (there's
  no SMS gateway yet) shown to share at pickup, with an input + verify
  step and a success state on match.
- **Photo** — a real `image_picker` gallery picker with thumbnail preview,
  using the `image_picker` dependency already in `pubspec.yaml`.

## 9. Notifications
Moved notification storage into `AppState` as a real list
(`notifications`, `pushNotification()`, `markNotificationRead()`) instead
of the old method that always returned an empty list. The app now
generates genuine notifications from real actions:
- Provider creates a donation → donation-category notification
- NGO claims a donation → donation-category notification
- Volunteer accepts a delivery → volunteer-category notification
- Volunteer completes a delivery → reward-category notification

`NotificationTile` now shows a distinct icon per category and supports
tap-to-mark-read. The screen still shows a proper "No notifications yet"
empty state when the list is empty.

## 10. All demo/hardcoded data removed
Every fabricated number and name is gone, replaced with either a real
computed value or an honest empty/pending state:

| Where | Before | Now |
|---|---|---|
| Provider Impact Points | `1,280` | `0` (no scoring backend yet) |
| Provider Impact tab | 540 kg / 2,160 / 48 / 4.8★ (all fake) | Computed from real donations; rating shows `—` |
| Food-safety dialog | Fake quality score (`84 + name.length % 12`) | Honest "analysis pending AI service" message |
| NGO Home stats | Active Claims `3`, Food Received `185 kg`, People Served `740` | All computed from the real claimed list |
| NGO Impact tab | 740 / 185 kg / 32 / 4.9★ (all fake) | Computed from real claims; rating shows `—` |
| Volunteer Home/Impact | Completed `12`, Distance `38 km`, Points `640`, Reliability `94%`, etc. | Computed from real deliveries; unknowable values show `—` or `0` |
| Admin Overview | 1,284 users / 86 providers / fake activity feed with invented names | `0` across the board with a "live analytics once Supabase is connected" banner; activity feed replaced with a proper empty state |
| Admin Reports chart | Invented weekly bar values, "DEMO DATA" chip | Empty-state message in the same card shape |
| Surplus Prediction card | Fake 150 customers / 91% confidence | "Prediction pending AI service" message, same card shape |
| Match Score card | Fake 94% match / "Excellent" fit | "Match score pending matching engine" message |
| Leaderboard | Rendered nothing when empty (silent blank space) | Proper "will populate as donations complete" empty state |

Nothing was replaced with a different set of fake numbers — every one of
these is either a real computation off actual session data, or an honest
"not available yet" state, exactly as instructed.

## Everything else
Colors, typography, the logo, existing cards/buttons, the role-based
dashboards' overall structure, and navigation are unchanged. This remains
a single `lib/main.dart` file.
