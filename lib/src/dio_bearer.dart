import 'dart:async';
import 'dart:developer';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DioBearer extends QueuedInterceptor {
  DioBearer({
    bool handleRefreshToken = false,
    bool useEncryptedSharedPreferences = true,
    required List<String> accessTokenPaths,
    String accessTokenKey = "access_token",
    String refreshTokenKey = "refresh_token",
    String refreshTokenMethod = "POST",
    String? refreshTokenPath,
    Dio? refreshTokenClient,
  }) : assert(
         handleRefreshToken ? (refreshTokenKey.isNotEmpty) : true,
         "Refresh token key must be provided to use refresh token mechanisms",
       ),
       assert(
         handleRefreshToken
             ? (refreshTokenPath != null && refreshTokenPath.isNotEmpty)
             : true,
         "Refresh token path must be provided to use refresh token mechanisms",
       ),
       assert(
         handleRefreshToken
             ? [
                 'GET',
                 'POST',
                 'PUT',
                 'PATCH',
                 'DELETE',
               ].contains(refreshTokenMethod.toUpperCase())
             : true,
         "Refresh token method must be one of: GET, POST, PUT, PATCH, DELETE",
       ),
       assert(
         handleRefreshToken ? refreshTokenClient != null : true,
         "Refresh token dio client must be provided to use refresh token mechanisms",
       ),
       _handleRefreshToken = handleRefreshToken,
       _useEncryptedSharedPreferences = useEncryptedSharedPreferences,
       _accessTokenPaths = accessTokenPaths,
       _accessTokenKey = accessTokenKey,
       _refreshTokenKey = refreshTokenKey,
       _refreshTokenPath = refreshTokenPath,
       _refreshTokenMethod = refreshTokenMethod.toUpperCase(),
       _refreshTokenClient = refreshTokenClient {
    // Check if refreshTokenClient contains this interceptor to prevent infinite loops
    if (handleRefreshToken && refreshTokenClient != null) {
      final hasSelfInterceptor = refreshTokenClient.interceptors.any(
        (interceptor) => interceptor is DioBearer,
      );
      if (hasSelfInterceptor) {
        throw ArgumentError(
          'The refreshTokenClient cannot contain a DioBearer interceptor. '
          'This would cause an infinite loop during token refresh. '
          'Please provide a separate Dio client without this interceptor.',
        );
      }
    }
  }

  final bool _handleRefreshToken;
  final bool _useEncryptedSharedPreferences;
  final List<String> _accessTokenPaths;
  final String _accessTokenKey;
  final String _refreshTokenKey;
  final String _refreshTokenMethod;
  final String? _refreshTokenPath;
  final Dio? _refreshTokenClient;

  // Prevent multiple simultaneous refresh attempts
  bool _isRefreshing = false;
  final List<Completer<String?>> _pendingCompleters = [];

  late final FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: _useEncryptedSharedPreferences,
    ),
  );

  // Public method to manually clear tokens (e.g., on logout)
  Future<void> clearTokens() async {
    await _clearTokens();
  }

  Future<String?> getAccessToken() async {
    return _getToken(_accessTokenKey);
  }

  Future<String?> getRefreshToken() async {
    return _getToken(_refreshTokenKey);
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _getToken(_accessTokenKey);
    options.headers["authorization"] = "Bearer $token";
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final statusCode = err.response?.statusCode;
    if (statusCode != 401 && statusCode != 403) {
      handler.next(err);
      return;
    }
    if (!_handleRefreshToken) {
      handler.next(err);
      return;
    }

    if (_accessTokenPaths.contains(err.requestOptions.path)) {
      handler.next(err);
      return;
    }

    // Try to refresh the token and retry the request
    try {
      final newAccessToken = await _refreshAccessToken();

      if (newAccessToken == null) {
        handler.next(err);
        return;
      }

      // Retry the original request with the new token
      final requestOptions = err.requestOptions;
      requestOptions.headers["authorization"] = "Bearer $newAccessToken";

      final response = await _refreshTokenClient!.fetch(requestOptions);
      handler.resolve(response);
    } catch (e, s) {
      log("error refresh access token: ", error: e, stackTrace: s);
      // If refresh fails, pass the original error
      handler.next(err);
    }
  }

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    if (!_accessTokenPaths.contains(response.requestOptions.path)) {
      handler.next(response);
      return;
    }

    final statusCode = response.statusCode;

    if (statusCode == null || statusCode < 200 || statusCode > 299) {
      handler.next(response);
      return;
    }

    final accessToken = response.data[_accessTokenKey];
    if (accessToken is! String) {
      handler.next(response);
      return;
    }

    await _saveToken(_accessTokenKey, accessToken);

    if (!_handleRefreshToken) {
      handler.next(response);
      return;
    }

    final refreshToken = response.data[_refreshTokenKey];
    if (refreshToken is! String) {
      handler.next(response);
      return;
    }

    await _saveToken(_refreshTokenKey, refreshToken);
    handler.next(response);
  }

  Future<String?> _refreshAccessToken() async {
    // Prevent multiple simultaneous refresh attempts
    if (_isRefreshing) {
      // Wait for the current refresh to complete
      return await _waitForRefresh();
    }

    _isRefreshing = true;

    try {
      final refreshToken = await _getToken(_refreshTokenKey);
      if (refreshToken == null || refreshToken.isEmpty) {
        return null;
      }

      final tokenData = {_refreshTokenKey: refreshToken};
      final response = await _refreshTokenClient!.fetch(
        RequestOptions(
          path: _refreshTokenPath!,
          method: _refreshTokenMethod,
          // Use queryParameters for GET, data for other methods
          queryParameters: _refreshTokenMethod == 'GET' ? tokenData : null,
          data: _refreshTokenMethod != 'GET' ? tokenData : null,
        ),
      );

      final newAccessToken = response.data[_accessTokenKey];
      if (newAccessToken is! String) {
        _notifyPendingRequests(null);
        return null;
      }

      await _saveToken(_accessTokenKey, newAccessToken);

      // Save new refresh token if provided
      final newRefreshToken = response.data[_refreshTokenKey];
      if (newRefreshToken is String) {
        await _saveToken(_refreshTokenKey, newRefreshToken);
      }

      // Notify pending requests
      _notifyPendingRequests(newAccessToken);

      return newAccessToken;
    } on DioException catch (e, s) {
      log("error refresh access token: ", error: e, stackTrace: s);

      final statusCode = e.response?.statusCode;
      if (statusCode != null && statusCode >= 400 && statusCode < 499) {
        await _clearTokens();
      }
      _notifyPendingRequests(null);
      return null;
    } finally {
      _isRefreshing = false;
      _pendingCompleters.clear();
    }
  }

  Future<String?> _waitForRefresh() async {
    final completer = Completer<String?>();
    _pendingCompleters.add(completer);
    return completer.future;
  }

  void _notifyPendingRequests(String? token) {
    for (final completer in _pendingCompleters) {
      if (!completer.isCompleted) {
        completer.complete(token);
      }
    }
  }

  Future<String?> _getToken(String key) {
    return _secureStorage.read(key: key);
  }

  Future<void> _saveToken(String key, String token) async {
    await _secureStorage.write(key: key, value: token);
  }

  Future<void> _clearTokens() async {
    await _secureStorage.delete(key: _accessTokenKey);
    await _secureStorage.delete(key: _refreshTokenKey);
  }
}
