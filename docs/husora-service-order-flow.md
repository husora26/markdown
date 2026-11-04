# Husora – Auftragsfluss (Hybrid-Beauftragung)

## Regelwerk je Fälligkeit (`private.maintenance_process_task`)
| Zuständigkeit / Modus | Ergebnis | Kosten ausgelöst? |
|---|---|---|
| Eigentümer · `owner_self_service` | Fälligkeit „selbst erledigen“, Erinnerungen | nein |
| offen · `unassigned` | „Zuständigkeit fehlt“, Hinweis an den Eigentümer | nein |
| Partner · `owner_approval` | „Service erforderlich – Freigabe nötig“, Hinweis an den Eigentümer; Auftrag erst nach `request_maintenance_service()` | erst nach Eigentümeranfrage **und** Annahme durch den Partner |
| Partner · `agreement_auto` | vollständige Vertragsprüfung → Auftrag (`offered`, Quelle `agreement_auto`, Preis aus Vertrag, Vertragsfassung) **oder** `blocked` mit Grund + Hinweis | nur im vorab vereinbarten Rahmen |

### Vertragsprüfung (`private.validate_service_agreement`)
Reihenfolge der Gründe (maschinenlesbar): `not_found`, `paused`, `not_active`, `approval_mode` (Vertrag erlaubt keine Automatik), `expired` (Laufzeit), `wrong_property`, `wrong_partner`, `partner_inactive` (nicht verbunden/getrennt), `partner_not_assigned` (Objektzuordnung), `out_of_scope` (Kategorie bzw. Leistungstitel), `outside_window` (vereinbarte Monate), `price_unclear` (Stundenpreis/Angebot), `over_max_per_visit`, `over_plan_budget`, `over_period_budget` (Summe im Monat/Quartal/Jahr/Laufzeit), `partner_absent`. Zusätzlich: kein zweiter aktiver Auftrag für dieselbe Fälligkeit (`recurrence_key = 'mt:'||generation_key`, `soi_guard`).

Blockierte Fälligkeiten werden bei jedem Lauf erneut geprüft (z. B. nachdem der Partner einer neuen Vertragsfassung zugestimmt hat). Hinweise sind je Grund nur einmal (Duplikatschutz).

## Auftragsstatus (bestehende Status-Engine, unverändert)
| Spezifikation | Husora | Bemerkung |
|---|---|---|
| draft | `draft` | |
| approval_required | Fälligkeit `owner_action = approval_required` | vor dem Auftrag |
| requested | `offered` | Anfrage beim Partner |
| quoted | `offered` + `quotes` | bestehende Angebotsfunktion |
| accepted / scheduled | `accepted` / `scheduled` | |
| in_progress | `in_progress` (+ `waiting_customer`, `waiting_parts`) | |
| completion_submitted | `completed` **ohne** `owner_confirmed_at` | „Wartet auf Bestätigung“ |
| completed | `completed` **mit** `owner_confirmed_at` | `confirm_service_completion(..., true)` |
| disputed | `completed` mit `owner_dispute_note` | `confirm_service_completion(..., false, Text)`; Partner kann über die bestehende Funktion wieder öffnen |
| rejected / cancelled | `rejected` / `cancelled` | Fälligkeit zurück an den Eigentümer |
| blocked | Fälligkeit `owner_action = blocked` | es entsteht **kein** Auftrag |

Die bestehenden Statuswerte blieben bewusst stabil, damit Rechnungen, Kalender, Sammelabrechnung, Bewertungen und Automatiken unverändert weiterlaufen.

## Bündelung
`request_maintenance_service(fälligkeiten[], partner, hinweis, preisrahmen)`: 1–10 Fälligkeiten desselben Objekts innerhalb von 14 Tagen → **ein** Auftrag, je Fälligkeit **eine** Position (Checkliste aus dem Plan). Wiederholter Aufruf liefert denselben Auftrag. Bündelung umgeht keine Freigabe: der Aufruf **ist** die ausdrückliche Anfrage des Eigentümers.

## Ausführung
- Partner: `update_order_item(position, status, checklisten_ergebnis, notiz)` nur bei laufenden Aufträgen; Statusänderungen erscheinen im Auftragsverlauf (`item_updated`).
- Zeit/Material/Anfahrt, Fotos, Dokumente, Nachrichten: bestehende Funktionen.
- Abschluss: Positionen „offen“ werden „erledigt“; erledigte Positionen schließen ihre Fälligkeit, „nicht erledigt“ geht an den Eigentümer zurück, „entfällt“ wird übersprungen; Plan erhält `last_performed_at` und neue `next_due_at`.

## Kostengrenzen (Szenario D)
- Aufträge aus `agreement_auto` dürfen nicht abgeschlossen werden, solange eine Mehrkosten-Freigabe offen ist oder die Ist-Kosten über dem freigegebenen Rahmen (`estimated_cost`, inkl. freigegebener Mehrkosten) liegen.
- `request_approval()` gibt Mehrkosten bei solchen Aufträgen **nie automatisch** frei, wenn dadurch das Vertragsmaximum je Einsatz überschritten würde – auch wenn ein Auto-Freigabelimit gesetzt ist.
- Keine Zustimmung durch Schweigen, keine Abbuchung.

## Mangel → Auftrag (Szenario C)
Bestehender Ablauf (Kontrolle → `repairs` → Angebot/Freigabe → Reparaturauftrag). Neu: Sobald ein Auftrag mit einem Mangel verknüpft ist, erhält er die Quelle `finding` und die Position den Bezug `source_repair_id`.
