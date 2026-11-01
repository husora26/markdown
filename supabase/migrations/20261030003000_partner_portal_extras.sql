-- =============================================================================
-- Partner-Portal: Erweiterungen
--  * Jahresverträge bearbeiten (Änderung muss die andere Seite bestätigen) und löschen
--  * Leistungspakete: eigener Name, Beschreibung und Ergänzungsfeld je Leistung
--  * Mitarbeiter: Name, Telefon, Info je Mitglied (auch schon bei der Einladung)
--  * Dokumente archivieren: Archiv-Status je Betrieb (Dokumente des Kunden bleiben unverändert)
-- =============================================================================

-- ----- Leistungspakete -----
alter table public.service_partner_services
  add column label       text check (length(label) <= 120),
  add column description text check (length(description) <= 1000),
  add column notes       text check (length(notes) <= 2000);
comment on column public.service_partner_services.notes is 'Ergänzungsfeld je Leistung (z. B. Anfahrt, Material, Mindestmenge).';

-- ----- Mitarbeiter -----
alter table public.organization_members
  add column display_name text check (length(display_name) <= 120),
  add column phone        text check (length(phone) <= 40),
  add column info         text check (length(info) <= 1000);
alter table public.organization_invites
  add column display_name text check (length(display_name) <= 120),
  add column phone        text check (length(phone) <= 40),
  add column info         text check (length(info) <= 1000);
create policy organization_invites_update on public.organization_invites for update to authenticated
  using (private.is_org_admin(organization_id)) with check (private.is_org_admin(organization_id));
grant update (display_name, phone, info) on public.organization_invites to authenticated;

-- Beim Annehmen einer Einladung die Angaben (Name, Telefon, Info) ins Mitglied übernehmen
create or replace function private.invite_copy_details()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.accepted_by is not null and old.accepted_by is null then
    update public.organization_members m
    set display_name = coalesce(m.display_name, new.display_name),
        phone = coalesce(m.phone, new.phone),
        info = coalesce(m.info, new.info)
    where m.organization_id = new.organization_id and m.user_id = new.accepted_by;
  end if;
  return new;
end;
$$;
create trigger organization_invites_copy_details after update of accepted_by on public.organization_invites
  for each row execute function private.invite_copy_details();

-- Hinweis: Der letzte aktive Admin ist bereits durch private.keep_last_admin() (Migration 1000) geschützt.

-- ----- Dokumente archivieren (je Betrieb) -----
create table public.document_archive (
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  document_id      uuid not null references public.documents(id) on delete cascade,
  archived_by      uuid references public.users(id) on delete set null default private.current_user_id(),
  archived_at      timestamptz not null default now(),
  primary key (organization_id, document_id)
);
comment on table public.document_archive is 'Archiv-Markierung eines Dokuments für einen Betrieb – das Dokument selbst (ggf. beim Kunden) bleibt unverändert.';
create index document_archive_document_idx on public.document_archive (document_id);
alter table public.document_archive enable row level security;
create policy document_archive_select on public.document_archive for select to authenticated
  using (private.can_read_org(organization_id));
create policy document_archive_insert on public.document_archive for insert to authenticated
  with check (private.is_org_staff(organization_id)
              and exists (select 1 from public.documents d where d.id = document_id));
create policy document_archive_delete on public.document_archive for delete to authenticated
  using (private.is_org_staff(organization_id));
grant select, insert, delete on public.document_archive to authenticated;
grant all on public.document_archive to service_role;

-- ----- Jahresverträge bearbeiten und löschen -----
create or replace function private.agreement_side(p_ag public.service_agreements)
returns text
language sql stable security definer set search_path = ''
as $$
  select case when private.is_org_staff(p_ag.organization_id) then 'owner'
              when private.is_partner_member(p_ag.service_partner_id) then 'partner' end
$$;

create or replace function public.update_service_agreement(
  p_agreement_id uuid, p_task_titles text[], p_annual_price numeric, p_starts_on date, p_ends_on date,
  p_interval_label text default null, p_visits_per_year integer default null, p_notes text default null)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_ag     public.service_agreements;
  v_side   text;
  v_titles text[];
  v_own    boolean;
begin
  select * into v_ag from public.service_agreements where id = p_agreement_id for update;
  if v_ag.id is null then raise exception 'Vertrag nicht gefunden' using errcode = 'P0002'; end if;
  v_side := private.agreement_side(v_ag);
  if v_side is null then raise exception 'Keine Berechtigung' using errcode = '42501'; end if;
  if v_ag.status not in ('proposed', 'active') then raise exception 'Beendete oder abgelehnte Verträge können nicht mehr geändert werden' using errcode = '22023'; end if;
  select coalesce(array_agg(t order by ord), '{}') into v_titles from (
    select distinct on (lower(trim(x))) trim(x) as t, ord
    from unnest(coalesce(p_task_titles, '{}'::text[])) with ordinality as u(x, ord)
    where length(trim(coalesce(x, ''))) between 1 and 160
    order by lower(trim(x)), ord
  ) s;
  if cardinality(v_titles) = 0 then raise exception 'Bitte mindestens eine Aufgabe angeben' using errcode = '22023'; end if;
  if cardinality(v_titles) > 20 then raise exception 'Höchstens 20 Aufgaben je Vertrag' using errcode = '22023'; end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on <= p_starts_on then raise exception 'Das Vertragsende muss nach dem Beginn liegen' using errcode = '22023'; end if;
  if p_ends_on > p_starts_on + interval '3 years' then raise exception 'Ein Jahresvertrag läuft höchstens 3 Jahre' using errcode = '22023'; end if;
  if p_annual_price is null or p_annual_price < 0 then raise exception 'Bitte einen Jahrespreis angeben' using errcode = '22023'; end if;
  -- eigener Kunde ohne Husora-Konto: sofort gültig; sonst bestätigt die andere Seite die Änderung
  v_own := exists (select 1 from public.service_partners sp where sp.id = v_ag.service_partner_id and sp.partner_organization_id = sp.organization_id);
  update public.service_agreements set
    task_title = v_titles[1], task_titles = v_titles, annual_price = round(p_annual_price, 2),
    starts_on = p_starts_on, ends_on = p_ends_on, interval_label = nullif(trim(p_interval_label), ''),
    visits_per_year = p_visits_per_year, notes = nullif(trim(p_notes), ''),
    title = v_titles[1] || case when cardinality(v_titles) > 1 then ' u. a.' else '' end || ' – Jahresvertrag ' || to_char(p_starts_on, 'YYYY'),
    status = case when v_own then status else 'proposed' end,
    proposed_by = case when v_own then proposed_by else v_side end,
    proposed_by_user = private.current_user_id(),
    responded_at = case when v_own then responded_at else null end
  where id = v_ag.id returning * into v_ag;
  if v_ag.status = 'proposed' then
    perform private.agreement_notify(v_ag, v_side = 'owner', 'Jahresvertrag geändert – bitte bestätigen');
  end if;
  return v_ag.status;
end;
$$;

create or replace function public.delete_service_agreement(p_agreement_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_ag public.service_agreements;
begin
  select * into v_ag from public.service_agreements where id = p_agreement_id for update;
  if v_ag.id is null then raise exception 'Vertrag nicht gefunden' using errcode = 'P0002'; end if;
  if private.agreement_side(v_ag) is null then raise exception 'Keine Berechtigung' using errcode = '42501'; end if;
  if exists (select 1 from public.invoices i where i.agreement_id = v_ag.id and i.status <> 'cancelled') then
    raise exception 'Zu diesem Vertrag gibt es bereits eine Jahresrechnung – bitte beenden statt löschen' using errcode = '22023';
  end if;
  -- Aufträge bleiben erhalten und werden wieder einzeln abrechenbar (agreement_id → null über den Fremdschlüssel)
  delete from public.service_agreements where id = v_ag.id;
end;
$$;

revoke all on function public.update_service_agreement(uuid, text[], numeric, date, date, text, integer, text) from public, anon;
revoke all on function public.delete_service_agreement(uuid) from public, anon;
revoke all on function private.agreement_side(public.service_agreements) from public, anon, authenticated;
grant execute on function public.update_service_agreement(uuid, text[], numeric, date, date, text, integer, text) to authenticated;
grant execute on function public.delete_service_agreement(uuid) to authenticated;
