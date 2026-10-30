import 'package:dio/dio.dart';

import 'json.dart';

/// An error returned by the API (`{error:{code,message,details}}`) or a
/// transport failure (statusCode 0, code `NETWORK_ERROR` / `TIMEOUT`).
class ApiException implements Exception {
  const ApiException(
    this.statusCode,
    this.code,
    this.message, [
    this.details = const <String, dynamic>{},
  ]);

  factory ApiException.fromDio(DioException e) {
    if (e.error is ApiException) return e.error! as ApiException;
    final response = e.response;
    if (response != null) {
      final status = response.statusCode ?? 0;
      final error = asJsonOrNull(asJsonOrNull(response.data)?['error']);
      if (error != null) {
        final code = asString(error['code'], 'HTTP_$status');
        final serverMessage = asString(error['message']);
        return ApiException(
          status,
          code,
          friendlyMessage(code, status, serverMessage),
          asJson(error['details']),
        );
      }
      return ApiException(
        status,
        'HTTP_$status',
        friendlyMessage('HTTP_$status', status, ''),
      );
    }
    return switch (e.type) {
      DioExceptionType.cancel => const ApiException(
        0,
        cancelled,
        'Request cancelled.',
      ),
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => const ApiException(
        0,
        timeout,
        offlineMessage,
      ),
      _ => const ApiException(0, networkError, offlineMessage),
    };
  }

  static const offlineMessage =
      "You're offline. Check your connection and try again.";

  /// Client-side wording for codes the app must explain itself; other
  /// codes keep the server message.
  static String friendlyMessage(String code, int status, String server) {
    switch (code) {
      case inUse:
        return "This record is used by other documents, so it can't be "
            'deleted. Deactivate it instead.';
      case tryAgain:
        return 'The server is busy. Please try again.';
      case requestInProgress:
        return 'This request is already being processed. Please wait.';
      case idempotencyMismatch:
        return 'This request conflicts with an earlier one. '
            'Reload and try again.';
      case payloadTooLarge:
        return 'That is too large to send. Reduce the size and try again.';
      case sessionRevoked:
        return 'Your access has changed. Please sign in again.';
    }
    if (status >= 500) return 'Something went wrong on our side. Try again.';
    if (server.isNotEmpty) return server;
    return switch (status) {
      404 => 'Not found.',
      403 => "You don't have access to this.",
      401 => 'Please sign in again.',
      _ => 'Request failed. Please try again.',
    };
  }

  static const networkError = 'NETWORK_ERROR';
  static const offline = networkError;
  static const inUse = 'IN_USE';
  static const tryAgain = 'TRY_AGAIN';
  static const requestInProgress = 'REQUEST_IN_PROGRESS';
  static const idempotencyMismatch = 'IDEMPOTENCY_MISMATCH';
  static const payloadTooLarge = 'PAYLOAD_TOO_LARGE';
  static const sessionRevoked = 'SESSION_REVOKED';
  static const timeout = 'TIMEOUT';
  static const cancelled = 'CANCELLED';
  static const validationError = 'VALIDATION_ERROR';
  static const tokenExpired = 'TOKEN_EXPIRED';
  static const unauthorized = 'UNAUTHORIZED';
  static const insufficientStock = 'INSUFFICIENT_STOCK';
  static const hasSettlements = 'HAS_SETTLEMENTS';
  static const alreadyCancelled = 'ALREADY_CANCELLED';

  final int statusCode;
  final String code;
  final String message;
  final Json details;

  bool get isNetworkError => statusCode == 0;
  bool get isNotFound => statusCode == 404;
  bool get isForbidden => statusCode == 403;
  bool get isValidation => code == validationError;

  /// `details` of a `VALIDATION_ERROR` as field → message.
  Map<String, String> get fieldErrors {
    if (!isValidation) return const {};
    return details.map((key, value) {
      final message = value is List ? value.join(', ') : asString(value);
      return MapEntry(key, message);
    });
  }

  @override
  String toString() => 'ApiException($statusCode, $code, $message)';
}
