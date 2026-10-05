"""A reference Reticulum peer for interop tests (official Python RNS).

Runs a Reticulum instance with a TCP server interface on the given port and
a SINGLE destination conest.carrier. Prints, one per line:
  READY <identity public key hex> <destination hash hex>
  ANNOUNCE <destination hash hex>     for each conest.carrier announce heard
  DATA <hex>                          for each packet delivered to it
On "send <public key hex> <data hex>" from stdin it encrypts the data to
that identity's conest.carrier destination and sends it; "announce"
announces its own destination.
"""
import os
import sys
import tempfile
import time

import RNS

port = int(sys.argv[1])
config_dir = tempfile.mkdtemp(prefix="rns_peer_")
with open(os.path.join(config_dir, "config"), "w") as f:
    f.write(f"""
[reticulum]
  enable_transport = yes
  share_instance = no
  panic_on_interface_error = yes
[logging]
  loglevel = 2
[interfaces]
  [[Test TCP Server]]
    type = TCPServerInterface
    enabled = yes
    listen_ip = 127.0.0.1
    listen_port = {port}
""")

reticulum = RNS.Reticulum(configdir=config_dir)
identity = RNS.Identity()
destination = RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, "conest", "carrier")
destination.set_proof_strategy(RNS.Destination.PROVE_NONE)


def on_packet(data, packet):
    print("DATA " + data.hex(), flush=True)


destination.set_packet_callback(on_packet)


class AnnounceHandler:
    aspect_filter = "conest.carrier"

    def received_announce(self, destination_hash, announced_identity, app_data):
        print("ANNOUNCE " + destination_hash.hex(), flush=True)


RNS.Transport.register_announce_handler(AnnounceHandler())
print("READY " + identity.get_public_key().hex() + " " + destination.hash.hex(), flush=True)

for line in sys.stdin:
    parts = line.split()
    if not parts:
        continue
    if parts[0] == "announce":
        destination.announce()
    elif parts[0] == "send":
        peer = RNS.Identity(create_keys=False)
        peer.load_public_key(bytes.fromhex(parts[1]))
        out = RNS.Destination(peer, RNS.Destination.OUT, RNS.Destination.SINGLE, "conest", "carrier")
        RNS.Packet(out, bytes.fromhex(parts[2])).send()
        print("SENT", flush=True)
    elif parts[0] == "quit":
        break
time.sleep(0.2)
