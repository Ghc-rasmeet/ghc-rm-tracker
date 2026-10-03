-- =====================================================================
-- v6.3 — admin-managed dropdowns across modules (Vercel Updations 4)
-- =====================================================================

-- ---------------- new fields ----------------
alter table public.fee_students add column if not exists sub_course text;
alter table public.cde_clients  add column if not exists eq_rm text;
alter table public.policies     add column if not exists rm_name text;
alter table public.policy_nominees add column if not exists relation_std text;

-- ---------------- field catalogue ----------------
insert into public.module_fields (module, field_key, label, ftype, grp, sort) values
  ('supp_fee','sub_course','Sub Course','list:subcourse','Course',5),
  ('supp_cde','eq_rm','Equity RM','list:eqrm','Ownership',16)
on conflict (module, field_key) do update set label = excluded.label, ftype = excluded.ftype, grp = excluded.grp;

update public.module_fields set ftype = 'list:rm'        where module = 'supp_fee' and field_key = 'rm';
update public.module_fields set ftype = 'list:eqdealer'  where module = 'supp_cde' and field_key = 'eq_dealer_email';
update public.module_fields set ftype = 'list:rmemail'   where module = 'supp_cde' and field_key = 'rm_email';
update public.module_fields set ftype = 'list:rmname'    where module = 'supp_cde' and field_key = 'rm_name';
update public.module_fields set ftype = 'list:founderyn' where module = 'supp_cde' and field_key = 'founder_connect';
update public.module_fields set ftype = 'list:ranking'   where module = 'supp_cde' and field_key = 'founder_ranking';
update public.module_fields set ftype = 'list:iosa'      where module = 'supp_cde' and field_key = 'inside_outside';
update public.module_fields set ftype = 'list:networth'  where module = 'supp_cde' and field_key = 'net_worth_1';
update public.module_fields set ftype = 'list:dbsource'  where module = 'supp_cde' and field_key = 'db_source';

-- ---------------- list values ----------------
insert into public.lookup_values (module, list_key, value, sort) values
  -- Fee tracking · sub course (empty to start, admin adds)
  ('supp_fee','subcourse','—',0),

  -- Client Data Entry
  ('supp_cde','eqdealer','akashdeep@greenhedgecapital.com',0),
  ('supp_cde','eqdealer','piyush.arora@greenhedgecapital.com',1),
  ('supp_cde','eqdealer','nidhi@greenhedgecapital.com',2),

  ('supp_cde','rmemail','rasmeet.sethi@greenhedgecapital.com',0),
  ('supp_cde','rmemail','akshdeep.kaur@greenhedgecapital.com',1),
  ('supp_cde','rmemail','rahul.kapoor@greenhedgecapital.com',2),
  ('supp_cde','rmemail','abhishek.sharma@greenhedgecapital.com',3),
  ('supp_cde','rmemail','sannat@greenhedgecapital.com',4),
  ('supp_cde','rmemail','madhubani@greenhedgecapital.com',5),
  ('supp_cde','rmemail','jasmeet@greenhedgecapital.com',6),

  ('supp_cde','rmname','Akshdeep Kaur',0), ('supp_cde','rmname','Rasmeet Branch',1),
  ('supp_cde','rmname','Rahul Kapoor',2), ('supp_cde','rmname','Abhishek Sharma',3),
  ('supp_cde','rmname','Jasmeet Singh',4), ('supp_cde','rmname','Madhubani Singh',5),
  ('supp_cde','rmname','Sannat Mehra',6), ('supp_cde','rmname','Branch Core',7),

  ('supp_cde','eqrm','Akshdeep Kaur',0), ('supp_cde','eqrm','Rasmeet Branch',1),
  ('supp_cde','eqrm','Rahul Kapoor',2), ('supp_cde','eqrm','Abhishek Sharma',3),
  ('supp_cde','eqrm','Jasmeet Singh',4), ('supp_cde','eqrm','Madhubani Singh',5),
  ('supp_cde','eqrm','Sannat Mehra',6),

  ('supp_cde','founderyn','Yes',0), ('supp_cde','founderyn','No',1),

  ('supp_cde','ranking','0',0), ('supp_cde','ranking','1',1), ('supp_cde','ranking','2',2),
  ('supp_cde','ranking','3',3), ('supp_cde','ranking','4',4), ('supp_cde','ranking','5',5),

  ('supp_cde','iosa','IS',0), ('supp_cde','iosa','OS',1), ('supp_cde','iosa','IOS',2),

  ('supp_cde','networth','RNI',0), ('supp_cde','networth','MNI',1),
  ('supp_cde','networth','HNI',2), ('supp_cde','networth','UHNI',3),

  ('supp_cde','dbsource','Internal Branch',0),
  ('supp_cde','dbsource','Founder Branch Introductory',1),
  ('supp_cde','dbsource','Founder Branch Deep',2),
  ('supp_cde','dbsource','Branding Branch',3),
  ('supp_cde','dbsource','Self Sourced',4),
  ('supp_cde','dbsource','Self Sourced Founder Tier 1',5),

  -- Insurance
  ('insurance','plan','Young Star Plan',0),
  ('insurance','plan','Star Cancer Care Platinum Insurance Policy',1),
  ('insurance','plan','National Senior Citizen Mediclaim Policy',2),
  ('insurance','plan','Bajaj Insurance',3),
  ('insurance','plan','National Insurance',4),
  ('insurance','plan','Term Insurance',5),
  ('insurance','plan','Tata',6),
  ('insurance','plan','ICICI Prudential',7),

  ('insurance','nomrel','Father',0), ('insurance','nomrel','Mother',1),
  ('insurance','nomrel','Spouse',2), ('insurance','nomrel','Child',3), ('insurance','nomrel','Other',4),

  ('insurance','rm','Akshdeep Kaur',0), ('insurance','rm','Rasmeet Branch',1),
  ('insurance','rm','Rahul Kapoor',2), ('insurance','rm','Abhishek Sharma',3),
  ('insurance','rm','Jasmeet Singh',4), ('insurance','rm','Madhubani Singh',5),
  ('insurance','rm','Sannat Mehra',6), ('insurance','rm','Branch Core',7)
on conflict (module, list_key, value) do nothing;

-- Fee tracking RM list already seeded in v6.1; make sure the names match the sheet
insert into public.lookup_values (module, list_key, value, sort) values
  ('supp_fee','rm','Akshdeep Kaur',0), ('supp_fee','rm','Rasmeet Branch',1),
  ('supp_fee','rm','Rahul Kapoor',2), ('supp_fee','rm','Abhishek Sharma',3),
  ('supp_fee','rm','Jasmeet Singh',4), ('supp_fee','rm','Madhubani Singh',5),
  ('supp_fee','rm','Sannat Mehra',6), ('supp_fee','rm','Branch Core',7)
on conflict (module, list_key, value) do nothing;

-- carry existing values into the lists so nothing already typed disappears
insert into public.lookup_values (module, list_key, value, sort)
  select 'supp_cde','rmname', rm_name, 90 from (select distinct rm_name from public.cde_clients where coalesce(rm_name,'') <> '') d
on conflict (module, list_key, value) do nothing;
insert into public.lookup_values (module, list_key, value, sort)
  select 'supp_cde','rmemail', rm_email, 90 from (select distinct rm_email from public.cde_clients where coalesce(rm_email,'') <> '') d
on conflict (module, list_key, value) do nothing;
insert into public.lookup_values (module, list_key, value, sort)
  select 'insurance','plan', plan_name, 90 from (select distinct plan_name from public.policies where coalesce(plan_name,'') <> '') d
on conflict (module, list_key, value) do nothing;

-- ---------------- rebuild the two reading views ----------------
drop view if exists public.fee_view;
create view public.fee_view with (security_invoker = on) as
  select id,
    case when public.fperm('supp_fee','student_id') = 'hidden' then null else student_id end as student_id,
    case when public.fperm('supp_fee','course_id') = 'hidden' then null else course_id end as course_id,
    case when public.fperm('supp_fee','student_name') = 'hidden' then null else student_name end as student_name,
    case when public.fperm('supp_fee','phone_no') = 'hidden' then null else phone_no end as phone_no,
    case when public.fperm('supp_fee','main_course') = 'hidden' then null else main_course end as main_course,
    case when public.fperm('supp_fee','sub_course') = 'hidden' then null else sub_course end as sub_course,
    case when public.fperm('supp_fee','source') = 'hidden' then null else source end as source,
    case when public.fperm('supp_fee','source_reference') = 'hidden' then null else source_reference end as source_reference,
    case when public.fperm('supp_fee','mode_of_connect') = 'hidden' then null else mode_of_connect end as mode_of_connect,
    case when public.fperm('supp_fee','reg_quarter') = 'hidden' then null else reg_quarter end as reg_quarter,
    case when public.fperm('supp_fee','actual_fees') = 'hidden' then null else actual_fees end as actual_fees,
    case when public.fperm('supp_fee','final_fees') = 'hidden' then null else final_fees end as final_fees,
    case when public.fperm('supp_fee','collection_date_1') = 'hidden' then null else collection_date_1 end as collection_date_1,
    case when public.fperm('supp_fee','received_1') = 'hidden' then null else received_1 end as received_1,
    case when public.fperm('supp_fee','status_1') = 'hidden' then null else status_1 end as status_1,
    case when public.fperm('supp_fee','collection_date_2') = 'hidden' then null else collection_date_2 end as collection_date_2,
    case when public.fperm('supp_fee','received_2') = 'hidden' then null else received_2 end as received_2,
    case when public.fperm('supp_fee','status_2') = 'hidden' then null else status_2 end as status_2,
    case when public.fperm('supp_fee','collection_date_3') = 'hidden' then null else collection_date_3 end as collection_date_3,
    case when public.fperm('supp_fee','received_3') = 'hidden' then null else received_3 end as received_3,
    case when public.fperm('supp_fee','status_3') = 'hidden' then null else status_3 end as status_3,
    case when public.fperm('supp_fee','relationship_discount') = 'hidden' then null else relationship_discount end as relationship_discount,
    case when public.fperm('supp_fee','discount_reason') = 'hidden' then null else discount_reason end as discount_reason,
    case when public.fperm('supp_fee','rm') = 'hidden' then null else rm end as rm,
    case when public.fperm('supp_fee','bs_intro') = 'hidden' then null else bs_intro end as bs_intro,
    case when public.fperm('supp_fee','bs_deep') = 'hidden' then null else bs_deep end as bs_deep,
    case when public.fperm('supp_fee','support') = 'hidden' then null else support end as support,
    case when public.fperm('supp_fee','internal_support') = 'hidden' then null else internal_support end as internal_support,
    total_received, balance_due, clearance_date, clearance_quarter, clearance_status,
    created_by, created_at, updated_at
  from public.fee_students;

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
    case when public.fperm('supp_cde','eq_rm') = 'hidden' then null else eq_rm end as eq_rm,
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

-- insurance uses lookup lists too, so its admins can manage them
insert into public.module_features (module, feature_key, label, kind) values
  ('insurance','manage_lists','Manage dropdown lists','action')
on conflict (module, feature_key) do nothing;
