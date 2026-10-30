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
