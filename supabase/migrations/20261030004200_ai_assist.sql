-- =============================================================================
-- HUSORA · Phase 12: KI-Vorschläge (Kontrollbericht, Schadenserkennung aus Fotos, Kostenschätzung)
-- =============================================================================
-- Ablauf (Edge Function „ai-assist“):
--   1. ai_begin() mit dem Token des Nutzers: prüft per RLS, dass der Nutzer das Objekt sehen darf,
--      prüft Tageskontingent und Schalter, legt einen Eintrag „pending“ an.
--   2. Die Edge Function liest die Daten mit dem Token des Nutzers (RLS) und fragt das Modell –
--      der API-Schlüssel liegt nur als Secret der Edge Function.
--   3. ai_complete() schreibt das Ergebnis – NUR die Edge Function (service_role) darf das, damit
--      niemand ein „KI-Ergebnis“ fälschen kann.
-- Ergebnisse sind immer Vorschläge (status 'suggested') und werden nie automatisch übernommen;
-- der Nutzer entscheidet mit ai_decide().
-- Idempotent.

insert into public.app_config (key, value) values ('ai', '{"enabled": false, "daily_limit": 50}') on conflict (key) do nothing;

create table if not exists public.ai_suggestions (
  id                uuid primary key default gen_random_uuid(),
  requester_org_id  uuid references public.organizations(id) on delete cascade,
  entity_org_id     uuid references public.organizations(id) on delete cascade,
  requested_by      uuid references public.users(id) on delete set null,
  kind              text not null check (kind in ('inspection_report', 'photo_damage', 'cost_estimate')),
  entity_type       text not null check (entity_type in ('inspection', 'photo', 'inspection_item', 'repair')),
  entity_id         uuid not null,
  status            text not null default 'pending' check (status in ('pending', 'suggested', 'accepted', 'dismissed', 'failed')),
  result            jsonb check (result is null or pg_column_size(result) <= 20000),
  model             text check (model is null or length(model) <= 60),
  error_message     text check (error_message is null or length(error_message) <= 300),
  created_at        timestamptz not null default now(),
  completed_at      timestamptz,
  decided_at        timestamptz,
  decided_by        uuid references public.users(id) on delete set null
);
comment on table public.ai_suggestions is 'KI-Vorschläge (nie automatisch übernommen). Ergebnis schreibt nur die Edge Function ai-assist.';
create index if not exists ai_suggestions_entity_idx on public.ai_suggestions (entity_type, entity_id, created_at desc);
create index if not exists ai_suggestions_requester_idx on public.ai_suggestions (requester_org_id, created_at desc);
create index if not exists ai_suggestions_entity_org_idx on public.ai_suggestions (entity_org_id);
create index if not exists ai_suggestions_requested_by_idx on public.ai_suggestions (requested_by) where requested_by is not null;
create index if not exists ai_suggestions_decided_by_idx on public.ai_suggestions (decided_by) where decided_by is not null;

alter table public.ai_suggestions enable row level security;
drop policy if exists ai_suggestions_select on public.ai_suggestions;
create policy ai_suggestions_select on public.ai_suggestions for select to authenticated
  using (requested_by = (select private.current_user_id())
         or (requester_org_id is not null and private.is_org_member(requester_org_id))
         or (entity_org_id is not null and private.can_read_org(entity_org_id)));
revoke all on public.ai_suggestions from anon, authenticated;
grant select on public.ai_suggestions to authenticated;

-- Objekt sichtbar? (läuft mit den Rechten des Aufrufers → RLS entscheidet)
create or replace function public.ai_entity_visible(p_entity_type text, p_entity_id uuid)
returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare v_org uuid;
begin
  if p_entity_type = 'inspection' then select i.organization_id into v_org from public.inspections i where i.id = p_entity_id;
  elsif p_entity_type = 'photo' then select p.organization_id into v_org from public.photos p where p.id = p_entity_id;
  elsif p_entity_type = 'inspection_item' then
    select i.organization_id into v_org from public.inspection_items ii join public.inspections i on i.id = ii.inspection_id where ii.id = p_entity_id;
  elsif p_entity_type = 'repair' then select r.organization_id into v_org from public.repairs r where r.id = p_entity_id;
  end if;
  return v_org;
end;
$$;
revoke all on function public.ai_entity_visible(text, uuid) from public, anon;
grant execute on function public.ai_entity_visible(text, uuid) to authenticated;

create or replace function private.ai_reserve(p_kind text, p_entity_type text, p_entity_id uuid, p_entity_org uuid, p_requester_org uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_cfg   jsonb := (select c.value from public.app_config c where c.key = 'ai');
  v_user  uuid := private.current_user_id();
  v_org   uuid := case when p_requester_org is not null and private.is_org_member(p_requester_org) then p_requester_org else p_entity_org end;
  v_count integer;
  v_id    uuid;
begin
  if v_user is null then raise exception 'Bitte zuerst anmelden' using errcode = '42501'; end if;
  if not coalesce((v_cfg ->> 'enabled')::boolean, false) then raise exception 'KI-Vorschläge sind gerade nicht freigeschaltet' using errcode = 'P0001'; end if;
  select count(*) into v_count from public.ai_suggestions s where s.requester_org_id = v_org and s.created_at > now() - interval '1 day';
  if v_count >= coalesce((v_cfg ->> 'daily_limit')::integer, 50) then raise exception 'Tageskontingent für KI-Vorschläge erreicht – morgen wieder' using errcode = 'P0001'; end if;
  insert into public.ai_suggestions (requester_org_id, entity_org_id, requested_by, kind, entity_type, entity_id)
  values (v_org, p_entity_org, v_user, p_kind, p_entity_type, p_entity_id)
  returning id into v_id;
  return v_id;
end; $$;

-- Schritt 1 (Nutzer-Token)
create or replace function public.ai_begin(p_kind text, p_entity_type text, p_entity_id uuid, p_organization_id uuid default null)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare v_org uuid;
begin
  if not ((p_kind = 'inspection_report' and p_entity_type = 'inspection')
          or (p_kind = 'photo_damage' and p_entity_type = 'photo')
          or (p_kind = 'cost_estimate' and p_entity_type in ('inspection_item', 'repair'))) then
    raise exception 'Ungültige Anfrage' using errcode = '22023';
  end if;
  v_org := public.ai_entity_visible(p_entity_type, p_entity_id);
  if v_org is null then raise exception 'Keine Berechtigung für dieses Objekt' using errcode = '42501'; end if;
  return private.ai_reserve(p_kind, p_entity_type, p_entity_id, v_org, p_organization_id);
end;
$$;
revoke all on function public.ai_begin(text, text, uuid, uuid) from public, anon;
grant execute on function public.ai_begin(text, text, uuid, uuid) to authenticated;

-- Schritt 3 (nur Edge Function / service_role)
create or replace function public.ai_complete(p_id uuid, p_result jsonb, p_model text, p_error text default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.ai_suggestions
  set status = case when p_error is null then 'suggested' else 'failed' end,
      result = case when p_error is null then p_result end, model = left(p_model, 60),
      error_message = left(p_error, 300), completed_at = now()
  where id = p_id and status = 'pending';
end; $$;
revoke all on function public.ai_complete(uuid, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.ai_complete(uuid, jsonb, text, text) to service_role;

-- Nutzer entscheidet über den Vorschlag
create or replace function public.ai_decide(p_id uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_s public.ai_suggestions;
begin
  select * into v_s from public.ai_suggestions s where s.id = p_id;
  if v_s.id is null or not (v_s.requested_by = private.current_user_id() or (v_s.requester_org_id is not null and private.is_org_member(v_s.requester_org_id))) then
    raise exception 'Keine Berechtigung' using errcode = '42501';
  end if;
  if v_s.status <> 'suggested' then raise exception 'Dieser Vorschlag ist nicht mehr offen' using errcode = '22023'; end if;
  update public.ai_suggestions set status = case when p_accept then 'accepted' else 'dismissed' end, decided_at = now(), decided_by = private.current_user_id()
  where id = v_s.id;
end; $$;
revoke all on function public.ai_decide(uuid, boolean) from public, anon;
grant execute on function public.ai_decide(uuid, boolean) to authenticated;
