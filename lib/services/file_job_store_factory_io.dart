import 'file_job_store.dart';
import 'file_job_store_io.dart';

/// Received files survive app restarts.
FileJobStore createFileJobStore() => FileJobStoreIo();
