import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/states.dart';
import 'auth_scaffold.dart';
import 'session.dart';

/// `/sso/done?ticket=` (also `/sso/callback`): redeems the one-time ticket
/// and signs in; the router then leaves the page.
class SsoCallbackScreen extends ConsumerStatefulWidget {
  const SsoCallbackScreen({super.key, required this.ticket});

  final String? ticket;

  @override
  ConsumerState<SsoCallbackScreen> createState() => _SsoCallbackScreenState();
}

class _SsoCallbackScreenState extends ConsumerState<SsoCallbackScreen> {
  Object? _error;

  @override
  void initState() {
    super.initState();
    final ticket = widget.ticket;
    if (ticket == null || ticket.isEmpty) {
      _error = 'Missing sign-in ticket.';
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _redeem(ticket));
    }
  }

  Future<void> _redeem(String ticket) async {
    try {
      await ref.read(sessionProvider.notifier).redeemSso(ticket);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) => AuthScaffold(
    title: 'Single sign-on',
    child: _error == null
        ? const Column(
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Signing you in…'),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                key: const Key('sso.error'),
                _error is String
                    ? _error! as String
                    : '${errorMessage(_error!)} Try signing in again.',
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/login'),
                child: const Text('Back to sign in'),
              ),
            ],
          ),
  );
}
