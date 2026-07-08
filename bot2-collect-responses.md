# Bot 2 — "Responses → votes" collector

## What this bot does
At **11:30 every morning** (voting closes so the order can be placed before lunch), this bot:

1. reads the **latest** `lunch.votes` row (the most recent `created_at` = today's form),
2. opens that form via its `link` / `form_id` and fetches all **responses**,
3. **writes the responses back into that same row** (`responses`, `tally`, `summary`, `updated_at`),
4. produces a **result message** listing the menus and how many votes each got.

It never creates rows — it only updates the row bot 1 created.

**Capabilities it needs:** Google Forms API (read responses for a `form_id`), and BigQuery
read + update (connection `gcp-default`).

---

## Step 1 — find the latest form

```sql
SELECT created_at, menu_date, link, form_id, menus
FROM `bruin-playground-bensu.lunch.votes`
WHERE updated_at IS NULL            -- not collected yet (optional; drop to always take the latest)
ORDER BY created_at DESC
LIMIT 1;
```

`menus` is the JSON array bot 1 composed — use it to know the valid menu labels and to map a chosen
label back to its dishes / `menu_slug`.

---

## Step 2 — fetch the responses

Using `form_id`, read every submission. For each, capture:
- `email` (from "Collect email addresses"),
- `name` (the "İsim / Name" answer),
- `choice` (the selected menu `label`),
- `choice_index` (its position, optional).

If someone submitted more than once, keep their **latest** submission only.

---

## Step 3 — tally and write back into the SAME row

Count votes per menu label (include 0-vote menus from `menus` so every option shows), and build a
short human-readable `summary`.

**Default when nobody votes:** if there are zero responses, don't leave the order empty — default to
the **general menu** (the Chef's Choice / `online-ozel-menu`, which bot 1 marks with
`"default": true` in `menus`). In that case set `tally` to all-zeros, and `summary` to note it was
the no-vote default, e.g. `"No votes — defaulting to the general menu (👨‍🍳 Chef's Choice)"`.

Then UPDATE the same row (matched by `created_at`):

```sql
UPDATE `bruin-playground-bensu.lunch.votes`
SET
  responses  = JSON '[{"name":"...","email":"...","choice":"🍗 Chicken — ...","choice_index":1}, ...]',
  tally      = JSON '[{"label":"🍗 Chicken — ...","votes":5}, {"label":"🥬 Vegetarian — ...","votes":2}, ...]',
  summary    = '2026-07-08 — 12 votes\n🍗 Chicken 5 | 🥩 Meat 3 | 🥬 Vegetarian 2 | 🥗 Light 2',
  updated_at = CURRENT_TIMESTAMP()
WHERE created_at = (SELECT MAX(created_at) FROM `bruin-playground-bensu.lunch.votes`);
```

---

## Step 4 — the result message

Post a summary to the team, e.g.:

```
🍽️ Öğle Yemeği sonuçları — 2026-07-08  (12 oy)
🍗 Chicken — Mangalda Tavuk + Arpa Şehriye Pilavı ........ 5
🥩 Meat — Beğendili Mangalda Köfte + Bulgur Pilavı ....... 3
🥬 Vegetarian — Kuru Fasulye + Pirinç Pilavı ............. 2
🥗 Light / Fit — Buharda Karışık Sebze + Salata .......... 2
Kazanan: 🍗 Chicken
```

The winning menu's dishes (`main`/`side` + their `option_id`s from `menus`) are what you order. If
there were no votes, the winner is the general menu (👨‍🍳 Chef's Choice) by default.

---

## Daily order of operations (full picture)
1. **09:00** — `adile-sultan-menus` refreshes `lunch.menus` (free options only).
2. **Bot 1** — composes random menus by type → creates the Google Form → INSERTs a `lunch.votes` row
   with the `link`.
3. Team votes during the morning.
4. **11:30 — Bot 2** — voting closes; reads the latest `lunch.votes` row → fetches responses →
   UPDATEs the same row with the tally → posts the result. No votes ⇒ default to the general menu.
