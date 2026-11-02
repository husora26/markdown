# Husora – GO/NO-GO-Bericht (Beta, Phasen 8–12, Security & Compliance)

Stand: 02.11.2026 · Grundlage: Beta-Mode-Brief, Architektur-Spezifikation (Phasen 8–12), Sicherheitsregeln des Projekts.
**Hinweis:** Die zweite Spezifikation „Husora_Legal_Beta_Compliance_Specification.md“ kam leer an (0 Bytes). Der Compliance-Test unten prüft daher gegen den Beta-Brief (§20 Datenschutz), die DSGVO-Grundsätze und die vorhandene Datenschutzerklärung – nicht gegen dieses Dokument.

## Gesamturteil

| Stufe | Urteil | Bedingung |
|---|---|---|
| Code & lokale Datenbank | **GO** | alle Tests grün (siehe unten) |
| Live-Datenbank (Supabase) | **NO-GO – sofort handeln** | Migrationen 3600–4300 sind noch nicht live; **4100 schließt eine kritische Sicherheitslücke, die live besteht** |
| Geschlossene Alpha/Closed Beta (eingeladene Tester) | **GO nach** Einspielen der Migrationen | Datenschutzerklärung (Entwurf) kurz rechtlich prüfen lassen |
| Öffentliche Beta / Launch | **NO-GO** | rechtliche Prüfung, Auftragsverarbeitungsverträge, leere Compliance-Spezifikation nachreichen, Push/E-Mail/KI einrichten |

## 1. Analyse (Bestand)

Vanilla-JS-Einzeldatei-App (`index.html`, GitHub Pages) + Supabase (Postgres, Auth, Storage, RLS, Edge Functions). Hausbesitzer-Daten sind local-first (Browser, Abgleich über `app_data`), Servicepartner/Aufträge serverseitig. Mandanten = `organizations`, Rollen über `organization_members`. Vorhandenes wurde erweitert statt dupliziert (Details: `BETA_MODE.md`, `ARCHITECTURE_AUDIT.md`).

## 2. Umgesetzt

| Bereich | Migration | Inhalt |
|---|---|---|
| Phase 8 Kosten & Freigaben | 3600 | Zeit/Material/Anfahrt je Auftrag, Rechnungsbetrag daraus, Mehrkosten-Freigaben, Auto-Freigabe-Limit |
| Beta Mode | 3700 | Schalter ohne Codeänderung, Analytics (nur nach Erfolg, ohne Doppelte), Feedback, 🐞 Fehler melden, Bewertung, 7-/30-Tage-Umfrage, Premium vormerken, Beta-Gruppen, Husora Beta Dashboard (Kennzahlen, Funnels, KPI-Ziele) |
| Phase 9 Benachrichtigungen & Chat | 3800 | Kategorien, Einstellungen je Kategorie (App/Push/E-Mail), Web-Push (Service Worker), E-Mail-Versand (Edge Function), Chat-Anhänge |
| Phase 10 Automatisierung | 3900 | Vertragsbesuche automatisch planen (ohne Doppelte), Mangel → Reparaturauftrag (Regel), pg_cron-Zeitplan |
| Phase 11 Matching/Bewertungen/Notdienst | 4000 | Bewertungen + Antwort, Angebotsvergleich, Notdienst anfordern, Bewertung/Notdienst in der Partnerauswahl |
| Security-Härtung | 4100 | siehe Abschnitt 3 |
| Phase 12 KI | 4200 | KI-Vorschläge (Kontrollbericht, Foto-Schaden, Kostenschätzung) über Edge Function `ai-assist`; nie automatisch übernommen |
| Compliance-Nachträge | 4300 | Aufbewahrungsfristen, Analytics-Allowlist, Löschfehler behoben, FK-Fix für Neuinstallation |

## 3. Security-Test

| Prüfung | Ergebnis |
|---|---|
| **Befund kritisch:** `anon`/`authenticated` hatten TRUNCATE/TRIGGER/REFERENCES auf allen Tabellen (Supabase-Standardrechte); TRUNCATE umgeht RLS | **behoben** (4100) – betrifft auch die Live-DB, dort noch offen |
| `anon` mit Schreibrechten auf 9 Tabellen (RLS blockte, aber unnötig) | **behoben** – nur noch anonymes Feedback |
| Sicherheits-Definer-Funktionen ohne Anmeldung ausführbar (4) | **behoben** |
| Alle Tabellen mit RLS · fester `search_path` · Schema `private` nicht für anon · nur `husora-public` öffentlich | ✅ (`security_test.sql`, dauerhaft in CI) |
| Organisation nie vom Client übernommen (Analytics, Feedback, Bewertungen, Kosten, Freigaben, KI) | ✅ serverseitig abgeleitet bzw. auf Mitgliedschaft geprüft |
| Fremde Organisation sieht keine Daten (Kosten, Freigaben, Bewertungen, Analytics, KI, Push, Einstellungen) | ✅ je Phase im SQL-Test geprüft |
| Hausbesitzer konnte Kostenpositionen in die Daten des Partners schreiben | **behoben** (3600) |
| KI-Ergebnisse fälschbar | ✅ nur `service_role` (Edge Function) schreibt Ergebnisse |
| Geheimnisse (Anthropic, VAPID, Resend, Dispatch-Secret) | ✅ nur Secrets/Vault, nicht im Code; kein Service-Role-Key im Client |
| Edge Functions | ⚠️ nicht deployt, lokal nicht typgeprüft (kein Deno in der Umgebung) |

## 4. Compliance-Test (DSGVO / Beta-Brief §20)

| Prüfung | Ergebnis |
|---|---|
| Keine Inhalte/Geheimnisse in Analytics | **verbessert:** Sperrliste ließ z. B. „title“ mit Inhalt durch → jetzt Allowlist (4300) ✅ |
| Recht auf Löschung | **Fehler behoben:** „Konto löschen“ scheiterte bei Nutzern mit Feedback (Trigger) ✅; Analytics, Bewertungen, Einstellungen, Push-Abos werden mitgelöscht ✅ |
| Aufbewahrung | ✅ Analytics 13 Monate, Bewertungen/KI 24 Monate, Push 6 Monate, Feedback 12 Monate – wöchentlich per pg_cron |
| Transparenz | **Datenschutzerklärung aktualisiert** (Entwurf): falsche Aussagen „keine Analyse“/„keine E-Mails“ korrigiert, Beta-Statistik, Benachrichtigungen und KI (Anthropic, USA, DPF/SCC) ergänzt |
| Opt-out Statistik · freiwillige Umfragen · KI nur auf Klick | ✅ |
| Datensparsamkeit KI | ✅ nur fachliche Angaben, keine Namen/Kontakte/Adressen |
| Rechtsgrundlage Analytics (berechtigtes Interesse vs. Einwilligung) | ⚠️ rechtliche Prüfung offen **[ext]** |
| Auftragsverarbeitungsverträge (Supabase, Stripe, Anthropic, Resend) | ⚠️ abschließen **[ext]** |
| Impressum | ⚠️ USt-IdNr. leer (`LEGAL_INFO.vatId`) |

## 5. Testergebnis

- **SQL (frische Datenbank, alle Migrationen + Seed):** 14 Testdateien, 350 Prüfungen, 0 Fehler (u. a. `rls_test` 84, `partner_portal_test` 53, `beta_mode_test` 30, `costs_approvals_test` 28, `reviews_quotes_test` 22, `security_test` 8, `compliance_test` 8).
- **E2E (Browser):** komplette Suite 44/44 grün, danach betroffene Suiten erneut grün; neue Suiten `costs`, `beta`, `notify`, `recurring`, `reviews`, `ai`.
- Migrationen idempotent (je zweimal eingespielt) und Neuinstallation von Grund auf erfolgreich.

## 6. Offene Punkte (priorisiert)

1. **Migrationen 3600–4300 live einspielen** – 4100 zuerst (Sicherheitslücke). Die Supabase-Bestätigung lief zweimal ab; alternativ im SQL Editor ausführen (alle idempotent).
2. Compliance-Spezifikation erneut hochladen (kam leer an) → Abgleich nachholen.
3. Rechtliche Prüfung Datenschutzerklärung/AGB, AV-Verträge, USt-IdNr. **[ext]**
4. Push/E-Mail einrichten (VAPID, Resend, Vault) und `ai-assist` deployen (`ANTHROPIC_API_KEY`) **[ext]** – bis dahin sind die Funktionen sichtbar deaktiviert bzw. Meldungen nur in der App.
5. Kleinere Lücken: Screenshot-Anhang bei Fehlerberichten, Anhänge vom Hausbesitzer senden, lokale Wartung → Server, KI-Vorschläge beim Hausbesitzer anzeigen, Angebotsanfrage an mehrere Partner in einem Schritt.
