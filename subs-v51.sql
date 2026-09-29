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
