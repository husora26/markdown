-- =============================================================================
-- HUSORA · Migration 1400 · Indizes auf den übrigen Fremdschlüsseln
-- =============================================================================
-- Fremdschlüssel ohne Index machen das Löschen/Ändern des referenzierten Datensatzes
-- (z. B. eines Benutzers) bei großen Tabellen langsam. Teilindizes halten sie klein.

create index automation_rules_created_by_fk_idx on public.automation_rules (created_by) where created_by is not null;
create index automation_rules_updated_by_fk_idx on public.automation_rules (updated_by) where updated_by is not null;
create index booking_sources_created_by_fk_idx on public.booking_sources (created_by) where created_by is not null;
create index booking_sources_updated_by_fk_idx on public.booking_sources (updated_by) where updated_by is not null;
create index bookings_created_by_fk_idx on public.bookings (created_by) where created_by is not null;
create index bookings_updated_by_fk_idx on public.bookings (updated_by) where updated_by is not null;
create index inspection_items_checked_by_fk_idx on public.inspection_items (checked_by) where checked_by is not null;
create index inspection_templates_created_by_fk_idx on public.inspection_templates (created_by) where created_by is not null;
create index inspection_templates_updated_by_fk_idx on public.inspection_templates (updated_by) where updated_by is not null;
create index inspections_created_by_fk_idx on public.inspections (created_by) where created_by is not null;
create index inspections_updated_by_fk_idx on public.inspections (updated_by) where updated_by is not null;
create index invoices_approved_by_fk_idx on public.invoices (approved_by) where approved_by is not null;
create index invoices_created_by_fk_idx on public.invoices (created_by) where created_by is not null;
create index invoices_document_id_fk_idx on public.invoices (document_id) where document_id is not null;
create index invoices_updated_by_fk_idx on public.invoices (updated_by) where updated_by is not null;
create index maintenance_created_by_fk_idx on public.maintenance (created_by) where created_by is not null;
create index maintenance_service_type_id_fk_idx on public.maintenance (service_type_id) where service_type_id is not null;
create index maintenance_updated_by_fk_idx on public.maintenance (updated_by) where updated_by is not null;
create index organization_members_invited_by_fk_idx on public.organization_members (invited_by) where invited_by is not null;
create index organizations_created_by_fk_idx on public.organizations (created_by) where created_by is not null;
create index organizations_updated_by_fk_idx on public.organizations (updated_by) where updated_by is not null;
create index properties_created_by_fk_idx on public.properties (created_by) where created_by is not null;
create index properties_updated_by_fk_idx on public.properties (updated_by) where updated_by is not null;
create index quotes_created_by_fk_idx on public.quotes (created_by) where created_by is not null;
create index quotes_decided_by_fk_idx on public.quotes (decided_by) where decided_by is not null;
create index quotes_document_id_fk_idx on public.quotes (document_id) where document_id is not null;
create index quotes_updated_by_fk_idx on public.quotes (updated_by) where updated_by is not null;
create index repairs_approved_by_fk_idx on public.repairs (approved_by) where approved_by is not null;
create index repairs_created_by_fk_idx on public.repairs (created_by) where created_by is not null;
create index repairs_updated_by_fk_idx on public.repairs (updated_by) where updated_by is not null;
create index service_orders_created_by_fk_idx on public.service_orders (created_by) where created_by is not null;
create index service_orders_updated_by_fk_idx on public.service_orders (updated_by) where updated_by is not null;
create index service_partners_created_by_fk_idx on public.service_partners (created_by) where created_by is not null;
create index service_partners_updated_by_fk_idx on public.service_partners (updated_by) where updated_by is not null;
create index service_tasks_created_by_fk_idx on public.service_tasks (created_by) where created_by is not null;
create index service_tasks_updated_by_fk_idx on public.service_tasks (updated_by) where updated_by is not null;
create index webhook_endpoints_created_by_fk_idx on public.webhook_endpoints (created_by) where created_by is not null;
create index webhook_endpoints_updated_by_fk_idx on public.webhook_endpoints (updated_by) where updated_by is not null;
create index webhook_events_webhook_endpoint_id_fk_idx on public.webhook_events (webhook_endpoint_id) where webhook_endpoint_id is not null;
