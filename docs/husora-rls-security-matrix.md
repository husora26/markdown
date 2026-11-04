# Husora – Sicherheits- und RLS-Matrix Hybrid Service

| Objekt | Eigentümer-Org (Staff) | Hausbesitzer (Objekteigentümer) | Partner (Mitglied) | Partner-Mitarbeiter (zugewiesen) | Fremde Org | anon |
|---|---|---|---|---|---|---|
| `maintenance` lesen | ja | ja | **nein** | nein | nein | nein |
| `maintenance` schreiben | nur über `save_maintenance_plan` / `set_maintenance_plan_status` | dito (`can_manage_property`) | nein | nein | nein | nein |
| `maintenance_occurrences` / Plan-Fälligkeiten | lesen; Aktionen nur über RPCs | dito | nein (sieht Positionen im Auftrag) | nein | nein | nein |
| `service_order_items` lesen | ja (`can_read_service_order`) | ja | ja (nicht `draft`) | ja (eigener Auftrag) | nein | nein |
| `service_order_items` schreiben | nein (nur Trigger/RPC) | nein | nur `update_order_item` bei laufendem Auftrag | dito | nein | nein |
| `service_agreement_versions` | lesen | – | lesen | nein | nein | nein |
| `update_agreement_terms`, `set_agreement_paused` | ja | – | ja (Partnerleitung) | nein | nein | nein |
| `confirm_service_completion` | ja | ja | nein | nein | nein | nein |
| `request_maintenance_service`, `complete/skip/reschedule_maintenance_task` | ja | ja | nein | nein | nein | nein |
| `maintenance_preview` | ja | ja | ja (rechnet nur, kein Datenzugriff) | ja | ja | nein |
| `run_maintenance_scheduler` | nein | nein | nein | nein | nein | nein (nur Server/pg_cron) |
| `refresh_maintenance_plan` | eigener Plan | eigener Plan | nein | nein | nein | nein |
| `maintenance_runs` | nein | nein | nein | nein | nein | nein (Plattform-Admins mit MFA) |
| `maintenance_templates` | lesen | lesen | lesen | lesen | lesen | nein |

Grundsätze:
- Organisation wird aus dem Objekt bzw. Vertrag/Auftrag abgeleitet, nie aus Client-Angaben (Test „Organisation kommt aus dem Objekt“).
- Alle RPCs `security definer` mit `search_path=''`, Berechtigungsprüfung am Anfang; interne Helfer (`private.*`) sind für Clients nicht ausführbar.
- Partner sehen Budgetgrenzen, Notizen und Pläne des Eigentümers nicht; sie sehen nur Aufträge, Positionen und den freigegebenen Preisrahmen.
- Kein Service-Role-Schlüssel im Client; Scheduler läuft serverseitig über pg_cron.
- Statusänderungen nur über die bestehende Status-Engine und geprüfte RPCs; der Fälligkeits-Wächter verhindert direkte Manipulation.
