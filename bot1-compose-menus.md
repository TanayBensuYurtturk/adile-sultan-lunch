# Bot 1 — "Compose daily menus" creator

## What this bot does
Every morning, after the `adile-sultan-menus` pipeline has refreshed `lunch.menus`, this bot:

1. reads today's available menus and their options (free **and** paid, with prices) from BigQuery
   (Kadıköy Fikirtepe branch),
2. **randomly composes one complete menu per menu type** (a random main + a random side), with the
   total price, an approximate calorie estimate **looked up from the internet**, and a link to the
   menu so people can customize,
3. **prepares the result** — the day's menu choices, with the general menu (Chef's Choice) marked as
   the default — writes it into `lunch.votes`, and produces a friendly announcement.

**Capabilities it needs:** BigQuery read + insert (connection `gcp-default`), and web search access
(to estimate dish calories).

---

## Step 1 — read today's menus (BigQuery, `gcp-default`)

```sql
SELECT
  menu_slug,
  menu_name,
  menu_base_price,      -- base price of the menu in TRY
  menu_url,             -- link to the menu's page (so users can open it and pick their own options)
  group_name,           -- 'Ana Yemek Seçimi' (main) or 'Yan Ürün Seçimi' (side)
  option_id,
  option_name,
  option_extra_price    -- extra surcharge for this option in TRY (0 = included/free)
FROM `bruin-playground-bensu.lunch.menus`
WHERE menu_date = CURRENT_DATE()
  AND is_available = TRUE
  AND group_name IN ('Ana Yemek Seçimi', 'Yan Ürün Seçimi');
```

Options include both free (`option_extra_price = 0`) and paid ones — the price is carried through so
the composed menu shows a real total.

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

Calories are **not** on the site — the bot looks them up from the internet per dish (see Step 2).

---

## Step 2 — compose one menu per type (randomly)

For each available menu type:
- pick **one random** option from `Ana Yemek Seçimi` → `main` (keep its `option_id`, `extra_price`)
- pick **one random** option from `Yan Ürün Seçimi` → `side` (keep its `option_id`, `extra_price`)
- `total_price = menu_base_price + main.extra_price + side.extra_price`
- **look up `approx_calories` from the internet** for the chosen dishes (see below)
- carry `menu_url` through so people can open the real menu and choose their own options
- assign a 1-based `index` and build a label:
  `"{index}. {emoji} {type} — {main} + {side} ({total_price}₺ · ~{approx_calories} kcal)"`

### Calorie lookup (from the internet)
The ordering site has no calorie data, so for each composed menu the bot **searches the web** to
estimate calories for the dishes it actually picked:
- Run a web search per dish, e.g. `"{main} kaç kalori 1 porsiyon"` and `"{side} kaç kalori 1 porsiyon"`
  (Turkish queries hit local nutrition sites like fitbilgi / yemek.com / diyetkolik).
- Take a representative **per-portion** kcal from the results; sum main + side → `approx_calories`
  (round to the nearest 10). It's an estimate, so keep the `~` in the label.
- Cache within the run so the same dish isn't searched twice; if a dish can't be found, fall back to
  a sensible number for its type (Light ~400, Vegetarian ~500, Chicken ~650, Chef's ~700,
  Meat & Veggie ~700, Rice Bowl ~750, Meat ~800) and move on — never block the poll on a lookup.

Because calories come from the real chosen dishes, the number changes with the random pick (grilled
chicken + salad reads lighter than lamb tandır + rice).

Because the picks are random, the featured combo changes day to day.
Keep each menu's `menu_slug`, `main`/`side` (name + option_id) so votes tie back to real dishes.

**Mark the general menu as default:** flag the Chef's Choice (`online-ozel-menu`) entry with
`"default": true` — this is the fallback when nobody votes. (If `online-ozel-menu` isn't available
that day, mark the first composed menu as default instead.)

Example composed set (`menus` JSON):
```json
[
  {"index":1,"emoji":"👨‍🍳","type":"Chef's Choice","menu_slug":"online-ozel-menu","default":true,
   "main":{"name":"Etli Yaprak Sarma","option_id":"37811-1","extra_price":0},
   "side":{"name":"Karışık Turşu","option_id":"37990-1","extra_price":0},
   "total_price":275,"approx_calories":700,
   "menu_url":"https://siparis.adilesultanevyemekleri.com/product/online-ozel-menu",
   "label":"1. 👨‍🍳 Chef's Choice — Etli Yaprak Sarma + Karışık Turşu (275₺ · ~700 kcal)"},
  {"index":2,"emoji":"🍗","type":"Chicken","menu_slug":"tavuklu-yemek-menu",
   "main":{"name":"Mangalda Tavuk ve Pirinç Pilavı","option_id":"37841-1","extra_price":0},
   "side":{"name":"Arpa Şehriye Pilavı","option_id":"37995-1","extra_price":0},
   "total_price":345,"approx_calories":650,
   "menu_url":"https://siparis.adilesultanevyemekleri.com/product/tavuklu-yemek-menu",
   "label":"2. 🍗 Chicken — Mangalda Tavuk ve Pirinç Pilavı + Arpa Şehriye Pilavı (345₺ · ~650 kcal)"}
]
```

The `main`/`side` are the **randomly chosen options**; `menu_url` is the link people follow if they
want something different from the random pick.

---

## Step 3 — write the result to `lunch.votes`

First make sure the table exists (idempotent — safe to run every day, and means the bot doesn't
depend on the `votes` Bruin pipeline having run first):

```sql
CREATE TABLE IF NOT EXISTS `bruin-playground-bensu.lunch.votes` (
  created_at TIMESTAMP,
  menu_date  DATE,
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

---

## Step 4 — announce the menu (not a dry "Done.")

**Do not emit any internal/status text** — no "Inserted into lunch.votes…", no row counts, no
"created table" messages. The only thing the bot outputs is the friendly announcement below: a
heading plus a **daily motivation** line that changes each day.

```
🍽️ Bugünün öğle menüsü seçenekleri — {date} 🍽️
"{daily motivation line}"

1. 👨‍🍳 Chef's Choice — Etli Yaprak Sarma + Karışık Turşu (275₺ · ~700 kcal)
2. 🍗 Chicken — Mangalda Tavuk ve Pirinç Pilavı + Arpa Şehriye Pilavı (345₺ · ~650 kcal)
3. 🥬 Vegetarian — Kuru Fasulye + Bulgur Pilavı (325₺ · ~500 kcal)
...

Kendi seçimini yapmak istersen 👉 https://siparis.adilesultanevyemekleri.com
```

**No link preview:** when this is posted to Slack, disable the auto-preview card by setting
`unfurl_links: false` and `unfurl_media: false` on the `chat.postMessage` call (optionally also wrap
the url as `<https://siparis.adilesultanevyemekleri.com>`), so no thumbnail/preview appears under the link.

Rotate the motivation so it feels fresh — pick one per day (e.g. by day-of-year, so it's stable for
the day). A few examples (add your own):
- "İyi bir öğün, iyi bir güne yakışır — afiyet olsun! 🌟"
- "Bugün kendine iyi bak, güzel bir menü seç 🍀"
- "Ekip birlikte yer, birlikte güçlenir 💪"
- "Az kaldı öğle arasına — en sevdiğine oy ver! ⏰"
- "Sağlıklı seçim, mutlu öğleden sonra demek 🥗"
- "Bugünün enerjisi tabakta başlar ⚡"
- "Ne seçersen seç, birlikte yemek güzel 🤝"

That's it — the day's menu choices are prepared in `lunch.votes` (latest `created_at` = today) and
the announcement is ready to share.
