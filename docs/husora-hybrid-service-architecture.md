# Husora – Hybrid Service & Smart Maintenance: Architektur

Stand 04.11.2026 · Migration `20261030004700_hybrid_service.sql` · Grundlage: Spezifikation „Hybrid Service Architecture“ und Bestandsaufnahme `docs/husora-service-audit.md`.

## 1. Grundsatz: erweitern statt Parallelsystem

| Ebene (Spezifikation) | Umsetzung in Husora | Art |
|---|---|---|
| A. Wartungsplan (`maintenance_plan`) | `public.maintenance` | erweitert |
| B. Fälligkeit (`maintenance_occurrence`) | `public.service_tasks` (Server-Fälligkeiten mit `maintenance_id`) + Lesesicht `public.maintenance_occurrences` | erweitert + Sicht |
| C. Serviceauftrag (`service_order`) | `public.service_orders` (bestehende Status-Engine) + **neu** `public.service_order_items` | erweitert + neu |
| D. Ausführungsnachweis | `service_order_cost_items`, `photos`, `documents`, `service_order_events`, Checkliste/Ergebnis je Position | wiederverwendet |
| Dauerauftrag | `public.service_agreements` + **neu** `public.service_agreement_versions` | erweitert + neu |
| Vorlagen | **neu** `public.maintenance_templates` (aus den bisherigen App-Vorlagen) | neu |
| Scheduler | **neu** `public.run_maintenance_scheduler()` + `public.maintenance_runs`, pg_cron `husora-maintenance` (täglich 03:29 UTC) | neu |
| Benachrichtigungen | `public.notifications` + Spalte `dedupe_key` | erweitert |
| Mehrkosten | `approval_requests`, `request_approval()`, `respond_approval()` | wiederverwendet (Vertragsmaximum ergänzt) |
| Angebote | `quotes`, `respond_quote()` | wiederverwendet |
| Mangel → Auftrag | `inspections`/`repairs`, `respond_repair_offer`, Automatik `create_repair_order` | wiederverwendet, Quelle `finding` |

Kein TypeScript/Zod im Projekt: Validierung liegt – wie im ganzen Projekt – serverseitig in Check-Constraints und `security definer`-RPCs (`search_path=''`). Die Organisation wird **immer aus dem Objekt** abgeleitet, nie aus der Eingabe.

## 2. Datenmodell (Kurzfassung)

**`maintenance` (Plan)**: `interval_type` (once, daily, weekly, every_n_weeks, monthly, every_n_months, quarterly, semi_annual, yearly, seasonal, custom), `interval_value`, `interval_unit`, `weekday`, `day_of_month`, `local_time`, `timezone`, `start_date`, `end_date`, `season_start_month/end_month`, `automation_mode` (owner_approval, agreement_auto, owner_self_service, unassigned), `assigned_type`, `assigned_partner_id`, `service_agreement_id`, `budget_limit`, `currency`, `reminder_days` (Standard 7/1/0), `lead_days` (Standard 14), `checklist`, `priority`, `status` (active, paused, archived …), `archived_at`.

**`service_tasks` (Fälligkeit)**: zusätzlich `maintenance_id`, `generation_key` (eindeutig: `Plan-ID:lokales Datum`), `local_scheduled_date` (Serienanker, unverändert bei Verschiebung), `assigned_type`, `owner_action` (self_service, approval_required, assign_partner, blocked), `blocked_reason`, `skipped_at`, `skip_reason`; Status zusätzlich `skipped`.

**`service_orders`**: zusätzlich `source_type` (manual, app_task, maintenance, agreement_auto, finding, emergency), `agreement_version`, `owner_confirmed_at/by`, `owner_dispute_note`.

**`service_order_items`**: Position je Fälligkeit (`occurrence_id`), `source_repair_id`, Menge/Einheit/Preis, `line_total` (berechnet), `status` (open, done, not_done, skipped), `checklist`, `checklist_results`, `partner_note`. Jeder Auftrag hat mindestens eine Position (Trigger, Bestand nachgetragen).

**`service_agreements`**: zusätzlich `pricing_type` (annual, per_visit, hourly, flat, quote_required), `unit_price`, `max_price_per_visit`, `budget_period_amount`, `budget_period`, `tax_mode`, `approval_mode` (owner_each, auto_within_limits), `categories`, `window_months`, `version`, `owner_accepted_at`, `partner_accepted_at`, `paused_at`; Status zusätzlich `paused`.

## 3. Terminberechnung

`private.maintenance_next_date(plan, nach_datum)` rechnet immer vom **Startanker** (kein Drift):
- Tages-/Wochenintervalle: Anker + k·Schritt (Wochentag optional).
- Monatsintervalle: Monat des Starts + k·Schritt, Tag = `day_of_month` bzw. Starttag, **auf das Monatsende begrenzt** (31. → 28./29.02., 30.04.); Schaltjahr automatisch.
- Saison (auch über den Jahreswechsel, z. B. Dez–März) filtert Termine.
- `end_date` beendet die Serie.
- Lokales Datum + Uhrzeit werden in der **Zeitzone des Plans** (Standard: Organisation) in UTC umgerechnet → 09:00 bleibt 09:00 über die Zeitumstellung.
- Vorschau im Formular: `public.maintenance_preview(plan_json, anzahl)` (ohne Datenzugriff).

## 4. Scheduler

`public.run_maintenance_scheduler(p_horizon_days default 60)` – nur Server (pg_cron), nicht für Clients ausführbar:
1. Globale Sperre `pg_try_advisory_xact_lock` – ein paralleler Lauf wird als `skipped_locked` protokolliert.
2. Je aktivem Plan (max. 5000, Fehler je Plan isoliert in eigener Subtransaktion) `private.maintenance_schedule_plan()` mit Sperre je Plan:
   - Fälligkeiten bis Heute + max(Vorlauf, Horizont) erzeugen, `on conflict (generation_key) do nothing` (idempotent). Keine rückwirkenden Termine außer bei Einmal-Plänen.
   - Fälligkeiten im Vorlauf durch das Regelwerk schicken (siehe Auftragsfluss).
   - Erinnerungen an den Eigentümer (7/1/0 Tage, einmalig je Stufe über `dedupe_key`), einmaliger Überfällig-Hinweis, Vortags-Erinnerung an den Partner.
   - `next_due_at` des Plans aktualisieren.
3. Lauf in `maintenance_runs` protokollieren (Zähler: Pläne, erzeugt, Aufträge, blockiert, Eigentümeraktionen, Erinnerungen, Fehlerliste).

Hausbesitzer können einen eigenen Plan sofort prüfen lassen: `public.refresh_maintenance_plan(plan)`.

## 5. Oberflächen

**Hausbesitzer-App → Partner-Portal → Reiter „Wartung“**: Kennzahlen (Handlungsbedarf, beim Partner, blockiert, erledigt 30 Tage), Fälligkeiten mit Filter (Handlungsbedarf, anstehend, beim Partner, erledigt, alle), Aktionen *Beauftragen*, *Selbst erledigt*, *Überspringen* (Grund Pflicht), *Verschieben* (nur diese Fälligkeit), Mehrfachauswahl → *Gemeinsam beauftragen* (ein Auftrag, mehrere Positionen), Wartungspläne anlegen/bearbeiten mit Vorlage, Zuständigkeit, Dauerauftrag, Budget, Checkliste und **Live-Vorschau der nächsten Termine**, Pausieren/Fortsetzen/Archivieren, Übernahme der bisherigen Geräte-Automatik in Server-Pläne. Auf der Seite „Serviceaufgaben“ erscheint ein Hinweis mit Sprung in die Wartung, sobald Entscheidungen offen sind.

**Hausbesitzer → Aufträge**: Herkunft (Wartungsplan, automatisch aus Dauerauftrag mit Fassung und Preisrahmen, Mangel, Notfall), Positionen mit Checklisten-Ergebnis, nach Abschluss *Abschluss bestätigen* oder *Rückfrage / Mangel*.

**Beide Seiten → Jahresverträge/Daueraufträge**: Konditionen (Preisart, Preis je Einsatz, Maximum je Einsatz, Budget je Zeitraum, Freigabeart, Leistungsbereiche, Fassung), *Konditionen ändern* (neue Fassung, Zustimmung der anderen Seite nötig), *Pausieren/Fortsetzen*.

**Partner-Portal → Auftrag**: Herkunftshinweis inkl. Vertragsfassung und freigegebenem Rahmen, Positionen mit abhakbarer Checkliste und *Erledigt / Nicht erledigt / Entfällt* je Position, Bestätigungsstatus des Kunden. Partner sehen **keine** Wartungspläne (Budget/Notizen bleiben privat), nur Aufträge und Positionen.

## 6. Bekannte Grenzen
- Zeitzone je Objekt existiert nicht; der Plan speichert seine Zeitzone (Standard: Organisation).
- Zahlungen/Abbuchungen sind nicht implementiert (Beta: Zahlungen aus).
- Partner-Verfügbarkeit wird nur über Betriebsabwesenheiten (`service_partner_absences`) geprüft, nicht über einzelne Mitarbeiter.
- Bündelungsvorschläge sind eine manuelle Mehrfachauswahl (gleiches Objekt, ≤ 14 Tage Abstand, ≤ 10 Fälligkeiten); eine automatische Bündelung findet nicht statt.
