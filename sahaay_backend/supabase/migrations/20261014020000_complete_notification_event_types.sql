-- Preserve every supported notification type and allow the two real events
-- that were missing from the deployed constraint: failed handover persistence
-- and a completed match attempt with no eligible NGO candidates.
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
            'handover_completed',
            'pickup_updated',
            'acknowledgment_ready',
            'donation_offer',
            'donation_offers_exhausted',
            'donation_no_match'
        ]::text[])
    );
