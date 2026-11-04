# Husora – Datenmigration Hybrid Service (Migration 4700)

## Ausgangslage (live, 04.11.2026)
`maintenance` 0 Zeilen · `service_agreements` 0 · `service_tasks` 96 (alle App-Aufgaben mit `app_ref`) · `service_orders` 46.

## Vorgehen (rein additiv, wiederholbar)
1. Neue Tabellen: `maintenance_templates` (25 Vorlagen aus der App), `service_agreement_versions`, `service_order_items`, `maintenance_runs`.
2. Neue Spalten mit Standardwerten an `maintenance`, `service_tasks`, `service_orders`, `service_agreements`, `notifications`. Statuslisten nur **erweitert** (`skipped`, `paused`, `archived`).
3. Bestand:
   - Jeder bestehende Auftrag erhält **eine** Position (Titel/Beschreibung/Aufgabe übernommen, erledigte Aufträge → Position erledigt), Mangelbezug ergänzt.
   - `source_type` für Bestandsaufträge: `app_task` (App-Aufgabe), `emergency`, `finding` (mit Mangel) oder `manual`.
   - Aktive Verträge erhalten Fassung 1 in `service_agreement_versions`.
   - Alte Pläne mit `interval_days` werden als `custom`-Intervall in Tagen mit Startdatum = bisherige Fälligkeit übernommen; der alte Trigger rechnet nur noch für Pläne ohne neue Regel.
4. `run_recurring_agreements()` und `request_approval()` wurden mit identischem Verhalten neu angelegt, ergänzt um die Doppelplanungs-Sperre bzw. die Vertragsmaximum-Regel.
5. pg_cron-Job `husora-maintenance` (`29 3 * * *`).

App-Aufgaben (local-first) bleiben unberührt: `project_app_tasks` löscht nur Aufgaben mit `app_ref`; Server-Fälligkeiten haben kein `app_ref`. Die Geräte-Automatik bleibt für Offline-Nutzer; die Übernahme in Server-Pläne erfolgt per Knopf und schaltet die übernommenen Vorlagen auf dem Gerät aus.

## Prüfung
- Migration zweimal hintereinander angewendet: ohne Fehler (idempotent).
- `supabase db reset` (alle 49 Migrationen von Grund auf): ohne Fehler; alle 18 SQL-Testdateien grün.

## Rücknahme (falls nötig)
Die Migration ist additiv. Rücknahme ohne Datenverlust des Bestands: pg_cron-Job `husora-maintenance` entfernen, neue Trigger (`service_orders_source`, `service_orders_default_item`, `service_orders_zy_sync_items`, `service_orders_budget_guard`, `repairs_link_finding`, `service_tasks_occurrence_guard`, `service_agreements_versioning/_snapshot`, `soi_*`) löschen. Neue Spalten/Tabellen können bestehen bleiben.

## Manuelle Schritte in Supabase
Keine. pg_cron ist im Projekt aktiv; der Job wird von der Migration angelegt. Wartungspläne in der App erscheinen, sobald die Migration eingespielt ist (vorher blendet die App den Bereich mit Hinweis aus).
