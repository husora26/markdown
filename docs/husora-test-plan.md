# Husora – Testplan Hybrid Service

## Automatisiert
| Ebene | Datei | Inhalt | Stand |
|---|---|---|---|
| SQL | `supabase/tests/hybrid_service_test.sql` | 97 Prüfungen: Terminregeln (Monatsende, Schaltjahr, Quartal, Halbjahr, Wochentag, n Wochen/Monate, Saison über Jahreswechsel, Enddatum, einmalig, eigenes Intervall, Zeitumstellung), Erzeugung/Idempotenz/Erzeugungsschlüssel, Laufprotokoll, Erledigen/Überspringen/Verschieben, Lösch- und Abschlussschutz, Freigabe-Modus inkl. Duplikatschutz der Hinweise, Bündelung, Positions-Dokumentation, Abschluss/Rückfrage/Bestätigung, Ablehnung ohne Neubeauftragung, Dauerauftrag-Automatik (Preis, Version, Position), keine Doppelaufträge, Budgetüberschreitung, alle Vertragsprüfgründe, Vertragsänderung → blockiert → nach Zustimmung Fassung 2, Pausieren, RLS/Mandantentrennung | grün |
| SQL-Regression | alle `supabase/tests/*.sql` (18 Dateien) nach `supabase db reset` | | grün |
| Browser (E2E) | `tests/e2e/hybrid.js` | Szenario A (wöchentlich, Dauerauftrag 40 €, Aufträge automatisch, kein Duplikat, Partneransicht mit Fassung), Szenario B (vierteljährlich mit Terminvorschau, Freigabe, Bündelung von 2 Fälligkeiten, Checkliste je Position beim Partner, Bestätigung durch den Eigentümer), Szenario C (Mangel → Quelle „Aus Mangel“), Szenario D (Mehrkosten über Maximum nicht automatisch freigegeben, Abschluss gesperrt, nach expliziter Freigabe möglich), Mandantentrennung, Hinweis auf der Aufgaben-Seite, Dunkelmodus | 18/18 grün |
| Browser-Regression | `tests/e2e/run.sh` (alle Suiten) | | siehe Bericht |

## Manuell (Beta)
1. Plan „Rasen mähen, wöchentlich, April–Oktober, selbst“ anlegen → Vorschau prüfen → Erinnerung 7/1/0 Tage erhalten.
2. Plan mit Partner „Freigabe je Einsatz“ → Hinweis „Service erforderlich“ → beauftragen → Partner nimmt an → Positionen abhaken → Abschluss → bestätigen.
3. Dauerauftrag auf „automatisch im Rahmen“ stellen (beide Seiten müssen der neuen Fassung zustimmen) → Plan „automatisch über Dauerauftrag“ → Aufträge erscheinen beim Partner.
4. Konditionen ändern → Automatik pausiert bis zur Zustimmung (Grund an der Fälligkeit sichtbar).
5. Geräte-Automatik in Wartungspläne übernehmen → keine doppelten Aufgaben.
6. Hell/Dunkel, 390 px Breite, Schriftgröße groß.

## Abnahmekriterien (Definition of Done, Auszug)
- Keine kostenpflichtige Beauftragung ohne explizite Eigentümeranfrage oder gültigen, vollständig geprüften Dauerauftrag.
- Kein doppelter Auftrag/Hinweis bei wiederholten Läufen.
- Mandantentrennung in allen neuen Tabellen/RPCs nachgewiesen.
- Bestehende Funktionen (App-Aufgaben, Aufträge, Jahresverträge, Rechnungen) unverändert lauffähig (Regression).
