# DioBearer

A Dio interceptor for automatic Bearer token management with refresh token support.

## Features

- 🔐 Automatic Bearer token injection in requests
- 🔄 Automatic token refresh on 401/403 errors
- 💾 Secure token storage using Flutter Secure Storage
- 🔁 Prevents multiple simultaneous refresh attempts
- 📦 Configurable token extraction from API responses

## Installation

```bash
flutter pub add dio_bearer
```

## Basic Usage

```dart
final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com/api/v1'));
final dioBearer = DioBearer(
  accessTokenPaths: ['/login', '/register'],
);

dio.interceptors.add(dioBearer);
```

## With Refresh Token

```dart
final refreshClient = Dio(BaseOptions(baseUrl: 'https://api.example.com/api/v1'));

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com/api/v1'));
final dioBearer = DioBearer(
  handleRefreshToken: true,
  accessTokenPaths: ['/login', '/register'],
  refreshTokenPath: '/auth/refresh',
  refreshTokenMethod: 'POST',
  refreshTokenClient: refreshClient,
);
dio.interceptors.add(dioBearer);
```

## Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `accessTokenPaths` | `List<String>` | required | API paths that return tokens |
| `accessTokenKey` | `String` | `"access_token"` | Key for access token in response |
| `refreshTokenKey` | `String` | `"refresh_token"` | Key for refresh token in response |
| `handleRefreshToken` | `bool` | `false` | Enable automatic token refresh |
| `refreshTokenPath` | `String?` | `null` | Endpoint for token refresh and must be provided if `handleRefreshToken` is `true` |
| `refreshTokenMethod` | `String` | `"POST"` | HTTP method for refresh and must be provided if `handleRefreshToken` is `true` |
| `refreshTokenClient` | `Dio?` | `null` | Separate Dio client for refresh requests and must be provided if `handleRefreshToken` is `true` |
| `useEncryptedSharedPreferences` | `bool` | `true` | Use encrypted storage on Android |

## Methods

```dart
// Get stored tokens
final accessToken = await dioBearer.getAccessToken();
final refreshToken = await dioBearer.getRefreshToken();

// Clear tokens (e.g., on logout)
await dioBearer.clearTokens();
```

## How It Works

1. **Token Storage**: Automatically extracts and stores tokens from configured endpoints
2. **Token Injection**: Adds `Authorization: Bearer <token>` header to all requests
3. **Auto Refresh**: On 401/403 errors, attempts to refresh the token and retry the request
4. **Queue Management**: Queues concurrent requests during token refresh

## Notes

- The `refreshTokenClient` must NOT contain the `DioBearer` interceptor to prevent infinite loops
- Tokens are automatically cleared if refresh fails
- Uses Flutter Secure Storage for secure token persistence