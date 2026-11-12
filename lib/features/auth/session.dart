import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../core/business_profile.dart';
import 'auth_models.dart';
import 'auth_repository.dart';

/// The signed-in user and the active company.
class SessionState {
  const SessionState({this.me, this.activeCompanyId});

  static const SessionState signedOut = SessionState();

  final Me? me;
  final String? activeCompanyId;

  bool get isSignedIn => me != null;

  User? get user => me?.user;

  List<Membership> get companies => me?.companies ?? const [];

  Membership? get company =>
      me?.company(activeCompanyId) ??
      (companies.isEmpty ? null : companies.first);

  bool get isPlatformAdmin => me?.isPlatformAdmin ?? false;

  PermissionSet get permissions {
    final own = company?.permissions ?? PermissionSet.none;
    return isPlatformAdmin ? own.plus(Perm.platformAdmin) : own;
  }

  bool can(String permission) => permissions.can(permission);

  /// Location scope of the active membership; `null` = all locations.
  List<String>? get locationIds => company?.locationIds;
}

final sessionProvider = AsyncNotifierProvider<SessionController, SessionState>(
  SessionController.new,
);

final activeCompanyIdProvider = Provider<String?>(
  (ref) => ref.watch(sessionProvider.select((s) => s.value?.activeCompanyId)),
);

final permissionsProvider = Provider<PermissionSet>(
  (ref) => ref.watch(
    sessionProvider.select((s) => s.value?.permissions ?? PermissionSet.none),
  ),
);

class SessionController extends AsyncNotifier<SessionState> {
  AuthRepository get _auth => ref.read(authRepositoryProvider);

  @override
  Future<SessionState> build() async {
    final api = ref.watch(apiClientProvider);
    final subscription = api.sessionExpired.listen(
      (_) => state = const AsyncData(SessionState.signedOut),
    );
    ref.onDispose(subscription.cancel);

    if (!await api.restore()) return SessionState.signedOut;
    try {
      await _auth.refresh();
    } on ApiException catch (e) {
      // Offline: keep the refresh token and let the user retry.
      if (e.isNetworkError) rethrow;
      await api.clearSession();
      return SessionState.signedOut;
    }
    return _loadMe();
  }

  Future<SessionState> _loadMe() async {
    final api = ref.read(apiClientProvider);
    try {
      final me = await _auth.me();
      final company =
          me.company(api.companyId) ??
          (me.companies.isEmpty ? null : me.companies.first);
      await api.setCompany(company?.id);
      _applyMoney(company);
      return SessionState(me: me, activeCompanyId: company?.id);
    } catch (_) {
      await api.clearSession();
      rethrow;
    }
  }

  Future<void> login(String email, String password) async {
    await _auth.login(email, password);
    state = AsyncData(await _loadMe());
  }

  /// Password step; a non-null result is the 2FA challenge to complete with
  /// [completeMfa]. Otherwise the user is signed in.
  Future<MfaChallenge?> signIn(String email, String password) async {
    final outcome = await _auth.signIn(email, password);
    if (outcome is MfaChallenge) return outcome;
    state = AsyncData(await _loadMe());
    return null;
  }

  Future<void> completeMfa(
    String mfaToken, {
    String? code,
    String? recoveryCode,
  }) async {
    await _auth.completeMfa(mfaToken, code: code, recoveryCode: recoveryCode);
    state = AsyncData(await _loadMe());
  }

  Future<void> redeemSso(String ticket) async {
    await _auth.redeemSso(ticket);
    state = AsyncData(await _loadMe());
  }

  Future<void> signup(SignupRequest request) async {
    await _auth.signup(request);
    state = AsyncData(await _loadMe());
  }

  /// Currency and digit grouping follow the company.
  void _applyMoney(Company? company) {
    final country = countryByCode(company?.country ?? 'IN');
    final currency = company?.currency ?? 'INR';
    // Keep Indian grouping for rupees whatever the country list says.
    configureMoney(
      currency: currency,
      locale: currency == 'INR' ? 'en_IN' : country.locale,
    );
  }

  Future<void> logout() async {
    configureMoney();
    await _auth.logout();
    state = const AsyncData(SessionState.signedOut);
  }

  Future<void> switchCompany(String companyId) async {
    final current = state.value;
    if (current?.me?.company(companyId) == null) return;
    await ref.read(apiClientProvider).setCompany(companyId);
    _applyMoney(current?.me?.company(companyId));
    state = AsyncData(
      SessionState(me: current!.me, activeCompanyId: companyId),
    );
  }

  /// Re-reads `/me` (e.g. after roles change).
  Future<void> reloadMe() async => state = AsyncData(await _loadMe());

  /// Retries restoring the session after a startup failure.
  void retry() => ref.invalidateSelf();
}
