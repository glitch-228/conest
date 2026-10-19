# Tor bridges

Where Tor itself is blocked, it can still be reached through a bridge: a
Tor relay that is not listed publicly. The bridges built into Tor are
public and are usually blocked too, so get your own from the Tor
Project.

## Getting bridges

Ask for obfs4 or webtunnel bridges in any of these ways:

- **Website:** open bridges.torproject.org (through a VPN or another
  network if it is blocked where you are).
- **Telegram:** write to @GetBridgesBot.
- **Email:** write to bridges@torproject.org from a Gmail or Riseup
  address.
- **A friend:** someone you trust who uses Tor can share a bridge line
  they use.

You get one or more lines that start with the bridge type, for example
`obfs4 ...` or `webtunnel ...`.

## Using them in Conest

1. Open Settings > Connectivity > Tor.
2. Paste the bridge lines into the bridges field, one per line.
3. Turn Tor on, or tap "Use these bridges" if it is already on.

When Tor looks blocked and no bridges are set, the Tor settings say so
and show these same steps.
