# Link filters

Bundled with Conest to clean links in messages. Refreshed with
`tool/update_link_filters.py`; nothing is downloaded at runtime.

## clearurls.json

- Source: https://rules2.clearurls.xyz/data.minify.json
- SHA-256: df97eb5c1aeeb9f96d0c28a6a60604f3cb2b1f9e7776eee228258e1b2bae1424 (matches https://rules2.clearurls.xyz/rules.minify.hash)
- Fetched: 2026-10-20
- The ClearURLs rules, https://github.com/ClearURLs/Rules, by Kevin Röbert
  and contributors, under the GNU Lesser General Public License v3.0
  (https://www.gnu.org/licenses/lgpl-3.0.html). The file is unchanged.

## embed_fixers.json

- Source: https://github.com/seriaati/embed-fixer at 937963ef5697b7bf26a615cd801dadaf1ac46ad0,
  `embed_fixer/fixes.py`
- Fetched: 2026-10-20
- Which embed-fixing services exist for which sites, as listed by the
  embed-fixer bot (AGPL-3.0). Only these facts are taken, not its code.
  Services that show ads, and sites it leaves off by default, are left
  out. Each service belongs to its own operator.
