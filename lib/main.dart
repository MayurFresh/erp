import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/error_handling.dart';
import 'features/construction/data/image_picker_photo_source.dart';
import 'features/construction/data/photo_source.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  installGlobalErrorHandlers();
  runApp(
    ProviderScope(
      // Screens offer explicit retry buttons instead of silent retries.
      retry: (retryCount, error) => null,
      overrides: [
        photoSourceProvider.overrideWithValue(ImagePickerPhotoSource()),
      ],
      child: const ProgenApp(),
    ),
  );
}
