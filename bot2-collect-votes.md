# Bot 2 — "Slack reactions → votes" collector

## What this bot does
At **11:30 every morning** (voting closes so the order can be placed before lunch), this bot:

1. reads the **latest** `lunch.votes` row (the most recent `created_at` = today's poll),
2. reads the **emoji reactions** on that Slack message (the votes),
3. **writes the votes back into that same row** (`responses`, `tally`, `summary`, `updated_at`),
4. produces a **result message** listing the menus and how many votes each got.

It never creates rows — it only updates the row bot 1 created.

**Capabilities it needs:**
- Slack access to read a message's reactions, resolve user names, and post the result — provided by
  the bot's own Slack integration. No token to manage here.
- BigQuery read + update (connection `gcp-default`).

**Config:** the channel is already known (`SLACK_CHANNEL_ID`); it gets `message_ts` straight from the
latest `lunch.votes` row, so it reads that message's reactions and posts the result directly.

---

## Step 1 — find the latest poll

```sql
SELECT created_at, menu_date, message_ts, menus
FROM `bruin-playground-bensu.lunch.votes`
WHERE updated_at IS NULL            -- not collected yet (optional; drop to always take the latest)
ORDER BY created_at DESC
LIMIT 1;
```

`menus` is the JSON array bot 1 composed. Use its `index`/`emoji`/`label`/`default` to map each
number reaction back to a menu.

---

## Step 2 — read the reactions (the votes)

Call `reactions.get` with `channel = SLACK_CHANNEL_ID` (from config) and `timestamp = message_ts`
(from the row). For each keycap
reaction (`one`, `two`, `three`, …), Slack returns the emoji name and the list of `users` who added it.

- Map emoji name → menu `index` (`one`→1, `two`→2, …) → the menu in `menus`.
- **Ignore the bot's own vote:** bot 1 added the initial reactions, so exclude the bot's user id
  from every reaction's user list.
- For each remaining user, resolve a display name with `users.info` (`real_name` or `name`).
- **One vote per person:** if a user reacted to more than one menu, keep their vote for the
  lowest-index menu (or drop them and note it) so nobody double-counts.

Build `responses`: `[{"user_id","name","choice_index","choice"}]`.

---

## Step 3 — tally and write back into the SAME row

Count votes per menu (include 0-vote menus from `menus` so every option shows) and build a short
human-readable `summary`.

**Default when nobody votes:** if there are zero reactions from real users, don't leave the order
empty — default to the **general menu** (the one flagged `"default": true` in `menus`, i.e. Chef's
Choice). Set `tally` to all-zeros and `summary` to note it was the no-vote default, e.g.
`"No votes — defaulting to the general menu (👨‍🍳 Chef's Choice)"`.

Then UPDATE the same row (matched by `created_at`):

```sql
UPDATE `bruin-playground-bensu.lunch.votes`
SET
  responses  = JSON '[{"user_id":"U123","name":"Bensu","choice_index":2,"choice":"🍗 Chicken — ..."}, ...]',
  tally      = JSON '[{"index":1,"label":"👨‍🍳 Chef''s Choice — ...","votes":1}, {"index":2,"label":"🍗 Chicken — ...","votes":5}, ...]',
  summary    = '2026-07-09 — 12 votes\n🍗 Chicken 5 | 🥩 Meat 3 | 🥬 Vegetarian 2 | 🥗 Light 2',
  updated_at = CURRENT_TIMESTAMP()
WHERE created_at = (SELECT MAX(created_at) FROM `bruin-playground-bensu.lunch.votes`);
```

---

## Step 4 — the result message

Post a summary to the same Slack channel (`chat.postMessage`, optionally as a thread reply on
`message_ts`). To avoid a link preview card, do BOTH: set `unfurl_links: false` and
`unfurl_media: false`, **and** format any URL as a Slack markdown link `<url|label>` rather than a
bare URL (a bare URL is what unfurls). Example:

```
🍽️ Öğle Yemeği sonuçları — 2026-07-09  (12 oy)
🍗 Chicken — Mangalda Tavuk + Arpa Şehriye Pilavı ........ 5
🥩 Meat — Beğendili Mangalda Köfte + Bulgur Pilavı ....... 3
🥬 Vegetarian — Kuru Fasulye + Pirinç Pilavı ............. 2
🥗 Light / Fit — Buharda Karışık Sebze + Salata .......... 2
Kazanan: 🍗 Chicken
```

The winning menu's dishes (`main`/`side` + their `option_id`s from `menus`), its `total_price`, and
its `menu_url` are what you order — the url lets whoever places the order open the exact menu. If
there were no votes, the winner is the general menu (👨‍🍳 Chef's Choice) by default. On a tie, prefer
the default menu, otherwise the lowest index.

---

## Daily order of operations (full picture)
1. **09:00** — `adile-sultan-menus` refreshes `lunch.menus` (Kadıköy Fikirtepe, free options only).
2. **Bot 1** — composes random menus by type → INSERTs a `lunch.votes` row with the `menus`.
   The menus get posted to Slack and the poll's `message_ts` is recorded on that row.
3. Team votes in Slack by tapping a reaction (no link).
4. **11:30 — Bot 2** — voting closes; reads the latest `lunch.votes` row → counts reactions →
   UPDATEs the same row with the tally → posts the result. No votes ⇒ default to the general menu.
