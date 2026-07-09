# adile-sultan-lunch

Bruin + two bots for the team's daily lunch order from **Adile Sultan Ev Yemekleri**
(`siparis.adilesultanevyemekleri.com`).

Bruin scrapes the menu and owns the tables; two bots (created separately, specced in the `bot*.md`
files) compose the daily menus, run a **Slack** vote, and tally the result. Voting happens right in
Slack via emoji reactions — no link, no external form.

```
        09:00 scrape                    bot 1: compose + post              bot 2: collect (11:30)
┌──────────┐   ┌─────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────────────────┐
│  menus/  │──▶│ lunch.menus │──▶│ Slack poll   │   │ lunch.votes  │   │ latest row → read Slack   │
│(scraper) │   │(free opts)  │   │ + 1️⃣2️⃣3️⃣    │──▶│ row: channel,│──▶│ reactions → tally/summary │
└──────────┘   └─────────────┘   │ reactions    │   │ ts, menus    │   │ back into the SAME row    │
                                 └──────┬───────┘   └──────────────┘   └──────────────────────────┘
                                        │ team taps a reaction (no link)
                                        ▼
```

The team picks **one complete menu** (bot 1 pre-selects the dishes) by tapping a reaction in Slack.

## Pipelines

### `menus/` — daily scraper (runs 09:00)
**`menus/assets/menus.py`** (Python) scrapes the 7 daily menus and **every selectable option**
inside each (main dish, side, promo add-ons) into **`lunch.menus`**, one row per option, for the
**Kadıköy Fikirtepe** branch (pinned in-session via the site's region cascade before scraping, since
menus and availability are branch-specific). Both free and paid options are kept, each with its
`option_extra_price`; each row also carries `menu_url` (the product-page link). Bread is excluded.
The site is server-rendered, so no browser or login is needed. Menus not offered today are recorded
with `is_available = false`.
- Strategy: `delete+insert` on `menu_date` (re-running a day replaces that day, history kept)
- Quality checks: `menu_date`/`menu_id`/`menu_slug` not-null, `menu_slug` accepted-values

### `votes/` — table owner (schema only)
**`votes/assets/votes.sql`** runs `CREATE TABLE IF NOT EXISTS lunch.votes (...)` — it just guarantees
the bot-managed `lunch.votes` table exists with the right schema. It never writes rows (the bots do)
and is idempotent, so re-running never wipes data. Columns: `created_at`, `menu_date`, `message_ts`,
`menus` (JSON), `responses` (JSON), `tally` (JSON), `summary`, `updated_at`.

## The bots (specs)
- **`bot1-compose-menus.md`** — reads `lunch.menus`, **randomly composes one menu per type** (marks
  the general menu, Chef's Choice, as `default`), and INSERTs the prepared menus into a `lunch.votes`
  row (`created_at` + `menu_date` + `menus`).
- **`bot2-collect-votes.md`** — runs **11:30 each morning**: reads the **latest** `lunch.votes` row,
  counts the Slack **reactions** on that message, writes them back into the **same row**
  (`responses`/`tally`/`summary`), and posts a menus-and-votes result. If nobody voted, it defaults
  the order to the general menu.
- **Slack:** the bots reach Slack through their own Slack integration — you don't manage a token.
  You only provide `SLACK_CHANNEL_ID`, and the bot must be added to that channel once.

## Setup

1. **Credentials:** copy `.bruin.example.yml` → `.bruin.yml` (git-ignored) and set the paths.
   The connection uses the BigQuery service-account key:
   `/Users/tanaybensu/Desktop/files/keys/bqbensukey.json`.
2. **Validate:** `bruin validate .`
3. **Scrape today's menu:** `bruin run ./menus`
4. **Create the votes table (once):** `bruin run ./votes`
5. **Inspect the scraped options:**
   ```bash
   bruin query --connection gcp-default \
     --query "SELECT menu_name, COUNT(option_id) free_opts FROM lunch.menus \
              WHERE menu_date = CURRENT_DATE() AND group_name='Ana Yemek Seçimi' GROUP BY 1"
   ```
6. **Hook up the bots** using `bot1-compose-menus.md` and `bot2-collect-votes.md`.

## Notes
- Destination: `bigquery://bruin-playground-bensu`, dataset `lunch`.
- `menus` runs at `0 9 * * *`; `votes` (schema) runs `daily`. The bots run on their own triggers
  (bot 1 after the 09:00 scrape, bot 2 at 11:30 when voting closes).
- `.bruin.yml` is git-ignored because it contains credential paths — never commit it.
