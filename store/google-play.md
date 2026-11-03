# Google Play – Closed Testing (Husora Beta)

Stand: 03.11.2026 · Paket-ID **com.husora.app** · Track **Closed testing (alpha)**, später Production.
Rechtliche Angaben: Entwurf – finale juristische Prüfung offen.

## 1. Einmalige Einrichtung (Konto)
- [ ] Google Play Developer-Konto (Organisation empfohlen, D-U-N-S-Nummer für Organisationen)
- [ ] App anlegen: Name „Husora“, Standardsprache Deutsch, App (nicht Spiel), kostenlos
- [ ] **Play App Signing** aktivieren; eigenen **Upload-Schlüssel** erzeugen (nie ins Repository):
      `keytool -genkeypair -v -keystore husora-upload.jks -alias husora-upload -keyalg RSA -keysize 4096 -validity 10000`
- [ ] Upload-Schlüssel sicher ablegen (Passwortmanager) und als GitHub-Secrets hinterlegen (siehe README_BETA.md §C)
- [ ] Dienstkonto für Uploads: Google Cloud → Dienstkonto + JSON-Schlüssel → Play Console → Nutzer und Berechtigungen → Dienstkonto einladen (Rechte: Releases verwalten) → Secret `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`
- [ ] **Erstes AAB manuell hochladen** (Play Console → Testen → Geschlossener Test → Release erstellen). Erst danach funktioniert der automatische Upload aus GitHub Actions.

## 2. Store-Eintrag
| Feld | Inhalt |
|---|---|
| App-Name | Husora |
| Kurzbeschreibung (≤ 80) | Ferienhaus organisieren, kontrollieren und Servicepartner beauftragen. |
| Vollständige Beschreibung | siehe `store/listing-de.md` |
| Symbol | `assets/icons/icon-512.png` (512×512) – vor Production hochauflösende Vektorvorlage einsetzen |
| Feature-Grafik | 1024×500 – noch zu erstellen |
| Screenshots | min. 2 Smartphone-Screenshots (z. B. aus `tests/e2e/output/audit/…`), echte Geräte bevorzugt |
| Kategorie | Haus & Wohnen (alternativ Produktivität) |
| Kontakt-E-Mail | info@husora.de (bzw. Support-Adresse) |
| Datenschutzerklärung (URL) | https://husora26.github.io/markdown/?legal=privacy |

## 3. App-Inhalte (Policy-Erklärungen)
| Punkt | Angabe (Entwurf) |
|---|---|
| App-Zugriff | Anmeldung erforderlich → **Testzugang für Google** anlegen (eigenes Beta-Konto, ggf. Einladungscode) und Zugangsdaten in „App-Zugriff“ eintragen |
| Werbung | Keine Werbung |
| Einstufung (IARC) | Fragebogen: keine Gewalt/sexuellen Inhalte; Nutzer-Kommunikation (Chat Hausbesitzer ↔ Servicepartner) = ja → voraussichtlich „USK ab 0 / PEGI 3“ mit Hinweis „Nutzerinteraktion“ |
| Zielgruppe | Erwachsene (18+), nicht für Kinder |
| Nachrichten-Apps / Finanz / Gesundheit | nein |
| Kontolöschung | In der App: Einstellungen → Rechtliches → Konto löschen. Web-Link für die Store-Angabe: https://husora26.github.io/markdown/?legal=delete |
| Berechtigungen | nur `INTERNET`, `ACCESS_NETWORK_STATE`. Kamera/Fotos über die System-Auswahl ohne Kamera-Berechtigung; kein Standort, keine Kontakte, kein Mikrofon |
| Target SDK | 36 (Capacitor 8, `android/variables.gradle`), minSdk 24 |

## 4. Datensicherheit (Data Safety) – Entwurf
Grundlage: Datenschutzerklärung der App, Drittanbieter-Register (Migration 4400). Alle Übertragungen verschlüsselt (HTTPS). Löschung in der App möglich.

| Datentyp | Erhoben | Geteilt | Zweck | Optional |
|---|---|---|---|---|
| Name, E-Mail-Adresse | ja | nein¹ | Kontoverwaltung, Kommunikation mit Servicepartnern | nein (Konto) |
| Adresse (Ferienhaus) | ja | nein¹ | App-Funktion | ja |
| Telefonnummer | ja | nein¹ | App-Funktion | ja |
| Fotos, Dateien/Dokumente | ja | nein¹ | App-Funktion (Hauskontrolle, Dokumente) | ja |
| Nachrichten (In-App) | ja | nein¹ | App-Funktion (Auftragschat) | ja |
| Finanzinfos (eigene Kosten, Rechnungen als Datensatz) | ja | nein¹ | App-Funktion | ja |
| App-Interaktionen | ja | nein | Analyse – **nur mit Einwilligung** | ja |
| Absturzprotokolle/Diagnose | ja | nein | Fehlerbehebung (Fehlerberichte) | ja (abschaltbar) |
| Geräte-/sonstige IDs | ja (zufällige App-Geräte-ID für den Abgleich) | nein | App-Funktion | nein |
| Standort, Kontakte, Kalender, Gesundheit | nein | – | – | – |

¹ Weitergabe an einen Servicepartner erfolgt nur, wenn der Nutzer ihn selbst beauftragt bzw. das Objekt freigibt (vom Nutzer veranlasst). Auftragsverarbeiter (Supabase u. a.) gelten nicht als „Teilen“. **Juristische Prüfung offen.**

## 5. Closed Testing
- [ ] Tester-Liste (E-Mail-Liste oder Google Group), zunächst 10–20 Personen
- [ ] Opt-in-Link kopieren → in Husora Admin → „Release & Wartung“ → Android Beta-Link eintragen (erscheint auf `beta.html` und in der App)
- [ ] Länder: Deutschland, Schweden (+ weitere nach Bedarf)
- [ ] Feedback-Kanal: In-App-Feedback (primär), Support-E-Mail
- [ ] Hinweis: Für neue persönliche Entwicklerkonten verlangt Google vor Production einen geschlossenen Test mit Mindestanzahl Testern über einen Mindestzeitraum – aktuelle Vorgabe in der Play Console prüfen.
