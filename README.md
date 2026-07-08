# adile-sultan-lunch

Bruin data pipelines for the team's daily lunch order from **Adile Sultan Ev Yemekleri**
(`siparis.adilesultanevyemekleri.com`).

Two pipelines feed BigQuery (`bruin-playground-bensu`), and two bots (created separately) sit on
top of them: one turns the scraped menu into a Google Form, the other reads the votes.

```
                09:00 scrape + compose                    bot 1
┌──────────┐   ┌─────────────┐   ┌────────────────────┐   ┌─────────────┐
│  menus/  │──▶│ lunch.menus │──▶│ lunch.daily_options│──▶│ Google Form │
│(scraper) │   │ (all opts)  │   │ (curated menus)    │   └──────┬──────┘
└──────────┘   └─────────────┘   └────────────────────┘          │ team votes
                                                                  ▼
┌──────────┐   18:00   ┌─────────────┐                     ┌─────────────┐
│  votes/  │◀──────────│ lunch.votes │◀────────────────────│ Form → Sheet│
│(ingestr) │  loads    │ (BigQuery)  │  ingestr            └─────────────┘
└──────────┘           └─────────────┘
```

The team picks **one complete menu** (dishes are pre-selected by the pipeline), not individual options.

## Pipelines

### `menus/` — daily scrape + compose (runs 09:00)
Two assets:

1. **`menus/assets/menus.py`** (Python) — scrapes the 7 daily menus and **every free selectable
   option inside each** (main dish, side, promo add-ons) into **`lunch.menus`**, one row per option.
   Paid/surcharge options and bread are excluded. The site is server-rendered, so no browser or
   login is needed. Menus not offered today are recorded with `is_available = false`.
   - Strategy: `delete+insert` on `menu_date` (re-running a day replaces that day, history kept)
   - Quality checks: `menu_date`/`menu_id`/`menu_slug` not-null, `menu_slug` accepted-values

2. **`menus/assets/daily_options.sql`** (BigQuery SQL, depends on `lunch.menus`) — composes one
   **complete, ready-to-eat menu per style** (Chicken, Meat, Vegetarian, Light/Fit, Rice Bowl,
   Chef's Choice, Meat & Veggie) by picking an on-theme main + a real side + bread from the raw
   options, into **`lunch.daily_options`**. This is the short list the team votes on. The category
   keyword rules are in the SQL and easy to tweak.

### `votes/` — Google Form responses → BigQuery (runs 18:00)
An `ingestr` asset that loads the Google Form responses sheet into **`lunch.votes`**.

- Asset: `votes/assets/votes.asset.yml` → table `lunch.votes`
- **Setup:** put the responses spreadsheet id in `source_table` (see the file's comments), and share
  the sheet with the service account email.

## The bots
- **`bot1-google-form.md`** — spec for the bot that reads `lunch.daily_options` and builds the daily
  Google Form (one question: pick a menu).
- (Bot 2 — reads `lunch.votes` to summarize/place the order — TBD.)

## Setup

1. **Credentials:** copy `.bruin.example.yml` → `.bruin.yml` (git-ignored) and set the paths.
   Both connections use the BigQuery service-account key:
   `/Users/tanaybensu/Desktop/files/keys/bqbensukey.json`.
2. **Validate:** `bruin validate .`
3. **Run the menus pipeline** (scrape + compose): `bruin run ./menus`
4. **Inspect the composed menus:**
   ```bash
   bruin query --connection gcp-default \
     --query "SELECT choice_index, label, total_price FROM lunch.daily_options ORDER BY choice_index"
   ```
5. **Votes:** once the Google Form + responses sheet exist, fill in `votes/assets/votes.asset.yml`
   and run `bruin run ./votes`.

## Notes
- Destination: `bigquery://project`, dataset `lunch`.
- Schedules are cron in each `pipeline.yml` (menus `0 9 * * *`, votes `0 18 * * *`); the orchestrator
  honors them.
- `.bruin.yml` is git-ignored because it contains credential paths — never commit it.
