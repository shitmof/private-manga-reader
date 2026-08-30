import 'package:flutter/material.dart';

import 'app.dart';
import 'data/app_database.dart';
import 'data/library_repository.dart';
import 'data/network_repository.dart';
import 'services/backup_service.dart';
import 'services/archive_import_service.dart';
import 'services/import_service.dart';
import 'services/incoming_archive_service.dart';
import 'services/local_mount_service.dart';
import 'services/network_credential_store.dart';
import 'services/network_library_service.dart';
import 'services/storage_service.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache
    ..maximumSize = 120
    ..maximumSizeBytes = 96 * 1024 * 1024;
  final storage = StorageService();
  await storage.initialize();
  final database = AppDatabase();
  final repository = LibraryRepository(database);
  final networkRepository = NetworkRepository(database);
  final importer = ImportService(repository, storage);
  final archiveImporter = ArchiveImportService(repository, storage, importer);
  final networkLibrary = NetworkLibraryService(
    networkRepository,
    storage,
    archiveImporter,
    SecureNetworkCredentialStore(),
  );
  final controller = AppController(
    repository,
    storage,
    importer,
    archiveImporter,
    BackupService(repository, storage),
    networkRepository,
    networkLibrary,
    incomingArchiveService: IncomingArchiveService(),
    localMountService: LocalMountService(networkRepository),
  );
  await controller.initialize();
  runApp(PrivateShelfApp(controller: controller));
}
