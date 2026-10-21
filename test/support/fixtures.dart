import 'package:progen_erp/core/permissions.dart';
import 'package:progen_erp/features/auth/auth_models.dart';
import 'package:progen_erp/features/auth/session.dart';

const testUser = User(id: 'u1', name: 'Asha Rao', email: 'asha@demo.in');

Membership membership(
  Set<String> permissions, {
  String id = 'c1',
  String name = 'Demo Builders',
  List<String>? locationIds,
}) => Membership(
  id: id,
  name: name,
  stateCode: '29',
  roles: const [RoleRef(id: 'r1', name: 'Owner')],
  permissions: PermissionSet(permissions),
  locationIds: locationIds,
);

SessionState signedIn(Set<String> permissions, {List<Membership>? extra}) =>
    SessionState(
      me: Me(user: testUser, companies: [membership(permissions), ...?extra]),
      activeCompanyId: 'c1',
    );

/// A session controller with a fixed state (no network).
class FakeSessionController extends SessionController {
  FakeSessionController(this.initial);

  final SessionState initial;

  @override
  Future<SessionState> build() async => initial;
}
