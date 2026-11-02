-- =============================================================================
-- HUSORA · Phase 9: Benachrichtigungen (Kategorien, Einstellungen, Push/E-Mail) + Chat-Anhänge
-- =============================================================================
-- Bestehendes wird erweitert:
--   * public.notifications bekommt eine Kategorie (order, message, invoice, approval, repair,
--     inspection, agreement, maintenance, system), aus vorhandenen Feldern abgeleitet.
--   * neu: public.notification_preferences (je Benutzer und Kategorie: in der App, Push, E-Mail)
--   * neu: public.push_subscriptions (Web-Push-Endpunkte des eigenen Geräts)
--   * Versand von Push/E-Mail übernimmt die Edge Function „notify-dispatch“. Der Trigger ruft sie nur
--     auf, wenn im Supabase Vault 'notify_dispatch_url' und 'notify_dispatch_secret' hinterlegt sind.
--     VAPID- und E-Mail-Schlüssel liegen ausschließlich als Secrets der Edge Function, nie im Code.
--   * public.messages: Anhang (Dokument oder Foto) desselben Auftrags.
-- Idempotent.

-- -----------------------------------------------------------------------------
-- 1) Kategorie je Benachrichtigung
-- -----------------------------------------------------------------------------
alter table public.notifications add column if not exists category text;
create or replace function private.notification_category(p_type text, p_entity text, p_title text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_type = 'message' or p_entity = 'message' then 'message'
    when p_title ~* '^(Freigabe|Mehrkosten)' then 'approval'
    when p_entity = 'invoice' or p_type = 'invoice' then 'invoice'
    when p_entity in ('service_agreement', 'agreement') or p_type = 'agreement' then 'agreement'
    when p_entity = 'repair' then 'repair'
    when p_entity = 'inspection' or p_type = 'inspection' then 'inspection'
    when p_entity in ('maintenance', 'automation') or p_type in ('maintenance', 'automation') then 'maintenance'
    when p_entity = 'service_order' or p_type = 'service_order' then 'order'
    else 'system' end
$$;
update public.notifications set category = private.notification_category(type, entity_type, title) where category is null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'notifications_category_check') then
    alter table public.notifications add constraint notifications_category_check
      check (category is null or category in ('order', 'message', 'invoice', 'approval', 'repair', 'inspection', 'agreement', 'maintenance', 'system'));
  end if;
end $$;
create index if not exists notifications_user_category_idx on public.notifications (user_id, category, created_at desc);

-- -----------------------------------------------------------------------------
-- 2) Einstellungen je Benutzer und Kategorie
-- -----------------------------------------------------------------------------
create table if not exists public.notification_preferences (
  user_id     uuid not null default private.current_user_id() references public.users(id) on delete cascade,
  category    text not null check (category in ('order', 'message', 'invoice', 'approval', 'repair', 'inspection', 'agreement', 'maintenance', 'system')),
  in_app      boolean not null default true,
  push        boolean not null default true,
  email       boolean not null default false,
  updated_at  timestamptz not null default now(),
  primary key (user_id, category)
);
comment on table public.notification_preferences is 'Benachrichtigungen je Benutzer und Kategorie: in der App, Push, E-Mail (fehlende Zeile = Standard)';
drop trigger if exists notification_preferences_set_updated_at on public.notification_preferences;
create trigger notification_preferences_set_updated_at before update on public.notification_preferences
  for each row execute function private.set_updated_at();
alter table public.notification_preferences enable row level security;
drop policy if exists notification_preferences_own on public.notification_preferences;
create policy notification_preferences_own on public.notification_preferences for all to authenticated
  using (user_id = (select private.current_user_id())) with check (user_id = (select private.current_user_id()));
revoke all on public.notification_preferences from anon;
grant select, insert, update, delete on public.notification_preferences to authenticated;

-- -----------------------------------------------------------------------------
-- 3) Web-Push-Abos (nur das eigene Gerät)
-- -----------------------------------------------------------------------------
create table if not exists public.push_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default private.current_user_id() references public.users(id) on delete cascade,
  endpoint      text not null unique check (endpoint ~ '^https://' and length(endpoint) <= 1000),
  p256dh        text not null check (length(p256dh) between 20 and 200),
  auth_key      text not null check (length(auth_key) between 8 and 100),
  user_agent    text check (user_agent is null or length(user_agent) <= 300),
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz
);
comment on table public.push_subscriptions is 'Web-Push-Endpunkte; Versand nur über die Edge Function notify-dispatch';
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
create or replace function private.push_subscription_owner()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  new.user_id := private.current_user_id();
  if new.user_id is null then raise exception 'Bitte zuerst anmelden' using errcode = '42501'; end if;
  select count(*) into v_count from public.push_subscriptions s where s.user_id = new.user_id;
  if v_count >= 10 then raise exception 'Höchstens 10 Geräte je Konto' using errcode = 'P0001'; end if;
  return new;
end; $$;
drop trigger if exists push_subscription_owner on public.push_subscriptions;
create trigger push_subscription_owner before insert on public.push_subscriptions
  for each row execute function private.push_subscription_owner();
alter table public.push_subscriptions enable row level security;
drop policy if exists push_subscriptions_own on public.push_subscriptions;
create policy push_subscriptions_own on public.push_subscriptions for all to authenticated
  using (user_id = (select private.current_user_id())) with check (user_id = (select private.current_user_id()));
revoke all on public.push_subscriptions from anon;
grant select, insert, delete on public.push_subscriptions to authenticated;

-- Öffentlicher VAPID-Schlüssel (kein Geheimnis) – hier vom Husora-Team einzutragen
insert into public.app_config (key, value) values ('push', '{"vapid_public_key": null}') on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- 4) Einstellungen beim Anlegen anwenden und Versand anstoßen
-- -----------------------------------------------------------------------------
create or replace function private.notification_apply_prefs()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_pref public.notification_preferences;
begin
  new.category := coalesce(new.category, private.notification_category(new.type, new.entity_type, new.title));
  select * into v_pref from public.notification_preferences p where p.user_id = new.user_id and p.category = new.category;
  if v_pref.user_id is not null and new.category <> 'system' then
    if not v_pref.in_app and not v_pref.push and not v_pref.email then return null; end if;  -- ganz ausgeschaltet
    if not v_pref.in_app then new.read_at := coalesce(new.read_at, now()); end if;           -- nur Push/E-Mail
  end if;
  return new;
end; $$;
drop trigger if exists notifications_apply_prefs on public.notifications;
create trigger notifications_apply_prefs before insert on public.notifications
  for each row execute function private.notification_apply_prefs();

create extension if not exists pg_net with schema extensions;
create or replace function private.notification_dispatch()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_url    text;
  v_secret text;
  v_push   boolean;
  v_email  boolean;
begin
  select coalesce(p.push, true), coalesce(p.email, false) into v_push, v_email
  from (select 1) x left join public.notification_preferences p on p.user_id = new.user_id and p.category = new.category;
  if not v_email and not (v_push and exists (select 1 from public.push_subscriptions s where s.user_id = new.user_id)) then return null; end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'notify_dispatch_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'notify_dispatch_secret';
  if v_url is null or v_secret is null then return null; end if;   -- Versand noch nicht eingerichtet
  perform net.http_post(url := v_url, body := jsonb_build_object('notification_id', new.id),
                        headers := jsonb_build_object('Content-Type', 'application/json', 'x-husora-secret', v_secret));
  return null;
exception when others then
  raise warning 'Benachrichtigung % nicht weitergeleitet: %', new.id, sqlerrm;
  return null;
end; $$;
drop trigger if exists notifications_dispatch on public.notifications;
create trigger notifications_dispatch after insert on public.notifications
  for each row execute function private.notification_dispatch();

-- -----------------------------------------------------------------------------
-- 5) Nachrichten benachrichtigen die Gegenseite (Kategorie message)
-- -----------------------------------------------------------------------------
-- Bestehend: notify_partner_message meldet dem Hausbesitzer Partner-Nachrichten im allgemeinen Gespräch.
-- Neu: Partner-Nachrichten im Auftragsgespräch an den Hausbesitzer; Nachrichten des Hausbesitzers an den Partner
-- (Leitung/Disposition und den zugewiesenen Mitarbeiter).
create or replace function private.notify_owner_message()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_sp    public.service_partners;
  v_order public.service_orders;
  v_owner boolean;
begin
  if new.sender_user_id is null then return null; end if;
  select o.* into v_order from public.service_orders o where o.id = new.service_order_id;
  select sp.* into v_sp from public.service_partners sp where sp.id = coalesce(new.service_partner_id, v_order.service_partner_id);
  if v_sp.id is null or v_sp.partner_organization_id is null or v_sp.partner_organization_id = new.organization_id then return null; end if;
  v_owner := exists (select 1 from public.organization_members m where m.organization_id = new.organization_id and m.user_id = new.sender_user_id and m.status = 'active');
  if v_owner then
    insert into public.notifications (organization_id, user_id, type, category, title, message, entity_type, entity_id)
    select v_sp.partner_organization_id, m.user_id, 'message', 'message',
           'Neue Nachricht von ' || coalesce((select o.name from public.organizations o where o.id = new.organization_id), 'deinem Kunden'),
           left(new.message, 200), case when new.service_order_id is not null then 'service_order' else 'service_partner' end,
           coalesce(new.service_order_id, new.service_partner_id)
    from public.organization_members m
    where m.organization_id = v_sp.partner_organization_id and m.status = 'active'
      and (m.role in ('admin', 'service_manager', 'dispatcher') or m.user_id = v_order.assigned_user_id);
  elsif new.service_partner_id is null and new.service_order_id is not null then
    insert into public.notifications (organization_id, user_id, type, category, title, message, entity_type, entity_id)
    select new.organization_id, m.user_id, 'message', 'message', 'Neue Nachricht von ' || coalesce(v_sp.company_name, 'deinem Servicepartner'),
           left(new.message, 200), 'service_order', new.service_order_id
    from public.organization_members m
    where m.organization_id = new.organization_id and m.status = 'active' and m.role in ('admin', 'property_manager', 'service_manager');
  end if;
  return null;
exception when others then
  raise warning 'Nachrichten-Benachrichtigung fehlgeschlagen: %', sqlerrm;
  return null;
end; $$;
drop trigger if exists messages_notify_owner on public.messages;
create trigger messages_notify_owner after insert on public.messages
  for each row execute function private.notify_owner_message();

-- -----------------------------------------------------------------------------
-- 6) Chat-Anhänge: Dokument oder Foto desselben Auftrags
-- -----------------------------------------------------------------------------
alter table public.messages
  add column if not exists document_id uuid references public.documents(id) on delete set null,
  add column if not exists photo_id    uuid references public.photos(id) on delete set null;
create index if not exists messages_document_idx on public.messages (document_id) where document_id is not null;
create index if not exists messages_photo_idx on public.messages (photo_id) where photo_id is not null;
create or replace function private.messages_attachment_check()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.document_id is not null and (new.service_order_id is null or not exists (
       select 1 from public.documents d where d.id = new.document_id and d.service_order_id = new.service_order_id)) then
    raise exception 'Anhänge nur aus demselben Auftrag' using errcode = '22023';
  end if;
  if new.photo_id is not null and (new.service_order_id is null or not exists (
       select 1 from public.photos p where p.id = new.photo_id and p.service_order_id = new.service_order_id)) then
    raise exception 'Anhänge nur aus demselben Auftrag' using errcode = '22023';
  end if;
  return new;
end; $$;
drop trigger if exists messages_attachment_check on public.messages;
create trigger messages_attachment_check before insert or update of document_id, photo_id on public.messages
  for each row execute function private.messages_attachment_check();
-- bestehende Installationen: Standardwert nachziehen
alter table public.notification_preferences alter column user_id set default private.current_user_id();
