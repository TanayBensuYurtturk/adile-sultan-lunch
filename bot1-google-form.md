# Bot 1 — "Menüler → Google Form" builder

**Goal:** every morning, after the `adile-sultan-menus` pipeline has composed the day's menus into
`lunch.daily_options` in BigQuery, build a **Google Form** where each teammate picks **one complete
menu** (not individual dishes) and post the link to the team. The form's responses feed the
`adile-sultan-votes` pipeline (`lunch.votes`).

The team only chooses a **menu**. The pipeline has already selected the dishes inside each menu
(main + side + bread), so the form is a single, simple question. This file is the instruction spec
you hand to the Bruin bot.

---

## 1. Input — read from BigQuery

Connection: `gcp-default` (project `bruin-playground-bensu`). Read the composed menus for the day:

```sql
SELECT
  choice_index,   -- 1-based display order
  emoji,          -- e.g. 🍗 🥩 🥬 🥗
  category,       -- Chicken, Meat, Vegetarian, Light / Fit, Rice Bowl, Chef's Choice, ...
  menu_name,      -- restaurant menu this came from
  main_dish,      -- pre-selected main
  side_dish,      -- pre-selected side
  total_price,    -- TRY (menu base price)
  label           -- ready-made display string, e.g. "🍗 Chicken — ... + Arpa Şehriye Pilavı"
FROM `bruin-playground-bensu.lunch.daily_options`
ORDER BY choice_index;
```

Typically 5–7 rows, one per style. Example output:

| choice_index | label | total_price |
|---|---|---|
| 1 | 👨‍🍳 Chef's Choice — Etli Yaprak Sarma + Karışık Turşu | 275 |
| 2 | 🍗 Chicken — Özel Soslu Tavuk ve Penne Makarna + Arpa Şehriye Pilavı | 345 |
| 3 | 🥗 Light / Fit — Buharda Karışık Sebze + … | 325 |
| 4 | 🥩 Meat — Beğendili Mangalda Köfte + Arpa Şehriye Pilavı | 455 |
| 5 | 🍚 Rice Bowl — Pilav Üstü Kuru Fasulye + Arpa Şehriye Pilavı | 245 |
| 6 | 🥬 Vegetarian — Bezelye + Arpa Şehriye Pilavı | 325 |

> The full dish-by-dish menu with all raw options still lives in `lunch.menus` if you ever want to
> build a more detailed form; `lunch.daily_options` is the curated short list for voting.

---

## 2. Output — the Google Form

Build one form per day, titled e.g. `Öğle Yemeği — {CURRENT_DATE}`.

**Identity (so votes map to people):**
- Turn on **Collect email addresses** (→ `Email Address` column), and
- Add a required short-answer question **"İsim / Name"**.

**The menu question (single, required):**
- One **multiple-choice** question: **"Bugünün menüsü / Today's menu"**.
- One choice per row from `lunch.daily_options`, using `label` as the choice text (it already
  includes emoji, category, main and side). Optionally append ` — {total_price}₺`.
- Keep the choices in `choice_index` order.
- No branching, no sub-questions — the dishes are already decided.

That's it: email + name + one menu pick.

---

## 3. Contract with the votes pipeline

- Link the form to a **responses spreadsheet** (Form editor → Responses → link to Sheets).
- Share that spreadsheet with the service account email used by the `google_sheets` connection
  (read access is enough).
- Put the spreadsheet id into `votes/assets/votes.asset.yml` (`source_table`). The responses tab is
  usually `Form Responses 1` (or `Form Yanıtları 1` in a Turkish UI).
- Each response becomes one row in `lunch.votes`: `Timestamp`, `Email Address`, `İsim`, and the
  chosen menu `label`. Because the choice text matches `lunch.daily_options.label`, you can join
  votes back to the exact menu (and its `main_option_id` / `side_option_id`) for placing the order.

---

## 4. Daily order of operations

1. `adile-sultan-menus` runs at **09:00** → refreshes `lunch.menus`, then composes `lunch.daily_options`.
2. **This bot** reads `lunch.daily_options` → builds today's Google Form → posts the link to the team.
3. Team votes during the day (one menu each).
4. `adile-sultan-votes` runs at **18:00** → loads the responses sheet into `lunch.votes`.
