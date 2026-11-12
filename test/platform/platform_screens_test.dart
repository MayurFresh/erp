import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'platform_fake_backend.dart';
import 'platform_harness.dart';

void main() {
  testWidgets('login asks for the 2FA code, then signs in', (tester) async {
    final h = await bootPlatform(
      tester,
      desktop,
      initial: '/login',
      signedIn: false,
    );
    await h.type('login.email', 'asha@example.com');
    await h.type('login.password', 'Secret123');
    await h.tap('login.submit');
    expect(find.byKey(const Key('mfa.code')), findsOneWidget);

    await h.type('mfa.code', '000000');
    await h.tap('mfa.submit');
    expect(
      find.byKey(const Key('mfa.code')),
      findsOneWidget,
      reason: 'wrong code',
    );

    await h.type('mfa.code', '123456');
    await h.tap('mfa.submit');
    final body = h.backend.last('POST', '/auth/login/mfa').data as Map;
    expect(body['mfaToken'], 'm1');
    expect(body['code'], '123456');
    h.expectClean('mfa login');
    await h.dispose();
  });

  testWidgets('forgot password sends the link', (tester) async {
    final h = await bootPlatform(
      tester,
      desktop,
      initial: '/forgot-password',
      signedIn: false,
    );
    await h.type('forgot.email', 'asha@example.com');
    await h.tap('forgot.submit');
    expect(find.byKey(const Key('forgot.sent')), findsOneWidget);
    expect(
      (h.backend.last('POST', '/auth/password/forgot').data as Map)['email'],
      'asha@example.com',
    );
    h.expectClean('forgot');
    await h.dispose();
  });

  testWidgets('reset password with a good and a bad token', (tester) async {
    final h = await bootPlatform(
      tester,
      desktop,
      initial: '/reset-password?token=t1',
      signedIn: false,
    );
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Newpass123');
    await tester.enterText(fields.at(1), 'Newpass123');
    await h.tap('reset.submit');
    expect(find.byKey(const Key('reset.done')), findsOneWidget);
    expect(
      (h.backend.last('POST', '/auth/password/reset').data as Map)['token'],
      't1',
    );
    await h.dispose();

    final h2 = await bootPlatform(
      tester,
      desktop,
      initial: '/reset-password?token=bad',
      signedIn: false,
    );
    final f2 = find.byType(TextFormField);
    await tester.enterText(f2.at(0), 'Newpass123');
    await tester.enterText(f2.at(1), 'Newpass123');
    await h2.tap('reset.submit');
    expect(find.byKey(const Key('reset.invalid')), findsOneWidget);
    await h2.dispose();
  });

  testWidgets('2FA setup, enable and recovery codes', (tester) async {
    final h = await bootPlatform(tester, desktop, initial: '/account/security');
    await h.tap('2fa.setup');
    expect(find.byKey(const Key('2fa.secret')), findsOneWidget);
    expect(find.textContaining('JBSWY3DPEHPK3PXP'), findsWidgets);
    await h.type('2fa.code', '123456');
    await h.tap('2fa.enable');
    expect(find.textContaining('aaaa-1111'), findsOneWidget);
    expect(h.backend.twoFactor, isTrue);
    await h.tap('2fa.copyCodes');
    expect(h.clipboard, contains('bbbb-2222'));
    h.expectClean('2fa');
    await h.dispose();
  });

  testWidgets('sessions: revoke one and all others', (tester) async {
    final backend = PlatformFakeBackend()
      ..sessions.add({'id': 's3', 'userAgent': 'Safari', 'current': false});
    final h = await bootPlatform(
      tester,
      desktop,
      initial: '/account/security',
      backend: backend,
    );
    expect(find.byKey(const Key('session.s2')), findsOneWidget);
    await h.tap('session.revoke.s2');
    expect(h.backend.count('DELETE', '/me/sessions/s2'), 1);
    expect(find.byKey(const Key('session.s2')), findsNothing);
    await h.tap('session.revokeOthers');
    if (find.byType(FilledButton).evaluate().isNotEmpty &&
        find.text('Sign out others').evaluate().isNotEmpty) {
      await tester.tap(find.text('Sign out others'));
      await tester.pumpAndSettle();
    }
    expect(h.backend.count('POST', '/me/sessions/revoke-others'), 1);
    await h.dispose();
  });

  testWidgets('bell shows the unread count and mark all read clears it', (
    tester,
  ) async {
    final h = await bootPlatform(tester, desktop, initial: '/home-x');
    await h.go('/');
    expect(find.byKey(const Key('notifications.bell')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('notifications.badge'))).data,
      '2',
    );
    await tester.tap(find.byKey(const Key('notifications.bell')));
    await tester.pumpAndSettle();
    expect(find.text('Approval needed'), findsOneWidget);
    await h.tap('notifications.readAll');
    expect(h.backend.count('POST', '/notifications/read-all'), 1);
    expect(find.byKey(const Key('notifications.badge')), findsNothing);
    h.expectClean('bell');
    await h.dispose();
  });

  testWidgets('tapping a notification marks it read and follows the link', (
    tester,
  ) async {
    final h = await bootPlatform(tester, desktop);
    await tester.tap(find.byKey(const Key('notification.n1')));
    await tester.pumpAndSettle();
    expect(h.backend.count('POST', '/notifications/n1/read'), 1);
    expect(find.text('Approvals stub'), findsOneWidget);
    await h.dispose();
  });

  testWidgets('new company copies the accounts of the active one', (
    tester,
  ) async {
    final h = await bootPlatform(tester, desktop, initial: '/companies/new');
    await h.type('newCompany.name', 'Gamma Ltd');
    await tester.tap(find.byKey(const Key('newCompany.state')));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('Gujarat'),
      find.byType(Scrollable).last,
      const Offset(0, -80),
    );
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gujarat').last);
    await tester.pumpAndSettle();
    await h.tap('newCompany.save');
    final body = h.backend.last('POST', '/companies').data as Map;
    expect(body['name'], 'Gamma Ltd');
    expect(body['copyAccountsFrom'], 'c1');
    h.expectClean('new company');
    await h.dispose();
  });

  testWidgets('inter-company entry is created from both sides', (tester) async {
    final h = await bootPlatform(tester, desktop, initial: '/intercompany/new');
    await tester.tap(find.byKey(const Key('ic.to.company')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta Works').last);
    await tester.pumpAndSettle();
    for (final key in ['ic.from.account-c1', 'ic.to.account-c2']) {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1100 Bank').last);
      await tester.pumpAndSettle();
    }
    await h.type('ic.amount', '2500');
    await h.type('ic.narration', 'Loan to Beta');
    await h.tap('ic.save');
    final body = h.backend.last('POST', '/intercompany-entries').data as Map;
    expect(body['amount'], 2500);
    expect((body['from'] as Map)['companyId'], 'c1');
    expect((body['to'] as Map)['companyId'], 'c2');
    expect(find.text('IC/26-27/00001'), findsOneWidget);
    h.expectClean('intercompany');
    await h.dispose();
  });

  testWidgets('consolidated trial balance renders per company', (tester) async {
    final h = await bootPlatform(tester, desktop, initial: '/consolidated');
    await tester.tap(find.byKey(const Key('consol.company.c1')));
    await tester.tap(find.byKey(const Key('consol.company.c2')));
    await tester.pump();
    await h.tap('consol.run');
    final q = h.backend
        .last('GET', '/reports/consolidated/trial-balance')
        .queryParameters;
    expect(q['companyIds'], 'c1,c2');
    expect(find.text('Alpha Traders'), findsWidgets);
    expect(find.text('Bank'), findsOneWidget);
    expect(find.byKey(const Key('consol.warning')), findsOneWidget);
    expect(find.textContaining('25.00'), findsWidgets);
    h.expectClean('consolidated');
    await h.dispose();
  });

  testWidgets('GSP settings save keeps blank secrets out of the body', (
    tester,
  ) async {
    final h = await bootPlatform(tester, desktop, initial: '/gsp-settings');
    await tester.tap(find.text('Provider'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gsp.provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acme GSP').last);
    await tester.pumpAndSettle();
    await h.type('gsp.cred.username', 'asha');
    await h.tap('gsp.save');
    final body = h.backend.last('PATCH', '/company/gsp').data as Map;
    expect(body['mode'], 'gsp');
    expect(body['provider'], 'acme');
    expect((body['credentials'] as Map)['username'], 'asha');
    expect((body['credentials'] as Map).containsKey('password'), isFalse);
    await h.tap('gsp.test');
    expect(find.text('Connected'), findsOneWidget);
    h.expectClean('gsp');
    await h.dispose();
  });

  for (final route in [
    '/account/security',
    '/companies',
    '/consolidated',
    '/gsp-settings',
    '/intercompany/new',
  ]) {
    testWidgets('phone layout has no overflow: $route', (tester) async {
      final h = await bootPlatform(tester, phone, initial: route);
      h.expectClean(route);
      await h.dispose();
    });
  }

  testWidgets('phone login shows the MFA step without overflow', (
    tester,
  ) async {
    final h = await bootPlatform(
      tester,
      phone,
      initial: '/login',
      signedIn: false,
    );
    await h.type('login.email', 'asha@example.com');
    await h.type('login.password', 'Secret123');
    await h.tap('login.submit');
    expect(find.byKey(const Key('mfa.code')), findsOneWidget);
    h.expectClean('phone mfa');
    await h.dispose();
  });
}
