-- =====================================================================
-- GHC Hub v6.0 — Supplementary module + field-level permissions
-- Pattern to be reused by every module from here on.
-- =====================================================================

-- ---------- generic field & feature permission framework ----------
create table if not exists public.module_fields (
  module text not null,
  field_key text not null,
  label text not null,
  ftype text not null default 'text',
  grp text default 'General',
  sort int default 0,
  primary key (module, field_key)
);

create table if not exists public.field_perms (
  module text not null, field_key text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  level text not null check (level in ('hidden','view','edit')),
  primary key (module, field_key, user_id)
);

create table if not exists public.module_features (
  module text not null, feature_key text not null, label text not null, kind text default 'report',
  primary key (module, feature_key)
);
create table if not exists public.feature_perms (
  module text not null, feature_key text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  allowed boolean not null default true,
  primary key (module, feature_key, user_id)
);

-- effective right on one field: super admin edits everything;
-- an explicit field row wins; otherwise the module level applies.
create or replace function public.fperm(m text, f text)
returns text language sql stable security definer as $$
  select case
    when public.is_super() then 'edit'
    when not public.has_module(m,'view') then 'hidden'
    else coalesce(
      (select level from public.field_perms fp where fp.module = m and fp.field_key = f and fp.user_id = auth.uid()),
      case when public.has_module(m,'edit') then 'edit' else 'view' end)
  end;
$$;

create or replace function public.fallowed(m text, f text)
returns boolean language sql stable security definer as $$
  select public.is_super() or coalesce(
    (select allowed from public.feature_perms x where x.module = m and x.feature_key = f and x.user_id = auth.uid()),
    public.has_module(m,'view'));
$$;

alter table public.module_fields enable row level security;
alter table public.field_perms enable row level security;
alter table public.module_features enable row level security;
alter table public.feature_perms enable row level security;
drop policy if exists "module_fields: read" on public.module_fields;
create policy "module_fields: read" on public.module_fields for select using (auth.uid() is not null);
drop policy if exists "module_fields: admin" on public.module_fields;
create policy "module_fields: admin" on public.module_fields for all using (public.is_super()) with check (public.is_super());
drop policy if exists "field_perms: read" on public.field_perms;
create policy "field_perms: read" on public.field_perms for select using (user_id = auth.uid() or public.is_super() or public.has_module(module,'admin'));
drop policy if exists "field_perms: admin" on public.field_perms;
create policy "field_perms: admin" on public.field_perms for all using (public.is_super() or public.has_module(module,'admin')) with check (public.is_super() or public.has_module(module,'admin'));
drop policy if exists "module_features: read" on public.module_features;
create policy "module_features: read" on public.module_features for select using (auth.uid() is not null);
drop policy if exists "module_features: admin" on public.module_features;
create policy "module_features: admin" on public.module_features for all using (public.is_super()) with check (public.is_super());
drop policy if exists "feature_perms: read" on public.feature_perms;
create policy "feature_perms: read" on public.feature_perms for select using (user_id = auth.uid() or public.is_super() or public.has_module(module,'admin'));
drop policy if exists "feature_perms: admin" on public.feature_perms;
create policy "feature_perms: admin" on public.feature_perms for all using (public.is_super() or public.has_module(module,'admin')) with check (public.is_super() or public.has_module(module,'admin'));

-- ---------- Supplementary module ----------
insert into public.modules (key, name, sort) values ('supp','Supplementary',4) on conflict (key) do nothing;
insert into public.modules (key, name, sort) values ('supp_cde','Client Data Entry',41) on conflict (key) do nothing;

create table if not exists public.cde_clients (
  id uuid primary key default gen_random_uuid(),
  log_date date,
  first_name text,
  last_name text,
  pan_no text,
  trading_code text,
  gender text,
  dob date,
  mobile text,
  email text,
  mailing_street text,
  mailing_city text,
  mailing_state text,
  mailing_zip text,
  eq_dealer_email text,
  rm_email text,
  rm_name text,
  founder_connect text,
  founder_ranking text,
  founder_reference text,
  inside_outside text,
  net_worth_1 text,
  db_source text,
  eq_setup_date date,
  eq_active_date date,
  uploaded_in_connect text,
  traded text,
  traded_date date,
  bse_client_code text,
  wealthelite_id text,
  mf_setup_date date,
  mf_active_date date,
  folio_check_date date,
  change_of_broker text,
  zoho_mf_setup boolean default false,
  zoho_mf_active boolean default false,
  zoho_eq_setup boolean default false,
  zoho_eq_active boolean default false,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists cde_pan_idx on public.cde_clients (pan_no);
create index if not exists cde_log_idx on public.cde_clients (log_date desc);

-- change log: one row per changed field, kept for a year
create table if not exists public.cde_log (
  id bigserial primary key,
  record_id uuid,
  client_name text,
  action text not null,
  field_key text,
  old_value text,
  new_value text,
  by_user uuid references public.profiles(id) on delete set null,
  at timestamptz default now()
);
create index if not exists cde_log_at_idx on public.cde_log (at desc);
create index if not exists cde_log_rec_idx on public.cde_log (record_id, at desc);

-- write guard + logging in one trigger
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
      if left(k,5) <> 'zoho_' and public.fperm('supp_cde', k) <> 'edit' then
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
drop trigger if exists cde_guard_trg on public.cde_clients;
create trigger cde_guard_trg before insert or update on public.cde_clients
  for each row execute function public.cde_guard();

-- keep the log to one year
create or replace function public.cde_log_prune() returns void language sql security definer as $$
  delete from public.cde_log where at < now() - interval '1 year';
$$;

-- reading view: hidden fields come back empty
create or replace view public.cde_view with (security_invoker = on) as
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
    created_by, created_at, updated_at
  from public.cde_clients;

alter table public.cde_clients enable row level security;
alter table public.cde_log enable row level security;
drop policy if exists "cde: read" on public.cde_clients;
create policy "cde: read" on public.cde_clients for select using (public.has_module('supp_cde','view'));
drop policy if exists "cde: write" on public.cde_clients;
create policy "cde: write" on public.cde_clients for all using (public.has_module('supp_cde','edit')) with check (public.has_module('supp_cde','edit'));
drop policy if exists "cde_log: read" on public.cde_log;
create policy "cde_log: read" on public.cde_log for select using (public.has_module('supp_cde','view'));
drop policy if exists "cde_log: insert" on public.cde_log;
create policy "cde_log: insert" on public.cde_log for insert with check (public.has_module('supp_cde','view'));

-- field catalogue
insert into public.module_fields (module, field_key, label, ftype, grp, sort) values
  ('supp_cde','log_date','Log Date','date','Entry',0),
  ('supp_cde','first_name','First Name','text','Identity',1),
  ('supp_cde','last_name','Last Name','text','Identity',2),
  ('supp_cde','pan_no','PAN No','text','Identity',3),
  ('supp_cde','trading_code','Trading Code','text','Identity',4),
  ('supp_cde','gender','Gender','select:Male|Female|Other','Identity',5),
  ('supp_cde','dob','Date of Birth','date','Identity',6),
  ('supp_cde','mobile','Mobile','phone','Contact',7),
  ('supp_cde','email','Email','email','Contact',8),
  ('supp_cde','mailing_street','Mailing Street','text','Contact',9),
  ('supp_cde','mailing_city','Mailing City','text','Contact',10),
  ('supp_cde','mailing_state','Mailing State','text','Contact',11),
  ('supp_cde','mailing_zip','Mailing Zipcode','text','Contact',12),
  ('supp_cde','eq_dealer_email','Equity Dealer email','email','Ownership',13),
  ('supp_cde','rm_email','RM email','email','Ownership',14),
  ('supp_cde','rm_name','RM Name','text','Ownership',15),
  ('supp_cde','founder_connect','Founder Connect','text','Founder',16),
  ('supp_cde','founder_ranking','Founder Ranking','text','Founder',17),
  ('supp_cde','founder_reference','Founder Reference','text','Founder',18),
  ('supp_cde','inside_outside','Inside/Outside','select:Inside|Outside','Founder',19),
  ('supp_cde','net_worth_1','Net Worth 1','text','Founder',20),
  ('supp_cde','db_source','MF & Eq Database Source','text','Founder',21),
  ('supp_cde','eq_setup_date','Eq Setup Date','date','Equity',22),
  ('supp_cde','eq_active_date','EQ A/C Active Date','date','Equity',23),
  ('supp_cde','uploaded_in_connect','Uploaded in connect','select:Yes|No','Equity',24),
  ('supp_cde','traded','Traded','select:Yes|No','Equity',25),
  ('supp_cde','traded_date','Date','date','Equity',26),
  ('supp_cde','bse_client_code','BSE Client Code','text','Mutual fund',27),
  ('supp_cde','wealthelite_id','Wealthelite Cust Id.','text','Mutual fund',28),
  ('supp_cde','mf_setup_date','MF Setup Date','date','Mutual fund',29),
  ('supp_cde','mf_active_date','MF A/C Active Date','date','Mutual fund',30),
  ('supp_cde','folio_check_date','Folio Creation Check Date','date','Mutual fund',31),
  ('supp_cde','change_of_broker','Change of Broker','select:Yes|No','Mutual fund',32)
on conflict (module, field_key) do update set label = excluded.label, ftype = excluded.ftype, grp = excluded.grp, sort = excluded.sort;

insert into public.module_features (module, feature_key, label, kind) values
  ('supp_cde','report_pipeline','Setup & activation report','report'),
  ('supp_cde','report_founder','Founder connect report','report'),
  ('supp_cde','zoho_flags','Tick the Zoho-updated boxes','action'),
  ('supp_cde','export','Export to Excel','action'),
  ('supp_cde','view_log','See the change log','action')
on conflict (module, feature_key) do nothing;
