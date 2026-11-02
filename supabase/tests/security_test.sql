-- =============================================================================
-- HUSORA · Security-Test: Rechte der API-Rollen auf Schema public
-- =============================================================================
-- Prüft dauerhaft, dass keine Client-Rolle RLS umgehen kann (TRUNCATE/TRIGGER/REFERENCES),
-- jede Tabelle RLS hat, anon nur die vorgesehenen Rechte besitzt und keine
-- Sicherheits-Definer-Funktion ohne Anmeldung ausführbar ist.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/security_test.sql
\set QUIET on
begin;
create function pg_temp.ok(p_label text, p_bad text) returns void language plpgsql as $$
begin
  if p_bad is not null and p_bad <> '' then raise exception 'SECURITY-TEST FEHLGESCHLAGEN – %: %', p_label, p_bad; end if;
  raise notice 'OK – %', p_label;
end $$;
\set QUIET off
select pg_temp.ok('Alle Tabellen in public haben RLS',
  (select string_agg(c.relname, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity));
select pg_temp.ok('Kein TRUNCATE/TRIGGER/REFERENCES für anon oder authenticated',
  (select string_agg(c.relname || ':' || r || ':' || p, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace
   cross join unnest(array['anon', 'authenticated']) r cross join unnest(array['TRUNCATE', 'TRIGGER', 'REFERENCES']) p
   where n.nspname = 'public' and c.relkind in ('r', 'p') and has_table_privilege(r, c.oid, p)));
select pg_temp.ok('anon schreibt nur anonymes Feedback',
  (select string_agg(c.relname || ':' || p, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace cross join unnest(array['INSERT', 'UPDATE', 'DELETE']) p
   where n.nspname = 'public' and c.relkind in ('r', 'p') and has_table_privilege('anon', c.oid, p) and not (c.relname = 'app_feedback' and p = 'INSERT')));
select pg_temp.ok('anon liest nur Tarife, Konfiguration und (per RLS gefiltert) nichts Weiteres mit Policy',
  (select string_agg(tablename || '.' || policyname, ', ') from pg_policies where schemaname = 'public' and 'anon' = any (roles)
   and tablename not in ('plans', 'app_config', 'app_feedback')));
select pg_temp.ok('Keine Sicherheits-Definer-Funktion ohne Anmeldung ausführbar',
  (select string_agg(p.proname, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef and has_function_privilege('anon', p.oid, 'EXECUTE')));
select pg_temp.ok('Sicherheits-Definer-Funktionen mit festem search_path',
  (select string_agg(n.nspname || '.' || p.proname, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')));
select pg_temp.ok('Schema private nicht für anon nutzbar', case when has_schema_privilege('anon', 'private', 'USAGE') then 'anon hat USAGE' end);
select pg_temp.ok('Nur husora-public ist öffentlich, alle anderen Buckets privat', (select string_agg(id, ', ') from storage.buckets where public and id <> 'husora-public'));
\echo '=== Alle Security-Tests bestanden ==='
rollback;
