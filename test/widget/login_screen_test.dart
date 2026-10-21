import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/theme.dart';
import 'package:progen_erp/features/auth/login_screen.dart';

void main() {
  Future<void> pumpLogin(WidgetTester tester, {Size? size}) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(theme: AppTheme.light, home: const LoginScreen()),
      ),
    );
  }

  testWidgets('renders the sign-in form', (tester) async {
    await pumpLogin(tester);
    expect(find.text('Progen ERP'), findsOneWidget);
    expect(find.text('Sign in'), findsWidgets);
    expect(find.byKey(const Key('login.email')), findsOneWidget);
    expect(find.byKey(const Key('login.password')), findsOneWidget);
  });

  testWidgets('validates empty fields without calling the API', (tester) async {
    await pumpLogin(tester);
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pump();
    expect(find.text('Email is required'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('login.email')),
      'not-an-email',
    );
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pump();
    expect(find.text('Enter a valid email'), findsOneWidget);
  });

  testWidgets('fits a 360 px wide phone', (tester) async {
    await pumpLogin(tester, size: const Size(360, 640));
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
