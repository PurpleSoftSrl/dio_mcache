# dio_mcache

> Hyper-configurable HTTP cache interceptor for Dio. Built on `mcache_dart`.

[![pub.dev](https://img.shields.io/pub/v/dio_mcache?label=pub.dev&logo=dart&color=0175C2)](https://pub.dev/packages/dio_mcache)
[![CI](https://github.com/PurpleSoftSrl/dio_mcache/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/PurpleSoftSrl/dio_mcache/actions/workflows/ci.yml)
[![Publish](https://github.com/PurpleSoftSrl/dio_mcache/actions/workflows/publish.yml/badge.svg)](https://github.com/PurpleSoftSrl/dio_mcache/actions/workflows/publish.yml)
[![Stars](https://img.shields.io/github/stars/PurpleSoftSrl/dio_mcache?color=yellow)](https://github.com/PurpleSoftSrl/dio_mcache/stargazers)
[![License](https://img.shields.io/badge/license-AGPL%20v3%20%7C%20Commercial-blue)](LICENSE)
[![tests](https://img.shields.io/badge/tests-34%20passed-brightgreen)](https://github.com/PurpleSoftSrl/dio_mcache/actions)

Every caching decision — TTL, key strategy, serialization, dedup, invalidation,
conditional fetch — is controllable globally and per-request.

---

## Install

```bash
dart pub add dio_mcache
```

```yaml
dependencies:
  dio_mcache: ^0.1.3
```

---

## Quick start

```dart
import 'package:dio_mcache/dio_mcache.dart';

final dio = Dio()..interceptors.add(DioCacheInterceptor(
  options: DioCacheOptions(expiration: const Duration(minutes: 5)),
));

final r1 = await dio.get('/products');   // network
final r2 = await dio.get('/products');   // from cache, instant
print(r2.extra['fromCache']);            // true
```

---

## Architecture

```
Request
  │
  ▼
DioCacheInterceptor
  ├── onRequest  → check cache (key → MemoryCache → hit? → serve)
  │                 ├── dedup check (pending identical request?)
  │                 ├── conditional headers (ETag / If-None-Match)
  │                 └── stale-while-revalidate (serve stale + bg refresh)
  │
  ├── onResponse → store cache (policy resolution → serialize → set)
  │                 ├── auto-invalidate related GETs on mutation
  │                 ├── tag registration
  │                 └── max-size / status-code filter
  │
  └── onError    → cleanup dedup entries
```

---

## Cache policies — organize by data type

Define named policies for different API patterns, switch per-request:

```dart
final dio = Dio()..interceptors.add(DioCacheInterceptor(
  options: DioCacheOptions(
    expiration: const Duration(minutes: 5),
    policies: {
      'user-data': const CachePolicy(
        expiration: Duration(minutes: 1),
        tags: ['user'],
      ),
      'static-assets': const CachePolicy(
        expiration: Duration(hours: 24),
        priority: CacheItemPriority.low,
      ),
    },
  ),
));

// Use a policy by name
await dio.get('/profile', options: Options(
  extra: {'cachePolicy': 'user-data'},
));
```

---

## Per-request granular control

Every global setting can be overridden per request via `Options.extra`:

| Extra key | Type | Description |
|---|---|---|
| `cachePolicy` | `String` | Named policy from global config |
| `perRequestCacheOptions` | `CachePolicy` | Full override of every cache option |
| `cacheControl` | `CacheControl` | normal, forceRefresh, onlyCache, noCache, noStore |
| `cacheExpiration` | `Duration` | Quick TTL override for this request |
| `cacheSlidingExpiration` | `Duration` | Quick sliding TTL override |
| `cacheTags` | `List<String>` | Tags for this cache entry |
| `cacheConditional` | `bool` | Enable ETag/If-None-Match conditional request |
| `cacheDedup` | `bool` | Enable/disable dedup for this call |
| `cacheKeyBuilder` | `CacheKeyBuilder` | Custom cache key for this request |
| `cacheSerialize` | `SerializeCache` | Custom data serializer |
| `cacheDeserialize` | `DeserializeCache` | Custom data deserializer |

### Full override example

```dart
await dio.get('/search', options: Options(extra: {
  'perRequestCacheOptions': CachePolicy(
    expiration: const Duration(seconds: 30),
    slidingExpiration: const Duration(seconds: 10),
    tags: ['search', 'volatile'],
    serialize: (data) => json.encode(data),
    deserialize: (data) => json.decode(data as String),
    maxResponseSize: 1024 * 1024,
    cacheRequest: true,
    cacheResponse: true,
  ),
}));
```

---

## Tag-based invalidation — bulk evict by group

```dart
// Assign tags to cache entries
await dio.get('/users/1', options: Options(extra: {'cacheTags': ['user']}));
await dio.get('/users/2', options: Options(extra: {'cacheTags': ['user']}));

// Invalidate everything tagged 'user' with one call
interceptor.invalidateByTag('user');

// Pattern-based invalidation
interceptor.invalidateByPathPattern(RegExp(r'/users/\d+'));
```

---

## CacheControl modes — 5 strategies per request

| Mode | Reads cache | Writes cache | Use case |
|---|---|---|---|
| `normal` | ✅ | ✅ | Default behavior |
| `forceRefresh` | ❌ | ✅ | Pull latest data, update cache |
| `onlyCache` | ✅ | ❌ | Offline-first, fail if no cache |
| `noCache` | ❌ | ✅ | Bypass cache but store response |
| `noStore` | ❌ | ❌ | Sensitive data, auth requests |

```dart
dio.get('/data', options: Options(extra: {'cacheControl': CacheControl.forceRefresh}));
dio.get('/data', options: Options(extra: {'cacheControl': CacheControl.onlyCache}));
dio.get('/data', options: Options(extra: {'cacheControl': CacheControl.noStore}));
```

---

## Request deduplication — 1 network call for N concurrent requests

When 100 widgets request the same endpoint simultaneously, only **one** hits the
network. All others wait and receive the same response.

```dart
final dio = Dio()..interceptors.add(DioCacheInterceptor(
  options: const DioCacheOptions(enableDeduplication: true),
));

// 5 concurrent calls → 1 network request
final results = await Future.wait([
  dio.get('/heavy'),
  dio.get('/heavy'),
  dio.get('/heavy'),
  dio.get('/heavy'),
  dio.get('/heavy'),
]);
// All return the same response, only 1 HTTP call made
```

Disable per-request: `extra: {'cacheDedup': false}`.

---

## Conditional requests (ETag / If-None-Match)

Bandwidth saved. Server returns `304 Not Modified` → cached body served automatically.

```dart
// First request: server returns data + ETag header
await dio.get('/resource');

// Subsequent requests: sends If-None-Match with stored ETag
final r = await dio.get('/resource', options: Options(
  extra: {'cacheConditional': true},
));
// Server: 304 → cached response used (zero data transferred)
print(r.extra['fromCache']); // true
```

---

## Stale-while-revalidate

Serve stale data instantly from cache while re-fetching in the background.
Users see cached data immediately; the UI updates when the fresh response arrives.

```dart
final dio = Dio()..interceptors.add(DioCacheInterceptor(
  options: const DioCacheOptions(
    expiration: const Duration(minutes: 5),
    staleWhileRevalidate: const Duration(minutes: 1),
  ),
));

// After 6 minutes:
// → stale cache returned INSTANTLY (no spinner)
// → network request started in background
// → next request gets fresh data
```

---

## Serialization / deserialization

Custom hooks for binary data, protobuf, or any non-JSON format:

```dart
await dio.get('/binary', options: Options(extra: {
  'perRequestCacheOptions': CachePolicy(
    serialize: (data) => (data as Uint8List).toList(), // binary → list
    deserialize: (data) => Uint8List.fromList(data as List<int>), // list → binary
  ),
}));
```

---

## Full API reference

### DioCacheOptions — global configuration

| Property | Type | Default | Description |
|---|---|---|---|
| `expiration` | `Duration?` | null | Global cache TTL |
| `slidingExpiration` | `Duration?` | null | Reset TTL on each cache hit |
| `staleWhileRevalidate` | `Duration?` | null | Serve stale + background refresh |
| `priority` | `CacheItemPriority` | normal | Eviction priority |
| `maxResponseSize` | `int?` | null | Max bytes to cache per response |
| `cacheMethods` | `Set<String>` | `{'GET'}` | HTTP methods to cache |
| `autoInvalidateOnMutation` | `bool` | true | POST/PUT/DELETE evicts related GETs |
| `enableDeduplication` | `bool` | false | Concurrent request dedup |
| `policies` | `Map<String, CachePolicy>` | `{}` | Named cache policies |
| `keyBuilder` | `CacheKeyBuilder?` | null | Custom cache key function |
| `shouldCacheResponse` | `ShouldCacheResponse?` | null | Filter which responses to cache |
| `shouldCacheRequest` | `ShouldCacheRequest?` | null | Filter which requests to cache |

### DioCacheInterceptor — instance methods

| Method | Description |
|---|---|
| `invalidateByTag(String tag)` | Remove all entries with given tag |
| `invalidateByPathPattern(RegExp pattern)` | Remove all entries matching URL pattern |
| `cache` | Access underlying `MemoryCache` (clear, stats, etc.) |

### CachePolicy — per-request override

| Property | Type | Overrides |
|---|---|---|
| `expiration` | `Duration?` | Absolute TTL |
| `slidingExpiration` | `Duration?` | Sliding TTL |
| `staleWhileRevalidate` | `Duration?` | Stale window |
| `priority` | `CacheItemPriority?` | Eviction priority |
| `maxResponseSize` | `int?` | Max bytes to cache |
| `tags` | `List<String>` | Tags for invalidation |
| `serialize` | `SerializeCache?` | Data serializer |
| `deserialize` | `DeserializeCache?` | Data deserializer |
| `cacheRequest` | `bool?` | Override whether to read from cache |
| `cacheResponse` | `bool?` | Override whether to write to cache |

---

## Integration with openapi_flutter_gen

Transparent with code generated by `openapi_flutter_gen`. Add the interceptor
to the Dio instance and all generated API calls are cached automatically:

```dart
final client = ApiClient(
  baseUrl: 'https://api.example.com',
  bearer: BearerSecurity(token: jwt),
  dio: Dio()..interceptors.add(DioCacheInterceptor(
    options: DioCacheOptions(expiration: const Duration(minutes: 5)),
  )),
  errorHandler: ApiErrorInterceptor(onUnauthorized: (_) => logout()),
);

// All generated calls are cached transparently
final result = await client.pets.listPets();  // network
final cached = await client.pets.listPets();  // cache hit
```

Still use per-request control:

```dart
final result = await client.users.getUser(
  userId: '123',
  extra: {'cacheControl': CacheControl.forceRefresh},
);
```

---

## License

**Dual-licensed.**

### Open Source — GNU AGPL v3

You can use, modify, and distribute this software freely under the terms of the
[GNU Affero General Public License v3](LICENSE).

### Commercial License

If the AGPL does not fit your business model, a **commercial license** is available.

[Contact us](mailto:developers@purplesoft.io) for pricing and terms.
