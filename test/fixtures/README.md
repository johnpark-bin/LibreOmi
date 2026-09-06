# Replay fixtures (LO-31)

`FakeOmiDevice` (`lib/device/fake_omi_device.dart`) replays a recorded BLE session so
tests, and manual debugging, can exercise the same code paths as a real device without
hardware. This directory holds those recordings.

**File extension: `.jsonl`.** (`docs/03-architecture.md` §7 currently says
`test/fixtures/*.bin`; that is stale — this README is the source of truth for the
fixture format until the docs pass that owns `docs/` catches up.)

## Format

JSON Lines: one JSON object per line, no trailing commas, no enclosing array.

```
{"t": <int>, "ch": "audio"|"button"|"battery"|"storage", "b": "<base64>"}
```

- `t` — milliseconds since the start of the session. Relative to the **first line** of
  the file (the first line does not have to be `t: 0`, but conventionally is).
  Values across the file must be monotonically non-decreasing.
- `ch` — which notification channel the payload came from:
  - `"audio"` — the audio-data-stream characteristic.
  - `"button"` — the button-trigger characteristic.
  - `"battery"` — the battery-level characteristic.
  - `"storage"` — the storage-data-stream characteristic.
- `b` — base64 of the **raw notification payload, exactly as the device sent it**,
  header bytes included. For `audio` this is the full `[packetIndex lo][packetIndex
  hi][frameIndex][payload…]` notification (see `docs/05-omi-ble-protocol.md`
  "Audio"), not just the stripped payload. For `battery` this is the single raw
  battery byte. For `button` it is the raw ≥4-byte button payload (see
  `docs/05-omi-ble-protocol.md` "Button events"). For `storage` it is a raw storage
  notification of any of the lengths `parseStoragePacket` understands.

Blank lines are ignored. A line that fails to parse (malformed JSON, missing field,
invalid base64) is **skipped**, not fatal — a capture killed mid-write (app backgrounded,
crash, force-quit) must still replay everything captured before the truncated line.

## Producing a fixture from a real device

Turn on Settings → Developer → "Capture BLE session" before connecting. While the
toggle is on, every connected device's audio, button, battery and storage
notifications are written as `.jsonl` lines to a `ble_session_<timestamp>.jsonl` file
in the app's support directory (`path_provider`'s `getApplicationSupportDirectory()`).
Pull that file off the device/emulator and copy it into this directory (or wherever a
test wants to load it from) to use it as a replay fixture.

## Hand-writing a fixture

Because the format is plain JSON lines, small fixtures are easy to write by hand — see
`omi_session_minimal.jsonl` for a fully hand-readable example. To hand-encode a
payload: take the raw bytes as a Dart/Python list of ints and base64-encode them, e.g.
in Python:

```python
import base64
base64.b64encode(bytes([0x01, 0x00, 0x00, 0x00])).decode()  # button: single tap
```

## `omi_session_synthetic.jsonl`

A larger, generated fixture (not hand-written — produced with a throwaway script, only
the resulting `.jsonl` is committed) used by `test/device/fake_omi_device_test.dart`:

- 200 audio packets (~2 s at the Opus codec's 100 frames/second), each 83 bytes:
  `[packetIndex lo][packetIndex hi][frameIndex][80 payload bytes]`. `packetIndex`
  runs 0 to 200 with 100 missing (as a little-endian uint16 split across the first
  two bytes), `frameIndex` cycles `0, 1, 0, 1, …`, and the payload bytes are derived
  from the packet index (not all-zero) so a truncation or off-by-one bug in a parser
  is visible in the payload contents, not just the length.

  LO-31 originally called for ~20 s of audio. 2 s was kept instead: at 100 fps a
  20-second fixture is 2000 lines, which defeats the reason this format was chosen
  over an opaque `.bin` — that a fixture can be read and reviewed in a diff. Nothing
  the replay test asserts (frame count, ordering, header strip, gap detection) gets
  stronger with ten times the packets. A real 20-second capture from hardware, made
  with the Settings → Developer toggle, is the owner's follow-up.
- **`packetIndex` 100 is deliberately skipped** (the sequence jumps `99` → `101`) so
  that gap-detection logic (`docs/05-omi-ble-protocol.md` "Audio": "LibreOmi should
  log gaps... as a BLE health metric") has a real gap to find.
- One `button` event with payload `01 00 00 00` (single tap) and one with
  `02 00 00 00` (double tap), interleaved among the audio events at plausible `t`
  values.

  A capture made by the in-app toggle re-encodes each button notification from the
  decoded `ButtonEvent` back to `[code, 0, 0, 0]`, because `OmiDevice.buttonEvents`
  only exposes the decoded enum. For the five documented codes that is byte-identical
  to what the device sent; for an undocumented code it records `00 00 00 00`, losing
  which unknown code arrived. If you are capturing specifically to investigate an
  unrecognised button code, read the raw bytes off `BleService.buttonStream` instead.
- Two `battery` events, `96` then `95`.
- `t` values are monotonically non-decreasing throughout, with audio packets spaced
  ~10 ms apart (matching the codec's 100 fps).

## `omi_session_minimal.jsonl`

A handful of hand-written lines (one of each channel) kept small enough to read in
full at a glance — the fixture this README's hand-writing example refers to.
