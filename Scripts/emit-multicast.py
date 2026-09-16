#!/usr/bin/env python3
"""Emit realistic AV multicast so MulticastView can be exercised without an AV
network attached.

Sends real packets, at realistic sizes and rates, to the real group addresses
and ports each protocol uses, and performs real IGMP joins so membership
reports appear in the app's IGMP log.

    ./Scripts/emit-multicast.py --interface en7
    ./Scripts/emit-multicast.py --interface en7 --profile sacn --universes 4
    ./Scripts/emit-multicast.py --address 192.0.2.10 --duration 60

Nothing here needs root. It cannot generate IGMP *queries* (those need a raw
socket), so the querier diagnostics are exercised by a real switch, not by this.
"""

import argparse
import os
import random
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

STOP = threading.Event()


def interface_address(name):
    """macOS reports an interface's IPv4 address through ipconfig."""
    try:
        out = subprocess.run(["ipconfig", "getifaddr", name],
                             capture_output=True, text=True, timeout=5)
        address = out.stdout.strip()
        return address or None
    except Exception:
        return None


def make_sender(source_address, ttl):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Binding to the interface address matters on macOS: with IP_MULTICAST_IF
    # alone, a host with no route for 224.0.0.0/4 answers sendto with
    # EHOSTUNREACH ("No route to host").
    sock.bind((source_address, 0))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, struct.pack("b", ttl))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                    socket.inet_aton(source_address))
    # Do not loop back to this host; we are testing what goes on the wire.
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    return sock


class Stream(threading.Thread):
    """One sender, paced to a target packet rate."""

    def __init__(self, label, group, port, payload_size, packets_per_second,
                 source_address, ttl=16, builder=None):
        super().__init__(daemon=True, name=label)
        self.label = label
        self.group = group
        self.port = port
        self.payload_size = payload_size
        self.rate = packets_per_second
        self.source_address = source_address
        self.ttl = ttl
        self.builder = builder
        self.sent = 0

    def run(self):
        sock = make_sender(self.source_address, self.ttl)
        interval = 1.0 / self.rate
        next_send = time.monotonic()
        sequence = 0
        while not STOP.is_set():
            payload = (self.builder(sequence) if self.builder
                       else bytes(random.getrandbits(8) for _ in range(min(16, self.payload_size)))
                            * (self.payload_size // min(16, self.payload_size) + 1))[:self.payload_size]
            try:
                sock.sendto(payload, (self.group, self.port))
                self.sent += 1
            except OSError as error:
                print(f"  {self.label}: {error}", file=sys.stderr)
                time.sleep(0.5)
            sequence = (sequence + 1) & 0xFFFF

            next_send += interval
            delay = next_send - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            else:
                # Fell behind; resynchronise rather than spiral.
                next_send = time.monotonic()
        sock.close()


# ---- payload builders ------------------------------------------------------

def sacn_packet(universe):
    """An E1.31 data packet: root layer, framing layer, DMP layer, 512 slots.
    638 bytes on the wire, which is what a real console sends."""
    def build(sequence):
        packet = bytearray()
        packet += struct.pack(">HH", 0x0010, 0x0000)          # preamble
        packet += b"ASC-E1.17\x00\x00\x00"                     # ACN packet identifier
        packet += struct.pack(">H", 0x7000 | 0x026E)           # root flags/length
        packet += struct.pack(">I", 0x00000004)                # vector: E1.31 data
        packet += bytes(16)                                    # sender CID
        packet += struct.pack(">H", 0x7000 | 0x0258)           # framing flags/length
        packet += struct.pack(">I", 0x00000002)                # vector: data packet
        packet += b"MulticastView test".ljust(64, b"\x00")     # source name
        packet += bytes([100])                                 # priority
        packet += struct.pack(">H", 0)                         # sync address
        packet += bytes([sequence & 0xFF])                     # sequence
        packet += bytes([0])                                   # options
        packet += struct.pack(">H", universe)
        packet += struct.pack(">H", 0x7000 | 0x0205)           # DMP flags/length
        packet += bytes([0x02, 0xA1])                          # vector, address type
        packet += struct.pack(">HHH", 0x0000, 0x0001, 0x0201)  # first addr, inc, count
        packet += bytes([0])                                   # DMX start code
        # A slowly moving chase, so the sparkline is not a flat line.
        packet += bytes([(sequence + channel) & 0xFF for channel in range(512)])
        return bytes(packet)
    return build


def rtp_packet(payload_type, payload_size):
    """An RTP packet as AES67 and ST 2110 send them."""
    def build(sequence):
        header = bytearray()
        header += bytes([0x80, payload_type & 0x7F])
        header += struct.pack(">H", sequence)
        header += struct.pack(">I", (sequence * 48) & 0xFFFFFFFF)   # timestamp
        header += struct.pack(">I", 0x11223344)                     # SSRC
        return bytes(header) + bytes(payload_size)
    return build


def ptp_packet(message_type, sequence_offset=0):
    """A PTPv2 header, so the app's classifier sees a plausible packet."""
    def build(sequence):
        packet = bytearray(44)
        packet[0] = message_type            # 0x00 Sync, 0x08 Follow_Up, 0x0b Announce
        packet[1] = 0x02                    # PTP version 2
        struct.pack_into(">H", packet, 2, 44)
        packet[4] = 0                       # domain 0
        struct.pack_into(">H", packet, 30, (sequence + sequence_offset) & 0xFFFF)
        packet[32] = 0x00                   # control
        packet[33] = 0x7F                   # log message interval
        return bytes(packet)
    return build


# ---- IGMP joins ------------------------------------------------------------

def join_groups(groups, source_address):
    """Real IP_ADD_MEMBERSHIP joins, which make the kernel emit real IGMP
    membership reports on the wire."""
    sockets = []
    for group in groups:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("", 0))
            request = socket.inet_aton(group) + socket.inet_aton(source_address)
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, request)
            sockets.append((sock, group, request))
        except OSError as error:
            print(f"  could not join {group}: {error}", file=sys.stderr)
    return sockets


def leave_groups(sockets):
    for sock, group, request in sockets:
        try:
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_DROP_MEMBERSHIP, request)
        except OSError:
            pass
        sock.close()


# ---- profiles --------------------------------------------------------------

def build_streams(profile, address, universes, scale):
    streams = []

    if profile in ("all", "sacn", "lighting"):
        for index in range(universes):
            universe = index + 1
            group = f"239.255.{universe // 256}.{universe % 256}"
            streams.append(Stream(f"sACN universe {universe}", group, 5568, 638,
                                  44 * scale, address, ttl=16,
                                  builder=sacn_packet(universe)))
        # One universe deliberately sent with TTL 1, which is the classic
        # "works on one VLAN, not the other" fault the app flags.
        streams.append(Stream("sACN universe 99 (TTL 1)", "239.255.0.99", 5568, 638,
                              44 * scale, address, ttl=1, builder=sacn_packet(99)))

    if profile in ("all", "aes67", "audio"):
        # 48 kHz, 8 channels, 24-bit, 1 ms packets: 1152 bytes of audio.
        streams.append(Stream("AES67 8ch", "239.69.1.10", 5004, 1152,
                              200 * scale, address, ttl=16,
                              builder=rtp_packet(98, 1152)))
        streams.append(Stream("AES67 2ch", "239.69.1.11", 5004, 288,
                              200 * scale, address, ttl=16,
                              builder=rtp_packet(97, 288)))
        streams.append(Stream("RTCP", "239.69.1.10", 5005, 64, 1, address, ttl=16))

    if profile in ("all", "dante", "audio"):
        streams.append(Stream("Dante flow 1", "239.255.10.20", 4321, 1024,
                              200 * scale, address, ttl=16))
        streams.append(Stream("Dante flow 2", "239.255.10.21", 4321, 512,
                              200 * scale, address, ttl=16))
        streams.append(Stream("Dante control", "224.0.0.231", 8702, 96, 4, address, ttl=1))

    if profile in ("all", "ptp", "clock"):
        streams.append(Stream("PTP Sync", "224.0.1.129", 319, 44, 8, address, ttl=1,
                              builder=ptp_packet(0x00)))
        streams.append(Stream("PTP Follow_Up", "224.0.1.129", 320, 44, 8, address, ttl=1,
                              builder=ptp_packet(0x08)))
        streams.append(Stream("PTP Announce", "224.0.1.129", 320, 64, 1, address, ttl=1,
                              builder=ptp_packet(0x0b, 1000)))

    if profile in ("all", "fragment"):
        # Larger than the 1500-byte MTU, so the kernel fragments it. Only the
        # first fragment carries a UDP header; the rest must be attributed to
        # this stream rather than appearing as a phantom on a garbage port.
        streams.append(Stream("Fragmented AES67", "239.69.2.10", 5004, 3000,
                              50 * scale, address, ttl=16,
                              builder=rtp_packet(98, 3000)))
        streams.append(Stream("Fragmented big", "239.69.2.11", 5004, 5000,
                              20 * scale, address, ttl=16,
                              builder=rtp_packet(98, 5000)))

    if profile in ("all", "video"):
        # A big ST 2110-ish essence stream, to give the chart something with a
        # different order of magnitude.
        streams.append(Stream("ST 2110 video", "239.100.1.1", 5004, 1400,
                              600 * scale, address, ttl=16,
                              builder=rtp_packet(96, 1400)))

    if profile in ("all", "control"):
        streams.append(Stream("Q-SYS Q-LAN", "239.192.0.5", 2048, 512, 50 * scale, address, ttl=16))
        streams.append(Stream("Crestron CIP", "239.1.1.10", 41794, 128, 2, address, ttl=16))
        streams.append(Stream("mDNS", "224.0.0.251", 5353, 180, 2, address, ttl=1))
        streams.append(Stream("SSDP", "239.255.255.250", 1900, 300, 1, address, ttl=1))

    return streams


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--interface", help="interface name to send from, e.g. en7")
    parser.add_argument("--address", help="source IPv4 address to send from (instead of --interface)")
    parser.add_argument("--duration", type=float, default=0,
                        help="seconds to run; 0 means until interrupted")
    parser.add_argument("--profile", default="all",
                        choices=["all", "sacn", "lighting", "aes67", "audio", "dante",
                                 "ptp", "clock", "video", "control", "fragment"])
    parser.add_argument("--universes", type=int, default=4, help="how many sACN universes")
    parser.add_argument("--scale", type=float, default=1.0,
                        help="multiply every packet rate, to push the capture harder")
    parser.add_argument("--no-join", action="store_true", help="skip the IGMP joins")
    args = parser.parse_args()

    address = args.address
    if not address and args.interface:
        address = interface_address(args.interface)
        if not address:
            print(f"error: {args.interface} has no IPv4 address", file=sys.stderr)
            return 1
    if not address:
        print("error: give --interface or --address", file=sys.stderr)
        return 1

    streams = build_streams(args.profile, address, args.universes, args.scale)
    if not streams:
        print("error: that profile produced no streams", file=sys.stderr)
        return 1

    print(f"Sending from {address} ({args.interface or 'by address'})")
    print(f"{len(streams)} streams, profile '{args.profile}'\n")
    total_pps = 0
    for stream in streams:
        print(f"  {stream.label:<28} {stream.group}:{stream.port:<6} "
              f"{stream.payload_size:>5} B  {stream.rate:>6.0f} pkt/s  TTL {stream.ttl}")
        total_pps += stream.rate
    estimated = sum((s.payload_size + 42) * s.rate * 8 for s in streams)
    print(f"\n  ~{total_pps:.0f} pkt/s, ~{estimated / 1e6:.1f} Mbit/s total\n")

    joined = []
    if not args.no_join:
        groups = sorted({stream.group for stream in streams})
        joined = join_groups(groups, address)
        print(f"Joined {len(joined)} groups (real IGMP membership reports)\n")

    def handle_signal(_signum, _frame):
        STOP.set()
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    for stream in streams:
        stream.start()

    started = time.monotonic()
    try:
        while not STOP.is_set():
            time.sleep(0.5)
            if args.duration and time.monotonic() - started >= args.duration:
                STOP.set()
    except KeyboardInterrupt:
        STOP.set()

    print("\nStopping...")
    for stream in streams:
        stream.join(timeout=2)
    if joined:
        leave_groups(joined)
        print("Left all groups (real IGMP leaves)")
    print(f"Sent {sum(s.sent for s in streams)} packets in {time.monotonic() - started:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
