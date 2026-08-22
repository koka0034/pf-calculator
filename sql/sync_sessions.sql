-- Сессии синхронизации: начальник создаёт сессию (короткий код → склад+дата),
-- работники входят по коду — им подставляются ресторан/склад/дата.
-- Запустить целиком в Supabase SQL Editor (идемпотентно).

-- 1) таблица сессий
create table if not exists public.sync_sessions (
  code text primary key,
  warehouse text not null,
  report_date text not null,
  device_id text,
  created_at timestamptz default now()
);

-- 2) создать/обновить сессию по коду
create or replace function public.create_session(p_code text, p_warehouse text, p_report_date text, p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into sync_sessions(code, warehouse, report_date, device_id)
  values (upper(trim(p_code)), p_warehouse, p_report_date, p_device_id)
  on conflict (code) do update set
    warehouse = excluded.warehouse,
    report_date = excluded.report_date,
    device_id = excluded.device_id,
    created_at = now();
  return jsonb_build_object('code', upper(trim(p_code)), 'warehouse', p_warehouse, 'report_date', p_report_date);
end;
$$;

-- 3) получить сессию по коду (null если нет)
create or replace function public.get_session(p_code text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select to_jsonb(s)
  from (select code, warehouse, report_date, created_at
        from sync_sessions
        where code = upper(trim(p_code))) s;
$$;

-- 4) список последних сессий
create or replace function public.list_sessions()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(s) order by s.created_at desc), '[]'::jsonb)
  from (select code, warehouse, report_date, created_at
        from sync_sessions
        order by created_at desc
        limit 50) s;
$$;

-- 5) права
grant execute on function public.create_session(text, text, text, text) to anon, authenticated;
grant execute on function public.get_session(text) to anon, authenticated;
grant execute on function public.list_sessions() to anon, authenticated;
