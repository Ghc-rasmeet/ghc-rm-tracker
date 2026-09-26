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
