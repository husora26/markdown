-- =============================================================================
-- HUSORA · Seed-Daten (nur lokale Entwicklung / Test – NICHT in Produktion laden)
-- =============================================================================
-- Testkonten (Passwort für alle: Husora!2026)
--   admin@husora.test        Admin der Testorganisation
--   eigentuemer@husora.test  Eigentümer von „Stuga Björkbacken“
--   partner@husora.test      Mitarbeiter von Nortivo Service AB (Servicepartner)
--   reinigung@husora.test    Reinigungskraft (cleaner)
--   betrachter@husora.test   Nur-Lesen (viewer)
--   fremd@husora.test        Admin einer ZWEITEN Organisation (Isolationstest)
--   support@husora.test      Husora-Super-Admin (interne Verwaltung)
--
-- Feste UUIDs, damit Tests und Doku stabil darauf verweisen können.
-- Termine sind relativ zu „heute“, damit die Daten immer aktuell wirken.

-- -----------------------------------------------------------------------------
-- Auth-Benutzer (der Trigger on_auth_user_created legt public.users an)
-- -----------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
       extensions.crypt('Husora!2026', extensions.gen_salt('bf')), now(),
       '{"provider": "email", "providers": ["email"]}'::jsonb,
       jsonb_build_object('first_name', u.first_name, 'last_name', u.last_name, 'language', u.lang),
       now(), now(), '', '', '', ''
from (values
  ('aaaaaaaa-0000-4000-8000-000000000001'::uuid, 'admin@husora.test',       'Anna',   'Admin',      'de'),
  ('aaaaaaaa-0000-4000-8000-000000000002'::uuid, 'eigentuemer@husora.test', 'Erik',   'Lindqvist',  'de'),
  ('aaaaaaaa-0000-4000-8000-000000000003'::uuid, 'partner@husora.test',     'Pelle',  'Nortivo',    'sv'),
  ('aaaaaaaa-0000-4000-8000-000000000004'::uuid, 'reinigung@husora.test',   'Rita',   'Reinigung',  'de'),
  ('aaaaaaaa-0000-4000-8000-000000000005'::uuid, 'betrachter@husora.test',  'Bernd',  'Betrachter', 'de'),
  ('aaaaaaaa-0000-4000-8000-000000000006'::uuid, 'fremd@husora.test',       'Frieda', 'Fremd',      'de'),
  ('aaaaaaaa-0000-4000-8000-000000000007'::uuid, 'support@husora.test',     'Sam',    'Support',    'de')
) as u(id, email, first_name, last_name, lang);

insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       'email', now(), now(), now()
from auth.users u where u.email like '%@husora.test';

-- Profil-IDs fest vergeben (bbbbbbbb-… entspricht aaaaaaaa-…)
update public.users set id = ('bbbbbbbb' || substr(auth_user_id::text, 9))::uuid
where email like '%@husora.test';
update public.users set phone = '+46 70 111 22 33' where email = 'admin@husora.test';
update public.users set phone = '+49 171 555 0101', timezone = 'Europe/Berlin' where email = 'eigentuemer@husora.test';
update public.users set timezone = 'Europe/Stockholm' where email in ('partner@husora.test', 'reinigung@husora.test');
update public.users set is_super_admin = true where email = 'support@husora.test';

-- -----------------------------------------------------------------------------
-- Organisationen und Mitglieder
-- -----------------------------------------------------------------------------
insert into public.organizations (id, name, legal_name, country, currency, timezone, email, phone, website, settings)
values
  ('cccccccc-0000-4000-8000-000000000001', 'Husora Testorganisation', 'Husora Test AB', 'SE', 'SEK', 'Europe/Stockholm',
   'info@husora.test', '+46 565 100 00', 'https://husora.de',
   '{"partner_ranking": {"distance": 40, "availability": 20, "rating": 25, "price": 15, "max_distance_km": 120, "max_open_orders": 8}}'),
  ('cccccccc-0000-4000-8000-000000000002', 'Fremde Ferienhaus GmbH', 'Fremde Ferienhaus GmbH', 'DE', 'EUR', 'Europe/Berlin',
   'kontakt@fremd.test', null, null, '{}');

insert into public.organization_members (organization_id, user_id, role, status) values
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000001', 'admin',           'active'),
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002', 'owner',           'active'),
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000003', 'service_partner', 'active'),
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000004', 'cleaner',         'active'),
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000005', 'viewer',          'active'),
  ('cccccccc-0000-4000-8000-000000000002', 'bbbbbbbb-0000-4000-8000-000000000006', 'admin',           'active');

-- -----------------------------------------------------------------------------
-- Ferienhäuser
-- -----------------------------------------------------------------------------
insert into public.properties (id, organization_id, name, description, street, house_number, postal_code, city, region, country,
                               latitude, longitude, property_type, living_area_m2, land_area_m2, bedrooms, bathrooms,
                               max_guests, year_built, status, owner_user_id)
values
  ('dddddddd-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'Stuga Björkbacken',
   'Rote Holzstuga am Waldrand mit Sauna und Seeblick.', 'Björkbacksvägen', '12', '686 30', 'Sunne', 'Värmland', 'SE',
   59.836000, 13.143000, 'cabin', 86.00, 2400.00, 3, 1, 6, 1978, 'active', 'bbbbbbbb-0000-4000-8000-000000000002'),
  ('dddddddd-0000-4000-8000-000000000002', 'cccccccc-0000-4000-8000-000000000001', 'Stuga Solbacken',
   'Ferienhaus mit Kamin, Bootssteg und großem Grundstück am Siljan.', 'Solbacksvägen', '4', '792 30', 'Mora', 'Dalarna', 'SE',
   61.004000, 14.537000, 'holiday_home', 112.00, 3100.00, 4, 2, 8, 1992, 'active', null),
  ('dddddddd-0000-4000-8000-000000000003', 'cccccccc-0000-4000-8000-000000000002', 'Haus am See',
   'Gehört der fremden Organisation – darf für Husora-Testnutzer niemals sichtbar sein.', 'Seeweg', '1', '24306', 'Plön',
   'Schleswig-Holstein', 'DE', 54.162000, 10.421000, 'holiday_home', 95.00, 800.00, 3, 1, 5, 2005, 'active', null);

insert into public.property_users (property_id, user_id, role) values
  ('dddddddd-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002', 'owner');

insert into public.property_features (property_id, feature_type, feature_name, value) values
  ('dddddddd-0000-4000-8000-000000000001', 'heating',  'Heizung',         'Luftwärmepumpe + Kaminofen'),
  ('dddddddd-0000-4000-8000-000000000001', 'water',    'Wasser',          'Eigener Brunnen, Filteranlage'),
  ('dddddddd-0000-4000-8000-000000000001', 'sewage',   'Abwasser',        'Kleinkläranlage'),
  ('dddddddd-0000-4000-8000-000000000001', 'wellness', 'Sauna',           'Holzofen-Sauna im Nebengebäude'),
  ('dddddddd-0000-4000-8000-000000000001', 'access',   'Schlüsseltresor', 'Am Geräteschuppen, Code über die App'),
  ('dddddddd-0000-4000-8000-000000000002', 'heating',  'Heizung',         'Erdwärme'),
  ('dddddddd-0000-4000-8000-000000000002', 'water',    'Wasser',          'Kommunal'),
  ('dddddddd-0000-4000-8000-000000000002', 'outdoor',  'Bootssteg',       'Steg mit Ruderboot'),
  ('dddddddd-0000-4000-8000-000000000002', 'internet', 'WLAN',            'Glasfaser 250 Mbit/s');

-- -----------------------------------------------------------------------------
-- Servicearten (global; existieren bereits aus Migration 1700)
-- -----------------------------------------------------------------------------
insert into public.service_types (id, organization_id, code, name, description, category) values
  ('eeeeeeee-0000-4000-8000-000000000001', null, 'cleaning',            'Reinigung',            'End- und Zwischenreinigung, Wäschewechsel', 'housekeeping'),
  ('eeeeeeee-0000-4000-8000-000000000002', null, 'gardening',           'Gartenpflege',         'Rasen, Hecken, Laub',                        'outdoor'),
  ('eeeeeeee-0000-4000-8000-000000000003', null, 'snow_removal',        'Schneeräumung',        'Zufahrt, Wege, Dach',                        'outdoor'),
  ('eeeeeeee-0000-4000-8000-000000000004', null, 'inspection',          'Hauskontrolle',        'Abwesenheits- und Saisonkontrollen',         'inspection'),
  ('eeeeeeee-0000-4000-8000-000000000005', null, 'electrician',         'Elektrik',             'Elektroinstallation und -reparatur',         'craft'),
  ('eeeeeeee-0000-4000-8000-000000000006', null, 'plumbing',            'Sanitär',              'Wasser, Abwasser, Brunnen',                  'craft'),
  ('eeeeeeee-0000-4000-8000-000000000007', null, 'heating',             'Heizung',              'Wartung und Reparatur von Heizanlagen',      'craft'),
  ('eeeeeeee-0000-4000-8000-000000000008', null, 'roofing',             'Dach & Dachrinne',     'Dacharbeiten, Rinnenreinigung',              'craft'),
  ('eeeeeeee-0000-4000-8000-000000000009', null, 'general_maintenance', 'Hausmeisterservice',   'Kleinreparaturen und allgemeine Wartung',    'maintenance')
on conflict do nothing;  -- globale Arten legt Migration 1700 bereits an

-- -----------------------------------------------------------------------------
-- Servicepartner
-- -----------------------------------------------------------------------------
insert into public.service_partners (id, organization_id, company_name, contact_name, email, phone, website, street, postal_code,
                                     city, country, latitude, longitude, description, status, rating)
values
  ('ffffffff-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'Nortivo Service AB', 'Pelle Nortivo',
   'pelle@nortivo.test', '+46 70 222 33 44', 'https://nortivo.test', 'Storgatan 5', '686 31', 'Sunne', 'SE',
   59.838000, 13.140000, 'Hausmeisterservice, Kontrollen, Garten und Schnee rund um Sunne.', 'active', 4.70),
  ('ffffffff-0000-4000-8000-000000000002', 'cccccccc-0000-4000-8000-000000000001', 'Solrosen Städ', 'Sofia Ek',
   'sofia@solrosen.test', '+46 70 333 44 55', null, 'Kyrkogatan 2', '685 30', 'Torsby', 'SE',
   60.135000, 13.000000, 'Reinigung und Wäscheservice für Ferienhäuser.', 'active', 4.30),
  ('ffffffff-0000-4000-8000-000000000003', 'cccccccc-0000-4000-8000-000000000001', 'Mora Bygg & VVS AB', 'Mats Berg',
   'mats@morabygg.test', '+46 70 444 55 66', 'https://morabygg.test', 'Industrigatan 8', '792 32', 'Mora', 'SE',
   61.007000, 14.543000, 'Bau, Sanitär und Heizung in Dalarna.', 'active', 4.50),
  ('ffffffff-0000-4000-8000-000000000004', 'cccccccc-0000-4000-8000-000000000002', 'Fremder Hausservice', 'Fritz Fremd',
   'service@fremd.test', null, null, 'Hafenstraße 3', '24306', 'Plön', 'DE',
   54.160000, 10.420000, 'Partner der fremden Organisation.', 'active', 4.00);

insert into public.service_partner_users (service_partner_id, user_id, role) values
  ('ffffffff-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000003', 'owner');

insert into public.service_partner_services (service_partner_id, service_type_id, price_from, price_to, price_unit, currency) values
  ('ffffffff-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000004',  450.00,  650.00, 'visit', 'SEK'),
  ('ffffffff-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000002',  420.00,  520.00, 'hour',  'SEK'),
  ('ffffffff-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000003',  600.00,  900.00, 'job',   'SEK'),
  ('ffffffff-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000008',  550.00,  650.00, 'hour',  'SEK'),
  ('ffffffff-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000009',  480.00,  560.00, 'hour',  'SEK'),
  ('ffffffff-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000001', 1400.00, 1900.00, 'job',   'SEK'),
  ('ffffffff-0000-4000-8000-000000000002', 'eeeeeeee-0000-4000-8000-000000000001', 1100.00, 1600.00, 'job',   'SEK'),
  ('ffffffff-0000-4000-8000-000000000003', 'eeeeeeee-0000-4000-8000-000000000006',  690.00,  790.00, 'hour',  'SEK'),
  ('ffffffff-0000-4000-8000-000000000003', 'eeeeeeee-0000-4000-8000-000000000007',  720.00,  820.00, 'hour',  'SEK'),
  ('ffffffff-0000-4000-8000-000000000003', 'eeeeeeee-0000-4000-8000-000000000005',  750.00,  850.00, 'hour',  'SEK'),
  ('ffffffff-0000-4000-8000-000000000003', 'eeeeeeee-0000-4000-8000-000000000009',  560.00,  640.00, 'hour',  'SEK'),
  ('ffffffff-0000-4000-8000-000000000004', 'eeeeeeee-0000-4000-8000-000000000001',   45.00,   60.00, 'hour',  'EUR');

insert into public.service_partner_areas (service_partner_id, postal_code, city, region, radius_km) values
  ('ffffffff-0000-4000-8000-000000000001', null, 'Sunne',  'Värmland', 60),
  ('ffffffff-0000-4000-8000-000000000002', null, 'Torsby', 'Värmland', 80),
  ('ffffffff-0000-4000-8000-000000000003', null, 'Mora',   'Dalarna',  70),
  ('ffffffff-0000-4000-8000-000000000004', '24306', 'Plön', null,      30);

-- -----------------------------------------------------------------------------
-- Buchungsquelle (Zugangsdaten nur als Vault-Verweis)
-- -----------------------------------------------------------------------------
insert into public.booking_sources (id, organization_id, name, provider, api_endpoint, credentials_reference, active)
values
  ('5ecc0000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'Airbnb', 'airbnb',
   'https://api.airbnb.test/v2', 'vault:airbnb_husora_test', true),
  ('5ecc0000-0000-4000-8000-000000000002', 'cccccccc-0000-4000-8000-000000000001', 'Booking.com', 'booking_com',
   'https://supply-xml.booking.test', 'vault:booking_com_husora_test', true);

insert into public.webhook_endpoints (organization_id, endpoint, provider, secret_reference) values
  ('cccccccc-0000-4000-8000-000000000001', 'channel-manager', 'airbnb',      'vault:webhook_airbnb_secret'),
  ('cccccccc-0000-4000-8000-000000000001', 'booking',         'booking_com', 'vault:webhook_booking_com_secret');

-- -----------------------------------------------------------------------------
-- Hauskontrollvorlage mit Kontrollpunkten
-- -----------------------------------------------------------------------------
insert into public.inspection_templates (id, organization_id, name, description, property_type, version)
values ('7e000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'Abwesenheitskontrolle Standard',
        'Regelmäßige Kontrolle während Leerstand und nach jeder Abreise.', null, 1);

insert into public.inspection_template_items (template_id, category, name, description, sort_order, required, frequency) values
  ('7e000000-0000-4000-8000-000000000001', 'Außen',    'Dach und Dachrinne',            'Sichtprüfung auf Schäden, Laub, Eiszapfen',      10, true,  null),
  ('7e000000-0000-4000-8000-000000000001', 'Außen',    'Fenster und Türen',             'Unversehrt, verschlossen, keine Einbruchspuren',  20, true,  null),
  ('7e000000-0000-4000-8000-000000000001', 'Außen',    'Grundstück und Zufahrt',        'Umgestürzte Bäume, Schnee, Zugang frei',          30, false, null),
  ('7e000000-0000-4000-8000-000000000001', 'Außen',    'Briefkasten',                   'Leeren, wichtige Post melden',                    40, false, 'weekly'),
  ('7e000000-0000-4000-8000-000000000001', 'Innen',    'Raumtemperatur',                'Frostschutz mind. 8 °C, Heizung läuft',           50, true,  null),
  ('7e000000-0000-4000-8000-000000000001', 'Innen',    'Feuchtigkeit und Schimmel',     'Wände, Ecken, Bad, Keller',                       60, true,  null),
  ('7e000000-0000-4000-8000-000000000001', 'Innen',    'Schädlinge',                    'Mäuse, Insekten, Spuren',                         70, false, null),
  ('7e000000-0000-4000-8000-000000000001', 'Technik',  'Wasserleitungen und Hähne',     'Dicht, kein Frost, Hauptventil-Stellung',         80, true,  null),
  ('7e000000-0000-4000-8000-000000000001', 'Technik',  'Heizung / Wärmepumpe',          'Störmeldungen, Filter',                           90, true,  'monthly'),
  ('7e000000-0000-4000-8000-000000000001', 'Technik',  'Strom und Sicherungen',         'FI-Schalter, Zählerstand notieren',              100, false, 'monthly'),
  ('7e000000-0000-4000-8000-000000000001', 'Sicherheit', 'Rauchmelder',                 'Funktionstest',                                  110, true,  'quarterly'),
  ('7e000000-0000-4000-8000-000000000001', 'Sicherheit', 'Feuerlöscher',                'Plombe, Druckanzeige, Prüfdatum',                120, false, 'yearly');

-- -----------------------------------------------------------------------------
-- Automationsregeln (vor den Buchungen anlegen, damit sie greifen)
-- -----------------------------------------------------------------------------
insert into public.automation_rules (organization_id, name, description, trigger_type, trigger_config, condition_config, action_config, sort_order)
values
  ('cccccccc-0000-4000-8000-000000000001', 'Endreinigung nach Abreise',
   'Legt bei jeder Gästebuchung eine Endreinigung an und bietet sie dem besten Partner an.',
   'booking_created', '{"anchor": "check_out", "offset_hours": 1, "duration_hours": 3}',
   '{"exclude_owner_stays": true}',
   '{"type": "create_cleaning_task", "service_type_code": "cleaning", "title": "Endreinigung {property_name}", "description": "Endreinigung nach Aufenthalt {guest_name}", "priority": "high", "auto_assign": true}', 10),
  ('cccccccc-0000-4000-8000-000000000001', 'Kontrolle nach Abreise',
   'Plant nach jedem Check-out eine Hauskontrolle mit der Standardvorlage.',
   'booking_checkout', '{"anchor": "check_out", "offset_hours": 4}', '{}',
   '{"type": "create_inspection", "template_id": "7e000000-0000-4000-8000-000000000001", "notes": "Automatisch nach Abreise"}', 20),
  ('cccccccc-0000-4000-8000-000000000001', 'Mangel → Reparatur',
   'Erzeugt aus jedem Mangel der Hauskontrolle eine Reparatur.',
   'inspection_item_defect', '{}', '{"item_statuses": ["defect"]}',
   '{"type": "create_repair", "title_prefix": "Mangel: "}', 30),
  ('cccccccc-0000-4000-8000-000000000001', 'Absage → nächster Partner',
   'Lehnt ein Partner ab, wird der Auftrag dem nächstbesten Partner angeboten.',
   'service_order_rejected', '{}', '{}', '{"type": "offer_next_partner"}', 40),
  ('cccccccc-0000-4000-8000-000000000001', 'Stornierung → Aufgaben absagen',
   'Storniert offene Aufgaben und Kontrollen einer stornierten Buchung.',
   'booking_cancelled', '{}', '{}', '{"type": "cancel_booking_tasks"}', 50),
  ('cccccccc-0000-4000-8000-000000000001', 'Wartung fällig → Admin informieren',
   'Benachrichtigt die Verwaltung, wenn eine Wartung fällig wird.',
   'maintenance_due', '{}', '{}',
   '{"type": "notify", "roles": ["admin"], "include_owner": true, "title": "Wartung fällig: {item_name}", "message": "{property_name}: {item_name} ist fällig."}', 60);

-- -----------------------------------------------------------------------------
-- Buchungen (lösen die Automationen oben aus)
-- -----------------------------------------------------------------------------
insert into public.bookings (id, organization_id, property_id, booking_source_id, external_booking_id, source,
                             guest_first_name, guest_last_name, guest_email, guest_phone, check_in, check_out, guest_count, status, notes)
values
  ('b0000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001',
   null, null, 'direct', 'Jonas', 'Weber', 'jonas.weber@example.test', null,
   date_trunc('day', now()) - interval '20 days' + interval '15 hours', date_trunc('day', now()) - interval '13 days' + interval '11 hours',
   2, 'completed', 'Abgeschlossener Aufenthalt'),
  ('b0000000-0000-4000-8000-000000000002', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001',
   '5ecc0000-0000-4000-8000-000000000001', 'HMABC12345', 'airbnb', 'Familie', 'Müller', 'mueller@example.test', '+49 160 1234567',
   date_trunc('day', now()) + interval '3 days 15 hours', date_trunc('day', now()) + interval '10 days 11 hours',
   4, 'confirmed', 'Hund erlaubt'),
  ('b0000000-0000-4000-8000-000000000003', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001',
   null, null, 'direct', 'Lena', 'Schmidt', 'lena.schmidt@example.test', null,
   date_trunc('day', now()) + interval '14 days 15 hours', date_trunc('day', now()) + interval '21 days 11 hours',
   2, 'confirmed', null),
  ('b0000000-0000-4000-8000-000000000004', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000002',
   '5ecc0000-0000-4000-8000-000000000002', '4711-0815', 'booking_com', 'Sven', 'Karlsson', 'sven.k@example.test', null,
   date_trunc('day', now()) + interval '5 days 16 hours', date_trunc('day', now()) + interval '12 days 10 hours',
   6, 'confirmed', null),
  ('b0000000-0000-4000-8000-000000000005', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001',
   null, null, 'owner', 'Erik', 'Lindqvist', null, null,
   date_trunc('day', now()) + interval '30 days 12 hours', date_trunc('day', now()) + interval '37 days 12 hours',
   2, 'confirmed', 'Eigennutzung'),
  ('b0000000-0000-4000-8000-000000000006', 'cccccccc-0000-4000-8000-000000000002', 'dddddddd-0000-4000-8000-000000000003',
   null, null, 'direct', 'Geheim', 'Gast', 'geheim@example.test', null,
   date_trunc('day', now()) + interval '2 days 15 hours', date_trunc('day', now()) + interval '6 days 10 hours',
   2, 'confirmed', 'Fremde Organisation');

-- -----------------------------------------------------------------------------
-- Abgeschlossene Hauskontrolle mit einem Mangel (Mangel → Reparatur per Automation)
-- -----------------------------------------------------------------------------
insert into public.inspections (id, organization_id, property_id, template_id, inspector_user_id, service_partner_id, booking_id,
                                scheduled_at, status, notes)
values ('1a000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001',
        '7e000000-0000-4000-8000-000000000001', null, 'ffffffff-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001',
        date_trunc('day', now()) - interval '13 days' + interval '14 hours', 'scheduled', 'Kontrolle nach Abreise Weber');

update public.inspection_items set status = 'ok'
where inspection_id = '1a000000-0000-4000-8000-000000000001';
update public.inspection_items
set status = 'defect', notes = 'Dachrinne an der Nordseite verstopft und eingerissen.', estimated_cost = 2500.00
where inspection_id = '1a000000-0000-4000-8000-000000000001' and name = 'Dach und Dachrinne';
update public.inspection_items
set status = 'warning', notes = 'Batterie schwach, Ersatz beim nächsten Besuch.'
where inspection_id = '1a000000-0000-4000-8000-000000000001' and name = 'Rauchmelder';
update public.inspections
set status = 'completed', overall_status = 'warning',
    started_at = date_trunc('day', now()) - interval '13 days' + interval '14 hours',
    completed_at = date_trunc('day', now()) - interval '13 days' + interval '15 hours'
where id = '1a000000-0000-4000-8000-000000000001';

-- -----------------------------------------------------------------------------
-- Beispielaufgaben
-- -----------------------------------------------------------------------------
insert into public.service_tasks (id, organization_id, property_id, booking_id, service_type_id, title, description, priority,
                                  status, scheduled_start, scheduled_end, assigned_partner_id, assigned_user_id)
values
  ('7a000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000002', 'eeeeeeee-0000-4000-8000-000000000001', 'Wäschewechsel und Begrüßungskorb',
   'Bettwäsche für 4 Personen, Kaffee, Brot, Blumen.', 'normal', 'assigned',
   date_trunc('day', now()) + interval '3 days 10 hours', date_trunc('day', now()) + interval '3 days 12 hours',
   null, 'bbbbbbbb-0000-4000-8000-000000000004'),
  ('7a000000-0000-4000-8000-000000000002', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001',
   null, 'eeeeeeee-0000-4000-8000-000000000002', 'Rasen mähen und Laub entfernen',
   'Vor Ankunft der Familie Müller.', 'normal', 'pending',
   date_trunc('day', now()) + interval '2 days 9 hours', date_trunc('day', now()) + interval '2 days 12 hours', null, null),
  ('7a000000-0000-4000-8000-000000000003', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000002',
   null, 'eeeeeeee-0000-4000-8000-000000000007', 'Jährliche Heizungswartung',
   'Erdwärmepumpe: Druck, Sole, Filter prüfen.', 'high', 'pending',
   date_trunc('day', now()) + interval '8 days 8 hours', date_trunc('day', now()) + interval '8 days 11 hours', null, null),
  ('7a000000-0000-4000-8000-000000000004', 'cccccccc-0000-4000-8000-000000000002', 'dddddddd-0000-4000-8000-000000000003',
   'b0000000-0000-4000-8000-000000000006', 'eeeeeeee-0000-4000-8000-000000000001', 'Geheime Reinigung',
   'Gehört der fremden Organisation.', 'normal', 'assigned',
   date_trunc('day', now()) + interval '6 days 11 hours', null, 'ffffffff-0000-4000-8000-000000000004', null);

-- -----------------------------------------------------------------------------
-- Beispiel-Serviceauftrag: Heizungswartung an Mora Bygg (angeboten → angenommen)
-- -----------------------------------------------------------------------------
insert into public.service_orders (id, organization_id, service_task_id, property_id, service_partner_id, title, description,
                                   status, scheduled_at, estimated_cost, currency)
values ('0d000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', '7a000000-0000-4000-8000-000000000003',
        'dddddddd-0000-4000-8000-000000000002', 'ffffffff-0000-4000-8000-000000000003', 'Jährliche Heizungswartung',
        'Erdwärmepumpe: Druck, Sole, Filter prüfen. Schlüssel im Tresor.', 'offered',
        date_trunc('day', now()) + interval '8 days 8 hours', 2160.00, 'SEK');
update public.service_orders set status = 'accepted', response_note = 'Termin passt, wir kommen um 8 Uhr.'
where id = '0d000000-0000-4000-8000-000000000001';

-- Reparaturauftrag für die Dachrinne (Reparatur stammt aus der Automation)
insert into public.service_orders (id, organization_id, property_id, service_partner_id, title, description, status,
                                   scheduled_at, estimated_cost, currency)
values ('0d000000-0000-4000-8000-000000000002', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001',
        'ffffffff-0000-4000-8000-000000000001', 'Dachrinne Nordseite reinigen und abdichten',
        'Mangel aus der Hauskontrolle.', 'offered', date_trunc('day', now()) + interval '1 day 9 hours', 2500.00, 'SEK');

update public.repairs
set status = 'approved', service_order_id = '0d000000-0000-4000-8000-000000000002', estimated_cost = 2500.00
where inspection_id = '1a000000-0000-4000-8000-000000000001' and title like 'Mangel: Dach%';

-- -----------------------------------------------------------------------------
-- Dokumente, Fotos, Angebot, Rechnung
-- -----------------------------------------------------------------------------
insert into public.documents (id, organization_id, property_id, service_order_id, uploaded_by, file_name, file_type, file_size,
                              storage_bucket, storage_path, document_type, description)
values
  ('d0c00000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', null,
   'bbbbbbbb-0000-4000-8000-000000000001', 'Versicherungspolice-2026.pdf', 'application/pdf', 184320, 'husora-documents',
   'organization/cccccccc-0000-4000-8000-000000000001/property/dddddddd-0000-4000-8000-000000000001/documents/Versicherungspolice-2026.pdf',
   'insurance', 'Gebäudeversicherung'),
  ('d0c00000-0000-4000-8000-000000000002', 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000002',
   '0d000000-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000001', 'Rechnung-MB-2026-117.pdf', 'application/pdf', 96256,
   'husora-documents',
   'organization/cccccccc-0000-4000-8000-000000000001/property/dddddddd-0000-4000-8000-000000000002/documents/Rechnung-MB-2026-117.pdf',
   'invoice', 'Rechnung Heizungswartung');

insert into public.photos (organization_id, property_id, inspection_id, inspection_item_id, uploaded_by, storage_bucket, storage_path, caption, taken_at)
select 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', ii.inspection_id, ii.id,
       'bbbbbbbb-0000-4000-8000-000000000003', 'husora-property-photos',
       'organization/cccccccc-0000-4000-8000-000000000001/property/dddddddd-0000-4000-8000-000000000001/inspections/dachrinne-nord.jpg',
       'Dachrinne Nordseite', date_trunc('day', now()) - interval '13 days' + interval '14 hours 30 minutes'
from public.inspection_items ii
where ii.inspection_id = '1a000000-0000-4000-8000-000000000001' and ii.name = 'Dach und Dachrinne';

insert into public.quotes (organization_id, property_id, repair_id, service_order_id, service_partner_id, quote_number, description,
                           amount_net, tax_amount, amount_gross, currency, status, valid_until)
select 'cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', r.id, '0d000000-0000-4000-8000-000000000002',
       'ffffffff-0000-4000-8000-000000000001', 'NOR-A-2026-031', 'Rinne reinigen, Riss abdichten, Fallrohr prüfen',
       2000.00, 500.00, 2500.00, 'SEK', 'received', current_date + 30
from public.repairs r
where r.service_order_id = '0d000000-0000-4000-8000-000000000002';

insert into public.invoices (organization_id, property_id, service_order_id, service_partner_id, document_id, invoice_number,
                             amount_net, tax_amount, amount_gross, currency, invoice_date, due_date, status)
values ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000002', '0d000000-0000-4000-8000-000000000001',
        'ffffffff-0000-4000-8000-000000000003', 'd0c00000-0000-4000-8000-000000000002', 'MB-2026-117',
        1728.00, 432.00, 2160.00, 'SEK', current_date - 40, current_date - 10, 'received');

-- -----------------------------------------------------------------------------
-- Wartung
-- -----------------------------------------------------------------------------
insert into public.maintenance (organization_id, property_id, service_type_id, title, description, category, last_performed_at,
                                interval_days, assigned_partner_id, estimated_cost)
values
  ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000002', 'eeeeeeee-0000-4000-8000-000000000007',
   'Wartung Erdwärmepumpe', 'Jährliche Herstellerwartung', 'heating', now() - interval '300 days', 365,
   'ffffffff-0000-4000-8000-000000000003', 2160.00),
  ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000009',
   'Schornsteinfeger Kaminofen', 'Gesetzliche Feuerstättenschau (sotning)', 'safety', now() - interval '370 days', 365,
   'ffffffff-0000-4000-8000-000000000001', 850.00),
  ('cccccccc-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000006',
   'Brunnenwasser-Analyse', 'Wasserprobe ans Labor', 'water', now() - interval '200 days', 365, null, 900.00);

-- Fällige Wartung und überfällige Rechnungen markieren (sonst per pg_cron stündlich)
select public.run_scheduled_automations();

-- -----------------------------------------------------------------------------
-- Benachrichtigung und Nachricht
-- -----------------------------------------------------------------------------
insert into public.notifications (organization_id, user_id, type, title, message, entity_type, entity_id) values
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002', 'inspection',
   'Hauskontrolle abgeschlossen', 'Stuga Björkbacken: 1 Mangel (Dachrinne), 1 Hinweis (Rauchmelder).',
   'inspection', '1a000000-0000-4000-8000-000000000001'),
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000003', 'service_order',
   'Neuer Auftrag angeboten', 'Dachrinne Nordseite reinigen und abdichten – Stuga Björkbacken.',
   'service_order', '0d000000-0000-4000-8000-000000000002');

insert into public.messages (organization_id, sender_user_id, recipient_user_id, service_order_id, message) values
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000003',
   '0d000000-0000-4000-8000-000000000002', 'Hallo Pelle, kannst du dir die Dachrinne morgen ansehen? Fotos sind im Auftrag.'),
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000003', 'bbbbbbbb-0000-4000-8000-000000000001',
   '0d000000-0000-4000-8000-000000000002', 'Ja, ich komme gegen 9 Uhr vorbei.');
