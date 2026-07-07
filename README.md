# adile-sultan-lunch

Bruin data pipelines for the team's daily lunch order from **Adile Sultan Ev Yemekleri**
(`siparis.adilesultanevyemekleri.com`).

Two pipelines feed BigQuery (`bruin-playground-bensu`), and two bots (created separately) sit on
top of them: one turns the scraped menu into a Google Form, the other reads the votes.

```
┌──────────────┐   09:00   ┌──────────────┐   bot 1   ┌─────────────┐
│  menus/      │──────────▶│ lunch.menus  │──────────▶│ Google Form │
│  (scraper)   │           │  (BigQuery)  │           └──────┬──────┘
└──────────────┘           └──────────────┘                  │ team votes
                                                             ▼
┌──────────────┐   18:00   ┌──────────────┐           ┌─────────────┐
│  votes/      │◀──────────│ lunch.votes  │◀──────────│ Form → Sheet│
│  (ingestr)   │  loads    │  (BigQuery)  │  ingestr  └─────────────┘
└──────────────┘           └──────────────┘
```

## Pipelines

### `menus/` — daily menu scraper (runs 09:00)
A Python (materialization) asset that scrapes the 7 daily menus and **every selectable option inside
each** (main dish, side, bread, promo add-ons), and writes one row per option to **`lunch.menus`**.
The site is server-rendered, so no browser or login is needed.

- Asset: `menus/assets/menus.py` → table `lunch.menus`
- Strategy: `delete+insert` on `menu_date` (re-running a day replaces that day, history is kept)
- Quality checks: `menu_date`/`menu_id`/`menu_slug` not-null, `menu_slug` accepted-values

### `votes/` — Google Form responses → BigQuery (runs 18:00)
An `ingestr` asset that loads the Google Form responses sheet into **`lunch.votes`**.

- Asset: `votes/assets/votes.asset.yml` → table `lunch.votes`
- **Setup:** put the responses spreadsheet id in `source_table` (see the file's comments), and share
  the sheet with the service account email.

## The bots
- **`bot1-google-form.md`** — spec for the bot that reads `lunch.menus` and builds the daily Google Form.
- (Bot 2 — reads `lunch.votes` to summarize/place the order — TBD.)

## Setup

1. **Credentials:** copy `.bruin.example.yml` → `.bruin.yml` (git-ignored) and set the paths.
   Both connections use the BigQuery service-account key:
   `/Users/tanaybensu/Desktop/files/keys/bqbensukey.json`.
2. **Validate:** `bruin validate .`
3. **Run the scraper:** `bruin run ./menus`
4. **Inspect:**
   ```bash
   bruin query --connection gcp-default \
     --query "SELECT menu_name, is_available, COUNT(option_id) opt_count \
              FROM lunch.menus WHERE menu_date = CURRENT_DATE() GROUP BY 1,2 ORDER BY opt_count DESC"
   ```
5. **Votes:** once the Google Form + responses sheet exist, fill in `votes/assets/votes.asset.yml`
   and run `bruin run ./votes`.

## Notes
- Destination: `bigquery://project`, dataset `lunch`.
- Schedules are cron in each `pipeline.yml` (menus `0 9 * * *`, votes `0 18 * * *`); the orchestrator
  honors them.
- `.bruin.yml` is git-ignored because it contains credential paths — never commit it.
