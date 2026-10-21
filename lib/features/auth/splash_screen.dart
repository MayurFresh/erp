import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/states.dart';
import 'auth_scaffold.dart';
import 'session.dart';

/// Shown while the stored session is restored, or if that fails offline.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final error = session.hasError && !session.isLoading ? session.error : null;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandMark(),
              const SizedBox(height: 32),
              if (error == null)
                const CircularProgressIndicator()
              else ...[
                ErrorView(
                  error: error,
                  onRetry: () => ref.read(sessionProvider.notifier).retry(),
                ),
                TextButton(
                  onPressed: () => ref.read(sessionProvider.notifier).logout(),
                  child: const Text('Sign in again'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
