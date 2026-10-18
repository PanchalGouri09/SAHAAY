-- ============================================================================
-- Extend notifications.type with the real business events added in Batch 2.
-- ============================================================================
--
-- The original constraint (20260912112505_remote_schema.sql) allows:
--   new_nearby_donation, claim_submitted, claim_accepted, claim_rejected,
--   donation_claimed, volunteer_assigned, pickup_reminder, delivery_completed,
--   delivery_failed, donation_expiring_soon, donation_cancelled
--
-- Batch 2 wires notifications to real events that had no type of their own:
--   claim_cancelled       -> provider: an NGO withdrew its claim
--   claim_completed       -> provider: an NGO marked its claim completed
--   handover_verified     -> provider: server-side handover code verified
--   pickup_updated        -> claiming NGO: food picked up / in transit
--   acknowledgment_ready  -> provider: completion PDF generated and persisted
--
-- No existing type is removed and no row is touched; the constraint is simply
-- widened. (The original constraint was added NOT VALID then validated; a
-- fresh ADD CONSTRAINT validates against all rows, which passes because every
-- stored value is from the allowed list.)
-- ============================================================================

alter table public.notifications
    drop constraint if exists notifications_type_check;

alter table public.notifications
    add constraint notifications_type_check check (
        type is null
        or type = any (array[
            'new_nearby_donation',
            'claim_submitted',
            'claim_accepted',
            'claim_rejected',
            'donation_claimed',
            'volunteer_assigned',
            'pickup_reminder',
            'delivery_completed',
            'delivery_failed',
            'donation_expiring_soon',
            'donation_cancelled',
            'claim_cancelled',
            'claim_completed',
            'handover_verified',
            'pickup_updated',
            'acknowledgment_ready'
        ]::text[])
    );
