-- =============================================================================
-- HUSORA · Migration 1300 · Partner-Routing: Ranking, Angebot, Antwort
-- =============================================================================
-- score = distance_score + availability_score + rating_score + price_score
-- Gewichte je Organisation in organizations.settings -> 'partner_ranking':
--   {"distance": 40, "availability": 20, "rating": 25, "price": 15,
--    "max_distance_km": 100, "max_open_orders": 10}

-- Entfernung in km (Haversine)
create or replace function public.distance_km(p_lat1 numeric, p_lon1 numeric, p_lat2 numeric, p_lon2 numeric)
returns numeric
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case when p_lat1 is null or p_lon1 is null or p_lat2 is null or p_lon2 is null then null
  else round((6371 * 2 * asin(sqrt(
         power(sin(radians((p_lat2 - p_lat1)::double precision) / 2), 2)
       + cos(radians(p_lat1::double precision)) * cos(radians(p_lat2::double precision))
       * power(sin(radians((p_lon2 - p_lon1)::double precision) / 2), 2)
       )))::numeric, 2)
  end
$$;

-- Passende Partner für ein Haus und eine Serviceart, bester zuerst.
-- security invoker: es werden nur Partner gerankt, die der Aufrufer sehen darf.
create or replace function public.match_service_partners(
  p_property_id uuid,
  p_service_type_id uuid,
  p_limit integer default 5,
  p_exclude_partner_ids uuid[] default null,
  p_scheduled_at timestamptz default null
)
returns table (
  service_partner_id  uuid,
  company_name        text,
  distance_km         numeric,
  open_orders         integer,
  rating              numeric,
  price_from          numeric,
  price_unit          text,
  distance_score      numeric,
  availability_score  numeric,
  rating_score        numeric,
  price_score         numeric,
  score               numeric
)
language sql
stable
set search_path = ''
as $$
  with prop as (
    select p.*, coalesce(o.settings -> 'partner_ranking', '{}'::jsonb) as cfg
    from public.properties p
    join public.organizations o on o.id = p.organization_id
    where p.id = p_property_id
  ),
  w as (
    select
      coalesce((cfg ->> 'distance')::numeric, 40)         as w_distance,
      coalesce((cfg ->> 'availability')::numeric, 20)     as w_availability,
      coalesce((cfg ->> 'rating')::numeric, 25)           as w_rating,
      coalesce((cfg ->> 'price')::numeric, 15)            as w_price,
      greatest(coalesce((cfg ->> 'max_distance_km')::numeric, 100), 1) as max_distance,
      greatest(coalesce((cfg ->> 'max_open_orders')::numeric, 10), 1)  as max_open
    from prop
  ),
  candidates as (
    select
      sp.id,
      sp.company_name,
      sp.rating,
      sps.price_from,
      sps.price_unit,
      public.distance_km(prop.latitude, prop.longitude, sp.latitude, sp.longitude) as dist,
      exists (
        select 1 from public.service_partner_areas a
        where a.service_partner_id = sp.id
          and (a.postal_code = prop.postal_code
               or lower(a.city) = lower(prop.city)
               or lower(a.region) = lower(prop.region))
      ) as area_match,
      exists (select 1 from public.service_partner_areas a where a.service_partner_id = sp.id) as has_areas,
      (
        select max(a.radius_km) from public.service_partner_areas a where a.service_partner_id = sp.id
      ) as max_radius,
      (
        select count(*) from public.service_orders so
        where so.service_partner_id = sp.id and so.status in ('offered', 'accepted', 'scheduled', 'in_progress')
      )::integer as open_cnt,
      (
        select count(*) from public.service_orders so
        where so.service_partner_id = sp.id and so.status in ('accepted', 'scheduled', 'in_progress')
          and p_scheduled_at is not null and so.scheduled_at is not null
          and so.scheduled_at between p_scheduled_at - interval '12 hours' and p_scheduled_at + interval '12 hours'
      )::integer as day_conflicts
    from prop
    join public.service_partners sp on sp.organization_id = prop.organization_id and sp.status = 'active'
    join public.service_partner_services sps
      on sps.service_partner_id = sp.id and sps.service_type_id = p_service_type_id and sps.active
    where p_exclude_partner_ids is null or sp.id <> all (p_exclude_partner_ids)
  ),
  eligible as (
    -- Einsatzgebiet: ohne hinterlegte Gebiete gilt der Partner als überall verfügbar
    select c.* from candidates c
    where not c.has_areas or c.area_match or (c.max_radius is not null and c.dist is not null and c.dist <= c.max_radius)
  ),
  scored as (
    select
      e.*,
      round(case
        when e.dist is not null then w.w_distance * greatest(0, 1 - e.dist / w.max_distance)
        when e.area_match then w.w_distance * 0.5
        else 0 end, 2) as s_distance,
      round(w.w_availability * greatest(0, 1 - e.open_cnt / w.max_open)
            * case when e.day_conflicts > 0 then 0.5 else 1 end, 2) as s_availability,
      round(w.w_rating * coalesce(e.rating, 2.5) / 5, 2) as s_rating,
      round(case
        when e.price_from is null then w.w_price * 0.5
        when e.price_from = 0 then w.w_price
        else w.w_price * (min(e.price_from) over () / e.price_from) end, 2) as s_price
    from eligible e cross join w
  )
  select s.id, s.company_name, s.dist, s.open_cnt, s.rating, s.price_from, s.price_unit,
         s.s_distance, s.s_availability, s.s_rating, s.s_price,
         s.s_distance + s.s_availability + s.s_rating + s.s_price as score
  from scored s
  order by score desc, s.dist nulls last, s.company_name
  limit greatest(p_limit, 1)
$$;

-- Aufgabe einem Partner anbieten (ohne Angabe: bester Treffer aus dem Ranking)
create or replace function public.offer_service_order(
  p_service_task_id uuid,
  p_service_partner_id uuid default null,
  p_estimated_cost numeric default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_task    public.service_tasks;
  v_partner uuid := p_service_partner_id;
  v_price   numeric;
  v_score   numeric;
  v_order   uuid;
  v_exclude uuid[];
begin
  select * into v_task from public.service_tasks t where t.id = p_service_task_id;
  if v_task.id is null then
    raise exception 'Aufgabe nicht gefunden' using errcode = 'P0002';
  end if;

  if v_partner is null then
    select array_agg(o.service_partner_id) into v_exclude
    from public.service_orders o where o.service_task_id = v_task.id and o.status = 'rejected';
    select m.service_partner_id, m.price_from, m.score into v_partner, v_price, v_score
    from public.match_service_partners(v_task.property_id, v_task.service_type_id, 1, v_exclude, v_task.scheduled_start) m;
    if v_partner is null then
      raise exception 'Kein passender Servicepartner gefunden' using errcode = 'P0002';
    end if;
  end if;

  insert into public.service_orders (organization_id, service_task_id, property_id, service_partner_id, title,
                                     description, status, scheduled_at, estimated_cost, match_score)
  values (v_task.organization_id, v_task.id, v_task.property_id, v_partner,
          v_task.title, v_task.description, 'offered', v_task.scheduled_start,
          coalesce(p_estimated_cost, v_price), v_score)
  returning id into v_order;
  return v_order;
end;
$$;

-- Antwort des Partners speichern (annehmen / ablehnen, optional Termin)
create or replace function public.respond_service_order(
  p_service_order_id uuid,
  p_accept boolean,
  p_note text default null,
  p_scheduled_at timestamptz default null
)
returns public.service_orders
language plpgsql
set search_path = ''
as $$
declare
  v_order public.service_orders;
begin
  update public.service_orders o
  set status = case when p_accept then 'accepted' else 'rejected' end,
      response_note = coalesce(p_note, o.response_note),
      scheduled_at = case when p_accept then coalesce(p_scheduled_at, o.scheduled_at) else o.scheduled_at end
  where o.id = p_service_order_id and o.status = 'offered'
  returning * into v_order;
  if v_order.id is null then
    raise exception 'Auftrag nicht gefunden oder nicht mehr offen' using errcode = 'P0002';
  end if;
  return v_order;
end;
$$;

revoke all on function public.match_service_partners(uuid, uuid, integer, uuid[], timestamptz) from public, anon;
revoke all on function public.offer_service_order(uuid, uuid, numeric) from public, anon;
revoke all on function public.respond_service_order(uuid, boolean, text, timestamptz) from public, anon;
revoke all on function public.distance_km(numeric, numeric, numeric, numeric) from anon;
grant execute on function public.match_service_partners(uuid, uuid, integer, uuid[], timestamptz) to authenticated, service_role;
grant execute on function public.offer_service_order(uuid, uuid, numeric) to authenticated, service_role;
grant execute on function public.respond_service_order(uuid, boolean, text, timestamptz) to authenticated, service_role;
grant execute on function public.distance_km(numeric, numeric, numeric, numeric) to authenticated, service_role;
