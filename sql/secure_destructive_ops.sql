-- Защита разрушительных операций синхронизации PIN-ом руководителя.
-- Идея: PIN хранится в БД в таблице, НЕ доступной роли anon, поэтому его нельзя
-- вытащить из публичного исходника калькулятора. Руководитель вводит PIN в момент
-- «Принять»/«Сбросить». Выгрузка (upsert_fact) остаётся открытой — её ущерб низкий.
--
-- Запустить целиком в Supabase SQL Editor. Идемпотентно.
-- ПЕРЕД запуском замените 'СМЕНИ_МЕНЯ' на реальный PIN руководителя.

-- 1) приватное хранилище секретов (anon не имеет прав select — ключ недоступен клиенту)
create table if not exists public.app_secrets (
  name  text primary key,
  value text not null
);
alter table public.app_secrets enable row level security;   -- по умолчанию всё запрещено
revoke all on public.app_secrets from anon, authenticated;   -- клиент не может читать напрямую

-- 2) задать/обновить PIN руководителя  ← ЗАМЕНИТЕ ЗНАЧЕНИЕ
insert into public.app_secrets(name, value)
values ('manager_pin', 'СМЕНИ_МЕНЯ')
on conflict (name) do update set value = excluded.value;

-- 3) helper: проверка PIN (SECURITY DEFINER читает app_secrets в обход RLS)
create or replace function public.check_pin(p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v text;
begin
  select value into v from app_secrets where name = 'manager_pin';
  -- если PIN в БД не задан — считаем защиту выключенной (обратная совместимость)
  if v is null then return true; end if;
  return p_pin is not null and p_pin = v;
end;
$$;

-- 4) ПРИЁМ (drain): теперь требует PIN. Параметр с default — старый вызов без PIN
--    корректно отклоняется, а не падает по «функция не найдена».
create or replace function public.drain_fact(p_warehouse text, p_report_date text, p_pin text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  res jsonb := '{}'::jsonb;
  r record;
begin
  if not check_pin(p_pin) then
    raise exception 'PIN_REQUIRED' using message = 'Неверный или отсутствующий PIN руководителя';
  end if;

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

-- 5) СБРОС (clear): тоже требует PIN
create or replace function public.clear_fact(p_warehouse text, p_report_date text, p_pin text default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  if not check_pin(p_pin) then
    raise exception 'PIN_REQUIRED' using message = 'Неверный или отсутствующий PIN руководителя';
  end if;

  delete from inventory_reports
  where warehouse = p_warehouse and report_date = p_report_date;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- 6) убрать СТАРЫЕ (без PIN) сигнатуры, чтобы их нельзя было позвать в обход защиты
drop function if exists public.drain_fact(text, text);
drop function if exists public.clear_fact(text, text);

-- 7) права
--   check_pin — только серверные функции (не выдаём клиенту, чтобы нельзя было брутить)
revoke all on function public.check_pin(text) from anon, authenticated;
grant execute on function public.drain_fact(text, text, text) to anon, authenticated;
grant execute on function public.clear_fact(text, text, text) to anon, authenticated;
-- upsert_fact оставляем как есть (открыт) — ущерб низкий, ломать частую выгрузку не нужно
