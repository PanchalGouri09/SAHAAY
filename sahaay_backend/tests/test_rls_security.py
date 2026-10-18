"""Security regression tests for the Batch 2 RLS hardening.

These are deliberately STATIC tests over the migration SQL and the Flutter
sources: the repository has no disposable Postgres in CI, so the invariants
that must never regress are asserted textually and structurally —

  * every broad `USING (true)` / `WITH CHECK (true)` anonymous policy that the
    original schema created is dropped by the corrective migration,
  * the corrective migration creates NO new policy (it can only remove),
  * no later migration reintroduces a broad anonymous policy,
  * the legitimate scoped read-only policies are preserved,
  * no service-role credential exists anywhere in the Flutter app,
  * the client-side Supabase bootstrap uses only the anon/publishable key.

Nothing here weakens runtime enforcement: RLS itself (enabled tables, role
grants, FastAPI service-role access) is unchanged and is exercised by the
backend normally.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

MIGRATIONS_DIR = Path(__file__).resolve().parents[1] / "supabase" / "migrations"
ORIGINAL_SCHEMA = MIGRATIONS_DIR / "20260912112505_remote_schema.sql"
FIX_MIGRATION = MIGRATIONS_DIR / "20261003000000_fix_anon_rls_policies.sql"
NOTIFICATION_TYPES_MIGRATION = (
    MIGRATIONS_DIR / "20261003000001_expand_notification_types.sql"
)
ACKNOWLEDGMENT_MIGRATION = (
    MIGRATIONS_DIR / "20261003000002_add_acknowledgment_reference.sql"
)
DEVICE_TOKEN_INDEX_MIGRATION = (
    MIGRATIONS_DIR / "20261014000000_restore_user_device_token_unique_index.sql"
)
COMPLETE_NOTIFICATION_TYPES_MIGRATION = (
    MIGRATIONS_DIR / "20261014020000_complete_notification_event_types.sql"
)
ANONYMOUS_POLICY_CHECK_MIGRATION = (
    MIGRATIONS_DIR / "20261015000000_harden_anonymous_policy_check.sql"
)
FLUTTER_DIR = Path(__file__).resolve().parents[2] / "sahaay"

_SENSITIVE_TABLES = ("users", "providers", "ngos", "volunteers")


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _broad_anon_policies(sql: str) -> list[tuple[str, str]]:
    """(table, policy_name) for every `to anon` policy using `true`."""
    found = []
    pattern = re.compile(
        r'create policy\s+"([^"]+)"\s+on\s+"?public"?\."?([a-z_]+)"?[^;]*?'
        r"(?:using\s*\(\s*(?:true)\s*\)|with\s+check\s*\(\s*(?:true)\s*\))",
        re.IGNORECASE | re.DOTALL,
    )
    for name, table in pattern.findall(sql):
        found.append((table, name))
    return found


def test_original_schema_contained_the_vulnerability_it_reported() -> None:
    # Guards the detector itself: if this ever fails, the regex above drifted
    # and every subsequent assertion loses its meaning.
    broad = _broad_anon_policies(_read(ORIGINAL_SCHEMA))
    assert len(broad) == 12, broad
    tables = {t for t, _ in broad}
    assert tables == set(_SENSITIVE_TABLES)


def test_fix_migration_drops_all_twelve_broad_anon_policies() -> None:
    sql = _read(FIX_MIGRATION)
    for table, name in _broad_anon_policies(_read(ORIGINAL_SCHEMA)):
        statement = f'drop policy if exists "{name}" on public.{table};'
        assert statement in sql, f"missing: {statement}"


def test_fix_migration_creates_no_new_policy() -> None:
    assert "create policy" not in _read(FIX_MIGRATION).lower()


def test_fix_migration_keeps_legitimate_scoped_read_only_policies() -> None:
    sql = _read(FIX_MIGRATION).lower()
    for kept in (
        "public_view_available_donations",
        "public_view_verified_ngos",
        "public_view_verified_providers",
    ):
        assert f"drop policy if exists \"{kept}\"" not in sql


def test_fix_migration_verifies_no_broad_anon_policy_remains() -> None:
    # The migration must fail loudly (RAISE EXCEPTION) if any broad anon
    # policy survives on any table — not only the four known ones.
    sql = _read(FIX_MIGRATION)
    assert "raise exception" in sql.lower()
    assert "pg_policies" in sql
    assert "anon" in sql


def test_forward_migration_checks_anon_and_public_role_policies() -> None:
    sql = _read(ANONYMOUS_POLICY_CHECK_MIGRATION).lower()
    assert "roles && array['anon', 'public']::name[]" in sql
    assert "pg_policies" in sql
    assert "drop policy" in sql
    assert "raise exception" in sql
    assert "users', 'providers', 'ngos', 'volunteers" in sql


def test_no_migration_reintroduces_a_broad_anonymous_policy() -> None:
    for migration in sorted(MIGRATIONS_DIR.glob("*.sql")):
        if migration == ORIGINAL_SCHEMA:
            continue  # historical snapshot; its policies are dropped by the fix
        sql = migration.read_text(encoding="utf-8")
        assert not _broad_anon_policies(sql), f"{migration.name} adds a broad policy"
        # No migration after the original snapshot may create ANY policy: the
        # corrective migration only removes them.
        assert "create policy" not in sql.lower(), (
            f"{migration.name} creates a policy"
        )


def test_sensitive_tables_enable_row_level_security() -> None:
    all_sql = "\n".join(
        m.read_text(encoding="utf-8") for m in sorted(MIGRATIONS_DIR.glob("*.sql"))
    )
    lowered = all_sql.lower()
    for table in (
        *_SENSITIVE_TABLES,
        "notifications",
        "donations",
        "claims",
        "deliveries",
    ):
        assert (
            f'alter table "public"."{table}" enable row level security;' in lowered
        ), f"RLS not enabled on {table}"


def test_device_tokens_has_no_client_policy() -> None:
    """user_device_tokens is RLS-enabled with ZERO client policies: only the
    FastAPI service role can touch FCM tokens."""
    sql = _read(MIGRATIONS_DIR / "20260925120000_create_user_device_tokens.sql")
    assert "enable row level security" in sql.lower()
    assert "create policy" not in sql.lower()


def test_device_token_conflict_index_migration_checks_duplicates_before_index() -> None:
    sql = _read(DEVICE_TOKEN_INDEX_MIGRATION).lower()
    assert "public.user_device_tokens" in sql
    assert "to_regclass('public.user_device_tokens') is null" in sql
    assert "lock table public.user_device_tokens in share mode" in sql
    assert sql.index("to_regclass(") < sql.index("lock table")
    assert sql.index("lock table") < sql.index("group by token")
    assert "group by token" in sql
    assert "having count(*) > 1" in sql
    assert sql.index("if duplicate_token_values > 0") < sql.index(
        "create unique index"
    )
    index_check_start = sql.index("from pg_index")
    index_check_end = sql.index("into has_token_conflict_index")
    index_check = sql[index_check_start:index_check_end]
    for condition in (
        "i.indisunique",
        "not i.indisexclusion",
        "i.indisvalid",
        "i.indisready",
        "i.indimmediate",
        "i.indpred is null",
        "i.indnkeyatts = 1",
        "pg_get_indexdef(i.indexrelid, 1, true) = 'token'",
    ):
        assert condition in index_check, f"missing conflict-arbiter check: {condition}"
    assert "on public.user_device_tokens (token)" in sql
    assert "raise exception" in sql
    assert "delete from public.user_device_tokens" not in sql
    assert "update public.user_device_tokens" not in sql


def test_notification_types_migration_only_widens_the_constraint() -> None:
    sql = _read(NOTIFICATION_TYPES_MIGRATION)
    assert "drop constraint if exists notifications_type_check" in sql
    # Every previously-valid type must still be valid (nothing is removed).
    for legacy in (
        "new_nearby_donation",
        "claim_submitted",
        "claim_accepted",
        "claim_rejected",
        "donation_claimed",
        "volunteer_assigned",
        "pickup_reminder",
        "delivery_completed",
        "delivery_failed",
        "donation_expiring_soon",
        "donation_cancelled",
    ):
        assert f"'{legacy}'" in sql, f"legacy type {legacy} was dropped"
    for added in (
        "claim_cancelled",
        "claim_completed",
        "handover_verified",
        "pickup_updated",
        "acknowledgment_ready",
    ):
        assert f"'{added}'" in sql


def test_latest_notification_migration_preserves_types_and_only_widens_check() -> None:
    sql = _read(COMPLETE_NOTIFICATION_TYPES_MIGRATION).lower()
    assert "drop constraint if exists notifications_type_check" in sql
    for supported_type in (
        "new_nearby_donation",
        "claim_submitted",
        "claim_accepted",
        "claim_rejected",
        "donation_claimed",
        "volunteer_assigned",
        "pickup_reminder",
        "delivery_completed",
        "delivery_failed",
        "donation_expiring_soon",
        "donation_cancelled",
        "claim_cancelled",
        "claim_completed",
        "handover_verified",
        "handover_completed",
        "pickup_updated",
        "acknowledgment_ready",
        "donation_offer",
        "donation_offers_exhausted",
        "donation_no_match",
    ):
        assert f"'{supported_type}'" in sql
    assert "delete from public.notifications" not in sql
    assert "update public.notifications" not in sql
    assert "truncate public.notifications" not in sql


def test_acknowledgment_columns_are_nullable_additive_columns() -> None:
    sql = _read(ACKNOWLEDGMENT_MIGRATION)
    assert "add column if not exists acknowledgment_pdf_url text" in sql
    assert (
        "add column if not exists acknowledgment_generated_at timestamp with time zone"
        in sql
    )
    # Additive only: nothing is dropped and no table is dropped.
    assert "drop column" not in sql
    assert "drop table" not in sql


# ---------------------------------------------------------------------------
# Flutter must never hold a service-role credential
# ---------------------------------------------------------------------------
def test_flutter_sources_contain_no_service_role_credential() -> None:
    offenders = []
    for path in list(FLUTTER_DIR.rglob("*.dart")) + [
        FLUTTER_DIR / "env.example.json"
    ]:
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        if re.search(r"service[_-]?role", text, re.IGNORECASE):
            offenders.append(str(path.relative_to(FLUTTER_DIR)))
    assert offenders == [], f"service-role material found in Flutter: {offenders}"


def test_flutter_supabase_bootstrap_uses_only_the_anon_key() -> None:
    source = _read(FLUTTER_DIR / "lib" / "services" / "supabase_service.dart")
    assert "publishableKey: anonKey" in source
    assert "service_role" not in source.lower()

    env_example = json.loads(_read(FLUTTER_DIR / "env.example.json"))
    supabase_keys = [k for k in env_example if "SUPABASE" in k.upper()]
    assert set(supabase_keys) == {"SUPABASE_URL", "SUPABASE_ANON_KEY"}


def test_protected_direct_table_access_is_refused_by_the_client_service() -> None:
    """The legacy client-side DatabaseService must still refuse every protected
    operation instead of silently using the anon key against business tables."""
    source = _read(FLUTTER_DIR / "lib" / "services" / "database_service.dart")
    assert "_requireBackendAuthorization" in source
    # Every write/protected-read helper still routes through the refusal guard.
    for helper in (
        "createUserProfile",
        "createProviderProfile",
        "createDonation",
        "createClaim",
        "createDelivery",
        "createNotification",
        "updateClaimStatus",
        "updateDonationStatus",
    ):
        assert helper in source, f"{helper} missing"
    assert source.count("_requireBackendAuthorization") >= 10
