# MulticastView

A native macOS app that shows the multicast actually flowing on a network
segment, labelled in the terms an AV operator uses: **"sACN universe 12"**, not
`239.255.0.12`.

Built for live and install AV networks — Dante audio, sACN lighting, NDI video,
PTP clock — where multicast misbehaviour shows up as dropouts and freezes during
a service that nobody can reproduce afterwards. Wireshark can tell you
everything if you already know what to look for; Dante Controller only knows
about Dante. This is one window that shows what is on the wire and says what
looks wrong.

[![CI](https://github.com/elliotmatson/multicast-view/actions/workflows/ci.yml/badge.svg)](https://github.com/elliotmatson/multicast-view/actions/workflows/ci.yml)
![Swift 5.8+](https://img.shields.io/badge/Swift-5.8%2B-orange)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![License MIT](https://img.shields.io/badge/License-MIT-green)

---

## What it does

Three sources, and **the interesting findings come from where they disagree**:

| Source | Answers | Needs |
|---|---|---|
| **BPF packet capture** | What is flowing, how fast, from whom, at what TTL | ChmodBPF, and a SPAN/mirror port to see past this host |
| **SNMP** (v2c, implemented natively) | Which switch ports each group is forwarded out of | SNMP read access |
| **Local memberships** | Which groups *this Mac* joined, on which interface | Nothing |

The disagreements are the diagnoses:

- Traffic in the capture, **no** switch ports in SNMP → the switch is *flooding*
  it, not forwarding it deliberately. Snooping is off or broken.
- Switch ports in SNMP, **no** traffic in the capture → a subscription with
  nothing behind it. Something is asking for a stream nobody is sending.
- A local join on an unexpected interface → the macOS routing trap (below).

### Identifying streams

Classification is by group address and destination port, and every label carries
a confidence level — `certain` when pinned by an IANA assignment or a
protocol-specific port, `likely` for a protocol's default, `guess` for range
membership alone. Low-confidence labels are drawn faded, so a wrong guess costs
you a glance at the port column and nothing more.

Recognised: sACN (E1.31), Art-Net, RDMnet, KiNET, Pathport · Dante audio /
control / clock, AES67, RAVENNA, SMPTE ST 2110, Q-SYS Q-LAN, Livewire+ ·
PTPv2, NTP · mDNS, SSDP, WS-Discovery/ONVIF, SLP, LLMNR, SAP/SDP, Shure ·
Crestron CIP/CTP, AMX ICSP, Harman HiQnet, KNXnet/IP, BACnet/IP · PIM, VRRP,
HSRP, GLBP, OSPF, RIP, EIGRP, IGMP, Auto-RP.

**sACN encodes its universe in the group address.** `239.255.<high>.<low>` →
universe `high × 256 + low`, valid 1–63999. The app decodes it and shows
"Universe 12".

**239.255.0.0/16 is shared** by Dante, NDI and sACN, so range membership alone
never produces a confident label there — only the port disambiguates.

Gear that uses an unregistered port can be labelled with your own rules under
**Settings → Protocols**; those are checked before the built-in catalogue.

### Diagnostics

- **Querier count**, judged **per VLAN**. There must be exactly one IGMP querier
  per VLAN; two competing ones flush membership tables unpredictably, which is
  exactly the irreproducible-dropout case. On a trunk every VLAN's querier
  appears in one capture, so counting them together would call a healthy network
  of ten VLANs ten competing queriers.
- **TTL 1 on a routable group** — won't cross a router, and the usual reason a
  stream works on one VLAN and not another. Not flagged for link-local
  (224.0.0.0/24), routing-plane traffic, or protocols like SSDP and PTP where a
  low TTL is correct.
- **Capture drops** — read from `BIOCGSTATS`. If the capture can't keep up,
  every rate shown is understated, and the app says so rather than lying.

### The session record

While capturing, a timeline is appended to
`~/Library/Application Support/MulticastView/Sessions/` as JSON Lines: stream
started/stopped, findings raised/cleared, querier changes, capture drops, and a
rate sample every ten seconds.

This is what answers *"the audio dropped out at 10:40 and nobody could reproduce
it at 2pm"*. Read it back with anything:

```bash
cd ~/Library/Application\ Support/MulticastView/Sessions
jq -r 'select(.kind!="sample") | "\(.time[11:19]) \(.kind) \(.summary)"' *.jsonl
```

```
19:06:54 sessionStart    Capture started on en7
19:06:55 findingRaised   TTL 1 on routable group 239.255.0.99:5568
19:06:55 streamAppeared  sACN (E1.31) · Universe 1 started — 239.255.0.1:5568
19:07:10 streamStopped   sACN (E1.31) · Universe 1 stopped — 239.255.0.1:5568
```

Discovery traffic (mDNS, SSDP, LLMNR) is left out of start/stop events: it goes
quiet between announcements and comes back, and that churn would bury the line
that matters. Sessions older than 30 days are pruned; each file is capped at
256 MB.

---

## Install

```bash
git clone https://github.com/elliotmatson/multicast-view.git
cd multicast-view
./Scripts/make-app.sh
open dist/
```

The app is **unsigned, un-notarised and unsandboxed by design**: raw packet
capture is impossible in a sandbox, and a privileged helper would need a paid
Developer ID. On first run, right-click → Open, or:

```bash
xattr -dr com.apple.quarantine dist/MulticastView.app
```

### Capture privileges

Reading packets needs access to `/dev/bpf*`, which macOS restricts to the
`access_bpf` group. Install **Wireshark's ChmodBPF helper** (from the Wireshark
installer, or `/Applications/Wireshark.app/Contents/Resources/Extras`), then log
out and back in. The app detects the problem and explains it rather than just
failing.

---

## Seeing more than your own port

Plugged into an ordinary wall port you will see almost nothing, and **that is
correct behaviour, not a bug** — a switch only sends a port the multicast that
port asked for.

To see a whole VLAN you need a **SPAN/mirror port** or a tap. Mirroring the
**uplink between two switches** is usually far more revealing than mirroring an
endpoint.

### The macOS routing trap

macOS joins multicast on the interface with the **lowest-metric default route**,
which is very often not the AV network. A Mac with Wi-Fi up and a Thunderbolt
adapter on the Dante VLAN will happily join over Wi-Fi and silently receive
nothing. The "this host joined on" column makes that visible immediately.

The interface picker also flags `awdl0` (Apple Wireless Direct Link — constant
chatter that buries real AV traffic, and the most common reason a Mac capture
looks unreadable), VPN tunnels, loopback and Wi-Fi.

---

## Development

```bash
swift build          # requires Xcode or a Swift 5.9+ toolchain
swift test
```

The package splits so that the logic is testable without a network or capture
privileges:

| Target | Contents |
|---|---|
| `MulticastCore` | Parsing, classification, aggregation, diagnostics, session log, SNMP/BER. No syscalls, no network. **190 tests.** |
| `CBPF` | C shim for BPF. `ioctl` is variadic and the `BIOC*` codes are macros; neither imports into Swift. |
| `MulticastSystem` | BPF capture, `getifmaddrs`, interface enumeration, SNMP transport, session writer. |
| `MulticastView` | The SwiftUI app. |

Tests use real byte-level fixtures — frames built by hand in the test, not
mocks. They cover every protocol the classifier knows, sACN universe decode at
its range boundaries, VLAN-tagged and QinQ frames, IP fragments alone and as an
ordered pair, all twelve IGMPv3 record-type × has-sources combinations,
aux-data skipping, a report lying about its record count, the Q-BRIDGE PortList
bitmap, the 23-bit IP→MAC collision, and BER integer/OID encoding across the
base-128 and 0x80 boundaries. The BPF filter is executed by a small interpreter
in the test suite, because a wrong jump offset does not fail — it silently
captures the wrong traffic.

### Exercising it without an AV network

```bash
./Scripts/emit-multicast.py --interface en7
./Scripts/emit-multicast.py --interface en7 --profile sacn --universes 8
./Scripts/emit-multicast.py --interface en7 --profile fragment
```

Sends real sACN, AES67, Dante-ish, PTP and ST 2110-ish traffic at realistic
sizes and rates, and performs real IGMP joins. No root, no dependencies beyond
the Python standard library.

### If `swift build` fails

`unable to lookup item 'PlatformPath'` means the machine has Command Line Tools
but no Xcode. SwiftPM 5.8 resolves the XCTest platform path at startup and dies
before compiling anything. `swiftc` itself is fine, so:

```bash
./Scripts/build-without-swiftpm.sh    # drives swiftc directly
./Scripts/test-without-swiftpm.sh     # same test files, XCTest shim
```

`make-app.sh` falls back to these automatically. Install Xcode or a Swift 5.9+
toolchain and plain `swift build` works unchanged.

---

## Known limits

- **Layer-2-only protocols are invisible.** SoundGrid, CobraNet and AVB/Milan
  (IEEE 1722) are not IP, and the capture filter accepts IPv4 multicast only.
- **Not every switch exposes multicast forwarding over SNMP.** Some expose very
  little of the Q-BRIDGE MIB and some expose none of it. Where that is the case
  the switch-port column stays empty however it is configured, and the two
  SNMP-dependent findings never fire — a limit of the switch, not a failed poll.
- **The SNMP path has never been exercised against a real agent.** Its BER
  encoding, GetBulk walk, termination rules and PortList decoding are covered by
  byte-level unit tests only.
- **SDVoE is not in the catalogue** — its multicast ports are not published in a
  form worth guessing at. Add a rule under Settings → Protocols for your
  deployment's group range.
- IGMP *queries* cannot be generated by the test script (they need a raw
  socket), so the querier diagnostics are exercised by real switches only.
- Interface removal mid-capture (unplugging a USB adapter) is handled in code
  but has not been tested.

## License

MIT — see [LICENSE](LICENSE).
