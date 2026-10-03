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
