""" @bruin

name: lunch.menus
type: python
image: python:3.11
connection: gcp-default

description: |
  Daily snapshot of Adile Sultan's lunch menus and every selectable option inside each menu.
  Scrapes the public ordering site (siparis.adilesultanevyemekleri.com), which is server-rendered,
  so no browser/login is needed. One row per selectable option; menus that are not offered today
  (their product page 302-redirects to the homepage) are recorded as a single marker row with
  is_available = false. Downstream, the Google Form bot reads this table (WHERE is_available)
  to build the day's poll.

materialization:
  type: table
  strategy: delete+insert
  incremental_key: menu_date

columns:
  - name: menu_date
    type: date
    description: "Date the menu was scraped (partition/refresh key)."
    checks:
      - name: not_null
  - name: menu_id
    type: integer
    description: "RestApp product id of the menu."
    checks:
      - name: not_null
  - name: menu_slug
    type: string
    description: "URL slug of the menu, e.g. online-ozel-menu."
    checks:
      - name: not_null
      - name: accepted_values
        value:
          - online-ozel-menu
          - dusuk-kalorili-fit-menu
          - etli-sebzeli-yemek-menu
          - etli-yemek-menu
          - pilav-ustu-menu
          - sebzeli-yemek-menu
          - tavuklu-yemek-menu
  - name: menu_name
    type: string
    description: "Display name of the menu, e.g. Online Özel Menü."
  - name: menu_description
    type: string
    description: "Short description shown on the menu card."
  - name: menu_base_price
    type: float64
    description: "Base price of the menu in TRY."
  - name: is_available
    type: boolean
    description: "Whether the menu is offered today (has selectable options)."
  - name: group_index
    type: integer
    description: "Order of the option group within the menu (1-based)."
  - name: group_name
    type: string
    description: "Option group name, e.g. Ana Yemek Seçimi, Yan Ürün Seçimi."
  - name: group_rule
    type: string
    description: "Selection rule text, e.g. (1 Adet seçiniz)."
  - name: group_choose
    type: integer
    description: "How many options must be chosen from this group."
  - name: group_required
    type: boolean
    description: "Whether choosing from this group is mandatory."
  - name: option_id
    type: string
    description: "RestApp option id (value attribute), unique within the product."
  - name: option_name
    type: string
    description: "Selectable option name, e.g. İzmir Köfte."
  - name: option_type
    type: string
    description: "Input type: radio (single) or checkbox (multi)."
  - name: option_extra_price
    type: float64
    description: "Extra price added by this option in TRY (0 if included)."
  - name: scraped_at
    type: timestamp
    description: "UTC timestamp of the scrape run."

@bruin """

import datetime as dt
import re

import pandas as pd
import requests
from bs4 import BeautifulSoup

BASE = "https://siparis.adilesultanevyemekleri.com"
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; adile-sultan-lunch-bot/1.0)"}

# The 7 daily menus the team orders from. Slugs are stable on the ordering site.
TARGET_SLUGS = [
    "online-ozel-menu",
    "dusuk-kalorili-fit-menu",
    "etli-sebzeli-yemek-menu",
    "etli-yemek-menu",
    "pilav-ustu-menu",
    "sebzeli-yemek-menu",
    "tavuklu-yemek-menu",
]

PRICE_RE = re.compile(r"([0-9]+(?:[.,][0-9]+)?)\s*₺")


def _to_float(txt):
    """Parse a Turkish-formatted price like '1.234,56 ₺' -> 1234.56."""
    if not txt:
        return None
    m = PRICE_RE.search(txt)
    if not m:
        return None
    num = m.group(1).replace(".", "").replace(",", ".")
    try:
        return float(num)
    except ValueError:
        return None


def _fetch(url):
    """GET a URL; return (html, final_url) so we can detect redirects."""
    r = requests.get(url, headers=HEADERS, timeout=30)
    r.raise_for_status()
    return r.text, r.url


def _parse_menu_cards(html):
    """From the landing page, map target slug -> {menu_id, name, description, base_price}."""
    soup = BeautifulSoup(html, "lxml")
    cards = {}
    for card in soup.select("div.food-item"):
        link = card.find("a", attrs={"data-prd-id": True})
        if not link:
            continue
        slug = link.get("href", "").rstrip("/").split("/")[-1]
        if slug not in TARGET_SLUGS:
            continue
        name_el = card.select_one("h6.search-el")
        desc_el = card.find("p")
        cards[slug] = {
            "menu_id": int(link["data-prd-id"]),
            "name": (name_el.get_text(strip=True) if name_el else link.get("title", "")).strip(),
            "description": desc_el.get_text(strip=True) if desc_el else "",
            "base_price": _to_float(card.get_text(" ")),
        }
    return cards


def _parse_option_groups(html):
    """From a product page, return the option groups and their selectable options."""
    soup = BeautifulSoup(html, "lxml")
    groups = []
    for gi, g in enumerate(soup.select("div.modifierGrupModifierList"), start=1):
        title_el = g.select_one(".divider-h4")
        rule_el = title_el.find_next("span") if title_el else None
        choose = g.get("data-choose")
        options = []
        for opt in g.select(".modifier-option"):
            inp = opt.find("input")
            if not inp:
                continue
            desc = opt.select_one(".custom-control-description")
            price_span = opt.select_one(".price-span")
            options.append({
                "option_id": inp.get("value"),
                "option_name": desc.get_text(strip=True) if desc else "",
                "option_type": inp.get("type", ""),
                "option_extra_price": (
                    _to_float(inp.get("data-price", ""))
                    or _to_float(price_span.get_text() if price_span else "")
                    or 0.0
                ),
            })
        groups.append({
            "group_index": gi,
            "group_name": title_el.get_text(strip=True) if title_el else "",
            "group_rule": rule_el.get_text(strip=True) if rule_el else "",
            "group_choose": int(choose) if choose and choose.isdigit() else 1,
            "group_required": bool(g.select_one(".required-div")),
            "options": options,
        })
    return groups


def materialize():
    run_date = dt.date.today()
    scraped_at = dt.datetime.now(dt.timezone.utc)
    landing_html, _ = _fetch(BASE)
    cards = _parse_menu_cards(landing_html)

    rows = []
    for slug in TARGET_SLUGS:
        card = cards.get(slug)
        if not card:
            continue
        html, final_url = _fetch(f"{BASE}/product/{slug}")
        # A menu not offered today 302-redirects to the homepage; detect via the final URL.
        available = f"/product/{slug}" in final_url
        groups = _parse_option_groups(html) if available else []

        base = {
            "menu_date": run_date,
            "menu_id": card["menu_id"],
            "menu_slug": slug,
            "menu_name": card["name"],
            "menu_description": card["description"],
            "menu_base_price": card["base_price"],
            "is_available": available and bool(groups),
            "scraped_at": scraped_at,
        }
        if available and groups:
            for grp in groups:
                for opt in grp["options"]:
                    rows.append({**base,
                        "group_index": grp["group_index"],
                        "group_name": grp["group_name"],
                        "group_rule": grp["group_rule"],
                        "group_choose": grp["group_choose"],
                        "group_required": grp["group_required"],
                        "option_id": opt["option_id"],
                        "option_name": opt["option_name"],
                        "option_type": opt["option_type"],
                        "option_extra_price": opt["option_extra_price"],
                    })
        else:
            # Record unavailable menus as a single marker row so the day is complete.
            rows.append({**base,
                "group_index": None, "group_name": None, "group_rule": None,
                "group_choose": None, "group_required": None,
                "option_id": None, "option_name": None, "option_type": None,
                "option_extra_price": None,
            })

    df = pd.DataFrame(rows)
    # Stable column order for the destination table.
    return df[[
        "menu_date", "menu_id", "menu_slug", "menu_name", "menu_description",
        "menu_base_price", "is_available", "group_index", "group_name", "group_rule",
        "group_choose", "group_required", "option_id", "option_name", "option_type",
        "option_extra_price", "scraped_at",
    ]]
