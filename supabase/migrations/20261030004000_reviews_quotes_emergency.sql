-- =============================================================================
-- HUSORA · Phase 11: Bewertungen, Kostenvergleich (Angebote), Notdienst, Matching-Daten
-- =============================================================================
--   * public.service_partner_reviews: eine Bewertung je abgeschlossenem Auftrag (nur der Hausbesitzer
--     des Auftrags), Antwort des Partners. Durchschnitt per Trigger an service_partners.rating (alle
--     Verbindungen dieses Partnerbetriebs) und organizations.rating_avg/rating_count.
--   * public.respond_quote(): Hausbesitzer nimmt ein Angebot an oder lehnt ab. Annahme übernimmt den
--     Betrag als Kostenschätzung; weitere Angebote derselben Aufgabe werden abgelehnt und noch offene
--     Anfragen dort zurückgezogen (Kostenvergleich mehrerer Partner).
--   * public.request_emergency(): Notfall → Anfrage mit Priorität „emergency“ an den besten verbundenen
--     Partner mit Notdienst (Objektfreigabe vor Bewertung), sofortige Benachrichtigung.
-- Idempotent.

-- -----------------------------------------------------------------------------
-- 1) Bewertungen
-- -----------------------------------------------------------------------------
alter table public.organizations
  add column if not exists rating_avg   numeric(3, 2),
  add column if not exists rating_count integer not null default 0;

create table if not exists public.service_partner_reviews (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  service_partner_id  uuid not null references public.service_partners(id) on delete cascade,
  service_order_id    uuid not null unique references public.service_orders(id) on delete cascade,
  rating              integer not null check (rating between 1 and 5),
  comment             text check (comment is null or length(comment) <= 2000),
  partner_reply       text check (partner_reply is null or length(partner_reply) <= 2000),
  replied_at          timestamptz,
  created_by          uuid references public.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
comment on table public.service_partner_reviews is 'Bewertung eines abgeschlossenen Auftrags durch den Hausbesitzer (eine je Auftrag), Antwort des Partners';
create index if not exists spr_partner_idx on public.service_partner_reviews (service_partner_id);
create index if not exists spr_org_idx on public.service_partner_reviews (organization_id);
create index if not exists spr_created_by_idx on public.service_partner_reviews (created_by) where created_by is not null;

create or replace function private.review_check()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_o public.service_orders;
begin
  if tg_op = 'INSERT' then
    select * into v_o from public.service_orders o where o.id = new.service_order_id;
    if v_o.id is null or v_o.status <> 'completed' then raise exception 'Bewerten geht erst nach Abschluss des Auftrags' using errcode = '22023'; end if;
    if not private.is_org_staff(v_o.organization_id) then raise exception 'Nur der Auftraggeber kann bewerten' using errcode = '42501'; end if;
    new.organization_id := v_o.organization_id;
    new.service_partner_id := v_o.service_partner_id;
    new.created_by := private.current_user_id();
    new.partner_reply := null; new.replied_at := null;
  else
    -- Inhalt bleibt fest; nur die Antwort des Partners (über reply_review) ändert sich
    new.organization_id := old.organization_id; new.service_partner_id := old.service_partner_id;
    new.service_order_id := old.service_order_id; new.created_by := old.created_by; new.created_at := old.created_at;
    if not private.is_system_context() then new.partner_reply := old.partner_reply; new.replied_at := old.replied_at; end if;
  end if;
  return new;
end; $$;
drop trigger if exists review_check on public.service_partner_reviews;
create trigger review_check before insert or update on public.service_partner_reviews
  for each row execute function private.review_check();
drop trigger if exists spr_set_updated_at on public.service_partner_reviews;
create trigger spr_set_updated_at before update on public.service_partner_reviews
  for each row execute function private.set_updated_at();
drop trigger if exists service_partner_reviews_audit on public.service_partner_reviews;
create trigger service_partner_reviews_audit after insert or update or delete on public.service_partner_reviews
  for each row execute function private.audit_row_change();

-- Durchschnitt je Partnerbetrieb (über alle Kunden)
create or replace function private.review_aggregate()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_porg uuid;
  v_avg  numeric;
  v_n    integer;
begin
  select sp.partner_organization_id into v_porg from public.service_partners sp where sp.id = coalesce(new.service_partner_id, old.service_partner_id);
  if v_porg is null then
    update public.service_partners sp set rating = (select round(avg(r.rating)::numeric, 2) from public.service_partner_reviews r where r.service_partner_id = sp.id)
    where sp.id = coalesce(new.service_partner_id, old.service_partner_id);
    return null;
  end if;
  select round(avg(r.rating)::numeric, 2), count(*) into v_avg, v_n
  from public.service_partner_reviews r join public.service_partners sp on sp.id = r.service_partner_id
  where sp.partner_organization_id = v_porg;
  update public.organizations set rating_avg = v_avg, rating_count = v_n where id = v_porg;
  update public.service_partners set rating = v_avg where partner_organization_id = v_porg;
  return null;
end; $$;
drop trigger if exists review_aggregate on public.service_partner_reviews;
create trigger review_aggregate after insert or update of rating or delete on public.service_partner_reviews
  for each row execute function private.review_aggregate();

alter table public.service_partner_reviews enable row level security;
drop policy if exists spr_select on public.service_partner_reviews;
create policy spr_select on public.service_partner_reviews for select to authenticated
  using (private.can_read_org(organization_id) or private.is_partner_member(service_partner_id));
drop policy if exists spr_insert on public.service_partner_reviews;
create policy spr_insert on public.service_partner_reviews for insert to authenticated
  with check (private.is_org_staff(organization_id));
drop policy if exists spr_update on public.service_partner_reviews;
create policy spr_update on public.service_partner_reviews for update to authenticated
  using (private.is_org_staff(organization_id)) with check (private.is_org_staff(organization_id));
revoke all on public.service_partner_reviews from anon, authenticated;
grant select, insert on public.service_partner_reviews to authenticated;
grant update (rating, comment) on public.service_partner_reviews to authenticated;

-- Partner antwortet auf eine Bewertung
create or replace function public.reply_review(p_review_id uuid, p_reply text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_r public.service_partner_reviews;
begin
  select * into v_r from public.service_partner_reviews r where r.id = p_review_id;
  if v_r.id is null or not private.is_partner_member(v_r.service_partner_id) or private.is_org_staff(v_r.organization_id) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  update public.service_partner_reviews set partner_reply = left(nullif(trim(p_reply), ''), 2000), replied_at = case when nullif(trim(p_reply), '') is null then null else now() end
  where id = v_r.id;
end; $$;
revoke all on function public.reply_review(uuid, text) from public, anon;
grant execute on function public.reply_review(uuid, text) to authenticated;

-- Bewertung → Benachrichtigung an den Partner
create or replace function private.review_notify()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (organization_id, user_id, type, category, title, message, entity_type, entity_id)
  select sp.partner_organization_id, m.user_id, 'service_order', 'order', 'Neue Bewertung: ' || repeat('★', new.rating) || repeat('☆', 5 - new.rating),
         left(coalesce(new.comment, ''), 200), 'service_order', new.service_order_id
  from public.service_partners sp join public.organization_members m on m.organization_id = sp.partner_organization_id
  where sp.id = new.service_partner_id and sp.partner_organization_id is not null and m.status = 'active' and m.role in ('admin', 'service_manager');
  return null;
exception when others then return null;
end; $$;
drop trigger if exists review_notify on public.service_partner_reviews;
create trigger review_notify after insert on public.service_partner_reviews
  for each row execute function private.review_notify();

-- -----------------------------------------------------------------------------
-- 2) Kostenvergleich: Angebot annehmen/ablehnen
-- -----------------------------------------------------------------------------
create or replace function public.respond_quote(p_quote_id uuid, p_approve boolean, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q     public.quotes;
  v_o     public.service_orders;
  v_other integer := 0;
  v_note  text := left(nullif(trim(p_note), ''), 500);
begin
  select * into v_q from public.quotes q where q.id = p_quote_id for update;
  if v_q.id is null or not private.is_org_staff(v_q.organization_id) then raise exception 'Keine Berechtigung' using errcode = '42501'; end if;
  if v_q.status not in ('requested', 'received') then raise exception 'Dieses Angebot ist bereits entschieden' using errcode = '22023'; end if;
  select * into v_o from public.service_orders o where o.id = v_q.service_order_id;
  update public.quotes set status = case when p_approve then 'approved' else 'rejected' end, decided_at = now(), decided_by = private.current_user_id() where id = v_q.id;
  if p_approve and v_o.id is not null then
    update public.service_orders set estimated_cost = v_q.amount_gross, approval_status = 'approved' where id = v_o.id;
    -- Vergleich: andere Angebote derselben Aufgabe ablehnen, offene Anfragen dort zurückziehen
    if v_o.service_task_id is not null then
      update public.quotes q set status = 'rejected', decided_at = now(), decided_by = private.current_user_id()
      from public.service_orders o
      where q.service_order_id = o.id and o.service_task_id = v_o.service_task_id and o.id <> v_o.id and q.status in ('requested', 'received');
      get diagnostics v_other = row_count;
      update public.service_orders o set status = 'cancelled', response_note = 'Anderes Angebot gewählt'
      where o.service_task_id = v_o.service_task_id and o.id <> v_o.id and o.status = 'offered';
    end if;
  end if;
  insert into public.notifications (organization_id, user_id, type, category, title, message, entity_type, entity_id)
  select sp.partner_organization_id, m.user_id, 'service_order', 'order',
         case when p_approve then 'Angebot angenommen: ' else 'Angebot abgelehnt: ' end || coalesce(v_q.quote_number, v_o.title, 'Angebot'),
         left(coalesce(v_note, v_q.amount_gross::text || ' ' || v_q.currency), 200), 'service_order', v_q.service_order_id
  from public.service_partners sp join public.organization_members m on m.organization_id = sp.partner_organization_id
  where sp.id = v_q.service_partner_id and sp.partner_organization_id is not null and m.status = 'active' and m.role in ('admin', 'service_manager', 'dispatcher', 'accounting');
  return jsonb_build_object('status', case when p_approve then 'approved' else 'rejected' end, 'others_rejected', v_other);
end;
$$;
revoke all on function public.respond_quote(uuid, boolean, text) from public, anon;
grant execute on function public.respond_quote(uuid, boolean, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 3) Notdienst
-- -----------------------------------------------------------------------------
create or replace function public.request_emergency(p_property_id uuid, p_title text, p_description text default null, p_exclude uuid[] default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org   uuid := private.property_org(p_property_id);
  v_sp    record;
  v_id    uuid;
  v_title text := left(nullif(trim(p_title), ''), 160);
begin
  if v_org is null or not private.is_org_staff(v_org) then raise exception 'Keine Berechtigung' using errcode = '42501'; end if;
  if v_title is null then raise exception 'Bitte kurz beschreiben, was passiert ist' using errcode = '22023'; end if;
  select sp.id, sp.company_name, sp.partner_organization_id into v_sp
  from public.service_partners sp join public.organizations po on po.id = sp.partner_organization_id
  where sp.organization_id = v_org and sp.partner_organization_id <> v_org and sp.disconnected_at is null and po.emergency_service
    and (p_exclude is null or not (sp.id = any (p_exclude)))
    and not exists (select 1 from public.service_partner_absences a where a.organization_id = po.id and a.user_id is null and now() between a.start_at and a.end_at)
  order by exists (select 1 from public.property_service_assignments psa where psa.property_id = p_property_id and psa.service_partner_id = sp.id and psa.status = 'active') desc,
           po.rating_avg desc nulls last, sp.company_name
  limit 1;
  if v_sp.id is null then
    raise exception 'Kein verbundener Servicepartner mit Notdienst verfügbar – bitte direkt anrufen (Notfall-Telefon)' using errcode = 'P0002';
  end if;
  insert into public.service_orders (organization_id, property_id, service_partner_id, title, description, status, priority, order_type, scheduled_at, currency, created_by)
  values (v_org, p_property_id, v_sp.id, 'NOTFALL: ' || v_title, left(nullif(trim(p_description), ''), 2000), 'offered', 'emergency', 'emergency', now(),
          (select o.currency from public.organizations o where o.id = v_org), private.current_user_id())
  returning id into v_id;
  insert into public.notifications (organization_id, user_id, type, category, title, message, entity_type, entity_id)
  select v_sp.partner_organization_id, m.user_id, 'service_order', 'order', 'NOTFALL: ' || v_title,
         left(concat_ws(' · ', (select p.name from public.properties p where p.id = p_property_id), 'bitte sofort annehmen oder ablehnen'), 200), 'service_order', v_id
  from public.organization_members m
  where m.organization_id = v_sp.partner_organization_id and m.status = 'active' and m.role in ('admin', 'service_manager', 'dispatcher');
  return jsonb_build_object('service_order_id', v_id, 'service_partner_id', v_sp.id, 'company_name', v_sp.company_name);
end;
$$;
revoke all on function public.request_emergency(uuid, text, text, uuid[]) from public, anon;
grant execute on function public.request_emergency(uuid, text, text, uuid[]) to authenticated;

-- Notdienst-Kennzeichen der verbundenen Partner für die Auswahl beim Hausbesitzer
create or replace function public.partner_directory_facts()
returns table (service_partner_id uuid, emergency_service boolean, rating_avg numeric, rating_count integer)
language sql stable security definer set search_path = '' as $$
  select sp.id, coalesce(po.emergency_service, false), po.rating_avg, coalesce(po.rating_count, 0)
  from public.service_partners sp left join public.organizations po on po.id = sp.partner_organization_id
  where private.is_org_member(sp.organization_id)
$$;
revoke all on function public.partner_directory_facts() from public, anon;
grant execute on function public.partner_directory_facts() to authenticated;
