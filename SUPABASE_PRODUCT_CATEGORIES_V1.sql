-- MarketLink DZ: dynamic product categories
-- Run this migration once in Supabase SQL Editor.
create table if not exists public.product_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  icon text not null default '📦',
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create unique index if not exists product_categories_name_lower_unique
  on public.product_categories (lower(name));

alter table public.products add column if not exists category text;

alter table public.product_categories enable row level security;

drop policy if exists "Authenticated users can view active product categories" on public.product_categories;
create policy "Authenticated users can view active product categories"
  on public.product_categories for select to authenticated
  using (auth.uid() is not null);

drop policy if exists "Admins can insert product categories" on public.product_categories;
create policy "Admins can insert product categories"
  on public.product_categories for insert to authenticated
  with check (exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  ));

drop policy if exists "Admins can update product categories" on public.product_categories;
create policy "Admins can update product categories"
  on public.product_categories for update to authenticated
  using (exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  ))
  with check (exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  ));

drop policy if exists "Admins can delete product categories" on public.product_categories;
create policy "Admins can delete product categories"
  on public.product_categories for delete to authenticated
  using (exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  ));

grant select, insert, update, delete on public.product_categories to authenticated;

insert into public.product_categories (name, icon, sort_order, active)
values
  ('ملابس', '👕', 10, true),
  ('أحذية', '👟', 20, true),
  ('إكسسوارات', '👜', 30, true),
  ('منزلية', '🏠', 40, true),
  ('أخرى', '📦', 90, true)
on conflict do nothing;

-- Existing products keep their data. Categorize them from the admin interface or
-- update category manually; the UI has a name/description fallback for legacy items.
