import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      // Screens offer explicit retry buttons instead of silent retries.
      retry: (retryCount, error) => null,
      child: const ProgenApp(),
    ),
  );
}
