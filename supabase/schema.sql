-- Схема базы «Ю Кофе» для Supabase.
-- Выполнить целиком один раз в SQL Editor нового проекта.
--
-- Модель прав:
--   admin@u-coffee.app   — управляющий: правит график, сотрудников, видит логи
--   barista@u-coffee.app — общий аккаунт баристов: правит только свои пожелания
--   аноним               — только чтение (чтобы график открывался без входа)

-- ---------------------------------------------------------------- таблицы --

create table if not exists public.baristas (
  id       bigint generated always as identity primary key,
  name     text not null unique,
  position int  not null default 0
);

create table if not exists public.shifts (
  date    date     not null,
  barista text     not null,
  type    smallint not null check (type between 1 and 3), -- 1=полная 2=утро 3=вечер
  primary key (date, barista)
);

create table if not exists public.prefs (
  date    date     not null,
  barista text     not null,
  type    smallint not null check (type between 1 and 4), -- 1=готов 2=после15 3=до15 4=не готов
  primary key (date, barista)
);

create table if not exists public.logs (
  id         bigint generated always as identity primary key,
  text       text        not null,
  created_at timestamptz not null default now()
);

create index if not exists logs_created_at_idx on public.logs (created_at desc);

-- ------------------------------------------------------------------- RLS --

alter table public.baristas enable row level security;
alter table public.shifts   enable row level security;
alter table public.prefs    enable row level security;
alter table public.logs     enable row level security;

-- Кто такой управляющий — одной функцией, чтобы не дублировать условие.
create or replace function public.is_admin() returns boolean
language sql stable
as $$
  select coalesce(auth.jwt() ->> 'email', '') = 'admin@u-coffee.app';
$$;

-- Читать может кто угодно: график должен открываться без входа.
drop policy if exists baristas_read on public.baristas;
drop policy if exists shifts_read   on public.shifts;
drop policy if exists prefs_read    on public.prefs;
drop policy if exists logs_read     on public.logs;

create policy baristas_read on public.baristas for select using (true);
create policy shifts_read   on public.shifts   for select using (true);
create policy prefs_read    on public.prefs    for select using (true);
create policy logs_read     on public.logs     for select using (true);

-- Писать график, сотрудников и логи — только управляющий.
drop policy if exists baristas_write on public.baristas;
drop policy if exists shifts_write   on public.shifts;
drop policy if exists logs_write     on public.logs;

create policy baristas_write on public.baristas for all
  using (public.is_admin()) with check (public.is_admin());
create policy shifts_write on public.shifts for all
  using (public.is_admin()) with check (public.is_admin());
create policy logs_write on public.logs for all
  using (public.is_admin()) with check (public.is_admin());

-- Пожелания пишет любой вошедший — то есть баристы под общим PIN.
-- Анониму запись закрыта: в старой базе она была открыта всему интернету.
drop policy if exists prefs_write on public.prefs;
create policy prefs_write on public.prefs for all
  to authenticated using (true) with check (true);

-- -------------------------------------------------------------- realtime --

alter publication supabase_realtime add table public.baristas;
alter publication supabase_realtime add table public.shifts;
alter publication supabase_realtime add table public.prefs;
alter publication supabase_realtime add table public.logs;

-- ------------------------------------------------------------ сотрудники --

insert into public.baristas (name, position) values
  ('Юрий', 0), ('Валерия', 1), ('Дарьяна', 2), ('Анастасия', 3)
on conflict (name) do nothing;
