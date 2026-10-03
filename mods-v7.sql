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

-- v7.1: people list for inventory (app users appear automatically; admin adds the rest)
insert into public.lookup_values (module, list_key, value, sort) values ('inv','person','—',0)
on conflict do nothing;
