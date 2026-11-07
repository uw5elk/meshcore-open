# File Transfer

MeshCore Open can send a file over the radio to everyone on a channel. The file travels as channel GRP_DATA packets (data type `0xF11E`) and is checked with a CRC-32 before it is shown as received. Lost packets are resent on request, so a file arrives intact or not at all.

## Requirements

- Companion firmware version code **11 or later** (the same channel-data layout as image messages). No firmware change is needed.
- A channel shared only with the recipient. Everyone who holds the channel secret receives the file, and the channel secret is the only encryption.

## Send a file

1. Open a channel chat and choose **Send file over radio** from the composer actions.
2. Pick a file (up to 512 KB, and at most 128 KB on the air). The file is zlib-compressed first when that makes it smaller, so text, logs and CSV shrink a lot while JPEG, ZIP and similar stay as they are. The dialog shows the original and compressed size, the packet count and, once the radio settings are known, a rough time estimate that excludes resends.
3. Progress appears in the banner above the composer. **File transfers** lists every transfer and lets you cancel a running one.

A transfer ends as *Delivered and verified* once a receiver reports a complete copy, or as *Failed* after 12 rounds without confirmation.

## Receive a file

An incoming file shows as a banner on its channel and in the **File transfers** list. When it is complete and verified, tap **Save**: a save dialog on desktop, the share sheet elsewhere. Received files are kept in memory only and are gone after the app restarts.

## Send a photo shrunk to a size

The attach menu also has **Send photo (shrink to size)**. Pick a photo, then a size (5, 10, 20, 40 or 80 KB; each shows a rough time). The app picks the largest picture size and then the highest JPEG quality that still fit, shows the result with a preview, and sends it as a normal `.jpg` file with the usual retransmission and confirmation. The receiver gets an ordinary JPEG to save. A JPEG already under the chosen size is sent untouched. If a photo cannot fit even at the smallest size, choose a larger one.

Decoding uses the engine's native decoder, scaled while decoding. Encoding uses the pure-Dart `image` package. The search itself is in [image_shrink.dart](../lib/services/image_shrink.dart) and is unit tested without Flutter.

## Compression

The OFFER flag `compressed` (bit 0) marks a zlib stream. The receiver inflates it with a hard cap of `kFileMaxOriginalBytes`, and a stream that is corrupt or expands beyond the cap fails the job. The CRC-32 covers the bytes on the air. Compression needs `dart:io`, so on web files are sent uncompressed and a compressed file cannot be opened.

## Airtime

A packet carries 157 file bytes. At typical settings one pass of a 30 KB file is on the order of minutes, and regional duty-cycle limits can stretch it well beyond that. Repeaters forward every packet, which uses airtime on the whole mesh. Prefer small files.

## Implementation reference

- [file_transfer_protocol.dart](../lib/services/file_transfer_protocol.dart): wire format, chunking, reassembly. Pure Dart.
- [file_transfer_engine.dart](../lib/services/file_transfer_engine.dart): retransmission rounds, STATUS replies, job tracking. Pure Dart.
- [file_transfer_service.dart](../lib/services/file_transfer_service.dart): `ChangeNotifier` wrapper and pacing, wired in `main.dart` and `MeshCoreConnector`.
- Tests: `test/file_transfer_protocol_test.dart`, `test/file_transfer_engine_test.dart`.
