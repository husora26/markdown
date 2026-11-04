# Husora – Daueraufträge / Servicevereinbarungen

Die bestehenden **Jahresverträge** (`service_agreements`) sind die Daueraufträge. Erweitert um Konditionen, Versionierung und Pausieren.

## Konditionen
| Feld | Bedeutung |
|---|---|
| `pricing_type` | `annual` (Jahrespreis ÷ Einsätze), `per_visit`, `flat` (Pauschale je Einsatz), `hourly`, `quote_required` |
| `unit_price` | Preis je Einsatz bzw. Stundensatz |
| `max_price_per_visit` | Obergrenze je Einsatz |
| `budget_period_amount` + `budget_period` | Budget je Monat/Quartal/Jahr/Laufzeit |
| `tax_mode` | Preise brutto / netto / steuerfrei (Anzeige) |
| `approval_mode` | `owner_each` (Standard: jede Beauftragung braucht Freigabe) oder `auto_within_limits` (Wartungspläne dürfen im Rahmen automatisch beauftragen) |
| `categories`, `task_titles` | Leistungsumfang (Kategorie oder Titel muss passen) |
| `window_months` | erlaubte Monate (optional) |

Nur `per_visit`, `flat` und `annual` (mit Einsatzzahl) ergeben einen eindeutigen Preis je Einsatz – bei `hourly`/`quote_required` blockiert die Automatik mit „Preis unklar“.

## Status
`proposed` → `active` (Zustimmung der anderen Seite) → `paused` ↔ `active` → `ended`; außerdem `declined`, `cancelled`.

## Versionierung
- Jede aktive Fassung wird unveränderlich in `service_agreement_versions` gespeichert (`snapshot` mit allen Konditionen).
- `update_agreement_terms(vertrag, konditionen)` erhöht `version`, setzt den Vertrag auf `proposed` (vorgeschlagen von der ändernden Seite) und benachrichtigt die andere Seite. **Bis zur Zustimmung beauftragt Husora nichts automatisch** (Grund „Dauerauftrag ist nicht aktiv“).
- Zustimmungszeitpunkte: `owner_accepted_at`, `partner_accepted_at`.
- Jeder automatisch erzeugte Auftrag speichert `agreement_version`.

## Zusammenspiel mit der bisherigen Vertragsplanung
`run_recurring_agreements()` (automatische Besuchsplanung aus Migration 3900) läuft unverändert für Verträge **ohne** Wartungsplan. Wird ein Vertrag von einem aktiven `agreement_auto`-Plan bedient, plant nur noch der Wartungs-Scheduler – keine doppelten Besuche.

## Abrechnung
Unverändert: Vertragsaufträge werden über die Jahres-/Sammelrechnung des Partners abgerechnet. Husora bucht nichts ab.
