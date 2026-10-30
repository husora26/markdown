-- =============================================================================
-- HUSORA · Migration 0500 · Buchungsquellen und Buchungen
-- =============================================================================

-- -----------------------------------------------------------------------------
-- booking_sources: Channel Manager, Airbnb, Booking.com, iCal …
-- Zugangsdaten NIE im Klartext: credentials_reference verweist auf Supabase Vault.
-- -----------------------------------------------------------------------------
create table public.booking_sources (
  id                     uuid primary key default gen_random_uuid(),
  organization_id        uuid not null references public.organizations(id) on delete cascade,
  name                   text not null,
  provider               text not null check (provider in ('airbnb', 'booking_com', 'vrbo', 'ical', 'channel_manager', 'direct', 'other')),
  api_endpoint           text,
  credentials_reference  text,
  active                 boolean not null default true,
  last_synced_at         timestamptz,
  created_by             uuid references public.users(id) on delete set null,
  updated_by             uuid references public.users(id) on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (organization_id, id),
  check (credentials_reference is null or credentials_reference ~ '^vault:')
);
comment on column public.booking_sources.credentials_reference is 'Verweis auf ein Secret in Supabase Vault, Format vault:<secret_name>. Niemals Passwörter oder API-Keys speichern.';
create index booking_sources_org_idx on public.booking_sources (organization_id) where active;
create trigger booking_sources_set_updated_at before update on public.booking_sources
  for each row execute function private.set_updated_at();
create trigger booking_sources_set_actor before insert or update on public.booking_sources
  for each row execute function private.set_actor_columns();

-- -----------------------------------------------------------------------------
-- bookings: Gästebuchungen und Eigennutzung
-- -----------------------------------------------------------------------------
create table public.bookings (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references public.organizations(id) on delete cascade,
  property_id          uuid not null,
  booking_source_id    uuid,
  external_booking_id  text,
  source               text not null default 'direct' check (source in ('direct', 'owner', 'airbnb', 'booking_com', 'vrbo', 'ical', 'channel_manager', 'other')),
  guest_first_name     text,
  guest_last_name      text,
  guest_email          text,
  guest_phone          text,
  check_in             timestamptz not null,
  check_out            timestamptz not null,
  guest_count          integer check (guest_count >= 0),
  status               text not null default 'confirmed' check (status in ('inquiry', 'confirmed', 'cancelled', 'completed')),
  notes                text,
  created_by           uuid references public.users(id) on delete set null,
  updated_by           uuid references public.users(id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, booking_source_id) references public.booking_sources (organization_id, id) on delete set null (booking_source_id),
  check (check_out > check_in),
  -- keine Doppelbuchung: bestätigte Aufenthalte desselben Hauses dürfen sich nicht überschneiden
  constraint bookings_no_overlap exclude using gist (
    property_id with =,
    tstzrange(check_in, check_out, '[)') with &&
  ) where (status = 'confirmed')
);
comment on table public.bookings is 'Buchungen inkl. Eigennutzung (source = owner). Überschneidungen bestätigter Buchungen sind ausgeschlossen.';

-- Idempotenter Import aus externen Kanälen
create unique index bookings_external_unique_idx on public.bookings (organization_id, source, external_booking_id)
  where external_booking_id is not null;
create index bookings_org_idx on public.bookings (organization_id, status);
create index bookings_property_check_in_idx on public.bookings (property_id, check_in);
create index bookings_property_check_out_idx on public.bookings (property_id, check_out);
create index bookings_check_in_idx on public.bookings (check_in);
create index bookings_check_out_idx on public.bookings (check_out);
create index bookings_created_at_idx on public.bookings (created_at);
create index bookings_source_idx on public.bookings (booking_source_id) where booking_source_id is not null;

create trigger bookings_set_updated_at before update on public.bookings
  for each row execute function private.set_updated_at();
create trigger bookings_set_actor before insert or update on public.bookings
  for each row execute function private.set_actor_columns();
