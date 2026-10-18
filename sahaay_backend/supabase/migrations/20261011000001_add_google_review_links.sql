-- Optional official Google Maps listing links for providers and NGOs.
alter table public.providers add column if not exists google_review_url text;
alter table public.ngos add column if not exists google_review_url text;
comment on column public.providers.google_review_url is 'Owner-supplied official Google Maps listing/review link.';
comment on column public.ngos.google_review_url is 'Owner-supplied official Google Maps listing/review link.';
