-- =============================================================================
-- HUSORA · Legal & Beta Compliance (Spezifikation „Husora Legal & Beta Compliance“ v1.0)
-- =============================================================================
-- Technisch umgesetzt / juristische Prüfung offen. Enthält:
--   1) Admin-Rollen (super/support/content/security) + MFA-Pflicht (aal2) für Admin-Funktionen
--   2) Rechtstexte mit Versionen + Zustimmungen, editierbares Impressum (app_config 'imprint')
--   3) Einwilligungen (Consent-Log) – Analytics nur nach Einwilligung (serverseitig erzwungen)
--   4) Servicepartner-Nachweisstatus (nicht geprüft … verifiziert nur durch Admin)
--   5) Bewertungen melden/moderieren
--   6) Datenschutz-Anfragen (Auskunft, Löschung …) mit Admin-Workflow
--   7) Datenpannen-Prozess (security_incidents)
--   8) Sicherheits-Audit-Log (Login, Rechte, Dokumente, Freigaben, Admin-Aktionen, Löschung, Export)
--   9) Zentrale Aufbewahrungsregeln (retention_rules), Bereinigung liest daraus
--  10) Interne Verzeichnisse: Drittanbieter, Verarbeitungstätigkeiten, KI-Systeme
--  11) Datenexport (export_my_data), Release-Gate (release_gate)
--  12) Storage: Dateityp-Allowlist für husora-private
-- Idempotent.

-- -----------------------------------------------------------------------------
-- 1) Admin-Rollen + MFA
-- -----------------------------------------------------------------------------
alter table public.users add column if not exists admin_roles text[] not null default '{}';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'users_admin_roles_check') then
    alter table public.users add constraint users_admin_roles_check
      check (admin_roles <@ array['super_admin', 'support_admin', 'content_admin', 'security_admin']);
  end if;
end $$;
-- bestehende Super-Admins übernehmen die Rolle super_admin
update public.users set admin_roles = array_append(admin_roles, 'super_admin') where is_super_admin and not ('super_admin' = any (admin_roles));

insert into public.app_config (key, value) values ('security', '{"require_admin_mfa": true}') on conflict (key) do nothing;

-- Rolle + (falls verlangt) zweiter Faktor in der aktuellen Sitzung
create or replace function private.has_admin_role(p_role text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.users u
    where u.auth_user_id = auth.uid()
      and (u.is_super_admin or 'super_admin' = any (u.admin_roles) or p_role = any (u.admin_roles))
  )
  and (coalesce((select (c.value ->> 'require_admin_mfa')::boolean from public.app_config c where c.key = 'security'), true) = false
       or coalesce(auth.jwt() ->> 'aal', '') = 'aal2')
$$;
create or replace function private.is_any_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select private.has_admin_role('support_admin') or private.has_admin_role('content_admin') or private.has_admin_role('security_admin')
$$;

-- Rolleninfo für die App (inkl. Hinweis, ob MFA fehlt)
create or replace function public.my_admin_status()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'roles', coalesce((select case when u.is_super_admin and not ('super_admin' = any (u.admin_roles)) then array_append(u.admin_roles, 'super_admin') else u.admin_roles end
                       from public.users u where u.auth_user_id = auth.uid()), '{}'),
    'aal', coalesce(auth.jwt() ->> 'aal', 'aal1'),
    'mfa_required', coalesce((select (c.value ->> 'require_admin_mfa')::boolean from public.app_config c where c.key = 'security'), true))
$$;
revoke all on function public.my_admin_status() from public, anon;
grant execute on function public.my_admin_status() to authenticated;

-- Admin-Rollen nur durch Super-Admins änderbar (bestehender Schutz erweitert)
create or replace function private.protect_user_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and current_user not in ('postgres', 'supabase_admin') then
    new.is_super_admin := old.is_super_admin;
    new.auth_user_id := old.auth_user_id;
    if not private.has_admin_role('super_admin') then
      new.is_beta_user := old.is_beta_user;
      new.beta_started_at := old.beta_started_at;
      new.beta_group := old.beta_group;
      new.admin_roles := old.admin_roles;
    end if;
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 8) Sicherheits-Audit-Log (früh angelegt, andere Teile schreiben hinein)
-- -----------------------------------------------------------------------------
create table if not exists public.security_audit_log (
  id               uuid primary key default gen_random_uuid(),
  event_type       text not null check (event_type in ('user_login', 'permission_change', 'document_access', 'document_delete', 'access_grant',
                                                       'access_revoke', 'admin_action', 'account_delete', 'data_export', 'service_assignment')),
  actor_user_id    uuid references public.users(id) on update cascade on delete set null,
  organization_id  uuid references public.organizations(id) on delete set null,
  entity_type      text check (entity_type is null or length(entity_type) <= 60),
  entity_id        uuid,
  metadata         jsonb not null default '{}'::jsonb check (pg_column_size(metadata) <= 2000),
  created_at       timestamptz not null default now()
);
comment on table public.security_audit_log is 'Sicherheitsrelevante Aktionen ohne Inhalte (Spezifikation §36). Lesen nur security_admin.';
create index if not exists sal_created_idx on public.security_audit_log (created_at desc);
create index if not exists sal_event_idx on public.security_audit_log (event_type, created_at desc);
create index if not exists sal_actor_idx on public.security_audit_log (actor_user_id) where actor_user_id is not null;
create index if not exists sal_org_idx on public.security_audit_log (organization_id) where organization_id is not null;
alter table public.security_audit_log enable row level security;
drop policy if exists sal_select on public.security_audit_log;
create policy sal_select on public.security_audit_log for select to authenticated using ((select private.has_admin_role('security_admin')));
revoke all on public.security_audit_log from anon, authenticated;
grant select on public.security_audit_log to authenticated;

create or replace function private.log_security_event(p_event text, p_org uuid, p_entity_type text, p_entity_id uuid, p_metadata jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.security_audit_log (event_type, actor_user_id, organization_id, entity_type, entity_id, metadata)
  values (p_event, private.current_user_id(), p_org, p_entity_type, p_entity_id, coalesce(p_metadata, '{}'::jsonb));
exception when others then
  raise warning 'Audit-Eintrag % nicht gespeichert: %', p_event, sqlerrm;
end; $$;

-- vom Client meldbar (Login, Dokument geöffnet) – begrenzt, Organisation nur bei Mitgliedschaft
create or replace function public.log_client_security_event(p_event text, p_entity_type text default null, p_entity_id uuid default null, p_organization_id uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  if private.current_user_id() is null or p_event not in ('user_login', 'document_access') then return; end if;
  select count(*) into v_count from public.security_audit_log l where l.actor_user_id = private.current_user_id() and l.created_at > now() - interval '1 hour';
  if v_count >= 200 then return; end if;
  perform private.log_security_event(p_event, case when p_organization_id is not null and private.is_org_member(p_organization_id) then p_organization_id end,
                                     left(p_entity_type, 60), p_entity_id);
end; $$;
revoke all on function public.log_client_security_event(text, text, uuid, uuid) from public, anon;
grant execute on function public.log_client_security_event(text, text, uuid, uuid) to authenticated;

-- Trigger: Rechte, Dokument gelöscht, Freigaben, Zuordnungen, Konfiguration
create or replace function private.audit_security_rows()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'organization_members' then
    if tg_op = 'INSERT' or new.role is distinct from old.role or new.status is distinct from old.status then
      perform private.log_security_event('permission_change', new.organization_id, 'organization_member', new.id,
        jsonb_build_object('role', new.role, 'status', new.status, 'old_role', case when tg_op = 'UPDATE' then old.role end));
    end if;
  elsif tg_table_name = 'documents' then
    perform private.log_security_event('document_delete', old.organization_id, 'document', old.id, jsonb_build_object('type', old.document_type));
  elsif tg_table_name = 'order_access_shares' then
    if tg_op = 'INSERT' then
      perform private.log_security_event('access_grant', new.organization_id, 'service_order', new.service_order_id, jsonb_build_object('valid_until', new.valid_until));
    elsif new.revoked_at is not null and old.revoked_at is null then
      perform private.log_security_event('access_revoke', new.organization_id, 'service_order', new.service_order_id);
    end if;
  elsif tg_table_name = 'property_service_assignments' then
    perform private.log_security_event(case when tg_op = 'UPDATE' and new.status = 'ended' then 'access_revoke' else 'service_assignment' end,
      new.organization_id, 'property', new.property_id, jsonb_build_object('level', new.access_level, 'status', new.status));
  elsif tg_table_name = 'app_config' then
    perform private.log_security_event('admin_action', null, 'app_config', null, jsonb_build_object('key', new.key));
  end if;
  return null;
end; $$;
drop trigger if exists organization_members_security_audit on public.organization_members;
create trigger organization_members_security_audit after insert or update of role, status on public.organization_members
  for each row execute function private.audit_security_rows();
drop trigger if exists documents_security_audit on public.documents;
create trigger documents_security_audit after delete on public.documents
  for each row execute function private.audit_security_rows();
drop trigger if exists order_access_shares_security_audit on public.order_access_shares;
create trigger order_access_shares_security_audit after insert or update of revoked_at on public.order_access_shares
  for each row execute function private.audit_security_rows();
drop trigger if exists psa_security_audit on public.property_service_assignments;
create trigger psa_security_audit after insert or update of status, access_level on public.property_service_assignments
  for each row execute function private.audit_security_rows();
drop trigger if exists app_config_security_audit on public.app_config;
create trigger app_config_security_audit after update on public.app_config
  for each row execute function private.audit_security_rows();

-- app_config: Schreibrechte je Schlüssel nach Rolle (Impressum/Rechtliches = content_admin, Rest = super_admin)
drop policy if exists app_config_write on public.app_config;
create policy app_config_write on public.app_config for update to authenticated
  using (case when key in ('imprint') then private.has_admin_role('content_admin') else private.has_admin_role('super_admin') end)
  with check (case when key in ('imprint') then private.has_admin_role('content_admin') else private.has_admin_role('super_admin') end);

-- Bestehende Admin-Rechte auf Rollen + MFA umstellen (Least Privilege)
drop policy if exists app_feedback_select on public.app_feedback;
create policy app_feedback_select on public.app_feedback for select to authenticated
  using (auth_user_id = (select auth.uid()) or (select private.has_admin_role('support_admin')));
drop policy if exists app_feedback_update on public.app_feedback;
create policy app_feedback_update on public.app_feedback for update to authenticated
  using ((select private.has_admin_role('support_admin'))) with check ((select private.has_admin_role('support_admin')));
drop policy if exists beta_ratings_select on public.beta_ratings;
create policy beta_ratings_select on public.beta_ratings for select to authenticated
  using (user_id = (select private.current_user_id()) or (select private.has_admin_role('support_admin')));
drop policy if exists analytics_events_select on public.analytics_events;
create policy analytics_events_select on public.analytics_events for select to authenticated
  using ((select private.has_admin_role('super_admin')));

-- Beta-Dashboard: Super-Admin oder Support (Support sieht Kennzahlen, aber keine privaten Dokumente)
do $$
declare v_src text;
begin
  select pg_get_functiondef('public.beta_dashboard()'::regprocedure) into v_src;
  v_src := replace(v_src, 'if not private.is_super_admin() then', 'if not (private.has_admin_role(''super_admin'') or private.has_admin_role(''support_admin'')) then');
  execute v_src;
end $$;

-- -----------------------------------------------------------------------------
-- 2) Rechtstexte, Versionen, Zustimmungen, Impressum
-- -----------------------------------------------------------------------------
create table if not exists public.legal_documents (
  id                   uuid primary key default gen_random_uuid(),
  document_type        text not null check (document_type in ('imprint', 'privacy', 'terms', 'beta_terms', 'partner_rules', 'liability', 'review_rules', 'ai_transparency')),
  version              text not null check (length(version) between 1 and 40),
  title                text not null check (length(title) between 1 and 160),
  content              text check (content is null or length(content) <= 200000),
  requires_acceptance  boolean not null default false,
  published_at         timestamptz,
  effective_from       date not null default current_date,
  created_by           uuid references public.users(id) on update cascade on delete set null,
  created_at           timestamptz not null default now(),
  unique (document_type, version)
);
comment on table public.legal_documents is 'Rechtstexte mit Version (Inhalt null = Fassung ist in der App hinterlegt). Entwurf – juristische Prüfung offen.';
create index if not exists legal_documents_type_idx on public.legal_documents (document_type, published_at desc);
alter table public.legal_documents enable row level security;
drop policy if exists legal_documents_select on public.legal_documents;
create policy legal_documents_select on public.legal_documents for select to anon, authenticated
  using (published_at is not null or private.has_admin_role('content_admin'));
drop policy if exists legal_documents_write on public.legal_documents;
create policy legal_documents_write on public.legal_documents for all to authenticated
  using (private.has_admin_role('content_admin')) with check (private.has_admin_role('content_admin'));
revoke all on public.legal_documents from anon, authenticated;
grant select on public.legal_documents to anon, authenticated;
grant insert, update on public.legal_documents to authenticated;

insert into public.legal_documents (document_type, version, title, requires_acceptance, published_at, effective_from) values
  ('imprint', '2026-11-02', 'Impressum', false, now(), '2026-11-02'),
  ('privacy', '2026-11-02', 'Datenschutzerklärung', false, now(), '2026-11-02'),
  ('terms', '2026-11-02', 'Nutzungsbedingungen / AGB', true, now(), '2026-11-02'),
  ('beta_terms', '2026-11-02', 'Husora Beta – Bedingungen', true, now(), '2026-11-02'),
  ('partner_rules', '2026-11-02', 'Regeln für Servicepartner', false, now(), '2026-11-02'),
  ('liability', '2026-11-02', 'Haftungs- und Prüfhinweise', false, now(), '2026-11-02'),
  ('review_rules', '2026-11-02', 'Regeln für Bewertungen', false, now(), '2026-11-02'),
  ('ai_transparency', '2026-11-02', 'KI- und Übersetzungstransparenz', false, now(), '2026-11-02')
on conflict (document_type, version) do nothing;

create table if not exists public.legal_acceptances (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default private.current_user_id() references public.users(id) on update cascade on delete cascade,
  document_type  text not null,
  version        text not null,
  accepted_at    timestamptz not null default now(),
  source         text check (source is null or length(source) <= 40),
  unique (user_id, document_type, version)
);
create index if not exists legal_acceptances_user_idx on public.legal_acceptances (user_id, document_type);
alter table public.legal_acceptances enable row level security;
drop policy if exists legal_acceptances_own on public.legal_acceptances;
create policy legal_acceptances_own on public.legal_acceptances for select to authenticated
  using (user_id = (select private.current_user_id()) or (select private.has_admin_role('support_admin')));
drop policy if exists legal_acceptances_insert on public.legal_acceptances;
create policy legal_acceptances_insert on public.legal_acceptances for insert to authenticated
  with check (user_id = (select private.current_user_id())
              and exists (select 1 from public.legal_documents d where d.document_type = legal_acceptances.document_type and d.version = legal_acceptances.version and d.published_at is not null));
revoke all on public.legal_acceptances from anon, authenticated;
grant select, insert on public.legal_acceptances to authenticated;

-- Welche zustimmungspflichtigen Fassungen fehlen dem Nutzer noch?
create or replace function public.my_pending_legal()
returns table (document_type text, version text, title text)
language sql stable security definer set search_path = ''
as $$
  select d.document_type, d.version, d.title
  from (select distinct on (document_type) * from public.legal_documents
        where published_at is not null and effective_from <= current_date order by document_type, effective_from desc, published_at desc) d
  where d.requires_acceptance and private.current_user_id() is not null
    and not exists (select 1 from public.legal_acceptances a where a.user_id = private.current_user_id() and a.document_type = d.document_type and a.version = d.version)
$$;
revoke all on function public.my_pending_legal() from public, anon;
grant execute on function public.my_pending_legal() to authenticated;

-- Impressum: nur echte Angaben; leere Felder bleiben als Platzhalter sichtbar
insert into public.app_config (key, value) values ('imprint', '{"operator": null, "company": null, "legal_form": null, "address": null, "email": null, "phone": null, "representatives": null, "register": null, "register_court": null, "vat_id": null, "other": null}')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- 3) Einwilligungen
-- -----------------------------------------------------------------------------
create table if not exists public.consent_log (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default private.current_user_id() references public.users(id) on update cascade on delete cascade,
  purpose       text not null check (purpose in ('analytics', 'marketing', 'external_content')),
  version       text not null check (length(version) <= 40),
  accepted      boolean not null,
  created_at    timestamptz not null default now(),
  withdrawn_at  timestamptz,
  source        text check (source is null or length(source) <= 40)
);
comment on table public.consent_log is 'Einwilligungen je Zweck (notwendige Verarbeitung braucht keine Einwilligung und steht hier nicht)';
create index if not exists consent_log_user_idx on public.consent_log (user_id, purpose, created_at desc);
alter table public.consent_log enable row level security;
drop policy if exists consent_log_own on public.consent_log;
create policy consent_log_own on public.consent_log for select to authenticated using (user_id = (select private.current_user_id()));
drop policy if exists consent_log_insert on public.consent_log;
create policy consent_log_insert on public.consent_log for insert to authenticated with check (user_id = (select private.current_user_id()));
revoke all on public.consent_log from anon, authenticated;
grant select, insert on public.consent_log to authenticated;
-- frühere Einträge beim Widerruf/Neuentscheid als erledigt markieren
create or replace function private.consent_close_previous()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.consent_log set withdrawn_at = now()
  where user_id = new.user_id and purpose = new.purpose and id <> new.id and withdrawn_at is null and accepted;
  return null;
end; $$;
drop trigger if exists consent_close_previous on public.consent_log;
create trigger consent_close_previous after insert on public.consent_log
  for each row execute function private.consent_close_previous();

create or replace function private.has_consent(p_user uuid, p_purpose text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select c.accepted from public.consent_log c where c.user_id = p_user and c.purpose = p_purpose order by c.created_at desc limit 1), false)
$$;

-- Analytics nur nach Einwilligung: Client-Ereignisse werden ohne Einwilligung verworfen
do $$
declare v_src text;
begin
  select pg_get_functiondef('public.track_events(jsonb,uuid)'::regprocedure) into v_src;
  if position('has_consent' in v_src) = 0 then
    v_src := replace(v_src, 'if not private.beta_config(''analytics'') then return 0; end if;',
      'if not private.beta_config(''analytics'') then return 0; end if;
  if not private.has_consent(v_user, ''analytics'') then return 0; end if;  -- Einwilligung (TDDDG/DSGVO)');
    execute v_src;
  end if;
end $$;
-- Server-Ereignisse (Prozessschritte) ebenfalls nur bei Einwilligung des Handelnden; Registrierung ohne Personenbezug
create or replace function private.track_server_event(p_event text, p_user uuid, p_org uuid, p_entity_type text, p_entity_id uuid, p_metadata jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.beta_config('analytics') then return; end if;
  if p_user is not null and not private.has_consent(p_user, 'analytics') then
    -- ohne Einwilligung nur anonymer Zähler (ohne Nutzer, ohne Objekt-ID)
    insert into public.analytics_events (organization_id, user_id, event_name, entity_type, app_role, source, metadata)
    values (null, null, p_event, p_entity_type, 'system', 'server', '{}'::jsonb);
    return;
  end if;
  insert into public.analytics_events (organization_id, user_id, event_name, entity_type, entity_id, app_role, source, metadata)
  values (p_org, p_user, p_event, p_entity_type, p_entity_id, 'system', 'server', coalesce(p_metadata, '{}'::jsonb))
  on conflict do nothing;
exception when others then
  raise warning 'Analytics-Ereignis % nicht gespeichert: %', p_event, sqlerrm;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4) Servicepartner: Nachweisstatus (verifiziert nur über definierten Admin-Prozess)
-- -----------------------------------------------------------------------------
alter table public.organizations
  add column if not exists verification_status text not null default 'not_checked',
  add column if not exists verification_note   text,
  add column if not exists verified_at         timestamptz,
  add column if not exists verification_expires_at date;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'organizations_verification_status_check') then
    alter table public.organizations add constraint organizations_verification_status_check
      check (verification_status in ('not_checked', 'in_review', 'verified', 'rejected', 'expired')
             and (verification_note is null or length(verification_note) <= 1000));
  end if;
end $$;
-- Betrieb selbst kann den Status nicht setzen
create or replace function private.protect_verification()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_system_context() and not private.has_admin_role('content_admin') then
    new.verification_status := old.verification_status; new.verification_note := old.verification_note;
    new.verified_at := old.verified_at; new.verification_expires_at := old.verification_expires_at;
  end if;
  return new;
end; $$;
drop trigger if exists organizations_protect_verification on public.organizations;
create trigger organizations_protect_verification before update of verification_status, verification_note, verified_at, verification_expires_at on public.organizations
  for each row execute function private.protect_verification();

create or replace function public.set_partner_verification(p_organization_id uuid, p_status text, p_note text default null, p_expires date default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.has_admin_role('content_admin') then raise exception 'Nur für das Husora-Team' using errcode = '42501'; end if;
  if p_status not in ('not_checked', 'in_review', 'verified', 'rejected', 'expired') then raise exception 'Ungültiger Status' using errcode = '22023'; end if;
  if p_status = 'verified' and nullif(trim(p_note), '') is null then raise exception 'Bitte den geprüften Nachweis beschreiben' using errcode = '22023'; end if;
  update public.organizations set verification_status = p_status, verification_note = left(nullif(trim(p_note), ''), 1000),
         verified_at = case when p_status = 'verified' then now() end, verification_expires_at = p_expires
  where id = p_organization_id and org_type in ('service_partner', 'both');
  perform private.log_security_event('admin_action', p_organization_id, 'partner_verification', p_organization_id, jsonb_build_object('status', p_status));
end; $$;
revoke all on function public.set_partner_verification(uuid, text, text, date) from public, anon;
grant execute on function public.set_partner_verification(uuid, text, text, date) to authenticated;

-- Abgelaufene Nachweise
create or replace function private.expire_verifications()
returns void language sql security definer set search_path = '' as $$
  update public.organizations set verification_status = 'expired'
  where verification_status = 'verified' and verification_expires_at is not null and verification_expires_at < current_date;
$$;

-- Nachweisstatus für die Partnerauswahl des Hausbesitzers
drop function if exists public.partner_directory_facts();
create or replace function public.partner_directory_facts()
returns table (service_partner_id uuid, emergency_service boolean, rating_avg numeric, rating_count integer, verification_status text)
language sql stable security definer set search_path = '' as $$
  select sp.id, coalesce(po.emergency_service, false), po.rating_avg, coalesce(po.rating_count, 0), coalesce(po.verification_status, 'not_checked')
  from public.service_partners sp left join public.organizations po on po.id = sp.partner_organization_id
  where private.is_org_member(sp.organization_id)
$$;
revoke all on function public.partner_directory_facts() from public, anon;
grant execute on function public.partner_directory_facts() to authenticated;

-- -----------------------------------------------------------------------------
-- 5) Bewertungen melden / moderieren
-- -----------------------------------------------------------------------------
alter table public.service_partner_reviews
  add column if not exists moderation_status text not null default 'visible',
  add column if not exists moderated_at      timestamptz,
  add column if not exists moderated_by      uuid references public.users(id) on update cascade on delete set null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'spr_moderation_status_check') then
    alter table public.service_partner_reviews add constraint spr_moderation_status_check check (moderation_status in ('visible', 'under_review', 'hidden'));
  end if;
end $$;
create table if not exists public.review_reports (
  id           uuid primary key default gen_random_uuid(),
  review_id    uuid not null references public.service_partner_reviews(id) on delete cascade,
  reported_by  uuid default private.current_user_id() references public.users(id) on update cascade on delete set null,
  reason       text not null check (reason in ('insult', 'false_claim', 'fake', 'manipulation', 'revenge', 'other')),
  note         text check (note is null or length(note) <= 1000),
  status       text not null default 'open' check (status in ('open', 'upheld', 'dismissed')),
  decided_by   uuid references public.users(id) on update cascade on delete set null,
  decided_at   timestamptz,
  created_at   timestamptz not null default now(),
  unique (review_id, reported_by)
);
create index if not exists review_reports_review_idx on public.review_reports (review_id);
create index if not exists review_reports_status_idx on public.review_reports (status, created_at desc);
alter table public.review_reports enable row level security;
drop policy if exists review_reports_select on public.review_reports;
create policy review_reports_select on public.review_reports for select to authenticated
  using (reported_by = (select private.current_user_id()) or (select private.has_admin_role('content_admin')));
revoke all on public.review_reports from anon, authenticated;
grant select on public.review_reports to authenticated;

create or replace function public.report_review(p_review_id uuid, p_reason text, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_r public.service_partner_reviews;
begin
  select * into v_r from public.service_partner_reviews r where r.id = p_review_id;
  if v_r.id is null or not (private.can_read_org(v_r.organization_id) or private.is_partner_member(v_r.service_partner_id)) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  insert into public.review_reports (review_id, reason, note) values (v_r.id, p_reason, left(nullif(trim(p_note), ''), 1000))
  on conflict (review_id, reported_by) do update set reason = excluded.reason, note = excluded.note, status = 'open';
  update public.service_partner_reviews set moderation_status = 'under_review' where id = v_r.id and moderation_status = 'visible';
end; $$;
revoke all on function public.report_review(uuid, text, text) from public, anon;
grant execute on function public.report_review(uuid, text, text) to authenticated;

create or replace function public.moderate_review(p_review_id uuid, p_status text, p_report_decision text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.has_admin_role('content_admin') then raise exception 'Nur für das Husora-Team' using errcode = '42501'; end if;
  if p_status not in ('visible', 'hidden') then raise exception 'Ungültiger Status' using errcode = '22023'; end if;
  update public.service_partner_reviews set moderation_status = p_status, moderated_at = now(), moderated_by = private.current_user_id() where id = p_review_id;
  update public.review_reports set status = coalesce(p_report_decision, case when p_status = 'hidden' then 'upheld' else 'dismissed' end),
         decided_by = private.current_user_id(), decided_at = now()
  where review_id = p_review_id and status = 'open';
  perform private.log_security_event('admin_action', null, 'review', p_review_id, jsonb_build_object('status', p_status));
end; $$;
revoke all on function public.moderate_review(uuid, text, text) from public, anon;
grant execute on function public.moderate_review(uuid, text, text) to authenticated;

-- Ausgeblendete Bewertungen zählen nicht und sind nur für Beteiligte/Moderation sichtbar
create or replace function private.review_aggregate()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_porg uuid;
  v_avg  numeric;
  v_n    integer;
begin
  select sp.partner_organization_id into v_porg from public.service_partners sp where sp.id = coalesce(new.service_partner_id, old.service_partner_id);
  if v_porg is null then
    update public.service_partners sp set rating = (select round(avg(r.rating)::numeric, 2) from public.service_partner_reviews r where r.service_partner_id = sp.id and r.moderation_status <> 'hidden')
    where sp.id = coalesce(new.service_partner_id, old.service_partner_id);
    return null;
  end if;
  select round(avg(r.rating)::numeric, 2), count(*) into v_avg, v_n
  from public.service_partner_reviews r join public.service_partners sp on sp.id = r.service_partner_id
  where sp.partner_organization_id = v_porg and r.moderation_status <> 'hidden';
  update public.organizations set rating_avg = v_avg, rating_count = v_n where id = v_porg;
  update public.service_partners set rating = v_avg where partner_organization_id = v_porg;
  return null;
end; $$;
drop trigger if exists review_aggregate on public.service_partner_reviews;
create trigger review_aggregate after insert or update of rating, moderation_status or delete on public.service_partner_reviews
  for each row execute function private.review_aggregate();
-- Moderationsspalten nicht durch Beteiligte änderbar (Spaltenrechte: nur rating/comment)
drop policy if exists spr_select on public.service_partner_reviews;
create policy spr_select on public.service_partner_reviews for select to authenticated
  using (private.can_read_org(organization_id) or private.is_partner_member(service_partner_id) or private.has_admin_role('content_admin'));

-- -----------------------------------------------------------------------------
-- 6) Datenschutz-Anfragen
-- -----------------------------------------------------------------------------
create table if not exists public.privacy_requests (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid default private.current_user_id() references public.users(id) on update cascade on delete set null,
  request_type  text not null check (request_type in ('access', 'rectification', 'erasure', 'restriction', 'objection', 'portability')),
  message       text check (message is null or length(message) <= 4000),
  status        text not null default 'new' check (status in ('new', 'verified', 'in_progress', 'completed', 'rejected')),
  handled_by    uuid references public.users(id) on update cascade on delete set null,
  handler_note  text check (handler_note is null or length(handler_note) <= 2000),
  due_at        date not null default (current_date + 30),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.privacy_requests is 'Betroffenenanfragen (Art. 15–21 DSGVO) mit Bearbeitungsstatus; Frist-Hinweis 1 Monat (Art. 12 Abs. 3)';
create index if not exists privacy_requests_status_idx on public.privacy_requests (status, created_at);
create index if not exists privacy_requests_user_idx on public.privacy_requests (user_id) where user_id is not null;
drop trigger if exists privacy_requests_set_updated_at on public.privacy_requests;
create trigger privacy_requests_set_updated_at before update on public.privacy_requests for each row execute function private.set_updated_at();
alter table public.privacy_requests enable row level security;
drop policy if exists privacy_requests_select on public.privacy_requests;
create policy privacy_requests_select on public.privacy_requests for select to authenticated
  using (user_id = (select private.current_user_id()) or (select private.has_admin_role('support_admin')));
drop policy if exists privacy_requests_insert on public.privacy_requests;
create policy privacy_requests_insert on public.privacy_requests for insert to authenticated
  with check (user_id = (select private.current_user_id()) and status = 'new');
drop policy if exists privacy_requests_update on public.privacy_requests;
create policy privacy_requests_update on public.privacy_requests for update to authenticated
  using ((select private.has_admin_role('support_admin'))) with check ((select private.has_admin_role('support_admin')));
revoke all on public.privacy_requests from anon, authenticated;
grant select, insert on public.privacy_requests to authenticated;
grant update (status, handled_by, handler_note) on public.privacy_requests to authenticated;

-- -----------------------------------------------------------------------------
-- 7) Datenpannen (Bewertung der Meldepflicht bleibt eine rechtliche Entscheidung)
-- -----------------------------------------------------------------------------
create table if not exists public.security_incidents (
  id                     uuid primary key default gen_random_uuid(),
  title                  text not null check (length(title) between 1 and 200),
  detected_at            timestamptz not null default now(),
  affected_system        text check (affected_system is null or length(affected_system) <= 200),
  affected_data          text check (affected_data is null or length(affected_data) <= 1000),
  severity               text not null default 'medium' check (severity in ('low', 'medium', 'high', 'critical')),
  affected_users         integer check (affected_users is null or affected_users >= 0),
  containment            text check (containment is null or length(containment) <= 2000),
  notification_required  text not null default 'to_assess' check (notification_required in ('to_assess', 'yes', 'no')),
  assessment_note        text check (assessment_note is null or length(assessment_note) <= 2000),
  authority_notified_at  timestamptz,
  resolved_at            timestamptz,
  created_by             uuid default private.current_user_id() references public.users(id) on update cascade on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
comment on table public.security_incidents is 'Datenpannen-Prozess (Art. 33/34 DSGVO: Bewertung binnen 72 h durch Verantwortlichen) – keine automatische Aussage zur Meldepflicht';
drop trigger if exists security_incidents_set_updated_at on public.security_incidents;
create trigger security_incidents_set_updated_at before update on public.security_incidents for each row execute function private.set_updated_at();
alter table public.security_incidents enable row level security;
drop policy if exists security_incidents_all on public.security_incidents;
create policy security_incidents_all on public.security_incidents for all to authenticated
  using ((select private.has_admin_role('security_admin'))) with check ((select private.has_admin_role('security_admin')));
revoke all on public.security_incidents from anon, authenticated;
grant select, insert, update on public.security_incidents to authenticated;

-- -----------------------------------------------------------------------------
-- 9) Zentrale Aufbewahrungsregeln
-- -----------------------------------------------------------------------------
create table if not exists public.retention_rules (
  data_type         text primary key,
  retention_period  interval,
  reason            text not null,
  deletion_method   text not null check (deletion_method in ('delete', 'anonymize', 'on_account_delete', 'manual_review')),
  legal_hold        boolean not null default false,
  category          text not null check (category in ('legal', 'product', 'security')),
  legal_review_open boolean not null default true,
  updated_at        timestamptz not null default now()
);
comment on table public.retention_rules is 'Aufbewahrung je Datentyp; gesetzliche Pflichten (legal_hold) getrennt von Produktdaten. Juristische Prüfung offen.';
insert into public.retention_rules (data_type, retention_period, reason, deletion_method, legal_hold, category) values
  ('analytics_events', '13 months', 'Beta-Auswertung (Zweck: Produktverbesserung)', 'delete', false, 'product'),
  ('beta_ratings', '24 months', 'Beta-Feedback', 'delete', false, 'product'),
  ('app_feedback', '12 months', 'Support und Fehlerbehebung', 'delete', false, 'product'),
  ('ai_suggestions', '24 months', 'Nachvollziehbarkeit von KI-Vorschlägen', 'delete', false, 'product'),
  ('notifications_read', '6 months', 'Benachrichtigungen (gelesen)', 'delete', false, 'product'),
  ('push_subscriptions', '6 months', 'Push-Adresse ohne Nutzung', 'delete', false, 'product'),
  ('stripe_events', '3 months', 'technische Zahlungsereignisse', 'delete', false, 'product'),
  ('security_audit_log', '24 months', 'Nachweis sicherheitsrelevanter Aktionen', 'delete', false, 'security'),
  ('consent_log', null, 'Nachweis von Einwilligungen (Art. 7 Abs. 1 DSGVO) – Dauer der Nutzung + Verjährung, Frist prüfen', 'on_account_delete', false, 'legal'),
  ('invoices', '10 years', 'Buchungsbelege (§ 147 AO, § 257 HGB) – Prüfung offen', 'manual_review', true, 'legal'),
  ('service_orders', null, 'Auftragsnachweis zwischen Hausbesitzer und Partner', 'manual_review', true, 'legal'),
  ('account_data', null, 'Konto und Hausdaten bis zur Löschung durch den Nutzer', 'on_account_delete', false, 'product'),
  ('privacy_requests', '36 months', 'Nachweis der Bearbeitung von Betroffenenanfragen', 'delete', false, 'legal'),
  ('security_incidents', '60 months', 'Dokumentation von Datenpannen (Art. 33 Abs. 5 DSGVO)', 'manual_review', true, 'legal')
on conflict (data_type) do nothing;
alter table public.retention_rules enable row level security;
drop policy if exists retention_rules_select on public.retention_rules;
create policy retention_rules_select on public.retention_rules for select to authenticated using ((select private.is_any_admin()));
drop policy if exists retention_rules_write on public.retention_rules;
create policy retention_rules_write on public.retention_rules for update to authenticated
  using ((select private.has_admin_role('super_admin'))) with check ((select private.has_admin_role('super_admin')));
revoke all on public.retention_rules from anon, authenticated;
grant select, update (retention_period, reason, deletion_method, legal_hold, legal_review_open) on public.retention_rules to authenticated;

create or replace function private.retention_of(p_type text, p_default interval)
returns interval language sql stable security definer set search_path = '' as $$
  select coalesce((select r.retention_period from public.retention_rules r where r.data_type = p_type and not r.legal_hold), p_default)
$$;
create or replace function private.cleanup_retention()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.app_feedback where created_at < now() - private.retention_of('app_feedback', '12 months');
  delete from public.notifications where read_at is not null and read_at < now() - private.retention_of('notifications_read', '6 months');
  delete from public.stripe_events where processed_at < now() - private.retention_of('stripe_events', '3 months');
  delete from public.analytics_events where occurred_at < now() - private.retention_of('analytics_events', '13 months');
  delete from public.beta_ratings where created_at < now() - private.retention_of('beta_ratings', '24 months');
  delete from public.ai_suggestions where created_at < now() - private.retention_of('ai_suggestions', '24 months')
     or (status in ('pending', 'failed') and created_at < now() - interval '30 days');
  delete from public.push_subscriptions where coalesce(last_used_at, created_at) < now() - private.retention_of('push_subscriptions', '6 months');
  delete from public.security_audit_log where created_at < now() - private.retention_of('security_audit_log', '24 months');
  delete from public.privacy_requests where status in ('completed', 'rejected') and updated_at < now() - private.retention_of('privacy_requests', '36 months');
  select private.expire_verifications();
$$;
revoke all on function private.cleanup_retention() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 10) Interne Verzeichnisse (kein Eintrag gilt als „geprüft“, bevor Verträge/Einstellungen geprüft sind)
-- -----------------------------------------------------------------------------
create table if not exists public.third_party_providers (
  key                 text primary key check (key ~ '^[a-z][a-z0-9_]{1,40}$'),
  provider_name       text not null,
  service             text not null,
  purpose             text not null,
  url                 text,
  data_processed      text not null,
  country             text not null,
  cookies             boolean not null default false,
  tracking            boolean not null default false,
  processor_status    text not null check (processor_status in ('processor', 'independent_controller', 'joint_controller', 'to_assess')),
  dpa_status          text not null default 'unknown' check (dpa_status in ('unknown', 'requested', 'signed', 'not_required')),
  transfer_mechanism  text,
  subprocessors       text,
  consent_category    text not null check (consent_category in ('necessary', 'analytics', 'marketing', 'external_content')),
  status              text not null default 'unknown' check (status in ('unknown', 'under_review', 'approved', 'blocked')),
  review_date         date,
  notes               text,
  updated_at          timestamptz not null default now()
);
comment on table public.third_party_providers is 'Drittanbieter-/Auftragsverarbeiter-Register (§8, §27). Status „approved“ erst nach Prüfung von Vertrag und Einstellungen.';
insert into public.third_party_providers (key, provider_name, service, purpose, url, data_processed, country, processor_status, transfer_mechanism, consent_category, status, notes) values
  ('supabase', 'Supabase Inc.', 'Datenbank, Auth, Storage, Edge Functions', 'Husora Cloud (Konten, Häuser, Aufträge, Dateien)', 'https://supabase.com', 'Konto-, Haus-, Auftrags-, Kommunikationsdaten, Dateien', 'Region des Projekts prüfen (EU empfohlen); Unternehmen USA', 'processor', 'DPA + SCC/DPF prüfen', 'necessary', 'under_review', 'Projektregion und DPA prüfen'),
  ('github_pages', 'GitHub Inc. (Microsoft)', 'Hosting der Web-App', 'Auslieferung der App-Dateien', 'https://pages.github.com', 'IP-Adresse, Zugriffsdaten (Server-Logs)', 'USA', 'to_assess', 'DPF/SCC prüfen', 'necessary', 'under_review', 'Für Produktion EU-Hosting erwägen'),
  ('stripe', 'Stripe Payments Europe, Ltd.', 'Zahlungen', 'Abonnements (in der Beta deaktiviert)', 'https://stripe.com', 'Name, E-Mail, Zahlungsdaten, Abo-Status', 'Irland/USA', 'independent_controller', 'SCC/DPF prüfen', 'necessary', 'under_review', 'Zahlungen während der Beta aus'),
  ('resend', 'Resend Inc.', 'E-Mail-Versand', 'Benachrichtigungen per E-Mail (nur nach Einschalten)', 'https://resend.com', 'E-Mail-Adresse, Titel/Kurztext der Benachrichtigung', 'USA', 'processor', 'DPA + SCC/DPF prüfen', 'necessary', 'unknown', 'noch nicht eingerichtet'),
  ('web_push', 'Push-Dienste der Browser (Google FCM, Apple, Mozilla)', 'Web-Push', 'Zustellung von Push-Benachrichtigungen', null, 'Push-Endpunkt, Titel/Kurztext', 'USA/EU je Browser', 'to_assess', 'prüfen', 'necessary', 'unknown', 'Push nur nach Aktivierung durch Nutzer'),
  ('anthropic', 'Anthropic PBC', 'KI-Vorschläge', 'Kontrollbericht, Schadenserkennung, Kostenschätzung', 'https://www.anthropic.com', 'Prüfpunkte, Mangelnotizen, Fotos, Haustyp/Baujahr/Region (keine Namen/Kontakte)', 'USA', 'processor', 'DPA + SCC/DPF prüfen', 'necessary', 'unknown', 'Deaktiviert bis Prüfung; Training mit API-Daten laut Anbieter standardmäßig nicht – prüfen'),
  ('osm_tiles', 'OpenStreetMap Foundation', 'Kartenkacheln', 'Karten anzeigen', 'https://www.openstreetmap.org', 'IP-Adresse, Kartenausschnitt', 'UK/EU', 'independent_controller', 'Angemessenheitsbeschluss UK', 'external_content', 'under_review', 'nur nach Einwilligung „Externe Inhalte“'),
  ('nominatim', 'OpenStreetMap Foundation (Nominatim)', 'Adresssuche', 'Koordinaten zu Adressen', 'https://nominatim.org', 'IP-Adresse, Suchbegriff (Adresse)', 'UK/EU', 'independent_controller', 'Angemessenheitsbeschluss UK', 'external_content', 'under_review', 'nur nach Einwilligung'),
  ('google_maps', 'Google Ireland Ltd.', 'Kartenvorschau / Routen-Link', 'Karte des Objekts, Routenplanung', 'https://maps.google.com', 'IP-Adresse, Koordinaten', 'Irland/USA', 'independent_controller', 'DPF', 'external_content', 'under_review', 'Einbettung nur nach Einwilligung; Links öffnen Google erst beim Klick'),
  ('open_meteo', 'Open-Meteo', 'Wetter', 'Wettervorhersage für Hauskoordinaten', 'https://open-meteo.com', 'IP-Adresse, Koordinaten', 'EU (Schweiz/Deutschland)', 'independent_controller', '–', 'external_content', 'under_review', 'nur nach Einwilligung'),
  ('exchange_rates', 'frankfurter.dev / open.er-api.com', 'Wechselkurse', 'Umrechnung SEK/EUR', null, 'IP-Adresse', 'EU/unbekannt', 'independent_controller', 'prüfen', 'external_content', 'under_review', 'nur nach Einwilligung'),
  ('cdn_libraries', 'cdnjs (Cloudflare), unpkg, jsDelivr', 'Programmbibliotheken', 'pdf.js, Leaflet, Tesseract.js laden', null, 'IP-Adresse', 'USA/weltweit', 'to_assess', 'prüfen', 'necessary', 'under_review', 'Für Produktion Selbst-Hosting erwägen'),
  ('translation', 'Google Übersetzer / MyMemory', 'Maschinelle Übersetzung', 'Schwedische Inseratstexte übersetzen', null, 'IP-Adresse, zu übersetzender Text (Inseratstext)', 'USA/Italien', 'independent_controller', 'prüfen', 'external_content', 'under_review', 'Ergebnis als maschinelle Übersetzung gekennzeichnet'),
  ('listing_import', 'Maklerportale + Weiterleitungen allorigins.win, cors.lol', 'Immobilienimport', 'Inseratsdaten übernehmen', null, 'IP-Adresse, Inserats-URL', 'unbekannt', 'independent_controller', 'prüfen', 'external_content', 'under_review', 'Nutzungsbedingungen/Urheberrecht der Portale prüfen; Weiterleitungsdienste ersetzen'),
  ('repull', 'Repull', 'Buchungsportal-Abgleich', 'Buchungen übernehmen (nur wenn verbunden)', null, 'Buchungsdaten', 'unbekannt', 'to_assess', 'prüfen', 'necessary', 'unknown', 'nur bei aktiver Verbindung')
on conflict (key) do nothing;
alter table public.third_party_providers enable row level security;
drop policy if exists tpp_select on public.third_party_providers;
create policy tpp_select on public.third_party_providers for select to authenticated using ((select private.is_any_admin()));
drop policy if exists tpp_write on public.third_party_providers;
create policy tpp_write on public.third_party_providers for update to authenticated
  using ((select private.has_admin_role('super_admin'))) with check ((select private.has_admin_role('super_admin')));
revoke all on public.third_party_providers from anon, authenticated;
grant select, update (status, dpa_status, review_date, notes) on public.third_party_providers to authenticated;
-- Für die App: nur Schlüssel, Kategorie und ob gesperrt (keine internen Notizen)
create or replace function public.provider_flags()
returns table (key text, consent_category text, blocked boolean)
language sql stable security definer set search_path = '' as $$
  select p.key, p.consent_category, p.status = 'blocked' from public.third_party_providers p
$$;
revoke all on function public.provider_flags() from public;
grant execute on function public.provider_flags() to anon, authenticated;

create table if not exists public.processing_activities (
  key             text primary key,
  name            text not null,
  purpose         text not null,
  data_subjects   text not null,
  data_categories text not null,
  legal_basis     text not null,
  recipients      text,
  retention_ref   text,
  tom_ref         text,
  legal_review_open boolean not null default true,
  updated_at      timestamptz not null default now()
);
comment on table public.processing_activities is 'Verzeichnis von Verarbeitungstätigkeiten (Art. 30 DSGVO) – intern, Entwurf';
insert into public.processing_activities (key, name, purpose, data_subjects, data_categories, legal_basis, recipients, retention_ref, tom_ref) values
  ('account_management', 'Kontoverwaltung', 'Registrierung, Login, Profil, Mitglieder', 'Nutzer', 'Name, E-Mail, Telefon (optional), Login-Daten', 'Art. 6 (1) b', 'supabase', 'account_data', 'RLS, MFA für Admins'),
  ('house_management', 'Hausverwaltung', 'Häuser, Räume, Aufgaben, Kontrollen, Kosten', 'Nutzer, ggf. Gäste in Buchungen', 'Adressen, Hausdaten, Buchungen, Notizen', 'Art. 6 (1) b', 'supabase', 'account_data', 'RLS, Mandantentrennung'),
  ('document_storage', 'Dokumente und Fotos', 'Ablage von Rechnungen, Verträgen, Fotos', 'Nutzer, Dritte auf Dokumenten', 'Dateien, Metadaten', 'Art. 6 (1) b', 'supabase', 'invoices / account_data', 'private Buckets, Typ-/Größenlimit'),
  ('emergency_access', 'Notfall & Zugang', 'Schlüssel-/Zugangsinformationen für Aufträge', 'Nutzer', 'Zugangscodes, Alarm, Schlüsselort', 'Art. 6 (1) b', 'freigegebener Partner (zeitlich begrenzt)', 'account_data', 'explizite, widerrufbare, protokollierte Freigabe'),
  ('service_partner_management', 'Servicepartner', 'Einladung, Verbindung, Kontaktfreigabe, Objektfreigabe', 'Partner, Hausbesitzer', 'Firmendaten, Kontakte, Freigaben', 'Art. 6 (1) b', 'verbundener Partner', 'account_data', 'RLS, Freigabestufen'),
  ('service_requests', 'Serviceanfragen und Aufträge', 'Anfragen, Aufträge, Termine, Nachrichten, Angebote, Rechnungen, Bewertungen', 'Hausbesitzer, Partner, Mitarbeiter', 'Auftrags-, Kosten-, Kommunikationsdaten', 'Art. 6 (1) b', 'Vertragspartner', 'service_orders / invoices', 'RLS, Statusmaschine'),
  ('analytics', 'Beta-Analytics', 'Nutzung messen, Produkt verbessern', 'Nutzer mit Konto', 'Ereignisname, Zeitpunkt, App-Version, Gerätetyp, Rolle', 'Art. 6 (1) a (Einwilligung) – prüfen', 'nur Husora-Team', 'analytics_events', 'Allowlist, keine Inhalte'),
  ('error_reporting', 'Fehlerberichte', 'Fehler beheben', 'Nutzer', 'Fehlermeldung, App-Version, Gerätetyp', 'Art. 6 (1) f', 'nur Husora-Team', 'app_feedback', 'keine Haus-/Buchungsdaten'),
  ('customer_support', 'Support, Feedback, Datenschutz-Anfragen', 'Anfragen beantworten', 'Nutzer', 'Nachricht, E-Mail (optional)', 'Art. 6 (1) b/f, Art. 12 ff.', 'support_admin', 'app_feedback / privacy_requests', 'Rollen, Least Privilege'),
  ('ai_suggestions', 'KI-Vorschläge', 'Kontrollberichte, Schäden, Kosten einschätzen', 'Hausbesitzer, Partner', 'Prüfpunkte, Fotos, Hausmerkmale (keine Namen)', 'Art. 6 (1) b/f – prüfen', 'anthropic', 'ai_suggestions', 'Datenminimierung, Vorschlagsstatus'),
  ('marketing', 'Marketing', 'derzeit keine Verarbeitung', '–', '–', '–', '–', '–', 'nicht aktiv'),
  ('billing', 'Abrechnung Tarife', 'Abonnements (in der Beta deaktiviert)', 'zahlende Nutzer', 'Abo-Status, Kundennummer', 'Art. 6 (1) b, c', 'stripe', 'invoices', 'keine Kartendaten bei Husora')
on conflict (key) do nothing;
alter table public.processing_activities enable row level security;
drop policy if exists pa_select on public.processing_activities;
create policy pa_select on public.processing_activities for select to authenticated using ((select private.is_any_admin()));
revoke all on public.processing_activities from anon, authenticated;
grant select on public.processing_activities to authenticated;

create table if not exists public.ai_register (
  key          text primary key,
  provider     text not null,
  model        text not null,
  purpose      text not null,
  input_data   text not null,
  output_data  text not null,
  retention    text not null,
  training_use text not null,
  location     text not null,
  dpa          text not null,
  transparency text not null,
  updated_at   timestamptz not null default now()
);
insert into public.ai_register (key, provider, model, purpose, input_data, output_data, retention, training_use, location, dpa, transparency) values
  ('ai_assist', 'Anthropic PBC', 'claude-opus-5-5', 'Kontrollbericht auswerten, Schaden auf Foto erkennen, Kosten schätzen',
   'Prüfpunkte/Notizen, Foto, Haustyp, Baujahr, Region – keine Namen, Kontakte, Adressen', 'Vorschlag (JSON), nie automatisch übernommen',
   'bei Husora 24 Monate (ai_suggestions); beim Anbieter laut Vertrag prüfen', 'laut Anbieter standardmäßig kein Training mit API-Daten – Vertrag prüfen',
   'USA', 'offen', 'Kennzeichnung „KI-Vorschlag“ und Hinweis „Du nutzt hier ein KI-System“'),
  ('translation', 'Google Übersetzer / MyMemory', 'maschinelle Übersetzung', 'Schwedische Inseratstexte übersetzen', 'Inseratstext', 'Übersetzung, gekennzeichnet als maschinell',
   'beim Anbieter – prüfen', 'prüfen', 'USA/Italien', 'offen', 'Kennzeichnung „maschinell übersetzt“')
on conflict (key) do nothing;
alter table public.ai_register enable row level security;
drop policy if exists ai_register_select on public.ai_register;
create policy ai_register_select on public.ai_register for select to authenticated using ((select private.is_any_admin()));
revoke all on public.ai_register from anon, authenticated;
grant select on public.ai_register to authenticated;

-- -----------------------------------------------------------------------------
-- 11a) Datenexport (nur eigene Daten bzw. eigene Organisationen; läuft mit RLS des Nutzers)
-- -----------------------------------------------------------------------------
create or replace function public.export_my_data()
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user uuid := private.current_user_id();
  v_orgs uuid[];
  v_out  jsonb;
begin
  if v_user is null then raise exception 'Bitte zuerst anmelden' using errcode = '42501'; end if;
  select coalesce(array_agg(m.organization_id), '{}') into v_orgs from public.organization_members m where m.user_id = v_user and m.status = 'active';
  select jsonb_build_object(
    'export_version', '1',
    'created_at', now(),
    'profile', (select to_jsonb(u) - 'is_super_admin' - 'admin_roles' from public.users u where u.id = v_user),
    'memberships', (select coalesce(jsonb_agg(jsonb_build_object('organization_id', m.organization_id, 'role', m.role, 'status', m.status, 'display_name', m.display_name, 'phone', m.phone)), '[]') from public.organization_members m where m.user_id = v_user),
    'organizations', (select coalesce(jsonb_agg(to_jsonb(o) - 'settings'), '[]') from public.organizations o where o.id = any (v_orgs)),
    'properties', (select coalesce(jsonb_agg(to_jsonb(p)), '[]') from public.properties p where p.organization_id = any (v_orgs)),
    'property_features', (select coalesce(jsonb_agg(to_jsonb(f)), '[]') from public.property_features f join public.properties p on p.id = f.property_id where p.organization_id = any (v_orgs)),
    'service_tasks', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from public.service_tasks t where t.organization_id = any (v_orgs)),
    'inspections', (select coalesce(jsonb_agg(to_jsonb(i) || jsonb_build_object('items', (select coalesce(jsonb_agg(to_jsonb(ii)), '[]') from public.inspection_items ii where ii.inspection_id = i.id))), '[]')
                    from public.inspections i where i.organization_id = any (v_orgs)),
    'repairs', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.repairs r where r.organization_id = any (v_orgs)),
    'service_orders', (select coalesce(jsonb_agg(to_jsonb(o)), '[]') from public.service_orders o
                       where o.organization_id = any (v_orgs) or o.service_partner_id in (select sp.id from public.service_partners sp where sp.partner_organization_id = any (v_orgs))),
    'messages', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'service_order_id', m.service_order_id, 'message', m.message, 'created_at', m.created_at)), '[]') from public.messages m where m.sender_user_id = v_user),
    'reviews_written', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.service_partner_reviews r where r.created_by = v_user),
    'beta_ratings', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.beta_ratings r where r.user_id = v_user),
    'feedback', (select coalesce(jsonb_agg(jsonb_build_object('kind', f.kind, 'type', f.feedback_type, 'message', f.message, 'created_at', f.created_at, 'status', f.status)), '[]') from public.app_feedback f where f.user_id = v_user),
    'notification_preferences', (select coalesce(jsonb_agg(to_jsonb(n)), '[]') from public.notification_preferences n where n.user_id = v_user),
    'consents', (select coalesce(jsonb_agg(to_jsonb(c)), '[]') from public.consent_log c where c.user_id = v_user),
    'legal_acceptances', (select coalesce(jsonb_agg(to_jsonb(a)), '[]') from public.legal_acceptances a where a.user_id = v_user),
    'privacy_requests', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.privacy_requests r where r.user_id = v_user),
    'app_data', (select coalesce(jsonb_agg(jsonb_build_object('organization_id', d.organization_id, 'key', d.key, 'updated_at', d.updated_at, 'value', d.value)), '[]') from public.app_data d where d.organization_id = any (v_orgs))
  ) into v_out;
  perform private.log_security_event('data_export', null, 'user', v_user);
  return v_out;
end;
$$;
revoke all on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;

-- Konto löschen: protokollieren (pseudonym – der Nutzerbezug entfällt mit der Löschung)
do $$
declare v_src text;
begin
  select pg_get_functiondef('public.delete_my_account(text)'::regprocedure) into v_src;
  if position('account_delete' in v_src) = 0 then
    v_src := replace(v_src, '  delete from public.users where id = v_user;',
      '  perform private.log_security_event(''account_delete'', null, ''user'', null, jsonb_build_object(''organizations_deleted'', coalesce(array_length(v_orgs, 1), 0)));
  delete from public.users where id = v_user;');
    execute v_src;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 11b) Beta Release Gate
-- -----------------------------------------------------------------------------
insert into public.app_config (key, value) values ('release_gate', '{"manual": {}}') on conflict (key) do nothing;
insert into public.app_config (key, value) values ('payments', '{"enabled": false}') on conflict (key) do nothing;

create or replace function public.release_gate()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_manual jsonb := coalesce((select c.value -> 'manual' from public.app_config c where c.key = 'release_gate'), '{}');
  v_imprint jsonb := (select c.value from public.app_config c where c.key = 'imprint');
  v_checks jsonb;
begin
  if not private.is_any_admin() then raise exception 'Nur für das Husora-Team' using errcode = '42501'; end if;
  v_checks := jsonb_build_array(
    -- automatisch geprüft
    jsonb_build_object('group', 'legal', 'key', 'imprint', 'label', 'Impressum vollständig (Pflichtangaben hinterlegt)', 'auto', true,
      'ok', v_imprint ->> 'operator' is not null and v_imprint ->> 'address' is not null and v_imprint ->> 'email' is not null),
    jsonb_build_object('group', 'legal', 'key', 'legal_docs', 'label', 'Datenschutz, Nutzungs- und Beta-Bedingungen veröffentlicht', 'auto', true,
      'ok', (select count(distinct d.document_type) from public.legal_documents d where d.published_at is not null and d.document_type in ('privacy', 'terms', 'beta_terms')) = 3),
    jsonb_build_object('group', 'legal', 'key', 'providers', 'label', 'Drittanbieter geprüft (kein Status „unbekannt“, aktive nicht gesperrt)', 'auto', true,
      'ok', not exists (select 1 from public.third_party_providers p where p.status = 'unknown')),
    jsonb_build_object('group', 'legal', 'key', 'retention', 'label', 'Lösch- und Aufbewahrungskonzept hinterlegt', 'auto', true,
      'ok', (select count(*) from public.retention_rules) >= 10),
    jsonb_build_object('group', 'security', 'key', 'rls', 'label', 'RLS auf allen Tabellen', 'auto', true,
      'ok', not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity)),
    jsonb_build_object('group', 'security', 'key', 'grants', 'label', 'Keine RLS-Umgehung über TRUNCATE/TRIGGER', 'auto', true,
      'ok', not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r'
                        and (has_table_privilege('authenticated', c.oid, 'TRUNCATE') or has_table_privilege('anon', c.oid, 'TRUNCATE')))),
    jsonb_build_object('group', 'security', 'key', 'storage', 'label', 'Private Buckets mit Größen- und Typbegrenzung', 'auto', true,
      'ok', not exists (select 1 from storage.buckets b where b.id <> 'husora-public' and (b.public or b.file_size_limit is null or b.allowed_mime_types is null))),
    jsonb_build_object('group', 'security', 'key', 'admin_mfa', 'label', 'MFA für Admins verpflichtend', 'auto', true,
      'ok', coalesce((select (c.value ->> 'require_admin_mfa')::boolean from public.app_config c where c.key = 'security'), false)),
    jsonb_build_object('group', 'security', 'key', 'incident_process', 'label', 'Incident-Prozess vorhanden', 'auto', true, 'ok', to_regclass('public.security_incidents') is not null),
    jsonb_build_object('group', 'product', 'key', 'payments_off', 'label', 'Keine echten Zahlungen während der Beta', 'auto', true,
      'ok', not coalesce((select (c.value ->> 'enabled')::boolean from public.app_config c where c.key = 'payments'), false))
  );
  -- manuell zu bestätigen (Bestätigung durch Admin, kein automatisches PASS)
  v_checks := v_checks || (select coalesce(jsonb_agg(jsonb_build_object('group', g, 'key', k, 'label', l, 'auto', false, 'ok', coalesce((v_manual ->> k)::boolean, false))), '[]')
    from (values ('legal', 'legal_review', 'Rechtstexte juristisch geprüft'), ('legal', 'roles_documented', 'Rollenmodell dokumentiert'),
                 ('legal', 'privacy_rights', 'Datenschutzrechte erreichbar (Kontakt + Anfrageweg getestet)'), ('legal', 'ai_reviewed', 'KI/Übersetzung geprüft'),
                 ('legal', 'import_reviewed', 'Immobilienimport geprüft (Quellen, Rechte)'), ('security', 'cross_tenant_test', 'Cross-Tenant-Test bestanden (Testmatrix)'),
                 ('security', 'delete_tested', 'Konto-Löschung getestet'), ('security', 'export_tested', 'Datenexport getestet'),
                 ('product', 'onboarding', 'Onboarding Hausbesitzer und Servicepartner getestet'), ('product', 'flows', 'Serviceanfrage, Auftrag, Hauskontrolle, Dokumente getestet'),
                 ('product', 'beta_tools', 'Feedback, Fehlerbericht, Analytics, Admin-Dashboard getestet')) m(g, k, l));
  return jsonb_build_object('checks', v_checks, 'passed', not exists (select 1 from jsonb_array_elements(v_checks) e where not (e ->> 'ok')::boolean));
end;
$$;
revoke all on function public.release_gate() from public, anon;
grant execute on function public.release_gate() to authenticated;

-- Open Beta nur bei bestandenem Gate
create or replace function private.guard_open_beta()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.key = 'beta' and new.value ->> 'default_group' = 'open_beta' and coalesce(old.value ->> 'default_group', '') <> 'open_beta' then
    if not coalesce((select (public.release_gate() ->> 'passed')::boolean), false) then
      raise exception 'Open Beta erst nach bestandenem Release-Gate' using errcode = 'P0001';
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists app_config_guard_open_beta on public.app_config;
create trigger app_config_guard_open_beta before update on public.app_config
  for each row execute function private.guard_open_beta();

-- -----------------------------------------------------------------------------
-- 12) Storage: Dateitypen auch für husora-private begrenzen
-- -----------------------------------------------------------------------------
update storage.buckets
set allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'text/plain', 'text/csv',
                               'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
    file_size_limit = least(coalesce(file_size_limit, 26214400), 26214400)
where id = 'husora-private';

-- Neue Tabellen: keine gefährlichen Rechte (Härtung aus 4100 auch hier)
do $$
declare r record;
begin
  for r in select c.oid::regclass as t from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r', 'p', 'v') loop
    execute format('revoke truncate, references, trigger on %s from anon, authenticated', r.t);
  end loop;
end $$;

-- Partnerliste für die Nachweisprüfung (nur content_admin)
create or replace function public.admin_partner_list()
returns table (id uuid, name text, verification_status text, verification_note text, verified_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select o.id, o.name, o.verification_status, o.verification_note, o.verified_at from public.organizations o
  where o.org_type in ('service_partner', 'both') and private.has_admin_role('content_admin')
  order by o.name
$$;
revoke all on function public.admin_partner_list() from public, anon;
grant execute on function public.admin_partner_list() to authenticated;

-- Reihenfolge von Einwilligung/Widerruf auch innerhalb einer Transaktion eindeutig
alter table public.consent_log alter column created_at set default clock_timestamp();
