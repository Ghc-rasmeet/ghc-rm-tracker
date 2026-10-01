-- =====================================================================
-- v6.2: Entered in Register block, Equity dealer as an admin-managed list,
--       export limited to admins
-- =====================================================================

-- register flags, mirroring the Zoho ones
alter table public.cde_clients add column if not exists reg_mf_setup boolean default false;
alter table public.cde_clients add column if not exists reg_mf_active boolean default false;
alter table public.cde_clients add column if not exists reg_eq_setup boolean default false;
alter table public.cde_clients add column if not exists reg_eq_active boolean default false;

-- the guard trigger must not block these either
create or replace function public.cde_guard()
returns trigger language plpgsql security definer as $$
declare
  o jsonb; n jsonb; k text; nm text;
  skip text[] := array['id','created_by','created_at','updated_at'];
begin
  nm := coalesce(new.first_name,'') || ' ' || coalesce(new.last_name,'');
  if TG_OP = 'INSERT' then
    insert into public.cde_log (record_id, client_name, action, by_user) values (new.id, nm, 'created', auth.uid());
    return new;
  end if;
  o := to_jsonb(old); n := to_jsonb(new);
  for k in select jsonb_object_keys(n) loop
    if k = any(skip) then continue; end if;
    if o->>k is distinct from n->>k then
      if left(k,5) <> 'zoho_' and left(k,4) <> 'reg_' and public.fperm('supp_cde', k) <> 'edit' then
        raise exception 'You are not allowed to change %', k;
      end if;
      insert into public.cde_log (record_id, client_name, action, field_key, old_value, new_value, by_user)
      values (new.id, nm, 'edited', k, o->>k, n->>k, auth.uid());
    end if;
  end loop;
  new.updated_at := now();
  return new;
end;
$$;

-- rebuild the reading view with the new columns
drop view if exists public.cde_view;
create view public.cde_view with (security_invoker = on) as
  select id,
    case when public.fperm('supp_cde','log_date') = 'hidden' then null else log_date end as log_date,
    case when public.fperm('supp_cde','first_name') = 'hidden' then null else first_name end as first_name,
    case when public.fperm('supp_cde','last_name') = 'hidden' then null else last_name end as last_name,
    case when public.fperm('supp_cde','pan_no') = 'hidden' then null else pan_no end as pan_no,
    case when public.fperm('supp_cde','trading_code') = 'hidden' then null else trading_code end as trading_code,
    case when public.fperm('supp_cde','gender') = 'hidden' then null else gender end as gender,
    case when public.fperm('supp_cde','dob') = 'hidden' then null else dob end as dob,
    case when public.fperm('supp_cde','mobile') = 'hidden' then null else mobile end as mobile,
    case when public.fperm('supp_cde','email') = 'hidden' then null else email end as email,
    case when public.fperm('supp_cde','mailing_street') = 'hidden' then null else mailing_street end as mailing_street,
    case when public.fperm('supp_cde','mailing_city') = 'hidden' then null else mailing_city end as mailing_city,
    case when public.fperm('supp_cde','mailing_state') = 'hidden' then null else mailing_state end as mailing_state,
    case when public.fperm('supp_cde','mailing_zip') = 'hidden' then null else mailing_zip end as mailing_zip,
    case when public.fperm('supp_cde','eq_dealer_email') = 'hidden' then null else eq_dealer_email end as eq_dealer_email,
    case when public.fperm('supp_cde','rm_email') = 'hidden' then null else rm_email end as rm_email,
    case when public.fperm('supp_cde','rm_name') = 'hidden' then null else rm_name end as rm_name,
    case when public.fperm('supp_cde','founder_connect') = 'hidden' then null else founder_connect end as founder_connect,
    case when public.fperm('supp_cde','founder_ranking') = 'hidden' then null else founder_ranking end as founder_ranking,
    case when public.fperm('supp_cde','founder_reference') = 'hidden' then null else founder_reference end as founder_reference,
    case when public.fperm('supp_cde','inside_outside') = 'hidden' then null else inside_outside end as inside_outside,
    case when public.fperm('supp_cde','net_worth_1') = 'hidden' then null else net_worth_1 end as net_worth_1,
    case when public.fperm('supp_cde','db_source') = 'hidden' then null else db_source end as db_source,
    case when public.fperm('supp_cde','eq_setup_date') = 'hidden' then null else eq_setup_date end as eq_setup_date,
    case when public.fperm('supp_cde','eq_active_date') = 'hidden' then null else eq_active_date end as eq_active_date,
    case when public.fperm('supp_cde','uploaded_in_connect') = 'hidden' then null else uploaded_in_connect end as uploaded_in_connect,
    case when public.fperm('supp_cde','traded') = 'hidden' then null else traded end as traded,
    case when public.fperm('supp_cde','traded_date') = 'hidden' then null else traded_date end as traded_date,
    case when public.fperm('supp_cde','bse_client_code') = 'hidden' then null else bse_client_code end as bse_client_code,
    case when public.fperm('supp_cde','wealthelite_id') = 'hidden' then null else wealthelite_id end as wealthelite_id,
    case when public.fperm('supp_cde','mf_setup_date') = 'hidden' then null else mf_setup_date end as mf_setup_date,
    case when public.fperm('supp_cde','mf_active_date') = 'hidden' then null else mf_active_date end as mf_active_date,
    case when public.fperm('supp_cde','folio_check_date') = 'hidden' then null else folio_check_date end as folio_check_date,
    case when public.fperm('supp_cde','change_of_broker') = 'hidden' then null else change_of_broker end as change_of_broker,
    zoho_mf_setup, zoho_mf_active, zoho_eq_setup, zoho_eq_active,
    reg_mf_setup, reg_mf_active, reg_eq_setup, reg_eq_active,
    created_by, created_at, updated_at
  from public.cde_clients;

-- Equity dealer email becomes a dropdown the admin can add to
update public.module_fields set ftype = 'list:eqdealer' where module = 'supp_cde' and field_key = 'eq_dealer_email';
insert into public.lookup_values (module, list_key, value, sort)
  select 'supp_cde', 'eqdealer', eq_dealer_email, 0
  from (select distinct eq_dealer_email from public.cde_clients where coalesce(eq_dealer_email,'') <> '') d
on conflict (module, list_key, value) do nothing;

insert into public.module_features (module, feature_key, label, kind) values
  ('supp_cde','manage_lists','Manage dropdown lists','action')
on conflict (module, feature_key) do nothing;
