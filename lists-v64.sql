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
