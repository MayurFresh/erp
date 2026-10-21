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
        return ApiException(
          status,
          asString(error['code'], 'HTTP_$status'),
          asString(error['message'], 'Request failed ($status)'),
          asJson(error['details']),
        );
      }
      return ApiException(
        status,
        'HTTP_$status',
        'Request failed with status $status'
            '${response.statusMessage == null ? '' : ' (${response.statusMessage})'}',
      );
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => const ApiException(
        0,
        timeout,
        'The server took too long to respond. Please try again.',
      ),
      DioExceptionType.cancel => const ApiException(
        0,
        cancelled,
        'Request cancelled.',
      ),
      _ => const ApiException(
        0,
        networkError,
        'Cannot reach the server. Check your connection and try again.',
      ),
    };
  }

  static const networkError = 'NETWORK_ERROR';
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
