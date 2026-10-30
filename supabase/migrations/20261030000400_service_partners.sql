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
