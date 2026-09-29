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
