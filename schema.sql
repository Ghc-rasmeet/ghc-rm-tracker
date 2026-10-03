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
-- =====================================================================
-- v6.4 — list manager: usage counts, merge, delete-when-unused
-- =====================================================================

-- how many records use each list value, for every list in every module
create or replace function public.lookup_usage(m text)
returns table (list_key text, value text, uses bigint)
language plpgsql security definer as $$
declare r record; col text; tbl text; n bigint;
begin
  for r in select lv.list_key, lv.value from public.lookup_values lv where lv.module = m loop
    tbl := null; col := null;
    if m = 'insurance' then
      if r.list_key = 'plan'   then tbl := 'policies';          col := 'plan_name';
      elsif r.list_key = 'rm'  then tbl := 'policies';          col := 'rm_name';
      elsif r.list_key = 'nomrel' then tbl := 'policy_nominees'; col := 'relation';
      end if;
    elsif m = 'supp_cde' then
      tbl := 'cde_clients';
      col := case r.list_key when 'eqdealer' then 'eq_dealer_email' when 'rmemail' then 'rm_email'
        when 'rmname' then 'rm_name' when 'eqrm' then 'eq_rm' when 'founderyn' then 'founder_connect'
        when 'ranking' then 'founder_ranking' when 'iosa' then 'inside_outside'
        when 'networth' then 'net_worth_1' when 'dbsource' then 'db_source' end;
    elsif m = 'supp_fee' then
      tbl := 'fee_students';
      col := case r.list_key when 'course' then 'main_course' when 'subcourse' then 'sub_course'
        when 'source' then 'source' when 'quarter' then 'reg_quarter' when 'discount' then 'discount_reason'
        when 'rm' then 'rm' when 'bsintro' then 'bs_intro' when 'bsdeep' then 'bs_deep'
        when 'paystatus' then 'status_1' when 'yesno' then 'support' end;
    end if;
    n := 0;
    if tbl is not null and col is not null then
      execute format('select count(*) from public.%I where %I = $1', tbl, col) into n using r.value;
      if m = 'supp_fee' and r.list_key = 'paystatus' then
        execute 'select count(*) from public.fee_students where status_1 = $1 or status_2 = $1 or status_3 = $1' into n using r.value;
      end if;
      if m = 'supp_fee' and r.list_key = 'yesno' then
        execute 'select count(*) from public.fee_students where support = $1 or internal_support = $1' into n using r.value;
      end if;
    end if;
    list_key := r.list_key; value := r.value; uses := n; return next;
  end loop;
end;
$$;

-- move every record from one value to another, then the old one can be deleted
create or replace function public.lookup_merge(m text, lk text, from_value text, to_value text)
returns bigint language plpgsql security definer as $$
declare tbl text; col text; n bigint := 0;
begin
  if not (public.is_super() or public.has_module(m,'admin')) then
    raise exception 'Only an admin of this module can merge list values';
  end if;
  if m = 'insurance' then
    if lk = 'plan' then tbl := 'policies'; col := 'plan_name';
    elsif lk = 'rm' then tbl := 'policies'; col := 'rm_name';
    elsif lk = 'nomrel' then tbl := 'policy_nominees'; col := 'relation'; end if;
  elsif m = 'supp_cde' then
    tbl := 'cde_clients';
    col := case lk when 'eqdealer' then 'eq_dealer_email' when 'rmemail' then 'rm_email'
      when 'rmname' then 'rm_name' when 'eqrm' then 'eq_rm' when 'founderyn' then 'founder_connect'
      when 'ranking' then 'founder_ranking' when 'iosa' then 'inside_outside'
      when 'networth' then 'net_worth_1' when 'dbsource' then 'db_source' end;
  elsif m = 'supp_fee' then
    tbl := 'fee_students';
    col := case lk when 'course' then 'main_course' when 'subcourse' then 'sub_course'
      when 'source' then 'source' when 'quarter' then 'reg_quarter' when 'discount' then 'discount_reason'
      when 'rm' then 'rm' when 'bsintro' then 'bs_intro' when 'bsdeep' then 'bs_deep' end;
  end if;
  if tbl is null or col is null then
    if m = 'supp_fee' and lk = 'paystatus' then
      execute 'update public.fee_students set status_1 = $2 where status_1 = $1' using from_value, to_value;
      execute 'update public.fee_students set status_2 = $2 where status_2 = $1' using from_value, to_value;
      execute 'update public.fee_students set status_3 = $2 where status_3 = $1' using from_value, to_value;
      get diagnostics n = row_count; return n;
    end if;
    if m = 'supp_fee' and lk = 'yesno' then
      execute 'update public.fee_students set support = $2 where support = $1' using from_value, to_value;
      execute 'update public.fee_students set internal_support = $2 where internal_support = $1' using from_value, to_value;
      get diagnostics n = row_count; return n;
    end if;
    raise exception 'That list is not linked to a field yet';
  end if;
  execute format('update public.%I set %I = $2 where %I = $1', tbl, col, col) using from_value, to_value;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- deleting a list value is only allowed when nothing uses it
create or replace function public.lookup_delete(m text, lk text, v text)
returns void language plpgsql security definer as $$
declare n bigint;
begin
  if not (public.is_super() or public.has_module(m,'admin')) then
    raise exception 'Only an admin of this module can delete list values';
  end if;
  select uses into n from public.lookup_usage(m) u where u.list_key = lk and u.value = v;
  if coalesce(n,0) > 0 then
    raise exception 'Still used by % record(s). Merge it into another option first.', n;
  end if;
  delete from public.lookup_values where module = m and list_key = lk and value = v;
end;
$$;

-- insurance types reuse the same idea
create or replace function public.ins_type_usage()
returns table (name text, uses bigint) language sql security definer as $$
  select t.name, (select count(*) from public.policies p where p.type = t.name) from public.ins_types t;
$$;
-- =====================================================================
-- GHC Hub v7.0 — custom fields + Café, Inventory, Batch Tracking
-- =====================================================================

-- ---------- admin-added custom fields (any module) ----------
alter table public.module_fields add column if not exists is_custom boolean default false;
alter table public.cde_clients  add column if not exists extra jsonb default '{}'::jsonb;
alter table public.fee_students add column if not exists extra jsonb default '{}'::jsonb;
alter table public.policies     add column if not exists extra jsonb default '{}'::jsonb;
alter table public.subs         add column if not exists extra jsonb default '{}'::jsonb;

-- ---------- modules ----------
insert into public.modules (key, name, sort) values
  ('cafe','Café',5), ('inv','Inventory',6), ('batch','Batch Tracking',7)
on conflict (key) do nothing;

-- =====================  CAFÉ  =====================
create table if not exists public.cafe_items (
  id uuid primary key default gen_random_uuid(),
  name text not null, vendor text, category text,
  price numeric, unit text default 'plate',
  active boolean default true, note text,
  extra jsonb default '{}'::jsonb,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);

create table if not exists public.cafe_orders (
  id uuid primary key default gen_random_uuid(),
  title text not null, occasion text, order_date date default current_date,
  head_count int, status text default 'draft' check (status in ('draft','sent for approval','approved','ordered','cancelled')),
  note text, total numeric default 0,
  extra jsonb default '{}'::jsonb,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);

create table if not exists public.cafe_order_lines (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.cafe_orders(id) on delete cascade,
  item_id uuid references public.cafe_items(id) on delete set null,
  item_name text not null, vendor text, price numeric, qty numeric default 1,
  amount numeric generated always as (coalesce(price,0) * coalesce(qty,0)) stored
);

create or replace function public.cafe_total() returns trigger language plpgsql security definer as $$
declare oid uuid;
begin
  oid := coalesce(new.order_id, old.order_id);
  update public.cafe_orders set total = coalesce((select sum(amount) from public.cafe_order_lines where order_id = oid), 0) where id = oid;
  return null;
end; $$;
drop trigger if exists cafe_total_trg on public.cafe_order_lines;
create trigger cafe_total_trg after insert or update or delete on public.cafe_order_lines
  for each row execute function public.cafe_total();

alter table public.cafe_items enable row level security;
alter table public.cafe_orders enable row level security;
alter table public.cafe_order_lines enable row level security;
drop policy if exists "cafe_items: read" on public.cafe_items;
create policy "cafe_items: read" on public.cafe_items for select using (public.has_module('cafe','view'));
drop policy if exists "cafe_items: admin" on public.cafe_items;
create policy "cafe_items: admin" on public.cafe_items for all
  using (public.is_super() or public.has_module('cafe','admin')) with check (public.is_super() or public.has_module('cafe','admin'));
drop policy if exists "cafe_orders: read" on public.cafe_orders;
create policy "cafe_orders: read" on public.cafe_orders for select using (public.has_module('cafe','view'));
drop policy if exists "cafe_orders: edit" on public.cafe_orders;
create policy "cafe_orders: edit" on public.cafe_orders for all using (public.has_module('cafe','edit')) with check (public.has_module('cafe','edit'));
drop policy if exists "cafe_lines: read" on public.cafe_order_lines;
create policy "cafe_lines: read" on public.cafe_order_lines for select using (public.has_module('cafe','view'));
drop policy if exists "cafe_lines: edit" on public.cafe_order_lines;
create policy "cafe_lines: edit" on public.cafe_order_lines for all using (public.has_module('cafe','edit')) with check (public.has_module('cafe','edit'));

insert into public.module_features (module, feature_key, label, kind) values
  ('cafe','manage_items','Add, edit and delete food items','action'),
  ('cafe','manage_lists','Manage dropdown lists','action'),
  ('cafe','export','Export to Excel','action')
on conflict do nothing;
insert into public.lookup_values (module, list_key, value, sort) values
  ('cafe','vendor','—',0), ('cafe','category','Snacks',0), ('cafe','category','Meals',1),
  ('cafe','category','Sweets',2), ('cafe','category','Beverages',3),
  ('cafe','occasion','Office event',0), ('cafe','occasion','Client meeting',1),
  ('cafe','occasion','Training',2), ('cafe','occasion','Festival',3)
on conflict do nothing;

-- =====================  INVENTORY  =====================
create table if not exists public.inv_items (
  id uuid primary key default gen_random_uuid(),
  code text unique, name text not null, category text, unit text default 'piece',
  opening_qty numeric default 0, rate numeric, reorder_level numeric default 0,
  active boolean default true, note text,
  extra jsonb default '{}'::jsonb,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);

create table if not exists public.inv_moves (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.inv_items(id) on delete cascade,
  move_type text not null check (move_type in ('purchase','free','paid','adjust','return')),
  qty numeric not null,
  person text, person_type text default 'employee' check (person_type in ('employee','client','other')),
  rate numeric, amount numeric,
  move_date date default current_date, note text,
  by_user uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);
create index if not exists inv_moves_item_idx on public.inv_moves (item_id, move_date desc);
create index if not exists inv_moves_person_idx on public.inv_moves (person);

create table if not exists public.inv_payments (
  id uuid primary key default gen_random_uuid(),
  person text not null, amount numeric not null, pay_date date default current_date,
  mode text, note text, by_user uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);

-- stock on hand, per item
create or replace view public.inv_stock with (security_invoker = on) as
  select i.id, i.code, i.name, i.category, i.unit, i.rate, i.reorder_level, i.active, i.opening_qty, i.extra,
    coalesce(i.opening_qty,0)
      + coalesce((select sum(qty) from public.inv_moves m where m.item_id = i.id and m.move_type in ('purchase','return')),0)
      - coalesce((select sum(qty) from public.inv_moves m where m.item_id = i.id and m.move_type in ('free','paid')),0)
      + coalesce((select sum(qty) from public.inv_moves m where m.item_id = i.id and m.move_type = 'adjust'),0) as balance,
    coalesce((select sum(qty) from public.inv_moves m where m.item_id = i.id and m.move_type = 'free'),0) as given_free,
    coalesce((select sum(qty) from public.inv_moves m where m.item_id = i.id and m.move_type = 'paid'),0) as given_paid
  from public.inv_items i;

-- what each person owes
create or replace view public.inv_dues with (security_invoker = on) as
  select p.person, p.person_type,
    coalesce(sum(p.amount),0) as billed,
    coalesce((select sum(amount) from public.inv_payments ip where ip.person = p.person),0) as paid,
    coalesce(sum(p.amount),0) - coalesce((select sum(amount) from public.inv_payments ip where ip.person = p.person),0) as due
  from public.inv_moves p
  where p.move_type = 'paid' and coalesce(p.person,'') <> ''
  group by p.person, p.person_type;

alter table public.inv_items enable row level security;
alter table public.inv_moves enable row level security;
alter table public.inv_payments enable row level security;
drop policy if exists "inv_items: read" on public.inv_items;
create policy "inv_items: read" on public.inv_items for select using (public.has_module('inv','view'));
drop policy if exists "inv_items: admin" on public.inv_items;
create policy "inv_items: admin" on public.inv_items for all
  using (public.is_super() or public.has_module('inv','admin')) with check (public.is_super() or public.has_module('inv','admin'));
drop policy if exists "inv_moves: read" on public.inv_moves;
create policy "inv_moves: read" on public.inv_moves for select using (public.has_module('inv','view'));
drop policy if exists "inv_moves: edit" on public.inv_moves;
create policy "inv_moves: edit" on public.inv_moves for all using (public.has_module('inv','edit')) with check (public.has_module('inv','edit'));
drop policy if exists "inv_pay: read" on public.inv_payments;
create policy "inv_pay: read" on public.inv_payments for select using (public.has_module('inv','view'));
drop policy if exists "inv_pay: edit" on public.inv_payments;
create policy "inv_pay: edit" on public.inv_payments for all using (public.has_module('inv','edit')) with check (public.has_module('inv','edit'));

insert into public.module_features (module, feature_key, label, kind) values
  ('inv','manage_items','Add, edit and delete items','action'),
  ('inv','manage_lists','Manage dropdown lists','action'),
  ('inv','record_payment','Record a payment against dues','action'),
  ('inv','export','Export to Excel','action'),
  ('inv','report_closing','Monthly closing report','report')
on conflict do nothing;
insert into public.lookup_values (module, list_key, value, sort) values
  ('inv','category','Stationery',0), ('inv','category','Merchandise',1),
  ('inv','category','Printed',2), ('inv','category','Other',3),
  ('inv','unit','piece',0), ('inv','unit','box',1), ('inv','unit','set',2)
on conflict do nothing;

-- =====================  BATCH TRACKING  =====================
create table if not exists public.batches (
  id uuid primary key default gen_random_uuid(),
  name text not null, course text, instructor text, coordinator text,
  whatsapp_group text, start_date date, end_date date,
  status text default 'running' check (status in ('upcoming','running','completed','cancelled')),
  note text, extra jsonb default '{}'::jsonb,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);

create table if not exists public.batch_students (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.batches(id) on delete cascade,
  student_name text not null, phone text, email text,
  fee_student_id uuid references public.fee_students(id) on delete set null,
  joined_on date default current_date,
  status text default 'active' check (status in ('active','left','completed')),
  note text, extra jsonb default '{}'::jsonb
);
create index if not exists batch_students_idx on public.batch_students (batch_id);

alter table public.batches enable row level security;
alter table public.batch_students enable row level security;
drop policy if exists "batches: read" on public.batches;
create policy "batches: read" on public.batches for select using (public.has_module('batch','view'));
drop policy if exists "batches: edit" on public.batches;
create policy "batches: edit" on public.batches for all using (public.has_module('batch','edit')) with check (public.has_module('batch','edit'));
drop policy if exists "bstudents: read" on public.batch_students;
create policy "bstudents: read" on public.batch_students for select using (public.has_module('batch','view'));
drop policy if exists "bstudents: edit" on public.batch_students;
create policy "bstudents: edit" on public.batch_students for all using (public.has_module('batch','edit')) with check (public.has_module('batch','edit'));

insert into public.module_features (module, feature_key, label, kind) values
  ('batch','manage_lists','Manage dropdown lists','action'),
  ('batch','export','Export to Excel','action')
on conflict do nothing;
insert into public.lookup_values (module, list_key, value, sort) values
  ('batch','course','Green',0), ('batch','course','Blue',1), ('batch','course','F&O',2),
  ('batch','instructor','—',0), ('batch','coordinator','—',0)
on conflict do nothing;

-- custom fields can be added to any of the new tables too
alter table public.cafe_items add column if not exists extra jsonb default '{}'::jsonb;

-- v7.1: people list for inventory
insert into public.lookup_values (module, list_key, value, sort) values ('inv','person','—',0) on conflict do nothing;
-- =====================================================================
-- GHC Hub v7.2 — KPI & Culture module
-- =====================================================================
insert into public.modules (key, name, sort) values ('kpi','KPI & Culture',8) on conflict (key) do nothing;

-- who can rate, and in which chair
create table if not exists public.kpi_raters (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  rater_role text not null check (rater_role in ('hr','founder'))
);

create table if not exists public.kpi_employees (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  user_id uuid references public.profiles(id) on delete set null,
  department text, designation text, joined_on date,
  active boolean default true, note text,
  extra jsonb default '{}'::jsonb,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);

create table if not exists public.kpi_ratings (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.kpi_employees(id) on delete cascade,
  quarter text not null,                       -- 'Q2 2026-27'
  rater_role text not null check (rater_role in ('hr','founder')),
  rater_user uuid references public.profiles(id) on delete set null,
  kpi_score numeric check (kpi_score >= 0 and kpi_score <= 10),
  culture_score numeric check (culture_score >= 0 and culture_score <= 10),
  kpi_note text, culture_note text,
  updated_at timestamptz default now(),
  unique (employee_id, quarter, rater_role)
);
create index if not exists kpi_rate_idx on public.kpi_ratings (employee_id, quarter);

create table if not exists public.kpi_incidents (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.kpi_employees(id) on delete cascade,
  quarter text, incident_date date default current_date,
  kind text default 'note' check (kind in ('appreciation','concern','note')),
  title text, note text,
  by_user uuid references public.profiles(id) on delete set null,
  by_role text,
  created_at timestamptz default now()
);
create index if not exists kpi_inc_idx on public.kpi_incidents (employee_id, incident_date desc);

-- combined score per employee per quarter
create or replace view public.kpi_scores with (security_invoker = on) as
  select e.id as employee_id, e.name, e.department, e.designation, e.active, r.quarter,
    avg(r.kpi_score)     as avg_kpi,
    avg(r.culture_score) as avg_culture,
    round((coalesce(avg(r.kpi_score),0) + coalesce(avg(r.culture_score),0)) / 2, 2) as combined,
    count(*) as raters
  from public.kpi_employees e
  join public.kpi_ratings r on r.employee_id = e.id
  group by e.id, e.name, e.department, e.designation, e.active, r.quarter;

alter table public.kpi_raters enable row level security;
alter table public.kpi_employees enable row level security;
alter table public.kpi_ratings enable row level security;
alter table public.kpi_incidents enable row level security;

drop policy if exists "kpi_raters: read" on public.kpi_raters;
create policy "kpi_raters: read" on public.kpi_raters for select using (public.has_module('kpi','view'));
drop policy if exists "kpi_raters: admin" on public.kpi_raters;
create policy "kpi_raters: admin" on public.kpi_raters for all
  using (public.is_super() or public.has_module('kpi','admin')) with check (public.is_super() or public.has_module('kpi','admin'));

drop policy if exists "kpi_emp: read" on public.kpi_employees;
create policy "kpi_emp: read" on public.kpi_employees for select using (public.has_module('kpi','view'));
drop policy if exists "kpi_emp: admin" on public.kpi_employees;
create policy "kpi_emp: admin" on public.kpi_employees for all
  using (public.is_super() or public.has_module('kpi','admin')) with check (public.is_super() or public.has_module('kpi','admin'));

drop policy if exists "kpi_rate: read" on public.kpi_ratings;
create policy "kpi_rate: read" on public.kpi_ratings for select using (public.has_module('kpi','view'));
-- a rater may only write in their own chair
drop policy if exists "kpi_rate: write" on public.kpi_ratings;
create policy "kpi_rate: write" on public.kpi_ratings for all
  using (public.is_super() or exists (select 1 from public.kpi_raters k where k.user_id = auth.uid() and k.rater_role = rater_role))
  with check (public.is_super() or exists (select 1 from public.kpi_raters k where k.user_id = auth.uid() and k.rater_role = rater_role));

drop policy if exists "kpi_inc: read" on public.kpi_incidents;
create policy "kpi_inc: read" on public.kpi_incidents for select using (public.has_module('kpi','view'));
drop policy if exists "kpi_inc: write" on public.kpi_incidents;
create policy "kpi_inc: write" on public.kpi_incidents for all
  using (public.has_module('kpi','edit')) with check (public.has_module('kpi','edit'));

insert into public.module_features (module, feature_key, label, kind) values
  ('kpi','manage_employees','Add and edit employees','action'),
  ('kpi','manage_raters','Decide who rates as HR and as Founder','action'),
  ('kpi','manage_lists','Manage dropdown lists','action'),
  ('kpi','export','Export to Excel','action'),
  ('kpi','report_year','Year summary report','report')
on conflict do nothing;

insert into public.lookup_values (module, list_key, value, sort) values
  ('kpi','department','Wealth',0), ('kpi','department','Equity',1), ('kpi','department','Academy',2),
  ('kpi','department','Operations',3), ('kpi','department','Marketing',4), ('kpi','department','Support',5),
  ('kpi','designation','RM',0), ('kpi','designation','Coordinator',1), ('kpi','designation','Specialist',2),
  ('kpi','designation','Manager',3), ('kpi','designation','Head',4)
on conflict do nothing;
