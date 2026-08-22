-- Синхронизация инвентаризации: per-device REPLACE + суммарный приём (drain).
-- Запустить целиком в Supabase SQL Editor.

-- 1) колонка для идентификатора устройства
alter table public.inventory_reports add column if not exists device_id text;

-- 2) выгрузка: заменяет вклад данного устройства (не суммирует — повторная выгрузка идемпотентна)
create or replace function public.upsert_fact(p_warehouse text, p_report_date text, p_device_id text, p_fact jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from inventory_reports
  where warehouse = p_warehouse and report_date = p_report_date and device_id = p_device_id;

  insert into inventory_reports (warehouse, report_date, device_id, fact)
  values (p_warehouse, p_report_date, p_device_id, coalesce(p_fact, '{}'::jsonb));
end;
$$;

-- 3) приём: суммирует вклады всех устройств по ключам, очищает сервер и возвращает сумму
create or replace function public.drain_fact(p_warehouse text, p_report_date text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  res jsonb := '{}'::jsonb;
  r record;
begin
  for r in
    select kv.key as k, sum(kv.value::numeric) as s
    from inventory_reports,
         jsonb_each_text(coalesce(fact, '{}'::jsonb)) as kv(key, value)
    where warehouse = p_warehouse and report_date = p_report_date
    group by kv.key
  loop
    res := jsonb_set(res, array[r.k], to_jsonb(greatest(0, r.s)));
  end loop;

  delete from inventory_reports where warehouse = p_warehouse and report_date = p_report_date;
  return res;
end;
$$;

-- 4) права
grant execute on function public.upsert_fact(text, text, text, jsonb) to anon, authenticated;
grant execute on function public.drain_fact(text, text) to anon, authenticated;
