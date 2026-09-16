A native macOS app that shows the multicast actually flowing on a network
segment, labelled in the terms an AV operator uses: **"sACN universe 12"**, not
`239.255.0.12`.

## Install

Download `MulticastView-VERSION.zip` below, unzip, and move the app where you like.

The app is **unsigned and un-notarised by design** — raw packet capture is
impossible in an App Sandbox, and signing for distribution needs a paid Apple
Developer Program membership. A browser download is quarantined, so macOS will
refuse to open it. To open it anyway, either:

- **macOS 15 and later** — double-click it once and let it be blocked, then go to
  **System Settings → Privacy & Security**, scroll to the bottom, and click
  **Open Anyway**. (Apple removed the old Control-click → Open bypass in
  macOS 15; on macOS 13 and 14 that shortcut still works.)
- **Any version** — clear the quarantine attribute directly:

  ```bash
  xattr -dr com.apple.quarantine /path/to/MulticastView.app
  ```

Or skip all of that and
[build from source](https://github.com/elliotmatson/multicast-view#build-it-yourself):
a locally built app is never quarantined and simply opens.

## Capture privileges

Reading packets needs access to `/dev/bpf*`, which macOS restricts to the
`access_bpf` group. Install **Wireshark's ChmodBPF helper** and log out and back
in. The app detects the problem and explains it rather than just failing.

## Requirements

macOS 13 or later. To see past your own port you need a SPAN/mirror port or a
tap — plugged into an ordinary wall port you will see very little, and that is
correct behaviour, not a fault.

## Known limits

- Layer-2-only protocols (SoundGrid, CobraNet, AVB/Milan) are invisible: they
  are not IP, and the capture filter accepts IPv4 multicast only.
- The SNMP half has never been exercised against a real agent. Its BER encoding,
  GetBulk walk and PortList decoding are covered by byte-level unit tests only,
  and not every switch exposes multicast forwarding over SNMP at all.
- Interface removal mid-capture is handled in code but untested.

See the [README](https://github.com/elliotmatson/multicast-view#readme) for what
it does and how it is put together.
