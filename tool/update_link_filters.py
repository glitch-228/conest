#!/usr/bin/env python3
"""Refresh the bundled link filters in assets/filters/.

Run before a release (it downloads data; it builds nothing):

    python3 tool/update_link_filters.py [--embed-fixer-commit SHA]

- clearurls.json: the ClearURLs rules (LGPL-3.0), unchanged, checked
  against the hash ClearURLs publishes next to them.
- embed_fixers.json: which embed-fixing services exist per site, read
  from the embed-fixer bot's fixes.py (github.com/seriaati/embed-fixer)
  with `ast`, never executed. Services that show ads are left out, and so
  are sites the bot leaves off by default.
- SOURCES.md: where both came from, when, and their licenses.

Nothing is downloaded by the app at runtime.
"""

import argparse
import ast
import datetime
import hashlib
import json
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "filters"

CLEARURLS_DATA = "https://rules2.clearurls.xyz/data.minify.json"
CLEARURLS_HASH = "https://rules2.clearurls.xyz/rules.minify.hash"
EMBED_FIXER_REPO = "seriaati/embed-fixer"
EMBED_FIXER_DEFAULT_COMMIT = "937963ef5697b7bf26a615cd801dadaf1ac46ad0"


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "conest-tools"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def clear_urls() -> tuple[bytes, str]:
    data = fetch(CLEARURLS_DATA)
    expected = fetch(CLEARURLS_HASH).decode().strip().lower()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        sys.exit(f"ClearURLs hash mismatch: {actual} != {expected}")
    providers = json.loads(data)["providers"]
    if not providers:
        sys.exit("ClearURLs rules have no providers")
    return data, actual


def _value(node: ast.AST, names: dict[str, object]) -> object:
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Name):
        if node.id not in names:
            raise ValueError(f"unknown name {node.id}")
        return names[node.id]
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
        return f"{node.value.id}.{node.attr}"
    if isinstance(node, ast.List):
        return [_value(item, names) for item in node.elts]
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        fields = {kw.arg: _value(kw.value, names) for kw in node.keywords}
        for index, arg in enumerate(node.args):
            fields[f"_{index}"] = _value(arg, names)
        fields["_type"] = node.func.id
        return fields
    raise ValueError(f"unsupported syntax: {ast.dump(node)}")


def embed_fixers(commit: str) -> dict:
    source = fetch(
        f"https://raw.githubusercontent.com/{EMBED_FIXER_REPO}/{commit}/embed_fixer/fixes.py"
    ).decode()
    tree = ast.parse(source)
    names: dict[str, object] = {}
    domains = None
    for statement in tree.body:
        target = None
        if isinstance(statement, ast.Assign) and len(statement.targets) == 1:
            target, value = statement.targets[0], statement.value
        elif isinstance(statement, ast.AnnAssign):
            target, value = statement.target, statement.value
        if not isinstance(target, ast.Name) or value is None:
            continue
        if target.id == "DOMAINS":
            domains = _value(value, names)
        elif isinstance(value, ast.Constant):
            names[target.id] = value.value
    if not isinstance(domains, list):
        sys.exit("embed-fixer: DOMAINS not found")

    sites = []
    for domain in domains:
        if domain.get("enabled_by_default", True) is False:
            continue
        services = []
        for method in domain["fix_methods"]:
            if method.get("has_ads"):
                continue
            fixes = []
            for fix in method["fixes"]:
                if fix["_type"] == "ReplaceFix":
                    fixes.append({"from": fix["old_domain"], "to": fix["new_domain"]})
                elif fix["_type"] == "AppendURLFix":
                    fixes.append({"wrap": fix["domain"]})
                else:
                    sys.exit(f"embed-fixer: unknown fix {fix['_type']}")
            services.append(
                {
                    "id": method["id"],
                    "name": method["name"],
                    "default": bool(method.get("default")),
                    "fixes": fixes,
                }
            )
        if not services:
            continue
        # The bot's default first (or its first one), then the rest in order.
        default = next((s for s in services if s["default"]), services[0])
        services = [default] + [s for s in services if s is not default]
        patterns = []
        for website in domain["websites"]:
            skip = website.get("skip_method_ids") or []
            patterns.append({"pattern": website["_0"], "skip": skip})
        sites.append(
            {
                "id": str(domain["id"]).split(".")[-1].lower(),
                "name": domain["name"],
                "patterns": patterns,
                "services": services,
            }
        )
    if not any(site["id"] == "twitter" for site in sites):
        sys.exit("embed-fixer: no Twitter/X entry; the format changed?")
    return {"source": f"https://github.com/{EMBED_FIXER_REPO}", "commit": commit, "sites": sites}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--embed-fixer-commit", default=EMBED_FIXER_DEFAULT_COMMIT)
    args = parser.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    data, digest = clear_urls()
    (OUT / "clearurls.json").write_bytes(data)
    fixers = embed_fixers(args.embed_fixer_commit)
    (OUT / "embed_fixers.json").write_text(json.dumps(fixers, indent=1) + "\n")

    today = datetime.date.today().isoformat()
    (OUT / "SOURCES.md").write_text(
        f"""# Link filters

Bundled with Conest to clean links in messages. Refreshed with
`tool/update_link_filters.py`; nothing is downloaded at runtime.

## clearurls.json

- Source: {CLEARURLS_DATA}
- SHA-256: {digest} (matches {CLEARURLS_HASH})
- Fetched: {today}
- The ClearURLs rules, https://github.com/ClearURLs/Rules, by Kevin Röbert
  and contributors, under the GNU Lesser General Public License v3.0
  (https://www.gnu.org/licenses/lgpl-3.0.html). The file is unchanged.

## embed_fixers.json

- Source: https://github.com/{EMBED_FIXER_REPO} at {args.embed_fixer_commit},
  `embed_fixer/fixes.py`
- Fetched: {today}
- Which embed-fixing services exist for which sites, as listed by the
  embed-fixer bot (AGPL-3.0). Only these facts are taken, not its code.
  Services that show ads, and sites it leaves off by default, are left
  out. Each service belongs to its own operator.
"""
    )
    print(f"clearurls.json: {len(data)} bytes, sha256 {digest}")
    print(f"embed_fixers.json: {len(fixers['sites'])} sites")


if __name__ == "__main__":
    main()
