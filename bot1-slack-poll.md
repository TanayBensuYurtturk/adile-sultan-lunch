# Bot 1 — "Menü → Slack poll" creator

## What this bot does
Every morning, after the `adile-sultan-menus` pipeline has refreshed `lunch.menus`, this bot:

1. reads today's available menus and their **free** options from BigQuery (Kadıköy Fikirtepe branch),
2. **randomly composes one complete menu per menu type** (a random main + a random side),
3. posts a **Slack message** listing the menus and adds one number reaction per menu
   (1️⃣ 2️⃣ 3️⃣ …) so the team votes **inside Slack — no link, no form**, and
4. **inserts a new row into `lunch.votes`** with the Slack `channel_id`, `message_ts`, `created_at`,
   and the `menus` it composed (Chef's Choice marked as the default).

Bot 2 later reads that row (by latest `created_at`) and counts the reactions.

**Capabilities it needs:**
- BigQuery read + insert (connection `gcp-default`).
- Slack access to post a message and add reactions — provided by the bot's own Slack integration.
  You don't manage a token here.

**Config you provide:**
- `SLACK_CHANNEL_ID` — the target channel id (e.g. `C0XXXXXXX`). That's it.

With just the channel id, the bot posts **directly** to the channel (no channel lookup, no token to
set up), then adds the number reactions. Make sure the bot has been added to that channel once.

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
- assign a 1-based `index` (the vote number) and build a label:
  `"{index}. {emoji} {type} — {main} + {side}"`

Because the picks are random, the featured combo changes day to day. Result: ~6 composed menus.
Keep each menu's `menu_slug`, `main`/`side` (name + option_id) so votes tie back to real dishes.

**Mark the general menu as default:** flag the Chef's Choice (`online-ozel-menu`) entry with
`"default": true` — bot 2 orders it if nobody votes. (If `online-ozel-menu` isn't available that day,
mark the first composed menu as default instead.)

There are 10 keycap number emoji (1️⃣–🔟), plenty for ~6 menus.

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

## Step 3 — post the Slack poll

- Post straight to the configured channel (`SLACK_CHANNEL_ID`). Body: a title + each menu's `label`
  on its own line, e.g.:

  ```
  🍽️ Öğle Yemeği — 2026-07-09  (bir menüye reaction ile oy verin)
  1. 👨‍🍳 Chef's Choice — Etli Yaprak Sarma + Karışık Turşu
  2. 🍗 Chicken — Mangalda Tavuk ve Pirinç Pilavı + Arpa Şehriye Pilavı
  3. 🥬 Vegetarian — Kuru Fasulye + Bulgur Pilavı
  ...
  ```

- Capture the returned `channel` and `ts` (message timestamp — this is the poll's id).
- `reactions.add` one keycap number per menu, in order, on that `ts`:
  `one`, `two`, `three`, `four`, `five`, `six`, … (Slack emoji names for 1️⃣–🔟).
  These are the buttons people tap to vote — no link, they vote right in the message.

---

## Step 4 — write the poll to `lunch.votes`

Insert one row (this is the only writer of `channel_id` / `message_ts` / `menus`):

```sql
INSERT INTO `bruin-playground-bensu.lunch.votes`
  (created_at, menu_date, channel_id, message_ts, menus)
VALUES (
  CURRENT_TIMESTAMP(),
  CURRENT_DATE(),
  'C0XXXXXXX',                 -- Slack channel id
  '1720512000.123456',         -- Slack message ts from chat.postMessage
  JSON '[ ... the composed menus from step 2 ... ]'
);
```

Done — bot 2 takes it from here (see `bot2-collect-votes.md`).
