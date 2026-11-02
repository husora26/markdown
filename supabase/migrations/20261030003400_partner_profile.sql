-- =============================================================================
-- HUSORA · Phase 4: Servicepartner-Profil, Preisart, Servicegebiete, Abwesenheiten
-- =============================================================================
-- Spezifikation §5–8. Erweitert bestehende Tabellen statt neue Profiltabellen anzulegen:
--   * organizations: Notdienst, automatische Annahme, Mindestauftragswert, Anfahrt, Stundensatz
--   * service_partner_services.price_type (hourly/fixed/quote/free), aus price_unit vorbelegt
--   * service_partner_areas: Name, Land, PLZ-Bereich, Koordinaten, aktiv
--   * neue Tabelle service_partner_absences (Betrieb oder einzelner Mitarbeiter)
--   * automatische Annahme neuer Anfragen, wenn der Betrieb sie eingeschaltet hat
-- Idempotent.

-- -----------------------------------------------------------------------------
-- 1) Profilfelder am Betrieb
-- -----------------------------------------------------------------------------
alter table public.organizations
  add column if not exists emergency_service   boolean not null default false,
  add column if not exists auto_accept_orders  boolean not null default false,
  add column if not exists minimum_order_value numeric(12, 2),
  add column if not exists travel_fee          numeric(12, 2),
  add column if not exists hourly_rate         numeric(12, 2);
comment on column public.organizations.emergency_service is 'Servicepartner bietet einen Notdienst an';
comment on column public.organizations.auto_accept_orders is 'Neue Anfragen von Kunden werden automatisch angenommen';
comment on column public.organizations.minimum_order_value is 'Mindestauftragswert (Organisationswährung); darunter keine automatische Annahme';
comment on column public.organizations.travel_fee is 'Anfahrtspauschale je Einsatz';
comment on column public.organizations.hourly_rate is 'Standard-Stundensatz';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'organizations_partner_prices_check') then
    alter table public.organizations add constraint organizations_partner_prices_check check (
      (minimum_order_value is null or minimum_order_value >= 0)
      and (travel_fee is null or travel_fee >= 0)
      and (hourly_rate is null or hourly_rate >= 0));
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 2) Preisart je Leistung
-- -----------------------------------------------------------------------------
alter table public.service_partner_services add column if not exists price_type text;
update public.service_partner_services
set price_type = case when price_from is null then 'quote' when price_unit = 'hour' then 'hourly' else 'fixed' end
where price_type is null;
alter table public.service_partner_services alter column price_type set default 'fixed';
alter table public.service_partner_services alter column price_type set not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'service_partner_services_price_type_check') then
    alter table public.service_partner_services add constraint service_partner_services_price_type_check
      check (price_type in ('hourly', 'fixed', 'quote', 'free'));
  end if;
end $$;
comment on column public.service_partner_services.price_type is 'hourly = Stundensatz, fixed = Festpreis je Einheit, quote = auf Anfrage, free = kostenlos';

-- -----------------------------------------------------------------------------
-- 3) Servicegebiete erweitern
-- -----------------------------------------------------------------------------
alter table public.service_partner_areas
  add column if not exists name               text,
  add column if not exists country            text,
  add column if not exists postal_code_prefix text,
  add column if not exists latitude           numeric(9, 6),
  add column if not exists longitude          numeric(9, 6),
  add column if not exists active             boolean not null default true;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'service_partner_areas_extra_check') then
    alter table public.service_partner_areas add constraint service_partner_areas_extra_check check (
      (name is null or length(name) <= 120)
      and (country is null or country ~ '^[A-Z]{2}$')
      and (postal_code_prefix is null or postal_code_prefix ~ '^[0-9A-Za-z ]{1,10}$')
      and (latitude is null or latitude between -90 and 90)
      and (longitude is null or longitude between -180 and 180));
  end if;
end $$;
-- Gebiet nur mit PLZ-Bereich ist jetzt ebenfalls gültig
alter table public.service_partner_areas drop constraint if exists service_partner_areas_check;
alter table public.service_partner_areas add constraint service_partner_areas_check
  check (postal_code is not null or city is not null or region is not null or radius_km is not null or postal_code_prefix is not null);
create index if not exists service_partner_areas_prefix_idx on public.service_partner_areas (postal_code_prefix) where postal_code_prefix is not null and active;

-- -----------------------------------------------------------------------------
-- 4) Abwesenheiten (Betrieb oder einzelner Mitarbeiter)
-- -----------------------------------------------------------------------------
create table if not exists public.service_partner_absences (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  user_id          uuid references public.users(id) on delete cascade,
  start_at         timestamptz not null,
  end_at           timestamptz not null,
  reason           text check (reason is null or length(reason) <= 300),
  created_by       uuid references public.users(id) on delete set null,
  updated_by       uuid references public.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (end_at > start_at),
  check (end_at <= start_at + interval '366 days')
);
comment on table public.service_partner_absences is 'Abwesenheiten eines Servicebetriebs (user_id null = ganzer Betrieb) oder einzelner Mitarbeiter';
create index if not exists spa_abs_org_idx on public.service_partner_absences (organization_id, start_at);
create index if not exists spa_abs_user_idx on public.service_partner_absences (user_id) where user_id is not null;
create index if not exists spa_abs_created_by_idx on public.service_partner_absences (created_by) where created_by is not null;
create index if not exists spa_abs_updated_by_idx on public.service_partner_absences (updated_by) where updated_by is not null;

-- Mitarbeiter muss zum Betrieb gehören
create or replace function private.absence_check()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    new.organization_id := old.organization_id;
  end if;
  if new.user_id is not null and not exists (
    select 1 from public.organization_members m
    where m.organization_id = new.organization_id and m.user_id = new.user_id and m.status = 'active') then
    raise exception 'Die Person gehört nicht zu diesem Betrieb' using errcode = '23503';
  end if;
  return new;
end;
$$;
drop trigger if exists absence_check on public.service_partner_absences;
create trigger absence_check before insert or update on public.service_partner_absences
  for each row execute function private.absence_check();
drop trigger if exists absences_set_updated_at on public.service_partner_absences;
create trigger absences_set_updated_at before update on public.service_partner_absences
  for each row execute function private.set_updated_at();
drop trigger if exists absences_set_actor on public.service_partner_absences;
create trigger absences_set_actor before insert or update on public.service_partner_absences
  for each row execute function private.set_actor_columns();
drop trigger if exists service_partner_absences_audit on public.service_partner_absences;
create trigger service_partner_absences_audit after insert or update or delete on public.service_partner_absences
  for each row execute function private.audit_row_change();

alter table public.service_partner_absences enable row level security;
-- Lesen: alle Mitglieder des Betriebs (Einsatzplanung)
drop policy if exists absences_select on public.service_partner_absences;
create policy absences_select on public.service_partner_absences for select to authenticated
  using (private.is_org_member(organization_id));
-- Schreiben: Leitung/Disposition für alle; Mitarbeiter nur die eigene Abwesenheit
drop policy if exists absences_insert on public.service_partner_absences;
create policy absences_insert on public.service_partner_absences for insert to authenticated
  with check (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher'])
              or (user_id = (select private.current_user_id()) and private.is_org_member(organization_id)));
drop policy if exists absences_update on public.service_partner_absences;
create policy absences_update on public.service_partner_absences for update to authenticated
  using (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher'])
         or (user_id = (select private.current_user_id()) and private.is_org_member(organization_id)))
  with check (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher'])
              or (user_id = (select private.current_user_id()) and private.is_org_member(organization_id)));
drop policy if exists absences_delete on public.service_partner_absences;
create policy absences_delete on public.service_partner_absences for delete to authenticated
  using (private.has_org_role(organization_id, array['admin', 'service_manager', 'dispatcher'])
         or (user_id = (select private.current_user_id()) and private.is_org_member(organization_id)));
revoke all on public.service_partner_absences from anon;
grant select, insert, update, delete on public.service_partner_absences to authenticated;

-- -----------------------------------------------------------------------------
-- 5) Automatische Annahme neuer Anfragen
-- -----------------------------------------------------------------------------
-- Bedingungen: Betrieb hat sie eingeschaltet, Mindestauftragswert erreicht (oder kein Preis
-- bekannt bzw. kein Minimum gesetzt) und der Betrieb ist am Termin nicht als Ganzes abwesend.
create or replace function private.auto_accept_order()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_org public.organizations;
  v_at  timestamptz;
begin
  if new.status <> 'offered' then return null; end if;
  select o.* into v_org
  from public.service_partners sp join public.organizations o on o.id = sp.partner_organization_id
  where sp.id = new.service_partner_id and sp.partner_organization_id <> new.organization_id;
  if v_org.id is null or not v_org.auto_accept_orders then return null; end if;
  if v_org.minimum_order_value is not null and new.estimated_cost is not null and new.estimated_cost < v_org.minimum_order_value then
    return null;
  end if;
  v_at := coalesce(new.scheduled_at, now());
  if exists (select 1 from public.service_partner_absences a
             where a.organization_id = v_org.id and a.user_id is null and v_at >= a.start_at and v_at < a.end_at) then
    return null;
  end if;
  update public.service_orders o
  set status = 'accepted', response_note = coalesce(o.response_note, 'Automatisch angenommen')
  where o.id = new.id and o.status = 'offered';
  return null;
end;
$$;
drop trigger if exists service_orders_zz_auto_accept on public.service_orders;
-- Name mit „zz“: läuft nach Protokoll- und Benachrichtigungs-Triggern des Inserts
create trigger service_orders_zz_auto_accept after insert on public.service_orders
  for each row execute function private.auto_accept_order();
