# Husora – Ferienhausverwaltung

Kopie der Husora-App (Stand 30.10.2026, Quelle: `husora26/claude-version`, Commit `aab093f`).

Husora hilft beim Verwalten von Ferienhäusern in Schweden: Serviceaufgaben, Hauskontrolle mit Kontrollplänen und Prüfprotokollen, Saison-Checklisten, Reparaturen und Sanierungen, Servicepartner, Buchungen, Kosten mit Finanzierung und Jahresarchiv, Dokumente, Verträge, Zählerstände, Notfall & Zugang.

## Aufbau

- `index.html` – die komplette App (HTML, CSS und JavaScript in einer Datei)
- `assets/` – Bilder der Startseiten-Kacheln

## Starten

Die App läuft ohne Build-Schritt direkt im Browser:

```bash
python3 -m http.server 8080
# dann http://localhost:8080 öffnen
```

Alle Daten werden im Browser gespeichert (localStorage). Unter Einstellungen → Datensicherung lassen sie sich als Datei sichern und wiederherstellen.

## Datenbank (Supabase)

Unter [`supabase/`](supabase/README.md) liegt die komplette PostgreSQL-Datenbank für den Mehrbenutzerbetrieb:

- Migrationen mit Fremdschlüsseln, Indizes und Row Level Security
- Storage-Buckets
- Automatisierung, Partner-Ranking und Webhooks
- Seed-Daten und ein RLS-Test

Installation, Konfiguration und Tests beschreibt [`supabase/README.md`](supabase/README.md).
