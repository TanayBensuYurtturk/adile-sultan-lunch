# Bot 1 — "Menüler → Google Form" builder

**Goal:** every morning, after the `adile-sultan-menus` pipeline has refreshed `lunch.menus`
in BigQuery, read today's available menus and their selectable options and build a **Google Form**
the team fills in to vote for their lunch. The form's responses feed the `adile-sultan-votes`
pipeline (`lunch.votes`).

This file is the instruction spec you hand to the Bruin bot. English comments throughout.

---

## 1. Input — read from BigQuery

Connection: `gcp-default` (project `bruin-playground-bensu`). Read only today's menus that are
actually on offer:

```sql
SELECT
  menu_id,
  menu_slug,
  menu_name,
  menu_base_price,
  group_index,
  group_name,          -- e.g. "Ana Yemek Seçimi", "Yan Ürün Seçimi", "Ekmek Seçimi"
  group_rule,          -- e.g. "(1 Adet seçiniz)"
  group_choose,        -- how many options must be picked from this group
  group_required,      -- TRUE = mandatory pick
  option_id,           -- stable id, use as the vote value
  option_name,         -- human label shown in the form
  option_type,         -- "radio" (single) or "checkbox" (multi)
  option_extra_price   -- extra TRY added by this option (0 if included)
FROM `bruin-playground-bensu.lunch.menus`
WHERE menu_date = CURRENT_DATE()
  AND is_available = TRUE
ORDER BY menu_name, group_index, option_name;
```

### `lunch.menus` shape (one row per selectable option)

| column | meaning |
|---|---|
| `menu_date` | scrape date (today) |
| `menu_id` / `menu_slug` / `menu_name` | the menu (e.g. `43808` / `online-ozel-menu` / `Online Özel Menü`) |
| `menu_base_price` | base price of the menu in TRY |
| `is_available` | whether the menu is offered today — **filter on TRUE** |
| `group_index` / `group_name` / `group_rule` | the option group inside the menu |
| `group_choose` / `group_required` | how many to pick / whether mandatory |
| `option_id` / `option_name` / `option_type` / `option_extra_price` | the individual choice |

There are typically 6 available menus per day, each with 8 groups. The mandatory groups are
**`Ana Yemek Seçimi`**, **`Yan Ürün Seçimi`** and **`Ekmek Seçimi`** (`group_required = TRUE`).
The `Promosyon *` groups (drinks, soups, desserts, sides) are optional add-ons.

---

## 2. Output — the Google Form

Build one form per day, titled e.g. `Öğle Yemeği — {CURRENT_DATE}`.

**Identity (so votes map to people):**
- Turn on **Collect email addresses** (→ `Email Address` column), and
- Add a required short-answer question **"İsim / Name"**.

**Menu choice + branching:**
1. Add a required multiple-choice question **"Menü seçimi / Which menu?"** listing the available
   `menu_name` values. Use *go-to-section-based-on-answer* so each choice jumps to that menu's section.
2. For each available menu, create a **section** containing one question per **required** group
   (`group_required = TRUE`), in `group_index` order:
   - `option_type = radio` / `group_choose = 1` → a required **multiple-choice** question.
   - `option_type = checkbox` → a **checkboxes** question (allow multiple).
   - Question title: prefix with the menu so response columns stay unambiguous, e.g.
     `[Etli Yemek Menü] Ana Yemek Seçimi`.
   - Options = that group's `option_name` list. If `option_extra_price > 0`, append ` (+{price}₺)`
     to the label so people see the surcharge.
   - Optionally add the `Promosyon *` groups as **optional** questions in the same section.

**Store the vote value as `option_id`** where possible (or keep a mapping), so `lunch.votes` can be
joined back to `lunch.menus` unambiguously.

---

## 3. Contract with the votes pipeline

- Link the form to a **responses spreadsheet** (Form editor → Responses → link to Sheets).
- Share that spreadsheet with the service account email used by the `google_sheets` connection
  (read access is enough).
- Put the spreadsheet id into `votes/assets/votes.asset.yml` (`source_table`). The responses tab is
  usually `Form Responses 1` (or `Form Yanıtları 1` in a Turkish UI).
- Each response row becomes one row in `lunch.votes`: `Timestamp`, `Email Address`, `İsim`,
  `Menü seçimi`, and the per-menu group answers. The `adile-sultan-votes` pipeline loads it as-is;
  normalization (who → which menu → which options) happens downstream.

---

## 4. Daily order of operations

1. `adile-sultan-menus` runs at **09:00** → refreshes `lunch.menus`.
2. **This bot** reads `lunch.menus` → builds today's Google Form → posts the link to the team.
3. Team votes during the day.
4. `adile-sultan-votes` runs at **18:00** → loads the responses sheet into `lunch.votes`.
