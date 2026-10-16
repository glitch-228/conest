"""CI-only behavioral negative checks for hostile BLE input. Never run locally."""
from pathlib import Path
import subprocess

path = Path("native/conest_native/src/ble/core.rs")


def check(before, after, test, path=path):
    original = path.read_text()
    assert original.count(before) == 1, f"Sabotage anchor changed: {before}"
    try:
        broken = original.replace(before, after)
        if before == "payload > MAX_PACKET":
            broken = broken.replace("if size > MAX_PACKET {", "if false {")
        path.write_text(broken)
        result = subprocess.run(
            ["cargo", "test", "-p", "conest_native", "--locked", test],
            capture_output=True, text=True)
        assert result.returncode != 0 and "test result: FAILED" in result.stdout, (
            f"Test did not detect sabotage: {test}\n{result.stdout}\n{result.stderr}")
        print(f"PASS negative check: {test}")
    finally:
        path.write_text(original)


check("link.queued_bytes + bytes.len() > MAX_QUEUE_BYTES", "false",
      "ble::core::tests::link_table_and_queue_limits")
check("old.role == role || role != preferred", "true",
      "ble::core::tests::crossed_links_converge_and_stale_callbacks_cannot_remove_replacement")
check("size == Some(self.bytes.len())", "false && size == Some(self.bytes.len())",
      "ble::core::tests::packets_split_at_every_boundary_including_padding_and_routes")
check("payload > MAX_PACKET", "false",
      "ble::core::tests::rejects_oversize_malformed_and_expired_partial_packets")
check("link.packets > MAX_PACKETS_PER_SECOND", "false",
      "ble::core::tests::notification_flood_and_event_buffer_are_bounded")
check("self.events.len() >= MAX_EVENTS", "false",
      "ble::core::tests::notification_flood_and_event_buffer_are_bounded")

callbacks = Path("native/conest_native/src/ble/callbacks.rs")
check("self.inspect(shared, adapter, available_workers, Some(key), admit)\n            .await", "Ok(0)",
      "ble::callbacks::tests::first_write_refreshes_subscription_before_delivery", callbacks)
check("complete = false;", "return Err(result.err().unwrap());",
      "ble::callbacks::tests::vanished_subscriber_does_not_reset_healthy_links", callbacks)
check("if !shared.core().ready(id, limit)", "if true",
      "ble::callbacks::tests::callbacks_during_cccd_setup_can_deliver_the_first_packet", callbacks)
check("admit(id, client);", "drop(client);",
      "ble::callbacks::tests::cancelled_refresh_never_leaves_a_ready_link_without_a_writer", callbacks)
check("if wanted.is_some_and(|wanted| wanted != key)", "if false",
      "ble::callbacks::tests::first_write_never_waits_for_unrelated_slow_subscribers", callbacks)
check("let mut complete = wanted.is_none();", "let mut complete = true;",
      "ble::callbacks::tests::first_write_never_waits_for_unrelated_slow_subscribers", callbacks)
check("self.next = (index + 1) % count;", "self.next = 0;",
      "ble::callbacks::tests::periodic_refresh_progresses_past_a_permanently_slow_first_peer", callbacks)
