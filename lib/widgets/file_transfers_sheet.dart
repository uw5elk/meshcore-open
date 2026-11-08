import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../helpers/snack_bar_builder.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../services/file_transfer_engine.dart';
import '../services/file_transfer_service.dart';
import '../utils/file_save.dart';

/// Localized one-line status of [job].
String fileJobStatusText(AppLocalizations l10n, FileTransferJob job) {
  switch (job.status) {
    case FileJobStatus.sending:
      return l10n.fileTransfer_status_sending(job.sentBlobs, job.totalBlobs);
    case FileJobStatus.waitingForStatus:
      return job.round == 0
          ? l10n.fileTransfer_status_sentAwaiting
          : l10n.fileTransfer_status_waiting(job.round + 1);
    case FileJobStatus.receiving:
      final total = job.totalChunks;
      return total == null
          ? l10n.fileTransfer_status_receivingUnknown
          : l10n.fileTransfer_status_receiving(job.receivedChunks, total);
    case FileJobStatus.delivered:
      return l10n.fileTransfer_status_delivered;
    case FileJobStatus.received:
      return l10n.fileTransfer_status_received;
    case FileJobStatus.failed:
      if (job.error == kFileErrorNoResponse) {
        return l10n.fileTransfer_status_noResponse;
      }
      return l10n.fileTransfer_status_failed(job.error ?? '');
    case FileJobStatus.cancelled:
      return l10n.fileTransfer_status_cancelled;
  }
}

/// Saves or shares a received file; shows a snack bar when that fails.
Future<void> saveFileJobToDevice(
  BuildContext context,
  FileTransferJob job,
) async {
  final data = job.data;
  if (data == null) return;
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  final l10n = context.l10n;
  final ok = await saveReceivedFile(
    data,
    job.name,
    sharePositionOrigin: origin,
  );
  if (!ok && context.mounted) {
    showDismissibleSnackBar(
      context,
      content: Text(l10n.fileTransfer_saveFailed),
    );
  }
}

/// Opens the list of file transfers.
Future<void> showFileTransfersSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _FileTransfersSheet(),
  );
}

/// Strip above the composer: the newest transfer on [channelIndex] that is
/// running or waiting to be saved. Tapping it opens the full list.
class FileTransferBanner extends StatelessWidget {
  final int channelIndex;

  const FileTransferBanner({super.key, required this.channelIndex});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<FileTransferService>();
    FileTransferJob? job;
    for (final j in service.jobs) {
      if (j.channelIndex != channelIndex) continue;
      if (j.isActive || j.status == FileJobStatus.received) {
        job = j;
        break;
      }
    }
    if (job == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final received = job.status == FileJobStatus.received;
    final jobId = job.id;
    return InkWell(
      onTap: () => showFileTransfersSheet(context),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          border: Border(
            bottom: BorderSide(color: scheme.outlineVariant, width: 1),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    received
                        ? l10n.fileTransfer_bannerReceived(job.name)
                        : l10n.fileTransfer_bannerActive(job.name),
                    style: Theme.of(context).textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    fileJobStatusText(l10n, job),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (job.isActive) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: job.fraction == 0 ? null : job.fraction,
                    ),
                  ],
                ],
              ),
            ),
            if (job.isActive)
              IconButton(
                tooltip: l10n.fileTransfer_cancel,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                onPressed: () => service.cancel(jobId),
              ),
          ],
        ),
      ),
    );
  }
}

class _FileTransfersSheet extends StatelessWidget {
  const _FileTransfersSheet();

  @override
  Widget build(BuildContext context) {
    final service = context.watch<FileTransferService>();
    final l10n = context.l10n;
    final jobs = service.jobs;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.fileTransfer_title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (jobs.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.fileTransfer_empty),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: jobs.length,
                  itemBuilder: (context, index) =>
                      _FileJobTile(job: jobs[index], service: service),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FileJobTile extends StatelessWidget {
  final FileTransferJob job;
  final FileTransferService service;

  const _FileJobTile({required this.job, required this.service});

  Future<void> _save(BuildContext context) async {
    final data = job.data;
    if (data == null) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final l10n = context.l10n;
    final ok = await saveReceivedFile(
      data,
      job.name,
      sharePositionOrigin: origin,
    );
    if (!ok && context.mounted) {
      showDismissibleSnackBar(
        context,
        content: Text(l10n.fileTransfer_saveFailed),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final canSave = job.status == FileJobStatus.received && job.data != null;
    return ListTile(
      leading: Icon(job.outgoing ? Icons.upload_file : Icons.download),
      title: Text(
        job.name.isEmpty ? '…' : job.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(fileJobStatusText(l10n, job)),
          if (job.isActive) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: job.fraction == 0 ? null : job.fraction,
            ),
          ],
        ],
      ),
      trailing: job.isActive
          ? IconButton(
              tooltip: l10n.fileTransfer_cancel,
              icon: const Icon(Icons.close),
              onPressed: () => service.cancel(job.id),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canSave)
                  IconButton(
                    tooltip: l10n.fileTransfer_save,
                    icon: const Icon(Icons.save_alt),
                    onPressed: () => _save(context),
                  ),
                IconButton(
                  tooltip: l10n.fileTransfer_dismiss,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => service.dismiss(job.id),
                ),
              ],
            ),
    );
  }
}
