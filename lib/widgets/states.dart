import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderException;

import '../core/api_exception.dart';
import '../core/app_colors.dart';
import '../core/design_tokens.dart';
import 'icon_badge.dart';
import 'illustrations.dart';
import 'skeleton.dart';

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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Skeleton rows where there is room; a plain spinner in small slots.
      if (constraints.hasBoundedHeight &&
          constraints.maxHeight >= 200 &&
          constraints.maxWidth >= 240) {
        final rows = (constraints.maxHeight / 64).floor().clamp(3, 8);
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: SkeletonList(rows: rows),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    },
  );
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
        ? Icons.search_off_outlined
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
        padding: const EdgeInsets.all(Space.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (notFound)
                const Illustration(IllustrationKind.search, width: 132)
              else
                IconBadge(
                  icon,
                  size: 44,
                  tone: forbidden ? Accent.amber : Accent.rose,
                ),
              const SizedBox(height: Space.md),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              if (canGoBack) ...[
                const SizedBox(height: Space.lg),
                OutlinedButton.icon(
                  onPressed: () {
                    final router = GoRouter.of(context);
                    router.canPop() ? router.pop() : router.go('/');
                  },
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back'),
                ),
              ] else if (onRetry != null && !forbidden && !notFound) ...[
                const SizedBox(height: Space.lg),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ],
          ),
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
    this.illustration,
  });

  final String message;

  /// Shown when there is no [illustration] and it is not the default inbox.
  final IconData icon;
  final Widget? action;

  /// A line drawing above the message. With the default [icon] and no
  /// illustration, a generic documents drawing is used.
  final IllustrationKind? illustration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = illustration;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (kind != null)
                Illustration(kind, width: 120)
              else
                IconBadge(icon, size: 44),
              const SizedBox(height: Space.md),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: Space.lg),
                action!,
              ],
            ],
          ),
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

void showErrorSnackBar(
  BuildContext context,
  Object error, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          errorMessage(error),
          style: TextStyle(color: context.colors.onDangerContainer),
        ),
        backgroundColor: context.colors.dangerContainer,
        behavior: SnackBarBehavior.floating,
        showCloseIcon: actionLabel == null,
        closeIconColor: context.colors.onDangerContainer,
        duration: actionLabel == null
            ? const Duration(seconds: 4)
            : const Duration(seconds: 12),
        action: actionLabel == null || onAction == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction),
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
