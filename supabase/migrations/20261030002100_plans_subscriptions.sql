-- =============================================================================
-- HUSORA · Migration 2100 · Tarife FREE / PLUS / PRO / ULTIMATE
-- =============================================================================
-- Preise, Grenzwerte und Funktionen je Tarif liegen in public.plans (nicht im
-- Frontend). Je Organisation gibt es höchstens ein Abo in public.subscriptions
-- (für Stripe vorbereitet). Ohne aktives Abo gilt FREE.
-- Schreiben in plans/subscriptions nur durch service_role (z. B. Stripe-Webhook),
-- nie aus dem Browser. Ein Downgrade löscht keine Daten – neue Einträge über dem
-- Limit werden in der App blockiert, die bestehenden bleiben erhalten.

create table public.plans (
  id                  text primary key check (id ~ '^[a-z][a-z0-9_]*$'),
  name                text not null,
  tagline             text,
  price_monthly_cents integer not null default 0 check (price_monthly_cents >= 0),
  currency            text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  sort                integer not null default 0,
  active              boolean not null default true,
  highlight           boolean not null default false,
  -- Grenzwerte: null = unbegrenzt
  limits              jsonb not null default '{}'::jsonb,
  -- Funktionsschlüssel, die dieser Tarif freischaltet
  features            jsonb not null default '[]'::jsonb check (jsonb_typeof(features) = 'array'),
  -- Beschreibungstexte für die Tarifseite
  highlights          jsonb not null default '[]'::jsonb check (jsonb_typeof(highlights) = 'array'),
  stripe_price_id     text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
comment on table public.plans is 'Tarife inkl. Preis, Grenzwerten (null = unbegrenzt) und Funktionsschlüsseln.';

create table public.subscriptions (
  id                     uuid primary key default gen_random_uuid(),
  organization_id        uuid not null unique references public.organizations(id) on delete cascade,
  plan_id                text not null references public.plans(id),
  stripe_customer_id     text,
  stripe_subscription_id text unique,
  status                 text not null default 'active' check (status in ('trialing', 'active', 'past_due', 'canceled', 'incomplete', 'incomplete_expired', 'unpaid', 'paused')),
  current_period_start   timestamptz,
  current_period_end     timestamptz,
  cancel_at_period_end   boolean not null default false,
  note                   text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
comment on table public.subscriptions is 'Abo je Organisation (Stripe vorbereitet). Ohne Eintrag oder ohne aktiven Status gilt FREE.';
create index subscriptions_plan_idx on public.subscriptions (plan_id);

create trigger plans_updated_at before update on public.plans for each row execute function private.set_updated_at();
create trigger subscriptions_updated_at before update on public.subscriptions for each row execute function private.set_updated_at();

alter table public.plans enable row level security;
alter table public.subscriptions enable row level security;

-- Tarife sind öffentlich lesbar (Preisseite auch ohne Anmeldung)
create policy plans_select on public.plans for select to anon, authenticated using (active);
-- Abo: lesen nur die eigene Organisation; schreiben nur service_role (keine Policy für insert/update/delete)
create policy subscriptions_select on public.subscriptions for select to authenticated using (private.can_read_org(organization_id));

grant select on public.plans to anon, authenticated;
grant select on public.subscriptions to authenticated;
grant all on public.plans, public.subscriptions to service_role;

-- -----------------------------------------------------------------------------
-- Tarif einer Organisation und Prüfung einzelner Funktionen
-- -----------------------------------------------------------------------------
create or replace function private.org_plan(p_organization_id uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select s.plan_id from public.subscriptions s
    where s.organization_id = p_organization_id
      and s.status in ('trialing', 'active', 'past_due')
      and (s.current_period_end is null or s.current_period_end > now() - interval '3 days')
  ), 'free')
$$;

create or replace function private.plan_allows(p_organization_id uuid, p_feature text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.plans p
    where p.id = private.org_plan(p_organization_id) and p.features ? p_feature
  )
$$;

-- Für die App: Tarif, Status, Grenzwerte und Funktionen der eigenen Organisation
create or replace function public.my_plan(p_organization_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_plan public.plans;
  v_sub  public.subscriptions;
begin
  if not private.can_read_org(p_organization_id) then
    raise exception 'Keine Berechtigung für diese Organisation' using errcode = '42501';
  end if;
  select * into v_plan from public.plans where id = private.org_plan(p_organization_id);
  select * into v_sub from public.subscriptions where organization_id = p_organization_id;
  return jsonb_build_object(
    'plan_id', v_plan.id,
    'plan_name', v_plan.name,
    'limits', v_plan.limits,
    'features', v_plan.features,
    'status', coalesce(v_sub.status, 'none'),
    'subscribed_plan_id', v_sub.plan_id,
    'current_period_end', v_sub.current_period_end,
    'cancel_at_period_end', coalesce(v_sub.cancel_at_period_end, false)
  );
end;
$$;

grant execute on function private.org_plan(uuid), private.plan_allows(uuid, text) to authenticated, service_role;
grant execute on function public.my_plan(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Serverseitige Sperre: Partner-Portal und Serviceaufträge erst ab PRO
-- (gilt für Hausbesitzer-Organisationen; Servicebetriebe sind nicht betroffen)
-- -----------------------------------------------------------------------------
create or replace function private.require_service_portal()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  -- Ausnahme nur für Vorgänge ohne angemeldeten Nutzer (Migration, Seed) und service_role.
  -- Nicht private.is_system_context(): in security-definer-Funktionen ist current_user immer der Besitzer.
  if auth.uid() is null or coalesce(auth.role(), '') = 'service_role' then return new; end if;
  if exists (select 1 from public.organizations o where o.id = new.organization_id and o.org_type = 'service_partner') then return new; end if;
  if not private.plan_allows(new.organization_id, 'service_portal') then
    raise exception 'Das Partner-Portal ist ab dem Tarif PRO verfügbar.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger service_orders_require_plan before insert on public.service_orders
  for each row execute function private.require_service_portal();
create trigger service_partner_invites_require_plan before insert on public.service_partner_invites
  for each row execute function private.require_service_portal();

-- -----------------------------------------------------------------------------
-- Tarife (Preise in Cent, monatlich)
-- -----------------------------------------------------------------------------
insert into public.plans (id, name, tagline, price_monthly_cents, currency, sort, highlight, limits, features, highlights) values
  ('free', 'FREE', 'Für dein erstes Ferienhaus', 0, 'EUR', 10, false,
   '{"properties":1,"users":1,"tasks_active":5,"service_partners":2,"documents":25,"inspection_reports_month":3,"listing_imports_month":0,"invoice_analyses_month":0}',
   '["calendar","tasks","inspection","seasons","costs_basic","emergency","bookings"]',
   '["1 Haus · 1 Benutzer","5 aktive Aufgaben · 2 Servicepartner","25 Dokumente · 3 Kontrollberichte/Monat","Basis-Hauskontrolle und Saison-Checklisten","Kalender, Aufgaben und Kostenübersicht","Notfallinformationen"]'),
  ('plus', 'PLUS', 'Für Eigentümer mit mehr Überblick', 790, 'EUR', 20, false,
   '{"properties":2,"users":2,"tasks_active":25,"service_partners":10,"documents":250,"inspection_reports_month":10,"listing_imports_month":5,"invoice_analyses_month":5}',
   '["calendar","tasks","inspection","seasons","costs_basic","emergency","bookings","repairs","renovations","contracts","meters","costs_annual","automation_basic","house_model","listing_import","invoice_ai","pdf_reports","ai_basic"]',
   '["2 Häuser · 2 Benutzer","25 aktive Aufgaben · 10 Servicepartner","250 Dokumente · 10 Kontrollberichte/Monat","Reparaturen, Sanierungsprojekte (Basis)","Verträge & Fristen, Zählerstände, Jahreskosten","Automatische Aufgaben (Basis) und Hausmodell","5 Inseratimporte und 5 Rechnungsanalysen/Monat","PDF-Berichte, einfache KI-Textanalyse"]'),
  ('pro', 'PRO', 'Mit Servicepartner-Portal', 1790, 'EUR', 30, true,
   '{"properties":5,"users":5,"tasks_active":null,"service_partners":null,"documents":2000,"inspection_reports_month":null,"listing_imports_month":20,"invoice_analyses_month":25}',
   '["calendar","tasks","inspection","seasons","costs_basic","emergency","bookings","repairs","renovations","contracts","meters","costs_annual","automation_basic","house_model","listing_import","invoice_ai","pdf_reports","ai_basic","service_portal","service_orders","repair_orders_auto","renovations_full","budget","automation_advanced","ai_advanced","cost_trends","annual_report","priority_support"]',
   '["5 Häuser · 5 Benutzer","Unbegrenzt Aufgaben, Servicepartner und Hauskontrollen","2.000 Dokumente","Servicepartner-Portal und Serviceaufträge","Automatische Reparaturaufträge","Volles Reparatur- und Sanierungsmanagement mit Budget","Erweiterte Automatisierung und KI","20 Inseratimporte, 25 Rechnungsanalysen/Monat","Kostenentwicklung, Jahresauswertung, Prioritätssupport"]'),
  ('ultimate', 'ULTIMATE', 'Für Portfolios und Profis', 3490, 'EUR', 40, false,
   '{"properties":20,"users":10,"tasks_active":null,"service_partners":null,"documents":null,"inspection_reports_month":null,"listing_imports_month":null,"invoice_analyses_month":100}',
   '["calendar","tasks","inspection","seasons","costs_basic","emergency","bookings","repairs","renovations","contracts","meters","costs_annual","automation_basic","house_model","listing_import","invoice_ai","pdf_reports","ai_basic","service_portal","service_orders","repair_orders_auto","renovations_full","budget","automation_advanced","ai_advanced","cost_trends","annual_report","priority_support","automation_autonomous","maintenance_planning","partner_auto_assign","escalations","cost_forecast","budget_alerts","condition_score","portfolio","roles_advanced","activity_log"]',
   '["20 Häuser · 10 Benutzer","Unbegrenzte Dokumente und Inseratimporte","Advanced Automatisierung: Aufgabenplanung, Wartungswarnungen, Eskalationen","Automatische Servicepartner-Zuordnung und Auftragserstellung","100 Rechnungsanalysen/Monat, Advanced KI","Kostenprognosen, Budgetwarnungen, Hauszustands-Score","Portfolioübersicht und Jahresbericht","Erweiterte Rollen, Aktivitätsprotokoll, Prioritätssupport"]')
on conflict (id) do nothing;
