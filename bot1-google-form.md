# Bot 1 — "Menü → Google Form" creator

## What this bot does
Every morning, after the `adile-sultan-menus` pipeline has refreshed `lunch.menus`, this bot:

1. reads today's available menus and their **free** options from BigQuery,
2. **randomly composes one complete menu per menu type** (a random main + a random side from that
   type's free options),
3. creates a **Google Form** where each teammate picks one of those composed menus, and
4. **inserts a new row into `lunch.votes`** with the form `link`, `form_id`, `created_at`, and the
   `menus` it composed.

Bot 2 later reads that row (by latest `created_at`) to collect the responses.

**Capabilities it needs:** BigQuery read + insert (connection `gcp-default`), and Google Forms API
access (create a form, add questions, enable a linked responses destination / read `form_id`).

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
- build a label: `"{emoji} {type} — {main} + {side}"`

Because the picks are random, the featured combo changes day to day. Result: ~6–7 composed menus.
Keep each menu's `menu_slug`, `main` (name + option_id), and `side` (name + option_id) so votes can
be tied back to real dishes later.

**Mark the general menu as default:** flag the Chef's Choice (`online-ozel-menu`) entry with
`"default": true`. This is the fallback bot 2 orders if nobody votes. (If `online-ozel-menu` isn't
available that day, mark the first composed menu as default instead.)

Example composed set:
```json
[
  {"type":"Chef's Choice","emoji":"👨‍🍳","menu_slug":"online-ozel-menu","default":true,
   "main":"Etli Yaprak Sarma","side":"Karışık Turşu",
   "label":"👨‍🍳 Chef's Choice — Etli Yaprak Sarma + Karışık Turşu"},
  {"type":"Chicken","emoji":"🍗","menu_slug":"tavuklu-yemek-menu",
   "main":"Mangalda Tavuk ve Pirinç Pilavı","side":"Arpa Şehriye Pilavı",
   "label":"🍗 Chicken — Mangalda Tavuk ve Pirinç Pilavı + Arpa Şehriye Pilavı"},
  {"type":"Vegetarian","emoji":"🥬","menu_slug":"sebzeli-yemek-menu",
   "main":"Kuru Fasulye","side":"Bulgur Pilavı",
   "label":"🥬 Vegetarian — Kuru Fasulye + Bulgur Pilavı"}
]
```

---

## Step 3 — create the Google Form

- Title: `Öğle Yemeği — {today}`.
- Turn on **Collect email addresses** and add a required short-answer **"İsim / Name"**.
- Add ONE required **multiple-choice** question **"Bugünün menüsü / Today's menu"**, one choice per
  composed menu using its `label` (in a stable order). No sub-options — dishes are already picked.
- Keep the `form_id` and the shareable `viewform` link.

---

## Step 4 — write the form to `lunch.votes`

Insert one row (this is the only writer of `link` / `menus`):

```sql
INSERT INTO `bruin-playground-bensu.lunch.votes`
  (created_at, menu_date, link, form_id, menus)
VALUES (
  CURRENT_TIMESTAMP(),
  CURRENT_DATE(),
  'https://docs.google.com/forms/d/e/XXXX/viewform',
  'XXXX',
  JSON '[ ... the composed menus from step 2 ... ]'
);
```

Then post the `link` to the team's channel. Done — bot 2 takes it from here (see
`bot2-collect-responses.md`).
