-- =============================================================================
-- Jahresverträge: mehrere Aufgaben je Vertrag, Beginn und Ende frei wählbar
--  * task_titles: Liste der enthaltenen Aufgaben (z. B. „Rasen mähen“, „Hecke schneiden“).
--    Ein Auftrag gehört zum Vertrag, wenn sein Titel mit einer dieser Aufgaben beginnt.
--    task_title bleibt als erste Aufgabe für ältere App-Versionen erhalten.
--  * propose_service_agreement nimmt p_task_titles und prüft das Enddatum verständlich.
-- =============================================================================
alter table public.service_agreements add column task_titles text[] not null default '{}';
-- Hausname (+ Ort) als Anzeige für den Partner: er darf das Haus selbst erst lesen, wenn ein Auftrag dazu existiert
alter table public.service_agreements add column property_label text check (length(property_label) <= 200);
update public.service_agreements a set property_label = concat_ws(', ', p.name, nullif(p.city, '')) from public.properties p where p.id = a.property_id and a.property_label is null;
update public.service_agreements set task_titles = array[task_title] where cardinality(task_titles) = 0;
alter table public.service_agreements add constraint service_agreements_task_titles_check
  check (cardinality(task_titles) between 1 and 20 and task_title = task_titles[1]);

create or replace function private.agreement_covers(p_titles text[], p_order_title text)
returns boolean
language sql immutable set search_path = ''
as $$
  select exists (select 1 from unnest(p_titles) t where length(trim(t)) > 0 and lower(trim(p_order_title)) like lower(trim(t)) || '%')
$$;

create or replace function private.service_orders_agreement()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_ag public.service_agreements;
  v_day date := coalesce(new.scheduled_at, now())::date;
begin
  if tg_op = 'INSERT' and new.agreement_id is null and new.service_partner_id is not null then
    select a.* into v_ag from public.service_agreements a
    where a.organization_id = new.organization_id and a.property_id = new.property_id
      and a.service_partner_id = new.service_partner_id and a.status = 'active'
      and v_day between a.starts_on and a.ends_on
      and private.agreement_covers(a.task_titles, new.title)
    order by a.starts_on desc limit 1;
    new.agreement_id := v_ag.id;
  end if;
  if new.agreement_id is not null and (tg_op = 'INSERT' or new.agreement_id is distinct from old.agreement_id) then
    select * into v_ag from public.service_agreements where id = new.agreement_id;
    if v_ag.id is null or v_ag.organization_id <> new.organization_id or v_ag.property_id <> new.property_id
       or v_ag.service_partner_id is distinct from new.service_partner_id or v_ag.status <> 'active' then
      raise exception 'Auftrag passt nicht zum Jahresvertrag' using errcode = '22023';
    end if;
    new.actual_cost := null;
  end if;
  return new;
end;
$$;

drop function public.propose_service_agreement(uuid, uuid, text, numeric, date, date, text, integer, text, text);
create or replace function public.propose_service_agreement(
  p_service_partner_id uuid, p_property_id uuid, p_task_title text, p_annual_price numeric,
  p_starts_on date default current_date, p_ends_on date default null, p_interval_label text default null,
  p_visits_per_year integer default null, p_notes text default null, p_title text default null,
  p_task_titles text[] default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_sp     public.service_partners;
  v_side   text;
  v_ag     public.service_agreements;
  v_titles text[];
  v_start  date := coalesce(p_starts_on, current_date);
  v_end    date;
begin
  select * into v_sp from public.service_partners where id = p_service_partner_id;
  if v_sp.id is null then raise exception 'Servicepartner nicht gefunden' using errcode = 'P0002'; end if;
  if private.is_org_staff(v_sp.organization_id) then v_side := 'owner';
  elsif private.is_partner_member(v_sp.id) then v_side := 'partner';
  else raise exception 'Keine Berechtigung' using errcode = '42501'; end if;
  if not exists (select 1 from public.properties p where p.id = p_property_id and p.organization_id = v_sp.organization_id) then
    raise exception 'Haus gehört nicht zu diesem Kunden' using errcode = '22023';
  end if;
  -- Aufgaben: bereinigt, ohne Dubletten, Reihenfolge wie eingegeben
  select coalesce(array_agg(t order by ord), '{}') into v_titles from (
    select distinct on (lower(trim(x))) trim(x) as t, ord
    from unnest(coalesce(p_task_titles, '{}'::text[]) || array[p_task_title]) with ordinality as u(x, ord)
    where length(trim(coalesce(x, ''))) between 1 and 160
    order by lower(trim(x)), ord
  ) s;
  if cardinality(v_titles) = 0 then raise exception 'Bitte mindestens eine Aufgabe angeben' using errcode = '22023'; end if;
  if cardinality(v_titles) > 20 then raise exception 'Höchstens 20 Aufgaben je Vertrag' using errcode = '22023'; end if;
  v_end := coalesce(p_ends_on, (v_start + interval '1 year' - interval '1 day')::date);
  if v_end <= v_start then raise exception 'Das Vertragsende muss nach dem Beginn liegen' using errcode = '22023'; end if;
  if v_end > v_start + interval '3 years' then raise exception 'Ein Jahresvertrag läuft höchstens 3 Jahre' using errcode = '22023'; end if;
  insert into public.service_agreements (organization_id, property_id, property_label, service_partner_id, title, task_title, task_titles, interval_label,
    visits_per_year, annual_price, currency, starts_on, ends_on, notes, status, proposed_by, proposed_by_user, responded_at)
  values (v_sp.organization_id, p_property_id,
    (select left(concat_ws(', ', p.name, nullif(p.city, '')), 200) from public.properties p where p.id = p_property_id), v_sp.id,
    coalesce(nullif(trim(p_title), ''), v_titles[1] || case when cardinality(v_titles) > 1 then ' u. a.' else '' end || ' – Jahresvertrag ' || to_char(v_start, 'YYYY')),
    v_titles[1], v_titles, nullif(trim(p_interval_label), ''), p_visits_per_year, round(p_annual_price, 2),
    (select o.currency from public.organizations o where o.id = v_sp.organization_id),
    v_start, v_end, nullif(trim(p_notes), ''),
    case when v_sp.partner_organization_id = v_sp.organization_id then 'active' else 'proposed' end,
    v_side, private.current_user_id(),
    case when v_sp.partner_organization_id = v_sp.organization_id then now() end)
  returning * into v_ag;
  if v_ag.status = 'proposed' then
    perform private.agreement_notify(v_ag, v_side = 'owner', 'Neuer Jahresvertrag vorgeschlagen');
  end if;
  return v_ag.id;
end;
$$;
revoke all on function public.propose_service_agreement(uuid, uuid, text, numeric, date, date, text, integer, text, text, text[]) from public, anon;
grant execute on function public.propose_service_agreement(uuid, uuid, text, numeric, date, date, text, integer, text, text, text[]) to authenticated;

create or replace function public.respond_service_agreement(p_agreement_id uuid, p_accept boolean)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_ag public.service_agreements;
  v_side text;
begin
  select * into v_ag from public.service_agreements where id = p_agreement_id for update;
  if v_ag.id is null then raise exception 'Vertrag nicht gefunden' using errcode = 'P0002'; end if;
  if private.is_org_staff(v_ag.organization_id) then v_side := 'owner';
  elsif private.is_partner_member(v_ag.service_partner_id) then v_side := 'partner';
  else raise exception 'Keine Berechtigung' using errcode = '42501'; end if;
  if v_ag.status <> 'proposed' then raise exception 'Der Vertrag ist nicht mehr offen' using errcode = '22023'; end if;
  if v_ag.proposed_by = v_side then raise exception 'Den eigenen Vorschlag nimmt die andere Seite an' using errcode = '42501'; end if;
  update public.service_agreements set status = case when p_accept then 'active' else 'declined' end, responded_at = now()
  where id = v_ag.id returning * into v_ag;
  perform private.agreement_notify(v_ag, v_side = 'owner', case when p_accept then 'Jahresvertrag angenommen' else 'Jahresvertrag abgelehnt' end);
  if p_accept then
    update public.service_orders o set agreement_id = v_ag.id
    where o.organization_id = v_ag.organization_id and o.property_id = v_ag.property_id
      and o.service_partner_id = v_ag.service_partner_id and o.agreement_id is null
      and o.status in ('offered', 'accepted', 'scheduled', 'in_progress')
      and coalesce(o.scheduled_at, now())::date between v_ag.starts_on and v_ag.ends_on
      and private.agreement_covers(v_ag.task_titles, o.title)
      and not exists (select 1 from public.invoices i where i.service_order_id = o.id);
  end if;
  return v_ag.status;
end;
$$;
