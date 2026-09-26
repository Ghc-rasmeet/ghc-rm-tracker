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
