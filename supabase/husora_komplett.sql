-- =============================================================================
-- HUSORA · Komplette Datenbank in einer Datei (für den Supabase SQL Editor)
-- =============================================================================
-- Inhalt: alle Migrationen aus supabase/migrations in der richtigen Reihenfolge,
-- OHNE Testdaten. Einmalig in einem NEUEN, leeren Supabase-Projekt ausführen:
--   Dashboard → SQL Editor → New query → Inhalt einfügen → Run
-- Danach in der App: Einstellungen → Daten & App → Cloud-Speicher (Supabase).
-- Datei wird erzeugt – Änderungen bitte in supabase/migrations vornehmen.


-- >>> 20261030000100_extensions_and_utilities.sql
-- =============================================================================
-- HUSORA · Migration 0100 · Erweiterungen, privates Schema, Hilfsfunktionen
-- =============================================================================
-- Das Schema "private" wird NICHT über die Supabase-API veröffentlicht.
-- Dort liegen Hilfsfunktionen für RLS, Trigger und interne Logik.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists btree_gist with schema extensions;

create schema if not exists private;
comment on schema private is 'Interne Husora-Funktionen (RLS-Helfer, Trigger). Nicht über PostgREST veröffentlicht.';

grant usage on schema private to authenticated, service_role;
revoke all on schema private from anon;

-- updated_at bei jeder Änderung automatisch setzen
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Fortlaufende Nummern für Serviceaufträge, Angebote und interne Belege
create sequence if not exists public.service_order_number_seq start 1000;

-- >>> 20261030000200_tenancy.sql
-- =============================================================================
-- HUSORA · Migration 0200 · Benutzer, Organisationen, Mitgliedschaften
-- =============================================================================

-- -----------------------------------------------------------------------------
-- users: Profil zu jedem Supabase-Auth-Benutzer
-- -----------------------------------------------------------------------------
create table public.users (
  id              uuid primary key default gen_random_uuid(),
  auth_user_id    uuid not null unique references auth.users(id) on delete cascade,
  email           text,
  first_name      text,
  last_name       text,
  phone           text,
  avatar_url      text,
  language        text not null default 'de' check (language in ('de', 'en', 'sv')),
  timezone        text not null default 'Europe/Berlin',
  is_super_admin  boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on table public.users is 'Anwendungsprofil je Supabase-Auth-Benutzer. Wird beim Registrieren automatisch angelegt.';
comment on column public.users.is_super_admin is 'Interne Husora-Verwaltung. Nur per service_role setzbar.';

create index users_email_idx on public.users (lower(email));
create trigger users_set_updated_at before update on public.users
  for each row execute function private.set_updated_at();

-- ID des angemeldeten Benutzers (public.users.id)
create or replace function private.current_user_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.id from public.users u where u.auth_user_id = auth.uid()
$$;

create or replace function private.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select u.is_super_admin from public.users u where u.auth_user_id = auth.uid()), false)
$$;

-- created_by / updated_by automatisch aus dem angemeldeten Benutzer setzen
create or replace function private.set_actor_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.current_user_id();
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, actor);
  else
    new.created_by := old.created_by;
  end if;
  new.updated_by := coalesce(actor, new.updated_by);
  return new;
end;
$$;

-- Profil beim Registrieren in Supabase Auth anlegen
create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.users (auth_user_id, email, first_name, last_name, language)
  values (
    new.id,
    new.email,
    nullif(new.raw_user_meta_data->>'first_name', ''),
    nullif(new.raw_user_meta_data->>'last_name', ''),
    coalesce(nullif(new.raw_user_meta_data->>'language', ''), 'de')
  )
  on conflict (auth_user_id) do update set email = excluded.email;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_auth_user();

-- E-Mail-Änderungen aus Auth übernehmen
create or replace function private.handle_auth_user_email_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.users set email = new.email where auth_user_id = new.id;
  return new;
end;
$$;

create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row when (old.email is distinct from new.email)
  execute function private.handle_auth_user_email_change();

-- is_super_admin darf nicht vom Benutzer selbst gesetzt werden.
-- Bewusst security invoker: current_user ist dann die aufrufende Rolle (authenticated),
-- bei Migrationen, SQL-Editor und security-definer-Funktionen dagegen postgres.
create or replace function private.protect_user_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and current_user not in ('postgres', 'supabase_admin') then
    new.is_super_admin := old.is_super_admin;
    new.auth_user_id := old.auth_user_id;
  end if;
  return new;
end;
$$;

create trigger users_protect_columns before update on public.users
  for each row execute function private.protect_user_columns();

-- -----------------------------------------------------------------------------
-- organizations: Mandanten (Vermieter, Verwalter, Eigentümergemeinschaften)
-- -----------------------------------------------------------------------------
create table public.organizations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  legal_name  text,
  country     text check (country is null or country ~ '^[A-Z]{2}$'),
  currency    text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  timezone    text not null default 'Europe/Berlin',
  email       text,
  phone       text,
  website     text,
  settings    jsonb not null default '{}'::jsonb,
  created_by  uuid references public.users(id) on delete set null,
  updated_by  uuid references public.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on column public.organizations.settings is 'Konfiguration, z. B. {"partner_ranking": {"distance": 40, "availability": 20, "rating": 25, "price": 15}}';

create index organizations_created_at_idx on public.organizations (created_at);
create trigger organizations_set_updated_at before update on public.organizations
  for each row execute function private.set_updated_at();
create trigger organizations_set_actor before insert or update on public.organizations
  for each row execute function private.set_actor_columns();

-- -----------------------------------------------------------------------------
-- organization_members: Rollen je Organisation
-- -----------------------------------------------------------------------------
create table public.organization_members (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  user_id          uuid not null references public.users(id) on delete cascade,
  role             text not null check (role in ('owner', 'admin', 'property_manager', 'service_manager', 'service_partner', 'cleaner', 'viewer')),
  status           text not null default 'active' check (status in ('invited', 'active', 'suspended')),
  invited_by       uuid references public.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (organization_id, user_id)
);
comment on column public.organization_members.role is
  'owner = Eigentümer (sieht nur eigene Häuser) · admin = alle Daten der Organisation · property_manager / service_manager = operative Verwaltung · service_partner = nur zugewiesene Aufträge · cleaner = nur zugewiesene Aufgaben · viewer = nur lesen';

create index organization_members_user_idx on public.organization_members (user_id);
create index organization_members_org_role_idx on public.organization_members (organization_id, role) where status = 'active';
create trigger organization_members_set_updated_at before update on public.organization_members
  for each row execute function private.set_updated_at();

-- Wer eine Organisation anlegt, wird automatisch deren Admin
create or replace function private.add_creator_as_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.current_user_id();
begin
  if actor is not null then
    insert into public.organization_members (organization_id, user_id, role, status)
    values (new.id, actor, 'admin', 'active')
    on conflict (organization_id, user_id) do nothing;
  end if;
  return new;
end;
$$;

create trigger organizations_add_creator after insert on public.organizations
  for each row execute function private.add_creator_as_admin();

-- -----------------------------------------------------------------------------
-- Rollen-Helfer für RLS (security definer, damit Policies nicht rekursiv werden)
-- -----------------------------------------------------------------------------
create or replace function private.org_role(p_organization_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select m.role
  from public.organization_members m
  join public.users u on u.id = m.user_id
  where m.organization_id = p_organization_id
    and u.auth_user_id = auth.uid()
    and m.status = 'active'
$$;

create or replace function private.is_org_member(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_super_admin() or private.org_role(p_organization_id) is not null
$$;

create or replace function private.has_org_role(p_organization_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_super_admin() or coalesce(private.org_role(p_organization_id) = any (p_roles), false)
$$;

-- admin
create or replace function private.is_org_admin(p_organization_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select private.has_org_role(p_organization_id, array['admin']) $$;

-- operative Verwaltung: admin, property_manager, service_manager
create or replace function private.is_org_staff(p_organization_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select private.has_org_role(p_organization_id, array['admin', 'property_manager', 'service_manager']) $$;

-- darf alle Daten der Organisation lesen: Verwaltung und viewer
create or replace function private.can_read_org(p_organization_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select private.has_org_role(p_organization_id, array['admin', 'property_manager', 'service_manager', 'viewer']) $$;

-- Organisationen, in denen der Benutzer aktiv Mitglied ist
create or replace function private.my_organization_ids()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select m.organization_id
  from public.organization_members m
  join public.users u on u.id = m.user_id
  where u.auth_user_id = auth.uid() and m.status = 'active'
$$;

-- >>> 20261030000300_properties.sql
-- =============================================================================
-- HUSORA · Migration 0300 · Ferienhäuser, Zuordnungen, Ausstattung
-- =============================================================================

create table public.properties (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  name             text not null check (length(trim(name)) > 0),
  description      text,
  street           text,
  house_number     text,
  postal_code      text,
  city             text,
  region           text,
  country          text check (country is null or country ~ '^[A-Z]{2}$'),
  latitude         numeric(9, 6) check (latitude between -90 and 90),
  longitude        numeric(9, 6) check (longitude between -180 and 180),
  property_type    text check (property_type is null or property_type in ('holiday_home', 'cabin', 'apartment', 'villa', 'farmhouse', 'other')),
  living_area_m2   numeric(8, 2) check (living_area_m2 >= 0),
  land_area_m2     numeric(10, 2) check (land_area_m2 >= 0),
  bedrooms         integer check (bedrooms >= 0),
  bathrooms        integer check (bathrooms >= 0),
  max_guests       integer check (max_guests >= 0),
  year_built       integer check (year_built between 1600 and 2100),
  status           text not null default 'active' check (status in ('active', 'inactive', 'maintenance', 'archived')),
  owner_user_id    uuid references public.users(id) on delete set null,
  created_by       uuid references public.users(id) on delete set null,
  updated_by       uuid references public.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- Ziel für zusammengesetzte Fremdschlüssel: Kindzeilen müssen zur selben Organisation gehören
  unique (organization_id, id)
);
comment on table public.properties is 'Ferienhäuser einer Organisation.';
comment on column public.properties.owner_user_id is 'Eigentümer des Hauses (Rolle owner sieht nur eigene Häuser).';

create index properties_org_status_idx on public.properties (organization_id, status);
create index properties_owner_idx on public.properties (owner_user_id) where owner_user_id is not null;
create index properties_org_region_idx on public.properties (organization_id, region);
create index properties_created_at_idx on public.properties (created_at);
create index properties_geo_idx on public.properties (latitude, longitude) where latitude is not null and longitude is not null;

create trigger properties_set_updated_at before update on public.properties
  for each row execute function private.set_updated_at();
create trigger properties_set_actor before insert or update on public.properties
  for each row execute function private.set_actor_columns();

-- -----------------------------------------------------------------------------
-- property_users: zusätzliche Personen je Haus (Miteigentümer, Hausmeister …)
-- -----------------------------------------------------------------------------
create table public.property_users (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  user_id      uuid not null references public.users(id) on delete cascade,
  role         text not null check (role in ('owner', 'manager', 'staff', 'viewer')),
  created_at   timestamptz not null default now(),
  unique (property_id, user_id)
);
create index property_users_user_idx on public.property_users (user_id);

-- -----------------------------------------------------------------------------
-- property_features: Ausstattung und technische Angaben (Sauna, Heizung, Brunnen …)
-- -----------------------------------------------------------------------------
create table public.property_features (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.properties(id) on delete cascade,
  feature_type  text not null,
  feature_name  text not null,
  value         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index property_features_property_idx on public.property_features (property_id, feature_type);
create trigger property_features_set_updated_at before update on public.property_features
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Zugriffs-Helfer je Haus
-- -----------------------------------------------------------------------------
create or replace function private.property_org(p_property_id uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$ select p.organization_id from public.properties p where p.id = p_property_id $$;

-- Rolle des angemeldeten Benutzers am Haus: owner (Eigentümer) oder Rolle aus property_users
create or replace function private.property_role(p_property_id uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select case
    when p.owner_user_id = private.current_user_id() then 'owner'
    else (select pu.role from public.property_users pu where pu.property_id = p.id and pu.user_id = private.current_user_id())
  end
  from public.properties p
  where p.id = p_property_id
    and private.org_role(p.organization_id) is not null
$$;

create or replace function private.is_property_owner(p_property_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(private.property_role(p_property_id) = 'owner', false) $$;

-- Lesen: Verwaltung/viewer der Organisation oder Person mit Zuordnung zum Haus.
-- Wird in Migration 0700 um zugewiesene Aufgaben und Aufträge erweitert.
create or replace function private.can_read_property(p_property_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.can_read_org(private.property_org(p_property_id))
      or private.property_role(p_property_id) is not null
$$;

-- Bearbeiten: Verwaltung der Organisation, Eigentümer oder Hausverwalter (property_users.manager)
create or replace function private.can_manage_property(p_property_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.is_org_staff(private.property_org(p_property_id))
      or coalesce(private.property_role(p_property_id) in ('owner', 'manager'), false)
$$;

-- >>> 20261030000400_service_partners.sql
-- =============================================================================
-- HUSORA · Migration 0400 · Servicearten und Servicepartner
-- =============================================================================

-- -----------------------------------------------------------------------------
-- service_types: global (organization_id NULL) oder je Organisation
-- -----------------------------------------------------------------------------
create table public.service_types (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid references public.organizations(id) on delete cascade,
  code             text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  name             text not null,
  description      text,
  category         text,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint service_types_code_unique unique nulls not distinct (organization_id, code)
);
comment on table public.service_types is 'Servicearten. organization_id NULL = globale Husora-Standardarten (cleaning, inspection …).';
create index service_types_org_idx on public.service_types (organization_id);
create trigger service_types_set_updated_at before update on public.service_types
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- service_partners: Betriebe, die eine Organisation beauftragt
-- -----------------------------------------------------------------------------
create table public.service_partners (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  company_name     text not null check (length(trim(company_name)) > 0),
  contact_name     text,
  email            text,
  phone            text,
  website          text,
  street           text,
  postal_code      text,
  city             text,
  country          text check (country is null or country ~ '^[A-Z]{2}$'),
  latitude         numeric(9, 6) check (latitude between -90 and 90),
  longitude        numeric(9, 6) check (longitude between -180 and 180),
  description      text,
  status           text not null default 'active' check (status in ('active', 'inactive', 'blocked')),
  rating           numeric(3, 2) check (rating between 0 and 5),
  notes            text,
  created_by       uuid references public.users(id) on delete set null,
  updated_by       uuid references public.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (organization_id, id)
);
create index service_partners_org_status_idx on public.service_partners (organization_id, status);
create index service_partners_org_name_idx on public.service_partners (organization_id, lower(company_name));
create index service_partners_geo_idx on public.service_partners (latitude, longitude) where latitude is not null and longitude is not null;
create index service_partners_created_at_idx on public.service_partners (created_at);
create trigger service_partners_set_updated_at before update on public.service_partners
  for each row execute function private.set_updated_at();
create trigger service_partners_set_actor before insert or update on public.service_partners
  for each row execute function private.set_actor_columns();

-- -----------------------------------------------------------------------------
-- service_partner_users: Benutzerkonten eines Partnerbetriebs (Login für Partner)
-- -----------------------------------------------------------------------------
create table public.service_partner_users (
  id                  uuid primary key default gen_random_uuid(),
  service_partner_id  uuid not null references public.service_partners(id) on delete cascade,
  user_id             uuid not null references public.users(id) on delete cascade,
  role                text not null default 'employee' check (role in ('owner', 'employee')),
  created_at          timestamptz not null default now(),
  unique (service_partner_id, user_id)
);
create index service_partner_users_user_idx on public.service_partner_users (user_id);

-- -----------------------------------------------------------------------------
-- service_partner_services: Leistungen und Preise je Partner
-- -----------------------------------------------------------------------------
create table public.service_partner_services (
  id                  uuid primary key default gen_random_uuid(),
  service_partner_id  uuid not null references public.service_partners(id) on delete cascade,
  service_type_id     uuid not null references public.service_types(id) on delete restrict,
  price_from          numeric(12, 2) check (price_from >= 0),
  price_to            numeric(12, 2) check (price_to >= 0),
  price_unit          text check (price_unit is null or price_unit in ('hour', 'job', 'visit', 'm2', 'month', 'year')),
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  active              boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (service_partner_id, service_type_id),
  check (price_to is null or price_from is null or price_to >= price_from)
);
create index service_partner_services_type_idx on public.service_partner_services (service_type_id) where active;
create trigger service_partner_services_set_updated_at before update on public.service_partner_services
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- service_partner_areas: Einsatzgebiete
-- -----------------------------------------------------------------------------
create table public.service_partner_areas (
  id                  uuid primary key default gen_random_uuid(),
  service_partner_id  uuid not null references public.service_partners(id) on delete cascade,
  postal_code         text,
  city                text,
  region              text,
  radius_km           numeric(7, 2) check (radius_km >= 0),
  created_at          timestamptz not null default now(),
  check (postal_code is not null or city is not null or region is not null or radius_km is not null)
);
create index service_partner_areas_partner_idx on public.service_partner_areas (service_partner_id);
create index service_partner_areas_postal_idx on public.service_partner_areas (postal_code) where postal_code is not null;
create index service_partner_areas_region_idx on public.service_partner_areas (lower(region)) where region is not null;

-- -----------------------------------------------------------------------------
-- Partner-Helfer
-- -----------------------------------------------------------------------------
-- Partnerbetriebe, für die der angemeldete Benutzer arbeitet
create or replace function private.my_partner_ids()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select spu.service_partner_id
  from public.service_partner_users spu
  join public.service_partners sp on sp.id = spu.service_partner_id
  where spu.user_id = private.current_user_id()
    and private.org_role(sp.organization_id) is not null
$$;

create or replace function private.is_partner_member(p_service_partner_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select p_service_partner_id is not null and p_service_partner_id in (select private.my_partner_ids()) $$;

create or replace function private.partner_org(p_service_partner_id uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$ select sp.organization_id from public.service_partners sp where sp.id = p_service_partner_id $$;

-- >>> 20261030000500_bookings.sql
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

-- >>> 20261030000600_inspections.sql
-- =============================================================================
-- HUSORA · Migration 0600 · Hauskontrollen: Vorlagen, Kontrollen, Prüfpunkte
-- =============================================================================

create table public.inspection_templates (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  name             text not null,
  description      text,
  property_type    text,
  active           boolean not null default true,
  version          integer not null default 1 check (version >= 1),
  created_by       uuid references public.users(id) on delete set null,
  updated_by       uuid references public.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (organization_id, id)
);
create index inspection_templates_org_idx on public.inspection_templates (organization_id) where active;
create trigger inspection_templates_set_updated_at before update on public.inspection_templates
  for each row execute function private.set_updated_at();
create trigger inspection_templates_set_actor before insert or update on public.inspection_templates
  for each row execute function private.set_actor_columns();

create table public.inspection_template_items (
  id              uuid primary key default gen_random_uuid(),
  template_id     uuid not null references public.inspection_templates(id) on delete cascade,
  category        text,
  name            text not null,
  description     text,
  sort_order      integer not null default 0,
  required        boolean not null default false,
  default_status  text not null default 'not_checked' check (default_status in ('ok', 'warning', 'defect', 'not_checked', 'not_applicable')),
  frequency       text check (frequency is null or frequency in ('weekly', 'biweekly', 'monthly', 'quarterly', 'semiannual', 'yearly')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on column public.inspection_template_items.frequency is 'Prüftaktung der Position (z. B. monthly); NULL = bei jeder Kontrolle.';
create index inspection_template_items_template_idx on public.inspection_template_items (template_id, sort_order);
create trigger inspection_template_items_set_updated_at before update on public.inspection_template_items
  for each row execute function private.set_updated_at();

create table public.inspections (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null,
  template_id         uuid,
  inspector_user_id   uuid references public.users(id) on delete set null,
  service_partner_id  uuid,
  booking_id          uuid,
  scheduled_at        timestamptz,
  started_at          timestamptz,
  completed_at        timestamptz,
  status              text not null default 'scheduled' check (status in ('scheduled', 'in_progress', 'completed', 'cancelled')),
  overall_status      text check (overall_status in ('ok', 'warning', 'critical')),
  notes               text,
  created_by          uuid references public.users(id) on delete set null,
  updated_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, template_id) references public.inspection_templates (organization_id, id) on delete set null (template_id),
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete set null (service_partner_id),
  foreign key (organization_id, booking_id) references public.bookings (organization_id, id) on delete set null (booking_id),
  check (completed_at is null or started_at is null or completed_at >= started_at),
  check (status <> 'completed' or completed_at is not null)
);
comment on column public.inspections.service_partner_id is 'Partnerbetrieb, der die Kontrolle durchführt (alternativ zu inspector_user_id).';
create index inspections_property_scheduled_idx on public.inspections (property_id, scheduled_at);
create index inspections_org_status_idx on public.inspections (organization_id, status);
create index inspections_inspector_idx on public.inspections (inspector_user_id) where inspector_user_id is not null;
create index inspections_partner_idx on public.inspections (service_partner_id) where service_partner_id is not null;
create index inspections_booking_idx on public.inspections (booking_id) where booking_id is not null;
create index inspections_template_idx on public.inspections (template_id) where template_id is not null;
create index inspections_created_at_idx on public.inspections (created_at);
create trigger inspections_set_updated_at before update on public.inspections
  for each row execute function private.set_updated_at();
create trigger inspections_set_actor before insert or update on public.inspections
  for each row execute function private.set_actor_columns();

create table public.inspection_items (
  id                uuid primary key default gen_random_uuid(),
  inspection_id     uuid not null references public.inspections(id) on delete cascade,
  template_item_id  uuid references public.inspection_template_items(id) on delete set null,
  category          text,
  name              text not null,
  status            text not null default 'not_checked' check (status in ('ok', 'warning', 'defect', 'not_checked', 'not_applicable')),
  notes             text,
  estimated_cost    numeric(12, 2) check (estimated_cost >= 0),
  photo_required    boolean not null default false,
  checked_at        timestamptz,
  checked_by        uuid references public.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (inspection_id, template_item_id)
);
comment on column public.inspection_items.name is 'Kopie des Positionsnamens zum Zeitpunkt der Kontrolle – bleibt erhalten, wenn die Vorlage geändert wird.';
create index inspection_items_inspection_status_idx on public.inspection_items (inspection_id, status);
create index inspection_items_template_item_idx on public.inspection_items (template_item_id) where template_item_id is not null;
create index inspection_items_defects_idx on public.inspection_items (inspection_id) where status in ('warning', 'defect');
create trigger inspection_items_set_updated_at before update on public.inspection_items
  for each row execute function private.set_updated_at();

-- Prüfpunkte beim Anlegen einer Kontrolle aus der Vorlage übernehmen
create or replace function private.create_items_from_template()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.template_id is not null then
    insert into public.inspection_items (inspection_id, template_item_id, category, name, status, photo_required)
    select new.id, ti.id, ti.category, ti.name, ti.default_status, false
    from public.inspection_template_items ti
    where ti.template_id = new.template_id
    order by ti.sort_order
    on conflict (inspection_id, template_item_id) do nothing;
  end if;
  return new;
end;
$$;

create trigger inspections_create_items after insert on public.inspections
  for each row execute function private.create_items_from_template();

-- -----------------------------------------------------------------------------
-- Zugriffs-Helfer Kontrolle
-- -----------------------------------------------------------------------------
create or replace function private.can_read_inspection(p_inspection_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.inspections i
    where i.id = p_inspection_id
      and (
        private.can_read_org(i.organization_id)
        or private.is_property_owner(i.property_id)
        or (i.inspector_user_id = private.current_user_id() and private.is_org_member(i.organization_id))
        or private.is_partner_member(i.service_partner_id)
      )
  )
$$;

-- Prüfpunkte bearbeiten: Verwaltung, eingeteilter Prüfer oder beauftragter Partner
create or replace function private.can_work_inspection(p_inspection_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.inspections i
    where i.id = p_inspection_id
      and i.status in ('scheduled', 'in_progress')
      and (
        private.is_org_staff(i.organization_id)
        or (i.inspector_user_id = private.current_user_id() and private.is_org_member(i.organization_id))
        or private.is_partner_member(i.service_partner_id)
      )
  ) or exists (
    select 1 from public.inspections i where i.id = p_inspection_id and private.is_org_staff(i.organization_id)
  )
$$;

-- >>> 20261030000700_tasks_orders_repairs.sql
-- =============================================================================
-- HUSORA · Migration 0700 · Serviceaufgaben, Serviceaufträge, Wartung, Reparaturen
-- =============================================================================

-- Systemkontext: Migration, SQL-Editor, service_role oder Aufruf aus einer
-- security-definer-Funktion. Bewusst security invoker (current_user = Aufrufer).
create or replace function private.is_system_context()
returns boolean
language sql
stable
set search_path = ''
as $$
  select current_user in ('postgres', 'supabase_admin', 'service_role')
      or coalesce(auth.role(), '') = 'service_role'
$$;

-- Serviceart muss global sein oder zur selben Organisation gehören
create or replace function private.check_service_type_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org      uuid;
  v_type_org uuid;
begin
  if new.service_type_id is null then
    return new;
  end if;
  if tg_table_name = 'service_partner_services' then
    v_org := private.partner_org(new.service_partner_id);
  else
    v_org := (to_jsonb(new) ->> 'organization_id')::uuid;
  end if;
  select st.organization_id into v_type_org from public.service_types st where st.id = new.service_type_id;
  if v_type_org is not null and v_type_org is distinct from v_org then
    raise exception 'Serviceart % gehört zu einer anderen Organisation', new.service_type_id using errcode = '23503';
  end if;
  return new;
end;
$$;

create trigger service_partner_services_check_type before insert or update of service_type_id on public.service_partner_services
  for each row execute function private.check_service_type_scope();

-- -----------------------------------------------------------------------------
-- service_tasks: Aufgaben (Reinigung, Wäsche, Kontrolle, Garten …)
-- -----------------------------------------------------------------------------
create table public.service_tasks (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references public.organizations(id) on delete cascade,
  property_id          uuid not null,
  booking_id           uuid,
  inspection_id        uuid,
  service_type_id      uuid references public.service_types(id) on delete set null,
  title                text not null check (length(trim(title)) > 0),
  description          text,
  priority             text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  status               text not null default 'pending' check (status in ('pending', 'assigned', 'accepted', 'in_progress', 'completed', 'cancelled')),
  scheduled_start      timestamptz,
  scheduled_end        timestamptz,
  assigned_partner_id  uuid,
  assigned_user_id     uuid references public.users(id) on delete set null,
  completed_at         timestamptz,
  completion_notes     text,
  created_by           uuid references public.users(id) on delete set null,
  updated_by           uuid references public.users(id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, booking_id) references public.bookings (organization_id, id) on delete set null (booking_id),
  foreign key (organization_id, inspection_id) references public.inspections (organization_id, id) on delete set null (inspection_id),
  foreign key (organization_id, assigned_partner_id) references public.service_partners (organization_id, id) on delete set null (assigned_partner_id),
  check (scheduled_end is null or scheduled_start is null or scheduled_end >= scheduled_start)
);
comment on column public.service_tasks.assigned_user_id is 'Eingeteilte Person (z. B. Reinigungskraft). Rolle cleaner sieht nur ihre eigenen Aufgaben.';
comment on column public.service_tasks.assigned_partner_id is 'Beauftragter Partnerbetrieb. Rolle service_partner sieht nur Aufgaben seines Betriebs.';

create index service_tasks_property_status_idx on public.service_tasks (property_id, status);
create index service_tasks_org_status_idx on public.service_tasks (organization_id, status);
create index service_tasks_scheduled_start_idx on public.service_tasks (scheduled_start);
create index service_tasks_open_idx on public.service_tasks (organization_id, scheduled_start)
  where status not in ('completed', 'cancelled');
create index service_tasks_partner_idx on public.service_tasks (assigned_partner_id, status) where assigned_partner_id is not null;
create index service_tasks_user_idx on public.service_tasks (assigned_user_id, status) where assigned_user_id is not null;
create index service_tasks_booking_idx on public.service_tasks (booking_id) where booking_id is not null;
create index service_tasks_inspection_idx on public.service_tasks (inspection_id) where inspection_id is not null;
create index service_tasks_type_idx on public.service_tasks (service_type_id);
create index service_tasks_created_at_idx on public.service_tasks (created_at);

-- Ausführende (Reinigungskraft, Partner) dürfen nur Status und Erledigungsnotiz ändern
create or replace function private.service_tasks_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status text;
  v_notes  text;
begin
  if tg_op = 'UPDATE'
     and not private.is_system_context()
     and not private.is_org_staff(old.organization_id)
     and not private.can_manage_property(old.property_id) then
    if new.status is distinct from old.status and new.status not in ('accepted', 'in_progress', 'completed') then
      raise exception 'Status "%" darf nur von der Verwaltung gesetzt werden', new.status using errcode = '42501';
    end if;
    v_status := new.status;
    v_notes := new.completion_notes;
    new := old;
    new.status := v_status;
    new.completion_notes := v_notes;
  end if;

  if new.status = 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  elsif tg_op = 'UPDATE' and old.status = 'completed' then
    new.completed_at := null;
  end if;
  if tg_op = 'INSERT' and new.status = 'pending' and (new.assigned_partner_id is not null or new.assigned_user_id is not null) then
    new.status := 'assigned';
  end if;
  return new;
end;
$$;

create trigger service_tasks_guard before insert or update on public.service_tasks
  for each row execute function private.service_tasks_guard();
create trigger service_tasks_check_type before insert or update of service_type_id on public.service_tasks
  for each row execute function private.check_service_type_scope();
create trigger service_tasks_set_actor before insert or update on public.service_tasks
  for each row execute function private.set_actor_columns();
create trigger service_tasks_set_updated_at before update on public.service_tasks
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- service_orders: Aufträge an Servicepartner
-- -----------------------------------------------------------------------------
create table public.service_orders (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  service_task_id     uuid,
  property_id         uuid not null,
  service_partner_id  uuid,
  order_number        text not null unique
                      default 'SO-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.service_order_number_seq')::text, 6, '0'),
  title               text not null check (length(trim(title)) > 0),
  description         text,
  status              text not null default 'draft' check (status in ('draft', 'offered', 'accepted', 'rejected', 'scheduled', 'in_progress', 'completed', 'cancelled')),
  offered_at          timestamptz,
  accepted_at         timestamptz,
  rejected_at         timestamptz,
  response_note       text,
  scheduled_at        timestamptz,
  completed_at        timestamptz,
  estimated_cost      numeric(12, 2) check (estimated_cost >= 0),
  actual_cost         numeric(12, 2) check (actual_cost >= 0),
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  match_score         numeric(6, 2),
  created_by          uuid references public.users(id) on delete set null,
  updated_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, service_task_id) references public.service_tasks (organization_id, id) on delete set null (service_task_id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete set null (service_partner_id),
  check (status in ('draft', 'cancelled') or service_partner_id is not null)
);
comment on column public.service_orders.match_score is 'Score aus public.match_service_partners zum Zeitpunkt der Vergabe.';
comment on column public.service_orders.response_note is 'Antwort des Partners (Begründung bei Ablehnung, Terminvorschlag …).';

create index service_orders_partner_status_idx on public.service_orders (service_partner_id, status);
create index service_orders_org_status_idx on public.service_orders (organization_id, status);
create index service_orders_property_idx on public.service_orders (property_id, status);
create index service_orders_task_idx on public.service_orders (service_task_id) where service_task_id is not null;
create index service_orders_scheduled_idx on public.service_orders (scheduled_at);
create index service_orders_created_at_idx on public.service_orders (created_at);

-- Verwaltung darf alles; der Partner nur annehmen/ablehnen/terminieren/abschließen
create or replace function private.service_orders_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status   text;
  v_note     text;
  v_sched    timestamptz;
  v_actual   numeric(12, 2);
begin
  if tg_op = 'UPDATE' and not private.is_system_context() then
    new.order_number := old.order_number;
    if not private.is_org_staff(old.organization_id) then
      if not private.is_partner_member(old.service_partner_id) then
        raise exception 'Keine Berechtigung für Auftrag %', old.order_number using errcode = '42501';
      end if;
      if new.status is distinct from old.status and not (
           (old.status = 'offered' and new.status in ('accepted', 'rejected'))
        or (old.status in ('accepted', 'scheduled') and new.status in ('scheduled', 'in_progress'))
        or (old.status in ('accepted', 'scheduled', 'in_progress') and new.status = 'completed')
      ) then
        raise exception 'Statuswechsel % → % ist für Partner nicht erlaubt', old.status, new.status using errcode = '42501';
      end if;
      v_status := new.status;
      v_note := new.response_note;
      v_sched := new.scheduled_at;
      v_actual := new.actual_cost;
      new := old;
      new.status := v_status;
      new.response_note := v_note;
      new.scheduled_at := v_sched;
      new.actual_cost := v_actual;
    end if;
  end if;

  if tg_op = 'INSERT' or new.status is distinct from old.status then
    case new.status
      when 'offered'   then new.offered_at := coalesce(new.offered_at, now());
      when 'accepted'  then new.accepted_at := coalesce(new.accepted_at, now());
      when 'rejected'  then new.rejected_at := coalesce(new.rejected_at, now());
      when 'completed' then new.completed_at := coalesce(new.completed_at, now());
      else null;
    end case;
  end if;
  return new;
end;
$$;

create trigger service_orders_guard before insert or update on public.service_orders
  for each row execute function private.service_orders_guard();
create trigger service_orders_set_actor before insert or update on public.service_orders
  for each row execute function private.set_actor_columns();
create trigger service_orders_set_updated_at before update on public.service_orders
  for each row execute function private.set_updated_at();

-- Auftragsstatus auf die verknüpfte Aufgabe übertragen
create or replace function private.sync_task_from_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.service_task_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.status is not distinct from old.status
     and new.service_partner_id is not distinct from old.service_partner_id then
    return new;
  end if;

  -- Absage: Aufgabe nur freigeben, wenn sie noch diesem Partner zugeordnet ist
  -- (ein Folgeangebot an den nächsten Partner kann bereits erfolgt sein)
  if new.status = 'rejected' then
    update public.service_tasks t
    set assigned_partner_id = null, status = 'pending'
    where t.id = new.service_task_id
      and t.assigned_partner_id is not distinct from new.service_partner_id
      and t.status not in ('completed', 'cancelled');
    return new;
  end if;

  update public.service_tasks t
  set assigned_partner_id = new.service_partner_id,
      status = case new.status
                 when 'offered'     then 'assigned'
                 when 'accepted'    then 'accepted'
                 when 'scheduled'   then 'accepted'
                 when 'in_progress' then 'in_progress'
                 when 'completed'   then 'completed'
                 else t.status
               end,
      scheduled_start = coalesce(new.scheduled_at, t.scheduled_start)
  where t.id = new.service_task_id
    and new.status not in ('draft', 'cancelled')
    and t.status <> 'cancelled';
  return new;
end;
$$;

create trigger service_orders_sync_task after insert or update of status, service_partner_id on public.service_orders
  for each row execute function private.sync_task_from_order();

-- -----------------------------------------------------------------------------
-- maintenance: wiederkehrende Wartung (Heizung, Schornstein, Brunnen …)
-- -----------------------------------------------------------------------------
create table public.maintenance (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references public.organizations(id) on delete cascade,
  property_id          uuid not null,
  service_type_id      uuid references public.service_types(id) on delete set null,
  title                text not null check (length(trim(title)) > 0),
  description          text,
  category             text,
  last_performed_at    timestamptz,
  next_due_at          timestamptz,
  interval_days        integer check (interval_days > 0),
  status               text not null default 'active' check (status in ('active', 'due', 'overdue', 'paused', 'retired')),
  assigned_partner_id  uuid,
  estimated_cost       numeric(12, 2) check (estimated_cost >= 0),
  created_by           uuid references public.users(id) on delete set null,
  updated_by           uuid references public.users(id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, assigned_partner_id) references public.service_partners (organization_id, id) on delete set null (assigned_partner_id)
);
create index maintenance_property_due_idx on public.maintenance (property_id, next_due_at);
create index maintenance_org_status_idx on public.maintenance (organization_id, status);
create index maintenance_due_idx on public.maintenance (next_due_at) where status in ('active', 'due', 'overdue');
create index maintenance_partner_idx on public.maintenance (assigned_partner_id) where assigned_partner_id is not null;
create index maintenance_created_at_idx on public.maintenance (created_at);

-- Nächste Fälligkeit aus letzter Ausführung + Intervall berechnen
create or replace function private.maintenance_next_due()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.interval_days is not null and new.last_performed_at is not null
     and (tg_op = 'INSERT' or new.last_performed_at is distinct from old.last_performed_at or new.interval_days is distinct from old.interval_days) then
    new.next_due_at := new.last_performed_at + make_interval(days => new.interval_days);
    if new.status in ('due', 'overdue') then
      new.status := 'active';
    end if;
  end if;
  return new;
end;
$$;

create trigger maintenance_next_due before insert or update on public.maintenance
  for each row execute function private.maintenance_next_due();
create trigger maintenance_check_type before insert or update of service_type_id on public.maintenance
  for each row execute function private.check_service_type_scope();
create trigger maintenance_set_actor before insert or update on public.maintenance
  for each row execute function private.set_actor_columns();
create trigger maintenance_set_updated_at before update on public.maintenance
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- repairs: Reparaturen (aus Mängeln der Hauskontrolle oder gemeldet)
-- -----------------------------------------------------------------------------
create table public.repairs (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null,
  inspection_id       uuid,
  inspection_item_id  uuid references public.inspection_items(id) on delete set null,
  service_order_id    uuid,
  title               text not null check (length(trim(title)) > 0),
  description         text,
  priority            text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  status              text not null default 'reported' check (status in ('reported', 'approved', 'assigned', 'in_progress', 'completed', 'cancelled')),
  estimated_cost      numeric(12, 2) check (estimated_cost >= 0),
  actual_cost         numeric(12, 2) check (actual_cost >= 0),
  reported_at         timestamptz not null default now(),
  approved_at         timestamptz,
  approved_by         uuid references public.users(id) on delete set null,
  completed_at        timestamptz,
  created_by          uuid references public.users(id) on delete set null,
  updated_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, inspection_id) references public.inspections (organization_id, id) on delete set null (inspection_id),
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete set null (service_order_id),
  check (status <> 'completed' or completed_at is not null)
);
create unique index repairs_inspection_item_unique_idx on public.repairs (inspection_item_id)
  where inspection_item_id is not null and status <> 'cancelled';
create index repairs_property_status_idx on public.repairs (property_id, status);
create index repairs_org_status_idx on public.repairs (organization_id, status);
create index repairs_inspection_idx on public.repairs (inspection_id) where inspection_id is not null;
create index repairs_order_idx on public.repairs (service_order_id) where service_order_id is not null;
create index repairs_created_at_idx on public.repairs (created_at);

-- Prüfpunkt muss zur angegebenen Kontrolle und Organisation gehören (für repairs und photos)
create or replace function private.check_inspection_item_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inspection uuid;
  v_org        uuid;
  v_property   uuid;
begin
  if new.inspection_item_id is null then
    return new;
  end if;
  select ii.inspection_id, i.organization_id, i.property_id into v_inspection, v_org, v_property
  from public.inspection_items ii
  join public.inspections i on i.id = ii.inspection_id
  where ii.id = new.inspection_item_id;

  if v_org is distinct from new.organization_id or v_property is distinct from new.property_id
     or (new.inspection_id is not null and new.inspection_id <> v_inspection) then
    raise exception 'Prüfpunkt % gehört nicht zu dieser Kontrolle', new.inspection_item_id using errcode = '23503';
  end if;
  new.inspection_id := v_inspection;
  return new;
end;
$$;

-- Freigabe und Abschluss automatisch protokollieren
create or replace function private.repairs_status_timestamps()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  end if;
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status <> 'approved') then
    new.approved_at := coalesce(new.approved_at, now());
    new.approved_by := coalesce(new.approved_by, private.current_user_id());
  end if;
  return new;
end;
$$;

create trigger repairs_check_item before insert or update of inspection_item_id, inspection_id on public.repairs
  for each row execute function private.check_inspection_item_scope();
create trigger repairs_status_timestamps before insert or update on public.repairs
  for each row execute function private.repairs_status_timestamps();
create trigger repairs_set_actor before insert or update on public.repairs
  for each row execute function private.set_actor_columns();
create trigger repairs_set_updated_at before update on public.repairs
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Zugriffs-Helfer
-- -----------------------------------------------------------------------------
create or replace function private.can_read_service_order(p_service_order_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.service_orders o
    where o.id = p_service_order_id
      and (
        private.can_read_org(o.organization_id)
        or private.is_property_owner(o.property_id)
        or (o.status <> 'draft' and private.is_partner_member(o.service_partner_id))
      )
  )
$$;

create or replace function private.can_read_repair(p_repair_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.repairs r
    where r.id = p_repair_id
      and (
        private.can_read_org(r.organization_id)
        or private.is_property_owner(r.property_id)
        or (r.service_order_id is not null and private.can_read_service_order(r.service_order_id))
        or (r.inspection_id is not null and private.can_read_inspection(r.inspection_id))
      )
  )
$$;

-- Haus lesen: zusätzlich Personen und Partner, die dort eine Aufgabe, einen Auftrag
-- oder eine Kontrolle haben (Adresse, Zugangsinfos – aber keine Gästedaten).
create or replace function private.can_read_property(p_property_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.can_read_org(private.property_org(p_property_id))
      or private.property_role(p_property_id) is not null
      or exists (
        select 1 from public.service_tasks t
        where t.property_id = p_property_id
          and t.status not in ('cancelled')
          and (
            (t.assigned_user_id = private.current_user_id() and private.is_org_member(t.organization_id))
            or private.is_partner_member(t.assigned_partner_id)
          )
      )
      or exists (
        select 1 from public.service_orders o
        where o.property_id = p_property_id
          and o.status not in ('draft', 'cancelled')
          and private.is_partner_member(o.service_partner_id)
      )
      or exists (
        select 1 from public.inspections i
        where i.property_id = p_property_id
          and i.status <> 'cancelled'
          and (
            (i.inspector_user_id = private.current_user_id() and private.is_org_member(i.organization_id))
            or private.is_partner_member(i.service_partner_id)
          )
      )
$$;

-- >>> 20261030000800_files_finance.sql
-- =============================================================================
-- HUSORA · Migration 0800 · Dokumente, Fotos, Angebote, Rechnungen
-- =============================================================================
-- Dateien liegen in Supabase Storage. Die Tabellen speichern nur Metadaten und
-- den Pfad. Pfadkonvention (wird per CHECK erzwungen):
--   organization/{organization_id}/property/{property_id}/{photos|documents|inspections|repairs}/…
--   organization/{organization_id}/documents/…   (Dokumente ohne Hausbezug)

-- -----------------------------------------------------------------------------
-- documents
-- -----------------------------------------------------------------------------
create table public.documents (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references public.organizations(id) on delete cascade,
  property_id       uuid,
  service_order_id  uuid,
  repair_id         uuid,
  inspection_id     uuid,
  uploaded_by       uuid references public.users(id) on delete set null,
  file_name         text not null check (length(trim(file_name)) > 0),
  file_type         text,
  file_size         bigint check (file_size >= 0),
  storage_bucket    text not null default 'husora-documents' check (storage_bucket in ('husora-documents', 'husora-private', 'husora-public')),
  storage_path      text not null,
  document_type     text not null default 'other' check (document_type in (
                      'contract', 'invoice', 'quote', 'inspection_report', 'repair_report', 'manual',
                      'insurance', 'permit', 'floor_plan', 'energy_certificate', 'other')),
  description       text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (organization_id, id),
  unique (storage_bucket, storage_path),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete set null (service_order_id),
  foreign key (organization_id, repair_id) references public.repairs (organization_id, id) on delete set null (repair_id),
  foreign key (organization_id, inspection_id) references public.inspections (organization_id, id) on delete set null (inspection_id),
  constraint documents_storage_path_check check (
    storage_path not like '%..%' and (
      (property_id is not null and storage_path like 'organization/' || organization_id::text || '/property/' || property_id::text || '/%')
      or (property_id is null and storage_path like 'organization/' || organization_id::text || '/documents/%')
    )
  )
);
create index documents_org_type_idx on public.documents (organization_id, document_type);
create index documents_property_idx on public.documents (property_id, created_at desc) where property_id is not null;
create index documents_order_idx on public.documents (service_order_id) where service_order_id is not null;
create index documents_repair_idx on public.documents (repair_id) where repair_id is not null;
create index documents_inspection_idx on public.documents (inspection_id) where inspection_id is not null;
create index documents_uploaded_by_idx on public.documents (uploaded_by);
create index documents_created_at_idx on public.documents (created_at);
create trigger documents_set_updated_at before update on public.documents
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- photos
-- -----------------------------------------------------------------------------
create table public.photos (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null,
  inspection_id       uuid,
  inspection_item_id  uuid references public.inspection_items(id) on delete set null,
  repair_id           uuid,
  service_order_id    uuid,
  service_task_id     uuid,
  uploaded_by         uuid references public.users(id) on delete set null,
  storage_bucket      text not null default 'husora-property-photos' check (storage_bucket in ('husora-property-photos', 'husora-private', 'husora-public')),
  storage_path        text not null,
  caption             text,
  taken_at            timestamptz,
  created_at          timestamptz not null default now(),
  unique (storage_bucket, storage_path),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, inspection_id) references public.inspections (organization_id, id) on delete set null (inspection_id),
  foreign key (organization_id, repair_id) references public.repairs (organization_id, id) on delete set null (repair_id),
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete set null (service_order_id),
  foreign key (organization_id, service_task_id) references public.service_tasks (organization_id, id) on delete set null (service_task_id),
  constraint photos_storage_path_check check (
    storage_path not like '%..%'
    and storage_path like 'organization/' || organization_id::text || '/property/' || property_id::text || '/%'
  )
);
create index photos_property_idx on public.photos (property_id, created_at desc);
create index photos_org_idx on public.photos (organization_id);
create index photos_inspection_idx on public.photos (inspection_id) where inspection_id is not null;
create index photos_inspection_item_idx on public.photos (inspection_item_id) where inspection_item_id is not null;
create index photos_repair_idx on public.photos (repair_id) where repair_id is not null;
create index photos_order_idx on public.photos (service_order_id) where service_order_id is not null;
create index photos_task_idx on public.photos (service_task_id) where service_task_id is not null;
create index photos_uploaded_by_idx on public.photos (uploaded_by);
create index photos_created_at_idx on public.photos (created_at);
create trigger photos_check_item before insert or update of inspection_item_id, inspection_id on public.photos
  for each row execute function private.check_inspection_item_scope();

-- Hochladende Person automatisch eintragen
create or replace function private.set_uploaded_by()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.uploaded_by := coalesce(private.current_user_id(), new.uploaded_by);
  return new;
end;
$$;
create trigger documents_set_uploaded_by before insert on public.documents
  for each row execute function private.set_uploaded_by();
create trigger photos_set_uploaded_by before insert on public.photos
  for each row execute function private.set_uploaded_by();

-- -----------------------------------------------------------------------------
-- quotes: Angebote von Servicepartnern
-- -----------------------------------------------------------------------------
create table public.quotes (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null,
  repair_id           uuid,
  service_order_id    uuid,
  service_partner_id  uuid,
  document_id         uuid,
  quote_number        text,
  description         text,
  amount_net          numeric(12, 2) check (amount_net >= 0),
  tax_amount          numeric(12, 2) check (tax_amount >= 0),
  amount_gross        numeric(12, 2) check (amount_gross >= 0),
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  status              text not null default 'requested' check (status in ('requested', 'received', 'approved', 'rejected', 'expired')),
  valid_until         date,
  received_at         timestamptz,
  decided_at          timestamptz,
  decided_by          uuid references public.users(id) on delete set null,
  created_by          uuid references public.users(id) on delete set null,
  updated_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, repair_id) references public.repairs (organization_id, id) on delete set null (repair_id),
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete set null (service_order_id),
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete set null (service_partner_id),
  foreign key (organization_id, document_id) references public.documents (organization_id, id) on delete set null (document_id),
  check (amount_gross is null or amount_net is null or tax_amount is null or amount_gross = amount_net + tax_amount)
);
create unique index quotes_partner_number_unique_idx on public.quotes (organization_id, service_partner_id, quote_number)
  where quote_number is not null;
create index quotes_org_status_idx on public.quotes (organization_id, status);
create index quotes_property_idx on public.quotes (property_id);
create index quotes_repair_idx on public.quotes (repair_id) where repair_id is not null;
create index quotes_order_idx on public.quotes (service_order_id) where service_order_id is not null;
create index quotes_partner_status_idx on public.quotes (service_partner_id, status);
create index quotes_created_at_idx on public.quotes (created_at);

-- -----------------------------------------------------------------------------
-- invoices: Rechnungen von Servicepartnern
-- -----------------------------------------------------------------------------
create table public.invoices (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  property_id         uuid not null,
  service_order_id    uuid,
  service_partner_id  uuid,
  document_id         uuid,
  invoice_number      text,
  amount_net          numeric(12, 2) check (amount_net >= 0),
  tax_amount          numeric(12, 2) check (tax_amount >= 0),
  amount_gross        numeric(12, 2) check (amount_gross >= 0),
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  invoice_date        date,
  due_date            date,
  status              text not null default 'received' check (status in ('draft', 'received', 'approved', 'paid', 'overdue', 'cancelled')),
  approved_at         timestamptz,
  approved_by         uuid references public.users(id) on delete set null,
  paid_at             timestamptz,
  created_by          uuid references public.users(id) on delete set null,
  updated_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, property_id) references public.properties (organization_id, id) on delete cascade,
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete set null (service_order_id),
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete set null (service_partner_id),
  foreign key (organization_id, document_id) references public.documents (organization_id, id) on delete set null (document_id),
  check (amount_gross is null or amount_net is null or tax_amount is null or amount_gross = amount_net + tax_amount),
  check (due_date is null or invoice_date is null or due_date >= invoice_date),
  check (status <> 'paid' or paid_at is not null)
);
create unique index invoices_partner_number_unique_idx on public.invoices (organization_id, service_partner_id, invoice_number)
  where invoice_number is not null;
create index invoices_org_status_idx on public.invoices (organization_id, status);
create index invoices_property_date_idx on public.invoices (property_id, invoice_date);
create index invoices_order_idx on public.invoices (service_order_id) where service_order_id is not null;
create index invoices_partner_status_idx on public.invoices (service_partner_id, status);
create index invoices_due_idx on public.invoices (due_date) where status in ('received', 'approved', 'overdue');
create index invoices_created_at_idx on public.invoices (created_at);

-- Partner dürfen Angebote/Rechnungen nur einreichen, nicht freigeben oder bezahlen
create or replace function private.finance_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if private.is_system_context() or private.is_org_staff(new.organization_id) then
    null;
  elsif private.is_partner_member(coalesce(new.service_partner_id, old.service_partner_id)) then
    if tg_op = 'UPDATE' and (new.service_partner_id is distinct from old.service_partner_id
                             or new.property_id is distinct from old.property_id
                             or new.organization_id is distinct from old.organization_id) then
      raise exception 'Zuordnung darf vom Partner nicht geändert werden' using errcode = '42501';
    end if;
    if new.status not in ('requested', 'received', 'draft') then
      raise exception 'Status "%" darf nur von der Verwaltung gesetzt werden', new.status using errcode = '42501';
    end if;
  end if;

  if tg_table_name = 'quotes' then
    if new.status = 'received' and (tg_op = 'INSERT' or old.status <> 'received') then
      new.received_at := coalesce(new.received_at, now());
    elsif new.status in ('approved', 'rejected') and (tg_op = 'INSERT' or old.status is distinct from new.status) then
      new.decided_at := now();
      new.decided_by := private.current_user_id();
    end if;
  else
    if new.status = 'approved' and (tg_op = 'INSERT' or old.status <> 'approved') then
      new.approved_at := coalesce(new.approved_at, now());
      new.approved_by := coalesce(new.approved_by, private.current_user_id());
    elsif new.status = 'paid' then
      new.paid_at := coalesce(new.paid_at, now());
    end if;
  end if;
  return new;
end;
$$;

create trigger quotes_guard before insert or update on public.quotes
  for each row execute function private.finance_guard();
create trigger quotes_set_actor before insert or update on public.quotes
  for each row execute function private.set_actor_columns();
create trigger quotes_set_updated_at before update on public.quotes
  for each row execute function private.set_updated_at();
create trigger invoices_guard before insert or update on public.invoices
  for each row execute function private.finance_guard();
create trigger invoices_set_actor before insert or update on public.invoices
  for each row execute function private.set_actor_columns();
create trigger invoices_set_updated_at before update on public.invoices
  for each row execute function private.set_updated_at();

-- Freigegebene Rechnung schreibt die Ist-Kosten in den Auftrag
create or replace function private.sync_order_cost_from_invoice()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.service_order_id is not null and new.status in ('approved', 'paid') and new.amount_gross is not null then
    update public.service_orders o
    set actual_cost = (
      select sum(i.amount_gross) from public.invoices i
      where i.service_order_id = new.service_order_id and i.status in ('approved', 'paid')
    )
    where o.id = new.service_order_id;
  end if;
  return new;
end;
$$;
create trigger invoices_sync_order_cost after insert or update of status, amount_gross on public.invoices
  for each row execute function private.sync_order_cost_from_invoice();

-- >>> 20261030000900_automation_communication.sql
-- =============================================================================
-- HUSORA · Migration 0900 · Automatisierung, Benachrichtigungen, Nachrichten,
--                           Audit-Log, Webhooks
-- =============================================================================

-- -----------------------------------------------------------------------------
-- automation_rules
-- Beispiele:  booking_created → create_cleaning_task
--             booking_checkout → create_inspection
--             inspection_item_defect → create_repair
-- -----------------------------------------------------------------------------
create table public.automation_rules (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references public.organizations(id) on delete cascade,
  name              text not null check (length(trim(name)) > 0),
  description       text,
  trigger_type      text not null check (trigger_type in (
                      'booking_created', 'booking_checkout', 'booking_cancelled',
                      'inspection_completed', 'inspection_item_defect',
                      'service_order_rejected', 'maintenance_due')),
  trigger_config    jsonb not null default '{}'::jsonb,
  condition_config  jsonb not null default '{}'::jsonb,
  action_config     jsonb not null,
  active            boolean not null default true,
  sort_order        integer not null default 0,
  created_by        uuid references public.users(id) on delete set null,
  updated_by        uuid references public.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (organization_id, id),
  check (jsonb_typeof(trigger_config) = 'object' and jsonb_typeof(condition_config) = 'object'),
  check (action_config ->> 'type' in (
           'create_task', 'create_cleaning_task', 'create_inspection', 'create_repair',
           'notify', 'cancel_booking_tasks', 'offer_next_partner'))
);
comment on column public.automation_rules.trigger_config is 'Zeitbezug, z. B. {"anchor": "check_out", "offset_hours": 1, "duration_hours": 3}';
comment on column public.automation_rules.condition_config is 'Bedingungen, z. B. {"sources": ["airbnb"], "min_nights": 2, "exclude_owner_stays": true, "item_statuses": ["defect"]}';
comment on column public.automation_rules.action_config is 'Aktion, z. B. {"type": "create_cleaning_task", "service_type_code": "cleaning", "title": "Endreinigung {property_name}", "auto_assign": true}';
create index automation_rules_org_trigger_idx on public.automation_rules (organization_id, trigger_type) where active;
create trigger automation_rules_set_updated_at before update on public.automation_rules
  for each row execute function private.set_updated_at();
create trigger automation_rules_set_actor before insert or update on public.automation_rules
  for each row execute function private.set_actor_columns();

-- -----------------------------------------------------------------------------
-- automation_runs: Protokoll jeder Ausführung (idempotent über idempotency_key)
-- -----------------------------------------------------------------------------
create table public.automation_runs (
  id                  uuid primary key default gen_random_uuid(),
  automation_rule_id  uuid not null,
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  trigger_type        text not null,
  entity_type         text not null,
  entity_id           uuid not null,
  idempotency_key     text not null,
  status              text not null default 'running' check (status in ('running', 'completed', 'failed', 'skipped')),
  input_data          jsonb,
  output_data         jsonb,
  error_message       text,
  started_at          timestamptz not null default now(),
  completed_at        timestamptz,
  foreign key (organization_id, automation_rule_id) references public.automation_rules (organization_id, id) on delete cascade,
  unique (automation_rule_id, idempotency_key)
);
create index automation_runs_org_started_idx on public.automation_runs (organization_id, started_at desc);
create index automation_runs_rule_idx on public.automation_runs (automation_rule_id, started_at desc);
create index automation_runs_entity_idx on public.automation_runs (entity_type, entity_id);
create index automation_runs_failed_idx on public.automation_runs (organization_id, started_at desc) where status = 'failed';

-- -----------------------------------------------------------------------------
-- notifications: persönliche Benachrichtigungen
-- -----------------------------------------------------------------------------
create table public.notifications (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  user_id          uuid not null references public.users(id) on delete cascade,
  type             text not null default 'info',
  title            text not null,
  message          text,
  entity_type      text,
  entity_id        uuid,
  read_at          timestamptz,
  created_at       timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_unread_idx on public.notifications (user_id) where read_at is null;
create index notifications_org_idx on public.notifications (organization_id, created_at desc);
create index notifications_entity_idx on public.notifications (entity_type, entity_id);

-- -----------------------------------------------------------------------------
-- messages: Nachrichten zwischen Verwaltung und Partner (je Auftrag oder direkt)
-- -----------------------------------------------------------------------------
create table public.messages (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references public.organizations(id) on delete cascade,
  sender_user_id     uuid references public.users(id) on delete set null,
  recipient_user_id  uuid references public.users(id) on delete set null,
  service_order_id   uuid,
  message            text not null check (length(trim(message)) between 1 and 10000),
  created_at         timestamptz not null default now(),
  read_at            timestamptz,
  foreign key (organization_id, service_order_id) references public.service_orders (organization_id, id) on delete cascade,
  check (recipient_user_id is not null or service_order_id is not null)
);
comment on table public.messages is 'Direktnachricht (recipient_user_id) oder Auftrags-Thread (service_order_id).';
create index messages_order_idx on public.messages (service_order_id, created_at) where service_order_id is not null;
create index messages_recipient_idx on public.messages (recipient_user_id, created_at desc) where recipient_user_id is not null;
create index messages_recipient_unread_idx on public.messages (recipient_user_id) where read_at is null;
create index messages_sender_idx on public.messages (sender_user_id, created_at desc);
create index messages_org_idx on public.messages (organization_id, created_at desc);

-- Absender immer der angemeldete Benutzer; danach darf nur der Empfänger read_at setzen
create or replace function private.messages_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_read timestamptz;
begin
  if private.is_system_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.sender_user_id := private.current_user_id();
    new.read_at := null;
    new.created_at := now();
  else
    v_read := new.read_at;
    new := old;
    new.read_at := v_read;
  end if;
  return new;
end;
$$;
create trigger messages_guard before insert or update on public.messages
  for each row execute function private.messages_guard();

-- Benachrichtigungen: Benutzer dürfen nur read_at ändern
create or replace function private.notifications_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_read timestamptz;
begin
  if not private.is_system_context() then
    v_read := new.read_at;
    new := old;
    new.read_at := v_read;
  end if;
  return new;
end;
$$;
create trigger notifications_guard before update on public.notifications
  for each row execute function private.notifications_guard();

-- -----------------------------------------------------------------------------
-- audit_logs: Änderungsprotokoll (wird ausschließlich per Trigger geschrieben)
-- -----------------------------------------------------------------------------
create table public.audit_logs (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid references public.organizations(id) on delete cascade,
  user_id          uuid references public.users(id) on delete set null,
  action           text not null check (action in ('insert', 'update', 'delete')),
  entity_type      text not null,
  entity_id        uuid,
  old_data         jsonb,
  new_data         jsonb,
  ip_address       inet,
  user_agent       text,
  created_at       timestamptz not null default now()
);
create index audit_logs_org_created_idx on public.audit_logs (organization_id, created_at desc);
create index audit_logs_entity_idx on public.audit_logs (entity_type, entity_id, created_at desc);
create index audit_logs_user_idx on public.audit_logs (user_id) where user_id is not null;
-- BRIN: sehr kleiner Index für zeitlich wachsende, große Tabellen
create index audit_logs_created_at_brin on public.audit_logs using brin (created_at);

-- -----------------------------------------------------------------------------
-- Webhooks: authentifiziert · idempotent · protokolliert · wiederholbar
-- -----------------------------------------------------------------------------
create table public.webhook_endpoints (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references public.organizations(id) on delete cascade,
  endpoint          text not null check (endpoint in ('channel-manager', 'booking', 'payment', 'service-order', 'partner')),
  provider          text not null,
  secret_reference  text not null check (secret_reference ~ '^vault:[A-Za-z0-9_.-]+$'),
  active            boolean not null default true,
  last_received_at  timestamptz,
  created_by        uuid references public.users(id) on delete set null,
  updated_by        uuid references public.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (organization_id, endpoint, provider)
);
comment on column public.webhook_endpoints.secret_reference is 'Signatur-Secret in Supabase Vault (vault:<name>). Niemals das Secret selbst speichern.';
create trigger webhook_endpoints_set_updated_at before update on public.webhook_endpoints
  for each row execute function private.set_updated_at();
create trigger webhook_endpoints_set_actor before insert or update on public.webhook_endpoints
  for each row execute function private.set_actor_columns();

create table public.webhook_events (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid references public.organizations(id) on delete cascade,
  webhook_endpoint_id  uuid references public.webhook_endpoints(id) on delete set null,
  endpoint             text not null check (endpoint in ('channel-manager', 'booking', 'payment', 'service-order', 'partner')),
  provider             text not null,
  event_id             text not null,
  event_type           text,
  payload              jsonb not null,
  headers              jsonb,
  status               text not null default 'received' check (status in ('received', 'processing', 'processed', 'failed', 'ignored')),
  attempts             integer not null default 0 check (attempts >= 0),
  max_attempts         integer not null default 8 check (max_attempts > 0),
  next_attempt_at      timestamptz default now(),
  locked_until         timestamptz,
  last_error           text,
  received_at          timestamptz not null default now(),
  processed_at         timestamptz,
  -- Idempotenz: dieselbe Zustellung wird nie doppelt verarbeitet
  constraint webhook_events_idempotency unique (endpoint, provider, event_id)
);
comment on column public.webhook_events.headers is 'Nur unkritische Header (ohne Authorization/Signatur).';
create index webhook_events_queue_idx on public.webhook_events (next_attempt_at)
  where status in ('received', 'failed');
create index webhook_events_processing_idx on public.webhook_events (locked_until) where status = 'processing';
create index webhook_events_org_idx on public.webhook_events (organization_id, received_at desc);

-- Signatur prüfen (HMAC-SHA256, Secret aus Supabase Vault)
create or replace function public.webhook_verify_signature(p_webhook_endpoint_id uuid, p_body text, p_signature text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ref      text;
  v_secret   text;
  v_expected text;
  v_given    text := lower(regexp_replace(coalesce(p_signature, ''), '^sha256=', ''));
begin
  select e.secret_reference into v_ref from public.webhook_endpoints e where e.id = p_webhook_endpoint_id and e.active;
  if v_ref is null then
    return false;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into v_secret using substr(v_ref, 7);
  if v_secret is null then
    return false;
  end if;
  v_expected := encode(extensions.hmac(convert_to(p_body, 'UTF8'), convert_to(v_secret, 'UTF8'), 'sha256'), 'hex');
  return length(v_given) = length(v_expected) and v_given = v_expected;
end;
$$;

-- Eingang speichern. Doppelte Zustellung → vorhandenes Ereignis, is_duplicate = true.
create or replace function public.webhook_receive(
  p_endpoint text,
  p_provider text,
  p_event_id text,
  p_payload jsonb,
  p_signature_valid boolean,
  p_event_type text default null,
  p_headers jsonb default null,
  p_webhook_endpoint_id uuid default null
)
returns table (webhook_event_id uuid, is_duplicate boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id  uuid;
  v_org uuid;
begin
  if not coalesce(p_signature_valid, false) then
    raise exception 'Webhook-Signatur ungültig' using errcode = '28000';
  end if;
  if p_webhook_endpoint_id is not null then
    select e.organization_id into v_org from public.webhook_endpoints e where e.id = p_webhook_endpoint_id;
    update public.webhook_endpoints set last_received_at = now() where id = p_webhook_endpoint_id;
  end if;

  insert into public.webhook_events (organization_id, webhook_endpoint_id, endpoint, provider, event_id, event_type, payload, headers)
  values (v_org, p_webhook_endpoint_id, p_endpoint, p_provider, p_event_id, p_event_type, p_payload,
          coalesce(p_headers, '{}'::jsonb) - 'authorization' - 'Authorization' - 'x-signature' - 'x-hub-signature-256')
  on conflict on constraint webhook_events_idempotency do nothing
  returning id into v_id;

  if v_id is not null then
    return query select v_id, false;
  else
    return query
      select we.id, true from public.webhook_events we
      where we.endpoint = p_endpoint and we.provider = p_provider and we.event_id = p_event_id;
  end if;
end;
$$;

-- Nächste fällige Ereignisse sperren und zur Verarbeitung ausgeben (parallel sicher)
create or replace function public.webhook_claim(p_limit integer default 10, p_lock_seconds integer default 300)
returns setof public.webhook_events
language sql
security definer
set search_path = ''
as $$
  update public.webhook_events we
  set status = 'processing',
      attempts = we.attempts + 1,
      locked_until = now() + make_interval(secs => p_lock_seconds)
  where we.id in (
    select q.id from public.webhook_events q
    where (q.status in ('received', 'failed') and q.next_attempt_at <= now() and q.attempts < q.max_attempts)
       or (q.status = 'processing' and q.locked_until < now() and q.attempts < q.max_attempts)
    order by q.next_attempt_at nulls last
    limit p_limit
    for update skip locked
  )
  returning we.*
$$;

-- Ergebnis zurückmelden. Fehler → erneuter Versuch mit exponentiellem Backoff (max. 6 h).
create or replace function public.webhook_complete(p_webhook_event_id uuid, p_success boolean, p_error text default null, p_organization_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.webhook_events we
  set status = case when p_success then 'processed' else 'failed' end,
      processed_at = case when p_success then now() else null end,
      last_error = case when p_success then null else left(p_error, 4000) end,
      locked_until = null,
      organization_id = coalesce(we.organization_id, p_organization_id),
      next_attempt_at = case
        when p_success or we.attempts >= we.max_attempts then null
        else now() + least(interval '6 hours', make_interval(mins => power(2, we.attempts)::integer))
      end
  where we.id = p_webhook_event_id;
end;
$$;

-- Manuell wiederholen (service_role oder Admin der Organisation)
create or replace function public.webhook_retry(p_webhook_event_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.webhook_events we
  set status = 'received', next_attempt_at = now(), locked_until = null,
      max_attempts = greatest(we.max_attempts, we.attempts + 1)
  where we.id = p_webhook_event_id
    and we.status in ('failed', 'ignored', 'processed')
    and (private.is_system_context() or (we.organization_id is not null and private.is_org_admin(we.organization_id)));
  if not found then
    raise exception 'Webhook-Ereignis nicht gefunden oder keine Berechtigung' using errcode = '42501';
  end if;
end;
$$;

-- Buchung aus Channel Manager / Airbnb / Booking.com idempotent übernehmen
create or replace function public.upsert_external_booking(
  p_organization_id uuid,
  p_property_id uuid,
  p_source text,
  p_external_booking_id text,
  p_check_in timestamptz,
  p_check_out timestamptz,
  p_status text default 'confirmed',
  p_guest_first_name text default null,
  p_guest_last_name text default null,
  p_guest_email text default null,
  p_guest_phone text default null,
  p_guest_count integer default null,
  p_booking_source_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.bookings (organization_id, property_id, booking_source_id, source, external_booking_id,
                               guest_first_name, guest_last_name, guest_email, guest_phone, guest_count,
                               check_in, check_out, status)
  values (p_organization_id, p_property_id, p_booking_source_id, p_source, p_external_booking_id,
          p_guest_first_name, p_guest_last_name, p_guest_email, p_guest_phone, p_guest_count,
          p_check_in, p_check_out, p_status)
  on conflict (organization_id, source, external_booking_id) where external_booking_id is not null
  do update set
    check_in = excluded.check_in,
    check_out = excluded.check_out,
    status = excluded.status,
    guest_first_name = coalesce(excluded.guest_first_name, public.bookings.guest_first_name),
    guest_last_name = coalesce(excluded.guest_last_name, public.bookings.guest_last_name),
    guest_email = coalesce(excluded.guest_email, public.bookings.guest_email),
    guest_phone = coalesce(excluded.guest_phone, public.bookings.guest_phone),
    guest_count = coalesce(excluded.guest_count, public.bookings.guest_count)
  returning id into v_id;
  if p_booking_source_id is not null then
    update public.booking_sources set last_synced_at = now() where id = p_booking_source_id;
  end if;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Automation Engine
-- -----------------------------------------------------------------------------
-- Bedingungen prüfen
create or replace function private.automation_conditions_met(p_condition jsonb, p_context jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_condition ? 'sources'
     and not coalesce(p_context ->> 'source', '') in (select jsonb_array_elements_text(p_condition -> 'sources')) then
    return false;
  end if;
  if coalesce((p_condition ->> 'exclude_owner_stays')::boolean, false) and p_context ->> 'source' = 'owner' then
    return false;
  end if;
  if p_condition ? 'min_nights' and coalesce((p_context ->> 'nights')::numeric, 0) < (p_condition ->> 'min_nights')::numeric then
    return false;
  end if;
  if p_condition ? 'property_ids'
     and not coalesce(p_context ->> 'property_id', '') in (select jsonb_array_elements_text(p_condition -> 'property_ids')) then
    return false;
  end if;
  if p_context ? 'item_status'
     and not coalesce(p_context ->> 'item_status', '') in (
       select jsonb_array_elements_text(coalesce(p_condition -> 'item_statuses', '["defect"]'::jsonb))) then
    return false;
  end if;
  if p_condition ? 'overall_statuses' and p_context ? 'overall_status'
     and not coalesce(p_context ->> 'overall_status', '') in (select jsonb_array_elements_text(p_condition -> 'overall_statuses')) then
    return false;
  end if;
  return true;
end;
$$;

-- Platzhalter {property_name}, {guest_name}, {item_name}, {order_number} ersetzen
create or replace function private.automation_text(p_template text, p_context jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(replace(replace(replace(coalesce(p_template, ''),
    '{property_name}', coalesce(p_context ->> 'property_name', '')),
    '{guest_name}', coalesce(p_context ->> 'guest_name', '')),
    '{item_name}', coalesce(p_context ->> 'item_name', '')),
    '{order_number}', coalesce(p_context ->> 'order_number', ''))
$$;

-- Serviceart über Code finden (eigene der Organisation vor globaler)
create or replace function private.service_type_by_code(p_organization_id uuid, p_code text)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select st.id from public.service_types st
  where st.code = p_code and st.active and (st.organization_id = p_organization_id or st.organization_id is null)
  order by st.organization_id nulls last
  limit 1
$$;

-- Aktion ausführen
create or replace function private.execute_automation_action(p_rule public.automation_rules, p_context jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_action    jsonb := p_rule.action_config;
  v_trigger   jsonb := p_rule.trigger_config;
  v_type      text := p_rule.action_config ->> 'type';
  v_org       uuid := p_rule.organization_id;
  v_property  uuid := (p_context ->> 'property_id')::uuid;
  v_anchor    timestamptz;
  v_start     timestamptz;
  v_end       timestamptz;
  v_id        uuid;
  v_type_id   uuid;
  v_partner   record;
  v_order     uuid;
  v_template  uuid;
  v_count     integer := 0;
  v_exclude   uuid[];
begin
  v_anchor := coalesce((p_context ->> coalesce(v_trigger ->> 'anchor', 'check_out'))::timestamptz, now());
  v_start := v_anchor + make_interval(hours => coalesce((v_trigger ->> 'offset_hours')::integer, 0));
  v_end := case when v_trigger ? 'duration_hours'
                then v_start + make_interval(hours => (v_trigger ->> 'duration_hours')::integer) end;

  if v_type in ('create_task', 'create_cleaning_task') then
    v_type_id := private.service_type_by_code(v_org, coalesce(v_action ->> 'service_type_code',
                   case when v_type = 'create_cleaning_task' then 'cleaning' end));
    insert into public.service_tasks (organization_id, property_id, booking_id, inspection_id, service_type_id,
                                      title, description, priority, scheduled_start, scheduled_end)
    values (v_org, v_property, (p_context ->> 'booking_id')::uuid, (p_context ->> 'inspection_id')::uuid, v_type_id,
            coalesce(nullif(private.automation_text(v_action ->> 'title', p_context), ''),
                     case when v_type = 'create_cleaning_task' then 'Endreinigung' else p_rule.name end),
            nullif(private.automation_text(v_action ->> 'description', p_context), ''),
            coalesce(v_action ->> 'priority', 'normal'), v_start, v_end)
    returning id into v_id;

    if coalesce((v_action ->> 'auto_assign')::boolean, false) and v_type_id is not null then
      select * into v_partner from public.match_service_partners(v_property, v_type_id, 1, null, v_start) limit 1;
      if v_partner.service_partner_id is not null then
        insert into public.service_orders (organization_id, service_task_id, property_id, service_partner_id, title,
                                           description, status, scheduled_at, estimated_cost, match_score)
        values (v_org, v_id, v_property, v_partner.service_partner_id,
                (select t.title from public.service_tasks t where t.id = v_id),
                nullif(private.automation_text(v_action ->> 'description', p_context), ''),
                'offered', v_start, v_partner.price_from, v_partner.score)
        returning id into v_order;
      end if;
    end if;
    return jsonb_build_object('service_task_id', v_id, 'service_order_id', v_order);

  elsif v_type = 'create_inspection' then
    v_template := coalesce((v_action ->> 'template_id')::uuid,
      (select t.id from public.inspection_templates t where t.organization_id = v_org and t.active order by t.created_at limit 1));
    insert into public.inspections (organization_id, property_id, template_id, booking_id, scheduled_at, notes)
    values (v_org, v_property, v_template, (p_context ->> 'booking_id')::uuid, v_start,
            nullif(private.automation_text(v_action ->> 'notes', p_context), ''))
    returning id into v_id;
    return jsonb_build_object('inspection_id', v_id);

  elsif v_type = 'create_repair' then
    insert into public.repairs (organization_id, property_id, inspection_id, inspection_item_id, title, description,
                                priority, estimated_cost)
    values (v_org, v_property, (p_context ->> 'inspection_id')::uuid, (p_context ->> 'inspection_item_id')::uuid,
            coalesce(v_action ->> 'title_prefix', 'Mangel: ') || coalesce(p_context ->> 'item_name', 'Kontrollpunkt'),
            p_context ->> 'item_notes',
            coalesce(v_action ->> 'priority', case when p_context ->> 'item_status' = 'defect' then 'high' else 'normal' end),
            (p_context ->> 'estimated_cost')::numeric)
    on conflict (inspection_item_id) where inspection_item_id is not null and status <> 'cancelled' do nothing
    returning id into v_id;
    return jsonb_build_object('repair_id', v_id);

  elsif v_type = 'notify' then
    insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
    select v_org, u.user_id, coalesce(v_action ->> 'notification_type', 'automation'),
           coalesce(nullif(private.automation_text(v_action ->> 'title', p_context), ''), p_rule.name),
           nullif(private.automation_text(v_action ->> 'message', p_context), ''),
           p_context ->> 'entity_type', (p_context ->> 'entity_id')::uuid
    from (
      select m.user_id from public.organization_members m
      where m.organization_id = v_org and m.status = 'active'
        and m.role in (select jsonb_array_elements_text(coalesce(v_action -> 'roles', '["admin"]'::jsonb)))
      union
      select p.owner_user_id from public.properties p
      where coalesce((v_action ->> 'include_owner')::boolean, false) and p.id = v_property and p.owner_user_id is not null
    ) u;
    get diagnostics v_count = row_count;
    return jsonb_build_object('notifications', v_count);

  elsif v_type = 'cancel_booking_tasks' then
    update public.service_tasks set status = 'cancelled'
    where booking_id = (p_context ->> 'booking_id')::uuid and status in ('pending', 'assigned');
    get diagnostics v_count = row_count;
    update public.service_orders set status = 'cancelled'
    where service_task_id in (select t.id from public.service_tasks t where t.booking_id = (p_context ->> 'booking_id')::uuid)
      and status in ('draft', 'offered');
    update public.inspections set status = 'cancelled'
    where booking_id = (p_context ->> 'booking_id')::uuid and status = 'scheduled';
    return jsonb_build_object('cancelled_tasks', v_count);

  elsif v_type = 'offer_next_partner' then
    select array_agg(o.service_partner_id) into v_exclude from public.service_orders o
    where o.service_task_id = (p_context ->> 'service_task_id')::uuid and o.status = 'rejected';
    select * into v_partner from public.match_service_partners(
      v_property, (select t.service_type_id from public.service_tasks t where t.id = (p_context ->> 'service_task_id')::uuid),
      1, v_exclude, (p_context ->> 'scheduled_at')::timestamptz) limit 1;
    if v_partner.service_partner_id is null then
      return jsonb_build_object('service_order_id', null, 'reason', 'kein weiterer Partner verfügbar');
    end if;
    insert into public.service_orders (organization_id, service_task_id, property_id, service_partner_id, title, description,
                                       status, scheduled_at, estimated_cost, match_score)
    select o.organization_id, o.service_task_id, o.property_id, v_partner.service_partner_id, o.title, o.description,
           'offered', o.scheduled_at, coalesce(v_partner.price_from, o.estimated_cost), v_partner.score
    from public.service_orders o where o.id = (p_context ->> 'service_order_id')::uuid
    returning id into v_order;
    return jsonb_build_object('service_order_id', v_order);
  end if;

  raise exception 'Unbekannte Aktion %', v_type;
end;
$$;

-- Alle aktiven Regeln eines Auslösers ausführen. Jede Regel läuft höchstens einmal
-- je Auslöser und Objekt (idempotency_key); Fehler einer Regel stoppen die anderen nicht.
create or replace function private.run_automations(
  p_organization_id uuid,
  p_trigger_type text,
  p_entity_type text,
  p_entity_id uuid,
  p_context jsonb,
  p_idempotency_suffix text default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule  public.automation_rules;
  v_run   uuid;
  v_out   jsonb;
  v_count integer := 0;
  v_ctx   jsonb := p_context || jsonb_build_object('entity_type', p_entity_type, 'entity_id', p_entity_id);
begin
  for v_rule in
    select * from public.automation_rules r
    where r.organization_id = p_organization_id and r.trigger_type = p_trigger_type and r.active
    order by r.sort_order, r.created_at
  loop
    v_run := null;
    insert into public.automation_runs (automation_rule_id, organization_id, trigger_type, entity_type, entity_id,
                                        idempotency_key, input_data)
    values (v_rule.id, p_organization_id, p_trigger_type, p_entity_type, p_entity_id,
            p_trigger_type || ':' || p_entity_id || coalesce(':' || p_idempotency_suffix, ''), v_ctx)
    on conflict (automation_rule_id, idempotency_key) do nothing
    returning id into v_run;
    continue when v_run is null;

    begin
      if not private.automation_conditions_met(v_rule.condition_config, v_ctx) then
        update public.automation_runs set status = 'skipped', completed_at = now(),
               output_data = '{"reason": "Bedingungen nicht erfüllt"}' where id = v_run;
        continue;
      end if;
      v_out := private.execute_automation_action(v_rule, v_ctx);
      update public.automation_runs set status = 'completed', output_data = v_out, completed_at = now() where id = v_run;
      v_count := v_count + 1;
    exception when others then
      update public.automation_runs set status = 'failed', error_message = sqlerrm, completed_at = now() where id = v_run;
    end;
  end loop;
  return v_count;
end;
$$;

-- Auslöser: Buchungen
create or replace function private.automation_on_booking()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ctx jsonb;
begin
  v_ctx := jsonb_build_object(
    'booking_id', new.id,
    'property_id', new.property_id,
    'property_name', (select p.name from public.properties p where p.id = new.property_id),
    'source', new.source,
    'check_in', new.check_in,
    'check_out', new.check_out,
    'nights', ceil(extract(epoch from (new.check_out - new.check_in)) / 86400),
    'guest_count', new.guest_count,
    'guest_name', nullif(trim(coalesce(new.guest_first_name, '') || ' ' || coalesce(new.guest_last_name, '')), ''));

  if new.status = 'confirmed' and (tg_op = 'INSERT' or old.status is distinct from 'confirmed') then
    perform private.run_automations(new.organization_id, 'booking_created', 'booking', new.id, v_ctx);
    perform private.run_automations(new.organization_id, 'booking_checkout', 'booking', new.id, v_ctx);
  elsif tg_op = 'UPDATE' and new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    perform private.run_automations(new.organization_id, 'booking_cancelled', 'booking', new.id, v_ctx);
  end if;

  -- Verschobener Check-out: offene, automatisch erzeugte Termine mitziehen
  if tg_op = 'UPDATE' and new.status = 'confirmed' and new.check_out is distinct from old.check_out then
    update public.service_tasks t
    set scheduled_start = t.scheduled_start + (new.check_out - old.check_out),
        scheduled_end = t.scheduled_end + (new.check_out - old.check_out)
    where t.booking_id = new.id and t.status in ('pending', 'assigned', 'accepted') and t.scheduled_start is not null;
    update public.inspections i
    set scheduled_at = i.scheduled_at + (new.check_out - old.check_out)
    where i.booking_id = new.id and i.status = 'scheduled' and i.scheduled_at is not null;
  end if;
  return new;
end;
$$;

create trigger bookings_automation after insert or update of status, check_out on public.bookings
  for each row execute function private.automation_on_booking();

-- Auslöser: Mangel an einem Prüfpunkt
create or replace function private.automation_on_inspection_item()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_insp public.inspections;
begin
  if new.status not in ('warning', 'defect') or (tg_op = 'UPDATE' and old.status = new.status) then
    return new;
  end if;
  select * into v_insp from public.inspections i where i.id = new.inspection_id;
  perform private.run_automations(v_insp.organization_id, 'inspection_item_defect', 'inspection_item', new.id,
    jsonb_build_object(
      'inspection_id', v_insp.id,
      'inspection_item_id', new.id,
      'property_id', v_insp.property_id,
      'property_name', (select p.name from public.properties p where p.id = v_insp.property_id),
      'item_name', new.name,
      'item_notes', new.notes,
      'item_status', new.status,
      'estimated_cost', new.estimated_cost),
    new.status);
  return new;
end;
$$;

create trigger inspection_items_automation after insert or update of status on public.inspection_items
  for each row execute function private.automation_on_inspection_item();

-- Auslöser: Kontrolle abgeschlossen
create or replace function private.automation_on_inspection()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    perform private.run_automations(new.organization_id, 'inspection_completed', 'inspection', new.id,
      jsonb_build_object(
        'inspection_id', new.id,
        'property_id', new.property_id,
        'property_name', (select p.name from public.properties p where p.id = new.property_id),
        'overall_status', new.overall_status,
        'defects', (select count(*) from public.inspection_items ii where ii.inspection_id = new.id and ii.status in ('warning', 'defect'))));
  end if;
  return new;
end;
$$;

create trigger inspections_automation after update of status on public.inspections
  for each row execute function private.automation_on_inspection();

-- Auslöser: Partner lehnt Auftrag ab
create or replace function private.automation_on_service_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'rejected' and old.status is distinct from 'rejected' then
    perform private.run_automations(new.organization_id, 'service_order_rejected', 'service_order', new.id,
      jsonb_build_object(
        'service_order_id', new.id,
        'service_task_id', new.service_task_id,
        'property_id', new.property_id,
        'property_name', (select p.name from public.properties p where p.id = new.property_id),
        'order_number', new.order_number,
        'scheduled_at', new.scheduled_at));
  end if;
  return new;
end;
$$;

create trigger service_orders_automation after update of status on public.service_orders
  for each row execute function private.automation_on_service_order();

-- Zeitgesteuert (pg_cron, z. B. stündlich): fällige Wartung, überfällige Rechnungen, alte Sperren
create or replace function public.run_scheduled_automations()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m        record;
  v_due      integer := 0;
  v_overdue  integer := 0;
begin
  for v_m in
    update public.maintenance m
    set status = case when m.next_due_at < now() then 'overdue' else 'due' end
    where m.status in ('active', 'due') and m.next_due_at is not null
      and m.next_due_at <= now() + interval '14 days'
      and m.status is distinct from (case when m.next_due_at < now() then 'overdue' else 'due' end)
    returning m.*
  loop
    v_due := v_due + 1;
    perform private.run_automations(v_m.organization_id, 'maintenance_due', 'maintenance', v_m.id,
      jsonb_build_object(
        'maintenance_id', v_m.id,
        'property_id', v_m.property_id,
        'property_name', (select p.name from public.properties p where p.id = v_m.property_id),
        'item_name', v_m.title,
        'check_out', v_m.next_due_at,
        'next_due_at', v_m.next_due_at),
      to_char(v_m.next_due_at, 'YYYY-MM-DD'));
  end loop;

  update public.invoices set status = 'overdue'
  where status in ('received', 'approved') and due_date < current_date;
  get diagnostics v_overdue = row_count;

  return jsonb_build_object('maintenance_due', v_due, 'invoices_overdue', v_overdue);
end;
$$;

-- >>> 20261030001000_rls_policies.sql
-- =============================================================================
-- HUSORA · Migration 1000 · Row Level Security
-- =============================================================================
-- Grundregel: Zugriff nur auf Zeilen von Organisationen, in denen der Benutzer
-- aktives Mitglied ist. Darüber hinaus:
--   owner            → nur eigene Häuser (properties.owner_user_id / property_users)
--   service_partner  → nur zugewiesene Aufträge, Aufgaben und Kontrollen seines Betriebs
--   cleaner          → nur ihm zugewiesene Aufgaben (+ Lesezugriff auf das Haus)
--   viewer           → alles der Organisation lesen, nichts ändern
--   admin / property_manager / service_manager → alle Daten der Organisation
--   Super-Admin      → interne Husora-Verwaltung (alle Organisationen)
-- Hilfsfunktionen liegen im nicht veröffentlichten Schema "private" (security definer,
-- dadurch keine rekursiven Policies). Argumentlose Aufrufe stehen in (select …),
-- damit Postgres sie je Abfrage nur einmal auswertet.

-- -----------------------------------------------------------------------------
-- Weitere Zugriffs-Helfer
-- -----------------------------------------------------------------------------
create or replace function private.shares_org_with(p_user_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.organization_members m
    where m.user_id = p_user_id
      and m.organization_id in (select private.my_organization_ids())
  )
$$;

create or replace function private.is_user_in_org(p_user_id uuid, p_organization_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.organization_members m
    where m.user_id = p_user_id and m.organization_id = p_organization_id and m.status = 'active'
  )
$$;

create or replace function private.template_org(p_template_id uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$ select t.organization_id from public.inspection_templates t where t.id = p_template_id $$;

create or replace function private.inspection_org(p_inspection_id uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$ select i.organization_id from public.inspections i where i.id = p_inspection_id $$;

-- Aufgabe sehen: Verwaltung/viewer, Eigentümer, eingeteilte Person, beauftragter Partner
create or replace function private.can_read_task(p_service_task_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.service_tasks t
    where t.id = p_service_task_id
      and (
        private.can_read_org(t.organization_id)
        or private.is_property_owner(t.property_id)
        or (t.assigned_user_id = private.current_user_id() and private.is_org_member(t.organization_id))
        or private.is_partner_member(t.assigned_partner_id)
      )
  )
$$;

-- Partnerbetrieb sehen: Verwaltung/viewer, eigene Mitarbeiter, Eigentümer mit Auftrag dieses Partners
create or replace function private.can_read_partner(p_service_partner_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.can_read_org(private.partner_org(p_service_partner_id))
      or private.is_partner_member(p_service_partner_id)
      or exists (
        select 1 from public.service_orders o
        where o.service_partner_id = p_service_partner_id and private.is_property_owner(o.property_id)
      )
$$;

-- -----------------------------------------------------------------------------
-- Spalten-Schutz für Rollen mit eingeschränktem Schreibrecht
-- -----------------------------------------------------------------------------
-- Eigentümer/Hausverwalter dürfen Hausdaten pflegen, aber nicht Organisation oder Eigentümer ändern
create or replace function private.properties_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_system_context() and not private.is_org_staff(old.organization_id) then
    new.organization_id := old.organization_id;
    new.owner_user_id := old.owner_user_id;
    new.status := case when new.status = 'archived' then old.status else new.status end;
  end if;
  return new;
end;
$$;
create trigger properties_guard before update on public.properties
  for each row execute function private.properties_guard();

-- Partner pflegen ihr Profil; Status, Bewertung und interne Notizen bleiben der Verwaltung vorbehalten
create or replace function private.service_partners_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_system_context() and not private.is_org_staff(old.organization_id) then
    new.organization_id := old.organization_id;
    new.status := old.status;
    new.rating := old.rating;
    new.notes := old.notes;
  end if;
  return new;
end;
$$;
create trigger service_partners_guard before update on public.service_partners
  for each row execute function private.service_partners_guard();

-- Prüfer (Mitarbeiter/Partner) dürfen nur Ablauf und Ergebnis der Kontrolle ändern
create or replace function private.inspections_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status   text;
  v_started  timestamptz;
  v_done     timestamptz;
  v_overall  text;
  v_notes    text;
begin
  if not private.is_system_context()
     and not private.is_org_staff(old.organization_id)
     and not private.can_manage_property(old.property_id) then
    if new.status is distinct from old.status and new.status not in ('in_progress', 'completed') then
      raise exception 'Status "%" darf nur von der Verwaltung gesetzt werden', new.status using errcode = '42501';
    end if;
    v_status := new.status; v_started := new.started_at; v_done := new.completed_at;
    v_overall := new.overall_status; v_notes := new.notes;
    new := old;
    new.status := v_status; new.started_at := v_started; new.completed_at := v_done;
    new.overall_status := v_overall; new.notes := v_notes;
  end if;
  if new.status = 'in_progress' then
    new.started_at := coalesce(new.started_at, now());
  elsif new.status = 'completed' then
    new.started_at := coalesce(new.started_at, now());
    new.completed_at := coalesce(new.completed_at, now());
  end if;
  return new;
end;
$$;
create trigger inspections_guard before update on public.inspections
  for each row execute function private.inspections_guard();

-- Prüfpunkt: geprüft von / am automatisch setzen
create or replace function private.inspection_items_checked()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status <> 'not_checked' and (tg_op = 'INSERT' or new.status is distinct from old.status) then
    new.checked_at := now();
    new.checked_by := coalesce(private.current_user_id(), new.checked_by);
  elsif new.status = 'not_checked' then
    new.checked_at := null;
    new.checked_by := null;
  end if;
  return new;
end;
$$;
create trigger inspection_items_checked before insert or update of status on public.inspection_items
  for each row execute function private.inspection_items_checked();

-- Letzter aktiver Admin einer Organisation darf nicht entfernt oder herabgestuft werden
create or replace function private.keep_last_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role = 'admin' and old.status = 'active'
     and (tg_op = 'DELETE' or new.role <> 'admin' or new.status <> 'active')
     and exists (select 1 from public.organizations o where o.id = old.organization_id)
     and not exists (
       select 1 from public.organization_members m
       where m.organization_id = old.organization_id and m.id <> old.id and m.role = 'admin' and m.status = 'active'
     ) then
    if pg_trigger_depth() > 1 then
      return coalesce(new, old);  -- Organisation wird gerade gelöscht (cascade)
    end if;
    raise exception 'Die Organisation braucht mindestens einen aktiven Admin' using errcode = '23514';
  end if;
  return coalesce(new, old);
end;
$$;
create trigger organization_members_keep_last_admin before update or delete on public.organization_members
  for each row execute function private.keep_last_admin();

-- -----------------------------------------------------------------------------
-- RLS aktivieren – ausnahmslos auf jeder Tabelle
-- -----------------------------------------------------------------------------
alter table public.users                    enable row level security;
alter table public.organizations            enable row level security;
alter table public.organization_members     enable row level security;
alter table public.properties               enable row level security;
alter table public.property_users           enable row level security;
alter table public.property_features        enable row level security;
alter table public.service_types            enable row level security;
alter table public.service_partners         enable row level security;
alter table public.service_partner_users    enable row level security;
alter table public.service_partner_services enable row level security;
alter table public.service_partner_areas    enable row level security;
alter table public.booking_sources          enable row level security;
alter table public.bookings                 enable row level security;
alter table public.inspection_templates     enable row level security;
alter table public.inspection_template_items enable row level security;
alter table public.inspections              enable row level security;
alter table public.inspection_items         enable row level security;
alter table public.service_tasks            enable row level security;
alter table public.service_orders           enable row level security;
alter table public.maintenance              enable row level security;
alter table public.repairs                  enable row level security;
alter table public.documents                enable row level security;
alter table public.photos                   enable row level security;
alter table public.quotes                   enable row level security;
alter table public.invoices                 enable row level security;
alter table public.automation_rules         enable row level security;
alter table public.automation_runs          enable row level security;
alter table public.notifications            enable row level security;
alter table public.messages                 enable row level security;
alter table public.audit_logs               enable row level security;
alter table public.webhook_endpoints        enable row level security;
alter table public.webhook_events           enable row level security;

-- -----------------------------------------------------------------------------
-- users
-- -----------------------------------------------------------------------------
create policy users_select on public.users for select to authenticated
  using (id = (select private.current_user_id()) or (select private.is_super_admin()) or private.shares_org_with(id));
create policy users_update_self on public.users for update to authenticated
  using (id = (select private.current_user_id()))
  with check (id = (select private.current_user_id()));
-- insert/delete: nur über Auth-Trigger bzw. service_role

-- -----------------------------------------------------------------------------
-- organizations / organization_members
-- -----------------------------------------------------------------------------
create policy organizations_select on public.organizations for select to authenticated
  using (private.is_org_member(id));
create policy organizations_insert on public.organizations for insert to authenticated
  with check ((select private.current_user_id()) is not null);
create policy organizations_update on public.organizations for update to authenticated
  using (private.is_org_admin(id)) with check (private.is_org_admin(id));
create policy organizations_delete on public.organizations for delete to authenticated
  using ((select private.is_super_admin()));

create policy organization_members_select on public.organization_members for select to authenticated
  using (user_id = (select private.current_user_id()) or private.can_read_org(organization_id));
create policy organization_members_insert on public.organization_members for insert to authenticated
  with check (private.is_org_admin(organization_id));
create policy organization_members_update on public.organization_members for update to authenticated
  using (private.is_org_admin(organization_id)) with check (private.is_org_admin(organization_id));
create policy organization_members_delete on public.organization_members for delete to authenticated
  using (private.is_org_admin(organization_id) or user_id = (select private.current_user_id()));

-- -----------------------------------------------------------------------------
-- properties, property_users, property_features
-- -----------------------------------------------------------------------------
create policy properties_select on public.properties for select to authenticated
  using (private.can_read_property(id));
create policy properties_insert on public.properties for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy properties_update on public.properties for update to authenticated
  using (private.can_manage_property(id)) with check (private.can_manage_property(id));
create policy properties_delete on public.properties for delete to authenticated
  using (private.is_org_admin(organization_id));

create policy property_users_select on public.property_users for select to authenticated
  using (user_id = (select private.current_user_id()) or private.can_manage_property(property_id)
         or private.can_read_org(private.property_org(property_id)));
create policy property_users_insert on public.property_users for insert to authenticated
  with check (private.is_org_staff(private.property_org(property_id)) or private.is_property_owner(property_id));
create policy property_users_update on public.property_users for update to authenticated
  using (private.is_org_staff(private.property_org(property_id)) or private.is_property_owner(property_id))
  with check (private.is_org_staff(private.property_org(property_id)) or private.is_property_owner(property_id));
create policy property_users_delete on public.property_users for delete to authenticated
  using (private.is_org_staff(private.property_org(property_id)) or private.is_property_owner(property_id));

create policy property_features_select on public.property_features for select to authenticated
  using (private.can_read_property(property_id));
create policy property_features_insert on public.property_features for insert to authenticated
  with check (private.can_manage_property(property_id));
create policy property_features_update on public.property_features for update to authenticated
  using (private.can_manage_property(property_id)) with check (private.can_manage_property(property_id));
create policy property_features_delete on public.property_features for delete to authenticated
  using (private.can_manage_property(property_id));

-- -----------------------------------------------------------------------------
-- service_types (global lesbar, global nur Super-Admin schreibbar)
-- -----------------------------------------------------------------------------
create policy service_types_select on public.service_types for select to authenticated
  using (organization_id is null or private.is_org_member(organization_id));
create policy service_types_insert on public.service_types for insert to authenticated
  with check (case when organization_id is null then (select private.is_super_admin()) else private.is_org_staff(organization_id) end);
create policy service_types_update on public.service_types for update to authenticated
  using (case when organization_id is null then (select private.is_super_admin()) else private.is_org_staff(organization_id) end)
  with check (case when organization_id is null then (select private.is_super_admin()) else private.is_org_staff(organization_id) end);
create policy service_types_delete on public.service_types for delete to authenticated
  using (case when organization_id is null then (select private.is_super_admin()) else private.is_org_staff(organization_id) end);

-- -----------------------------------------------------------------------------
-- service_partners und Unterlagen
-- -----------------------------------------------------------------------------
create policy service_partners_select on public.service_partners for select to authenticated
  using (private.can_read_org(organization_id) or private.can_read_partner(id));
create policy service_partners_insert on public.service_partners for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy service_partners_update on public.service_partners for update to authenticated
  using (private.is_org_staff(organization_id) or private.is_partner_member(id))
  with check (private.is_org_staff(organization_id) or private.is_partner_member(id));
create policy service_partners_delete on public.service_partners for delete to authenticated
  using (private.is_org_staff(organization_id));

create policy service_partner_users_select on public.service_partner_users for select to authenticated
  using (user_id = (select private.current_user_id()) or private.is_partner_member(service_partner_id)
         or private.can_read_org(private.partner_org(service_partner_id)));
create policy service_partner_users_insert on public.service_partner_users for insert to authenticated
  with check (private.is_org_staff(private.partner_org(service_partner_id)));
create policy service_partner_users_update on public.service_partner_users for update to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)))
  with check (private.is_org_staff(private.partner_org(service_partner_id)));
create policy service_partner_users_delete on public.service_partner_users for delete to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)));

create policy service_partner_services_select on public.service_partner_services for select to authenticated
  using (private.can_read_partner(service_partner_id));
create policy service_partner_services_insert on public.service_partner_services for insert to authenticated
  with check (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));
create policy service_partner_services_update on public.service_partner_services for update to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id))
  with check (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));
create policy service_partner_services_delete on public.service_partner_services for delete to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));

create policy service_partner_areas_select on public.service_partner_areas for select to authenticated
  using (private.can_read_partner(service_partner_id));
create policy service_partner_areas_insert on public.service_partner_areas for insert to authenticated
  with check (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));
create policy service_partner_areas_update on public.service_partner_areas for update to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id))
  with check (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));
create policy service_partner_areas_delete on public.service_partner_areas for delete to authenticated
  using (private.is_org_staff(private.partner_org(service_partner_id)) or private.is_partner_member(service_partner_id));

-- -----------------------------------------------------------------------------
-- booking_sources, bookings (Gästedaten: nur Verwaltung, viewer und Eigentümer)
-- -----------------------------------------------------------------------------
create policy booking_sources_select on public.booking_sources for select to authenticated
  using (private.can_read_org(organization_id));
create policy booking_sources_insert on public.booking_sources for insert to authenticated
  with check (private.is_org_admin(organization_id));
create policy booking_sources_update on public.booking_sources for update to authenticated
  using (private.is_org_admin(organization_id)) with check (private.is_org_admin(organization_id));
create policy booking_sources_delete on public.booking_sources for delete to authenticated
  using (private.is_org_admin(organization_id));

create policy bookings_select on public.bookings for select to authenticated
  using (private.can_read_org(organization_id) or private.is_property_owner(property_id));
create policy bookings_insert on public.bookings for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy bookings_update on public.bookings for update to authenticated
  using (private.is_org_staff(organization_id) or private.can_manage_property(property_id))
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy bookings_delete on public.bookings for delete to authenticated
  using (private.is_org_staff(organization_id));

-- -----------------------------------------------------------------------------
-- Hauskontrollen
-- -----------------------------------------------------------------------------
create policy inspection_templates_select on public.inspection_templates for select to authenticated
  using (private.is_org_member(organization_id));
create policy inspection_templates_insert on public.inspection_templates for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy inspection_templates_update on public.inspection_templates for update to authenticated
  using (private.is_org_staff(organization_id)) with check (private.is_org_staff(organization_id));
create policy inspection_templates_delete on public.inspection_templates for delete to authenticated
  using (private.is_org_staff(organization_id));

create policy inspection_template_items_select on public.inspection_template_items for select to authenticated
  using (private.is_org_member(private.template_org(template_id)));
create policy inspection_template_items_insert on public.inspection_template_items for insert to authenticated
  with check (private.is_org_staff(private.template_org(template_id)));
create policy inspection_template_items_update on public.inspection_template_items for update to authenticated
  using (private.is_org_staff(private.template_org(template_id)))
  with check (private.is_org_staff(private.template_org(template_id)));
create policy inspection_template_items_delete on public.inspection_template_items for delete to authenticated
  using (private.is_org_staff(private.template_org(template_id)));

create policy inspections_select on public.inspections for select to authenticated
  using (
    private.can_read_org(organization_id)
    or private.is_property_owner(property_id)
    or (inspector_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(service_partner_id)
  );
create policy inspections_insert on public.inspections for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy inspections_update on public.inspections for update to authenticated
  using (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (inspector_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(service_partner_id)
  )
  with check (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (inspector_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(service_partner_id)
  );
create policy inspections_delete on public.inspections for delete to authenticated
  using (private.is_org_staff(organization_id));

create policy inspection_items_select on public.inspection_items for select to authenticated
  using (private.can_read_inspection(inspection_id));
create policy inspection_items_insert on public.inspection_items for insert to authenticated
  with check (private.can_work_inspection(inspection_id));
create policy inspection_items_update on public.inspection_items for update to authenticated
  using (private.can_work_inspection(inspection_id)) with check (private.can_work_inspection(inspection_id));
create policy inspection_items_delete on public.inspection_items for delete to authenticated
  using (private.is_org_staff(private.inspection_org(inspection_id)));

-- -----------------------------------------------------------------------------
-- service_tasks (cleaner: nur eigene Aufgaben)
-- -----------------------------------------------------------------------------
create policy service_tasks_select on public.service_tasks for select to authenticated
  using (
    private.can_read_org(organization_id)
    or private.is_property_owner(property_id)
    or (assigned_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(assigned_partner_id)
  );
create policy service_tasks_insert on public.service_tasks for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy service_tasks_update on public.service_tasks for update to authenticated
  using (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (assigned_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(assigned_partner_id)
  )
  with check (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (assigned_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
    or private.is_partner_member(assigned_partner_id)
  );
create policy service_tasks_delete on public.service_tasks for delete to authenticated
  using (private.is_org_staff(organization_id));

-- -----------------------------------------------------------------------------
-- service_orders (service_partner: nur Aufträge seines Betriebs, keine Entwürfe)
-- -----------------------------------------------------------------------------
create policy service_orders_select on public.service_orders for select to authenticated
  using (
    private.can_read_org(organization_id)
    or private.is_property_owner(property_id)
    or (status <> 'draft' and private.is_partner_member(service_partner_id))
  );
create policy service_orders_insert on public.service_orders for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy service_orders_update on public.service_orders for update to authenticated
  using (private.is_org_staff(organization_id) or (status <> 'draft' and private.is_partner_member(service_partner_id)))
  with check (private.is_org_staff(organization_id) or private.is_partner_member(service_partner_id));
create policy service_orders_delete on public.service_orders for delete to authenticated
  using (private.is_org_staff(organization_id));

-- -----------------------------------------------------------------------------
-- maintenance, repairs
-- -----------------------------------------------------------------------------
create policy maintenance_select on public.maintenance for select to authenticated
  using (private.can_read_org(organization_id) or private.is_property_owner(property_id)
         or private.is_partner_member(assigned_partner_id));
create policy maintenance_insert on public.maintenance for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy maintenance_update on public.maintenance for update to authenticated
  using (private.is_org_staff(organization_id) or private.can_manage_property(property_id))
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy maintenance_delete on public.maintenance for delete to authenticated
  using (private.is_org_staff(organization_id));

create policy repairs_select on public.repairs for select to authenticated
  using (
    private.can_read_org(organization_id)
    or private.is_property_owner(property_id)
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
    or (inspection_id is not null and private.can_read_inspection(inspection_id))
  );
-- Melden: Verwaltung, Eigentümer/Hausverwalter oder Prüfer während der Kontrolle
create policy repairs_insert on public.repairs for insert to authenticated
  with check (
    private.is_org_staff(organization_id)
    or (status = 'reported' and (
          private.can_manage_property(property_id)
          or (inspection_id is not null and private.can_work_inspection(inspection_id))))
  );
create policy repairs_update on public.repairs for update to authenticated
  using (private.is_org_staff(organization_id) or private.can_manage_property(property_id))
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
create policy repairs_delete on public.repairs for delete to authenticated
  using (private.is_org_staff(organization_id));

-- -----------------------------------------------------------------------------
-- documents, photos
-- -----------------------------------------------------------------------------
create policy documents_select on public.documents for select to authenticated
  using (
    private.can_read_org(organization_id)
    or uploaded_by = (select private.current_user_id())
    or (property_id is not null and private.is_property_owner(property_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
  );
create policy documents_insert on public.documents for insert to authenticated
  with check (
    private.is_org_staff(organization_id)
    or (property_id is not null and private.can_manage_property(property_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id) and private.is_org_member(organization_id))
  );
create policy documents_update on public.documents for update to authenticated
  using (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()))
  with check (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()));
create policy documents_delete on public.documents for delete to authenticated
  using (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()));

create policy photos_select on public.photos for select to authenticated
  using (
    private.can_read_org(organization_id)
    or uploaded_by = (select private.current_user_id())
    or private.is_property_owner(property_id)
    or (inspection_id is not null and private.can_read_inspection(inspection_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
    or (service_task_id is not null and private.can_read_task(service_task_id))
    or (repair_id is not null and private.can_read_repair(repair_id))
  );
create policy photos_insert on public.photos for insert to authenticated
  with check (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (inspection_id is not null and private.can_work_inspection(inspection_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id) and private.is_org_member(organization_id))
    or (service_task_id is not null and private.can_read_task(service_task_id) and private.is_org_member(organization_id))
  );
create policy photos_update on public.photos for update to authenticated
  using (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()))
  with check (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()));
create policy photos_delete on public.photos for delete to authenticated
  using (private.is_org_staff(organization_id) or uploaded_by = (select private.current_user_id()));

-- -----------------------------------------------------------------------------
-- quotes, invoices
-- -----------------------------------------------------------------------------
create policy quotes_select on public.quotes for select to authenticated
  using (private.can_read_org(organization_id) or private.is_property_owner(property_id)
         or private.is_partner_member(service_partner_id));
create policy quotes_insert on public.quotes for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.is_partner_member(service_partner_id));
create policy quotes_update on public.quotes for update to authenticated
  using (private.is_org_staff(organization_id) or private.is_property_owner(property_id)
         or (private.is_partner_member(service_partner_id) and status in ('requested', 'received')))
  with check (private.is_org_staff(organization_id) or private.is_property_owner(property_id)
              or private.is_partner_member(service_partner_id));
create policy quotes_delete on public.quotes for delete to authenticated
  using (private.is_org_staff(organization_id));

create policy invoices_select on public.invoices for select to authenticated
  using (private.can_read_org(organization_id) or private.is_property_owner(property_id)
         or private.is_partner_member(service_partner_id));
create policy invoices_insert on public.invoices for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.is_partner_member(service_partner_id));
create policy invoices_update on public.invoices for update to authenticated
  using (private.is_org_staff(organization_id)
         or (private.is_partner_member(service_partner_id) and status in ('draft', 'received')))
  with check (private.is_org_staff(organization_id) or private.is_partner_member(service_partner_id));
create policy invoices_delete on public.invoices for delete to authenticated
  using (private.is_org_staff(organization_id));

-- -----------------------------------------------------------------------------
-- Automatisierung
-- -----------------------------------------------------------------------------
create policy automation_rules_select on public.automation_rules for select to authenticated
  using (private.can_read_org(organization_id));
create policy automation_rules_insert on public.automation_rules for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy automation_rules_update on public.automation_rules for update to authenticated
  using (private.is_org_staff(organization_id)) with check (private.is_org_staff(organization_id));
create policy automation_rules_delete on public.automation_rules for delete to authenticated
  using (private.is_org_staff(organization_id));

-- Protokoll: nur lesen; geschrieben wird ausschließlich von der Engine
create policy automation_runs_select on public.automation_runs for select to authenticated
  using (private.can_read_org(organization_id));

-- -----------------------------------------------------------------------------
-- notifications (nur eigene), messages (Absender, Empfänger, Auftrags-Thread)
-- -----------------------------------------------------------------------------
create policy notifications_select on public.notifications for select to authenticated
  using (user_id = (select private.current_user_id()));
create policy notifications_insert on public.notifications for insert to authenticated
  with check (private.is_org_staff(organization_id) and private.is_user_in_org(user_id, organization_id));
create policy notifications_update on public.notifications for update to authenticated
  using (user_id = (select private.current_user_id())) with check (user_id = (select private.current_user_id()));
create policy notifications_delete on public.notifications for delete to authenticated
  using (user_id = (select private.current_user_id()));

create policy messages_select on public.messages for select to authenticated
  using (
    sender_user_id = (select private.current_user_id())
    or recipient_user_id = (select private.current_user_id())
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
  );
create policy messages_insert on public.messages for insert to authenticated
  with check (
    private.is_org_member(organization_id)
    and (service_order_id is null or private.can_read_service_order(service_order_id))
    and (recipient_user_id is null or private.is_user_in_org(recipient_user_id, organization_id))
  );
create policy messages_update on public.messages for update to authenticated
  using (recipient_user_id = (select private.current_user_id()))
  with check (recipient_user_id = (select private.current_user_id()));
create policy messages_delete on public.messages for delete to authenticated
  using (sender_user_id = (select private.current_user_id()));

-- -----------------------------------------------------------------------------
-- audit_logs, Webhooks (nur Admins lesen)
-- -----------------------------------------------------------------------------
create policy audit_logs_select on public.audit_logs for select to authenticated
  using (case when organization_id is null then (select private.is_super_admin()) else private.is_org_admin(organization_id) end);

create policy webhook_endpoints_select on public.webhook_endpoints for select to authenticated
  using (private.is_org_admin(organization_id));
create policy webhook_endpoints_insert on public.webhook_endpoints for insert to authenticated
  with check (private.is_org_admin(organization_id));
create policy webhook_endpoints_update on public.webhook_endpoints for update to authenticated
  using (private.is_org_admin(organization_id)) with check (private.is_org_admin(organization_id));
create policy webhook_endpoints_delete on public.webhook_endpoints for delete to authenticated
  using (private.is_org_admin(organization_id));

create policy webhook_events_select on public.webhook_events for select to authenticated
  using (organization_id is not null and private.is_org_admin(organization_id));

-- -----------------------------------------------------------------------------
-- Rechte
-- -----------------------------------------------------------------------------
-- anon (nicht angemeldet) erhält keinerlei Zugriff auf Tabellen
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

-- Protokolle sind für angemeldete Benutzer nur lesbar
revoke insert, update, delete, truncate on public.audit_logs, public.automation_runs, public.webhook_events from authenticated;
revoke truncate, references, trigger on all tables in schema public from authenticated;

-- Hilfsfunktionen
revoke all on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated, service_role;

-- Server-Funktionen (Edge Functions mit service_role, pg_cron)
revoke all on function public.webhook_verify_signature(uuid, text, text) from public, anon, authenticated;
revoke all on function public.webhook_receive(text, text, text, jsonb, boolean, text, jsonb, uuid) from public, anon, authenticated;
revoke all on function public.webhook_claim(integer, integer) from public, anon, authenticated;
revoke all on function public.webhook_complete(uuid, boolean, text, uuid) from public, anon, authenticated;
revoke all on function public.upsert_external_booking(uuid, uuid, text, text, timestamptz, timestamptz, text, text, text, text, text, integer, uuid) from public, anon, authenticated;
revoke all on function public.run_scheduled_automations() from public, anon, authenticated;
grant execute on function public.webhook_verify_signature(uuid, text, text) to service_role;
grant execute on function public.webhook_receive(text, text, text, jsonb, boolean, text, jsonb, uuid) to service_role;
grant execute on function public.webhook_claim(integer, integer) to service_role;
grant execute on function public.webhook_complete(uuid, boolean, text, uuid) to service_role;
grant execute on function public.upsert_external_booking(uuid, uuid, text, text, timestamptz, timestamptz, text, text, text, text, text, integer, uuid) to service_role;
grant execute on function public.run_scheduled_automations() to service_role;
-- Erneut zustellen: Admin der Organisation (Prüfung in der Funktion)
revoke all on function public.webhook_retry(uuid) from public, anon;
grant execute on function public.webhook_retry(uuid) to authenticated, service_role;

-- >>> 20261030001100_audit_triggers.sql
-- =============================================================================
-- HUSORA · Migration 1100 · Audit-Log für Kerntabellen
-- =============================================================================
-- Schreibt jede Änderung nach public.audit_logs (wer, was, alt/neu, IP).
-- Personenbezogene Gästedaten werden im Log maskiert.

create or replace function private.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old     jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new     jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row     jsonb := coalesce(v_new, v_old);
  v_org     uuid;
  v_ip      inet;
  v_headers jsonb;
  v_mask    text[] := array['guest_email', 'guest_phone', 'credentials_reference', 'secret_reference'];
  v_key     text;
begin
  if tg_op = 'UPDATE' and v_old - 'updated_at' - 'updated_by' = v_new - 'updated_at' - 'updated_by' then
    return null;  -- keine fachliche Änderung
  end if;

  v_org := case when tg_table_name = 'organizations' then (v_row ->> 'id')::uuid
                else (v_row ->> 'organization_id')::uuid end;
  if tg_table_name = 'organizations' and tg_op = 'DELETE' then
    v_org := null;
  elsif v_org is not null and not exists (select 1 from public.organizations o where o.id = v_org) then
    return null;  -- Organisation wird gerade gelöscht (cascade); protokolliert wird nur die Organisation
  end if;

  foreach v_key in array v_mask loop
    if v_old ? v_key and v_old ->> v_key is not null then v_old := jsonb_set(v_old, array[v_key], '"***"'); end if;
    if v_new ? v_key and v_new ->> v_key is not null then v_new := jsonb_set(v_new, array[v_key], '"***"'); end if;
  end loop;

  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
    v_ip := split_part(coalesce(v_headers ->> 'x-forwarded-for', v_headers ->> 'x-real-ip'), ',', 1)::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, old_data, new_data, ip_address, user_agent)
  values (v_org, private.current_user_id(), lower(tg_op), tg_table_name, (v_row ->> 'id')::uuid, v_old, v_new, v_ip,
          left(v_headers ->> 'user-agent', 500));
  return null;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array[
    'organizations', 'organization_members', 'properties', 'property_users', 'service_partners',
    'booking_sources', 'bookings', 'inspection_templates', 'inspections', 'service_tasks', 'service_orders',
    'maintenance', 'repairs', 'documents', 'quotes', 'invoices', 'automation_rules', 'webhook_endpoints'
  ] loop
    execute format(
      'create trigger %I after insert or update or delete on public.%I for each row execute function private.audit_row_change()',
      t || '_audit', t);
  end loop;
end;
$$;

-- >>> 20261030001200_storage.sql
-- =============================================================================
-- HUSORA · Migration 1200 · Supabase Storage: Buckets und Zugriffsregeln
-- =============================================================================
-- Pfadkonvention (alle Buckets):
--   organization/{organization_id}/property/{property_id}/photos/…
--   organization/{organization_id}/property/{property_id}/documents/…
--   organization/{organization_id}/property/{property_id}/inspections/…
--   organization/{organization_id}/property/{property_id}/repairs/…
--   organization/{organization_id}/documents/…          (ohne Hausbezug)
-- Nur husora-public ist öffentlich. Private Dateien sind nie öffentlich erreichbar;
-- Zugriff erfolgt über RLS bzw. kurzlebige signierte URLs.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('husora-public',          'husora-public',          true,  5242880,
     array['image/jpeg', 'image/png', 'image/webp', 'image/svg+xml']),
  ('husora-private',         'husora-private',         false, 52428800, null),
  ('husora-documents',       'husora-documents',       false, 52428800,
     array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'text/plain', 'text/csv',
           'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
           'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']),
  ('husora-property-photos', 'husora-property-photos', false, 15728640,
     array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Pfad zerlegen: organization / {org} / property / {property} / {bereich} / datei
create or replace function private.storage_path_parts(p_name text, out organization_id uuid, out property_id uuid, out area text)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_parts text[] := string_to_array(p_name, '/');
  v_uuid  text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
begin
  if p_name like '%..%' or p_name like '/%' or v_parts[1] is distinct from 'organization' or v_parts[2] !~ v_uuid then
    return;
  end if;
  organization_id := v_parts[2]::uuid;
  if v_parts[3] = 'property' and array_length(v_parts, 1) >= 6 and v_parts[4] ~ v_uuid
     and v_parts[5] in ('photos', 'documents', 'inspections', 'repairs') then
    property_id := v_parts[4]::uuid;
    area := v_parts[5];
  elsif v_parts[3] = 'documents' and array_length(v_parts, 1) >= 4 then
    area := 'org_documents';
  else
    organization_id := null;  -- ungültiger Pfad
  end if;
end;
$$;

-- Bereich passt zum Bucket?
create or replace function private.storage_area_allowed(p_bucket text, p_area text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case p_bucket
    when 'husora-property-photos' then p_area in ('photos', 'inspections', 'repairs')
    when 'husora-documents'       then p_area in ('documents', 'inspections', 'repairs', 'org_documents')
    when 'husora-private'         then p_area is not null
    when 'husora-public'          then p_area is not null
    else false
  end
$$;

-- Lesen: Verwaltung/viewer der Organisation oder Eigentümer des Hauses
create or replace function private.storage_can_read(p_bucket text, p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select private.can_read_org(sp.organization_id)
        or (sp.property_id is not null
            and private.property_org(sp.property_id) = sp.organization_id
            and private.is_property_owner(sp.property_id))
    from private.storage_path_parts(p_name) sp
    where sp.organization_id is not null
  ), false)
$$;

-- Hochladen: gültiger Pfad + Verwaltung, Eigentümer/Hausverwalter oder Person/Partner
-- mit Arbeit an diesem Haus (Fotos, Kontroll- und Reparaturbelege). viewer nie.
create or replace function private.storage_can_write(p_bucket text, p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select private.storage_area_allowed(p_bucket, sp.area)
       and (
         private.is_org_staff(sp.organization_id)
         or (p_bucket <> 'husora-public'
             and sp.property_id is not null
             and private.property_org(sp.property_id) = sp.organization_id
             and (
               private.can_manage_property(sp.property_id)
               or (private.can_read_property(sp.property_id)
                   and coalesce(private.org_role(sp.organization_id), '') <> 'viewer'
                   and sp.area in ('photos', 'inspections', 'repairs', 'documents'))
             ))
       )
    from private.storage_path_parts(p_name) sp
    where sp.organization_id is not null
  ), false)
$$;

grant execute on function private.storage_path_parts(text), private.storage_area_allowed(text, text),
  private.storage_can_read(text, text), private.storage_can_write(text, text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Policies auf storage.objects
-- -----------------------------------------------------------------------------
-- Öffentlicher Bucket: lesen für alle, schreiben nur Verwaltung
create policy husora_public_read on storage.objects for select to anon, authenticated
  using (bucket_id = 'husora-public');
create policy husora_public_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'husora-public' and private.storage_can_write(bucket_id, name));
create policy husora_public_update on storage.objects for update to authenticated
  using (bucket_id = 'husora-public' and private.storage_can_write(bucket_id, name))
  with check (bucket_id = 'husora-public' and private.storage_can_write(bucket_id, name));
create policy husora_public_delete on storage.objects for delete to authenticated
  using (bucket_id = 'husora-public' and private.storage_can_write(bucket_id, name));

-- Private Buckets: lesen nur mit Berechtigung. Zusätzlich darf lesen, wer den zugehörigen
-- Datensatz in public.photos / public.documents sehen darf (dort greift deren RLS).
create policy husora_private_read on storage.objects for select to authenticated
  using (
    bucket_id in ('husora-private', 'husora-documents', 'husora-property-photos')
    and (
      private.storage_can_read(bucket_id, name)
      or owner_id = (select auth.uid())::text
      or exists (select 1 from public.photos p where p.storage_bucket = bucket_id and p.storage_path = name)
      or exists (select 1 from public.documents d where d.storage_bucket = bucket_id and d.storage_path = name)
    )
  );
create policy husora_private_insert on storage.objects for insert to authenticated
  with check (
    bucket_id in ('husora-private', 'husora-documents', 'husora-property-photos')
    and private.storage_can_write(bucket_id, name)
  );
create policy husora_private_update on storage.objects for update to authenticated
  using (
    bucket_id in ('husora-private', 'husora-documents', 'husora-property-photos')
    and (owner_id = (select auth.uid())::text
         or private.is_org_staff((private.storage_path_parts(name)).organization_id))
  )
  with check (
    bucket_id in ('husora-private', 'husora-documents', 'husora-property-photos')
    and private.storage_can_write(bucket_id, name)
  );
create policy husora_private_delete on storage.objects for delete to authenticated
  using (
    bucket_id in ('husora-private', 'husora-documents', 'husora-property-photos')
    and (owner_id = (select auth.uid())::text
         or private.is_org_staff((private.storage_path_parts(name)).organization_id))
  );

-- >>> 20261030001300_partner_matching.sql
-- =============================================================================
-- HUSORA · Migration 1300 · Partner-Routing: Ranking, Angebot, Antwort
-- =============================================================================
-- score = distance_score + availability_score + rating_score + price_score
-- Gewichte je Organisation in organizations.settings -> 'partner_ranking':
--   {"distance": 40, "availability": 20, "rating": 25, "price": 15,
--    "max_distance_km": 100, "max_open_orders": 10}

-- Entfernung in km (Haversine)
create or replace function public.distance_km(p_lat1 numeric, p_lon1 numeric, p_lat2 numeric, p_lon2 numeric)
returns numeric
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case when p_lat1 is null or p_lon1 is null or p_lat2 is null or p_lon2 is null then null
  else round((6371 * 2 * asin(sqrt(
         power(sin(radians((p_lat2 - p_lat1)::double precision) / 2), 2)
       + cos(radians(p_lat1::double precision)) * cos(radians(p_lat2::double precision))
       * power(sin(radians((p_lon2 - p_lon1)::double precision) / 2), 2)
       )))::numeric, 2)
  end
$$;

-- Passende Partner für ein Haus und eine Serviceart, bester zuerst.
-- security invoker: es werden nur Partner gerankt, die der Aufrufer sehen darf.
create or replace function public.match_service_partners(
  p_property_id uuid,
  p_service_type_id uuid,
  p_limit integer default 5,
  p_exclude_partner_ids uuid[] default null,
  p_scheduled_at timestamptz default null
)
returns table (
  service_partner_id  uuid,
  company_name        text,
  distance_km         numeric,
  open_orders         integer,
  rating              numeric,
  price_from          numeric,
  price_unit          text,
  distance_score      numeric,
  availability_score  numeric,
  rating_score        numeric,
  price_score         numeric,
  score               numeric
)
language sql
stable
set search_path = ''
as $$
  with prop as (
    select p.*, coalesce(o.settings -> 'partner_ranking', '{}'::jsonb) as cfg
    from public.properties p
    join public.organizations o on o.id = p.organization_id
    where p.id = p_property_id
  ),
  w as (
    select
      coalesce((cfg ->> 'distance')::numeric, 40)         as w_distance,
      coalesce((cfg ->> 'availability')::numeric, 20)     as w_availability,
      coalesce((cfg ->> 'rating')::numeric, 25)           as w_rating,
      coalesce((cfg ->> 'price')::numeric, 15)            as w_price,
      greatest(coalesce((cfg ->> 'max_distance_km')::numeric, 100), 1) as max_distance,
      greatest(coalesce((cfg ->> 'max_open_orders')::numeric, 10), 1)  as max_open
    from prop
  ),
  candidates as (
    select
      sp.id,
      sp.company_name,
      sp.rating,
      sps.price_from,
      sps.price_unit,
      public.distance_km(prop.latitude, prop.longitude, sp.latitude, sp.longitude) as dist,
      exists (
        select 1 from public.service_partner_areas a
        where a.service_partner_id = sp.id
          and (a.postal_code = prop.postal_code
               or lower(a.city) = lower(prop.city)
               or lower(a.region) = lower(prop.region))
      ) as area_match,
      exists (select 1 from public.service_partner_areas a where a.service_partner_id = sp.id) as has_areas,
      (
        select max(a.radius_km) from public.service_partner_areas a where a.service_partner_id = sp.id
      ) as max_radius,
      (
        select count(*) from public.service_orders so
        where so.service_partner_id = sp.id and so.status in ('offered', 'accepted', 'scheduled', 'in_progress')
      )::integer as open_cnt,
      (
        select count(*) from public.service_orders so
        where so.service_partner_id = sp.id and so.status in ('accepted', 'scheduled', 'in_progress')
          and p_scheduled_at is not null and so.scheduled_at is not null
          and so.scheduled_at between p_scheduled_at - interval '12 hours' and p_scheduled_at + interval '12 hours'
      )::integer as day_conflicts
    from prop
    join public.service_partners sp on sp.organization_id = prop.organization_id and sp.status = 'active'
    join public.service_partner_services sps
      on sps.service_partner_id = sp.id and sps.service_type_id = p_service_type_id and sps.active
    where p_exclude_partner_ids is null or sp.id <> all (p_exclude_partner_ids)
  ),
  eligible as (
    -- Einsatzgebiet: ohne hinterlegte Gebiete gilt der Partner als überall verfügbar
    select c.* from candidates c
    where not c.has_areas or c.area_match or (c.max_radius is not null and c.dist is not null and c.dist <= c.max_radius)
  ),
  scored as (
    select
      e.*,
      round(case
        when e.dist is not null then w.w_distance * greatest(0, 1 - e.dist / w.max_distance)
        when e.area_match then w.w_distance * 0.5
        else 0 end, 2) as s_distance,
      round(w.w_availability * greatest(0, 1 - e.open_cnt / w.max_open)
            * case when e.day_conflicts > 0 then 0.5 else 1 end, 2) as s_availability,
      round(w.w_rating * coalesce(e.rating, 2.5) / 5, 2) as s_rating,
      round(case
        when e.price_from is null then w.w_price * 0.5
        when e.price_from = 0 then w.w_price
        else w.w_price * (min(e.price_from) over () / e.price_from) end, 2) as s_price
    from eligible e cross join w
  )
  select s.id, s.company_name, s.dist, s.open_cnt, s.rating, s.price_from, s.price_unit,
         s.s_distance, s.s_availability, s.s_rating, s.s_price,
         s.s_distance + s.s_availability + s.s_rating + s.s_price as score
  from scored s
  order by score desc, s.dist nulls last, s.company_name
  limit greatest(p_limit, 1)
$$;

-- Aufgabe einem Partner anbieten (ohne Angabe: bester Treffer aus dem Ranking)
create or replace function public.offer_service_order(
  p_service_task_id uuid,
  p_service_partner_id uuid default null,
  p_estimated_cost numeric default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_task    public.service_tasks;
  v_partner uuid := p_service_partner_id;
  v_price   numeric;
  v_score   numeric;
  v_order   uuid;
  v_exclude uuid[];
begin
  select * into v_task from public.service_tasks t where t.id = p_service_task_id;
  if v_task.id is null then
    raise exception 'Aufgabe nicht gefunden' using errcode = 'P0002';
  end if;

  if v_partner is null then
    select array_agg(o.service_partner_id) into v_exclude
    from public.service_orders o where o.service_task_id = v_task.id and o.status = 'rejected';
    select m.service_partner_id, m.price_from, m.score into v_partner, v_price, v_score
    from public.match_service_partners(v_task.property_id, v_task.service_type_id, 1, v_exclude, v_task.scheduled_start) m;
    if v_partner is null then
      raise exception 'Kein passender Servicepartner gefunden' using errcode = 'P0002';
    end if;
  end if;

  insert into public.service_orders (organization_id, service_task_id, property_id, service_partner_id, title,
                                     description, status, scheduled_at, estimated_cost, match_score)
  values (v_task.organization_id, v_task.id, v_task.property_id, v_partner,
          v_task.title, v_task.description, 'offered', v_task.scheduled_start,
          coalesce(p_estimated_cost, v_price), v_score)
  returning id into v_order;
  return v_order;
end;
$$;

-- Antwort des Partners speichern (annehmen / ablehnen, optional Termin)
create or replace function public.respond_service_order(
  p_service_order_id uuid,
  p_accept boolean,
  p_note text default null,
  p_scheduled_at timestamptz default null
)
returns public.service_orders
language plpgsql
set search_path = ''
as $$
declare
  v_order public.service_orders;
begin
  update public.service_orders o
  set status = case when p_accept then 'accepted' else 'rejected' end,
      response_note = coalesce(p_note, o.response_note),
      scheduled_at = case when p_accept then coalesce(p_scheduled_at, o.scheduled_at) else o.scheduled_at end
  where o.id = p_service_order_id and o.status = 'offered'
  returning * into v_order;
  if v_order.id is null then
    raise exception 'Auftrag nicht gefunden oder nicht mehr offen' using errcode = 'P0002';
  end if;
  return v_order;
end;
$$;

revoke all on function public.match_service_partners(uuid, uuid, integer, uuid[], timestamptz) from public, anon;
revoke all on function public.offer_service_order(uuid, uuid, numeric) from public, anon;
revoke all on function public.respond_service_order(uuid, boolean, text, timestamptz) from public, anon;
revoke all on function public.distance_km(numeric, numeric, numeric, numeric) from anon;
grant execute on function public.match_service_partners(uuid, uuid, integer, uuid[], timestamptz) to authenticated, service_role;
grant execute on function public.offer_service_order(uuid, uuid, numeric) to authenticated, service_role;
grant execute on function public.respond_service_order(uuid, boolean, text, timestamptz) to authenticated, service_role;
grant execute on function public.distance_km(numeric, numeric, numeric, numeric) to authenticated, service_role;

-- >>> 20261030001400_foreign_key_indexes.sql
-- =============================================================================
-- HUSORA · Migration 1400 · Indizes auf den übrigen Fremdschlüsseln
-- =============================================================================
-- Fremdschlüssel ohne Index machen das Löschen/Ändern des referenzierten Datensatzes
-- (z. B. eines Benutzers) bei großen Tabellen langsam. Teilindizes halten sie klein.

create index automation_rules_created_by_fk_idx on public.automation_rules (created_by) where created_by is not null;
create index automation_rules_updated_by_fk_idx on public.automation_rules (updated_by) where updated_by is not null;
create index booking_sources_created_by_fk_idx on public.booking_sources (created_by) where created_by is not null;
create index booking_sources_updated_by_fk_idx on public.booking_sources (updated_by) where updated_by is not null;
create index bookings_created_by_fk_idx on public.bookings (created_by) where created_by is not null;
create index bookings_updated_by_fk_idx on public.bookings (updated_by) where updated_by is not null;
create index inspection_items_checked_by_fk_idx on public.inspection_items (checked_by) where checked_by is not null;
create index inspection_templates_created_by_fk_idx on public.inspection_templates (created_by) where created_by is not null;
create index inspection_templates_updated_by_fk_idx on public.inspection_templates (updated_by) where updated_by is not null;
create index inspections_created_by_fk_idx on public.inspections (created_by) where created_by is not null;
create index inspections_updated_by_fk_idx on public.inspections (updated_by) where updated_by is not null;
create index invoices_approved_by_fk_idx on public.invoices (approved_by) where approved_by is not null;
create index invoices_created_by_fk_idx on public.invoices (created_by) where created_by is not null;
create index invoices_document_id_fk_idx on public.invoices (document_id) where document_id is not null;
create index invoices_updated_by_fk_idx on public.invoices (updated_by) where updated_by is not null;
create index maintenance_created_by_fk_idx on public.maintenance (created_by) where created_by is not null;
create index maintenance_service_type_id_fk_idx on public.maintenance (service_type_id) where service_type_id is not null;
create index maintenance_updated_by_fk_idx on public.maintenance (updated_by) where updated_by is not null;
create index organization_members_invited_by_fk_idx on public.organization_members (invited_by) where invited_by is not null;
create index organizations_created_by_fk_idx on public.organizations (created_by) where created_by is not null;
create index organizations_updated_by_fk_idx on public.organizations (updated_by) where updated_by is not null;
create index properties_created_by_fk_idx on public.properties (created_by) where created_by is not null;
create index properties_updated_by_fk_idx on public.properties (updated_by) where updated_by is not null;
create index quotes_created_by_fk_idx on public.quotes (created_by) where created_by is not null;
create index quotes_decided_by_fk_idx on public.quotes (decided_by) where decided_by is not null;
create index quotes_document_id_fk_idx on public.quotes (document_id) where document_id is not null;
create index quotes_updated_by_fk_idx on public.quotes (updated_by) where updated_by is not null;
create index repairs_approved_by_fk_idx on public.repairs (approved_by) where approved_by is not null;
create index repairs_created_by_fk_idx on public.repairs (created_by) where created_by is not null;
create index repairs_updated_by_fk_idx on public.repairs (updated_by) where updated_by is not null;
create index service_orders_created_by_fk_idx on public.service_orders (created_by) where created_by is not null;
create index service_orders_updated_by_fk_idx on public.service_orders (updated_by) where updated_by is not null;
create index service_partners_created_by_fk_idx on public.service_partners (created_by) where created_by is not null;
create index service_partners_updated_by_fk_idx on public.service_partners (updated_by) where updated_by is not null;
create index service_tasks_created_by_fk_idx on public.service_tasks (created_by) where created_by is not null;
create index service_tasks_updated_by_fk_idx on public.service_tasks (updated_by) where updated_by is not null;
create index webhook_endpoints_created_by_fk_idx on public.webhook_endpoints (created_by) where created_by is not null;
create index webhook_endpoints_updated_by_fk_idx on public.webhook_endpoints (updated_by) where updated_by is not null;
create index webhook_events_webhook_endpoint_id_fk_idx on public.webhook_events (webhook_endpoint_id) where webhook_endpoint_id is not null;

-- >>> 20261030001500_app_sync.sql
-- =============================================================================
-- HUSORA · Migration 1500 · Cloud-Sync der Husora-App
-- =============================================================================
-- Die App speichert ihre Daten als Schlüssel "stugliv-…" (JSON). public.app_data
-- nimmt diese Schlüssel vollständig und unverändert auf – damit liegt die komplette
-- App-Datenbank in Supabase und lässt sich auf jedem Gerät wiederherstellen.
-- Zusätzlich überträgt ein Trigger Ferienhäuser, Buchungen und Aufgaben in die
-- normalisierten Tabellen (properties, bookings, service_tasks). Dort sind sie über
-- app_ref (ID aus der App) eindeutig zugeordnet und werden bei jedem Sync aktualisiert.

-- -----------------------------------------------------------------------------
-- Zuordnung App-ID ↔ Datensatz
-- -----------------------------------------------------------------------------
alter table public.properties    add column app_ref text;
alter table public.bookings      add column app_ref text;
alter table public.service_tasks add column app_ref text;
comment on column public.properties.app_ref is 'ID des Datensatzes in der Husora-App (Cloud-Sync).';
comment on column public.bookings.app_ref is 'ID des Datensatzes in der Husora-App (Cloud-Sync).';
comment on column public.service_tasks.app_ref is 'ID des Datensatzes in der Husora-App (Cloud-Sync).';
create unique index properties_app_ref_idx    on public.properties (organization_id, app_ref)    where app_ref is not null;
create unique index bookings_app_ref_idx      on public.bookings (organization_id, app_ref)      where app_ref is not null;
create unique index service_tasks_app_ref_idx on public.service_tasks (organization_id, app_ref) where app_ref is not null;

-- Aus der App übernommene Buchungen lösen keine Datenbank-Automationen aus:
-- die App plant Reinigung und Kontrolle selbst, die Aufgaben kommen per Sync.
drop trigger bookings_automation on public.bookings;
create trigger bookings_automation after insert or update of status, check_out on public.bookings
  for each row when (new.app_ref is null) execute function private.automation_on_booking();

-- -----------------------------------------------------------------------------
-- app_data: alle App-Schlüssel je Organisation
-- -----------------------------------------------------------------------------
create table public.app_data (
  organization_id    uuid not null references public.organizations(id) on delete cascade,
  key                text not null check (key ~ '^stugliv-[a-z0-9-]+$'),
  value              text not null,
  size_bytes         integer generated always as (octet_length(value)) stored,
  device_id          text check (device_id is null or length(device_id) <= 64),
  updated_by         uuid references public.users(id) on delete set null,
  updated_at         timestamptz not null default now(),
  projection_status  text,
  primary key (organization_id, key)
);
comment on table public.app_data is 'Komplette Daten der Husora-App (localStorage-Schlüssel "stugliv-…") je Organisation.';
comment on column public.app_data.projection_status is 'Ergebnis der Übernahme in die Fachtabellen, z. B. "3 Häuser" oder die Fehlermeldung.';
create index app_data_org_updated_idx on public.app_data (organization_id, updated_at desc);
create index app_data_updated_by_idx on public.app_data (updated_by) where updated_by is not null;

create or replace function private.app_data_stamp()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(private.current_user_id(), new.updated_by);
  return new;
end;
$$;
create trigger app_data_stamp before insert or update on public.app_data
  for each row execute function private.app_data_stamp();

alter table public.app_data enable row level security;
create policy app_data_select on public.app_data for select to authenticated
  using (private.can_read_org(organization_id));
create policy app_data_insert on public.app_data for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy app_data_update on public.app_data for update to authenticated
  using (private.is_org_staff(organization_id)) with check (private.is_org_staff(organization_id));
create policy app_data_delete on public.app_data for delete to authenticated
  using (private.is_org_staff(organization_id));
revoke all on public.app_data from anon;

-- -----------------------------------------------------------------------------
-- Hilfsfunktionen für die Übernahme
-- -----------------------------------------------------------------------------
-- Erste Zahl aus einem Text ("86 m²", "1.978", "6 Schlafplätze" …)
create or replace function private.app_num(p_text text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select nullif(replace(substring(coalesce(p_text, '') from '-?[0-9]+(?:[.,][0-9]+)?'), ',', '.'), '')::numeric
$$;

create or replace function private.app_country(p_address text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_address ~* '(schweden|sweden|sverige)' then 'SE'
    when p_address ~* '(norwegen|norway|norge)' then 'NO'
    when p_address ~* '(dänemark|daenemark|denmark|danmark)' then 'DK'
    when p_address ~* '(finnland|finland|suomi)' then 'FI'
    when p_address ~* '(deutschland|germany)' then 'DE'
    when p_address ~* '(österreich|austria)' then 'AT'
    when p_address ~* '(schweiz|switzerland)' then 'CH'
    when p_address ~* '(niederlande|netherlands)' then 'NL'
  end
$$;

-- Datum (YYYY-MM-DD) + Uhrzeit (HH:MM) in der Zeitzone der Organisation
create or replace function private.app_ts(p_date text, p_time text, p_default_time text, p_timezone text)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
  v_time text := coalesce(substring(coalesce(p_time, '') from '^\d{1,2}:\d{2}'), p_default_time);
begin
  if p_date !~ '^\d{4}-\d{2}-\d{2}$' then
    return null;
  end if;
  return ((p_date || ' ' || v_time)::timestamp) at time zone coalesce(p_timezone, 'Europe/Stockholm');
exception when others then
  return null;
end;
$$;

-- Ferienhäuser übernehmen
create or replace function private.project_app_properties(p_org uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item  jsonb;
  v_count integer := 0;
  v_refs  text[] := '{}';
  v_addr  text;
  v_year  numeric;
begin
  for v_item in select * from jsonb_array_elements(p_items) loop
    continue when coalesce(v_item ->> 'id', '') = '' or coalesce(trim(v_item ->> 'name'), '') = '';
    v_addr := coalesce(v_item ->> 'address', '');
    v_year := private.app_num(v_item ->> 'yearBuilt');
    insert into public.properties (organization_id, app_ref, name, description, city, region, country,
                                   living_area_m2, land_area_m2, bedrooms, max_guests, year_built, property_type)
    values (p_org, v_item ->> 'id', trim(v_item ->> 'name'),
            nullif(concat_ws(' · ', nullif(v_addr, ''), nullif(v_item ->> 'condition', '')), ''),
            nullif(trim(split_part(v_addr, ',', 1)), ''),
            coalesce(nullif(v_item ->> 'region', ''), nullif(trim(split_part(v_addr, ',', 2)), '')),
            private.app_country(v_addr),
            private.app_num(v_item ->> 'livingArea'),
            private.app_num(v_item ->> 'plotSize'),
            private.app_num(v_item ->> 'rooms')::integer,
            private.app_num(v_item ->> 'beds')::integer,
            case when v_year between 1600 and 2100 then v_year::integer end,
            'holiday_home')
    on conflict (organization_id, app_ref) where app_ref is not null do update set
      name = excluded.name,
      description = excluded.description,
      city = excluded.city,
      region = excluded.region,
      country = excluded.country,
      living_area_m2 = excluded.living_area_m2,
      land_area_m2 = excluded.land_area_m2,
      bedrooms = excluded.bedrooms,
      max_guests = excluded.max_guests,
      year_built = excluded.year_built;
    v_refs := v_refs || (v_item ->> 'id');
    v_count := v_count + 1;
  end loop;
  -- In der App gelöschte Häuser entfernen (nur aus der App stammende)
  delete from public.properties p
  where p.organization_id = p_org and p.app_ref is not null and not (p.app_ref = any (v_refs));
  return v_count;
end;
$$;

-- Buchungen übernehmen
create or replace function private.project_app_bookings(p_org uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item     jsonb;
  v_count    integer := 0;
  v_refs     text[] := '{}';
  v_tz       text := (select o.timezone from public.organizations o where o.id = p_org);
  v_property uuid;
  v_in       timestamptz;
  v_out      timestamptz;
  v_owner    boolean;
  v_source   text;
  v_status   text;
  v_name     text;
begin
  for v_item in select * from jsonb_array_elements(p_items) loop
    continue when coalesce(v_item ->> 'id', '') = '';
    select p.id into v_property from public.properties p
    where p.organization_id = p_org and p.app_ref = v_item ->> 'propertyId';
    v_in := private.app_ts(v_item ->> 'startDate', v_item ->> 'arrivalTime', '15:00', v_tz);
    v_out := private.app_ts(v_item ->> 'endDate', v_item ->> 'departureTime', '11:00', v_tz);
    continue when v_property is null or v_in is null or v_out is null or v_out <= v_in;

    v_owner := v_item ->> 'kind' = 'owner' or lower(coalesce(v_item ->> 'source', '')) = 'owner'
               or coalesce(v_item ->> 'owner', '') in ('true', '1');
    v_source := case
      when v_owner then 'owner'
      when lower(coalesce(v_item ->> 'source', '')) like '%airbnb%' then 'airbnb'
      when lower(coalesce(v_item ->> 'source', '')) like '%booking%' then 'booking_com'
      when lower(coalesce(v_item ->> 'source', '')) like '%vrbo%' then 'vrbo'
      when lower(coalesce(v_item ->> 'source', '')) like '%ical%' then 'ical'
      else 'direct' end;
    v_status := case when coalesce(v_item ->> 'cancelled', '') in ('true', '1') then 'cancelled'
                     when v_out < now() then 'completed' else 'confirmed' end;
    v_name := nullif(trim(coalesce(v_item ->> 'guestName', '')), '');

    begin
      insert into public.bookings (organization_id, property_id, app_ref, source, guest_first_name, guest_last_name,
                                   guest_count, check_in, check_out, status, notes)
      values (p_org, v_property, v_item ->> 'id', v_source,
              nullif(split_part(v_name, ' ', 1), ''), nullif(trim(substr(v_name, length(split_part(v_name, ' ', 1)) + 1)), ''),
              private.app_num(v_item ->> 'guestCount')::integer, v_in, v_out, v_status, nullif(v_item ->> 'notes', ''))
      on conflict (organization_id, app_ref) where app_ref is not null do update set
        property_id = excluded.property_id, source = excluded.source,
        guest_first_name = excluded.guest_first_name, guest_last_name = excluded.guest_last_name,
        guest_count = excluded.guest_count, check_in = excluded.check_in, check_out = excluded.check_out,
        status = excluded.status, notes = excluded.notes;
    exception when exclusion_violation then
      -- Überschneidung mit einer anderen bestätigten Buchung: als Anfrage übernehmen
      insert into public.bookings (organization_id, property_id, app_ref, source, guest_first_name, guest_last_name,
                                   guest_count, check_in, check_out, status, notes)
      values (p_org, v_property, v_item ->> 'id', v_source,
              nullif(split_part(v_name, ' ', 1), ''), nullif(trim(substr(v_name, length(split_part(v_name, ' ', 1)) + 1)), ''),
              private.app_num(v_item ->> 'guestCount')::integer, v_in, v_out, 'inquiry',
              concat_ws(' · ', nullif(v_item ->> 'notes', ''), 'Überschneidet sich mit einer anderen Buchung'))
      on conflict (organization_id, app_ref) where app_ref is not null do update set
        status = 'inquiry', check_in = excluded.check_in, check_out = excluded.check_out, notes = excluded.notes;
    end;
    v_refs := v_refs || (v_item ->> 'id');
    v_count := v_count + 1;
  end loop;
  delete from public.bookings b
  where b.organization_id = p_org and b.app_ref is not null and not (b.app_ref = any (v_refs));
  return v_count;
end;
$$;

-- Aufgaben übernehmen
create or replace function private.project_app_tasks(p_org uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item     jsonb;
  v_count    integer := 0;
  v_refs     text[] := '{}';
  v_tz       text := (select o.timezone from public.organizations o where o.id = p_org);
  v_property uuid;
  v_booking  uuid;
  v_status   text;
begin
  for v_item in select * from jsonb_array_elements(p_items) loop
    continue when coalesce(v_item ->> 'id', '') = '' or coalesce(trim(v_item ->> 'title'), '') = '';
    select p.id into v_property from public.properties p
    where p.organization_id = p_org
      and (p.app_ref = v_item ->> 'propertyId' or (v_item ->> 'propertyId' is null and p.name = v_item ->> 'property'))
    order by (p.app_ref = v_item ->> 'propertyId') desc nulls last
    limit 1;
    continue when v_property is null;
    select b.id into v_booking from public.bookings b
    where b.organization_id = p_org and b.app_ref = v_item ->> 'bookingId';

    v_status := case
      when coalesce(v_item ->> 'done', '') = 'true' or v_item ->> 'status' ilike 'erledigt%' then 'completed'
      when v_item ->> 'status' ilike 'in bearbeitung%' then 'in_progress'
      when v_item ->> 'status' ilike 'storniert%' then 'cancelled'
      else 'pending' end;

    insert into public.service_tasks (organization_id, property_id, booking_id, app_ref, title, description,
                                      priority, status, scheduled_start)
    values (p_org, v_property, v_booking, v_item ->> 'id', trim(v_item ->> 'title'),
            nullif(concat_ws(E'\n', nullif(v_item ->> 'description', ''),
                             case when coalesce(v_item ->> 'area', '') <> '' then 'Bereich: ' || (v_item ->> 'area') end), ''),
            case v_item ->> 'priority' when 'urgent' then 'urgent' when 'soon' then 'high' when 'low' then 'low' else 'normal' end,
            v_status,
            private.app_ts(v_item ->> 'date', v_item ->> 'time', '09:00', v_tz))
    on conflict (organization_id, app_ref) where app_ref is not null do update set
      property_id = excluded.property_id, booking_id = excluded.booking_id, title = excluded.title,
      description = excluded.description, priority = excluded.priority, status = excluded.status,
      scheduled_start = excluded.scheduled_start;
    v_refs := v_refs || (v_item ->> 'id');
    v_count := v_count + 1;
  end loop;
  delete from public.service_tasks t
  where t.organization_id = p_org and t.app_ref is not null and not (t.app_ref = any (v_refs));
  return v_count;
end;
$$;

-- Trigger: nach jedem Upload die passenden Fachtabellen aktualisieren.
-- Fehler werden protokolliert, verhindern aber nie das Speichern der App-Daten.
create or replace function private.project_app_data()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_json   jsonb;
  v_count  integer;
  v_status text;
begin
  if new.key not in ('stugliv-properties', 'stugliv-bookings', 'stugliv-tasks') then
    return null;
  end if;
  begin
    v_json := new.value::jsonb;
    if jsonb_typeof(v_json) <> 'array' then
      v_status := 'übersprungen: keine Liste';
    elsif new.key = 'stugliv-properties' then
      v_count := private.project_app_properties(new.organization_id, v_json);
      v_status := v_count || ' Ferienhäuser übernommen';
      -- Buchungen und Aufgaben hängen an den Häusern: nach neuen Häusern erneut zuordnen
      update public.app_data set value = value
      where organization_id = new.organization_id and key in ('stugliv-bookings', 'stugliv-tasks');
    elsif new.key = 'stugliv-bookings' then
      v_count := private.project_app_bookings(new.organization_id, v_json);
      v_status := v_count || ' Buchungen übernommen';
      update public.app_data set value = value
      where organization_id = new.organization_id and key = 'stugliv-tasks';
    else
      v_count := private.project_app_tasks(new.organization_id, v_json);
      v_status := v_count || ' Aufgaben übernommen';
    end if;
  exception when others then
    v_status := 'Fehler: ' || left(sqlerrm, 500);
  end;
  update public.app_data set projection_status = v_status
  where organization_id = new.organization_id and key = new.key and projection_status is distinct from v_status;
  return null;
end;
$$;

create trigger app_data_project after insert or update of value on public.app_data
  for each row execute function private.project_app_data();

-- -----------------------------------------------------------------------------
-- Organisation des angemeldeten Benutzers (wird beim ersten Anmelden angelegt)
-- -----------------------------------------------------------------------------
create or replace function public.ensure_my_organization(p_name text default 'Meine Ferienhäuser')
returns table (organization_id uuid, name text, role text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := private.current_user_id();
  v_org  uuid;
begin
  if v_user is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  select m.organization_id into v_org
  from public.organization_members m
  where m.user_id = v_user and m.status = 'active'
  order by (m.role = 'admin') desc, m.created_at
  limit 1;

  if v_org is null then
    insert into public.organizations (name, country, currency, timezone)
    values (coalesce(nullif(trim(p_name), ''), 'Meine Ferienhäuser'), 'SE', 'EUR', 'Europe/Stockholm')
    returning id into v_org;
    -- private.add_creator_as_admin trägt den Benutzer als Admin ein
  end if;

  return query
    select o.id, o.name, m.role
    from public.organizations o
    join public.organization_members m on m.organization_id = o.id and m.user_id = v_user
    where o.id = v_org;
end;
$$;

revoke all on function public.ensure_my_organization(text) from public, anon;
grant execute on function public.ensure_my_organization(text) to authenticated, service_role;
grant execute on function private.app_data_stamp(), private.app_num(text), private.app_country(text),
  private.app_ts(text, text, text, text) to authenticated, service_role;

-- >>> 20261030001600_app_files.sql
-- =============================================================================
-- HUSORA · Migration 1600 · Dateien der App in Supabase Storage
-- =============================================================================
-- Die App lädt Fotos und Dokumente beim Cloud-Sync als echte Dateien in Storage
-- (husora-property-photos, husora-documents, husora-private) und ersetzt sie in
-- app_data durch Verweise der Form
--   husora-storage:<bucket>/organization/<org>/property/<haus>/<bereich>/<hash>.<ext>
-- Diese Migration legt dazu Metadaten in public.documents und public.photos an.

alter table public.documents add column app_ref text;
alter table public.photos    add column app_ref text;
comment on column public.documents.app_ref is 'ID des Dokuments in der Husora-App (Cloud-Sync).';
comment on column public.photos.app_ref is 'Herkunft in der Husora-App, z. B. <haus-id>:<datei> (Cloud-Sync).';
create unique index documents_app_ref_idx on public.documents (organization_id, app_ref) where app_ref is not null;
create unique index photos_app_ref_idx    on public.photos (organization_id, app_ref)    where app_ref is not null;

-- Verweis zerlegen: Bucket, Pfad und – falls vorhanden – Haus-UUID aus dem Pfad
create or replace function private.app_file_ref(p_ref text, out bucket text, out path text, out property_id uuid)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_rest text;
  v_parts text[];
begin
  if p_ref is null or p_ref !~ '^husora-storage:[a-z-]+/organization/' then
    return;
  end if;
  v_rest := substr(p_ref, length('husora-storage:') + 1);
  bucket := split_part(v_rest, '/', 1);
  path := substr(v_rest, length(bucket) + 2);
  v_parts := string_to_array(path, '/');
  if v_parts[3] = 'property' and v_parts[4] ~ '^[0-9a-f-]{36}$' then
    property_id := v_parts[4]::uuid;
  end if;
end;
$$;

create or replace function private.app_document_type(p_category text, p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when concat_ws(' ', p_category, p_name) ~* '(vertrag|contract|miet|pacht)' then 'contract'
    when concat_ws(' ', p_category, p_name) ~* '(rechnung|invoice|faktura|beleg)' then 'invoice'
    when concat_ws(' ', p_category, p_name) ~* '(angebot|offert|quote)' then 'quote'
    when concat_ws(' ', p_category, p_name) ~* '(versicherung|insurance|försäkring|police)' then 'insurance'
    when concat_ws(' ', p_category, p_name) ~* '(anleitung|handbuch|manual|bedienung)' then 'manual'
    when concat_ws(' ', p_category, p_name) ~* '(protokoll|kontroll|inspection|besiktning)' then 'inspection_report'
    when concat_ws(' ', p_category, p_name) ~* '(reparatur|repair)' then 'repair_report'
    when concat_ws(' ', p_category, p_name) ~* '(grundriss|plan|ritning)' then 'floor_plan'
    when concat_ws(' ', p_category, p_name) ~* '(energie|energy)' then 'energy_certificate'
    when concat_ws(' ', p_category, p_name) ~* '(genehmigung|permit|bygglov)' then 'permit'
    else 'other'
  end
$$;

-- Dokumente (stugliv-documents) → public.documents
create or replace function private.project_app_documents(p_org uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item  jsonb;
  v_file  record;
  v_count integer := 0;
  v_refs  text[] := '{}';
begin
  for v_item in select * from jsonb_array_elements(p_items) loop
    continue when coalesce(v_item ->> 'id', '') = '';
    select * into v_file from private.app_file_ref(v_item ->> 'dataUrl');
    continue when v_file.bucket is null or v_file.bucket not in ('husora-documents', 'husora-private', 'husora-public');
    begin
      insert into public.documents (organization_id, property_id, app_ref, file_name, file_type, file_size,
                                    storage_bucket, storage_path, document_type)
      values (p_org, v_file.property_id, v_item ->> 'id', coalesce(nullif(trim(v_item ->> 'name'), ''), 'Dokument'),
              nullif(v_item ->> 'type', ''), private.app_num(v_item ->> 'size')::bigint,
              v_file.bucket, v_file.path, private.app_document_type(v_item ->> 'category', v_item ->> 'name'))
      on conflict (organization_id, app_ref) where app_ref is not null do update set
        property_id = excluded.property_id, file_name = excluded.file_name, file_type = excluded.file_type,
        file_size = excluded.file_size, storage_bucket = excluded.storage_bucket, storage_path = excluded.storage_path,
        document_type = excluded.document_type;
      v_refs := v_refs || (v_item ->> 'id');
      v_count := v_count + 1;
    exception when unique_violation then
      null;  -- gleiche Datei mehrfach in der App: ein Eintrag genügt
    end;
  end loop;
  delete from public.documents d
  where d.organization_id = p_org and d.app_ref is not null and not (d.app_ref = any (v_refs));
  return v_count;
end;
$$;

-- Hausfotos (stugliv-properties → photo / photos[]) → public.photos
create or replace function private.project_app_photos(p_org uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ref   record;
  v_file  record;
  v_count integer := 0;
  v_refs  text[] := '{}';
  v_app   text;
begin
  for v_ref in
    select distinct p ->> 'id' as property_ref, p ->> 'name' as property_name, f.value as ref
    from jsonb_array_elements(p_items) p
    cross join lateral (
      select jsonb_array_elements_text(case when jsonb_typeof(p -> 'photos') = 'array' then p -> 'photos' else '[]'::jsonb end)
      union all
      select p ->> 'photo'
    ) f(value)
    where f.value like 'husora-storage:husora-property-photos/%'
  loop
    select * into v_file from private.app_file_ref(v_ref.ref);
    continue when v_file.property_id is null;
    v_app := v_ref.property_ref || ':' || regexp_replace(v_file.path, '^.*/', '');
    begin
      insert into public.photos (organization_id, property_id, app_ref, storage_bucket, storage_path, caption)
      values (p_org, v_file.property_id, v_app, v_file.bucket, v_file.path, v_ref.property_name)
      on conflict (organization_id, app_ref) where app_ref is not null do update set
        storage_bucket = excluded.storage_bucket, storage_path = excluded.storage_path, caption = excluded.caption;
      v_refs := v_refs || v_app;
      v_count := v_count + 1;
    exception when unique_violation or foreign_key_violation or check_violation then
      null;
    end;
  end loop;
  delete from public.photos ph
  where ph.organization_id = p_org and ph.app_ref is not null and not (ph.app_ref = any (v_refs));
  return v_count;
end;
$$;

-- Übernahme-Trigger um Dokumente und Fotos erweitern
create or replace function private.project_app_data()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_json   jsonb;
  v_count  integer;
  v_photos integer;
  v_status text;
begin
  if new.key not in ('stugliv-properties', 'stugliv-bookings', 'stugliv-tasks', 'stugliv-documents') then
    return null;
  end if;
  begin
    v_json := new.value::jsonb;
    if jsonb_typeof(v_json) <> 'array' then
      v_status := 'übersprungen: keine Liste';
    elsif new.key = 'stugliv-properties' then
      v_count := private.project_app_properties(new.organization_id, v_json);
      v_photos := private.project_app_photos(new.organization_id, v_json);
      v_status := v_count || ' Ferienhäuser' || case when v_photos > 0 then ', ' || v_photos || ' Fotos' else '' end || ' übernommen';
      update public.app_data set value = value
      where organization_id = new.organization_id and key in ('stugliv-bookings', 'stugliv-tasks', 'stugliv-documents');
    elsif new.key = 'stugliv-bookings' then
      v_count := private.project_app_bookings(new.organization_id, v_json);
      v_status := v_count || ' Buchungen übernommen';
      update public.app_data set value = value
      where organization_id = new.organization_id and key = 'stugliv-tasks';
    elsif new.key = 'stugliv-documents' then
      v_count := private.project_app_documents(new.organization_id, v_json);
      v_status := v_count || ' Dokumente übernommen';
    else
      v_count := private.project_app_tasks(new.organization_id, v_json);
      v_status := v_count || ' Aufgaben übernommen';
    end if;
  exception when others then
    v_status := 'Fehler: ' || left(sqlerrm, 500);
  end;
  update public.app_data set projection_status = v_status
  where organization_id = new.organization_id and key = new.key and projection_status is distinct from v_status;
  return null;
end;
$$;

grant execute on function private.app_file_ref(text), private.app_document_type(text, text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Speicherverbrauch für die Anzeige in der App
-- Grenzen: Supabase Free-Plan (500 MB Datenbank, 1 GB Dateien); anpassbar über
-- organizations.settings -> 'storage_limits' -> {"database_mb": …, "files_mb": …}
-- -----------------------------------------------------------------------------
create or replace function public.my_cloud_usage(p_organization_id uuid)
returns table (
  app_data_bytes  bigint,
  file_count      bigint,
  file_bytes      bigint,
  database_bytes  bigint,
  database_limit  bigint,
  files_limit     bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limits jsonb;
begin
  if not private.can_read_org(p_organization_id) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  select coalesce(o.settings -> 'storage_limits', '{}'::jsonb) into v_limits from public.organizations o where o.id = p_organization_id;
  return query
    select
      (select coalesce(sum(a.size_bytes), 0)::bigint from public.app_data a where a.organization_id = p_organization_id),
      (select count(*) from storage.objects so where so.name like 'organization/' || p_organization_id::text || '/%'),
      (select coalesce(sum((so.metadata ->> 'size')::bigint), 0)::bigint from storage.objects so
        where so.name like 'organization/' || p_organization_id::text || '/%'),
      pg_database_size(current_database()),
      coalesce((v_limits ->> 'database_mb')::bigint, 500) * 1024 * 1024,
      coalesce((v_limits ->> 'files_mb')::bigint, 1024) * 1024 * 1024;
end;
$$;
revoke all on function public.my_cloud_usage(uuid) from public, anon;
grant execute on function public.my_cloud_usage(uuid) to authenticated, service_role;

-- >>> 20261030001700_partner_portal.sql
-- =============================================================================
-- HUSORA · Migration 1700 · Zugang für Servicepartner (Partner-Portal)
-- =============================================================================
-- Servicepartner sind eigene Organisationen (org_type service_partner) mit
-- Firmendaten, Mitarbeitern, eigenen Kunden, Leistungen und Kontrollvorlagen.
-- Ein Hausbesitzer lädt einen Partner per Code ein; danach ist der Partner-
-- Datensatz des Hausbesitzers (service_partners) mit der Partner-Organisation
-- verknüpft. Alle bestehenden Regeln (Aufträge, Aufgaben, Kontrollen, Angebote,
-- Rechnungen, Nachrichten, Dateien) greifen damit automatisch – ohne doppelte Daten.
--
-- Rollen in der Partner-Organisation (organization_members.role):
--   admin            Inhaber / Administration
--   dispatcher       Disposition: alle Aufträge, Mitarbeiter einteilen
--   service_manager  wie dispatcher
--   accounting       Buchhaltung: Aufträge lesen, Angebote/Rechnungen
--   technician       Techniker: nur ihm zugewiesene Aufträge
--   inspector        Kontrolleur: nur ihm zugewiesene Aufträge und Kontrollen
--   viewer           nur lesen

-- -----------------------------------------------------------------------------
-- Rollen erweitern
-- -----------------------------------------------------------------------------
alter table public.organization_members drop constraint organization_members_role_check;
alter table public.organization_members add constraint organization_members_role_check check (role in (
  'owner', 'admin', 'property_manager', 'service_manager', 'service_partner', 'cleaner', 'viewer',
  'dispatcher', 'technician', 'inspector', 'accounting'));

create or replace function private.is_org_staff(p_organization_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select private.has_org_role(p_organization_id, array['admin', 'property_manager', 'service_manager', 'dispatcher']) $$;

create or replace function private.can_read_org(p_organization_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select private.has_org_role(p_organization_id, array['admin', 'property_manager', 'service_manager', 'dispatcher', 'accounting', 'viewer']) $$;

-- -----------------------------------------------------------------------------
-- Organisationen: Art und Firmendaten
-- -----------------------------------------------------------------------------
alter table public.organizations
  add column org_type             text not null default 'homeowner' check (org_type in ('homeowner', 'service_partner', 'both')),
  add column legal_form           text,
  add column description          text,
  add column logo_url             text,
  add column vat_id               text,
  add column registration_number  text,
  add column contact_name         text,
  add column street               text,
  add column postal_code          text,
  add column city                 text,
  add column billing_street       text,
  add column billing_postal_code  text,
  add column billing_city         text,
  add column billing_country      text check (billing_country is null or billing_country ~ '^[A-Z]{2}$'),
  add column bank_name            text,
  add column iban                 text check (iban is null or replace(iban, ' ', '') ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{8,30}$'),
  add column bic                  text check (bic is null or bic ~ '^[A-Z0-9]{8}([A-Z0-9]{3})?$'),
  add column service_radius_km    numeric(7, 2) check (service_radius_km >= 0),
  add column business_hours       jsonb not null default '{}'::jsonb,
  add column emergency_phone      text;
comment on column public.organizations.org_type is 'homeowner = Hausbesitzer/Verwaltung · service_partner = Servicebetrieb · both = beides';
create index organizations_type_idx on public.organizations (org_type);

-- Verknüpfung: Partner-Datensatz eines Hausbesitzers ↔ Organisation des Partners
alter table public.service_partners add column partner_organization_id uuid references public.organizations(id) on delete set null;
comment on column public.service_partners.partner_organization_id is 'Organisation des Servicepartners (Partner-Portal). Ihre Mitarbeiter sehen die Aufträge dieses Partners.';
create unique index service_partners_partner_org_idx on public.service_partners (organization_id, partner_organization_id)
  where partner_organization_id is not null;
create index service_partners_partner_org_lookup_idx on public.service_partners (partner_organization_id) where partner_organization_id is not null;

-- Zuständiger Mitarbeiter des Partners
alter table public.service_orders add column assigned_user_id uuid references public.users(id) on delete set null;
comment on column public.service_orders.assigned_user_id is 'Mitarbeiter des Servicepartners, der den Auftrag ausführt (Techniker sehen nur ihre Aufträge).';
create index service_orders_assigned_user_idx on public.service_orders (assigned_user_id, status) where assigned_user_id is not null;

-- -----------------------------------------------------------------------------
-- Kunden des Servicepartners
-- -----------------------------------------------------------------------------
create table public.customers (
  id                      uuid primary key default gen_random_uuid(),
  organization_id         uuid not null references public.organizations(id) on delete cascade,
  linked_organization_id  uuid references public.organizations(id) on delete set null,
  customer_number         text,
  company_name            text,
  first_name              text,
  last_name               text,
  email                   text,
  phone                   text,
  street                  text,
  postal_code             text,
  city                    text,
  country                 text check (country is null or country ~ '^[A-Z]{2}$'),
  notes                   text,
  created_by              uuid references public.users(id) on delete set null,
  updated_by              uuid references public.users(id) on delete set null,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (organization_id, id),
  check (coalesce(nullif(trim(company_name), ''), nullif(trim(first_name), ''), nullif(trim(last_name), '')) is not null)
);
comment on table public.customers is 'Kunden eines Servicepartners. linked_organization_id = Hausbesitzer-Organisation, die den Partner eingeladen hat.';
create index customers_org_idx on public.customers (organization_id, lower(coalesce(company_name, last_name, first_name)));
create unique index customers_linked_idx on public.customers (organization_id, linked_organization_id) where linked_organization_id is not null;
create index customers_linked_lookup_idx on public.customers (linked_organization_id) where linked_organization_id is not null;
create index customers_created_by_fk_idx on public.customers (created_by) where created_by is not null;
create index customers_updated_by_fk_idx on public.customers (updated_by) where updated_by is not null;
create trigger customers_set_updated_at before update on public.customers
  for each row execute function private.set_updated_at();
create trigger customers_set_actor before insert or update on public.customers
  for each row execute function private.set_actor_columns();
create trigger customers_audit after insert or update or delete on public.customers
  for each row execute function private.audit_row_change();

alter table public.properties add column owner_customer_id uuid;
alter table public.properties add constraint properties_owner_customer_fkey
  foreign key (organization_id, owner_customer_id) references public.customers (organization_id, id) on delete set null (owner_customer_id);
create index properties_owner_customer_idx on public.properties (owner_customer_id) where owner_customer_id is not null;

-- -----------------------------------------------------------------------------
-- Einladungen: Hausbesitzer → Partner, Partner → Mitarbeiter
-- -----------------------------------------------------------------------------
create table public.service_partner_invites (
  id                        uuid primary key default gen_random_uuid(),
  organization_id           uuid not null references public.organizations(id) on delete cascade,
  service_partner_id        uuid not null,
  email                     text,
  code                      text not null unique,
  created_by                uuid references public.users(id) on delete set null,
  expires_at                timestamptz not null default now() + interval '30 days',
  accepted_at               timestamptz,
  accepted_organization_id  uuid references public.organizations(id) on delete set null,
  created_at                timestamptz not null default now(),
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete cascade
);
create index service_partner_invites_org_idx on public.service_partner_invites (organization_id, created_at desc);
create index service_partner_invites_partner_idx on public.service_partner_invites (service_partner_id);
create index service_partner_invites_accepted_org_idx on public.service_partner_invites (accepted_organization_id) where accepted_organization_id is not null;
create index service_partner_invites_created_by_idx on public.service_partner_invites (created_by) where created_by is not null;

create table public.organization_invites (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  email            text not null,
  role             text not null check (role in ('admin', 'dispatcher', 'service_manager', 'accounting', 'technician', 'inspector', 'viewer', 'property_manager', 'owner', 'cleaner')),
  code             text not null unique,
  created_by       uuid references public.users(id) on delete set null,
  expires_at       timestamptz not null default now() + interval '14 days',
  accepted_at      timestamptz,
  accepted_by      uuid references public.users(id) on delete set null,
  created_at       timestamptz not null default now()
);
create index organization_invites_org_idx on public.organization_invites (organization_id, created_at desc);
create index organization_invites_created_by_idx on public.organization_invites (created_by) where created_by is not null;
create index organization_invites_accepted_by_idx on public.organization_invites (accepted_by) where accepted_by is not null;

-- Kurzer, gut abtippbarer Code (ohne 0/O/1/I)
create or replace function private.invite_code(p_prefix text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea := extensions.gen_random_bytes(8);
  v_code  text := '';
begin
  for i in 0..7 loop
    v_code := v_code || substr(v_chars, (get_byte(v_bytes, i) % 32) + 1, 1);
    if i = 3 then v_code := v_code || '-'; end if;
  end loop;
  return p_prefix || '-' || v_code;
end;
$$;

-- -----------------------------------------------------------------------------
-- Zugriffs-Helfer für Partner-Organisationen
-- -----------------------------------------------------------------------------
-- Partnerbetriebe mit vollem Zugriff: direkte Zuordnung (service_partner_users) oder
-- Leitung/Disposition/Buchhaltung der verknüpften Partner-Organisation
create or replace function private.my_partner_ids()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select spu.service_partner_id
  from public.service_partner_users spu
  join public.service_partners sp on sp.id = spu.service_partner_id
  where spu.user_id = private.current_user_id()
    and private.org_role(sp.organization_id) is not null
  union
  select sp.id
  from public.service_partners sp
  join public.organization_members m on m.organization_id = sp.partner_organization_id
  where m.user_id = private.current_user_id()
    and m.status = 'active'
    and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher', 'accounting')
$$;

-- Jeder aktive Mitarbeiter der Partner-Organisation (auch Techniker/Kontrolleure)
create or replace function private.is_partner_employee(p_service_partner_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_service_partner_id is not null and (
    private.is_partner_member(p_service_partner_id)
    or exists (
      select 1 from public.service_partners sp
      join public.organization_members m on m.organization_id = sp.partner_organization_id
      where sp.id = p_service_partner_id and m.user_id = private.current_user_id() and m.status = 'active'
    )
  )
$$;

-- Auftrag bearbeiten (Partnerseite): Leitung/Disposition oder zugewiesener Mitarbeiter
create or replace function private.can_work_order(p_service_order_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.service_orders o
    where o.id = p_service_order_id
      and o.status <> 'draft'
      and (
        private.is_org_staff(o.organization_id)
        or private.is_partner_member(o.service_partner_id)
        or (o.assigned_user_id = private.current_user_id() and private.is_partner_employee(o.service_partner_id))
      )
  )
$$;

create or replace function private.can_read_service_order(p_service_order_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.service_orders o
    where o.id = p_service_order_id
      and (
        private.can_read_org(o.organization_id)
        or private.is_property_owner(o.property_id)
        or (o.status <> 'draft' and private.is_partner_member(o.service_partner_id))
        or (o.status <> 'draft' and o.assigned_user_id = private.current_user_id() and private.is_partner_employee(o.service_partner_id))
      )
  )
$$;

create or replace function private.can_read_inspection(p_inspection_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.inspections i
    where i.id = p_inspection_id
      and (
        private.can_read_org(i.organization_id)
        or private.is_property_owner(i.property_id)
        or (i.inspector_user_id = private.current_user_id() and (private.is_org_member(i.organization_id) or private.is_partner_employee(i.service_partner_id)))
        or private.is_partner_member(i.service_partner_id)
      )
  )
$$;

create or replace function private.can_work_inspection(p_inspection_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.inspections i
    where i.id = p_inspection_id
      and (
        private.is_org_staff(i.organization_id)
        or (i.status in ('scheduled', 'in_progress') and (
              (i.inspector_user_id = private.current_user_id() and (private.is_org_member(i.organization_id) or private.is_partner_employee(i.service_partner_id)))
              or private.is_partner_member(i.service_partner_id)))
      )
  )
$$;

create or replace function private.can_read_property(p_property_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.can_read_org(private.property_org(p_property_id))
      or private.property_role(p_property_id) is not null
      or exists (
        select 1 from public.service_tasks t
        where t.property_id = p_property_id
          and t.status not in ('cancelled')
          and (
            (t.assigned_user_id = private.current_user_id() and private.is_org_member(t.organization_id))
            or private.is_partner_member(t.assigned_partner_id)
          )
      )
      or exists (
        select 1 from public.service_orders o
        where o.property_id = p_property_id
          and o.status not in ('draft', 'cancelled')
          and (private.is_partner_member(o.service_partner_id)
               or (o.assigned_user_id = private.current_user_id() and private.is_partner_employee(o.service_partner_id)))
      )
      or exists (
        select 1 from public.inspections i
        where i.property_id = p_property_id
          and i.status <> 'cancelled'
          and (
            (i.inspector_user_id = private.current_user_id() and (private.is_org_member(i.organization_id) or private.is_partner_employee(i.service_partner_id)))
            or private.is_partner_member(i.service_partner_id)
          )
      )
$$;

-- Partnerseite: Mitarbeiter einteilen, Techniker dürfen nur Ablauf ändern
create or replace function private.service_orders_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status   text;
  v_note     text;
  v_sched    timestamptz;
  v_actual   numeric(12, 2);
  v_assigned uuid;
  v_lead     boolean;
begin
  if tg_op = 'UPDATE' and not private.is_system_context() then
    new.order_number := old.order_number;
    if not private.is_org_staff(old.organization_id) then
      v_lead := private.is_partner_member(old.service_partner_id);
      if not v_lead and not (old.assigned_user_id = private.current_user_id() and private.is_partner_employee(old.service_partner_id)) then
        raise exception 'Keine Berechtigung für Auftrag %', old.order_number using errcode = '42501';
      end if;
      if new.status is distinct from old.status and not (
           (old.status = 'offered' and new.status in ('accepted', 'rejected'))
        or (old.status in ('accepted', 'scheduled') and new.status in ('scheduled', 'in_progress'))
        or (old.status in ('accepted', 'scheduled', 'in_progress') and new.status = 'completed')
      ) then
        raise exception 'Statuswechsel % → % ist für Partner nicht erlaubt', old.status, new.status using errcode = '42501';
      end if;
      v_status := new.status;
      v_note := new.response_note;
      v_sched := new.scheduled_at;
      v_actual := new.actual_cost;
      v_assigned := case when v_lead then new.assigned_user_id else old.assigned_user_id end;
      new := old;
      new.status := v_status;
      new.response_note := v_note;
      new.scheduled_at := v_sched;
      new.actual_cost := v_actual;
      new.assigned_user_id := v_assigned;
    end if;
  end if;

  if tg_op = 'INSERT' or new.status is distinct from old.status then
    case new.status
      when 'offered'   then new.offered_at := coalesce(new.offered_at, now());
      when 'accepted'  then new.accepted_at := coalesce(new.accepted_at, now());
      when 'rejected'  then new.rejected_at := coalesce(new.rejected_at, now());
      when 'completed' then new.completed_at := coalesce(new.completed_at, now());
      else null;
    end case;
  end if;
  return new;
end;
$$;

-- Zugewiesener Mitarbeiter muss zum Partner gehören
create or replace function private.check_order_assignee()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.assigned_user_id is not null and new.assigned_user_id is distinct from old.assigned_user_id
     and not exists (
       select 1 from public.service_partners sp
       join public.organization_members m on m.organization_id = sp.partner_organization_id
       where sp.id = new.service_partner_id and m.user_id = new.assigned_user_id and m.status = 'active'
       union all
       select 1 from public.service_partner_users spu
       where spu.service_partner_id = new.service_partner_id and spu.user_id = new.assigned_user_id
     ) then
    raise exception 'Die zugewiesene Person arbeitet nicht für diesen Servicepartner' using errcode = '23503';
  end if;
  return new;
end;
$$;
create trigger service_orders_check_assignee before insert or update of assigned_user_id, service_partner_id on public.service_orders
  for each row execute function private.check_order_assignee();

-- Partner darf bei seiner Kontrolle auch den Prüfer aus seinem Team einteilen
create or replace function private.inspections_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status   text;
  v_started  timestamptz;
  v_done     timestamptz;
  v_overall  text;
  v_notes    text;
  v_inspector uuid;
begin
  if not private.is_system_context()
     and not private.is_org_staff(old.organization_id)
     and not private.can_manage_property(old.property_id) then
    if new.status is distinct from old.status and new.status not in ('in_progress', 'completed') then
      raise exception 'Status "%" darf nur von der Verwaltung gesetzt werden', new.status using errcode = '42501';
    end if;
    v_status := new.status; v_started := new.started_at; v_done := new.completed_at;
    v_overall := new.overall_status; v_notes := new.notes;
    v_inspector := case when private.is_partner_member(old.service_partner_id) then new.inspector_user_id else old.inspector_user_id end;
    new := old;
    new.status := v_status; new.started_at := v_started; new.completed_at := v_done;
    new.overall_status := v_overall; new.notes := v_notes; new.inspector_user_id := v_inspector;
  end if;
  if new.status = 'in_progress' then
    new.started_at := coalesce(new.started_at, now());
  elsif new.status = 'completed' then
    new.started_at := coalesce(new.started_at, now());
    new.completed_at := coalesce(new.completed_at, now());
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Policies anpassen
-- -----------------------------------------------------------------------------
-- Häuser: Organisation direkt prüfen (sonst scheitert INSERT … RETURNING, weil die
-- Hilfsfunktion die gerade eingefügte Zeile noch nicht sieht)
drop policy properties_select on public.properties;
create policy properties_select on public.properties for select to authenticated
  using (private.can_read_org(organization_id) or private.can_read_property(id));

drop policy service_orders_select on public.service_orders;
create policy service_orders_select on public.service_orders for select to authenticated
  using (
    private.can_read_org(organization_id)
    or private.is_property_owner(property_id)
    or (status <> 'draft' and private.is_partner_member(service_partner_id))
    or (status <> 'draft' and assigned_user_id = (select private.current_user_id()) and private.is_partner_employee(service_partner_id))
  );
drop policy service_orders_update on public.service_orders;
create policy service_orders_update on public.service_orders for update to authenticated
  using (
    private.is_org_staff(organization_id)
    or (status <> 'draft' and private.is_partner_member(service_partner_id))
    or (status <> 'draft' and assigned_user_id = (select private.current_user_id()) and private.is_partner_employee(service_partner_id))
  )
  with check (private.is_org_staff(organization_id) or private.is_partner_employee(service_partner_id));

drop policy inspections_select on public.inspections;
create policy inspections_select on public.inspections for select to authenticated
  using (private.can_read_inspection(id));
drop policy inspections_insert on public.inspections;
create policy inspections_insert on public.inspections for insert to authenticated
  with check (private.is_org_staff(organization_id) or private.can_manage_property(property_id));
drop policy inspections_update on public.inspections;
create policy inspections_update on public.inspections for update to authenticated
  using (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or private.can_work_inspection(id)
  )
  with check (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or private.is_partner_employee(service_partner_id)
    or (inspector_user_id = (select private.current_user_id()) and private.is_org_member(organization_id))
  );

-- Kontrolle des eigenen Betriebs (auch nach Abschluss, z. B. für den Prüfbericht)
create or replace function private.is_inspection_partner(p_inspection_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.inspections i
    where i.id = p_inspection_id
      and (private.is_partner_member(i.service_partner_id)
           or (i.inspector_user_id = private.current_user_id() and private.is_partner_employee(i.service_partner_id)))
  )
$$;

drop policy documents_insert on public.documents;
create policy documents_insert on public.documents for insert to authenticated
  with check (
    private.is_org_staff(organization_id)
    or (property_id is not null and private.can_manage_property(property_id))
    or (service_order_id is not null and private.can_work_order(service_order_id))
    or (inspection_id is not null and private.is_inspection_partner(inspection_id))
  );
drop policy photos_insert on public.photos;
create policy photos_insert on public.photos for insert to authenticated
  with check (
    private.is_org_staff(organization_id)
    or private.can_manage_property(property_id)
    or (inspection_id is not null and private.can_work_inspection(inspection_id))
    or (service_order_id is not null and private.can_work_order(service_order_id))
    or (service_task_id is not null and private.can_read_task(service_task_id) and private.is_org_member(organization_id))
  );
drop policy messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (
    (private.is_org_member(organization_id) or (service_order_id is not null and private.can_work_order(service_order_id)))
    and (service_order_id is null or private.can_read_service_order(service_order_id))
    and (recipient_user_id is null or private.is_user_in_org(recipient_user_id, organization_id))
  );

alter table public.customers enable row level security;
create policy customers_select on public.customers for select to authenticated
  using (private.can_read_org(organization_id));
create policy customers_insert on public.customers for insert to authenticated
  with check (private.is_org_staff(organization_id));
create policy customers_update on public.customers for update to authenticated
  using (private.is_org_staff(organization_id)) with check (private.is_org_staff(organization_id));
create policy customers_delete on public.customers for delete to authenticated
  using (private.is_org_staff(organization_id));

alter table public.service_partner_invites enable row level security;
create policy service_partner_invites_select on public.service_partner_invites for select to authenticated
  using (private.is_org_staff(organization_id) or (accepted_organization_id is not null and private.can_read_org(accepted_organization_id)));
create policy service_partner_invites_delete on public.service_partner_invites for delete to authenticated
  using (private.is_org_staff(organization_id));

alter table public.organization_invites enable row level security;
create policy organization_invites_select on public.organization_invites for select to authenticated
  using (private.is_org_admin(organization_id));
create policy organization_invites_delete on public.organization_invites for delete to authenticated
  using (private.is_org_admin(organization_id));
revoke all on public.customers, public.service_partner_invites, public.organization_invites from anon;
revoke insert, update on public.service_partner_invites, public.organization_invites from authenticated;

-- -----------------------------------------------------------------------------
-- Globale Servicearten (Leistungskategorien)
-- -----------------------------------------------------------------------------
insert into public.service_types (id, organization_id, code, name, description, category) values
  ('eeeeeeee-0000-4000-8000-000000000004', null, 'inspection',              'Hauskontrolle',        'Abwesenheits- und Saisonkontrollen',         'inspection'),
  ('eeeeeeee-0000-4000-8000-000000000010', null, 'holiday_home_inspection', 'Ferienhauskontrolle',  'Kontrolle vor/nach Aufenthalten',            'inspection'),
  ('eeeeeeee-0000-4000-8000-000000000001', null, 'cleaning',                'Reinigung',            'End- und Zwischenreinigung, Wäschewechsel', 'housekeeping'),
  ('eeeeeeee-0000-4000-8000-000000000002', null, 'gardening',               'Gartenpflege',         'Rasen, Hecken, Laub',                        'outdoor'),
  ('eeeeeeee-0000-4000-8000-000000000003', null, 'snow_removal',            'Winterdienst',         'Schneeräumung, Streudienst, Dach',           'outdoor'),
  ('eeeeeeee-0000-4000-8000-000000000011', null, 'repair',                  'Reparatur',            'Reparaturen aller Art',                      'craft'),
  ('eeeeeeee-0000-4000-8000-000000000006', null, 'plumbing',                'Sanitär',              'Wasser, Abwasser, Brunnen',                  'craft'),
  ('eeeeeeee-0000-4000-8000-000000000007', null, 'heating',                 'Heizung',              'Wartung und Reparatur von Heizanlagen',      'craft'),
  ('eeeeeeee-0000-4000-8000-000000000005', null, 'electrician',             'Elektro',              'Elektroinstallation und -reparatur',         'craft'),
  ('eeeeeeee-0000-4000-8000-000000000008', null, 'roofing',                 'Dach',                 'Dacharbeiten, Rinnenreinigung',              'craft'),
  ('eeeeeeee-0000-4000-8000-000000000012', null, 'facade',                  'Fassade',              'Anstrich, Holzschutz, Fassadenreparatur',    'craft'),
  ('eeeeeeee-0000-4000-8000-000000000013', null, 'windows',                 'Fenster',              'Fenster und Türen',                          'craft'),
  ('eeeeeeee-0000-4000-8000-000000000014', null, 'key_service',             'Schlüsselservice',     'Schlüsselübergabe und -verwaltung',          'service'),
  ('eeeeeeee-0000-4000-8000-000000000009', null, 'general_maintenance',     'Technische Wartung',   'Hausmeisterservice und technische Wartung',  'maintenance')
on conflict on constraint service_types_code_unique do nothing;

-- -----------------------------------------------------------------------------
-- RPC: Partner-Organisation anlegen (Onboarding)
-- -----------------------------------------------------------------------------
create or replace function public.create_partner_organization(p_profile jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := private.current_user_id();
  v_org      uuid;
  v_partner  uuid;
  v_template uuid;
  v_name     text := nullif(trim(p_profile ->> 'name'), '');
  v_code     text;
  v_tpl      record;
begin
  if v_user is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  if v_name is null then
    raise exception 'Bitte den Firmennamen angeben' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.organization_members m join public.organizations o on o.id = m.organization_id
    where m.user_id = v_user and m.status = 'active' and o.org_type in ('service_partner', 'both') and m.role = 'admin'
  ) then
    raise exception 'Du hast bereits einen Servicebetrieb angelegt' using errcode = '23505';
  end if;

  insert into public.organizations (name, org_type, legal_form, contact_name, email, phone, website, street, postal_code, city,
                                    country, currency, timezone, vat_id, registration_number, emergency_phone, service_radius_km, description)
  values (v_name, 'service_partner', nullif(p_profile ->> 'legal_form', ''), nullif(p_profile ->> 'contact_name', ''),
          nullif(p_profile ->> 'email', ''), nullif(p_profile ->> 'phone', ''), nullif(p_profile ->> 'website', ''),
          nullif(p_profile ->> 'street', ''), nullif(p_profile ->> 'postal_code', ''), nullif(p_profile ->> 'city', ''),
          coalesce(nullif(upper(p_profile ->> 'country'), ''), 'SE'), coalesce(nullif(upper(p_profile ->> 'currency'), ''), 'SEK'),
          'Europe/Stockholm', nullif(p_profile ->> 'vat_id', ''), nullif(p_profile ->> 'registration_number', ''),
          nullif(p_profile ->> 'emergency_phone', ''), private.app_num(p_profile ->> 'service_radius_km'), nullif(p_profile ->> 'description', ''))
  returning id into v_org;
  -- Admin-Mitgliedschaft legt private.add_creator_as_admin an

  -- Eigener Partner-Datensatz: für Aufträge eigener Kunden
  insert into public.service_partners (organization_id, partner_organization_id, company_name, contact_name, email, phone,
                                       website, street, postal_code, city, country, status, description)
  values (v_org, v_org, v_name, nullif(p_profile ->> 'contact_name', ''), nullif(p_profile ->> 'email', ''),
          nullif(p_profile ->> 'phone', ''), nullif(p_profile ->> 'website', ''), nullif(p_profile ->> 'street', ''),
          nullif(p_profile ->> 'postal_code', ''), nullif(p_profile ->> 'city', ''),
          coalesce(nullif(upper(p_profile ->> 'country'), ''), 'SE'), 'active', nullif(p_profile ->> 'description', ''))
  returning id into v_partner;

  if coalesce(p_profile ->> 'service_radius_km', '') <> '' or coalesce(p_profile ->> 'city', '') <> '' then
    insert into public.service_partner_areas (service_partner_id, city, radius_km)
    values (v_partner, nullif(p_profile ->> 'city', ''), private.app_num(p_profile ->> 'service_radius_km'));
  end if;

  for v_code in select jsonb_array_elements_text(coalesce(p_profile -> 'services', '[]'::jsonb)) loop
    insert into public.service_partner_services (service_partner_id, service_type_id, currency)
    select v_partner, st.id, coalesce(nullif(upper(p_profile ->> 'currency'), ''), 'SEK')
    from public.service_types st where st.code = v_code and st.organization_id is null
    on conflict (service_partner_id, service_type_id) do nothing;
  end loop;

  -- Standard-Kontrollvorlagen
  for v_tpl in
    select * from (values
      ('Standard Hauskontrolle', 'Regelmäßige Kontrolle eines Wohnhauses', array[
         'Außen|Dach und Dachrinne', 'Außen|Fassade und Holzschutz', 'Außen|Fenster und Türen', 'Außen|Grundstück und Zufahrt',
         'Innen|Feuchtigkeit und Schimmel', 'Innen|Raumtemperatur', 'Technik|Wasserleitungen und Hähne', 'Technik|Heizung',
         'Technik|Strom und Sicherungen', 'Sicherheit|Rauchmelder']),
      ('Ferienhaus Kontrolle', 'Abwesenheitskontrolle für Ferienhäuser', array[
         'Außen|Dach und Dachrinne', 'Außen|Fenster und Türen verschlossen', 'Außen|Briefkasten', 'Innen|Raumtemperatur (Frostschutz)',
         'Innen|Feuchtigkeit und Schimmel', 'Innen|Schädlinge', 'Technik|Wasser und Hauptventil', 'Technik|Heizung / Wärmepumpe',
         'Technik|Strom und Zählerstand', 'Sicherheit|Rauchmelder', 'Sicherheit|Feuerlöscher']),
      ('Übergabekontrolle', 'Kontrolle bei An- und Abreise von Gästen', array[
         'Innen|Sauberkeit', 'Innen|Inventar vollständig', 'Innen|Schäden an Möbeln', 'Innen|Bettwäsche und Handtücher',
         'Technik|Geräte funktionsfähig', 'Außen|Terrasse und Grill', 'Außen|Müll entsorgt', 'Sicherheit|Schlüssel übergeben']),
      ('Winterkontrolle', 'Kontrolle in der Frostperiode', array[
         'Außen|Schneelast auf dem Dach', 'Außen|Zufahrt geräumt', 'Außen|Eiszapfen und Dachrinne', 'Innen|Raumtemperatur (Frostschutz)',
         'Technik|Wasser abgestellt / Frostschutz', 'Technik|Heizung läuft', 'Technik|Stromversorgung', 'Sicherheit|Rauchmelder']),
      ('Technik-Kontrolle', 'Kontrolle der Haustechnik', array[
         'Technik|Heizung / Wärmepumpe', 'Technik|Warmwasserbereiter', 'Technik|Wasserfilter / Brunnen', 'Technik|Abwasser / Kläranlage',
         'Technik|Elektroinstallation und FI-Schalter', 'Technik|Lüftung', 'Sicherheit|Rauchmelder', 'Sicherheit|Feuerlöscher'])
    ) as t(name, description, items)
  loop
    insert into public.inspection_templates (organization_id, name, description)
    values (v_org, v_tpl.name, v_tpl.description) returning id into v_template;
    insert into public.inspection_template_items (template_id, category, name, sort_order)
    select v_template, split_part(item, '|', 1), split_part(item, '|', 2), ord * 10
    from unnest(v_tpl.items) with ordinality as x(item, ord);
  end loop;

  return v_org;
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC: Kontext des Partner-Portals (Organisation, Rolle, verbundene Kunden)
-- -----------------------------------------------------------------------------
create or replace function public.partner_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user   uuid := private.current_user_id();
  v_org_id uuid;
  v_org    public.organizations;
  v_role   text;
begin
  if v_user is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  select m.organization_id, m.role into v_org_id, v_role
  from public.organization_members m
  join public.organizations o on o.id = m.organization_id
  where m.user_id = v_user and m.status = 'active' and o.org_type in ('service_partner', 'both')
  order by (m.role = 'admin') desc, m.created_at
  limit 1;
  select * into v_org from public.organizations o where o.id = v_org_id;
  if v_org.id is null then
    return jsonb_build_object('organization', null);
  end if;
  return jsonb_build_object(
    'organization', to_jsonb(v_org) - 'settings',
    'role', v_role,
    'user_id', v_user,
    'self_partner_id', (select sp.id from public.service_partners sp where sp.organization_id = v_org.id and sp.partner_organization_id = v_org.id limit 1),
    'links', coalesce((
      select jsonb_agg(jsonb_build_object('service_partner_id', sp.id, 'organization_id', sp.organization_id, 'organization_name', o.name) order by o.name)
      from public.service_partners sp join public.organizations o on o.id = sp.organization_id
      where sp.partner_organization_id = v_org.id and sp.organization_id <> v_org.id
    ), '[]'::jsonb)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC: Einladung Hausbesitzer → Partner
-- -----------------------------------------------------------------------------
create or replace function public.create_service_partner_invite(p_service_partner_id uuid, p_email text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org  uuid := private.partner_org(p_service_partner_id);
  v_code text;
begin
  if v_org is null or not private.is_org_staff(v_org) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if exists (select 1 from public.service_partners sp where sp.id = p_service_partner_id and sp.partner_organization_id is not null) then
    raise exception 'Dieser Servicepartner ist bereits verbunden' using errcode = '23505';
  end if;
  -- offene Einladungen dieses Partners ersetzen
  delete from public.service_partner_invites where service_partner_id = p_service_partner_id and accepted_at is null;
  loop
    v_code := private.invite_code('HUS');
    exit when not exists (select 1 from public.service_partner_invites where code = v_code);
  end loop;
  insert into public.service_partner_invites (organization_id, service_partner_id, email, code, created_by)
  values (v_org, p_service_partner_id, nullif(trim(p_email), ''), v_code, private.current_user_id());
  return v_code;
end;
$$;

create or replace function public.accept_service_partner_invite(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := private.current_user_id();
  v_invite   public.service_partner_invites;
  v_partner_org uuid;
  v_home     public.organizations;
  v_inviter  public.users;
begin
  if v_user is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  select m.organization_id into v_partner_org
  from public.organization_members m join public.organizations o on o.id = m.organization_id
  where m.user_id = v_user and m.status = 'active' and o.org_type in ('service_partner', 'both') and m.role in ('admin', 'dispatcher', 'service_manager')
  order by (m.role = 'admin') desc limit 1;
  if v_partner_org is null then
    raise exception 'Bitte zuerst deinen Servicebetrieb anlegen' using errcode = '42501';
  end if;

  select * into v_invite from public.service_partner_invites i where i.code = upper(trim(p_code)) for update;
  if v_invite.id is null or v_invite.expires_at < now() then
    raise exception 'Der Einladungscode ist ungültig oder abgelaufen' using errcode = 'P0002';
  end if;
  if v_invite.accepted_at is not null then
    raise exception 'Dieser Einladungscode wurde bereits verwendet' using errcode = '23505';
  end if;
  if v_invite.organization_id = v_partner_org then
    raise exception 'Das ist eine Einladung deiner eigenen Organisation' using errcode = '22023';
  end if;
  if exists (select 1 from public.service_partners sp where sp.organization_id = v_invite.organization_id and sp.partner_organization_id = v_partner_org) then
    raise exception 'Du bist mit diesem Kunden bereits verbunden' using errcode = '23505';
  end if;

  update public.service_partners sp set partner_organization_id = v_partner_org where sp.id = v_invite.service_partner_id;
  update public.service_partner_invites set accepted_at = now(), accepted_organization_id = v_partner_org where id = v_invite.id;

  select * into v_home from public.organizations o where o.id = v_invite.organization_id;
  select * into v_inviter from public.users u where u.id = v_invite.created_by;
  insert into public.customers (organization_id, linked_organization_id, company_name, first_name, last_name, email, phone, country)
  values (v_partner_org, v_home.id, v_home.name, v_inviter.first_name, v_inviter.last_name,
          coalesce(v_home.email, v_inviter.email), coalesce(v_home.phone, v_inviter.phone), v_home.country)
  on conflict (organization_id, linked_organization_id) where linked_organization_id is not null do nothing;

  return jsonb_build_object('organization_id', v_home.id, 'organization_name', v_home.name, 'service_partner_id', v_invite.service_partner_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC: Mitarbeiter einladen / Einladung annehmen
-- -----------------------------------------------------------------------------
create or replace function public.create_member_invite(p_organization_id uuid, p_email text, p_role text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  if not private.is_org_admin(p_organization_id) then
    raise exception 'Nur Admins können Mitarbeiter einladen' using errcode = '42501';
  end if;
  if coalesce(trim(p_email), '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Bitte eine gültige E-Mail-Adresse angeben' using errcode = '22023';
  end if;
  loop
    v_code := private.invite_code('TEAM');
    exit when not exists (select 1 from public.organization_invites where code = v_code);
  end loop;
  insert into public.organization_invites (organization_id, email, role, code, created_by)
  values (p_organization_id, lower(trim(p_email)), p_role, v_code, private.current_user_id());
  return v_code;
end;
$$;

create or replace function public.accept_member_invite(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   public.users;
  v_invite public.organization_invites;
begin
  select * into v_user from public.users u where u.id = private.current_user_id();
  if v_user.id is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  select * into v_invite from public.organization_invites i where i.code = upper(trim(p_code)) for update;
  if v_invite.id is null or v_invite.expires_at < now() or v_invite.accepted_at is not null then
    raise exception 'Der Einladungscode ist ungültig, abgelaufen oder schon verwendet' using errcode = 'P0002';
  end if;
  if lower(coalesce(v_user.email, '')) <> v_invite.email then
    raise exception 'Diese Einladung gilt für %. Bitte mit dieser E-Mail-Adresse anmelden.', v_invite.email using errcode = '42501';
  end if;
  insert into public.organization_members (organization_id, user_id, role, status, invited_by)
  values (v_invite.organization_id, v_user.id, v_invite.role, 'active', v_invite.created_by)
  on conflict (organization_id, user_id) do update set role = excluded.role, status = 'active';
  update public.organization_invites set accepted_at = now(), accepted_by = v_user.id where id = v_invite.id;
  return jsonb_build_object('organization_id', v_invite.organization_id, 'role', v_invite.role,
    'organization_name', (select o.name from public.organizations o where o.id = v_invite.organization_id));
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC: Kontrolle beim Kunden starten (Vorlage des Partners)
-- -----------------------------------------------------------------------------
create or replace function public.partner_start_inspection(p_property_id uuid, p_template_id uuid, p_scheduled_at timestamptz default now())
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org      uuid := private.property_org(p_property_id);
  v_tpl_org  uuid := private.template_org(p_template_id);
  v_partner  uuid;
  v_id       uuid;
  v_user     uuid := private.current_user_id();
begin
  if v_org is null or not private.can_read_property(p_property_id) then
    raise exception 'Kein Zugriff auf dieses Haus' using errcode = '42501';
  end if;
  if v_tpl_org is null or not private.can_read_org(v_tpl_org) then
    raise exception 'Vorlage nicht gefunden' using errcode = 'P0002';
  end if;
  -- Partner-Datensatz des Kunden, der zu meiner Organisation gehört
  select sp.id into v_partner from public.service_partners sp
  where sp.organization_id = v_org and sp.partner_organization_id = v_tpl_org;
  if v_partner is null or not private.is_partner_employee(v_partner) then
    raise exception 'Für dieses Haus bist du nicht als Servicepartner verbunden' using errcode = '42501';
  end if;

  insert into public.inspections (organization_id, property_id, template_id, inspector_user_id, service_partner_id, scheduled_at, status, notes)
  values (v_org, p_property_id, case when v_tpl_org = v_org then p_template_id end, v_user, v_partner,
          coalesce(p_scheduled_at, now()), 'scheduled',
          'Vorlage: ' || (select t.name from public.inspection_templates t where t.id = p_template_id))
  returning id into v_id;
  if v_tpl_org <> v_org then
    insert into public.inspection_items (inspection_id, category, name, status)
    select v_id, ti.category, ti.name, ti.default_status
    from public.inspection_template_items ti where ti.template_id = p_template_id order by ti.sort_order;
  end if;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Cloud-Sync: Fortschritt des Partners nicht durch den App-Stand überschreiben
-- -----------------------------------------------------------------------------
create or replace function private.project_app_tasks(p_org uuid, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item     jsonb;
  v_count    integer := 0;
  v_refs     text[] := '{}';
  v_tz       text := (select o.timezone from public.organizations o where o.id = p_org);
  v_property uuid;
  v_booking  uuid;
  v_status   text;
begin
  for v_item in select * from jsonb_array_elements(p_items) loop
    continue when coalesce(v_item ->> 'id', '') = '' or coalesce(trim(v_item ->> 'title'), '') = '';
    select p.id into v_property from public.properties p
    where p.organization_id = p_org
      and (p.app_ref = v_item ->> 'propertyId' or (v_item ->> 'propertyId' is null and p.name = v_item ->> 'property'))
    order by (p.app_ref = v_item ->> 'propertyId') desc nulls last
    limit 1;
    continue when v_property is null;
    select b.id into v_booking from public.bookings b
    where b.organization_id = p_org and b.app_ref = v_item ->> 'bookingId';

    v_status := case
      when coalesce(v_item ->> 'done', '') = 'true' or v_item ->> 'status' ilike 'erledigt%' then 'completed'
      when v_item ->> 'status' ilike 'in bearbeitung%' then 'in_progress'
      when v_item ->> 'status' ilike 'storniert%' then 'cancelled'
      else 'pending' end;

    insert into public.service_tasks (organization_id, property_id, booking_id, app_ref, title, description,
                                      priority, status, scheduled_start)
    values (p_org, v_property, v_booking, v_item ->> 'id', trim(v_item ->> 'title'),
            nullif(concat_ws(E'\n', nullif(v_item ->> 'description', ''),
                             case when coalesce(v_item ->> 'area', '') <> '' then 'Bereich: ' || (v_item ->> 'area') end), ''),
            case v_item ->> 'priority' when 'urgent' then 'urgent' when 'soon' then 'high' when 'low' then 'low' else 'normal' end,
            v_status,
            private.app_ts(v_item ->> 'date', v_item ->> 'time', '09:00', v_tz))
    on conflict (organization_id, app_ref) where app_ref is not null do update set
      property_id = excluded.property_id, booking_id = excluded.booking_id, title = excluded.title,
      description = excluded.description, priority = excluded.priority,
      -- Ein Partner arbeitet daran: offener App-Status überschreibt dessen Fortschritt nicht
      status = case
        when public.service_tasks.assigned_partner_id is not null and excluded.status = 'pending' then public.service_tasks.status
        else excluded.status end,
      scheduled_start = excluded.scheduled_start;
    v_refs := v_refs || (v_item ->> 'id');
    v_count := v_count + 1;
  end loop;
  delete from public.service_tasks t
  where t.organization_id = p_org and t.app_ref is not null and not (t.app_ref = any (v_refs));
  return v_count;
end;
$$;


-- -----------------------------------------------------------------------------
-- Auftrag anbieten: Währung der Organisation übernehmen
-- -----------------------------------------------------------------------------
create or replace function public.offer_service_order(
  p_service_task_id uuid,
  p_service_partner_id uuid default null,
  p_estimated_cost numeric default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_task    public.service_tasks;
  v_partner uuid := p_service_partner_id;
  v_price   numeric;
  v_score   numeric;
  v_order   uuid;
  v_exclude uuid[];
begin
  select * into v_task from public.service_tasks t where t.id = p_service_task_id;
  if v_task.id is null then
    raise exception 'Aufgabe nicht gefunden' using errcode = 'P0002';
  end if;

  if v_partner is null then
    select array_agg(o.service_partner_id) into v_exclude
    from public.service_orders o where o.service_task_id = v_task.id and o.status = 'rejected';
    select m.service_partner_id, m.price_from, m.score into v_partner, v_price, v_score
    from public.match_service_partners(v_task.property_id, v_task.service_type_id, 1, v_exclude, v_task.scheduled_start) m;
    if v_partner is null then
      raise exception 'Kein passender Servicepartner gefunden' using errcode = 'P0002';
    end if;
  end if;

  insert into public.service_orders (organization_id, service_task_id, property_id, service_partner_id, title,
                                     description, status, scheduled_at, estimated_cost, match_score, currency)
  values (v_task.organization_id, v_task.id, v_task.property_id, v_partner,
          v_task.title, v_task.description, 'offered', v_task.scheduled_start,
          coalesce(p_estimated_cost, v_price), v_score,
          (select o.currency from public.organizations o where o.id = v_task.organization_id))
  returning id into v_order;
  return v_order;
end;
$$;

-- -----------------------------------------------------------------------------
-- Hausbesitzer-Cloud-Sync: nur Hausbesitzer-Organisationen verwenden
-- (ein reiner Servicepartner bekommt beim Sync eine eigene Hausbesitzer-Organisation)
-- -----------------------------------------------------------------------------
create or replace function public.ensure_my_organization(p_name text default 'Meine Ferienhäuser')
returns table (organization_id uuid, name text, role text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := private.current_user_id();
  v_org  uuid;
begin
  if v_user is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;
  select m.organization_id into v_org
  from public.organization_members m
  join public.organizations o on o.id = m.organization_id
  where m.user_id = v_user and m.status = 'active' and o.org_type in ('homeowner', 'both')
  order by (m.role = 'admin') desc, m.created_at
  limit 1;

  if v_org is null then
    insert into public.organizations (name, country, currency, timezone, org_type)
    values (coalesce(nullif(trim(p_name), ''), 'Meine Ferienhäuser'), 'SE', 'EUR', 'Europe/Stockholm', 'homeowner')
    returning id into v_org;
  end if;

  return query
    select o.id, o.name, m.role
    from public.organizations o
    join public.organization_members m on m.organization_id = o.id and m.user_id = v_user
    where o.id = v_org;
end;
$$;

-- -----------------------------------------------------------------------------
-- Rechte
-- -----------------------------------------------------------------------------
revoke all on function public.create_partner_organization(jsonb) from public, anon;
revoke all on function public.partner_context() from public, anon;
revoke all on function public.create_service_partner_invite(uuid, text) from public, anon;
revoke all on function public.accept_service_partner_invite(text) from public, anon;
revoke all on function public.create_member_invite(uuid, text, text) from public, anon;
revoke all on function public.accept_member_invite(text) from public, anon;
revoke all on function public.partner_start_inspection(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.create_partner_organization(jsonb), public.partner_context(),
  public.create_service_partner_invite(uuid, text), public.accept_service_partner_invite(text),
  public.create_member_invite(uuid, text, text), public.accept_member_invite(text),
  public.partner_start_inspection(uuid, uuid, timestamptz) to authenticated, service_role;
revoke all on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated, service_role;

-- >>> 20261030001800_partner_messenger.sql
-- =============================================================================
-- HUSORA · Migration 1800 · Messenger zwischen Hausbesitzer und Servicepartner
-- =============================================================================
-- Neben Nachrichten zu einzelnen Aufträgen gibt es je Servicepartner einen
-- durchgehenden Gesprächsverlauf (messages.service_partner_id). Sichtbar nur für
-- die Verwaltung des Hausbesitzers und die Leitung des Partnerbetriebs.
-- Lesebestätigung: die jeweils andere Seite setzt read_at.

alter table public.messages add column service_partner_id uuid;
alter table public.messages add constraint messages_service_partner_fkey
  foreign key (organization_id, service_partner_id) references public.service_partners (organization_id, id) on delete cascade;
comment on column public.messages.service_partner_id is 'Gespräch mit einem Servicepartner (unabhängig von einzelnen Aufträgen).';
create index messages_partner_thread_idx on public.messages (service_partner_id, created_at) where service_partner_id is not null;
create index messages_unread_thread_idx on public.messages (organization_id, service_partner_id) where read_at is null;

alter table public.messages drop constraint messages_check;
alter table public.messages add constraint messages_check
  check (recipient_user_id is not null or service_order_id is not null or service_partner_id is not null);

-- Gesprächsverlauf mit einem Partner sehen/führen: Hausbesitzer-Verwaltung oder Partnerleitung
create or replace function private.can_access_partner_thread(p_organization_id uuid, p_service_partner_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_service_partner_id is not null
     and (private.can_read_org(p_organization_id) or private.is_partner_member(p_service_partner_id))
$$;

drop policy messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (
    sender_user_id = (select private.current_user_id())
    or recipient_user_id = (select private.current_user_id())
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
    or private.can_access_partner_thread(organization_id, service_partner_id)
  );

drop policy messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (
    (service_order_id is null or private.can_read_service_order(service_order_id))
    and (recipient_user_id is null or private.is_user_in_org(recipient_user_id, organization_id))
    and (
      (service_partner_id is not null and private.can_access_partner_thread(organization_id, service_partner_id))
      or (service_partner_id is null and (private.is_org_member(organization_id)
                                          or (service_order_id is not null and private.can_work_order(service_order_id))))
    )
  );

-- Gelesen markieren: Empfänger oder die andere Seite eines Gesprächs (Spaltenschutz: nur read_at)
create policy messages_mark_read on public.messages for update to authenticated
  using (
    sender_user_id is distinct from (select private.current_user_id())
    and (private.can_access_partner_thread(organization_id, service_partner_id)
         or (service_order_id is not null and private.can_read_service_order(service_order_id)))
  )
  with check (
    private.can_access_partner_thread(organization_id, service_partner_id)
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
  );

-- Benachrichtigung für die Verwaltung, wenn ein Partner schreibt
create or replace function private.notify_partner_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_partner text;
begin
  if new.service_partner_id is null or private.is_org_member(new.organization_id) then
    return new;  -- nur Nachrichten der Partnerseite melden
  end if;
  select sp.company_name into v_partner from public.service_partners sp where sp.id = new.service_partner_id;
  insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
  select new.organization_id, m.user_id, 'message', 'Neue Nachricht von ' || coalesce(v_partner, 'Servicepartner'),
         left(new.message, 200), 'service_partner', new.service_partner_id
  from public.organization_members m
  where m.organization_id = new.organization_id and m.status = 'active'
    and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher');
  return new;
end;
$$;
create trigger messages_notify_partner after insert on public.messages
  for each row execute function private.notify_partner_message();

grant execute on function private.can_access_partner_thread(uuid, uuid), private.notify_partner_message() to authenticated, service_role;

-- >>> 20261030001900_partner_service_groups.sql
-- =============================================================================
-- HUSORA · Migration 1900 · Leistungsgruppen für Servicepartner
-- =============================================================================
-- Im Partner-Portal wählt ein Betrieb nur noch drei Leistungsgruppen:
-- Hauskontrolle (inspection, besteht bereits), Servicearbeiten und Sanierungen.
-- Preise je Arbeitspaket (price_unit = 'job') oder je Stunde ('hour').

insert into public.service_types (id, organization_id, code, name, description, category) values
  ('eeeeeeee-0000-4000-8000-000000000015', null, 'service_work', 'Servicearbeiten', 'Hausservice, Reinigung, Garten, Winterdienst, kleine Reparaturen', 'service'),
  ('eeeeeeee-0000-4000-8000-000000000016', null, 'renovation',   'Sanierungen',     'Sanierung und Renovierung: Dach, Fassade, Fenster, Bad, Technik',  'craft')
on conflict on constraint service_types_code_unique do nothing;

-- -----------------------------------------------------------------------------
-- Hausfotos für beauftragte Servicepartner
-- -----------------------------------------------------------------------------
-- Ein Partner sieht die allgemeinen Fotos eines Hauses (ohne Bezug zu Auftrag,
-- Kontrolle, Aufgabe oder Reparatur), solange er für genau dieses Haus einen
-- Auftrag hat (angefragt, angenommen, terminiert, in Arbeit oder erledigt).
-- Abgelehnte, stornierte und Entwurfsaufträge geben nichts frei.
create or replace function private.is_property_partner(p_property_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.service_orders o
    where o.property_id = p_property_id
      and o.status in ('offered', 'accepted', 'scheduled', 'in_progress', 'completed')
      and (private.is_partner_member(o.service_partner_id)
           or (o.assigned_user_id = private.current_user_id() and private.is_partner_employee(o.service_partner_id)))
  )
$$;
grant execute on function private.is_property_partner(uuid) to authenticated, service_role;

drop policy photos_select on public.photos;
create policy photos_select on public.photos for select to authenticated
  using (
    private.can_read_org(organization_id)
    or uploaded_by = (select private.current_user_id())
    or private.is_property_owner(property_id)
    or (inspection_id is not null and private.can_read_inspection(inspection_id))
    or (service_order_id is not null and private.can_read_service_order(service_order_id))
    or (service_task_id is not null and private.can_read_task(service_task_id))
    or (repair_id is not null and private.can_read_repair(repair_id))
    or (property_id is not null and inspection_id is null and service_order_id is null and service_task_id is null and repair_id is null
        and private.is_property_partner(property_id))
  );

-- >>> 20261030002000_partner_member_fast.sql
-- =============================================================================
-- HUSORA · Migration 2000 · Schnellere Partner-Prüfung in den RLS-Regeln
-- =============================================================================
-- private.is_partner_member wurde pro geprüfter Zeile über my_partner_ids()
-- ausgewertet, also über die komplette Liste aller Partner des Nutzers. Bei vielen
-- Zeilen (Aufträge, Fotos, Nachrichten) führte das zu Zeitüberschreitungen.
-- Gleiche Logik, aber als gezielte Prüfung genau eines Partners über die
-- vorhandenen Indizes (service_partners.id, organization_members(organization_id, user_id),
-- service_partner_users(service_partner_id, user_id)).

create or replace function private.is_partner_member(p_service_partner_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_service_partner_id is not null and (
    -- Leitung des Partnerbetriebs (eigene Partner-Organisation)
    exists (
      select 1
      from public.service_partners sp
      join public.organization_members m on m.organization_id = sp.partner_organization_id
      where sp.id = p_service_partner_id
        and m.user_id = (select private.current_user_id())
        and m.status = 'active'
        and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher', 'accounting')
    )
    -- direkt dem Partner zugeordneter Nutzer, der selbst Mitglied der beauftragenden Organisation ist
    or exists (
      select 1
      from public.service_partner_users spu
      join public.service_partners sp on sp.id = spu.service_partner_id
      where spu.service_partner_id = p_service_partner_id
        and spu.user_id = (select private.current_user_id())
        and private.org_role(sp.organization_id) is not null
    )
  )
$$;

