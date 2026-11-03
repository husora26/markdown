# Apple App Store Connect & TestFlight (Husora Beta)

Stand: 03.11.2026 · Bundle ID **com.husora.app** · iOS ab 15.0 (Capacitor 8).
Rechtliche Angaben: Entwurf – finale juristische Prüfung offen.

## 1. Einmalige Einrichtung
- [ ] Apple Developer Program (Organisation empfohlen; D-U-N-S-Nummer)
- [ ] Certificates, Identifiers & Profiles → Identifier **com.husora.app** registrieren (Capabilities: keine zusätzlichen nötig)
- [ ] App Store Connect → Meine Apps → „+“ → Name „Husora“, Primärsprache Deutsch, Bundle ID com.husora.app, SKU `husora-ios`
- [ ] App-Store-Connect-API-Schlüssel (Benutzer und Zugriff → Integrationen → Schlüssel, Rolle „App Manager“) → `.p8` herunterladen (nur einmal möglich)
- [ ] GitHub-Secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` (`base64 -i AuthKey_XXXX.p8`), `APPLE_TEAM_ID`
- Signatur: automatisch über den API-Schlüssel im Workflow (`-allowProvisioningUpdates`); keine Zertifikate im Repository.

## 2. TestFlight
| Feld | Inhalt |
|---|---|
| Beta-App-Beschreibung | Husora hilft Ferienhausbesitzern, ihr Haus zu organisieren, Kontrollen zu planen und Servicepartner zu beauftragen. Servicepartner erhalten Aufträge, dokumentieren Hauskontrollen und rechnen ab. Dies ist eine Vorabversion für eingeladene Tester. |
| Was soll getestet werden | 1) Registrierung, E-Mail bestätigen, Anmeldung, Passwort zurücksetzen · 2) Haus anlegen, Aufgaben, Hauskontrolle mit Fotos · 3) Servicepartner einladen und beauftragen · 4) Als Servicepartner: Auftrag annehmen, Kontrolle dokumentieren, Status ändern · 5) Dokumente hochladen und öffnen · 6) Datenexport und Konto löschen |
| Feedback | Bitte über den Button „Feedback“ bzw. 🐞 in der App melden (mit Geräteinfos), alternativ Screenshot-Feedback in TestFlight. |
| Kontakt | info@husora.de |
| Testzugang (für Beta-Review) | eigenes Testkonto + ggf. Einladungscode unter „Testinformationen → Anmeldeinformationen“ |

Ablauf: **Interne Tester** (bis 100 Teammitglieder, ohne Review) → danach **Externe Gruppe** (Beta App Review durch Apple) → öffentlichen TestFlight-Link erzeugen → in Husora Admin als „iPhone Beta-Link“ eintragen.

## 3. App-Datenschutz („App Privacy“) – Entwurf
Tracking (App Tracking Transparency): **nein** – keine Werbe-IDs, keine Verknüpfung mit Daten Dritter.

| Kategorie | Erhoben | Mit Identität verknüpft | Zweck |
|---|---|---|---|
| Kontaktdaten: Name, E-Mail, Telefon, Adresse | ja | ja | App-Funktionalität |
| Nutzerinhalte: Fotos, Dokumente, Nachrichten, sonstige Inhalte | ja | ja | App-Funktionalität |
| Kennungen: Nutzer-ID | ja | ja | App-Funktionalität |
| Nutzungsdaten: Produktinteraktion | ja (nur mit Einwilligung) | ja | Analyse |
| Diagnose: Absturz-/Fehlerdaten | ja | ja | App-Funktionalität (Fehlerbehebung) |
| Standort, Kontakte, Gesundheit, Finanzdaten (Zahlungsdaten) | nein | – | – |

## 4. App Review / Store-Angaben
| Punkt | Angabe |
|---|---|
| Altersfreigabe | 4+ (Fragebogen: keine bedenklichen Inhalte; Nutzer-Kommunikation über Aufträge) |
| Exportkonformität | `ITSAppUsesNonExemptEncryption = false` (nur Standard-HTTPS) – in Info.plist gesetzt |
| Anmeldepflicht | Konto erforderlich → Demo-Konto für Review angeben; Kontolöschung in der App vorhanden (Richtlinie 5.1.1(v)) |
| Käufe | In der iOS-App **keine** Buchung von Tarifen (Stripe-Checkout in nativen Builds gesperrt, Richtlinie 3.1.1). Vor einem Premium-Launch: In-App-Kauf oder Reader-/Business-Ausnahme prüfen |
| Berechtigungen | Kamera (`NSCameraUsageDescription`), Fotos (`NSPhotoLibraryUsageDescription`, `…AddUsageDescription`) – nur bei Nutzung |
| Datenschutz-URL | https://husora26.github.io/markdown/?legal=privacy |
| Support-URL | https://husora26.github.io/markdown/beta.html |
| Risiko Richtlinie 4.2 (Minimalfunktion/Web-Wrapper) | Husora nutzt native Funktionen (Kamera/Fotos, Teilen/Speichern, Deep Links, Offline-Speicher). Native Push folgt. In der Review-Notiz die Kernfunktionen für Servicepartner/Hausbesitzer beschreiben. |
