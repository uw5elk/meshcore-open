import 'dart:ui' show Rect;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import 'platform_info.dart';

/// Saves a file received over the mesh: a save dialog on desktop, the share
/// sheet elsewhere. [name] must already be sanitized (the transfer protocol
/// does that when it parses the OFFER). Returns false on failure; a cancelled
/// dialog is not one.
Future<bool> saveReceivedFile(
  Uint8List data,
  String name, {
  Rect? sharePositionOrigin,
}) async {
  final file = XFile.fromData(
    data,
    mimeType: 'application/octet-stream',
    name: name,
  );
  try {
    if (PlatformInfo.isDesktop) {
      final location = await getSaveLocation(suggestedName: name);
      if (location != null) await file.saveTo(location.path);
      return true;
    }
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [file],
        fileNameOverrides: [name],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
    return result.status != ShareResultStatus.unavailable;
  } catch (e) {
    debugPrint('file save failed: $e');
    return false;
  }
}
