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
