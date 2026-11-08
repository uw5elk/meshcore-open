import 'file_job_store.dart';

/// Web: files live only for the lifetime of the tab.
FileJobStore createFileJobStore() => InMemoryFileJobStore();
