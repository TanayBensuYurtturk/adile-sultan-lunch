/* @bruin

name: lunch.votes
type: bq.sql

description: |
  Bot-managed table, one row per daily lunch form. Bruin only guarantees the table exists with the
  right schema (CREATE TABLE IF NOT EXISTS, so re-runs never wipe data). The bots do the writing:
    - Bot 1 (menu form creator): INSERTs a row with created_at, menu_date, link, form_id, menus.
    - Bot 2 (response collector):  UPDATEs the latest row, filling responses, tally, summary, updated_at.
  See bot1-google-form.md and bot2-collect-responses.md.

@bruin */

CREATE TABLE IF NOT EXISTS `bruin-playground-bensu.lunch.votes` (
  created_at TIMESTAMP,   -- when bot 1 created the form; identifies the row (latest = today's form)
  menu_date  DATE,        -- the day this form is for
  link       STRING,      -- Google Form URL (written by bot 1)
  form_id    STRING,      -- Google Form id, for reading responses (written by bot 1)
  menus      JSON,        -- menus bot 1 composed: [{"type","main","side","menu_slug","label"}]
  responses  JSON,        -- raw responses (written by bot 2): [{"name","email","choice","choice_index"}]
  tally      JSON,        -- per-menu vote counts (written by bot 2): [{"label","votes"}]
  summary    STRING,      -- human-readable result: menus + votes (written by bot 2)
  updated_at TIMESTAMP    -- when bot 2 filled the responses
);
