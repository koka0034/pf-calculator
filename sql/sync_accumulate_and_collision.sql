-- ===========================================================================
-- Волна 6: накопление вкладов на сервере + защита от коллизий + ключ без даты
-- Запустить ЦЕЛИКОМ в Supabase -> SQL Editor. Применять ДО деплоя клиента.
-- ===========================================================================
--
-- НАЗВАНИЯ (историческое наследие, менять не нужно):
--   inventory_reports.warehouse = КОД СЕССИИ (напр. K7P4QM), НЕ склад.
--   sync_sessions.warehouse     = реальный склад-метка (напр. Бар) для бейджа.
-- Ключ синхронизации теперь: КОД СЕССИИ + УСТРОЙСТВО (без даты).
-- ---------------------------------------------------------------------------

-- 1) колонка устройства (если ещё нет)
alter table public.inventory_reports add column if not exists device_id text;

-- 2) чистим таблицу вкладов и меняем ключ уникальности на (сессия + устройство).
--    ВНИМАНИЕ: строки вкладов транзитны (стираются при приёмке), поэтому очищаем,
--    чтобы новый уникальный ключ без даты применился без конфликтов.
delete from public.inventory_reports;
alter table public.inventory_reports drop constraint if exists inventory_reports_warehouse_report_date_key;
alter table public.inventory_reports drop constraint if exists inventory_reports_wh_date_dev_key;
alter table public.inventory_reports drop constraint if exists inventory_reports_wh_dev_key;
alter table public.inventory_reports add constraint inventory_reports_wh_dev_key unique (warehouse, device_id);

-- 3) убираем старые версии функций с параметром даты (иначе перегрузка станет неоднозначной)
drop function if exists public.accumulate_fact(text, text, text, jsonb);
drop function if exists public.upsert_fact(text, text, text, jsonb);
drop function if exists public.drain_fact(text, text);
drop function if exists public.clear_fact(text, text);

-- 4) НАКОПЛЕНИЕ: суммирует новый вклад устройства с уже лежащим на сервере
create or replace function public.accumulate_fact(p_warehouse text, p_device_id text, p_fact jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  existing jsonb;
  merged   jsonb;
  rec      record;
begin
  select fact into existing
  from inventory_reports
  where warehouse = p_warehouse and device_id = p_device_id;

  if not found then
    insert into inventory_reports (warehouse, device_id, fact)
    values (p_warehouse, p_device_id, coalesce(p_fact, '{}'::jsonb))
    on conflict (warehouse, device_id) do update set fact = excluded.fact;
    return;
  end if;

  merged := coalesce(existing, '{}'::jsonb);
  for rec in select key as k, value::numeric as v
             from jsonb_each_text(coalesce(p_fact, '{}'::jsonb))
  loop
    merged := jsonb_set(
      merged,
      array[rec.k],
      to_jsonb( coalesce((merged->>rec.k)::numeric, 0) + rec.v )
    );
  end loop;

  update inventory_reports set fact = merged
  where warehouse = p_warehouse and device_id = p_device_id;
end;
$$;
grant execute on function public.accumulate_fact(text, text, jsonb) to anon, authenticated;

-- 5) ПРИЁМ: суммирует вклады всех устройств по сессии, очищает сервер, возвращает сумму
create or replace function public.drain_fact(p_warehouse text)
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
    where warehouse = p_warehouse
    group by kv.key
  loop
    res := jsonb_set(res, array[r.k], to_jsonb(greatest(0, r.s)));
  end loop;

  delete from inventory_reports where warehouse = p_warehouse;
  return res;
end;
$$;
grant execute on function public.drain_fact(text) to anon, authenticated;

-- 6) СБРОС: удаляет вклады сессии без приёма, возвращает число удалённых строк
create or replace function public.clear_fact(p_warehouse text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  delete from inventory_reports where warehouse = p_warehouse;
  get diagnostics n = row_count;
  return n;
end;
$$;
grant execute on function public.clear_fact(text) to anon, authenticated;

-- 7) ЗАЩИТА ОТ КОЛЛИЗИЙ: код сессии не перезаписывается, если уже занят.
--    При занятом коде возвращает {"error":"code_taken"} — клиент подберёт другой код.
create or replace function public.create_session(p_code text, p_warehouse text, p_report_date text, p_device_id text, p_dict jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into sync_sessions(code, warehouse, report_date, device_id, dict)
  values (upper(trim(p_code)), p_warehouse, p_report_date, p_device_id, coalesce(p_dict, '[]'::jsonb));
  return jsonb_build_object('code', upper(trim(p_code)), 'warehouse', p_warehouse, 'report_date', p_report_date);
exception when unique_violation then
  return jsonb_build_object('error', 'code_taken');
end;
$$;
grant execute on function public.create_session(text, text, text, text, jsonb) to anon, authenticated;
