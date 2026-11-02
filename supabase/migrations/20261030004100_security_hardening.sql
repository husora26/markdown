-- =============================================================================
-- HUSORA · Sicherheits-Härtung der Tabellenrechte (Security-Test 02.11.2026)
-- =============================================================================
-- Befund: Die Standardrechte von Supabase geben anon und authenticated auf jede neue Tabelle im
-- Schema public ALLE Rechte – auch TRUNCATE, REFERENCES und TRIGGER. RLS gilt für SELECT/INSERT/
-- UPDATE/DELETE, aber NICHT für TRUNCATE: Ein beliebiger angemeldeter Nutzer (bei einigen Tabellen
-- sogar ohne Anmeldung) hätte per „TRUNCATE“ die Daten aller Organisationen löschen können.
-- (Über die REST-API ist TRUNCATE nicht direkt aufrufbar, über SQL-Zugänge mit diesen Rollen aber schon.)
-- Behebung:
--   * TRUNCATE, REFERENCES, TRIGGER für anon/authenticated auf allen Tabellen entziehen
--   * anon bekommt nur noch, was eine anon-Policy wirklich braucht (Lesen plans/app_config,
--     anonymes Feedback); alle anderen Schreibrechte für anon entfallen
--   * Standardrechte für künftige Tabellen entsprechend anpassen
--   * Funktionen im Schema public: anon darf nur noch die ausdrücklich freigegebenen ausführen
-- Idempotent.

do $$
declare r record;
begin
  for r in select c.oid::regclass as t from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f') loop
    execute format('revoke truncate, references, trigger on %s from anon, authenticated', r.t);
    execute format('revoke insert, update, delete on %s from anon', r.t);
  end loop;
end $$;
-- benötigte anon-Rechte (siehe Policies plans_select, app_config_select, app_feedback_insert_anon)
grant select on public.plans, public.app_config to anon;
grant insert on public.app_feedback to anon;

-- künftige Tabellen/Funktionen: keine gefährlichen Rechte mehr automatisch vergeben
do $$
begin
  alter default privileges for role postgres in schema public revoke truncate, references, trigger on tables from anon, authenticated;
  alter default privileges for role postgres in schema public revoke insert, update, delete on tables from anon;
  alter default privileges for role postgres in schema public revoke execute on functions from anon;
exception when others then raise notice 'Standardrechte (postgres) nicht geändert: %', sqlerrm;
end $$;
do $$
begin
  alter default privileges for role supabase_admin in schema public revoke truncate, references, trigger on tables from anon, authenticated;
  alter default privileges for role supabase_admin in schema public revoke insert, update, delete on tables from anon;
exception when others then raise notice 'Standardrechte (supabase_admin) nicht geändert: %', sqlerrm;
end $$;

-- Sicherheits-Definer-Funktionen: anon nur, wo ohne Anmeldung nötig (keine)
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prosecdef and has_function_privilege('anon', p.oid, 'EXECUTE') loop
    execute format('revoke execute on function %s from anon, public', r.f);
    execute format('grant execute on function %s to authenticated', r.f);
  end loop;
end $$;
