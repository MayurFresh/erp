import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// In-process stand-in for the `/platform/*` endpoints.
class SuperFakeBackend implements HttpClientAdapter {
  SuperFakeBackend({this.admin = true});

  final bool admin;
  final List<RequestOptions> requests = [];
  final Map<String, (int, Object?)> overrides = {};
  String status = 'active';
  String? reason;

  bool called(String method, String path) =>
      requests.any((r) => r.method == method && r.path == path);

  static const user = {
    'id': 'u-admin',
    'name': 'Platform Admin',
    'email': 'superadmin@demo.in',
    'phone': null,
  };

  Map<String, Object?> tenant(String id, String name, {String? st}) => {
    'id': id,
    'name': name,
    'status': st ?? (id == 't1' ? status : 'active'),
    'createdAt': '2026-10-01T10:00:00Z',
    'suspendedAt': (st ?? (id == 't1' ? status : 'active')) == 'suspended'
        ? '2026-11-02T10:00:00Z'
        : null,
    'suspendedReason': id == 't1' ? reason : null,
    'companyCount': 1,
    'userCount': 2,
    'activeUsers': 2,
    'businessType': id == 't1' ? 'restaurant' : 'kirana',
    'plan': 'team',
    'country': 'IN',
    'ownerName': 'Asha Rao',
    'ownerEmail': '$id@example.com',
    'lastSignInAt': '2026-11-03T09:00:00Z',
    'hasPlatformAdmin': false,
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
    final (code, body) =
        overrides['${options.method} ${options.path}'] ??
        _route(options.method, options.path, options);
    return ResponseBody.fromString(
      jsonEncode(body),
      code,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  (int, Object?) _route(String method, String path, RequestOptions o) {
    final b = o.data is Map
        ? Map<String, Object?>.from(o.data as Map)
        : const <String, Object?>{};
    switch ((method, path)) {
      case ('POST', '/auth/refresh'):
        return (
          200,
          {
            'accessToken': 'access',
            'refreshToken': 'refresh-2',
            'expiresIn': 900,
            'user': user,
          },
        );
      case ('GET', '/me'):
        return (
          200,
          {'user': user, 'isPlatformAdmin': admin, 'companies': <Object?>[]},
        );
      case ('GET', '/business-types'):
        return (200, {'groups': [], 'types': []});
      case ('GET', '/platform/overview'):
        return (
          200,
          {
            'tenants': 12,
            'activeTenants': 11,
            'suspendedTenants': 1,
            'users': 30,
            'companies': 14,
            'usersSignedInLast30Days': 18,
            'byBusinessType': [
              {'key': 'kirana', 'count': 6},
              {'key': 'restaurant', 'count': 4},
              {'key': 'hospital', 'count': 2},
            ],
            'byPlan': [
              {'key': 'team', 'count': 8},
              {'key': 'business', 'count': 4},
            ],
            'byCountry': [
              {'key': 'IN', 'count': 11},
              {'key': 'AE', 'count': 1},
            ],
            'signupsByMonth': [
              for (var i = 0; i < 12; i++)
                {
                  'month': '2026-${(i + 1).toString().padLeft(2, '0')}',
                  'count': i % 4,
                },
            ],
          },
        );
      case ('GET', '/platform/tenants'):
        final q = '${o.queryParameters['q'] ?? ''}'.toLowerCase();
        final want = o.queryParameters['status'];
        final rows =
            [
              tenant('t1', 'Spice Route Kitchen'),
              tenant('t2', 'Patel Kirana Store'),
            ].where((t) {
              if (want != null && t['status'] != want) return false;
              return q.isEmpty || '${t['name']}'.toLowerCase().contains(q);
            }).toList();
        return (200, {'data': rows, 'total': rows.length});
      case ('GET', '/platform/tenants/t1'):
        return (
          200,
          {
            'tenant': tenant('t1', 'Spice Route Kitchen'),
            'companies': [
              {
                'id': 'c1',
                'name': 'Spice Route Kitchen',
                'businessType': 'restaurant',
                'plan': 'team',
                'country': 'IN',
                'currency': 'INR',
                'enabledModules': ['sales', 'inventory'],
                'createdAt': '2026-10-01T10:00:00Z',
                'counts': {'invoices': 4, 'parties': 3, 'items': 9},
              },
            ],
            'users': [
              {
                'id': 'u1',
                'name': 'Asha Rao',
                'email': 'asha@example.com',
                'isActive': true,
                'isLocked': true,
                'twoFactor': false,
                'isPlatformAdmin': false,
                'lastSignInAt': '2026-11-03T09:00:00Z',
                'roles': [
                  {'companyId': 'c1', 'role': 'Owner'},
                ],
              },
            ],
          },
        );
      case ('PATCH', '/platform/tenants/t1'):
        if (b['status'] == 'suspended') {
          status = 'suspended';
          reason = b['reason'] as String?;
        } else if (b['status'] == 'active') {
          status = 'active';
          reason = null;
        }
        return (200, tenant('t1', 'Spice Route Kitchen'));
      case ('GET', '/platform/audit'):
        return (
          200,
          {
            'data': [
              {
                'id': 'a1',
                'adminUserId': 'u-admin',
                'adminName': 'Platform Admin',
                'action': 'tenant_suspend',
                'tenantId': 't1',
                'tenantName': 'Spice Route Kitchen',
                'targetType': 'tenant',
                'targetId': 't1',
                'detail': {'reason': 'Unpaid'},
                'createdAt': '2026-11-02T10:00:00Z',
              },
            ],
            'next': null,
          },
        );
      case ('POST', '/platform/users/u1/reset-link'):
        return (
          200,
          {
            'link': 'https://app.example/#/reset-password?token=abc123',
            'expiresAt': '2026-11-04T12:00:00Z',
          },
        );
      case ('POST', '/platform/users/u1/unlock'):
        return (204, null);
    }
    return (
      404,
      {
        'error': {'code': 'NOT_FOUND', 'message': 'No fake for $method $path'},
      },
    );
  }
}
