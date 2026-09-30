-- =====================================================================
-- GHC Hub v6.1 — Supplementary > GHC Student Fee Tracking
-- =====================================================================

-- ---------- admin-managed dropdown lists (reusable by any module) ----------
create table if not exists public.lookup_values (
  id bigserial primary key,
  module text not null, list_key text not null,
  value text not null, sort int default 0, active boolean default true,
  unique (module, list_key, value)
);
alter table public.lookup_values enable row level security;
drop policy if exists "lookups: read" on public.lookup_values;
create policy "lookups: read" on public.lookup_values for select using (auth.uid() is not null);
drop policy if exists "lookups: admin" on public.lookup_values;
create policy "lookups: admin" on public.lookup_values for all
  using (public.is_super() or public.has_module(module,'admin'))
  with check (public.is_super() or public.has_module(module,'admin'));

insert into public.modules (key, name, sort) values ('supp_fee','GHC Student Fee Tracking',42) on conflict (key) do nothing;

create table if not exists public.fee_students (
  id uuid primary key default gen_random_uuid(),
  student_id text,
  course_id text,
  student_name text,
  phone_no text,
  main_course text,
  source text,
  source_reference text,
  mode_of_connect text,
  reg_quarter text,
  actual_fees numeric,
  final_fees numeric,
  collection_date_1 date,
  received_1 numeric,
  status_1 text,
  collection_date_2 date,
  received_2 numeric,
  status_2 text,
  collection_date_3 date,
  received_3 numeric,
  status_3 text,
  relationship_discount numeric,
  discount_reason text,
  rm text,
  bs_intro text,
  bs_deep text,
  support text,
  internal_support text,
  total_received numeric generated always as (
    coalesce(received_1,0) + coalesce(received_2,0) + coalesce(received_3,0) + coalesce(relationship_discount,0)) stored,
  balance_due numeric generated always as (
    coalesce(final_fees,0) - (coalesce(received_1,0) + coalesce(received_2,0) + coalesce(received_3,0) + coalesce(relationship_discount,0))) stored,
  clearance_date date,
  clearance_quarter text,
  clearance_status text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists fee_student_idx on public.fee_students (student_name);
create index if not exists fee_course_idx on public.fee_students (main_course);
create index if not exists fee_clear_idx on public.fee_students (clearance_quarter);

-- Indian financial-year quarter from a date
create or replace function public.fy_quarter(d date) returns text language sql immutable as $$
  select case when d is null then null else
    'Q' || (case when extract(month from d) between 4 and 6 then 1
                 when extract(month from d) between 7 and 9 then 2
                 when extract(month from d) between 10 and 12 then 3 else 4 end)::text
    || ' ' || (case when extract(month from d) >= 4 then extract(year from d) else extract(year from d) - 1 end)::int::text
    || '-' || right(((case when extract(month from d) >= 4 then extract(year from d) else extract(year from d) - 1 end) + 1)::int::text, 2)
  end;
$$;

-- fee log
create table if not exists public.fee_log (
  id bigserial primary key,
  record_id uuid, student_name text, action text not null,
  field_key text, old_value text, new_value text,
  by_user uuid references public.profiles(id) on delete set null,
  at timestamptz default now()
);
create index if not exists fee_log_at_idx on public.fee_log (at desc);

create or replace function public.fee_guard()
returns trigger language plpgsql security definer as $$
declare o jsonb; n jsonb; k text;
  skip text[] := array['id','created_by','created_at','updated_at','total_received','balance_due','clearance_date','clearance_quarter','clearance_status'];
begin
  -- work out when the balance was cleared
  new.clearance_date := case when coalesce(new.final_fees,0) > 0
        and (coalesce(new.received_1,0) + coalesce(new.received_2,0) + coalesce(new.received_3,0) + coalesce(new.relationship_discount,0)) >= new.final_fees
      then greatest(coalesce(new.collection_date_1,'1900-01-01'), coalesce(new.collection_date_2,'1900-01-01'), coalesce(new.collection_date_3,'1900-01-01'))
      else null end;
  if new.clearance_date = '1900-01-01' then new.clearance_date := null; end if;
  new.clearance_quarter := public.fy_quarter(new.clearance_date);
  new.clearance_status := case when new.clearance_date is not null then 'Complete' else 'Pending' end;

  if TG_OP = 'INSERT' then
    insert into public.fee_log (record_id, student_name, action, by_user) values (new.id, new.student_name, 'created', auth.uid());
    return new;
  end if;
  o := to_jsonb(old); n := to_jsonb(new);
  for k in select jsonb_object_keys(n) loop
    if k = any(skip) then continue; end if;
    if o->>k is distinct from n->>k then
      if public.fperm('supp_fee', k) <> 'edit' then raise exception 'You are not allowed to change %', k; end if;
      insert into public.fee_log (record_id, student_name, action, field_key, old_value, new_value, by_user)
      values (new.id, new.student_name, 'edited', k, o->>k, n->>k, auth.uid());
    end if;
  end loop;
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists fee_guard_trg on public.fee_students;
create trigger fee_guard_trg before insert or update on public.fee_students
  for each row execute function public.fee_guard();

create or replace view public.fee_view with (security_invoker = on) as
  select id,
    case when public.fperm('supp_fee','student_id') = 'hidden' then null else student_id end as student_id,
    case when public.fperm('supp_fee','course_id') = 'hidden' then null else course_id end as course_id,
    case when public.fperm('supp_fee','student_name') = 'hidden' then null else student_name end as student_name,
    case when public.fperm('supp_fee','phone_no') = 'hidden' then null else phone_no end as phone_no,
    case when public.fperm('supp_fee','main_course') = 'hidden' then null else main_course end as main_course,
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

alter table public.fee_students enable row level security;
alter table public.fee_log enable row level security;
drop policy if exists "fee: read" on public.fee_students;
create policy "fee: read" on public.fee_students for select using (public.has_module('supp_fee','view'));
drop policy if exists "fee: write" on public.fee_students;
create policy "fee: write" on public.fee_students for all using (public.has_module('supp_fee','edit')) with check (public.has_module('supp_fee','edit'));
drop policy if exists "fee_log: read" on public.fee_log;
create policy "fee_log: read" on public.fee_log for select using (public.has_module('supp_fee','view'));
drop policy if exists "fee_log: insert" on public.fee_log;
create policy "fee_log: insert" on public.fee_log for insert with check (public.has_module('supp_fee','view'));

insert into public.module_fields (module, field_key, label, ftype, grp, sort) values
  ('supp_fee','student_id','Student ID','text','Student',0),
  ('supp_fee','course_id','Course ID','text','Student',1),
  ('supp_fee','student_name','Student Name','text','Student',2),
  ('supp_fee','phone_no','Phone No','phone','Student',3),
  ('supp_fee','main_course','Main Course','list:course','Course',4),
  ('supp_fee','source','Source','list:source','Course',5),
  ('supp_fee','source_reference','Source Reference','text','Course',6),
  ('supp_fee','mode_of_connect','Mode of connect','text','Course',7),
  ('supp_fee','reg_quarter','Registration Quarter','list:quarter','Course',8),
  ('supp_fee','actual_fees','Actual Fees','number','Fees',9),
  ('supp_fee','final_fees','Final Fees','number','Fees',10),
  ('supp_fee','collection_date_1','Collection Date 1','date','Instalment 1',11),
  ('supp_fee','received_1','Received 1','number','Instalment 1',12),
  ('supp_fee','status_1','Mode & Confirmation (1)','list:paystatus','Instalment 1',13),
  ('supp_fee','collection_date_2','Collection Date 2','date','Instalment 2',14),
  ('supp_fee','received_2','Received 2','number','Instalment 2',15),
  ('supp_fee','status_2','Mode & Confirmation (2)','list:paystatus','Instalment 2',16),
  ('supp_fee','collection_date_3','Collection Date 3','date','Instalment 3',17),
  ('supp_fee','received_3','Received 3','number','Instalment 3',18),
  ('supp_fee','status_3','Mode & Confirmation (3)','list:paystatus','Instalment 3',19),
  ('supp_fee','relationship_discount','Relationship Discount','number','Adjustment',20),
  ('supp_fee','discount_reason','Discount Reason','list:discount','Adjustment',21),
  ('supp_fee','rm','RM','list:rm','Ownership',22),
  ('supp_fee','bs_intro','Build Specialist – Intro','list:bsintro','Ownership',23),
  ('supp_fee','bs_deep','Build Specialist – Deep','list:bsdeep','Ownership',24),
  ('supp_fee','support','Support','list:yesno','Ownership',25),
  ('supp_fee','internal_support','Internal Support','list:yesno','Ownership',26)
on conflict (module, field_key) do update set label = excluded.label, ftype = excluded.ftype, grp = excluded.grp, sort = excluded.sort;

insert into public.module_features (module, feature_key, label, kind) values
  ('supp_fee','report_quarter','Clearance quarter report','report'),
  ('supp_fee','report_course','Course and batch report','report'),
  ('supp_fee','report_rm','RM and source report','report'),
  ('supp_fee','export','Export to Excel','action'),
  ('supp_fee','view_log','See the change log','action'),
  ('supp_fee','manage_lists','Manage dropdown lists','action')
on conflict (module, feature_key) do nothing;

insert into public.lookup_values (module, list_key, value, sort) values
  ('supp_fee','course','Green',0),
  ('supp_fee','course','Blue',1),
  ('supp_fee','course','F&O',2),
  ('supp_fee','source','Self Source',0),
  ('supp_fee','source','Founder Branch deep',1),
  ('supp_fee','source','GHC Internal',2),
  ('supp_fee','source','GHC Branding',3),
  ('supp_fee','source','Founder Branch',4),
  ('supp_fee','source','Founder Branch Intro',5),
  ('supp_fee','quarter','Q1 2026-27',0),
  ('supp_fee','quarter','Q2 2026-27',1),
  ('supp_fee','quarter','Q3 2026-27',2),
  ('supp_fee','quarter','Q4 2026-27',3),
  ('supp_fee','paystatus','Received online',0),
  ('supp_fee','paystatus','Received online & Confirmed',1),
  ('supp_fee','paystatus','Received Cash',2),
  ('supp_fee','paystatus','Received Cash & Confirmed',3),
  ('supp_fee','paystatus','Received via UPI & Cash both',4),
  ('supp_fee','paystatus','Received via UPI & Cash both Confirmed',5),
  ('supp_fee','discount','Founder Extra',0),
  ('supp_fee','discount','RM Relationship Extra',1),
  ('supp_fee','discount','NPA',2),
  ('supp_fee','rm','Rahul Kapoor',0),
  ('supp_fee','rm','Abhishek Sharma',1),
  ('supp_fee','rm','Jasmeet Singh',2),
  ('supp_fee','rm','Sehajpreet Singh',3),
  ('supp_fee','rm','Madhubani Singh',4),
  ('supp_fee','rm','Sannat Mehra',5),
  ('supp_fee','rm','Branch Core',6),
  ('supp_fee','rm','N/A',7),
  ('supp_fee','bsintro','NA',0),
  ('supp_fee','bsintro','Sehaj',1),
  ('supp_fee','bsdeep','NA',0),
  ('supp_fee','bsdeep','Sehaj',1),
  ('supp_fee','yesno','Yes',0),
  ('supp_fee','yesno','No',1)
on conflict (module, list_key, value) do nothing;
