-- =============================================================================
-- HUSORA · Migration 0100 · Erweiterungen, privates Schema, Hilfsfunktionen
-- =============================================================================
-- Das Schema "private" wird NICHT über die Supabase-API veröffentlicht.
-- Dort liegen Hilfsfunktionen für RLS, Trigger und interne Logik.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists btree_gist with schema extensions;

create schema if not exists private;
comment on schema private is 'Interne Husora-Funktionen (RLS-Helfer, Trigger). Nicht über PostgREST veröffentlicht.';

grant usage on schema private to authenticated, service_role;
revoke all on schema private from anon;

-- updated_at bei jeder Änderung automatisch setzen
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Fortlaufende Nummern für Serviceaufträge, Angebote und interne Belege
create sequence if not exists public.service_order_number_seq start 1000;
