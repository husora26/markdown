-- =============================================================================
-- HUSORA · Migration 2300 · Mitglieder für Hausbesitzer, Benutzer-Limit je Tarif
-- =============================================================================
-- Hausbesitzer laden Familie, Miteigentümer oder Verwaltung per TEAM-Code ein
-- (create_member_invite / accept_member_invite aus Migration 1700).
-- Neu: Auswahl der Organisation (wer eingeladen wurde, hat oft zusätzlich eine
-- eigene, leere Organisation) und eine serverseitige Benutzergrenze je Tarif.

-- Alle Hausbesitzer-Organisationen des Nutzers (für die Auswahl in der App)
create or replace function public.my_organizations()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'organization_id', o.id, 'name', o.name, 'role', m.role,
           'members', (select count(*) from public.organization_members x where x.organization_id = o.id and x.status = 'active'),
           'joined_at', m.created_at
         ) order by m.created_at), '[]'::jsonb)
  from public.organization_members m
  join public.organizations o on o.id = m.organization_id
  where m.user_id = private.current_user_id() and m.status = 'active' and o.org_type in ('homeowner', 'both')
$$;
grant execute on function public.my_organizations() to authenticated;

-- Mitglieder samt Kontakt (nur für Leser der Organisation)
create or replace function public.org_members(p_organization_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.can_read_org(p_organization_id) then
    raise exception 'Keine Berechtigung für diese Organisation' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', m.id, 'user_id', m.user_id, 'role', m.role, 'status', m.status,
             'email', u.email, 'name', nullif(trim(concat_ws(' ', u.first_name, u.last_name)), ''),
             'is_me', m.user_id = private.current_user_id(), 'created_at', m.created_at) order by m.created_at)
    from public.organization_members m join public.users u on u.id = m.user_id
    where m.organization_id = p_organization_id
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.org_members(uuid) to authenticated;

-- Benutzergrenze: aktive Mitglieder + offene Einladungen dürfen das Tariflimit nicht überschreiten
create or replace function private.enforce_user_limit()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_limit integer;
  v_used integer;
  v_plan text;
begin
  if auth.uid() is null or coalesce(auth.role(), '') = 'service_role' then return new; end if;
  if exists (select 1 from public.organizations o where o.id = new.organization_id and o.org_type = 'service_partner') then return new; end if;
  v_plan := private.org_plan(new.organization_id);
  select nullif(p.limits ->> 'users', '')::integer into v_limit from public.plans p where p.id = v_plan;
  if v_limit is null then return new; end if; -- unbegrenzt
  select (select count(*) from public.organization_members m where m.organization_id = new.organization_id and m.status = 'active')
       + (select count(*) from public.organization_invites i where i.organization_id = new.organization_id and i.accepted_at is null and i.expires_at > now())
    into v_used;
  if v_used >= v_limit then
    raise exception 'Dein Tarif umfasst % Benutzer – für weitere Mitglieder wechsle in einen größeren Tarif.', v_limit using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger organization_invites_user_limit before insert on public.organization_invites
  for each row execute function private.enforce_user_limit();
