import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// In-process stand-in for the v1.7 platform endpoints.
class PlatformFakeBackend implements HttpClientAdapter {
  PlatformFakeBackend({this.unread = 2});

  static const permissions = [
    'dashboard.view',
    'parties.view',
    'invoices.view',
    'users.manage',
    'company.manage',
    'companies.create',
    'security.manage',
    'accounts.view',
    'accounts.journal',
    'reports.view',
    'gst.view',
    'gst.manage',
    'einvoice.manage',
  ];

  int unread;
  bool twoFactor = false;
  final List<Map<String, Object?>> sessions = [
    {
      'id': 's1',
      'userAgent': 'Chrome on Mac',
      'ip': '1.2.3.4',
      'startedAt': '2026-11-01T10:00:00Z',
      'lastUsedAt': '2026-11-03T10:00:00Z',
      'method': 'password',
      'current': true,
    },
    {
      'id': 's2',
      'userAgent': 'Firefox on Windows',
      'ip': '5.6.7.8',
      'startedAt': '2026-10-30T10:00:00Z',
      'lastUsedAt': '2026-11-02T10:00:00Z',
      'method': 'password',
      'current': false,
    },
  ];
  final List<Map<String, Object?>> notifications = [
    {
      'id': 'n1',
      'title': 'Approval needed',
      'body': 'Bill PUR/1 awaits you',
      'link': '/approvals',
      'readAt': null,
      'createdAt': '2026-11-03T09:00:00Z',
    },
    {
      'id': 'n2',
      'title': 'Import done',
      'body': '12 rows',
      'link': null,
      'readAt': null,
      'createdAt': '2026-11-03T08:00:00Z',
    },
  ];
  final List<Map<String, Object?>> entries = [];
  final List<RequestOptions> requests = [];
  final Map<String, (int, Object?)> overrides = {};
  Map<String, Object?> gsp = {
    'mode': 'manual',
    'provider': null,
    'providers': [
      {
        'id': 'acme',
        'name': 'Acme GSP',
        'capabilities': ['einvoice', 'gstr1_save'],
        'credentialFields': [
          {'key': 'username', 'label': 'Username', 'secret': false},
          {'key': 'password', 'label': 'Password', 'secret': true},
        ],
      },
    ],
    'credentials': {'username': null, 'password': null},
    'savedSecrets': <String>[],
  };

  RequestOptions last(String method, String path) =>
      requests.lastWhere((r) => r.method == method && r.path == path);

  int count(String method, String path) =>
      requests.where((r) => r.method == method && r.path == path).length;

  static (int, Object?) error(
    int status,
    String code,
    String message, [
    Map<String, Object?> details = const {},
  ]) => (
    status,
    {
      'error': {'code': code, 'message': message, 'details': details},
    },
  );

  static const user = {
    'id': 'u1',
    'name': 'Asha Owner',
    'email': 'asha@example.com',
    'phone': null,
  };

  static Map<String, Object?> company(String id, String name) => {
    'id': id,
    'name': name,
    'legalName': name,
    'gstin': null,
    'pan': null,
    'stateCode': '24',
    'roles': [
      {'id': 'r1', 'name': 'Owner'},
    ],
    'permissions': permissions,
    'locationIds': null,
  };

  static final authResult = {
    'accessToken': 'access',
    'refreshToken': 'refresh-2',
    'expiresIn': 900,
    'user': user,
  };

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (status, body) =
        overrides['${options.method} ${options.path}'] ??
        _route(options.method, options.path, options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  Map<String, Object?> _body(RequestOptions o) =>
      Map<String, Object?>.from(o.data as Map? ?? const {});

  static Map<String, Object?> _tbRow(String code, String name, num a, num b) =>
      {
        'code': code,
        'name': name,
        'debit': a + b,
        'credit': 0,
        'byCompany': {'c1': a, 'c2': b},
      };

  (int, Object?) _route(String method, String path, RequestOptions o) {
    final b = o.data is Map ? _body(o) : const <String, Object?>{};
    switch ((method, path)) {
      case ('POST', '/auth/login'):
        if (b['password'] == 'Secret123') {
          return (
            200,
            {
              'mfaRequired': true,
              'mfaToken': 'm1',
              'methods': ['totp', 'recovery'],
            },
          );
        }
        return (200, authResult);
      case ('POST', '/auth/login/mfa'):
        return b['code'] == '123456' || b['recoveryCode'] != null
            ? (200, authResult)
            : error(401, 'MFA_INVALID', 'That code is not right');
      case ('GET', '/auth/sso/discover'):
        return (200, {'providers': []});
      case ('POST', '/auth/password/forgot'):
        return (202, {});
      case ('POST', '/auth/password/reset'):
        return b['token'] == 'bad'
            ? error(400, 'RESET_TOKEN_INVALID', 'Link expired')
            : (200, {});
      case ('POST', '/auth/refresh'):
        return (200, authResult);
      case ('GET', '/me'):
        return (
          200,
          {
            'user': user,
            'companies': [
              company('c1', 'Alpha Traders'),
              company('c2', 'Beta Works'),
            ],
          },
        );
      case ('GET', '/me/security'):
        return (
          200,
          {
            'twoFactorEnabled': twoFactor,
            'recoveryCodesLeft': twoFactor ? 8 : 0,
            'mustEnrol2fa': false,
          },
        );
      case ('POST', '/me/2fa/setup'):
        return (
          200,
          {
            'secret': 'JBSWY3DPEHPK3PXP',
            'otpauthUri': 'otpauth://totp/Progen:asha?secret=JBSWY3DPEHPK3PXP',
          },
        );
      case ('POST', '/me/2fa/enable'):
        if (b['code'] != '123456') {
          return error(400, 'MFA_INVALID', 'That code is not right');
        }
        twoFactor = true;
        return (
          200,
          {
            'recoveryCodes': ['aaaa-1111', 'bbbb-2222'],
          },
        );
      case ('GET', '/me/sessions'):
        return (200, {'data': sessions});
      case ('POST', '/me/sessions/revoke-others'):
        sessions.removeWhere((s) => s['current'] != true);
        return (200, {});
      case ('GET', '/me/notification-prefs'):
        return (200, {'data': []});
      case ('GET', '/notifications/unread-count'):
        return (200, {'unread': unread});
      case ('GET', '/notifications'):
        return (200, {'data': notifications, 'unread': unread});
      case ('POST', '/notifications/read-all'):
        for (final n in notifications) {
          n['readAt'] = '2026-11-03T10:00:00Z';
        }
        unread = 0;
        return (200, {});
      case ('GET', '/company'):
        return (
          200,
          {'id': 'c1', 'name': 'Alpha Traders', 'require2fa': false},
        );
      case ('GET', '/companies'):
        return (
          200,
          {
            'data': [
              company('c1', 'Alpha Traders'),
              company('c2', 'Beta Works'),
            ],
          },
        );
      case ('POST', '/companies'):
        return (201, {'id': 'c3', 'name': b['name']});
      case ('GET', '/accounts'):
        return (
          200,
          {
            'data': [
              {
                'id': 'a-${o.headers['X-Company-Id']}',
                'code': '1100',
                'name': 'Bank',
              },
            ],
            'total': 1,
          },
        );
      case ('GET', '/intercompany-entries'):
        return (200, {'data': entries, 'total': entries.length});
      case ('POST', '/intercompany-entries'):
        final e = {
          'id': 'ic1',
          'number': 'IC/26-27/00001',
          'date': b['date'],
          'amount': b['amount'],
          'narration': b['narration'],
          'status': 'posted',
          'from': {
            ...(b['from'] as Map).cast<String, Object?>(),
            'companyName': 'Alpha Traders',
            'accountName': 'Bank',
          },
          'to': {
            ...(b['to'] as Map).cast<String, Object?>(),
            'companyName': 'Beta Works',
            'accountName': 'Bank',
          },
        };
        entries.add(e);
        return (201, e);
      case ('GET', '/reports/intercompany'):
        return (
          200,
          {
            'asOf': '2026-11-03',
            'rows': [],
            'accountBalance': 0,
            'unexplained': 0,
          },
        );
      case ('GET', '/reports/consolidated/trial-balance'):
        return (
          200,
          {
            'companies': [
              {'id': 'c1', 'name': 'Alpha Traders'},
              {'id': 'c2', 'name': 'Beta Works'},
            ],
            'rows': [_tbRow('1100', 'Bank', 100, 50)],
            'totalDebit': 150,
            'totalCredit': 150,
            'eliminations': {'intercompany': 25},
            'warnings': ['Party Beta Works matches a listed company GSTIN'],
          },
        );
      case ('GET', '/company/gsp'):
        return (200, gsp);
      case ('PATCH', '/company/gsp'):
        gsp = {
          ...gsp,
          'mode': b['mode'],
          'provider': b['provider'],
          'savedSecrets': ['password'],
        };
        return (200, gsp);
      case ('POST', '/company/gsp/test'):
        return (200, {'ok': true, 'message': 'Connected'});
      case ('GET', '/gst/submissions'):
        return (200, {'data': []});
    }
    if (method == 'POST' && path.startsWith('/notifications/')) {
      unread = unread > 0 ? unread - 1 : 0;
      return (200, {});
    }
    if (method == 'DELETE' && path.startsWith('/me/sessions/')) {
      sessions.removeWhere((s) => path.endsWith('/${s['id']}'));
      return (204, null);
    }
    return error(404, 'NOT_FOUND', 'No fake for $method $path');
  }
}
