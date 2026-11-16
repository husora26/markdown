-- =============================================================================
-- HUSORA · Mängel melden und Reparaturen im Tarif FREE
-- =============================================================================
-- Freie Funktionen (Auffälligkeit in Aufgaben, Saison-Checklisten, Hauskontrolle) erzeugen Mängel.
-- Ihr Ziel „Reparatur & Instandhaltung“ war erst ab PLUS offen – eine Sackgasse. Die Funktion
-- 'repairs' gehört deshalb in FREE. Automatische Reparaturaufträge (repair_orders_auto) bleiben PRO.

update public.plans
   set features = features || '["repairs"]'::jsonb
 where id = 'free' and not features ? 'repairs';

update public.plans
   set highlights = highlights || '["Mängel melden und Reparaturen planen"]'::jsonb
 where id = 'free' and not highlights ? 'Mängel melden und Reparaturen planen';
