/* @bruin

name: lunch.daily_options
type: bq.sql

description: |
  The curated set of complete lunch menus the team votes on each day. The team picks a MENU,
  not individual options — so this asset composes one ready-to-eat menu per style (Chicken, Meat,
  Vegetarian, Light/Fit, Rice Bowl, Chef's Choice, Meat & Veggie) out of the raw options scraped
  into lunch.menus. For each available restaurant menu it selects a main dish that fits the style
  (preferring an on-theme dish) plus a side. The Google Form bot reads this table and lists `label`
  as the voting choices.

depends:
  - lunch.menus

materialization:
  type: table
  # Full rebuild each run: the table holds the current day's composed menus.
  # Per-day history is always recoverable from lunch.menus.
  strategy: create+replace

columns:
  - name: menu_date
    type: date
    checks:
      - name: not_null
  - name: choice_index
    type: integer
    description: "1-based order of this menu in the form."
  - name: category
    type: string
    description: "Friendly style label, e.g. Chicken, Meat, Vegetarian, Light / Fit."
  - name: emoji
    type: string
  - name: menu_slug
    type: string
  - name: menu_name
    type: string
  - name: menu_id
    type: integer
  - name: main_dish
    type: string
    description: "Chosen main dish for this menu."
  - name: main_option_id
    type: string
  - name: side_dish
    type: string
  - name: side_option_id
    type: string
  - name: total_price
    type: float64
    description: "Menu base price in TRY (all chosen dishes are free options)."
  - name: label
    type: string
    description: "Display string for the form choice."
    checks:
      - name: not_null

@bruin */

-- Meat / poultry keyword patterns used to keep vegetarian picks truly meat-free
-- and to steer meat/chicken picks toward on-theme dishes.
WITH src AS (
  SELECT *
  FROM `bruin-playground-bensu.lunch.menus`
  WHERE menu_date = (SELECT MAX(menu_date) FROM `bruin-playground-bensu.lunch.menus`)
    AND is_available = TRUE
    AND group_name IN ('Ana Yemek Seçimi', 'Yan Ürün Seçimi')
),
cat AS (
  SELECT
    *,
    CASE menu_slug
      WHEN 'tavuklu-yemek-menu'       THEN 'Chicken'
      WHEN 'etli-yemek-menu'          THEN 'Meat'
      WHEN 'etli-sebzeli-yemek-menu'  THEN 'Meat & Veggie'
      WHEN 'sebzeli-yemek-menu'       THEN 'Vegetarian'
      WHEN 'dusuk-kalorili-fit-menu'  THEN 'Light / Fit'
      WHEN 'pilav-ustu-menu'          THEN 'Rice Bowl'
      WHEN 'online-ozel-menu'         THEN "Chef's Choice"
      ELSE menu_name
    END AS category,
    CASE menu_slug
      WHEN 'tavuklu-yemek-menu'       THEN '🍗'
      WHEN 'etli-yemek-menu'          THEN '🥩'
      WHEN 'etli-sebzeli-yemek-menu'  THEN '🥘'
      WHEN 'sebzeli-yemek-menu'       THEN '🥬'
      WHEN 'dusuk-kalorili-fit-menu'  THEN '🥗'
      WHEN 'pilav-ustu-menu'          THEN '🍚'
      WHEN 'online-ozel-menu'         THEN '👨‍🍳'
      ELSE '🍽️'
    END AS emoji,
    -- is this option meat/poultry?
    REGEXP_CONTAINS(LOWER(option_name),
      r'tavuk|hindi|köfte|kebab|\bet\b|etli|dana|kuzu|kıyma|kavurma|sarma|bonfile|tandır') AS is_meaty
  FROM src
),
-- Pick the best option per (menu, group): on-theme first, then by name.
ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY menu_slug, group_name
      ORDER BY
        CASE
          WHEN group_name = 'Ana Yemek Seçimi' AND category = 'Chicken'
               AND LOWER(option_name) LIKE '%tavuk%' THEN 0
          WHEN group_name = 'Ana Yemek Seçimi' AND category = 'Vegetarian'
               AND NOT is_meaty THEN 0
          WHEN group_name = 'Ana Yemek Seçimi' AND category = 'Light / Fit'
               AND REGEXP_CONTAINS(LOWER(option_name), r'ızgara|buhar|haşlama|sebze') THEN 0
          WHEN group_name = 'Ana Yemek Seçimi' AND category IN ('Meat', 'Meat & Veggie')
               AND REGEXP_CONTAINS(LOWER(option_name), r'köfte|dana|kuzu|\bet\b|etli|kıyma|kebab') THEN 0
          -- prefer a real side (rice/bulgur/potato/pasta), not a drink or soup
          WHEN group_name = 'Yan Ürün Seçimi'
               AND NOT REGEXP_CONTAINS(LOWER(option_name),
                   r'gazoz|ayran|kola|soda|\bsu\b|çorba|çay|içecek|meşrubat|limonata|şalgam|şıra') THEN 0
          ELSE 1
        END,
        option_name
    ) AS rn
  FROM cat
),
picks AS (
  SELECT
    menu_date, menu_id, menu_slug, menu_name, category, emoji, menu_base_price,
    MAX(IF(group_name = 'Ana Yemek Seçimi', option_name, NULL)) AS main_dish,
    MAX(IF(group_name = 'Ana Yemek Seçimi', option_id, NULL))   AS main_option_id,
    MAX(IF(group_name = 'Yan Ürün Seçimi', option_name, NULL))  AS side_dish,
    MAX(IF(group_name = 'Yan Ürün Seçimi', option_id, NULL))    AS side_option_id
  FROM ranked
  WHERE rn = 1
  GROUP BY menu_date, menu_id, menu_slug, menu_name, category, emoji, menu_base_price
)
SELECT
  menu_date,
  ROW_NUMBER() OVER (ORDER BY category) AS choice_index,
  category,
  emoji,
  menu_slug,
  menu_name,
  menu_id,
  main_dish,
  main_option_id,
  side_dish,
  side_option_id,
  ROUND(menu_base_price, 2) AS total_price,
  FORMAT('%s %s — %s + %s', emoji, category, main_dish, side_dish) AS label
FROM picks
ORDER BY choice_index
