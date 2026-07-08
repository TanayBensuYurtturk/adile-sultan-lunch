# adile-sultan-lunch

Bruin + two bots for the team's daily lunch order from **Adile Sultan Ev Yemekleri**
(`siparis.adilesultanevyemekleri.com`).

Bruin scrapes the menu and owns the tables; two bots (created separately, specced in the `bot*.md`
files) compose the daily menus, run the Google Form vote, and tally the result.

```
        09:00 scrape                     bot 1: compose + form                bot 2: collect
┌──────────┐   ┌─────────────┐   ┌─────────────┐   ┌──────────────┐   ┌──────────────────────────┐
│  menus/  │──▶│ lunch.menus │──▶│ Google Form │   │ lunch.votes  │   │ latest row → responses,  │
│(scraper) │   │(free opts)  │   │ (per type)  │──▶│ row: link,   │──▶│ tally, summary written   │
└──────────┘   └─────────────┘   └──────┬──────┘   │ created_at,  │   │ back into the SAME row   │
                                        │ votes     │ menus        │   └──────────────────────────┘
                                        ▼           └──────────────┘
                                   team fills form
```

The team picks **one complete menu** (bot 1 pre-selects the dishes), not individual options.

## Pipelines

### `menus/` — daily scraper (runs 09:00)
**`menus/assets/menus.py`** (Python) scrapes the 7 daily menus and **every free selectable option**
inside each (main dish, side, promo add-ons) into **`lunch.menus`**, one row per option.
Paid/surcharge options and bread are excluded. The site is server-rendered, so no browser or login
is needed. Menus not offered today are recorded with `is_available = false`.
- Strategy: `delete+insert` on `menu_date` (re-running a day replaces that day, history kept)
- Quality checks: `menu_date`/`menu_id`/`menu_slug` not-null, `menu_slug` accepted-values

### `votes/` — table owner (schema only)
**`votes/assets/votes.sql`** runs `CREATE TABLE IF NOT EXISTS lunch.votes (...)` — it just guarantees
the bot-managed `lunch.votes` table exists with the right schema. It never writes rows (the bots do)
and is idempotent, so re-running never wipes data. Columns: `created_at`, `menu_date`, `link`,
`form_id`, `menus` (JSON), `responses` (JSON), `tally` (JSON), `summary`, `updated_at`.

## The bots (specs)
- **`bot1-google-form.md`** — reads `lunch.menus`, **randomly composes one menu per type** (marks the
  general menu, Chef's Choice, as `default`), creates a Google Form, and INSERTs a `lunch.votes` row
  with the form `link` + `created_at` + `menus`.
- **`bot2-collect-responses.md`** — runs **11:30 each morning**: reads the **latest** `lunch.votes`
  row, fetches that form's responses, writes them back into the **same row**
  (`responses`/`tally`/`summary`), and posts a menus-and-votes result. If nobody voted, it defaults
  the order to the general menu.

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
6. **Hook up the bots** using `bot1-google-form.md` and `bot2-collect-responses.md`.

## Notes
- Destination: `bigquery://bruin-playground-bensu`, dataset `lunch`.
- `menus` runs at `0 9 * * *`; `votes` (schema) runs `daily`. The bots run on their own triggers
  (bot 1 after the 09:00 scrape, bot 2 at 11:30 when voting closes).
- `.bruin.yml` is git-ignored because it contains credential paths — never commit it.
