# File Transfer

MeshCore Open can send a file over the radio to everyone on a channel. The file travels as channel GRP_DATA packets (data type `0xF11E`) and is checked with a CRC-32 before it is shown as received. Lost packets are resent on request, so a file arrives intact or not at all.

## Requirements

- Companion firmware version code **11 or later** (the same channel-data layout as image messages). No firmware change is needed.
- A channel shared only with the recipient. Everyone who holds the channel secret receives the file, and the channel secret is the only encryption.

## Send a file

1. Open a channel chat and choose **Send file over radio** from the composer actions.
2. Pick a file (up to 128 KB). The dialog shows the packet count and, once the radio settings are known, a rough time estimate that excludes resends.
3. Progress appears in the banner above the composer. **File transfers** lists every transfer and lets you cancel a running one.

A transfer ends as *Delivered and verified* once a receiver reports a complete copy, or as *Failed* after 12 rounds without confirmation.

## Receive a file

An incoming file shows as a banner on its channel and in the **File transfers** list. When it is complete and verified, tap **Save**: a save dialog on desktop, the share sheet elsewhere. Received files are kept in memory only and are gone after the app restarts.

## Airtime

A packet carries 157 file bytes. At typical settings one pass of a 30 KB file is on the order of minutes, and regional duty-cycle limits can stretch it well beyond that. Repeaters forward every packet, which uses airtime on the whole mesh. Prefer small files.

## Implementation reference

- [file_transfer_protocol.dart](../lib/services/file_transfer_protocol.dart): wire format, chunking, reassembly. Pure Dart.
- [file_transfer_engine.dart](../lib/services/file_transfer_engine.dart): retransmission rounds, STATUS replies, job tracking. Pure Dart.
- [file_transfer_service.dart](../lib/services/file_transfer_service.dart): `ChangeNotifier` wrapper and pacing, wired in `main.dart` and `MeshCoreConnector`.
- Tests: `test/file_transfer_protocol_test.dart`, `test/file_transfer_engine_test.dart`.
