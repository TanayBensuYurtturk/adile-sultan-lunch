# Bot 1 — "Compose daily menus" creator

## What this bot does
Every morning, after the `adile-sultan-menus` pipeline has refreshed `lunch.menus`, this bot:

1. reads today's available menus and their **free** options from BigQuery (Kadıköy Fikirtepe branch),
2. **randomly composes one complete menu per menu type** (a random main + a random side),
3. **prepares the result** — the day's menu choices, with the general menu (Chef's Choice) marked as
   the default — and writes it into `lunch.votes`.

**Capabilities it needs:** BigQuery read + insert (connection `gcp-default`).

---

## Step 1 — read today's menus (BigQuery, `gcp-default`)

```sql
SELECT
  menu_slug,
  menu_name,
  group_name,     -- 'Ana Yemek Seçimi' (main) or 'Yan Ürün Seçimi' (side)
  option_id,
  option_name
FROM `bruin-playground-bensu.lunch.menus`
WHERE menu_date = CURRENT_DATE()
  AND is_available = TRUE
  AND group_name IN ('Ana Yemek Seçimi', 'Yan Ürün Seçimi');
```

Every row here is a **free** option (paid options and bread are already excluded upstream).

### Menu types
Map `menu_slug` to a friendly type + emoji:

| menu_slug | type | emoji |
|---|---|---|
| `tavuklu-yemek-menu` | Chicken | 🍗 |
| `etli-yemek-menu` | Meat | 🥩 |
| `etli-sebzeli-yemek-menu` | Meat & Veggie | 🥘 |
| `sebzeli-yemek-menu` | Vegetarian | 🥬 |
| `dusuk-kalorili-fit-menu` | Light / Fit | 🥗 |
| `pilav-ustu-menu` | Rice Bowl | 🍚 |
| `online-ozel-menu` | Chef's Choice | 👨‍🍳 |

---

## Step 2 — compose one menu per type (randomly)

For each available menu type:
- pick **one random** option from `Ana Yemek Seçimi` → `main`
- pick **one random** option from `Yan Ürün Seçimi` → `side`
- assign a 1-based `index` and build a label: `"{index}. {emoji} {type} — {main} + {side}"`

Because the picks are random, the featured combo changes day to day. Result: ~6 composed menus.
Keep each menu's `menu_slug`, `main`/`side` (name + option_id) so votes tie back to real dishes.

**Mark the general menu as default:** flag the Chef's Choice (`online-ozel-menu`) entry with
`"default": true` — this is the fallback when nobody votes. (If `online-ozel-menu` isn't available
that day, mark the first composed menu as default instead.)

Example composed set:
```json
[
  {"index":1,"emoji":"👨‍🍳","type":"Chef's Choice","menu_slug":"online-ozel-menu","default":true,
   "main":"Etli Yaprak Sarma","side":"Karışık Turşu",
   "label":"1. 👨‍🍳 Chef's Choice — Etli Yaprak Sarma + Karışık Turşu"},
  {"index":2,"emoji":"🍗","type":"Chicken","menu_slug":"tavuklu-yemek-menu",
   "main":"Mangalda Tavuk ve Pirinç Pilavı","side":"Arpa Şehriye Pilavı",
   "label":"2. 🍗 Chicken — Mangalda Tavuk ve Pirinç Pilavı + Arpa Şehriye Pilavı"}
]
```

---

## Step 3 — write the result to `lunch.votes`

First make sure the table exists (idempotent — safe to run every day, and means the bot doesn't
depend on the `votes` Bruin pipeline having run first):

```sql
CREATE TABLE IF NOT EXISTS `bruin-playground-bensu.lunch.votes` (
  created_at TIMESTAMP,
  menu_date  DATE,
  channel_id STRING,
  message_ts STRING,
  menus      JSON,
  responses  JSON,
  tally      JSON,
  summary    STRING,
  updated_at TIMESTAMP
);
```

Then insert one row with the composed menus (this is the only writer of `menus`):

```sql
INSERT INTO `bruin-playground-bensu.lunch.votes`
  (created_at, menu_date, menus)
VALUES (
  CURRENT_TIMESTAMP(),
  CURRENT_DATE(),
  JSON '[ ... the composed menus from step 2 ... ]'
);
```

That's it — the day's menu choices are now prepared in `lunch.votes` (latest `created_at` = today).
