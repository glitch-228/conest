# XMPP servers

Bundled with Conest so setup can find a server where it can create an
account. Refreshed with `tool/update_xmpp_servers.py`; nothing is
downloaded at runtime.

## servers.json

- Source: https://providers.xmpp.net (its published lists, categories A to D)
- Fetched: 2026-10-29
- Only facts are taken: the domain, whether in-band registration needs a
  CAPTCHA, and the registration web page where there is no in-band one.
  Each server belongs to its own operator.
