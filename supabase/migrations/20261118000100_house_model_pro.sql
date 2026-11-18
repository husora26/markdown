-- 3D-Hausmodell erst ab PRO (Vorgabe Tarifgestaltung, 2026-11-18)
update public.plans
   set features = features - 'house_model',
       highlights = (select coalesce(jsonb_agg(case when h = 'Automatische Aufgaben (Basis) und Hausmodell' then 'Automatische Aufgaben (Basis)' else h end), '[]'::jsonb)
                       from jsonb_array_elements_text(highlights) as h)
 where id = 'plus';

update public.plans
   set features = case when features ? 'house_model' then features else features || '["house_model"]'::jsonb end
 where id in ('pro', 'ultimate');

update public.plans
   set highlights = highlights || '["3D-Hausmodell des Ferienhauses"]'::jsonb
 where id = 'pro' and not highlights ? '3D-Hausmodell des Ferienhauses';
