import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Logs uncaught framework and platform errors and, in release builds,
/// replaces the red error screen with a friendly card.
void installGlobalErrorHandlers({bool? release}) {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    debugPrint('FlutterError: ${details.exceptionAsString()}');
    if (previous != null) previous(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught: $error\n$stack');
    return true;
  };
  if (release ?? kReleaseMode) {
    ErrorWidget.builder = (details) => const FriendlyErrorCard();
  }
}

/// Shown instead of a widget that failed to build.
class FriendlyErrorCard extends StatelessWidget {
  const FriendlyErrorCard({super.key});

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Material(
      color: Colors.transparent,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 8),
              const Text(
                'Something went wrong here.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              const Text(
                'Go back and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
