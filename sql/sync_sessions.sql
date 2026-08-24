-- Сессии синхронизации: начальник создаёт сессию (короткий код → склад+дата),
-- работники входят по коду — им подставляются ресторан/склад/дата,
-- а список товаров (dict) берётся с устройства, создавшего сессию.
-- Запустить целиком в Supabase SQL Editor (идемпотентно).

-- 1) таблица сессий
create table if not exists public.sync_sessions (
  code text primary key,
  warehouse text not null,
  report_date text not null,
  device_id text,
  created_at timestamptz default now()
);

-- 1.1) список товаров, выгруженный создателем сессии
alter table public.sync_sessions add column if not exists dict jsonb;

-- 2) создать/обновить сессию по коду (со списком товаров)
drop function if exists public.create_session(text, text, text, text);
create or replace function public.create_session(p_code text, p_warehouse text, p_report_date text, p_device_id text, p_dict jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into sync_sessions(code, warehouse, report_date, device_id, dict)
  values (upper(trim(p_code)), p_warehouse, p_report_date, p_device_id, coalesce(p_dict, '[]'::jsonb))
  on conflict (code) do update set
    warehouse = excluded.warehouse,
    report_date = excluded.report_date,
    device_id = excluded.device_id,
    dict = excluded.dict,
    created_at = now();
  return jsonb_build_object('code', upper(trim(p_code)), 'warehouse', p_warehouse, 'report_date', p_report_date);
end;
$$;

-- 3) получить сессию по коду (null если нет) — вместе со списком товаров
create or replace function public.get_session(p_code text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select to_jsonb(s)
  from (select code, warehouse, report_date, created_at, dict
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
grant execute on function public.create_session(text, text, text, text, jsonb) to anon, authenticated;
grant execute on function public.get_session(text) to anon, authenticated;
grant execute on function public.list_sessions() to anon, authenticated;
