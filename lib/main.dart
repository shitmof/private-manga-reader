import 'package:flutter/material.dart';

import 'app.dart';
import 'data/app_database.dart';
import 'data/library_repository.dart';
import 'services/backup_service.dart';
import 'services/archive_import_service.dart';
import 'services/import_service.dart';
import 'services/storage_service.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = StorageService();
  await storage.initialize();
  final database = AppDatabase();
  final repository = LibraryRepository(database);
  final importer = ImportService(repository, storage);
  final controller = AppController(
    repository,
    storage,
    importer,
    ArchiveImportService(repository, storage, importer),
    BackupService(repository, storage),
  );
  await controller.initialize();
  runApp(PrivateShelfApp(controller: controller));
}
