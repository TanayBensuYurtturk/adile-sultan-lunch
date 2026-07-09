/* @bruin

name: lunch.votes
type: bq.sql

description: |
  Bot-managed table, one row per daily lunch poll. Bruin only guarantees the table exists with the
  right schema (CREATE TABLE IF NOT EXISTS, so re-runs never wipe data). The bots do the writing:
    - Bot 1 (compose menus):       INSERTs a row with created_at, menu_date, menus (and message_ts once posted).
    - Bot 2 (vote collector):      UPDATEs the latest row, filling responses, tally, summary, updated_at.
  Voting happens in Slack via emoji reactions (no link). See bot1-slack-poll.md and bot2-collect-votes.md.

@bruin */

CREATE TABLE IF NOT EXISTS `bruin-playground-bensu.lunch.votes` (
  created_at TIMESTAMP,   -- when the row was created; identifies the row (latest = today's poll)
  menu_date  DATE,        -- the day this poll is for
  message_ts STRING,      -- Slack message id of the poll, to read reactions (channel is known from config)
  menus      JSON,        -- menus bot 1 composed: [{"index","emoji","type","main","side","menu_slug","label","default"}]
  responses  JSON,        -- who voted (written by bot 2): [{"user_id","name","choice_index","choice"}]
  tally      JSON,        -- per-menu vote counts (written by bot 2): [{"index","label","votes"}]
  summary    STRING,      -- human-readable result: menus + votes (written by bot 2)
  updated_at TIMESTAMP    -- when bot 2 collected the votes
);
