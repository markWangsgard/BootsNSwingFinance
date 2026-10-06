-- Non-destructive migration from the legacy records(id, kind, data) table.
-- Run this once in the Supabase SQL editor. The legacy table is intentionally kept
-- so the old data remains available as a rollback and backup source.
create table if not exists public.accounts (
  id text primary key,
  name text not null,
  kind text not null check (kind in ('debit', 'credit'))
);

create table if not exists public.events (
  id text primary key,
  name text not null,
  date date not null
);

create table if not exists public.categories (
  name text primary key
);

create table if not exists public.transactions (
  id text primary key,
  type text not null check (type in ('income', 'expense', 'payment')),
  date date not null,
  amt numeric(12, 2) not null,
  acct text not null references public.accounts(id),
  to_account text references public.accounts(id),
  vendor text not null default '',
  loc text not null default '',
  cat text not null default '',
  event_id text references public.events(id),
  note text not null default '',
  receipt_id text
);

-- INSERT ... ON CONFLICT makes this safe to run more than once.
insert into public.accounts (id, name, kind)
select data->>'id', data->>'name', data->>'kind'
from public.records
where kind = 'acc'
on conflict (id) do nothing;

insert into public.events (id, name, date)
select data->>'id', coalesce(data->>'name', 'Event'), (data->>'date')::date
from public.records
where kind = 'ev'
on conflict (id) do nothing;

insert into public.categories (name)
select value
from public.records r
cross join lateral jsonb_array_elements_text(r.data->'list') as values(value)
where r.kind = 'cfg' and r.id = 'cfg:cats'
on conflict (name) do nothing;

insert into public.transactions
  (id, type, date, amt, acct, to_account, vendor, loc, cat, event_id, note, receipt_id)
select
  data->>'id',
  data->>'type',
  (data->>'date')::date,
  (data->>'amt')::numeric,
  data->>'acct',
  nullif(data->>'to', ''),
  coalesce(data->>'vendor', ''),
  coalesce(data->>'loc', ''),
  coalesce(data->>'cat', ''),
  nullif(data->>'ev', ''),
  coalesce(data->>'note', ''),
  nullif(data->>'rid', '')
from public.records
where kind = 'tx'
on conflict (id) do nothing;

-- The app is intentionally shared between authenticated users, matching the
-- existing records table behavior described in the UI.
alter table public.accounts enable row level security;
alter table public.events enable row level security;
alter table public.categories enable row level security;
alter table public.transactions enable row level security;

do $$
declare
  table_name text;
begin
  foreach table_name in array array['accounts', 'events', 'categories', 'transactions'] loop
    execute format('drop policy if exists ledger_authenticated_all on public.%I', table_name);
    execute format('create policy ledger_authenticated_all on public.%I for all to authenticated using (true) with check (true)', table_name);
  end loop;
end $$;
