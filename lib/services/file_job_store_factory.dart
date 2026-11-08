/// Platform-appropriate [FileJobStore], chosen at compile time (the io
/// variant imports `dart:io`, which would break the web build).
library;

export 'file_job_store_factory_stub.dart'
    if (dart.library.io) 'file_job_store_factory_io.dart';
