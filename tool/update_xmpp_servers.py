#!/usr/bin/env python3
"""Refresh the bundled list of XMPP servers where Conest can create an
account (assets/xmpp/servers.json).

Run before a release (it downloads data; it builds nothing):

    python3 tool/update_xmpp_servers.py

Source: the XMPP Providers project (https://providers.xmpp.net), its
published lists for categories A to D. Kept are the providers that

- allow in-band registration (XEP-0077) without an email address, or
- send people to a registration web page (then the app shows that link).

Order: sign-up with only a name and password first, then those with a
CAPTCHA, then web page only; within each, better categories first.

Nothing is downloaded by the app at runtime.
"""

import datetime
import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "xmpp"
BASE = "https://data.xmpp.net/providers/v2/providers-{}.json"
CATEGORIES = "ABCD"
MAX_SERVERS = 120
DOMAIN = re.compile(r"^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "conest-tools"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def web_page(entry: dict) -> str | None:
    pages = entry.get("registrationWebPage") or {}
    for language in ("en", *pages):
        url = pages.get(language)
        if isinstance(url, str) and url.startswith("https://") and len(url) <= 512:
            return url
    return None


def main() -> None:
    chosen = []
    for category in CATEGORIES:
        for entry in json.loads(fetch(BASE.format(category))):
            domain = str(entry.get("jid", "")).lower()
            if not DOMAIN.match(domain):
                continue
            in_band = entry.get("inBandRegistration") is True and not entry.get(
                "inBandRegistrationEmailAddressRequired", False
            )
            web = web_page(entry)
            if not in_band and web is None:
                continue
            chosen.append(
                {
                    "domain": domain,
                    "captcha": bool(in_band and entry.get("inBandRegistrationCaptchaRequired")),
                    **({"web": web} if web and not in_band else {}),
                    "_rank": (
                        0 if in_band and not entry.get("inBandRegistrationCaptchaRequired") else 1 if in_band else 2,
                        category,
                    ),
                }
            )
    chosen.sort(key=lambda server: (server["_rank"], server["domain"]))
    seen = set()
    servers = []
    for server in chosen:
        if server["domain"] in seen:
            continue
        seen.add(server["domain"])
        del server["_rank"]
        servers.append(server)
    servers = servers[:MAX_SERVERS]
    if len(servers) < 5:
        sys.exit("XMPP providers: too few servers; the format changed?")
    OUT.mkdir(parents=True, exist_ok=True)
    today = datetime.date.today().isoformat()
    (OUT / "servers.json").write_text(
        json.dumps(
            {"source": "https://providers.xmpp.net", "fetched": today, "servers": servers},
            indent=1,
            ensure_ascii=False,
        )
        + "\n"
    )
    (OUT / "SOURCES.md").write_text(
        "# XMPP servers\n\n"
        "Bundled with Conest so setup can find a server where it can create an\n"
        "account. Refreshed with `tool/update_xmpp_servers.py`; nothing is\n"
        "downloaded at runtime.\n\n"
        "## servers.json\n\n"
        "- Source: https://providers.xmpp.net (its published lists, categories A to D)\n"
        f"- Fetched: {today}\n"
        "- Only facts are taken: the domain, whether in-band registration needs a\n"
        "  CAPTCHA, and the registration web page where there is no in-band one.\n"
        "  Each server belongs to its own operator.\n"
    )
    print(f"{len(servers)} servers")


if __name__ == "__main__":
    main()
