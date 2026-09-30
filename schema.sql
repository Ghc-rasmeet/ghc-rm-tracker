-- =====================================================================
-- GHC Touch Tracker — complete database schema (v3.10, 26 Sep 2026)
-- Safe to run on a fresh Supabase project OR re-run on an existing one.
-- Order: run this, deploy admin-users edge function, create users,
--        set names/roles (bottom), then Restore from a Backup file.
-- =====================================================================

-- ---------- profiles (one row per login) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role text not null default 'rm',
  email text,
  created_at timestamptz default now()
);
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('rm','manager','admin'));

create or replace function public.is_manager()
returns boolean language sql stable security definer as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('manager','admin'));
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email), new.email);
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- clients (from Zoho export) ----------
create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  client_code text,                -- Wealthelite Cust Id.
  name text not null,              -- Full Name
  pan text,                        -- PAN No
  family_head text,                -- Family Head Name
  family_head_pan text,            -- Family Head PAN (grouping key)
  rm_id uuid references public.profiles(id),   -- matched from MF RM Email
  mf_rm_name text,                 -- MF RM
  lead_advisory text,              -- Lead Advisory
  created_at timestamptz default now()
);
alter table public.clients drop constraint if exists clients_code_key;
alter table public.clients add constraint clients_code_key unique (client_code);
create index if not exists clients_rm_idx      on public.clients (rm_id);
create index if not exists clients_family_idx  on public.clients (family_head);
create index if not exists clients_fh_pan_idx  on public.clients (family_head_pan);

-- ---------- touches (append-only log; edits keep history in touch_log) ----------
create table if not exists public.touches (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  rm_id uuid not null references public.profiles(id),
  touch_date date not null default current_date,
  mode text not null,          -- comma-separated: call, meeting, message
  status text not null,
  touch_type text not null default 'relationship',  -- comma-separated: sales, relationship
  note text,
  expected_date date,
  edited_at timestamptz,
  created_at timestamptz default now()
);
alter table public.touches drop constraint if exists touches_mode_check;
alter table public.touches drop constraint if exists touches_touch_type_check;
alter table public.touches drop constraint if exists touches_status_check;
alter table public.touches add constraint touches_status_check
  check (status in ('no answer','discussing','declined','interested','executed','avoiding','none'));
create index if not exists touches_client_idx on public.touches (client_id, touch_date desc);
create index if not exists touches_rm_idx     on public.touches (rm_id, touch_date desc);

create table if not exists public.touch_log (
  id uuid primary key default gen_random_uuid(),
  touch_id uuid not null,
  client_id uuid not null references public.clients(id) on delete cascade,
  rm_id uuid not null references public.profiles(id),
  touch_date date, mode text, status text, touch_type text, note text, expected_date date,
  logged_at timestamptz default now()
);
create index if not exists touch_log_touch_idx on public.touch_log (touch_id, logged_at desc);

-- ---------- written reviews (one per client per quarter) + history ----------
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  rm_id uuid not null references public.profiles(id),
  quarter_start date not null,
  status text not null,
  sent_date date,
  note text,
  updated_at timestamptz default now(),
  unique (client_id, quarter_start)
);
alter table public.reviews drop constraint if exists reviews_status_check;
alter table public.reviews add constraint reviews_status_check
  check (status in ('sent','discussing','declined','interested','executed','avoiding'));
create index if not exists reviews_client_idx on public.reviews (client_id, quarter_start);

create table if not exists public.review_log (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  rm_id uuid not null references public.profiles(id),
  quarter_start date not null,
  status text not null,
  sent_date date,
  note text,
  logged_at timestamptz default now()
);
create index if not exists review_log_client_idx on public.review_log (client_id, logged_at desc);

-- ---------- upload log (manager dashboard line) ----------
create table if not exists public.upload_log (
  id uuid primary key default gen_random_uuid(),
  uploaded_at timestamptz default now(),
  by_user uuid references public.profiles(id),
  file_name text, rows_in_excel int, uploaded int, skipped int, no_rm int
);

-- =====================================================================
-- Row level security
-- =====================================================================
alter table public.profiles   enable row level security;
alter table public.clients    enable row level security;
alter table public.touches    enable row level security;
alter table public.touch_log  enable row level security;
alter table public.reviews    enable row level security;
alter table public.review_log enable row level security;
alter table public.upload_log enable row level security;

-- profiles
drop policy if exists "profiles: own or manager" on public.profiles;
create policy "profiles: own or manager" on public.profiles
  for select using (id = auth.uid() or public.is_manager());

-- clients
drop policy if exists "clients: own or manager" on public.clients;
create policy "clients: own or manager" on public.clients
  for select using (rm_id = auth.uid() or public.is_manager());
drop policy if exists "clients: manager writes" on public.clients;
create policy "clients: manager writes" on public.clients
  for all using (public.is_manager()) with check (public.is_manager());

-- touches
drop policy if exists "touches: own or manager" on public.touches;
create policy "touches: own or manager" on public.touches
  for select using (rm_id = auth.uid() or public.is_manager()
    or exists (select 1 from public.clients c where c.id = client_id and c.rm_id = auth.uid()));
drop policy if exists "touches: rm inserts own" on public.touches;
create policy "touches: rm inserts own" on public.touches
  for insert with check (rm_id = auth.uid()
    and exists (select 1 from public.clients c where c.id = client_id and c.rm_id = auth.uid()));
drop policy if exists "touches: rm edits own" on public.touches;
create policy "touches: rm edits own" on public.touches
  for update using (rm_id = auth.uid()) with check (rm_id = auth.uid());
drop policy if exists "touches: manager writes" on public.touches;
create policy "touches: manager writes" on public.touches
  for all using (public.is_manager()) with check (public.is_manager());

-- touch_log
drop policy if exists "touch_log: read" on public.touch_log;
create policy "touch_log: read" on public.touch_log for select using (
  rm_id = auth.uid() or public.is_manager()
  or exists (select 1 from public.clients c where c.id = client_id and c.rm_id = auth.uid()));
drop policy if exists "touch_log: insert" on public.touch_log;
create policy "touch_log: insert" on public.touch_log for insert with check (
  public.is_manager() or exists (select 1 from public.clients c where c.id = client_id and c.rm_id = auth.uid()));

-- reviews
drop policy if exists "reviews: read" on public.reviews;
create policy "reviews: read" on public.reviews for select using (
  rm_id = auth.uid() or public.is_manager()
  or exists (select 1 from public.clients c where c.id = client_id and c.rm_id = auth.uid()));
drop policy if exists "reviews: rm writes own clients" on public.reviews;
create policy "reviews: rm writes own clients" on public.reviews for all using (
  exists (select 1 from public.clients c where c.id = client_id and c.rm_id = auth.uid()))
  with check (exists (select 1 from public.clients c where c.id = client_id and c.rm_id = auth.uid()));
drop policy if exists "reviews: manager" on public.reviews;
create policy "reviews: manager" on public.reviews for all using (public.is_manager()) with check (public.is_manager());

-- review_log
drop policy if exists "review_log: read" on public.review_log;
create policy "review_log: read" on public.review_log for select using (
  rm_id = auth.uid() or public.is_manager()
  or exists (select 1 from public.clients c where c.id = client_id and c.rm_id = auth.uid()));
drop policy if exists "review_log: insert" on public.review_log;
create policy "review_log: insert" on public.review_log for insert with check (
  public.is_manager() or exists (select 1 from public.clients c where c.id = client_id and c.rm_id = auth.uid()));

-- upload_log
drop policy if exists "upload_log: manager" on public.upload_log;
create policy "upload_log: manager" on public.upload_log
  for all using (public.is_manager()) with check (public.is_manager());

-- =====================================================================
-- After creating users in Authentication → Users, set names and roles.
-- (profiles rows are created automatically by the trigger.)
-- =====================================================================
-- update public.profiles set role = 'manager', full_name = 'Rasmeet Sethi' where email = 'rasmeet.sethi@greenhedgecapital.com';
-- update public.profiles set full_name = 'Abhishek Sharma' where email = 'abhishek.sharma@greenhedgecapital.com';
-- update public.profiles set full_name = 'Jasmeet'         where email = 'jasmeet@greenhedgecapital.com';
-- update public.profiles set full_name = 'Madhubani'       where email = 'madhubani@greenhedgecapital.com';
-- update public.profiles set full_name = 'Sehajpreet'      where email = 'sehajpreet@greenhedgecapital.com';
-- update public.profiles set full_name = 'Rahul Kapoor'    where email = 'rahul.kapoor@greenhedgecapital.com';
-- update public.profiles set full_name = 'Sannat'          where email = 'sannat@greenhedgecapital.com';
-- update public.profiles set full_name = 'Akshdeep Kaur'   where email = 'akshdeep.kaur@greenhedgecapital.com';
-- update public.profiles set full_name = 'Rohini'          where email = 'rohini@greenhedgecapital.com';
-- update public.profiles set full_name = 'Test RM'         where email = 'testing@greenhedgecapital.com';
-- =====================================================================
-- GHC Hub v4.0 — modules, per-user access, Insurance module, storage
-- Run once in SQL Editor. Also append to schema.sql in the repo.
-- =====================================================================

-- ---------- modules & access ----------
create table if not exists public.modules (key text primary key, name text not null, sort int default 0);
insert into public.modules (key, name, sort) values ('touch','Touch & Review System',1), ('insurance','Insurance',2)
  on conflict (key) do nothing;

create table if not exists public.user_modules (
  user_id uuid not null references public.profiles(id) on delete cascade,
  module text not null references public.modules(key) on delete cascade,
  level text not null default 'edit' check (level in ('view','edit')),
  primary key (user_id, module)
);
-- everyone who exists today keeps the Touch module
insert into public.user_modules (user_id, module, level) select id, 'touch', 'edit' from public.profiles on conflict do nothing;

create or replace function public.has_module(m text, lvl text default 'view')
returns boolean language sql stable security definer as $$
  select public.is_manager() or exists (
    select 1 from public.user_modules um where um.user_id = auth.uid() and um.module = m
      and (lvl = 'view' or um.level = 'edit'));
$$;

alter table public.modules enable row level security;
alter table public.user_modules enable row level security;
drop policy if exists "modules: read" on public.modules;
create policy "modules: read" on public.modules for select using (true);
drop policy if exists "user_modules: own or manager" on public.user_modules;
create policy "user_modules: own or manager" on public.user_modules for select using (user_id = auth.uid() or public.is_manager());
drop policy if exists "user_modules: manager writes" on public.user_modules;
create policy "user_modules: manager writes" on public.user_modules for all using (public.is_manager()) with check (public.is_manager());

-- ---------- insurance ----------
create table if not exists public.ins_types (id serial primary key, name text unique not null, active boolean default true);
insert into public.ins_types (name) values ('Health'), ('Life'), ('General') on conflict (name) do nothing;

create table if not exists public.ins_clients (
  id uuid primary key default gen_random_uuid(),
  pan text unique,
  name text not null,
  phone text, email text,
  client_id uuid references public.clients(id) on delete set null,
  created_at timestamptz default now()
);

create table if not exists public.policies (
  id uuid primary key default gen_random_uuid(),
  ins_client_id uuid not null references public.ins_clients(id) on delete cascade,
  type text not null,
  policy_no text not null,
  kind text not null check (kind in ('fresh','renewal')),
  plan_name text,
  sum_assured numeric, existing_bonus numeric, bonus numeric,
  valid_from date, valid_to date,
  collection_date date, collection_amt numeric, next_due date,
  rm_id uuid references public.profiles(id) on delete set null,
  service_only boolean default false,
  narration text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);
create index if not exists policies_client_idx on public.policies (ins_client_id);
create index if not exists policies_due_idx on public.policies (next_due);
create index if not exists policies_no_idx on public.policies (policy_no);

create table if not exists public.policy_nominees (
  id uuid primary key default gen_random_uuid(),
  policy_id uuid not null references public.policies(id) on delete cascade,
  name text not null, relation text, share numeric
);

create table if not exists public.policy_files (
  id uuid primary key default gen_random_uuid(),
  ins_client_id uuid not null references public.ins_clients(id) on delete cascade,
  policy_id uuid references public.policies(id) on delete set null,
  path text not null,
  file_name text not null,
  uploaded_by uuid references public.profiles(id) on delete set null,
  uploaded_at timestamptz default now()
);

alter table public.ins_types enable row level security;
alter table public.ins_clients enable row level security;
alter table public.policies enable row level security;
alter table public.policy_nominees enable row level security;
alter table public.policy_files enable row level security;

drop policy if exists "ins_types: read" on public.ins_types;
create policy "ins_types: read" on public.ins_types for select using (public.has_module('insurance','view'));
drop policy if exists "ins_types: manager" on public.ins_types;
create policy "ins_types: manager" on public.ins_types for all using (public.is_manager()) with check (public.is_manager());

drop policy if exists "ins_clients: read" on public.ins_clients;
create policy "ins_clients: read" on public.ins_clients for select using (public.has_module('insurance','view'));
drop policy if exists "ins_clients: edit" on public.ins_clients;
create policy "ins_clients: edit" on public.ins_clients for all using (public.has_module('insurance','edit')) with check (public.has_module('insurance','edit'));

drop policy if exists "policies: read" on public.policies;
create policy "policies: read" on public.policies for select using (public.has_module('insurance','view'));
drop policy if exists "policies: edit" on public.policies;
create policy "policies: edit" on public.policies for all using (public.has_module('insurance','edit')) with check (public.has_module('insurance','edit'));

drop policy if exists "nominees: read" on public.policy_nominees;
create policy "nominees: read" on public.policy_nominees for select using (public.has_module('insurance','view'));
drop policy if exists "nominees: edit" on public.policy_nominees;
create policy "nominees: edit" on public.policy_nominees for all using (public.has_module('insurance','edit')) with check (public.has_module('insurance','edit'));

drop policy if exists "files: read" on public.policy_files;
create policy "files: read" on public.policy_files for select using (public.has_module('insurance','view'));
drop policy if exists "files: edit" on public.policy_files;
create policy "files: edit" on public.policy_files for all using (public.has_module('insurance','edit')) with check (public.has_module('insurance','edit'));

-- ---------- storage bucket for policy documents ----------
insert into storage.buckets (id, name, public) values ('policies','policies', false) on conflict (id) do nothing;
drop policy if exists "policies bucket read" on storage.objects;
create policy "policies bucket read" on storage.objects for select using (bucket_id = 'policies' and public.has_module('insurance','view'));
drop policy if exists "policies bucket write" on storage.objects;
create policy "policies bucket write" on storage.objects for insert with check (bucket_id = 'policies' and public.has_module('insurance','edit'));
drop policy if exists "policies bucket manage" on storage.objects;
create policy "policies bucket manage" on storage.objects for all using (bucket_id = 'policies' and public.is_manager()) with check (bucket_id = 'policies' and public.is_manager());

-- v4.1: policy holder + covered members
alter table public.policies add column if not exists holder_name text;
alter table public.policies add column if not exists holder_age int;
create table if not exists public.policy_members (
  id uuid primary key default gen_random_uuid(),
  policy_id uuid not null references public.policies(id) on delete cascade,
  name text not null, age int, relation text
);
alter table public.policy_members enable row level security;
drop policy if exists "members: read" on public.policy_members;
create policy "members: read" on public.policy_members for select using (public.has_module('insurance','view'));
drop policy if exists "members: edit" on public.policy_members;
create policy "members: edit" on public.policy_members for all using (public.has_module('insurance','edit')) with check (public.has_module('insurance','edit'));

-- v4.2: date of birth for holder and members (age computed)
alter table public.policies add column if not exists holder_dob date;
alter table public.policy_members add column if not exists dob date;
-- =====================================================================
-- GHC Hub v5.0 — permission model + Subscriptions module
-- =====================================================================

-- ---------- roles: admin = SUPER admin, manager = admin, rm = coordinator
create or replace function public.is_super()
returns boolean language sql stable security definer as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- per-module grant gains 'admin' level + reveal flag
alter table public.user_modules drop constraint if exists user_modules_level_check;
alter table public.user_modules add constraint user_modules_level_check check (level in ('view','edit','admin'));
alter table public.user_modules add column if not exists can_reveal boolean default false;

-- module access: super admin has everything; everyone else needs a grant
create or replace function public.has_module(m text, lvl text default 'view')
returns boolean language sql stable security definer as $$
  select public.is_super() or exists (
    select 1 from public.user_modules um
    where um.user_id = auth.uid() and um.module = m
      and case lvl when 'view' then true
                   when 'edit' then um.level in ('edit','admin')
                   when 'admin' then um.level = 'admin' end);
$$;

create or replace function public.can_reveal(m text)
returns boolean language sql stable security definer as $$
  select public.is_super() or exists (
    select 1 from public.user_modules um where um.user_id = auth.uid() and um.module = m and um.can_reveal);
$$;

-- grant rules: super admin manages anyone; a module-admin manages that module only
drop policy if exists "user_modules: manager writes" on public.user_modules;
drop policy if exists "user_modules: super writes" on public.user_modules;
create policy "user_modules: super writes" on public.user_modules for all
  using (public.is_super()) with check (public.is_super());
drop policy if exists "user_modules: module admin writes" on public.user_modules;
create policy "user_modules: module admin writes" on public.user_modules for all
  using (public.has_module(module,'admin')) with check (public.has_module(module,'admin'));
drop policy if exists "user_modules: own or manager" on public.user_modules;
create policy "user_modules: read" on public.user_modules for select
  using (user_id = auth.uid() or public.is_super() or public.has_module(module,'admin'));

-- existing grants: everyone keeps Touch; give current managers admin on both modules
update public.user_modules set level = 'admin'
 where user_id in (select id from public.profiles where role in ('manager','admin'));
insert into public.user_modules (user_id, module, level, can_reveal)
  select id, 'insurance', 'admin', true from public.profiles where role in ('manager','admin')
  on conflict (user_id, module) do nothing;

-- ---------- subscriptions module ----------
insert into public.modules (key, name, sort) values ('subs','Subscriptions',3) on conflict (key) do nothing;

create table if not exists public.subs (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null default 'professional' check (category in ('personal','professional','both')),
  start_date date, end_date date,
  amount numeric,
  cycle text default 'monthly' check (cycle in ('monthly','quarterly','half-yearly','yearly','one-time')),
  auto_renew boolean default true,
  email text, phone text,
  username text, password text,           -- hidden unless can_reveal
  sensitive boolean default false,
  bank_name text, bank_account text,
  pay_mode text check (pay_mode in ('credit card','debit card','UPI','net banking','cash','other')),
  link text, narration text,
  status text not null default 'active' check (status in ('active','cancelled')),
  cancelled_on date, cancel_reason text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);
create index if not exists subs_end_idx on public.subs (end_date);
create index if not exists subs_status_idx on public.subs (status);

create table if not exists public.subs_log (
  id uuid primary key default gen_random_uuid(),
  sub_id uuid not null references public.subs(id) on delete cascade,
  action text not null,                    -- renewed / cancelled / edited
  start_date date, end_date date, amount numeric, note text,
  by_user uuid references public.profiles(id) on delete set null,
  logged_at timestamptz default now()
);

alter table public.subs enable row level security;
alter table public.subs_log enable row level security;
drop policy if exists "subs: read" on public.subs;
create policy "subs: read" on public.subs for select using (public.has_module('subs','view'));
drop policy if exists "subs: edit" on public.subs;
create policy "subs: edit" on public.subs for all using (public.has_module('subs','edit')) with check (public.has_module('subs','edit'));
drop policy if exists "subs_log: read" on public.subs_log;
create policy "subs_log: read" on public.subs_log for select using (public.has_module('subs','view'));
drop policy if exists "subs_log: edit" on public.subs_log;
create policy "subs_log: edit" on public.subs_log for all using (public.has_module('subs','edit')) with check (public.has_module('subs','edit'));

-- hide secrets from anyone without reveal rights
create or replace view public.subs_safe as
  select id, name, category, start_date, end_date, amount, cycle, auto_renew, phone, link, narration,
         bank_name, bank_account, pay_mode, status, cancelled_on, cancel_reason, sensitive, created_at, created_by,
         case when sensitive and not public.can_reveal('subs') then null else email end as email,
         case when sensitive and not public.can_reveal('subs') then null else username end as username,
         case when sensitive and not public.can_reveal('subs') then null else password end as password
  from public.subs;
-- v5.1: personal subscriptions visible to super admin only
drop view if exists public.subs_safe;
create view public.subs_safe with (security_invoker = on) as
  select id, name, category, start_date, end_date, amount, cycle, auto_renew, phone, link, narration,
         bank_name, bank_account, pay_mode, status, cancelled_on, cancel_reason, sensitive, created_at, created_by,
         case when sensitive and not public.can_reveal('subs') then null else email end as email,
         case when sensitive and not public.can_reveal('subs') then null else username end as username,
         case when sensitive and not public.can_reveal('subs') then null else password end as password
  from public.subs
  where category <> 'personal' or public.is_super();

-- only super admin may create or change a personal subscription
drop policy if exists "subs: edit" on public.subs;
create policy "subs: read base" on public.subs for select
  using (public.has_module('subs','view') and (category <> 'personal' or public.is_super()));
create policy "subs: write" on public.subs for insert
  with check (public.has_module('subs','edit') and (category <> 'personal' or public.is_super()));
create policy "subs: update" on public.subs for update
  using (public.has_module('subs','edit') and (category <> 'personal' or public.is_super()))
  with check (public.has_module('subs','edit') and (category <> 'personal' or public.is_super()));
create policy "subs: delete" on public.subs for delete
  using (public.is_super());
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
