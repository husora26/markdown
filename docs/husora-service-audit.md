# Husora – Bestandsaufnahme Service & Wartung (Phase 0)

Stand 04.11.2026 · Grundlage: „Husora Hybrid Service & Smart Maintenance Architecture“ · Repository `husora26/markdown`, Supabase-Projekt `ggsoygxmcsmrsrbmplrz` (Beta).

## 1. Technik

| Bereich | Befund |
|---|---|
| Frontend | **Eine** Datei `index.html` (Vanilla JS, Template-Literale), enthält Hausbesitzer-App **und** Partner-Portal (`pp.*`). Kein Build, kein TypeScript, keine Zod-Bibliothek. Native Hülle: Capacitor (`android/`, `ios/`). |
| Backend | Supabase: Postgres + RLS + RPCs (`security definer`, `search_path=''`), Storage (private Buckets), pg_cron (live aktiv, 3 Jobs), Edge Functions vorhanden, aber für diese Domäne nicht nötig (Logik als RPC/Transaktion). |
| Typen/Validierung | Kein TypeScript im Projekt → Domänentypen als JSDoc/`docs`, **Validierung serverseitig in den RPCs** (Check-Constraints + Prüfungen), wie im gesamten Projekt. |
| Tests | SQL-Tests `supabase/tests/*.sql` (CI), Browser-E2E `tests/e2e/*.js` (Playwright, CI). |
| Mandant | `organizations` (homeowner / service_partner / both) + `organization_members.role`; Partnerbezug `service_partners.partner_organization_id`; Helfer `private.is_org_staff`, `can_read_org`, `is_partner_member`, `can_work_order`, `can_read_property`. |

## 2. Daten zur Laufzeit (live)
`maintenance` 0 · `service_agreements` 0 · `service_tasks` 96 (alle aus der App, `app_ref` gesetzt) · `service_orders` 46 · `automation_rules` 0 · pg_cron 3 Jobs. → Migration rein additiv möglich, keine Datenübernahme aus `maintenance` nötig.

## 3. Ist-/Soll-Matrix

| Soll (Spezifikation) | Bestand | Bewertung | Entscheidung |
|---|---|---|---|
| `maintenance_plans` | Tabelle **`maintenance`** (Titel, Kategorie, `interval_days`, `next_due_at`, `assigned_partner_id`, Status, RLS) – von der App nicht genutzt | teilweise vorhanden | **erweitern** (Intervalltypen, Zeitzone, Zuständigkeit, Modus, Vertrag, Budget, Saison, Checkliste, Erinnerung). Name bleibt `maintenance`, in der App „Wartungsplan“. |
| Wartungslogik in der App | Browser-Automatik `runAutoTasks()` (Vorlagen mit Intervall in Tagen/Monaten/Saison) in `localStorage` | vorhanden, aber **nicht serverseitig**, nicht idempotent über Geräte | bleibt für Offline-Nutzer; Übernahme in Server-Pläne per Knopf („In Wartungsplan übernehmen“). Keine zweite Vorlagenliste: Vorlagen werden als `maintenance_templates` in die DB übernommen. |
| `maintenance_templates` | Vorlagen nur im JS (`defaultAutoTemplates`, 20+) | im Client vorhanden | **neu** als Tabelle, aus denselben Vorlagen befüllt |
| `maintenance_occurrences` | **`service_tasks`** = Aufgabe je Termin, Aufträge hängen per `service_task_id` daran, Statusabgleich Auftrag→Aufgabe existiert | Äquivalent vorhanden | **Fälligkeit = `service_tasks`** + `maintenance_id`, `generation_key` (eindeutig), `local_scheduled_date`, `assigned_type`, `blocked_reason`, `skip_reason`, Status `skipped`/`owner_action`/`blocked`. Kein paralleles Aufgabensystem. |
| `service_orders` | vorhanden inkl. Status-Engine (`order_transition_allowed`), Freigaben, Kosten, Rechnung | vorhanden | **wiederverwenden**; Ergänzung `source_type`, `owner_confirmed_at`, `owner_dispute_note`, `agreement_version`. Statuswerte bleiben stabil (Mapping siehe State-Machine). |
| `service_order_items` | – (1 Auftrag = 1 Aufgabe) | fehlt | **neu**: Positionen je Fälligkeit, Bündelung, Checkliste/Ergebnis je Position; Rückwärts: bestehende Aufträge erhalten 1 Position. |
| `service_execution_logs` | `service_order_cost_items` (Zeit, Material, Anfahrt), `photos`/`documents` mit `service_order_id`, `service_order_events` | vorhanden | **wiederverwenden** + Checklisten-Ergebnis an `service_order_items`. |
| `service_order_events` | vorhanden (append-only, Statuswechsel, Nachrichten) | vorhanden | wiederverwenden, neue Ereignistypen |
| `service_agreements` | vorhanden (Jahresvertrag: Leistungen, Besuche/Jahr, Jahrespreis, Laufzeit, Vorschlag/Annahme, Auto-Planung 3900) | teilweise | **erweitern**: Preisart, Preis/Einsatz, Max. je Einsatz, Budget je Zeitraum, Steuer, Freigabeart, Pausieren, Version, Zustimmungszeitpunkte. |
| `service_agreement_versions` | – | fehlt | **neu** (unveränderliche Fassungen) |
| `service_order_quotes` | **`quotes`** + `respond_quote()` | vorhanden | wiederverwenden |
| Mehrkosten-Freigabe | `approval_requests` + `request_approval()` + Auto-Limit | vorhanden | wiederverwenden; zusätzlich Sperre „Ist-Kosten über Vertragsmaximum ohne Freigabe“ |
| `automation_runs` | vorhanden (je Regel) | teilweise | **neu `maintenance_runs`** (Lauf-ID, Zähler, Fehler) – `automation_runs` verlangt eine Regel-ID |
| `maintenance_notifications` | `notifications` + Präferenzen + Push/E-Mail-Weiterleitung | vorhanden | wiederverwenden, Spalte `dedupe_key` (eindeutig) für Erinnerungen |
| Hauskontrolle → Mangel → Auftrag | `inspections`/`inspection_items`, `repairs` (Mangel), `respond_repair_offer`, Automatik `create_repair_order` | vorhanden | wiederverwenden; Finding-Quelle an Position (`source_repair_id`) |
| Partnerzuordnung | `property_service_assignments`, `service_partners` | vorhanden | Pflichtprüfung bei Plan mit Partner |
| Scheduler | pg_cron + `run_scheduled_automations`, `run_recurring_agreements` | vorhanden | **neu `run_maintenance_scheduler()`** mit Advisory-Lock, täglich per pg_cron; bestehende Vertragsplanung bleibt für Verträge ohne Wartungsplan |
| Partner-Verfügbarkeit | `service_partner_absences` | teilweise | bei Auto-Auftrag geprüft |

## 4. Offene technische Punkte / Annahmen
- **Kein TypeScript/Zod** im Projekt → keine Einführung einer Build-Kette (Regel „bestehende Architektur nutzen“). Typen in `docs/husora-hybrid-service-architecture.md`, Validierung in SQL.
- **Objektzeitzone:** es gibt keine Zeitzone je Haus, nur je Organisation (`organizations.timezone`). Der Plan speichert seine Zeitzone (Standard: Organisation).
- Hausbesitzer-Aufgaben der App sind local-first (`localStorage` → `app_data` → `service_tasks`). Server-Fälligkeiten (ohne `app_ref`) werden vom App-Abgleich **nicht** gelöscht (Abgleich löscht nur `app_ref`-Aufgaben) – geprüft im Code von `project_app_tasks`.
- Zahlungen sind in der Beta aus; es wird **keine** Abbuchung implementiert.
