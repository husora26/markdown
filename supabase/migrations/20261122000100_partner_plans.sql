-- =============================================================================
-- HUSORA · Migration 20261122000100 · Tarife für Servicepartner (Free/Plus/Pro/Ultra)
-- =============================================================================
-- Umsetzung der „Husora Service Partner App – Tarif- und Berechtigungsspezifikation“ v1.0.
--
-- Verbindlich: KEINE Vermittlungsprovision. Husora verdient bei Servicepartnern nur
-- über Abos und optionale Zusatzmodule. Es gibt in diesem Schema keine Spalte und
-- keine Funktion, die einen Prozentsatz auf Aufträge berechnet.
--
-- Aufbau (bewusst getrennt von den Hausbesitzer-Tarifen in public.plans/subscriptions):
--   partner_plans          Tarife mit Preis, Limits (jsonb) und Funktionen (jsonb-Array)
--   partner_addon_catalog  buchbare Zusatzmodule mit Preis und Wirkung
--   partner_subscriptions  Abo je Servicebetrieb (Tenant = Organisation)
--   partner_addons         gebuchte Zusatzmodule je Servicebetrieb
--   partner_entitlements   individuelle, zeitlich begrenzte Freischaltungen durch Husora-Admins
--   partner_subscription_events  Protokoll aller Abo-Änderungen (datensparsam)
-- Warum getrennte Tabellen: installierte Hausbesitzer-Apps lesen public.plans komplett
-- und würden Partner-Tarife sonst auf ihrer Tarifseite anzeigen. Eine Organisation mit
-- beiden Rollen (org_type 'both') hat so zwei voneinander unabhängige Abos.
--
-- Prioritätsregel für die effektiven Rechte (private.partner_entitlements):
--   1. aktive individuelle Freischaltung (partner_entitlements) – gewinnt immer
--   2. Tarif + gebuchte Zusatzmodule (Zusatzmodule erhöhen Limits / schalten Funktionen zu)
-- Limits: Schlüssel fehlt oder Wert null = unbegrenzt (nur für die unten definierten
-- Limit-Schlüssel). Nutzung wird bei jeder Prüfung live ermittelt – Änderungen im
-- Adminbereich wirken damit sofort (kein Cache in der Datenbank; die App lädt den
-- Stand beim Öffnen des Partner-Portals und nach jeder Anlage neu).
--
-- Auftragslimit: gezählt werden nur Aufträge, die der Servicebetrieb selbst anlegt
-- (nicht die, die Hausbesitzer ihm schicken), je Kalendermonat (Europe/Stockholm).
-- Der Zähler steigt beim Anlegen und sinkt beim Löschen nicht (kein Umgehen durch Löschen).
--
-- Downgrade/Kündigung löschen nie Daten: vorhandene Kunden, Objekte, Aufträge,
-- Benutzer und Dateien bleiben erhalten und lesbar, nur neue Einträge über dem Limit
-- werden abgelehnt. Bestehende Mitarbeiter über dem Benutzerlimit bleiben aktiv
-- (Übergangsregel), es können aber keine weiteren eingeladen werden.
-- Idempotent.

-- -----------------------------------------------------------------------------
-- 1) Tarife
-- -----------------------------------------------------------------------------
create table if not exists public.partner_plans (
  id                  text primary key check (id ~ '^[a-z][a-z0-9_]*$'),
  code                text not null unique check (code in ('free', 'plus', 'pro', 'ultra') or code ~ '^[a-z][a-z0-9_]*$'),
  name                text not null,
  tagline             text,
  price_monthly_cents integer not null default 0 check (price_monthly_cents >= 0),
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  billing_interval    text not null default 'monthly' check (billing_interval in ('monthly', 'yearly')),
  is_active           boolean not null default true,
  highlight           boolean not null default false,
  sort_order          integer not null default 0,
  limits              jsonb not null default '{}'::jsonb check (jsonb_typeof(limits) = 'object'),
  features            jsonb not null default '[]'::jsonb check (jsonb_typeof(features) = 'array'),
  highlights          jsonb not null default '[]'::jsonb check (jsonb_typeof(highlights) = 'array'),
  stripe_price_id     text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
comment on table public.partner_plans is 'Tarife für Servicebetriebe. limits: customers, properties, orders_month, users, storage_bytes, locations (null = unbegrenzt). Keine Provision.';

-- -----------------------------------------------------------------------------
-- 2) Zusatzmodule (Katalog)
-- -----------------------------------------------------------------------------
create table if not exists public.partner_addon_catalog (
  code                text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  name                text not null,
  description         text,
  price_monthly_cents integer not null check (price_monthly_cents >= 0),
  price_is_from       boolean not null default false,
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  -- Wirkung: {"limits": {"users": 1}} erhöht je Menge, {"features": ["ai_assistant"]} schaltet zu
  effect              jsonb not null default '{}'::jsonb check (jsonb_typeof(effect) = 'object'),
  usage_based_note    text,
  is_active           boolean not null default true,
  sort_order          integer not null default 0,
  stripe_price_id     text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
comment on table public.partner_addon_catalog is 'Optionale Zusatzmodule für Servicebetriebe. Werden nur nach ausdrücklicher Aktivierung mit bestätigtem Preis berechnet.';

-- -----------------------------------------------------------------------------
-- 3) Abo, Zusatzmodule, Freischaltungen, Ereignisse je Servicebetrieb
-- -----------------------------------------------------------------------------
create table if not exists public.partner_subscriptions (
  id                        uuid primary key default gen_random_uuid(),
  organization_id           uuid not null unique references public.organizations(id) on delete cascade,
  plan_id                   text not null references public.partner_plans(id),
  status                    text not null default 'active' check (status in ('trialing', 'active', 'past_due', 'canceled', 'incomplete')),
  billing_provider          text not null default 'manual' check (billing_provider in ('stripe', 'manual')),
  provider_customer_id      text,
  provider_subscription_id  text unique,
  current_period_start      timestamptz,
  current_period_end        timestamptz,
  cancel_at_period_end      boolean not null default false,
  note                      text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);
comment on table public.partner_subscriptions is 'Abo eines Servicebetriebs. Ohne Eintrag oder ohne gültigen Status gilt Free. Schreiben nur Husora-Admins und der Zahlungs-Webhook.';
create index if not exists partner_subscriptions_plan_idx on public.partner_subscriptions (plan_id);

create table if not exists public.partner_addons (
  id                            uuid primary key default gen_random_uuid(),
  organization_id               uuid not null references public.organizations(id) on delete cascade,
  addon_code                    text not null references public.partner_addon_catalog(code),
  status                        text not null default 'requested' check (status in ('requested', 'active', 'canceled')),
  quantity                      integer not null default 1 check (quantity between 1 and 1000),
  price_monthly_cents_confirmed integer not null check (price_monthly_cents_confirmed >= 0),
  confirmed_at                  timestamptz not null default now(),
  confirmed_by                  uuid references public.users(id) on delete set null,
  provider_subscription_item_id text,
  created_at                    timestamptz not null default now(),
  updated_at                    timestamptz not null default now()
);
comment on table public.partner_addons is 'Gebuchte Zusatzmodule. requested = vom Betrieb mit Preis bestätigt, wird erst nach Freigabe/Zahlung active.';
create unique index if not exists partner_addons_open_idx on public.partner_addons (organization_id, addon_code) where status <> 'canceled';
create index if not exists partner_addons_code_idx on public.partner_addons (addon_code);
create index if not exists partner_addons_confirmed_by_idx on public.partner_addons (confirmed_by) where confirmed_by is not null;

create table if not exists public.partner_entitlements (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  feature_key     text not null check (feature_key ~ '^[a-z][a-z0-9_]*$'),
  enabled         boolean not null default true,
  limit_override  bigint check (limit_override >= 0),
  unlimited       boolean not null default false,
  valid_from      timestamptz not null default now(),
  valid_until     timestamptz,
  reason          text not null check (length(trim(reason)) > 0),
  created_by      uuid references public.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (valid_until is null or valid_until > valid_from)
);
comment on table public.partner_entitlements is 'Individuelle Freischaltung durch Husora-Admins. Gewinnt gegenüber Tarif und Zusatzmodulen. Für Limits: limit_override oder unlimited.';
create index if not exists partner_entitlements_org_idx on public.partner_entitlements (organization_id, feature_key);
create index if not exists partner_entitlements_created_by_idx on public.partner_entitlements (created_by) where created_by is not null;

create table if not exists public.partner_subscription_events (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references public.organizations(id) on delete cascade,
  subscription_id    uuid references public.partner_subscriptions(id) on delete set null,
  event_type         text not null,
  provider_event_id  text unique,
  payload            jsonb not null default '{}'::jsonb,
  processed_at       timestamptz,
  created_at         timestamptz not null default now()
);
comment on table public.partner_subscription_events is 'Protokoll der Abo-Änderungen (Tarif, Status, Zusatzmodule). Keine Zahlungsdaten.';
create index if not exists partner_subscription_events_org_idx on public.partner_subscription_events (organization_id, created_at desc);
create index if not exists partner_subscription_events_sub_idx on public.partner_subscription_events (subscription_id) where subscription_id is not null;

-- Monatszähler für selbst angelegte Aufträge in der vorhandenen Tabelle usage_counters
alter table public.usage_counters drop constraint if exists usage_counters_metric_check;
alter table public.usage_counters add constraint usage_counters_metric_check
  check (metric in ('listing_imports_month', 'invoice_analyses_month', 'partner_orders_month'));

do $$
declare t text;
begin
  foreach t in array array['partner_plans', 'partner_addon_catalog', 'partner_subscriptions', 'partner_addons', 'partner_entitlements'] loop
    if not exists (select 1 from pg_trigger where tgname = t || '_updated_at') then
      execute format('create trigger %I before update on public.%I for each row execute function private.set_updated_at()', t || '_updated_at', t);
    end if;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 4) Zugriff (RLS)
-- -----------------------------------------------------------------------------
alter table public.partner_plans enable row level security;
alter table public.partner_addon_catalog enable row level security;
alter table public.partner_subscriptions enable row level security;
alter table public.partner_addons enable row level security;
alter table public.partner_entitlements enable row level security;
alter table public.partner_subscription_events enable row level security;

drop policy if exists partner_plans_select on public.partner_plans;
create policy partner_plans_select on public.partner_plans for select to anon, authenticated
  using (is_active or private.has_admin_role('super_admin'));
drop policy if exists partner_plans_admin on public.partner_plans;
create policy partner_plans_admin on public.partner_plans for all to authenticated
  using (private.has_admin_role('super_admin')) with check (private.has_admin_role('super_admin'));

drop policy if exists partner_addon_catalog_select on public.partner_addon_catalog;
create policy partner_addon_catalog_select on public.partner_addon_catalog for select to anon, authenticated
  using (is_active or private.has_admin_role('super_admin'));
drop policy if exists partner_addon_catalog_admin on public.partner_addon_catalog;
create policy partner_addon_catalog_admin on public.partner_addon_catalog for all to authenticated
  using (private.has_admin_role('super_admin')) with check (private.has_admin_role('super_admin'));

-- Betriebe lesen nur ihr eigenes Abo/ihre Module/Freischaltungen/Ereignisse; ändern nur Admins
drop policy if exists partner_subscriptions_select on public.partner_subscriptions;
create policy partner_subscriptions_select on public.partner_subscriptions for select to authenticated
  using (private.can_read_org(organization_id) or private.has_admin_role('support_admin'));
drop policy if exists partner_subscriptions_admin on public.partner_subscriptions;
create policy partner_subscriptions_admin on public.partner_subscriptions for all to authenticated
  using (private.has_admin_role('super_admin')) with check (private.has_admin_role('super_admin'));

drop policy if exists partner_addons_select on public.partner_addons;
create policy partner_addons_select on public.partner_addons for select to authenticated
  using (private.can_read_org(organization_id) or private.has_admin_role('support_admin'));
drop policy if exists partner_addons_admin on public.partner_addons;
create policy partner_addons_admin on public.partner_addons for all to authenticated
  using (private.has_admin_role('super_admin')) with check (private.has_admin_role('super_admin'));

drop policy if exists partner_entitlements_select on public.partner_entitlements;
create policy partner_entitlements_select on public.partner_entitlements for select to authenticated
  using (private.can_read_org(organization_id) or private.has_admin_role('support_admin'));
drop policy if exists partner_entitlements_admin on public.partner_entitlements;
create policy partner_entitlements_admin on public.partner_entitlements for all to authenticated
  using (private.has_admin_role('super_admin')) with check (private.has_admin_role('super_admin'));

drop policy if exists partner_subscription_events_select on public.partner_subscription_events;
create policy partner_subscription_events_select on public.partner_subscription_events for select to authenticated
  using (private.is_org_admin(organization_id) or private.has_admin_role('support_admin'));

grant select on public.partner_plans, public.partner_addon_catalog to anon, authenticated;
grant select on public.partner_subscriptions, public.partner_addons, public.partner_entitlements, public.partner_subscription_events to authenticated;
grant insert, update, delete on public.partner_plans, public.partner_addon_catalog, public.partner_subscriptions, public.partner_addons, public.partner_entitlements to authenticated;
grant all on public.partner_plans, public.partner_addon_catalog, public.partner_subscriptions, public.partner_addons, public.partner_entitlements, public.partner_subscription_events to service_role;

-- -----------------------------------------------------------------------------
-- 5) Protokoll: jede Abo-/Modul-Änderung landet in partner_subscription_events
-- -----------------------------------------------------------------------------
create or replace function private.log_partner_subscription_change()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_table_name = 'partner_subscriptions' then
    if tg_op = 'INSERT' or new.plan_id is distinct from old.plan_id or new.status is distinct from old.status
       or new.cancel_at_period_end is distinct from old.cancel_at_period_end or new.current_period_end is distinct from old.current_period_end then
      insert into public.partner_subscription_events (organization_id, subscription_id, event_type, payload, processed_at)
      values (new.organization_id, new.id, case when tg_op = 'INSERT' then 'subscription.created' else 'subscription.updated' end,
        jsonb_strip_nulls(jsonb_build_object('plan_id', new.plan_id, 'previous_plan_id', case when tg_op = 'UPDATE' then old.plan_id end,
          'status', new.status, 'previous_status', case when tg_op = 'UPDATE' then old.status end,
          'cancel_at_period_end', new.cancel_at_period_end, 'current_period_end', new.current_period_end,
          'provider', new.billing_provider, 'actor', private.current_user_id())), now());
    end if;
  else
    if tg_op = 'INSERT' or new.status is distinct from old.status or new.quantity is distinct from old.quantity then
      insert into public.partner_subscription_events (organization_id, event_type, payload, processed_at)
      values (new.organization_id, 'addon.' || new.status,
        jsonb_strip_nulls(jsonb_build_object('addon_code', new.addon_code, 'quantity', new.quantity,
          'price_monthly_cents', new.price_monthly_cents_confirmed, 'actor', private.current_user_id())), now());
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists partner_subscriptions_log on public.partner_subscriptions;
create trigger partner_subscriptions_log after insert or update on public.partner_subscriptions
  for each row execute function private.log_partner_subscription_change();
drop trigger if exists partner_addons_log on public.partner_addons;
create trigger partner_addons_log after insert or update on public.partner_addons
  for each row execute function private.log_partner_subscription_change();

-- -----------------------------------------------------------------------------
-- 6) Hilfsfunktionen
-- -----------------------------------------------------------------------------
create or replace function private.is_partner_org(p_organization_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.organizations o where o.id = p_organization_id and o.org_type in ('service_partner', 'both')) $$;

-- Eigener Partner-Datensatz eines Betriebs (für „selbst angelegte Aufträge“)
create or replace function private.self_partner_id(p_organization_id uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$ select sp.id from public.service_partners sp where sp.organization_id = p_organization_id and sp.partner_organization_id = p_organization_id limit 1 $$;

-- Aktueller Tarif eines Betriebs. Bezahlte Rechte gelten bis Periodenende, auch nach Kündigung;
-- incomplete (Zahlung nicht bestätigt) schaltet nichts frei; past_due mit 3 Tagen Kulanz.
create or replace function private.partner_plan_id(p_organization_id uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select s.plan_id from public.partner_subscriptions s
    join public.partner_plans p on p.id = s.plan_id
    where s.organization_id = p_organization_id
      and (
        (s.status in ('trialing', 'active') and (s.current_period_end is null or s.current_period_end > now()))
        or (s.status = 'past_due' and (s.current_period_end is null or s.current_period_end > now() - interval '3 days'))
        or (s.status = 'canceled' and s.current_period_end is not null and s.current_period_end > now())
      )
  ), 'partner_free')
$$;

create or replace function private.partner_month_start()
returns date
language sql stable set search_path = ''
as $$ select date_trunc('month', now() at time zone 'Europe/Stockholm')::date $$;

-- Aktuelle Nutzung je Limit-Schlüssel
create or replace function private.partner_usage(p_organization_id uuid, p_key text)
returns bigint
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_type text := (select o.org_type from public.organizations o where o.id = p_organization_id);
begin
  case p_key
    when 'customers' then
      return (select count(*) from public.customers c where c.organization_id = p_organization_id);
    when 'properties' then
      -- reiner Servicebetrieb: alle Objekte; Betrieb mit beiden Rollen: nur Objekte seiner Kunden
      return (select count(*) from public.properties p where p.organization_id = p_organization_id
              and (v_type = 'service_partner' or p.owner_customer_id is not null));
    when 'orders_month' then
      return coalesce((select u.count from public.usage_counters u where u.organization_id = p_organization_id
                       and u.metric = 'partner_orders_month' and u.period = private.partner_month_start()), 0);
    when 'users' then
      return (select count(*) from public.organization_members m where m.organization_id = p_organization_id and m.status = 'active');
    when 'storage_bytes' then
      return coalesce((select sum(d.file_size) from public.documents d where d.organization_id = p_organization_id), 0);
    when 'locations' then
      return 1;
    else
      return 0;
  end case;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7) Zentrale Auflösung der Rechte: getTenantEntitlements(tenantId)
-- -----------------------------------------------------------------------------
create or replace function private.partner_entitlements(p_organization_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_plan      public.partner_plans;
  v_sub       public.partner_subscriptions;
  v_limits    jsonb;
  v_features  jsonb;
  v_addons    jsonb := '[]'::jsonb;
  v_overrides jsonb := '[]'::jsonb;
  v_usage     jsonb := '{}'::jsonb;
  v_remaining jsonb := '{}'::jsonb;
  r           record;
  k           text;
  v_limit     bigint;
  v_used      bigint;
begin
  select * into v_plan from public.partner_plans where id = private.partner_plan_id(p_organization_id);
  if v_plan.id is null then
    select * into v_plan from public.partner_plans where code = 'free';
  end if;
  select * into v_sub from public.partner_subscriptions where organization_id = p_organization_id;
  v_limits := coalesce(v_plan.limits, '{}'::jsonb);
  v_features := coalesce(v_plan.features, '[]'::jsonb);

  -- Zusatzmodule: nur aktive, erhöhen Limits je Menge oder schalten Funktionen zu
  for r in
    select a.addon_code, a.quantity, a.status, c.name, c.effect
    from public.partner_addons a join public.partner_addon_catalog c on c.code = a.addon_code
    where a.organization_id = p_organization_id and a.status <> 'canceled'
  loop
    v_addons := v_addons || jsonb_build_array(jsonb_build_object('code', r.addon_code, 'name', r.name, 'quantity', r.quantity, 'status', r.status));
    continue when r.status <> 'active';
    for k in select jsonb_object_keys(coalesce(r.effect -> 'limits', '{}'::jsonb)) loop
      if v_limits ? k and jsonb_typeof(v_limits -> k) = 'number' then
        v_limits := jsonb_set(v_limits, array[k], to_jsonb((v_limits ->> k)::bigint + (r.effect -> 'limits' ->> k)::bigint * r.quantity));
      end if;
    end loop;
    v_features := v_features || coalesce(r.effect -> 'features', '[]'::jsonb);
  end loop;

  -- Individuelle Freischaltungen (gewinnen immer; die zuletzt angelegte zählt)
  for r in
    select distinct on (e.feature_key) e.feature_key, e.enabled, e.limit_override, e.unlimited, e.valid_until, e.reason
    from public.partner_entitlements e
    where e.organization_id = p_organization_id and e.valid_from <= now() and (e.valid_until is null or e.valid_until > now())
    order by e.feature_key, e.created_at desc
  loop
    v_overrides := v_overrides || jsonb_build_array(jsonb_build_object('key', r.feature_key, 'enabled', r.enabled, 'valid_until', r.valid_until));
    if r.feature_key in ('customers', 'properties', 'orders_month', 'users', 'storage_bytes', 'locations') then
      if r.unlimited then v_limits := jsonb_set(v_limits, array[r.feature_key], 'null'::jsonb);
      elsif r.limit_override is not null then v_limits := jsonb_set(v_limits, array[r.feature_key], to_jsonb(r.limit_override));
      end if;
    elsif r.enabled then
      v_features := v_features || to_jsonb(r.feature_key);
    else
      v_features := coalesce((select jsonb_agg(f) from jsonb_array_elements(v_features) f where f #>> '{}' <> r.feature_key), '[]'::jsonb);
    end if;
  end loop;
  v_features := coalesce((select jsonb_agg(distinct f) from jsonb_array_elements(v_features) f), '[]'::jsonb);

  foreach k in array array['customers', 'properties', 'orders_month', 'users', 'storage_bytes', 'locations'] loop
    v_used := private.partner_usage(p_organization_id, k);
    v_limit := nullif(v_limits ->> k, '')::bigint;
    v_usage := v_usage || jsonb_build_object(k, v_used);
    v_remaining := v_remaining || jsonb_build_object(k, case when v_limit is null then null else greatest(v_limit - v_used, 0) end);
    if not v_limits ? k then v_limits := v_limits || jsonb_build_object(k, null); end if;
  end loop;

  return jsonb_build_object(
    'organization_id', p_organization_id,
    'enforced', private.partner_plans_enforced(),
    'plan_id', v_plan.id,
    'plan_code', v_plan.code,
    'plan_name', v_plan.name,
    'price_monthly_cents', v_plan.price_monthly_cents,
    'currency', v_plan.currency,
    'status', coalesce(v_sub.status, 'none'),
    'subscribed_plan_id', v_sub.plan_id,
    'billing_provider', v_sub.billing_provider,
    'current_period_start', v_sub.current_period_start,
    'current_period_end', v_sub.current_period_end,
    'cancel_at_period_end', coalesce(v_sub.cancel_at_period_end, false),
    'features', v_features,
    'limits', v_limits,
    'usage', v_usage,
    'remaining', v_remaining,
    'addons', v_addons,
    'overrides', v_overrides,
    'order_period_start', private.partner_month_start(),
    'order_period_end', (private.partner_month_start() + interval '1 month')::date
  );
end;
$$;

-- Für die App: Rechte des eigenen Betriebs (Tenant aus der Anmeldung, nicht vom Browser)
create or replace function public.partner_entitlements(p_organization_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_org uuid := p_organization_id;
begin
  if v_org is null then
    select m.organization_id into v_org from public.organization_members m join public.organizations o on o.id = m.organization_id
    where m.user_id = private.current_user_id() and m.status = 'active' and o.org_type in ('service_partner', 'both')
    order by (m.role = 'admin') desc, m.created_at limit 1;
  end if;
  if v_org is null or not private.is_partner_org(v_org) then
    raise exception 'Kein Servicebetrieb gefunden' using errcode = 'P0002';
  end if;
  if not (private.is_org_member(v_org) or private.has_admin_role('support_admin')) then
    raise exception 'Keine Berechtigung für diesen Servicebetrieb' using errcode = '42501';
  end if;
  return private.partner_entitlements(v_org);
end;
$$;
revoke all on function public.partner_entitlements(uuid) from public, anon;
grant execute on function public.partner_entitlements(uuid) to authenticated;

-- Hat der Betrieb eine Funktion?
create or replace function private.partner_has_feature(p_organization_id uuid, p_feature text)
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(private.partner_entitlements(p_organization_id) -> 'features' ? p_feature, false) $$;

-- -----------------------------------------------------------------------------
-- 8) Zentrale Limitprüfung: checkTenantLimit(tenantId, resourceKey, requestedAmount)
-- -----------------------------------------------------------------------------
create or replace function private.partner_limit_label(p_key text, p_n bigint)
returns text
language sql immutable set search_path = ''
as $$
  select case p_key
    when 'customers' then case when p_n = 1 then 'Kunde' else 'Kunden' end
    when 'properties' then case when p_n = 1 then 'Objekt' else 'Objekte' end
    when 'orders_month' then case when p_n = 1 then 'Auftrag pro Monat' else 'Aufträge pro Monat' end
    when 'users' then case when p_n = 1 then 'Benutzer' else 'Benutzer' end
    when 'locations' then case when p_n = 1 then 'Standort' else 'Standorte' end
    else p_key end
$$;

-- p_dative: „von 25 Objekten“ statt „bis zu 25 Objekte“
drop function if exists private.partner_format_limit(text, bigint);
create or replace function private.partner_format_limit(p_key text, p_n bigint, p_dative boolean default false)
returns text
language sql immutable set search_path = ''
as $$
  select case when p_key = 'storage_bytes' then
    case when p_n >= 1073741824 then trim(to_char(p_n / 1073741824.0, 'FM999990.##')) || ' GB' else trim(to_char(p_n / 1048576.0, 'FM999990')) || ' MB' end
  when p_dative and p_n <> 1 then p_n::text || ' ' || case p_key when 'properties' then 'Objekten' when 'orders_month' then 'Aufträgen pro Monat'
    when 'users' then 'Benutzern' when 'locations' then 'Standorten' else private.partner_limit_label(p_key, p_n) end
  else p_n::text || ' ' || private.partner_limit_label(p_key, p_n) end
$$;

-- Liefert ok/used/limit/plan/upgrade und eine verständliche Meldung. Prüft nur, sperrt nicht.
create or replace function private.partner_check_limit(p_organization_id uuid, p_key text, p_amount bigint default 1)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_ent     jsonb := private.partner_entitlements(p_organization_id);
  v_limit   bigint := nullif(v_ent -> 'limits' ->> p_key, '')::bigint;
  v_used    bigint := (v_ent -> 'usage' ->> p_key)::bigint;
  v_up      public.partner_plans;
  v_msg     text;
begin
  if v_limit is null or v_used + greatest(p_amount, 0) <= v_limit then
    return jsonb_build_object('ok', true, 'key', p_key, 'used', v_used, 'limit', v_limit, 'plan_id', v_ent ->> 'plan_id');
  end if;
  -- kleinster aktiver Tarif, der den Bedarf deckt
  select * into v_up from public.partner_plans p
  where p.is_active and p.sort_order > coalesce((select q.sort_order from public.partner_plans q where q.id = v_ent ->> 'plan_id'), 0)
    and (p.limits -> p_key is null or jsonb_typeof(p.limits -> p_key) = 'null' or (p.limits ->> p_key)::bigint >= v_used + greatest(p_amount, 0))
  order by p.sort_order limit 1;
  v_msg := format('Du hast dein %s von %s im %s-Tarif erreicht.',
    case p_key when 'customers' then 'Kundenlimit' when 'properties' then 'Objektlimit' when 'orders_month' then 'Auftragslimit'
      when 'users' then 'Benutzerlimit' when 'storage_bytes' then 'Speicherlimit' when 'locations' then 'Standortlimit' else 'Limit' end,
    private.partner_format_limit(p_key, v_limit, true), v_ent ->> 'plan_name');
  if v_up.id is not null then
    v_msg := v_msg || format(' Wechsle zu %s, um %s zu %s.', v_up.name,
      case when v_up.limits -> p_key is null or jsonb_typeof(v_up.limits -> p_key) = 'null' then 'unbegrenzt ' || private.partner_limit_label(p_key, 2)
           else 'bis zu ' || private.partner_format_limit(p_key, (v_up.limits ->> p_key)::bigint) end,
      case when p_key in ('customers', 'properties', 'users') then 'verwalten' else 'nutzen' end);
  end if;
  if p_key = 'orders_month' then
    v_msg := v_msg || ' Der Zähler beginnt am 1. des nächsten Monats neu.';
  end if;
  return jsonb_build_object('ok', false, 'key', p_key, 'used', v_used, 'limit', v_limit, 'plan_id', v_ent ->> 'plan_id',
    'plan_name', v_ent ->> 'plan_name', 'upgrade_plan_id', v_up.id, 'upgrade_plan_name', v_up.name, 'message', v_msg);
end;
$$;

-- Für die App (Vorabprüfung vor dem Öffnen eines Formulars; die echte Sperre sitzt in den Triggern)
create or replace function public.check_partner_limit(p_organization_id uuid, p_resource_key text, p_requested_amount integer default 1)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_org_member(p_organization_id) then
    raise exception 'Keine Berechtigung für diesen Servicebetrieb' using errcode = '42501';
  end if;
  if p_resource_key not in ('customers', 'properties', 'orders_month', 'users', 'storage_bytes', 'locations') then
    raise exception 'Unbekannte Ressource' using errcode = '22023';
  end if;
  return private.partner_check_limit(p_organization_id, p_resource_key, p_requested_amount);
end;
$$;
revoke all on function public.check_partner_limit(uuid, text, integer) from public, anon;
grant execute on function public.check_partner_limit(uuid, text, integer) to authenticated;

-- Atomar: sperrt den Betrieb je Ressource für die laufende Transaktion, prüft und wirft bei Überschreitung.
-- Gleichzeitige Anlagen warten aufeinander, dadurch kann kein Limit durch parallele Requests überschritten werden.
create or replace function private.partner_enforce_limit(p_organization_id uuid, p_key text, p_amount bigint default 1)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_check jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended('husora-partner-limit:' || p_organization_id::text || ':' || p_key, 0));
  v_check := private.partner_check_limit(p_organization_id, p_key, p_amount);
  if not (v_check ->> 'ok')::boolean then
    raise exception '%', v_check ->> 'message'
      using errcode = 'P0001', detail = v_check::text, hint = 'husora_plan_limit';
  end if;
end;
$$;

-- Startschalter: app_config 'partner_plans' {"enforce": true} schaltet Limits und Funktionssperren
-- für Servicebetriebe scharf. Ausgeliefert ist er AUS, damit laufende Beta-Betriebe nicht plötzlich
-- gesperrt werden, solange Tarifwechsel noch nicht bezahlt werden können. Super-Admins schalten ihn
-- im Adminbereich (oder per SQL) ein.
insert into public.app_config (key, value) values ('partner_plans', '{"enforce": false}') on conflict (key) do nothing;

create or replace function private.partner_plans_enforced()
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce((select (c.value ->> 'enforce')::boolean from public.app_config c where c.key = 'partner_plans'), false) $$;

-- Wer darf die Prüfung überspringen: Migrationen/Seeds ohne Anmeldung und service_role (Webhook, Admin-Skripte)
create or replace function private.partner_limit_bypass()
returns boolean
language sql stable security definer set search_path = ''
as $$ select auth.uid() is null or coalesce(auth.role(), '') = 'service_role' or not private.partner_plans_enforced() $$;

-- -----------------------------------------------------------------------------
-- 9) Trigger: Kunden, Objekte, Aufträge, Benutzer, Speicher
-- -----------------------------------------------------------------------------
create or replace function private.partner_limit_customers()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if private.partner_limit_bypass() or not private.is_partner_org(new.organization_id) then return new; end if;
  -- Fremde Anlagen lehnt RLS ab – ohne Limit-Auskunft über einen anderen Betrieb
  if not private.is_org_member(new.organization_id) then return new; end if;
  perform private.partner_enforce_limit(new.organization_id, 'customers', 1);
  return new;
end;
$$;
drop trigger if exists customers_partner_limit on public.customers;
create trigger customers_partner_limit before insert on public.customers
  for each row execute function private.partner_limit_customers();

create or replace function private.partner_limit_properties()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_type text;
begin
  if private.partner_limit_bypass() or not private.is_org_member(new.organization_id) then return new; end if;
  select o.org_type into v_type from public.organizations o where o.id = new.organization_id;
  if v_type = 'service_partner' or (v_type = 'both' and new.owner_customer_id is not null) then
    perform private.partner_enforce_limit(new.organization_id, 'properties', 1);
  end if;
  return new;
end;
$$;
drop trigger if exists properties_partner_limit on public.properties;
create trigger properties_partner_limit before insert on public.properties
  for each row execute function private.partner_limit_properties();

-- Nur selbst angelegte Aufträge (Organisation = Betrieb und eigener Partner-Datensatz) zählen
create or replace function private.partner_limit_orders()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_period date := private.partner_month_start();
begin
  if private.partner_limit_bypass() or not private.is_partner_org(new.organization_id) then return new; end if;
  -- Fremde Anlagen lehnt RLS ab – ohne Limit-Auskunft über einen anderen Betrieb
  if not private.is_org_member(new.organization_id) then return new; end if;
  if new.service_partner_id is distinct from private.self_partner_id(new.organization_id) then return new; end if;
  perform private.partner_enforce_limit(new.organization_id, 'orders_month', 1);
  insert into public.usage_counters (organization_id, metric, period, count) values (new.organization_id, 'partner_orders_month', v_period, 1)
  on conflict (organization_id, metric, period) do update set count = public.usage_counters.count + 1, updated_at = now();
  return new;
end;
$$;
drop trigger if exists service_orders_partner_limit on public.service_orders;
create trigger service_orders_partner_limit before insert on public.service_orders
  for each row execute function private.partner_limit_orders();

-- Benutzer: neue aktive Mitgliedschaft (auch Reaktivierung). Bestehende bleiben bei Downgrade aktiv.
create or replace function private.partner_limit_members()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status <> 'active' or (tg_op = 'UPDATE' and old.status = 'active') then return new; end if;
  if private.partner_limit_bypass() or not private.is_partner_org(new.organization_id) then return new; end if;
  perform private.partner_enforce_limit(new.organization_id, 'users', 1);
  return new;
end;
$$;
drop trigger if exists organization_members_partner_limit on public.organization_members;
create trigger organization_members_partner_limit before insert or update of status on public.organization_members
  for each row execute function private.partner_limit_members();

-- Speicher: Dokumente im eigenen Betrieb (Uploads zu Aufträgen von Hausbesitzern liegen bei diesen)
create or replace function private.partner_limit_storage()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if private.partner_limit_bypass() or not private.is_partner_org(new.organization_id) then return new; end if;
  -- Fremde Anlagen lehnt RLS ab – ohne Limit-Auskunft über einen anderen Betrieb
  if not private.is_org_member(new.organization_id) then return new; end if;
  if coalesce(new.file_size, 0) <= 0 then return new; end if;
  perform private.partner_enforce_limit(new.organization_id, 'storage_bytes', new.file_size);
  return new;
end;
$$;
drop trigger if exists documents_partner_limit on public.documents;
create trigger documents_partner_limit before insert on public.documents
  for each row execute function private.partner_limit_storage();

-- -----------------------------------------------------------------------------
-- 10) Mitarbeiter einladen: offene Einladungen zählen mit (Rest wie bisher)
-- -----------------------------------------------------------------------------
create or replace function public.create_member_invite(p_organization_id uuid, p_email text, p_role text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_open integer;
begin
  if not private.is_org_admin(p_organization_id) then
    raise exception 'Nur Admins können Mitarbeiter einladen' using errcode = '42501';
  end if;
  if coalesce(trim(p_email), '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Bitte eine gültige E-Mail-Adresse angeben' using errcode = '22023';
  end if;
  if private.is_partner_org(p_organization_id) and not private.partner_limit_bypass() then
    select count(*) into v_open from public.organization_invites i
    where i.organization_id = p_organization_id and i.accepted_at is null and i.expires_at > now() and i.email <> lower(trim(p_email));
    perform private.partner_enforce_limit(p_organization_id, 'users', 1 + v_open);
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

-- -----------------------------------------------------------------------------
-- 11) Zusatzmodul mit sichtbar bestätigtem Preis anfragen / kündigen (Betriebs-Admin)
-- -----------------------------------------------------------------------------
create or replace function public.request_partner_addon(p_organization_id uuid, p_addon_code text, p_confirmed_price_cents integer, p_quantity integer default 1)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_addon public.partner_addon_catalog;
  v_row   public.partner_addons;
begin
  if not private.is_org_admin(p_organization_id) or not private.is_partner_org(p_organization_id) then
    raise exception 'Nur Admins des Servicebetriebs können Zusatzmodule buchen' using errcode = '42501';
  end if;
  select * into v_addon from public.partner_addon_catalog where code = p_addon_code and is_active;
  if v_addon.code is null then
    raise exception 'Dieses Zusatzmodul ist nicht verfügbar' using errcode = 'P0002';
  end if;
  if p_confirmed_price_cents is distinct from v_addon.price_monthly_cents then
    raise exception 'Der Preis hat sich geändert. Bitte den aktuellen Preis bestätigen.' using errcode = '22023';
  end if;
  insert into public.partner_addons (organization_id, addon_code, status, quantity, price_monthly_cents_confirmed, confirmed_by)
  values (p_organization_id, p_addon_code, 'requested', greatest(coalesce(p_quantity, 1), 1), v_addon.price_monthly_cents, private.current_user_id())
  on conflict (organization_id, addon_code) where status <> 'canceled'
  do update set quantity = excluded.quantity, price_monthly_cents_confirmed = excluded.price_monthly_cents_confirmed,
                confirmed_at = now(), confirmed_by = excluded.confirmed_by
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;
revoke all on function public.request_partner_addon(uuid, text, integer, integer) from public, anon;
grant execute on function public.request_partner_addon(uuid, text, integer, integer) to authenticated;

create or replace function public.cancel_partner_addon(p_organization_id uuid, p_addon_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_org_admin(p_organization_id) or not private.is_partner_org(p_organization_id) then
    raise exception 'Nur Admins des Servicebetriebs können Zusatzmodule kündigen' using errcode = '42501';
  end if;
  update public.partner_addons set status = 'canceled'
  where organization_id = p_organization_id and addon_code = p_addon_code and status <> 'canceled';
end;
$$;
revoke all on function public.cancel_partner_addon(uuid, text) from public, anon;
grant execute on function public.cancel_partner_addon(uuid, text) to authenticated;

-- Vorschau für einen Tarifwechsel: was wäre über dem Limit des Zieltarifs (nichts wird gelöscht)
create or replace function public.partner_plan_change_preview(p_organization_id uuid, p_plan_id text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_target public.partner_plans;
  v_ent    jsonb;
  v_over   jsonb := '[]'::jsonb;
  v_lost   jsonb;
  k        text;
  v_limit  bigint;
  v_used   bigint;
begin
  if not private.is_org_member(p_organization_id) then
    raise exception 'Keine Berechtigung für diesen Servicebetrieb' using errcode = '42501';
  end if;
  select * into v_target from public.partner_plans where id = p_plan_id and is_active;
  if v_target.id is null then raise exception 'Unbekannter Tarif' using errcode = 'P0002'; end if;
  v_ent := private.partner_entitlements(p_organization_id);
  foreach k in array array['customers', 'properties', 'orders_month', 'users', 'storage_bytes', 'locations'] loop
    v_limit := nullif(v_target.limits ->> k, '')::bigint;
    v_used := (v_ent -> 'usage' ->> k)::bigint;
    if v_limit is not null and v_used > v_limit then
      v_over := v_over || jsonb_build_array(jsonb_build_object('key', k, 'used', v_used, 'limit', v_limit));
    end if;
  end loop;
  select coalesce(jsonb_agg(f), '[]'::jsonb) into v_lost from jsonb_array_elements(v_ent -> 'features') f where not v_target.features @> jsonb_build_array(f);
  return jsonb_build_object('plan_id', v_target.id, 'plan_name', v_target.name, 'over_limit', v_over, 'features_lost', v_lost);
end;
$$;
revoke all on function public.partner_plan_change_preview(uuid, text) from public, anon;
grant execute on function public.partner_plan_change_preview(uuid, text) to authenticated;

grant execute on function private.is_partner_org(uuid), private.self_partner_id(uuid), private.partner_plan_id(uuid),
  private.partner_month_start(), private.partner_usage(uuid, text), private.partner_entitlements(uuid), private.partner_has_feature(uuid, text),
  private.partner_check_limit(uuid, text, bigint), private.partner_enforce_limit(uuid, text, bigint), private.partner_limit_bypass(),
  private.partner_limit_label(text, bigint), private.partner_format_limit(text, bigint, boolean), private.partner_plans_enforced() to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 12) Startwerte (Preise netto/Monat). Änderungen danach nur im Adminbereich.
-- -----------------------------------------------------------------------------
insert into public.partner_plans (id, code, name, tagline, price_monthly_cents, sort_order, highlight, limits, features, highlights) values
  ('partner_free', 'free', 'Free', 'Husora kennenlernen', 0, 10, false,
   '{"customers":3,"properties":5,"orders_month":10,"users":1,"locations":1,"storage_bytes":524288000}',
   '["orders_basic","customers_overview","photos_basic","inspections_basic","service_profile","stats_basic","branding_husora"]',
   '["3 Kunden · 5 Objekte","10 eigene Aufträge pro Monat","1 Benutzer","Basis-Auftragsverwaltung und Fotodokumentation","Kunden- und Objektübersicht, Leistungsprofil","500 MB Speicher"]'),
  ('partner_plus', 'plus', 'Plus', 'Für Selbstständige', 1490, 20, false,
   '{"customers":20,"properties":25,"orders_month":100,"users":1,"locations":1,"storage_bytes":5368709120}',
   '["orders_basic","orders_full","customers_overview","photos_basic","photos","inspections_basic","inspections","checklists","repairs","calendar","recurring_basic","quotes_basic","invoices_basic","pdf_reports","email","automation_basic","service_profile","stats_basic","branding_husora"]',
   '["20 Kunden · 25 Objekte","100 eigene Aufträge pro Monat","Checklisten, Hauskontrollen, Mängelmeldungen","Kalender und wiederkehrende Aufgaben","Angebote und Rechnungsdokumentation (Basis)","PDF-Berichte · 5 GB Speicher"]'),
  ('partner_pro', 'pro', 'Pro', 'Für Betriebe mit Team', 2990, 30, true,
   '{"customers":100,"properties":100,"orders_month":null,"users":5,"locations":1,"storage_bytes":26843545600}',
   '["orders_basic","orders_full","customers_overview","photos_basic","photos","inspections_basic","inspections","checklists","repairs","calendar","recurring_basic","recurring_advanced","quotes_basic","quotes_advanced","invoices_basic","invoices_advanced","pdf_reports","email","automation_basic","automation_advanced","service_profile","stats_basic","stats_advanced","employee_management","role_permissions","order_assignment","dispatch_basic","maintenance_intervals","work_logs","material_travel","customer_communication","auto_planning","escalations","company_profile"]',
   '["100 Kunden · 100 Objekte","Unbegrenzte Aufträge","Bis zu 5 Benutzer mit Rollen und Rechten","Mitarbeiter- und Auftragszuweisung","Wartungsintervalle, Arbeitsprotokolle, Material und Fahrten","Erweiterte Angebote, Rechnungen und Auswertungen","Eigenes Unternehmensprofil · 25 GB Speicher"]'),
  ('partner_ultra', 'ultra', 'Ultra', 'Für Teams und Standorte', 5990, 40, false,
   '{"customers":null,"properties":null,"orders_month":null,"users":20,"locations":null,"storage_bytes":107374182400}',
   '["orders_basic","orders_full","customers_overview","photos_basic","photos","inspections_basic","inspections","checklists","checklists_custom","repairs","calendar","calendar_advanced","recurring_basic","recurring_advanced","quotes_basic","quotes_advanced","invoices_basic","invoices_advanced","pdf_reports","email","automation_basic","automation_advanced","service_profile","stats_basic","stats_advanced","employee_management","employee_management_advanced","role_permissions","roles_advanced","order_assignment","dispatch_basic","dispatch_advanced","maintenance_intervals","maintenance_auto","work_logs","material_travel","customer_communication","auto_planning","escalations","company_profile","multi_location","subcontractor_management","budget_control","reports_advanced","api_access","export","white_label","priority_support"]',
   '["Unbegrenzte Kunden, Objekte und Aufträge","Bis zu 20 Benutzer · mehrere Standorte","Team- und Einsatzplanung, Subunternehmer","Individuelle Checklisten, automatisierte Wartungsplanung","Budget- und Kostenkontrolle, Unternehmensberichte","API, Export und eigenes Branding","Priorisierter Support · 100 GB Speicher"]')
on conflict (id) do nothing;

insert into public.partner_addon_catalog (code, name, description, price_monthly_cents, price_is_from, effect, usage_based_note, sort_order) values
  ('extra_user', 'Weiterer Benutzer', 'Ein zusätzlicher Benutzer über das Tariflimit hinaus.', 390, false, '{"limits":{"users":1}}', null, 10),
  ('extra_properties', 'Weitere 100 Immobilien', '100 zusätzliche Objekte.', 990, false, '{"limits":{"properties":100}}', null, 20),
  ('premium_archive', 'Premium-Dokumentenarchiv', 'Erweitertes Archiv für Dokumente und Berichte.', 490, false, '{"features":["premium_archive"]}', null, 30),
  ('advanced_automation', 'Erweiterte Automatisierung', 'Zusätzliche Automatisierungen.', 990, false, '{"features":["automation_advanced"]}', null, 40),
  ('ai_assistant', 'KI-Assistent für Servicepartner', 'KI-Unterstützung für Texte und Auswertungen.', 990, false, '{"features":["ai_assistant"]}', 'Externe KI-Kosten bei sehr hoher Nutzung werden vorab transparent ausgewiesen.', 50),
  ('customer_comm_plus', 'Erweiterte Kundenkommunikation', 'Zusätzliche Kommunikationswege mit Kunden.', 490, false, '{"features":["customer_communication_plus"]}', 'SMS oder WhatsApp kosten je Nachricht extra und werden separat ausgewiesen.', 60),
  ('white_label_portal', 'White-Label-Kundenportal', 'Kundenportal mit eigenem Branding.', 1990, false, '{"features":["white_label_portal"]}', null, 70),
  ('api_plus', 'API-Erweiterung', 'Zusätzliche Integrationen über die API.', 1990, true, '{"features":["api_plus"]}', 'Preis ab 19,90 €, abhängig vom Umfang.', 80)
on conflict (code) do nothing;

-- -----------------------------------------------------------------------------
-- 13) Adminbereich: Übersicht aller Servicebetriebe mit Tarif, Status und Nutzung
-- -----------------------------------------------------------------------------
create or replace function public.admin_partner_plan_overview()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.has_admin_role('support_admin') then
    raise exception 'Nur für das Husora-Team' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'organization_id', o.id, 'name', o.name,
      'subscription', (select to_jsonb(s) - 'provider_customer_id' from public.partner_subscriptions s where s.organization_id = o.id),
      'entitlements', private.partner_entitlements(o.id) - 'features'
    ) order by o.name)
    from public.organizations o where o.org_type in ('service_partner', 'both')
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.admin_partner_plan_overview() from public, anon;
grant execute on function public.admin_partner_plan_overview() to authenticated;
