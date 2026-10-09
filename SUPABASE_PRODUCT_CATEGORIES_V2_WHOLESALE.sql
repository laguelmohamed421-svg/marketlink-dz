-- MarketLink DZ: expand wholesale product categories to 12
-- Safe to run in Supabase SQL Editor. Existing products and category names are preserved.
-- Existing broad categories are kept to avoid breaking products already assigned to them.

insert into public.product_categories (name, icon, sort_order, active)
values
  ('ملابس', '👕', 10, true),
  ('أحذية', '👟', 20, true),
  ('إكسسوارات', '👜', 30, true),
  ('منزلية', '🏠', 40, true),
  ('مواد التجميل والعناية الشخصية', '💄', 50, true),
  ('الهواتف والإكسسوارات الإلكترونية', '📱', 60, true),
  ('منتجات الأطفال والرضّع', '🧸', 70, true),
  ('إكسسوارات السيارات', '🚗', 80, true),
  ('الرياضة واللياقة البدنية', '🏋️', 90, true),
  ('الأدوات المدرسية والمكتبية', '📚', 100, true),
  ('الأدوات واللوازم المهنية', '🧰', 110, true),
  ('أخرى', '📦', 120, true)
on conflict (lower(name)) do update
set icon = excluded.icon,
    sort_order = excluded.sort_order,
    active = true;

-- The existing supplier upload form and marketer category filters read from
-- product_categories, so these categories will appear there after this SQL runs.
