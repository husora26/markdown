# Husora – Zustände Wartungsplan und Fälligkeit

## Wartungsplan (`maintenance.status`)
| Status | Bedeutung | Übergang |
|---|---|---|
| `active` | erzeugt Fälligkeiten | → `paused`, `archived` über `set_maintenance_plan_status()` |
| `paused` | erzeugt nichts; künftige offene Fälligkeiten ohne Auftrag werden entfernt, Historie bleibt | → `active` (erzeugt ab heute neu), `archived` |
| `archived` | beendet, `archived_at` gesetzt, Historie bleibt | – |

Änderung der Regel (`save_maintenance_plan` mit `id`): künftige, noch offene Fälligkeiten **ohne Auftrag** werden neu berechnet; erledigte, übersprungene und beauftragte bleiben unverändert.

## Fälligkeit (Speicherung in `service_tasks.status` + `owner_action`)
| Gespeichert | `owner_action` | Anzeige (`maintenance_occurrences.occurrence_status`) |
|---|---|---|
| `pending`, Datum > heute + Vorlauf | – | `upcoming` |
| `pending`, im Vorlauf | `self_service` | `due` |
| `pending` | `approval_required` / `assign_partner` / `blocked` | `owner_action_required` |
| `pending` (oder `assigned`), Datum < heute | beliebig | `overdue` |
| `assigned` (Auftrag angeboten) | – | `partner_requested` |
| `accepted` (Auftrag angenommen/geplant) | – | `assigned` |
| `in_progress` | – | `in_progress` |
| `completed` | – | `completed` |
| `skipped` (Grund Pflicht) | – | `skipped` |
| `cancelled` | – | `cancelled` |

### Übergänge
```
upcoming ──(Vorlauf erreicht, Regelwerk)──► due / owner_action_required / partner_requested (agreement_auto)
owner_action_required ──request_maintenance_service()──► partner_requested
partner_requested ──Partner nimmt an──► assigned ──Start──► in_progress ──Abschluss──► completed
partner_requested / assigned ──Ablehnung/Storno──► owner_action_required (approval_required, Grund gesetzt; KEINE automatische Neubeauftragung)
due / owner_action_required ──complete_maintenance_task()──► completed
due / owner_action_required ──skip_maintenance_task(Grund)──► skipped
pending ──reschedule_maintenance_task(Datum)──► pending (nur Termin, Serie unverändert)
Auftrag erledigt, Position „nicht erledigt“ ──► owner_action_required („Beim Einsatz nicht erledigt“)
Auftrag erledigt, Position „entfällt“ ──► skipped
Auftrag wieder geöffnet ──► in_progress
```

### Schutzregeln (Trigger `service_tasks_occurrence_guard`)
- Fälligkeiten aus Plänen werden von Clients nicht gelöscht.
- `maintenance_id`, `generation_key`, `local_scheduled_date`, `owner_action`, `blocked_reason`, `assigned_type` sind für Clients unveränderlich.
- `completed`/`skipped` bleiben abgeschlossen.
- Ausnahme nur im Systemkontext (geprüfte RPCs, Scheduler).
- Eine Plan-Fälligkeit gehört höchstens zu **einem** aktiven Auftrag (`soi_guard`); App-Aufgaben ohne Plan dürfen weiterhin an mehrere Partner zum Preisvergleich gehen.
