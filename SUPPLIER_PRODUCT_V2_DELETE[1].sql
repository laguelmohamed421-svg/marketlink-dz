-- MarketLink DZ — Supplier Product V2
-- Run this in Supabase SQL Editor.

alter table public.products
  add column if not exists description text,
  add column if not exists stock_quantity integer not null default 0,
  add column if not exists min_order_quantity integer not null default 1,
  add column if not exists delivery_company text,
  add column if not exists image_urls jsonb not null default '[]'::jsonb;

alter table public.products
  drop constraint if exists products_stock_quantity_check;
alter table public.products
  add constraint products_stock_quantity_check check (stock_quantity >= 0);

alter table public.products
  drop constraint if exists products_min_order_quantity_check;
alter table public.products
  add constraint products_min_order_quantity_check check (min_order_quantity >= 1);

-- Storage bucket for product images.
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do update set public = true;

-- Suppliers can upload/update/delete only files inside their own folder: supplier UUID/filename.
drop policy if exists "suppliers upload product images" on storage.objects;
create policy "suppliers upload product images"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'product-images'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "suppliers update product images" on storage.objects;
create policy "suppliers update product images"
on storage.objects for update to authenticated
using (
  bucket_id = 'product-images'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'product-images'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "suppliers delete product images" on storage.objects;
create policy "suppliers delete product images"
on storage.objects for delete to authenticated
using (
  bucket_id = 'product-images'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- Public read is intentional: product photos must be visible to marketers.
drop policy if exists "public read product images" on storage.objects;
create policy "public read product images"
on storage.objects for select
using (bucket_id = 'product-images');

-- Product ownership: suppliers create/update their own products.
drop policy if exists "suppliers can insert own products" on public.products;
create policy "suppliers can insert own products"
on public.products for insert to authenticated
with check (
  auth.uid() = supplier_id
  and exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'supplier'
  )
);

drop policy if exists "suppliers can update own products" on public.products;
create policy "suppliers can update own products"
on public.products for update to authenticated
using (
  auth.uid() = supplier_id
  and exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'supplier'
  )
)
with check (
  auth.uid() = supplier_id
  and exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'supplier'
  )
);

-- Minimum order is measured in series. One series = 6 pieces.
alter table public.products
  add column if not exists min_order_series integer not null default 1;

update public.products
set min_order_series = greatest(1, coalesce(min_order_quantity, 1))
where min_order_series = 1;

alter table public.products
  drop constraint if exists products_min_order_series_check;
alter table public.products
  add constraint products_min_order_series_check check (min_order_series >= 1);

-- Suppliers can delete only their own products.
-- Deletion is still blocked by the orders FK when the product has existing orders.
drop policy if exists "suppliers can delete own products" on public.products;

create policy "suppliers can delete own products"
on public.products for delete to authenticated
using (
  auth.uid() = supplier_id
  and exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'supplier'
  )
);


-- =========================================================
-- Supplier Credit Limit — 3 Delivered -> first full settlement -> 10
-- =========================================================
alter table public.supplier_billing
  add column if not exists delivered_orders integer not null default 0,
  add column if not exists credit_limit integer not null default 3,
  add column if not exists outstanding_dzd numeric(12,2) not null default 0,
  add column if not exists blocked boolean not null default false,
  add column if not exists updated_at timestamptz not null default now();

alter table public.supplier_billing drop constraint if exists supplier_billing_credit_limit_check;
alter table public.supplier_billing add constraint supplier_billing_credit_limit_check check (credit_limit in (3,10));
alter table public.supplier_billing drop constraint if exists supplier_billing_delivered_orders_check;
alter table public.supplier_billing add constraint supplier_billing_delivered_orders_check check (delivered_orders >= 0);
alter table public.supplier_billing drop constraint if exists supplier_billing_outstanding_check;
alter table public.supplier_billing add constraint supplier_billing_outstanding_check check (outstanding_dzd >= 0);

update public.supplier_billing b
set delivered_orders = coalesce((select count(*) from public.orders o where o.supplier_id=b.supplier_id and o.status='delivered'),0),
    updated_at=now();

-- Make sure every supplier has a billing row.
insert into public.supplier_billing(supplier_id,delivered_orders,credit_limit,outstanding_dzd,blocked,updated_at)
select p.id,0,3,0,false,now()
from public.profiles p
where p.role='supplier'
and not exists(select 1 from public.supplier_billing b where b.supplier_id=p.id);

-- Protect order creation at database level: blocked suppliers cannot receive new orders.
create or replace function public.set_order_pricing()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare p record; mp record; b record; min_units integer;
begin
  select id,supplier_id,wholesale_price,active,stock_quantity,min_order_series into p from public.products where id=new.product_id for update;
  if not found or not p.active then raise exception 'Product is not available'; end if;
  if new.supplier_id<>p.supplier_id then raise exception 'Supplier does not match product'; end if;
  select * into b from public.supplier_billing where supplier_id=p.supplier_id for update;
  if b.blocked or coalesce(b.delivered_orders,0)>=coalesce(b.credit_limit,3) then raise exception 'Supplier credit limit reached. Settlement is required before new orders.'; end if;
  if new.marketer_id is null then raise exception 'Marketer is required'; end if;
  select marketer_commission,platform_commission,active into mp from public.marketer_products where marketer_id=new.marketer_id and product_id=new.product_id for update;
  if not found or not mp.active then raise exception 'Marketer must add this product and activate it first'; end if;
  if mp.marketer_commission<0 or mp.marketer_commission>100 then raise exception 'Marketer commission must be between 0 and 100 DZD'; end if;
  if mp.platform_commission<>50 then raise exception 'Platform commission must be 50 DZD'; end if;
  if new.quantity<=0 or mod(new.quantity,6)<>0 then raise exception 'Order quantity must be a multiple of 6 because 1 series = 6 pieces'; end if;
  min_units=greatest(1,coalesce(p.min_order_series,3))*6;
  if new.quantity<min_units then raise exception 'Order is below the supplier minimum order'; end if;
  if new.quantity>coalesce(p.stock_quantity,0) then raise exception 'Not enough stock'; end if;
  new.wholesale_price_snapshot=p.wholesale_price; new.marketer_commission=mp.marketer_commission; new.platform_commission=50;
  update public.products set stock_quantity=stock_quantity-new.quantity where id=p.id and stock_quantity>=new.quantity;
  if not found then raise exception 'Not enough stock'; end if;
  return new;
end; $$;

drop trigger if exists set_order_pricing_trigger on public.orders;
create trigger set_order_pricing_trigger before insert on public.orders for each row execute procedure public.set_order_pricing();

-- Fix Delivered billing for both UPDATE and direct INSERT without referencing OLD on INSERT.
create or replace function public.apply_delivered_commission()
returns trigger language plpgsql security definer set search_path=public as $$
declare should_apply boolean:=false;
begin
  if TG_OP='INSERT' then should_apply := (new.status='delivered');
  else should_apply := (new.status='delivered' and coalesce(old.status,'')<>'delivered'); end if;
  if should_apply then
    insert into public.supplier_billing(supplier_id) values(new.supplier_id) on conflict(supplier_id) do nothing;
    update public.supplier_billing
      set outstanding_dzd=outstanding_dzd+(new.quantity*50),
          delivered_units=delivered_units+new.quantity,
          delivered_orders=delivered_orders+1,
          blocked=(delivered_orders+1)>=credit_limit,
          updated_at=now()
      where supplier_id=new.supplier_id;
  end if;
  return new;
end; $$;

drop trigger if exists apply_delivered_commission_trigger on public.orders;
create trigger apply_delivered_commission_trigger after update of status on public.orders for each row execute procedure public.apply_delivered_commission();
drop trigger if exists apply_delivered_commission_insert_trigger on public.orders;
create trigger apply_delivered_commission_insert_trigger after insert on public.orders for each row execute procedure public.apply_delivered_commission();

-- Safe product deletion: an ordered product cannot be deleted; hide it instead.
alter table public.orders drop constraint if exists orders_product_id_fkey;
alter table public.orders add constraint orders_product_id_fkey foreign key(product_id) references public.products(id) on delete restrict;

alter table public.supplier_billing enable row level security;
drop policy if exists "suppliers can view own billing" on public.supplier_billing;
create policy "suppliers can view own billing" on public.supplier_billing for select to authenticated using(auth.uid()=supplier_id or public.is_admin(auth.uid()));

-- ============================================================
-- MarketLink DZ — Shipping Receipt + Tracking V6
-- Supplier uploads courier receipt; marketer can view it.
-- ============================================================

alter table public.orders
  add column if not exists shipping_company text,
  add column if not exists tracking_number text,
  add column if not exists shipping_receipt_url text,
  add column if not exists shipped_at timestamptz;

-- Storage bucket for courier receipts.
insert into storage.buckets (id, name, public)
values ('shipping-receipts', 'shipping-receipts', true)
on conflict (id) do update set public = true;

-- Supplier can upload only inside their own UUID folder.
drop policy if exists "suppliers upload shipping receipts" on storage.objects;
create policy "suppliers upload shipping receipts"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'shipping-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
  and exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'supplier'
  )
);

-- Supplier can replace/delete only their own receipt files.
drop policy if exists "suppliers update shipping receipts" on storage.objects;
create policy "suppliers update shipping receipts"
on storage.objects for update to authenticated
using (
  bucket_id = 'shipping-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'shipping-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "suppliers delete shipping receipts" on storage.objects;
create policy "suppliers delete shipping receipts"
on storage.objects for delete to authenticated
using (
  bucket_id = 'shipping-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- Receipts are public-read because the URL is shared with the marketer.
-- The actual URL is not displayed publicly unless the order owner receives it.
drop policy if exists "public read shipping receipts" on storage.objects;
create policy "public read shipping receipts"
on storage.objects for select
using (bucket_id = 'shipping-receipts');

-- Suppliers may update shipping information only for their own orders.
drop policy if exists "orders supplier update shipping" on public.orders;
create policy "orders supplier update shipping"
on public.orders
for update to authenticated
using (
  auth.uid() = supplier_id
  and exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'supplier'
  )
)
with check (
  auth.uid() = supplier_id
  and exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'supplier'
  )
);

-- Helpful index for tracking lookup.
create index if not exists orders_tracking_number_idx
on public.orders(tracking_number)
where tracking_number is not null;



-- ============================================================
-- MarketLink DZ V9 — Admin Order Control
-- Admin is the only party allowed to confirm Delivered/Returned.
-- Supplier only provides shipping information.
-- ============================================================

alter table public.orders
  add column if not exists shipping_company text,
  add column if not exists tracking_number text,
  add column if not exists shipping_receipt_url text,
  add column if not exists shipped_at timestamptz;

-- Shipping receipt storage.
insert into storage.buckets (id, name, public)
values ('shipping-receipts', 'shipping-receipts', true)
on conflict (id) do update set public = true;

drop policy if exists "suppliers upload shipping receipts" on storage.objects;
create policy "suppliers upload shipping receipts"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'shipping-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "suppliers update shipping receipts" on storage.objects;
create policy "suppliers update shipping receipts"
on storage.objects for update to authenticated
using (
  bucket_id = 'shipping-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'shipping-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "suppliers delete shipping receipts" on storage.objects;
create policy "suppliers delete shipping receipts"
on storage.objects for delete to authenticated
using (
  bucket_id = 'shipping-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "public read shipping receipts" on storage.objects;
create policy "public read shipping receipts"
on storage.objects for select
using (bucket_id = 'shipping-receipts');

-- Secure admin-only status transition.
create or replace function public.admin_set_order_status(
  p_order_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_ok boolean;
  old_status text;
begin
  select exists(
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  ) into admin_ok;

  if not admin_ok then
    raise exception 'Admin only';
  end if;

  if p_status not in ('delivered','returned','cancelled') then
    raise exception 'Invalid admin status';
  end if;

  select status into old_status
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found';
  end if;

  if old_status = 'delivered' and p_status <> 'delivered' then
    raise exception 'Delivered order cannot be changed by this action';
  end if;

  update public.orders
  set status = p_status,
      delivered_at = case
        when p_status = 'delivered' then coalesce(delivered_at, now())
        else delivered_at
      end
  where id = p_order_id;
end;
$$;

revoke all on function public.admin_set_order_status(uuid,text) from public;
grant execute on function public.admin_set_order_status(uuid,text) to authenticated;

-- IMPORTANT:
-- Existing delivered triggers from V7/V8 remain responsible for commission/billing.
-- The Admin function changes the order status normally so those triggers fire.
-- Supplier order updates are restricted below: suppliers may update shipping
-- information/status to shipping, but cannot set Delivered/Returned.

drop policy if exists "orders supplier update" on public.orders;
create policy "orders supplier update" on public.orders
for update to authenticated
using (
  auth.uid() = supplier_id
  or public.is_admin(auth.uid())
)
with check (
  public.is_admin(auth.uid())
  or (
    auth.uid() = supplier_id
    and status in ('pending','shipping')
  )
);

-- Admin can update all orders.
drop policy if exists "orders admin update" on public.orders;
create policy "orders admin update" on public.orders
for update to authenticated
using (public.is_admin(auth.uid()))
with check (public.is_admin(auth.uid()));

-- ============================================================
-- Recommended trigger hardening:
-- supplier can move pending -> shipping, but cannot self-confirm
-- delivered/returned through the UI.
-- ============================================================
create or replace function public.guard_supplier_order_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() = old.supplier_id
     and not public.is_admin(auth.uid()) then

    if new.status not in ('pending','shipping') then
      raise exception 'Supplier cannot confirm Delivered or Returned. Admin confirmation is required.';
    end if;

    if old.status = 'shipping' and new.status = 'pending' then
      raise exception 'Shipping order cannot be moved back to pending.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists guard_supplier_order_status_trigger on public.orders;
create trigger guard_supplier_order_status_trigger
before update on public.orders
for each row
execute procedure public.guard_supplier_order_status();

-- ============================================================
-- V9 note:
-- Commission is earned only when status becomes Delivered.
-- The existing V7 delivered trigger should be idempotent in production.
-- ============================================================


-- ============================================================
-- MarketLink DZ V10 — Return / Retour workflow
-- Admin records the final return. Supplier cannot confirm it.
-- ============================================================

alter table public.orders
  add column if not exists return_reason text,
  add column if not exists returned_at timestamptz;

create index if not exists orders_returned_idx
on public.orders(status, returned_at desc);

-- Admin-only final return confirmation.
create or replace function public.admin_set_order_returned(
  p_order_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_ok boolean;
  old_status text;
begin
  select exists(
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  ) into admin_ok;

  if not admin_ok then
    raise exception 'Admin only';
  end if;

  select status into old_status
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found';
  end if;

  if old_status = 'delivered' then
    raise exception 'Delivered order cannot be marked as returned from this action';
  end if;

  update public.orders
  set status='returned',
      return_reason=p_reason,
      returned_at=coalesce(returned_at, now())
  where id=p_order_id;
end;
$$;

revoke all on function public.admin_set_order_returned(uuid,text) from public;
grant execute on function public.admin_set_order_returned(uuid,text) to authenticated;

-- Returned orders are visible to their marketer, supplier and admin.
-- No commission is earned by a returned order.
