create extension if not exists "pg_cron" with schema "pg_catalog";

drop extension if exists "pg_net";

create extension if not exists "cube" with schema "public";

create extension if not exists "earthdistance" with schema "public";


  create table "public"."claims" (
    "id" uuid not null default gen_random_uuid(),
    "donation_id" uuid not null,
    "ngo_id" uuid not null,
    "requested_quantity" numeric(10,2) not null,
    "status" text not null default 'pending'::text,
    "claimed_at" timestamp with time zone not null default now(),
    "accepted_at" timestamp with time zone,
    "rejected_at" timestamp with time zone,
    "notes" text,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now(),
    "rejection_reason" text
      );


alter table "public"."claims" enable row level security;


  create table "public"."deliveries" (
    "id" uuid not null default gen_random_uuid(),
    "donation_id" uuid not null,
    "claim_id" uuid not null,
    "volunteer_id" uuid,
    "pickup_address" text not null,
    "delivery_address" text not null,
    "pickup_time" timestamp with time zone,
    "delivery_time" timestamp with time zone,
    "status" text not null default 'assigned'::text,
    "notes" text,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now(),
    "proof_of_delivery_url" text,
    "failure_reason" text
      );


alter table "public"."deliveries" enable row level security;


  create table "public"."donations" (
    "id" uuid not null default gen_random_uuid(),
    "provider_id" uuid not null,
    "prediction_id" uuid,
    "food_name" text not null,
    "food_category" text not null,
    "quantity" numeric(10,2) not null,
    "unit" text not null default 'servings'::text,
    "servings" integer,
    "veg_type" text,
    "description" text,
    "food_image_url" text,
    "prepared_at" timestamp with time zone not null,
    "expiry_time" timestamp with time zone not null,
    "pickup_deadline" timestamp with time zone not null,
    "pickup_address" text not null,
    "latitude" double precision,
    "longitude" double precision,
    "status" text not null default 'available'::text,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now(),
    "cancellation_reason" text
      );


alter table "public"."donations" enable row level security;


  create table "public"."feedback" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid not null,
    "donation_id" uuid,
    "rating" integer,
    "feedback_type" text,
    "comments" text,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."feedback" enable row level security;


  create table "public"."food_predictions" (
    "id" uuid not null default gen_random_uuid(),
    "provider_id" uuid not null,
    "prediction_date" date not null,
    "day_of_week" text,
    "meal_type" text,
    "expected_customers" integer,
    "planned_quantity" integer not null,
    "historical_average" numeric(10,2),
    "predicted_consumption" numeric(10,2),
    "predicted_surplus" numeric(10,2),
    "surplus_probability" numeric(5,2),
    "recommendation" text,
    "model_version" text,
    "created_at" timestamp with time zone not null default now(),
    "confidence_score" numeric(5,2)
      );


alter table "public"."food_predictions" enable row level security;


  create table "public"."impact_records" (
    "id" uuid not null default gen_random_uuid(),
    "donation_id" uuid not null,
    "meals_rescued" integer not null default 0,
    "food_weight_kg" numeric(10,2),
    "people_served" integer,
    "estimated_co2_saved" numeric(10,2),
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."impact_records" enable row level security;


  create table "public"."ngos" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid not null,
    "organization_name" text not null,
    "registration_number" text,
    "description" text,
    "phone" text,
    "address" text not null,
    "city" text not null default 'Pune'::text,
    "latitude" double precision,
    "longitude" double precision,
    "food_capacity" integer,
    "preferred_food_types" text[],
    "verified" boolean not null default false,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."ngos" enable row level security;


  create table "public"."notifications" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid not null,
    "title" text not null,
    "message" text not null,
    "type" text,
    "related_donation_id" uuid,
    "is_read" boolean not null default false,
    "created_at" timestamp with time zone not null default now()
      );


alter table "public"."notifications" enable row level security;


  create table "public"."providers" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid not null,
    "organization_name" text not null,
    "organization_type" text not null,
    "description" text,
    "phone" text,
    "address" text not null,
    "city" text not null default 'Pune'::text,
    "latitude" double precision,
    "longitude" double precision,
    "verified" boolean not null default false,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."providers" enable row level security;


  create table "public"."users" (
    "id" uuid not null default gen_random_uuid(),
    "firebase_uid" text not null,
    "full_name" text not null,
    "email" text not null,
    "phone" text,
    "role" text not null,
    "profile_image_url" text,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."users" enable row level security;


  create table "public"."volunteers" (
    "id" uuid not null default gen_random_uuid(),
    "user_id" uuid not null,
    "availability_status" text not null default 'offline'::text,
    "vehicle_type" text,
    "current_latitude" double precision,
    "current_longitude" double precision,
    "verified" boolean not null default false,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."volunteers" enable row level security;

CREATE UNIQUE INDEX claims_pkey ON public.claims USING btree (id);

CREATE UNIQUE INDEX deliveries_claim_id_key ON public.deliveries USING btree (claim_id);

CREATE UNIQUE INDEX deliveries_donation_id_key ON public.deliveries USING btree (donation_id);

CREATE UNIQUE INDEX deliveries_pkey ON public.deliveries USING btree (id);

CREATE UNIQUE INDEX donations_pkey ON public.donations USING btree (id);

CREATE UNIQUE INDEX feedback_pkey ON public.feedback USING btree (id);

CREATE UNIQUE INDEX food_predictions_pkey ON public.food_predictions USING btree (id);

CREATE INDEX idx_claims_donation ON public.claims USING btree (donation_id);

CREATE INDEX idx_claims_donation_status ON public.claims USING btree (donation_id, status);

CREATE INDEX idx_claims_ngo ON public.claims USING btree (ngo_id);

CREATE INDEX idx_claims_status ON public.claims USING btree (status);

CREATE INDEX idx_deliveries_status ON public.deliveries USING btree (status);

CREATE INDEX idx_deliveries_volunteer ON public.deliveries USING btree (volunteer_id);

CREATE INDEX idx_donations_expiry ON public.donations USING btree (expiry_time);

CREATE INDEX idx_donations_location ON public.donations USING btree (latitude, longitude);

CREATE INDEX idx_donations_pickup_deadline ON public.donations USING btree (pickup_deadline);

CREATE INDEX idx_donations_provider ON public.donations USING btree (provider_id);

CREATE INDEX idx_donations_status ON public.donations USING btree (status);

CREATE INDEX idx_donations_status_expiry ON public.donations USING btree (status, expiry_time);

CREATE INDEX idx_ngos_city ON public.ngos USING btree (city);

CREATE INDEX idx_ngos_preferred_food_types ON public.ngos USING gin (preferred_food_types);

CREATE INDEX idx_notifications_unread ON public.notifications USING btree (user_id, is_read);

CREATE INDEX idx_notifications_user ON public.notifications USING btree (user_id);

CREATE INDEX idx_predictions_date ON public.food_predictions USING btree (prediction_date);

CREATE INDEX idx_predictions_provider ON public.food_predictions USING btree (provider_id);

CREATE INDEX idx_predictions_provider_date ON public.food_predictions USING btree (provider_id, prediction_date);

CREATE INDEX idx_providers_city ON public.providers USING btree (city);

CREATE INDEX idx_users_firebase_uid ON public.users USING btree (firebase_uid);

CREATE INDEX idx_users_role ON public.users USING btree (role);

CREATE UNIQUE INDEX impact_records_donation_id_key ON public.impact_records USING btree (donation_id);

CREATE UNIQUE INDEX impact_records_pkey ON public.impact_records USING btree (id);

CREATE UNIQUE INDEX ngos_pkey ON public.ngos USING btree (id);

CREATE UNIQUE INDEX ngos_user_id_key ON public.ngos USING btree (user_id);

CREATE UNIQUE INDEX notifications_pkey ON public.notifications USING btree (id);

CREATE UNIQUE INDEX providers_pkey ON public.providers USING btree (id);

CREATE UNIQUE INDEX providers_user_id_key ON public.providers USING btree (user_id);

CREATE UNIQUE INDEX users_email_key ON public.users USING btree (email);

CREATE UNIQUE INDEX users_firebase_uid_key ON public.users USING btree (firebase_uid);

CREATE UNIQUE INDEX users_pkey ON public.users USING btree (id);

CREATE UNIQUE INDEX volunteers_pkey ON public.volunteers USING btree (id);

CREATE UNIQUE INDEX volunteers_user_id_key ON public.volunteers USING btree (user_id);

alter table "public"."claims" add constraint "claims_pkey" PRIMARY KEY using index "claims_pkey";

alter table "public"."deliveries" add constraint "deliveries_pkey" PRIMARY KEY using index "deliveries_pkey";

alter table "public"."donations" add constraint "donations_pkey" PRIMARY KEY using index "donations_pkey";

alter table "public"."feedback" add constraint "feedback_pkey" PRIMARY KEY using index "feedback_pkey";

alter table "public"."food_predictions" add constraint "food_predictions_pkey" PRIMARY KEY using index "food_predictions_pkey";

alter table "public"."impact_records" add constraint "impact_records_pkey" PRIMARY KEY using index "impact_records_pkey";

alter table "public"."ngos" add constraint "ngos_pkey" PRIMARY KEY using index "ngos_pkey";

alter table "public"."notifications" add constraint "notifications_pkey" PRIMARY KEY using index "notifications_pkey";

alter table "public"."providers" add constraint "providers_pkey" PRIMARY KEY using index "providers_pkey";

alter table "public"."users" add constraint "users_pkey" PRIMARY KEY using index "users_pkey";

alter table "public"."volunteers" add constraint "volunteers_pkey" PRIMARY KEY using index "volunteers_pkey";

alter table "public"."claims" add constraint "claims_donation_id_fkey" FOREIGN KEY (donation_id) REFERENCES public.donations(id) ON DELETE CASCADE not valid;

alter table "public"."claims" validate constraint "claims_donation_id_fkey";

alter table "public"."claims" add constraint "claims_ngo_id_fkey" FOREIGN KEY (ngo_id) REFERENCES public.ngos(id) ON DELETE CASCADE not valid;

alter table "public"."claims" validate constraint "claims_ngo_id_fkey";

alter table "public"."claims" add constraint "claims_requested_quantity_check" CHECK ((requested_quantity > (0)::numeric)) not valid;

alter table "public"."claims" validate constraint "claims_requested_quantity_check";

alter table "public"."claims" add constraint "claims_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'rejected'::text, 'cancelled'::text, 'completed'::text]))) not valid;

alter table "public"."claims" validate constraint "claims_status_check";

alter table "public"."deliveries" add constraint "deliveries_claim_id_fkey" FOREIGN KEY (claim_id) REFERENCES public.claims(id) ON DELETE CASCADE not valid;

alter table "public"."deliveries" validate constraint "deliveries_claim_id_fkey";

alter table "public"."deliveries" add constraint "deliveries_claim_id_key" UNIQUE using index "deliveries_claim_id_key";

alter table "public"."deliveries" add constraint "deliveries_donation_id_fkey" FOREIGN KEY (donation_id) REFERENCES public.donations(id) ON DELETE CASCADE not valid;

alter table "public"."deliveries" validate constraint "deliveries_donation_id_fkey";

alter table "public"."deliveries" add constraint "deliveries_donation_id_key" UNIQUE using index "deliveries_donation_id_key";

alter table "public"."deliveries" add constraint "deliveries_status_check" CHECK ((status = ANY (ARRAY['assigned'::text, 'accepted'::text, 'picked_up'::text, 'in_transit'::text, 'delivered'::text, 'failed'::text, 'cancelled'::text]))) not valid;

alter table "public"."deliveries" validate constraint "deliveries_status_check";

alter table "public"."deliveries" add constraint "deliveries_volunteer_id_fkey" FOREIGN KEY (volunteer_id) REFERENCES public.volunteers(id) ON DELETE SET NULL not valid;

alter table "public"."deliveries" validate constraint "deliveries_volunteer_id_fkey";

alter table "public"."donations" add constraint "donations_check" CHECK ((expiry_time > prepared_at)) not valid;

alter table "public"."donations" validate constraint "donations_check";

alter table "public"."donations" add constraint "donations_check1" CHECK ((pickup_deadline <= expiry_time)) not valid;

alter table "public"."donations" validate constraint "donations_check1";

alter table "public"."donations" add constraint "donations_prediction_id_fkey" FOREIGN KEY (prediction_id) REFERENCES public.food_predictions(id) ON DELETE SET NULL not valid;

alter table "public"."donations" validate constraint "donations_prediction_id_fkey";

alter table "public"."donations" add constraint "donations_provider_id_fkey" FOREIGN KEY (provider_id) REFERENCES public.providers(id) ON DELETE CASCADE not valid;

alter table "public"."donations" validate constraint "donations_provider_id_fkey";

alter table "public"."donations" add constraint "donations_quantity_check" CHECK ((quantity > (0)::numeric)) not valid;

alter table "public"."donations" validate constraint "donations_quantity_check";

alter table "public"."donations" add constraint "donations_servings_check" CHECK (((servings IS NULL) OR (servings >= 0))) not valid;

alter table "public"."donations" validate constraint "donations_servings_check";

alter table "public"."donations" add constraint "donations_status_check" CHECK ((status = ANY (ARRAY['available'::text, 'claimed'::text, 'pickup_assigned'::text, 'picked_up'::text, 'in_transit'::text, 'delivered'::text, 'completed'::text, 'expired'::text, 'cancelled'::text]))) not valid;

alter table "public"."donations" validate constraint "donations_status_check";

alter table "public"."donations" add constraint "donations_veg_type_check" CHECK (((veg_type IS NULL) OR (veg_type = ANY (ARRAY['vegetarian'::text, 'non_vegetarian'::text, 'vegan'::text, 'mixed'::text])))) not valid;

alter table "public"."donations" validate constraint "donations_veg_type_check";

alter table "public"."feedback" add constraint "feedback_donation_id_fkey" FOREIGN KEY (donation_id) REFERENCES public.donations(id) ON DELETE SET NULL not valid;

alter table "public"."feedback" validate constraint "feedback_donation_id_fkey";

alter table "public"."feedback" add constraint "feedback_feedback_type_check" CHECK (((feedback_type IS NULL) OR (feedback_type = ANY (ARRAY['provider'::text, 'ngo'::text, 'volunteer'::text, 'platform'::text, 'delivery'::text])))) not valid;

alter table "public"."feedback" validate constraint "feedback_feedback_type_check";

alter table "public"."feedback" add constraint "feedback_rating_check" CHECK (((rating IS NULL) OR ((rating >= 1) AND (rating <= 5)))) not valid;

alter table "public"."feedback" validate constraint "feedback_rating_check";

alter table "public"."feedback" add constraint "feedback_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE not valid;

alter table "public"."feedback" validate constraint "feedback_user_id_fkey";

alter table "public"."food_predictions" add constraint "food_predictions_confidence_score_check" CHECK (((confidence_score IS NULL) OR ((confidence_score >= (0)::numeric) AND (confidence_score <= (100)::numeric)))) not valid;

alter table "public"."food_predictions" validate constraint "food_predictions_confidence_score_check";

alter table "public"."food_predictions" add constraint "food_predictions_expected_customers_check" CHECK (((expected_customers IS NULL) OR (expected_customers >= 0))) not valid;

alter table "public"."food_predictions" validate constraint "food_predictions_expected_customers_check";

alter table "public"."food_predictions" add constraint "food_predictions_meal_type_check" CHECK (((meal_type IS NULL) OR (meal_type = ANY (ARRAY['breakfast'::text, 'lunch'::text, 'snacks'::text, 'dinner'::text, 'other'::text])))) not valid;

alter table "public"."food_predictions" validate constraint "food_predictions_meal_type_check";

alter table "public"."food_predictions" add constraint "food_predictions_planned_quantity_check" CHECK ((planned_quantity >= 0)) not valid;

alter table "public"."food_predictions" validate constraint "food_predictions_planned_quantity_check";

alter table "public"."food_predictions" add constraint "food_predictions_predicted_consumption_check" CHECK (((predicted_consumption IS NULL) OR (predicted_consumption >= (0)::numeric))) not valid;

alter table "public"."food_predictions" validate constraint "food_predictions_predicted_consumption_check";

alter table "public"."food_predictions" add constraint "food_predictions_predicted_surplus_check" CHECK (((predicted_surplus IS NULL) OR (predicted_surplus >= (0)::numeric))) not valid;

alter table "public"."food_predictions" validate constraint "food_predictions_predicted_surplus_check";

alter table "public"."food_predictions" add constraint "food_predictions_provider_id_fkey" FOREIGN KEY (provider_id) REFERENCES public.providers(id) ON DELETE CASCADE not valid;

alter table "public"."food_predictions" validate constraint "food_predictions_provider_id_fkey";

alter table "public"."food_predictions" add constraint "food_predictions_surplus_probability_check" CHECK (((surplus_probability IS NULL) OR ((surplus_probability >= (0)::numeric) AND (surplus_probability <= (100)::numeric)))) not valid;

alter table "public"."food_predictions" validate constraint "food_predictions_surplus_probability_check";

alter table "public"."impact_records" add constraint "impact_records_donation_id_fkey" FOREIGN KEY (donation_id) REFERENCES public.donations(id) ON DELETE CASCADE not valid;

alter table "public"."impact_records" validate constraint "impact_records_donation_id_fkey";

alter table "public"."impact_records" add constraint "impact_records_donation_id_key" UNIQUE using index "impact_records_donation_id_key";

alter table "public"."impact_records" add constraint "impact_records_estimated_co2_saved_check" CHECK (((estimated_co2_saved IS NULL) OR (estimated_co2_saved >= (0)::numeric))) not valid;

alter table "public"."impact_records" validate constraint "impact_records_estimated_co2_saved_check";

alter table "public"."impact_records" add constraint "impact_records_food_weight_kg_check" CHECK (((food_weight_kg IS NULL) OR (food_weight_kg >= (0)::numeric))) not valid;

alter table "public"."impact_records" validate constraint "impact_records_food_weight_kg_check";

alter table "public"."impact_records" add constraint "impact_records_meals_rescued_check" CHECK ((meals_rescued >= 0)) not valid;

alter table "public"."impact_records" validate constraint "impact_records_meals_rescued_check";

alter table "public"."impact_records" add constraint "impact_records_people_served_check" CHECK (((people_served IS NULL) OR (people_served >= 0))) not valid;

alter table "public"."impact_records" validate constraint "impact_records_people_served_check";

alter table "public"."ngos" add constraint "ngos_food_capacity_check" CHECK (((food_capacity IS NULL) OR (food_capacity >= 0))) not valid;

alter table "public"."ngos" validate constraint "ngos_food_capacity_check";

alter table "public"."ngos" add constraint "ngos_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE not valid;

alter table "public"."ngos" validate constraint "ngos_user_id_fkey";

alter table "public"."ngos" add constraint "ngos_user_id_key" UNIQUE using index "ngos_user_id_key";

alter table "public"."notifications" add constraint "notifications_related_donation_id_fkey" FOREIGN KEY (related_donation_id) REFERENCES public.donations(id) ON DELETE SET NULL not valid;

alter table "public"."notifications" validate constraint "notifications_related_donation_id_fkey";

alter table "public"."notifications" add constraint "notifications_type_check" CHECK (((type IS NULL) OR (type = ANY (ARRAY['new_nearby_donation'::text, 'claim_submitted'::text, 'claim_accepted'::text, 'claim_rejected'::text, 'donation_claimed'::text, 'volunteer_assigned'::text, 'pickup_reminder'::text, 'delivery_completed'::text, 'delivery_failed'::text, 'donation_expiring_soon'::text, 'donation_cancelled'::text])))) not valid;

alter table "public"."notifications" validate constraint "notifications_type_check";

alter table "public"."notifications" add constraint "notifications_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE not valid;

alter table "public"."notifications" validate constraint "notifications_user_id_fkey";

alter table "public"."providers" add constraint "providers_organization_type_check" CHECK ((organization_type = ANY (ARRAY['restaurant'::text, 'hotel'::text, 'hostel'::text, 'canteen'::text, 'event_organizer'::text, 'household'::text, 'other'::text]))) not valid;

alter table "public"."providers" validate constraint "providers_organization_type_check";

alter table "public"."providers" add constraint "providers_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE not valid;

alter table "public"."providers" validate constraint "providers_user_id_fkey";

alter table "public"."providers" add constraint "providers_user_id_key" UNIQUE using index "providers_user_id_key";

alter table "public"."users" add constraint "users_email_key" UNIQUE using index "users_email_key";

alter table "public"."users" add constraint "users_firebase_uid_key" UNIQUE using index "users_firebase_uid_key";

alter table "public"."users" add constraint "users_role_check" CHECK ((role = ANY (ARRAY['provider'::text, 'ngo'::text, 'volunteer'::text, 'admin'::text]))) not valid;

alter table "public"."users" validate constraint "users_role_check";

alter table "public"."volunteers" add constraint "volunteers_availability_status_check" CHECK ((availability_status = ANY (ARRAY['available'::text, 'busy'::text, 'offline'::text]))) not valid;

alter table "public"."volunteers" validate constraint "volunteers_availability_status_check";

alter table "public"."volunteers" add constraint "volunteers_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE not valid;

alter table "public"."volunteers" validate constraint "volunteers_user_id_fkey";

alter table "public"."volunteers" add constraint "volunteers_user_id_key" UNIQUE using index "volunteers_user_id_key";

alter table "public"."volunteers" add constraint "volunteers_vehicle_type_check" CHECK (((vehicle_type IS NULL) OR (vehicle_type = ANY (ARRAY['walking'::text, 'bike'::text, 'car'::text, 'other'::text])))) not valid;

alter table "public"."volunteers" validate constraint "volunteers_vehicle_type_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.expire_stale_donations()
 RETURNS void
 LANGUAGE sql
AS $function$
    UPDATE public.donations
    SET status = 'expired'
    WHERE status = 'available'
      AND expiry_time < NOW();
$function$
;

CREATE OR REPLACE FUNCTION public.handle_claim_acceptance()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.status = 'accepted' AND OLD.status IS DISTINCT FROM 'accepted' THEN

        -- Reject all other pending claims on the same donation
        UPDATE public.claims
        SET status = 'rejected',
            rejected_at = NOW(),
            rejection_reason = COALESCE(rejection_reason, 'Another NGO claim was accepted first')
        WHERE donation_id = NEW.donation_id
          AND id <> NEW.id
          AND status = 'pending';

        -- Move the donation to 'claimed'
        UPDATE public.donations
        SET status = 'claimed'
        WHERE id = NEW.donation_id
          AND status = 'available';

        NEW.accepted_at := COALESCE(NEW.accepted_at, NOW());
    END IF;

    IF NEW.status = 'rejected' AND OLD.status IS DISTINCT FROM 'rejected' THEN
        NEW.rejected_at := COALESCE(NEW.rejected_at, NOW());
    END IF;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.record_delivery_impact()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_donation RECORD;
    v_food_weight_kg NUMERIC(10,2);
    v_meals INTEGER;
BEGIN
    IF NEW.status = 'delivered' AND OLD.status IS DISTINCT FROM 'delivered' THEN

        SELECT quantity, unit, servings
        INTO v_donation
        FROM public.donations
        WHERE id = NEW.donation_id;

        v_meals := COALESCE(v_donation.servings, FLOOR(v_donation.quantity)::INTEGER);

        v_food_weight_kg := CASE
            WHEN v_donation.unit ILIKE 'kg' THEN v_donation.quantity
            ELSE NULL
        END;

        INSERT INTO public.impact_records (
            donation_id, meals_rescued, food_weight_kg, estimated_co2_saved
        )
        VALUES (
            NEW.donation_id,
            GREATEST(v_meals, 0),
            v_food_weight_kg,
            CASE WHEN v_food_weight_kg IS NOT NULL THEN v_food_weight_kg * 2.5 ELSE NULL END
        )
        ON CONFLICT (donation_id) DO UPDATE
        SET meals_rescued = EXCLUDED.meals_rescued,
            food_weight_kg = EXCLUDED.food_weight_kg,
            estimated_co2_saved = EXCLUDED.estimated_co2_saved;

        -- Also mark the donation itself completed
        UPDATE public.donations
        SET status = 'completed'
        WHERE id = NEW.donation_id
          AND status IN ('delivered', 'in_transit', 'picked_up', 'pickup_assigned', 'claimed');
    END IF;

    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$function$
;

create or replace view "public"."v_prediction_accuracy" as  SELECT fp.id AS prediction_id,
    fp.provider_id,
    fp.prediction_date,
    fp.meal_type,
    fp.predicted_surplus,
    fp.surplus_probability,
    fp.confidence_score,
    COALESCE(sum(d.quantity), (0)::numeric) AS actual_surplus,
    count(d.id) AS donations_created
   FROM (public.food_predictions fp
     LEFT JOIN public.donations d ON ((d.prediction_id = fp.id)))
  GROUP BY fp.id, fp.provider_id, fp.prediction_date, fp.meal_type, fp.predicted_surplus, fp.surplus_probability, fp.confidence_score;


CREATE OR REPLACE FUNCTION public.validate_claim_quantity()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_donation_quantity NUMERIC(10,2);
BEGIN
    SELECT quantity INTO v_donation_quantity
    FROM public.donations
    WHERE id = NEW.donation_id;

    IF v_donation_quantity IS NULL THEN
        RAISE EXCEPTION 'Donation % not found', NEW.donation_id;
    END IF;

    IF NEW.requested_quantity > v_donation_quantity THEN
        RAISE EXCEPTION
            'Requested quantity (%) exceeds available donation quantity (%)',
            NEW.requested_quantity, v_donation_quantity;
    END IF;

    RETURN NEW;
END;
$function$
;

grant delete on table "public"."claims" to "anon";

grant insert on table "public"."claims" to "anon";

grant references on table "public"."claims" to "anon";

grant select on table "public"."claims" to "anon";

grant trigger on table "public"."claims" to "anon";

grant truncate on table "public"."claims" to "anon";

grant update on table "public"."claims" to "anon";

grant delete on table "public"."claims" to "authenticated";

grant insert on table "public"."claims" to "authenticated";

grant references on table "public"."claims" to "authenticated";

grant select on table "public"."claims" to "authenticated";

grant trigger on table "public"."claims" to "authenticated";

grant truncate on table "public"."claims" to "authenticated";

grant update on table "public"."claims" to "authenticated";

grant delete on table "public"."claims" to "service_role";

grant insert on table "public"."claims" to "service_role";

grant references on table "public"."claims" to "service_role";

grant select on table "public"."claims" to "service_role";

grant trigger on table "public"."claims" to "service_role";

grant truncate on table "public"."claims" to "service_role";

grant update on table "public"."claims" to "service_role";

grant delete on table "public"."deliveries" to "anon";

grant insert on table "public"."deliveries" to "anon";

grant references on table "public"."deliveries" to "anon";

grant select on table "public"."deliveries" to "anon";

grant trigger on table "public"."deliveries" to "anon";

grant truncate on table "public"."deliveries" to "anon";

grant update on table "public"."deliveries" to "anon";

grant delete on table "public"."deliveries" to "authenticated";

grant insert on table "public"."deliveries" to "authenticated";

grant references on table "public"."deliveries" to "authenticated";

grant select on table "public"."deliveries" to "authenticated";

grant trigger on table "public"."deliveries" to "authenticated";

grant truncate on table "public"."deliveries" to "authenticated";

grant update on table "public"."deliveries" to "authenticated";

grant delete on table "public"."deliveries" to "service_role";

grant insert on table "public"."deliveries" to "service_role";

grant references on table "public"."deliveries" to "service_role";

grant select on table "public"."deliveries" to "service_role";

grant trigger on table "public"."deliveries" to "service_role";

grant truncate on table "public"."deliveries" to "service_role";

grant update on table "public"."deliveries" to "service_role";

grant delete on table "public"."donations" to "anon";

grant insert on table "public"."donations" to "anon";

grant references on table "public"."donations" to "anon";

grant select on table "public"."donations" to "anon";

grant trigger on table "public"."donations" to "anon";

grant truncate on table "public"."donations" to "anon";

grant update on table "public"."donations" to "anon";

grant delete on table "public"."donations" to "authenticated";

grant insert on table "public"."donations" to "authenticated";

grant references on table "public"."donations" to "authenticated";

grant select on table "public"."donations" to "authenticated";

grant trigger on table "public"."donations" to "authenticated";

grant truncate on table "public"."donations" to "authenticated";

grant update on table "public"."donations" to "authenticated";

grant delete on table "public"."donations" to "service_role";

grant insert on table "public"."donations" to "service_role";

grant references on table "public"."donations" to "service_role";

grant select on table "public"."donations" to "service_role";

grant trigger on table "public"."donations" to "service_role";

grant truncate on table "public"."donations" to "service_role";

grant update on table "public"."donations" to "service_role";

grant delete on table "public"."feedback" to "anon";

grant insert on table "public"."feedback" to "anon";

grant references on table "public"."feedback" to "anon";

grant select on table "public"."feedback" to "anon";

grant trigger on table "public"."feedback" to "anon";

grant truncate on table "public"."feedback" to "anon";

grant update on table "public"."feedback" to "anon";

grant delete on table "public"."feedback" to "authenticated";

grant insert on table "public"."feedback" to "authenticated";

grant references on table "public"."feedback" to "authenticated";

grant select on table "public"."feedback" to "authenticated";

grant trigger on table "public"."feedback" to "authenticated";

grant truncate on table "public"."feedback" to "authenticated";

grant update on table "public"."feedback" to "authenticated";

grant delete on table "public"."feedback" to "service_role";

grant insert on table "public"."feedback" to "service_role";

grant references on table "public"."feedback" to "service_role";

grant select on table "public"."feedback" to "service_role";

grant trigger on table "public"."feedback" to "service_role";

grant truncate on table "public"."feedback" to "service_role";

grant update on table "public"."feedback" to "service_role";

grant delete on table "public"."food_predictions" to "anon";

grant insert on table "public"."food_predictions" to "anon";

grant references on table "public"."food_predictions" to "anon";

grant select on table "public"."food_predictions" to "anon";

grant trigger on table "public"."food_predictions" to "anon";

grant truncate on table "public"."food_predictions" to "anon";

grant update on table "public"."food_predictions" to "anon";

grant delete on table "public"."food_predictions" to "authenticated";

grant insert on table "public"."food_predictions" to "authenticated";

grant references on table "public"."food_predictions" to "authenticated";

grant select on table "public"."food_predictions" to "authenticated";

grant trigger on table "public"."food_predictions" to "authenticated";

grant truncate on table "public"."food_predictions" to "authenticated";

grant update on table "public"."food_predictions" to "authenticated";

grant delete on table "public"."food_predictions" to "service_role";

grant insert on table "public"."food_predictions" to "service_role";

grant references on table "public"."food_predictions" to "service_role";

grant select on table "public"."food_predictions" to "service_role";

grant trigger on table "public"."food_predictions" to "service_role";

grant truncate on table "public"."food_predictions" to "service_role";

grant update on table "public"."food_predictions" to "service_role";

grant delete on table "public"."impact_records" to "anon";

grant insert on table "public"."impact_records" to "anon";

grant references on table "public"."impact_records" to "anon";

grant select on table "public"."impact_records" to "anon";

grant trigger on table "public"."impact_records" to "anon";

grant truncate on table "public"."impact_records" to "anon";

grant update on table "public"."impact_records" to "anon";

grant delete on table "public"."impact_records" to "authenticated";

grant insert on table "public"."impact_records" to "authenticated";

grant references on table "public"."impact_records" to "authenticated";

grant select on table "public"."impact_records" to "authenticated";

grant trigger on table "public"."impact_records" to "authenticated";

grant truncate on table "public"."impact_records" to "authenticated";

grant update on table "public"."impact_records" to "authenticated";

grant delete on table "public"."impact_records" to "service_role";

grant insert on table "public"."impact_records" to "service_role";

grant references on table "public"."impact_records" to "service_role";

grant select on table "public"."impact_records" to "service_role";

grant trigger on table "public"."impact_records" to "service_role";

grant truncate on table "public"."impact_records" to "service_role";

grant update on table "public"."impact_records" to "service_role";

grant delete on table "public"."ngos" to "anon";

grant insert on table "public"."ngos" to "anon";

grant references on table "public"."ngos" to "anon";

grant select on table "public"."ngos" to "anon";

grant trigger on table "public"."ngos" to "anon";

grant truncate on table "public"."ngos" to "anon";

grant update on table "public"."ngos" to "anon";

grant delete on table "public"."ngos" to "authenticated";

grant insert on table "public"."ngos" to "authenticated";

grant references on table "public"."ngos" to "authenticated";

grant select on table "public"."ngos" to "authenticated";

grant trigger on table "public"."ngos" to "authenticated";

grant truncate on table "public"."ngos" to "authenticated";

grant update on table "public"."ngos" to "authenticated";

grant delete on table "public"."ngos" to "service_role";

grant insert on table "public"."ngos" to "service_role";

grant references on table "public"."ngos" to "service_role";

grant select on table "public"."ngos" to "service_role";

grant trigger on table "public"."ngos" to "service_role";

grant truncate on table "public"."ngos" to "service_role";

grant update on table "public"."ngos" to "service_role";

grant delete on table "public"."notifications" to "anon";

grant insert on table "public"."notifications" to "anon";

grant references on table "public"."notifications" to "anon";

grant select on table "public"."notifications" to "anon";

grant trigger on table "public"."notifications" to "anon";

grant truncate on table "public"."notifications" to "anon";

grant update on table "public"."notifications" to "anon";

grant delete on table "public"."notifications" to "authenticated";

grant insert on table "public"."notifications" to "authenticated";

grant references on table "public"."notifications" to "authenticated";

grant select on table "public"."notifications" to "authenticated";

grant trigger on table "public"."notifications" to "authenticated";

grant truncate on table "public"."notifications" to "authenticated";

grant update on table "public"."notifications" to "authenticated";

grant delete on table "public"."notifications" to "service_role";

grant insert on table "public"."notifications" to "service_role";

grant references on table "public"."notifications" to "service_role";

grant select on table "public"."notifications" to "service_role";

grant trigger on table "public"."notifications" to "service_role";

grant truncate on table "public"."notifications" to "service_role";

grant update on table "public"."notifications" to "service_role";

grant delete on table "public"."providers" to "anon";

grant insert on table "public"."providers" to "anon";

grant references on table "public"."providers" to "anon";

grant select on table "public"."providers" to "anon";

grant trigger on table "public"."providers" to "anon";

grant truncate on table "public"."providers" to "anon";

grant update on table "public"."providers" to "anon";

grant delete on table "public"."providers" to "authenticated";

grant insert on table "public"."providers" to "authenticated";

grant references on table "public"."providers" to "authenticated";

grant select on table "public"."providers" to "authenticated";

grant trigger on table "public"."providers" to "authenticated";

grant truncate on table "public"."providers" to "authenticated";

grant update on table "public"."providers" to "authenticated";

grant delete on table "public"."providers" to "service_role";

grant insert on table "public"."providers" to "service_role";

grant references on table "public"."providers" to "service_role";

grant select on table "public"."providers" to "service_role";

grant trigger on table "public"."providers" to "service_role";

grant truncate on table "public"."providers" to "service_role";

grant update on table "public"."providers" to "service_role";

grant delete on table "public"."users" to "anon";

grant insert on table "public"."users" to "anon";

grant references on table "public"."users" to "anon";

grant select on table "public"."users" to "anon";

grant trigger on table "public"."users" to "anon";

grant truncate on table "public"."users" to "anon";

grant update on table "public"."users" to "anon";

grant delete on table "public"."users" to "authenticated";

grant insert on table "public"."users" to "authenticated";

grant references on table "public"."users" to "authenticated";

grant select on table "public"."users" to "authenticated";

grant trigger on table "public"."users" to "authenticated";

grant truncate on table "public"."users" to "authenticated";

grant update on table "public"."users" to "authenticated";

grant delete on table "public"."users" to "service_role";

grant insert on table "public"."users" to "service_role";

grant references on table "public"."users" to "service_role";

grant select on table "public"."users" to "service_role";

grant trigger on table "public"."users" to "service_role";

grant truncate on table "public"."users" to "service_role";

grant update on table "public"."users" to "service_role";

grant delete on table "public"."volunteers" to "anon";

grant insert on table "public"."volunteers" to "anon";

grant references on table "public"."volunteers" to "anon";

grant select on table "public"."volunteers" to "anon";

grant trigger on table "public"."volunteers" to "anon";

grant truncate on table "public"."volunteers" to "anon";

grant update on table "public"."volunteers" to "anon";

grant delete on table "public"."volunteers" to "authenticated";

grant insert on table "public"."volunteers" to "authenticated";

grant references on table "public"."volunteers" to "authenticated";

grant select on table "public"."volunteers" to "authenticated";

grant trigger on table "public"."volunteers" to "authenticated";

grant truncate on table "public"."volunteers" to "authenticated";

grant update on table "public"."volunteers" to "authenticated";

grant delete on table "public"."volunteers" to "service_role";

grant insert on table "public"."volunteers" to "service_role";

grant references on table "public"."volunteers" to "service_role";

grant select on table "public"."volunteers" to "service_role";

grant trigger on table "public"."volunteers" to "service_role";

grant truncate on table "public"."volunteers" to "service_role";

grant update on table "public"."volunteers" to "service_role";


  create policy "public_view_available_donations"
  on "public"."donations"
  as permissive
  for select
  to public
using (((status = 'available'::text) AND (expiry_time > now())));



  create policy "Allow anonymous insert ngos"
  on "public"."ngos"
  as permissive
  for insert
  to anon
with check (true);



  create policy "Allow anonymous select ngos"
  on "public"."ngos"
  as permissive
  for select
  to anon
using (true);



  create policy "Allow anonymous update ngos"
  on "public"."ngos"
  as permissive
  for update
  to anon
using (true)
with check (true);



  create policy "public_view_verified_ngos"
  on "public"."ngos"
  as permissive
  for select
  to public
using ((verified = true));



  create policy "Allow anonymous insert providers"
  on "public"."providers"
  as permissive
  for insert
  to anon
with check (true);



  create policy "Allow anonymous select providers"
  on "public"."providers"
  as permissive
  for select
  to anon
using (true);



  create policy "Allow anonymous update providers"
  on "public"."providers"
  as permissive
  for update
  to anon
using (true)
with check (true);



  create policy "public_view_verified_providers"
  on "public"."providers"
  as permissive
  for select
  to public
using ((verified = true));



  create policy "Allow anonymous insert users"
  on "public"."users"
  as permissive
  for insert
  to anon
with check (true);



  create policy "Allow anonymous select users"
  on "public"."users"
  as permissive
  for select
  to anon
using (true);



  create policy "Allow anonymous update users"
  on "public"."users"
  as permissive
  for update
  to anon
using (true)
with check (true);



  create policy "Allow anonymous insert volunteers"
  on "public"."volunteers"
  as permissive
  for insert
  to anon
with check (true);



  create policy "Allow anonymous select volunteers"
  on "public"."volunteers"
  as permissive
  for select
  to anon
using (true);



  create policy "Allow anonymous update volunteers"
  on "public"."volunteers"
  as permissive
  for update
  to anon
using (true)
with check (true);


CREATE TRIGGER trg_handle_claim_acceptance BEFORE UPDATE OF status ON public.claims FOR EACH ROW EXECUTE FUNCTION public.handle_claim_acceptance();

CREATE TRIGGER trg_validate_claim_quantity BEFORE INSERT OR UPDATE OF requested_quantity ON public.claims FOR EACH ROW EXECUTE FUNCTION public.validate_claim_quantity();

CREATE TRIGGER update_claims_updated_at BEFORE UPDATE ON public.claims FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER trg_record_delivery_impact AFTER UPDATE OF status ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.record_delivery_impact();

CREATE TRIGGER update_deliveries_updated_at BEFORE UPDATE ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_donations_updated_at BEFORE UPDATE ON public.donations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_ngos_updated_at BEFORE UPDATE ON public.ngos FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_providers_updated_at BEFORE UPDATE ON public.providers FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_volunteers_updated_at BEFORE UPDATE ON public.volunteers FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


