import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderException;

import '../core/api_exception.dart';

/// Human-readable message for any error thrown by the app's API layer.
String errorMessage(Object error) {
  final inner = error is ProviderException ? error.exception : error;
  if (inner is ApiException) return inner.message;
  // Never show raw exception text.
  return 'Something went wrong. Please try again.';
}

/// The [ApiException] behind [error], if any.
ApiException? apiError(Object error) {
  final inner = error is ProviderException ? error.exception : error;
  return inner is ApiException ? inner : null;
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final api = apiError(error);
    final forbidden = api?.isForbidden ?? false;
    final notFound = api?.isNotFound ?? false;
    final icon = forbidden
        ? Icons.lock_outline
        : notFound
        ? Icons.search_off
        : (api?.isNetworkError ?? false)
        ? Icons.cloud_off_outlined
        : Icons.error_outline;
    final message = forbidden
        ? "You don't have access to this. Ask an administrator."
        : notFound
        ? 'Not found. It may have been deleted.'
        : errorMessage(error);
    final canGoBack = notFound && GoRouter.maybeOf(context) != null;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 48,
              color: forbidden || notFound
                  ? theme.colorScheme.outline
                  : theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (canGoBack) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: () {
                  final router = GoRouter.of(context);
                  router.canPop() ? router.pop() : router.go('/');
                },
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back'),
              ),
            ] else if (onRetry != null && !forbidden && !notFound) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// Loading / error-with-retry / data for an [AsyncValue].
class AsyncValueView<T> extends StatelessWidget {
  const AsyncValueView({
    super.key,
    required this.value,
    required this.data,
    this.onRetry,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => switch (value) {
    AsyncValue(:final T value, hasValue: true) => data(value),
    AsyncValue(:final Object error, hasError: true) => ErrorView(
      error: error,
      onRetry: onRetry,
    ),
    _ => const LoadingView(),
  };
}

void showErrorSnackBar(BuildContext context, Object error) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final theme = Theme.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          errorMessage(error),
          style: TextStyle(color: theme.colorScheme.onErrorContainer),
        ),
        backgroundColor: theme.colorScheme.errorContainer,
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        closeIconColor: theme.colorScheme.onErrorContainer,
      ),
    );
}

void showInfoSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
}
