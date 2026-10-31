-- =============================================================================
-- HUSORA · Migration 2200 · Launch: Feedback/Fehlerberichte, Benachrichtigungen,
--                              Konto löschen, Stripe-Idempotenz
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Feedback und Fehlerberichte aus der App (nur schreiben, nie lesen)
-- -----------------------------------------------------------------------------
create table public.app_feedback (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null default 'feedback' check (kind in ('feedback', 'bug', 'error')),
  message         text not null check (length(trim(message)) between 1 and 4000),
  context         jsonb not null default '{}'::jsonb check (pg_column_size(context) <= 8000),
  page            text check (length(page) <= 80),
  app_version     text check (length(app_version) <= 40),
  user_agent      text check (length(user_agent) <= 300),
  contact_email   text check (contact_email is null or contact_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  auth_user_id    uuid default auth.uid(),
  organization_id uuid references public.organizations(id) on delete set null,
  created_at      timestamptz not null default now()
);
comment on table public.app_feedback is 'Feedback, Fehlermeldungen und automatische Fehlerberichte. Lesen nur über service_role (Dashboard).';
create index app_feedback_created_idx on public.app_feedback (created_at desc);
create index app_feedback_kind_idx on public.app_feedback (kind, created_at desc);

alter table public.app_feedback enable row level security;
-- Schreiben dürfen alle (auch ohne Konto), aber nur mit eigener/keiner Nutzer-ID
-- und nur in eine Organisation, der man angehört.
create policy app_feedback_insert_anon on public.app_feedback for insert to anon
  with check (auth_user_id is null and organization_id is null);
create policy app_feedback_insert on public.app_feedback for insert to authenticated
  with check (
    (auth_user_id is null or auth_user_id = auth.uid())
    and (organization_id is null or private.is_org_member(organization_id))
  );
grant insert on public.app_feedback to anon, authenticated;
grant all on public.app_feedback to service_role;

-- Missbrauchsschutz: höchstens 30 Einträge je Konto und Stunde, 300 ohne Konto je Stunde
create or replace function private.app_feedback_rate_limit()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_count integer;
begin
  if new.auth_user_id is not null then
    select count(*) into v_count from public.app_feedback where auth_user_id = new.auth_user_id and created_at > now() - interval '1 hour';
    if v_count >= 30 then raise exception 'Zu viele Meldungen – bitte später erneut versuchen.' using errcode = 'P0001'; end if;
  else
    select count(*) into v_count from public.app_feedback where auth_user_id is null and created_at > now() - interval '1 hour';
    if v_count >= 300 then raise exception 'Zu viele Meldungen – bitte später erneut versuchen.' using errcode = 'P0001'; end if;
  end if;
  return new;
end;
$$;
create trigger app_feedback_rate_limit before insert on public.app_feedback
  for each row execute function private.app_feedback_rate_limit();

-- -----------------------------------------------------------------------------
-- 2) Benachrichtigungen bei Auftragsstatus und Rechnungen
-- -----------------------------------------------------------------------------
-- Hausbesitzer-Verwaltung: angenommen, abgelehnt, terminiert, in Arbeit, erledigt.
-- Partnerleitung: neue Anfrage, zurückgezogen.
create or replace function private.notify_order_status()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_partner text;
  v_partner_org uuid;
  v_title text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
  select sp.company_name, sp.partner_organization_id into v_partner, v_partner_org
  from public.service_partners sp where sp.id = new.service_partner_id;

  -- an den Hausbesitzer
  v_title := case new.status
    when 'accepted' then coalesce(v_partner, 'Servicepartner') || ' hat den Auftrag angenommen'
    when 'rejected' then coalesce(v_partner, 'Servicepartner') || ' hat den Auftrag abgelehnt'
    when 'scheduled' then 'Termin geplant: ' || new.title
    when 'in_progress' then coalesce(v_partner, 'Servicepartner') || ' hat mit dem Auftrag begonnen'
    when 'completed' then 'Auftrag erledigt: ' || new.title
    else null end;
  if tg_op = 'UPDATE' and v_title is not null and v_partner_org is not null and v_partner_org <> new.organization_id then
    insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
    select new.organization_id, m.user_id, 'service_order', v_title,
           left(concat_ws(' · ', new.title, nullif(new.response_note, '')), 200), 'service_order', new.id
    from public.organization_members m
    where m.organization_id = new.organization_id and m.status = 'active'
      and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher');
  end if;

  -- an den Partnerbetrieb
  if v_partner_org is not null and v_partner_org <> new.organization_id
     and ((tg_op = 'INSERT' and new.status = 'offered') or (tg_op = 'UPDATE' and new.status = 'cancelled')) then
    insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
    select v_partner_org, m.user_id, 'service_order',
           case when new.status = 'offered' then 'Neue Anfrage: ' || new.title else 'Anfrage zurückgezogen: ' || new.title end,
           left(coalesce(new.description, ''), 200), 'service_order', new.id
    from public.organization_members m
    where m.organization_id = v_partner_org and m.status = 'active'
      and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher');
  end if;
  return new;
end;
$$;
create trigger service_orders_notify_status after insert or update of status on public.service_orders
  for each row execute function private.notify_order_status();

create or replace function private.notify_invoice()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_partner text;
begin
  if new.service_partner_id is null or private.is_org_member(new.organization_id) then return new; end if; -- nur Rechnungen der Partnerseite
  select sp.company_name into v_partner from public.service_partners sp where sp.id = new.service_partner_id;
  insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id)
  select new.organization_id, m.user_id, 'invoice', 'Rechnung von ' || coalesce(v_partner, 'Servicepartner'),
         concat_ws(' · ', new.invoice_number, new.amount_gross::text || ' ' || new.currency), 'invoice', new.id
  from public.organization_members m
  where m.organization_id = new.organization_id and m.status = 'active'
    and m.role in ('admin', 'property_manager', 'service_manager', 'dispatcher', 'accounting');
  return new;
end;
$$;
create trigger invoices_notify after insert on public.invoices
  for each row execute function private.notify_invoice();

-- -----------------------------------------------------------------------------
-- 3) Konto löschen (Löschkonzept, Art. 17 DSGVO)
-- -----------------------------------------------------------------------------
-- Löscht Organisationen, in denen der Nutzer das einzige aktive Mitglied ist
-- (samt aller Daten per ON DELETE CASCADE), entfernt seine übrigen Mitgliedschaften
-- und löscht das Benutzerkonto. Dateien im Storage löscht die App vorher über die
-- Storage-API (direktes Löschen in storage.objects ist nicht erlaubt).
-- Rechnungen/Aufträge anderer Organisationen bleiben dort zur Nachweisführung erhalten.
create or replace function public.delete_my_account(p_confirm text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_auth uuid := auth.uid();
  v_user uuid := private.current_user_id();
  v_orgs uuid[];
  v_left integer;
begin
  if v_auth is null or v_user is null then raise exception 'Nicht angemeldet' using errcode = '42501'; end if;
  if p_confirm is distinct from 'LÖSCHEN' then raise exception 'Bitte zur Bestätigung LÖSCHEN eingeben.' using errcode = '22023'; end if;
  select coalesce(array_agg(m.organization_id), '{}') into v_orgs
  from public.organization_members m
  where m.user_id = v_user and m.status = 'active'
    and not exists (select 1 from public.organization_members o where o.organization_id = m.organization_id and o.user_id <> v_user and o.status = 'active');
  delete from public.organizations where id = any (v_orgs);
  delete from public.organization_members where user_id = v_user;
  select count(*) into v_left from public.organization_members where user_id = v_user;
  delete from public.users where id = v_user;
  delete from auth.users where id = v_auth;
  return jsonb_build_object('deleted_organizations', coalesce(array_length(v_orgs, 1), 0), 'remaining_memberships', v_left);
end;
$$;
revoke all on function public.delete_my_account(text) from public, anon;
grant execute on function public.delete_my_account(text) to authenticated;

-- Welche Organisationen würde das Löschen mitnehmen? (für den Bestätigungsdialog)
create or replace function public.my_deletion_preview()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'organizations', coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'org_type', o.org_type)), '[]'::jsonb)
  )
  from public.organizations o
  join public.organization_members m on m.organization_id = o.id and m.user_id = private.current_user_id() and m.status = 'active'
  where not exists (select 1 from public.organization_members x where x.organization_id = o.id and x.user_id <> m.user_id and x.status = 'active')
$$;
grant execute on function public.my_deletion_preview() to authenticated;

-- -----------------------------------------------------------------------------
-- 4) Stripe: verarbeitete Webhook-Ereignisse (Idempotenz), nur service_role
-- -----------------------------------------------------------------------------
create table public.stripe_events (
  id           text primary key,
  type         text not null,
  processed_at timestamptz not null default now(),
  payload      jsonb
);
alter table public.stripe_events enable row level security;
grant all on public.stripe_events to service_role;
comment on table public.stripe_events is 'Bereits verarbeitete Stripe-Ereignisse (doppelte Webhooks werden ignoriert). Kein Zugriff aus dem Browser.';

-- -----------------------------------------------------------------------------
-- 5) Aufbewahrung: Feedback/Fehlerberichte 12 Monate, gelesene Benachrichtigungen 6 Monate,
--    verarbeitete Stripe-Ereignisse 3 Monate – wöchentlich per pg_cron
-- -----------------------------------------------------------------------------
create or replace function private.cleanup_retention()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.app_feedback where created_at < now() - interval '12 months';
  delete from public.notifications where read_at is not null and read_at < now() - interval '6 months';
  delete from public.stripe_events where processed_at < now() - interval '3 months';
$$;

do $$
begin
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.schedule('husora-retention', '17 3 * * 0', 'select private.cleanup_retention()');
exception when others then
  raise notice 'pg_cron nicht verfügbar – Bereinigung bitte manuell ausführen: %', sqlerrm;
end $$;
