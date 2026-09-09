## Conest 0.3.9 nightly

### Iroh connections and file transfers

- Messaging and files can use Iroh discovery and relay fallback without a
  custom Conest relay. LAN remains preferred when available.
- Gives Iroh connection setup 30 seconds instead of the previous 4-second
  transport timeout, allowing discovery and connection establishment time
  to complete.
- Adds a recommended 100 MiB Iroh file limit, enabled by default in Settings.
  It applies to both direct and relayed Iroh transfers. Larger files can use
  LAN, or both peers can disable the limit to allow larger Iroh transfers.
- Large Iroh transfers can still be slow; the limit is a practical default,
  not a throughput improvement.
- Fixes Iroh contact presence and delivery receipts: transport acceptance
  alone no longer marks a message as delivered to its recipient.

### LAN transfers and responsiveness

- Uses the existing LAN messaging port for attachment ingress, avoiding
  random file ports that may be blocked by a firewall.
- Uses larger binary blocks for manual transfers, moves hashing and block
  processing off the UI isolate, and reduces progress/checkpoint overhead.
- Improves endpoint recovery, retry backoff, verification heartbeats, and
  transfer timing to reduce stalls and misleading acknowledgement timeouts.
- Raises the LAN byte budget that previously throttled sustained transfers.

### Storage and debug testing

- Adds a setting to disable the default 10% free-space reserve, plus a
  per-file Download Anyway option when the file fits but would use the reserve.
- Matching debug builds support LAN and Iroh file matrices, negotiate the
  selected transport and peer size limits, and stop before generating files
  above the negotiated Iroh limit. Debug test controls remain debug-only.

### Validation

- Flutter: 302 tests passed, with 4 opt-in tests skipped; analysis passed.
- Separate native transfer checks passed for 1000/2000 MiB LAN transfers
  with the Iroh limit enabled and 250 MiB Iroh with the limit disabled.
- Rust workspace: 56 tests passed for the preceding transport changes.
- A native public-Iroh discovery/relay test passed with direct IP transport
  disabled. Android/Linux device testing also confirmed online transfers;
  large-file performance and network transitions still need device testing.

Update both peers to this nightly to use the matching transfer fixes and
negotiate the Iroh file limit. The 30 MiB default Conest store-forward limit
remains separate from the Iroh limit.
