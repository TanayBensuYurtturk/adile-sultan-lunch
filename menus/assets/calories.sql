/* @bruin

name: lunch.calories
type: bq.sql

description: |
  Approximate per-portion calories for each dish (mains and sides) available today, derived from
  lunch.menus. The ordering site publishes no calorie data, so this is a keyword-based estimate:
  a protein component + a carb component for composed mains, or a single representative value for
  legume/veg mains, soups, salads, desserts and drinks. Values are rounded and clearly approximate.
  Bot 1 reads this table to show ~kcal per composed menu (main + side) — no runtime web lookups.

depends:
  - lunch.menus

materialization:
  type: table
  # Full rebuild each run for the current day's dishes.
  strategy: create+replace

columns:
  - name: menu_date
    type: date
    checks:
      - name: not_null
  - name: dish
    type: string
    description: "Dish name (matches lunch.menus.option_name)."
    checks:
      - name: not_null
  - name: group_name
    type: string
    description: "Ana Yemek Seçimi (main) or Yan Ürün Seçimi (side)."
  - name: approx_calories
    type: integer
    description: "Approximate per-portion calories (keyword-based estimate, not from the site)."
    checks:
      - name: not_null

@bruin */

WITH dishes AS (
  SELECT DISTINCT option_name AS dish, group_name
  FROM `bruin-playground-bensu.lunch.menus`
  WHERE menu_date = (SELECT MAX(menu_date) FROM `bruin-playground-bensu.lunch.menus`)
    AND is_available = TRUE
    AND group_name IN ('Ana Yemek Seçimi', 'Yan Ürün Seçimi')
),
scored AS (
  SELECT
    dish,
    group_name,
    LOWER(dish) AS n,
    -- Protein component (for composed mains like "Dana Kavurma ve Pirinç Pilavı").
    CASE
      WHEN REGEXP_CONTAINS(LOWER(dish), r'kuzu|tandır')                 THEN 400
      WHEN REGEXP_CONTAINS(LOWER(dish), r'dana|\bet\b|kavurma|kebab|orman|bonfile') THEN 350
      WHEN REGEXP_CONTAINS(LOWER(dish), r'köfte|kıyma')                 THEN 300
      WHEN REGEXP_CONTAINS(LOWER(dish), r'tavuk|hindi')                 THEN 260
      ELSE 0
    END AS protein_kcal,
    -- Carb component.
    CASE
      WHEN REGEXP_CONTAINS(LOWER(dish), r'lazanya')                     THEN 420
      WHEN REGEXP_CONTAINS(LOWER(dish), r'mantı')                       THEN 480
      WHEN REGEXP_CONTAINS(LOWER(dish), r'makarna|penne|spagetti')      THEN 380
      WHEN REGEXP_CONTAINS(LOWER(dish), r'pirinç pilav|iç pilav|şehriye|basmati|nohutlu pirinç') THEN 300
      WHEN REGEXP_CONTAINS(LOWER(dish), r'bulgur')                      THEN 240
      WHEN REGEXP_CONTAINS(LOWER(dish), r'patates püres|püre|patates')  THEN 250
      ELSE 0
    END AS carb_kcal,
    -- Standalone value (legume/veg mains, soups, salads, desserts, drinks, börek, etc.).
    CASE
      WHEN REGEXP_CONTAINS(LOWER(dish), r'kuru fasulye|fasulye')        THEN 350
      WHEN REGEXP_CONTAINS(LOWER(dish), r'nohut')                       THEN 300
      WHEN REGEXP_CONTAINS(LOWER(dish), r'mercimek')                    THEN 280
      WHEN REGEXP_CONTAINS(LOWER(dish), r'musakka|karnıyarık')          THEN 280
      WHEN REGEXP_CONTAINS(LOWER(dish), r'dolma|sarma')                 THEN 260
      WHEN REGEXP_CONTAINS(LOWER(dish), r'börek|mücver')                THEN 320
      WHEN REGEXP_CONTAINS(LOWER(dish), r'kadayıf|sütlaç|revani|baklava|kek|pasta|tart|kurabiye|bomba|aşure|kompost|tatlı|kakao') THEN 350
      WHEN REGEXP_CONTAINS(LOWER(dish), r'çorba')                       THEN 150
      WHEN REGEXP_CONTAINS(LOWER(dish), r'humus')                       THEN 200
      WHEN REGEXP_CONTAINS(LOWER(dish), r'cacık|yoğurt|ayran')          THEN 100
      WHEN REGEXP_CONTAINS(LOWER(dish), r'gazoz|kola|meşrubat')         THEN 90
      WHEN REGEXP_CONTAINS(LOWER(dish), r'salata|turşu|ıspanak|sebze|kabak|bezelye|mantar') THEN 150
      ELSE 0
    END AS standalone_kcal
  FROM dishes
)
SELECT
  (SELECT MAX(menu_date) FROM `bruin-playground-bensu.lunch.menus`) AS menu_date,
  dish,
  group_name,
  CASE
    WHEN protein_kcal + carb_kcal > 0 THEN protein_kcal + carb_kcal
    WHEN standalone_kcal > 0          THEN standalone_kcal
    ELSE 300  -- sensible default for anything unmatched
  END AS approx_calories
FROM scored
ORDER BY group_name, dish
