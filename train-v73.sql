-- =====================================================================
-- GHC Hub v7.3 — Training Library (documents, notes, decks)
-- =====================================================================
insert into public.modules (key, name, sort) values ('train','Training Library',9) on conflict (key) do nothing;

create table if not exists public.library_items (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  kind text default 'Training',          -- Training / Mentorship / Motivation / Process / Culture
  department text,
  audience text,                         -- for whom
  tags text[] default '{}',
  summary text,                          -- a few lines about it
  note text,                             -- optional full text typed straight in
  speaker text,                          -- who gave the training
  held_on date,
  status text default 'published' check (status in ('draft','published','archived')),
  author_user uuid references public.profiles(id) on delete set null,
  extra jsonb default '{}'::jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists lib_kind_idx on public.library_items (kind);
create index if not exists lib_dept_idx on public.library_items (department);
create index if not exists lib_search_idx on public.library_items
  using gin (to_tsvector('english', coalesce(title,'') || ' ' || coalesce(summary,'') || ' ' || coalesce(note,'') || ' ' || coalesce(speaker,'')));

create table if not exists public.library_files (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.library_items(id) on delete cascade,
  path text not null,
  file_name text not null,
  file_type text,
  size_kb int,
  uploaded_by uuid references public.profiles(id) on delete set null,
  uploaded_at timestamptz default now()
);
create index if not exists lib_files_idx on public.library_files (item_id);

alter table public.library_items enable row level security;
alter table public.library_files enable row level security;
drop policy if exists "lib: read" on public.library_items;
create policy "lib: read" on public.library_items for select using (public.has_module('train','view'));
drop policy if exists "lib: edit" on public.library_items;
create policy "lib: edit" on public.library_items for all using (public.has_module('train','edit')) with check (public.has_module('train','edit'));
drop policy if exists "libf: read" on public.library_files;
create policy "libf: read" on public.library_files for select using (public.has_module('train','view'));
drop policy if exists "libf: edit" on public.library_files;
create policy "libf: edit" on public.library_files for all using (public.has_module('train','edit')) with check (public.has_module('train','edit'));

-- storage for the documents
insert into storage.buckets (id, name, public) values ('library','library', false) on conflict (id) do nothing;
drop policy if exists "library read" on storage.objects;
create policy "library read" on storage.objects for select using (bucket_id = 'library' and public.has_module('train','view'));
drop policy if exists "library write" on storage.objects;
create policy "library write" on storage.objects for insert with check (bucket_id = 'library' and public.has_module('train','edit'));
drop policy if exists "library manage" on storage.objects;
create policy "library manage" on storage.objects for all
  using (bucket_id = 'library' and (public.is_super() or public.has_module('train','admin')))
  with check (bucket_id = 'library' and (public.is_super() or public.has_module('train','admin')));

insert into public.module_features (module, feature_key, label, kind) values
  ('train','manage_lists','Manage dropdown lists','action'),
  ('train','delete_item','Delete an item from the library','action'),
  ('train','export','Export the index to Excel','action')
on conflict do nothing;

insert into public.lookup_values (module, list_key, value, sort) values
  ('train','kind','Training',0), ('train','kind','Mentorship',1), ('train','kind','Motivation',2),
  ('train','kind','Process',3), ('train','kind','Culture',4), ('train','kind','Announcement',5),
  ('train','department','All',0), ('train','department','Wealth',1), ('train','department','Equity',2),
  ('train','department','Academy',3), ('train','department','Operations',4), ('train','department','Marketing',5),
  ('train','audience','Everyone',0), ('train','audience','Mentors',1), ('train','audience','RMs',2),
  ('train','audience','Coordinators',3), ('train','audience','New joiners',4), ('train','audience','Management',5),
  ('train','speaker','Founder',0), ('train','speaker','HR',1)
on conflict do nothing;
