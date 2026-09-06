# 05 — Omi BLE protocol reference (as used by LibreOmi)

Sources: upstream `omibutfree/lib/services/ble_service.dart` (constants "extracted from
original app"), `BasedHardware/omi` `app/lib/services/devices/connectors/omi_connection.dart`,
and the React Native SDK. Items marked *observed* come from omibutfree's runtime
behaviour and should be re-verified against the firmware version you own
(shown in Device Settings → Firmware).

Since LO-30 the constants and the pure packet parsers described here live in
`lib/device/omi_gatt.dart` (unit-tested in `test/device/omi_gatt_test.dart`).
LO-31 deleted the `lib/services/ble/ble_protocol.dart` re-export shim and put
the `OmiDevice` / `OmiStorage` interfaces of `docs/03-architecture.md` §2 in
front of the transport.

## GATT services and characteristics

| Service | UUID | Characteristic | UUID | Props | Notes |
|---------|------|----------------|------|-------|-------|
| Omi main | `19b10000-e8f2-537e-4f6c-d104768a1214` | Audio data stream | `19b10001-…` | notify | audio packets |
| | | Audio codec | `19b10002-…` | read | 1 byte codec id |
| Battery (SIG) | `180f` | Battery level | `2a19` | read, notify | 0–100 |
| Device Info (SIG) | `180a` | Model `2a24`, Firmware `2a26`, Hardware `2a27`, Manufacturer `2a29` | | read | UTF-8 strings |
| Settings | `19b10010-e8f2-537e-4f6c-d104768a1214` | LED dim ratio | `19b10011-…` | read, write | 1 byte 0–100 |
| | | Mic gain | `19b10012-…` | read, write | 1 byte 0–100 |
| Speaker / haptic | `cab1ab95-2ea5-4f4d-bb56-874b72cfc984` | Speaker data | `cab1ab96-…` | write | 1 byte haptic level (*observed*: 1 = 20 ms, 2 = 50 ms, 3 = 500 ms) |
| Button | `23ba7924-0000-1000-7450-346eac492e92` | Button trigger | `23ba7925-…` | notify | 4+ bytes |
| Storage (SD card) | `30295780-4301-eabd-2904-2849adfeae43` | Storage data stream | `30295781-…` | write, notify | commands in, data out |
| | | Storage read control | `30295782-…` | read | list of int32 LE |

Scan filter: advertised name contains "omi" (case-insensitive). Filtering by service
UUID `19b10000-…` is also valid and more robust; do both.

## Audio

- Sample rate 16 kHz, mono.
- Codec id (read once after connect): `1` = PCM 8-bit? (`pcm8`, 160-byte frames),
  `20` = Opus 10 ms frames (160 samples, 80-byte payload, 100 fps),
  `21` = Opus 20 ms frames (`opusFS320`, 320 samples, 120-byte payload, 50 fps).
  Unknown ids default to `pcm8` upstream; LibreOmi should refuse to stream and show an error instead.
  (As of LO-12 `getAudioCodec()` still falls back to `pcm8` and only logs a warning —
  refusing to stream changes the public return type and is deferred to LO-14.)
- **Packet layout (notify):** `[packetIndex lo][packetIndex hi][frameIndex][payload…]`.
  Strip the first 3 bytes; the remainder is one Opus frame (or PCM).
  Omibutfree ignores packet index; LibreOmi should log gaps (`packetIndex` not
  incrementing by 1) as a BLE health metric.
- **MTU:** payload 80 B + 3 B header = 83 B notification. Android must call
  `requestMtu(512)` after connect (default 23 B truncates). iOS negotiates automatically.
- Deepgram accepts the raw Opus frames directly with `encoding=opus&sample_rate=16000`;
  local STT requires decoding to PCM16 first.

## Button events

Notification payload ≥ 4 bytes; first 4 bytes little-endian `uint32` state
(*observed* values, from omibutfree's handler):

| Value | Meaning (observed) | LibreOmi action |
|------:|--------------------|-----------------|
| 1 | single tap | toggle hold-to-ask (start / finish query) |
| 2 | double tap | save current conversation now |
| 3 | long-press start | ignore (newer firmware powers the device off) |
| 4 | single-tap release | ignore |
| 5 | long-press end | ignore |

Debounce: ignore events while a previous one is being processed.

## Storage (SD card) protocol

Read control characteristic → byte array parsed as consecutive int32 LE:
`[totalBytes, offsetBytes, …]`. Empty array ⇒ firmware has no storage service.

Write to storage data characteristic (6 bytes):
`[command, fileNumber, offset >> 24, offset >> 16, offset >> 8, offset & 0xFF]`
(offset **big-endian**).

| command | meaning |
|--------:|---------|
| 0 | start streaming file `fileNumber` from `offset` |
| 1 | clear / acknowledge file (delete on device) |
| 3 | stop current transfer (a single byte `0x03`, **not** the 6-byte payload) |

Since LO-50 the stop command has its own encoder (`buildStorageStopCommand()` in
`lib/device/omi_gatt.dart`) and its own transport call (`OmiStorage.stopRead()`),
because it is the one command that is not the 6-byte `[command, fileNumber, offset]`
shape. A cancelled sync sends it so the firmware stops streaming into a listener that
is already gone.

Responses on the data characteristic:

- 1-byte packets: `0` ready, `3` bad file size, `4` file empty, `100` transfer complete,
  anything else = error (*observed*).
- 83-byte packets: `[hdr0][hdr1][hdr2][len][data(len)…]` — one Opus frame (*observed*).
  `len` is the 4th byte, so at most 79 payload bytes actually fit. Upstream slices
  `value.sublist(4, 4 + value[3])` unguarded and throws a `RangeError` if the firmware
  ever reports a larger `len`; `parseStoragePacket` clamps to the bytes present instead.
- 440-byte packets: repeated `[len][data(len)]` records, `len == 0` is padding (*observed*).
  Upstream stops at `offset + 1 + len >= 440`, which discards a record that would end
  exactly on the last byte of the packet. `parseStoragePacket` reproduces that condition
  verbatim so LO-30 stays a no-behaviour-change refactor; correcting it needs a device to
  verify against and is deferred.
- Any other length is ignored (`StoragePacketKind.unknown`).

Local file format written by omibutfree (kept for compatibility):
`sdcard_audio_{codec}_16000_1_{unixStart}.bin` = repeated `[len int32 LE][opus frame]`.

Timing: firmware streams at roughly real time × N; omibutfree waits `seconds + 60` for
completion and 5 s for the first packet.

## Device settings

- Mic gain and LED dim are single unsigned bytes 0–100; read after connect, write on
  slider release.
- Battery: read on connect and every 60 s; also subscribe to notify if supported.

## Connection sequence (LibreOmi)

1. user-initiated: `connect(timeout 10 s, autoConnect: false, mtu: null)`, retrying
   GATT 133/257 up to 3× (1 s, 2 s). Saved device: `connect(autoConnect: true, mtu: null)`,
   which only *arms* the request — steps 2-6 then run when `connectionState` reports
   connected (`BleService._onConnectedSetup`).
2. Android: `requestMtu(512)` **before** `discoverServices()` (an unsolicited MTU update
   otherwise races discovery); refuse the session if the negotiated MTU is < 86. Then
   `requestConnectionPriority(high)` while streaming, `balanced` when idle. Both calls
   throw off Android, so they are Android-guarded.
3. `discoverServices()` **once**; cache characteristics by UUID
4. read codec, device info, battery; subscribe battery notify if present
   (as of LO-12 the reads are implemented but the battery *notify* subscription is not —
   `batteryStream` is only fed by polling callers; see LO-17)
5. subscribe button notify
6. probe storage control (presence ⇒ SD-card UI enabled)
7. subscribe audio notify only when a session starts; unsubscribe on stop
8. on disconnect: cancel every subscription, clear cache, schedule reconnect. The
   auto-connect listener is deliberately *not* cancelled — it is what observes the
   reconnection the OS performs on its own.
