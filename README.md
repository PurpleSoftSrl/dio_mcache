# dio_cache_interceptor

Hyper-configurable HTTP cache interceptor for Dio. Built on `mcache_dart`.

Full developer control: every caching behavior can be configured globally, per-request via
named policies, or overridden individually via `Options.extra`.

```dart
final dio = Dio()..interceptors.add(DioCacheInterceptor(
  options: DioCacheOptions(
    expiration: const Duration(minutes: 5),
    policies: {
      'user-data': CachePolicy(expiration: const Duration(minutes: 1), tags: ['user']),
      'static':    CachePolicy(expiration: const Duration(hours: 24), priority: CacheItemPriority.low),
    },
    enableDeduplication: true,
  ),
));
```

## Cache policies

Define named policies for different types of data, switch per-request via `cachePolicy`:

```dart
// Use a policy by name
await dio.get('/profile', options: Options(
  extra: {'cachePolicy': 'user-data'},
));

// Override everything per-request
await dio.get('/search', options: Options(extra: {
  'perRequestCacheOptions': CachePolicy(
    expiration: const Duration(seconds: 30),
    tags: ['search', 'volatile'],
    serialize: (data) => data.toString(),
    deserialize: (data) => json.decode(data),
  ),
}));
```

## Tag-based invalidation

Group cache entries with tags, invalidate by tag later:

```dart
await dio.get('/users', options: Options(
  extra: {'cacheTags': ['user']},
));

// After a mutation, invalidate all user-related caches
cacheInterceptor.invalidateByTag('user');
```

## Request deduplication

Prevent concurrent identical requests from hitting the network. The first request is served from cache on completion:

```dart
final dio = Dio()..interceptors.add(DioCacheInterceptor(
  options: DioCacheOptions(enableDeduplication: true),
));

// Even if 100 widgets call this simultaneously, only 1 network call happens
final r1 = dio.get('/heavy-endpoint');
final r2 = dio.get('/heavy-endpoint'); // waits for r1, returns same response
```

## Conditional requests (ETag)

Save bandwidth by re-validating cached responses with `If-None-Match`:

```dart
final r = await dio.get('/data', options: Options(
  extra: {'cacheConditional': true}, // sends If-None-Match header
));
// Server returns 304 → cached version used automatically
```

## Per-request granular control

Every setting overridable via `Options.extra`:

| Extra key | Type | Description |
|---|---|---|
| `cacheControl` | `CacheControl` | normal, forceRefresh, onlyCache, noCache, noStore |
| `cachePolicy` | `String` | Named policy from global config |
| `perRequestCacheOptions` | `CachePolicy` | Full override of every cache option |
| `cacheExpiration` | `Duration` | Quick TTL override |
| `cacheSlidingExpiration` | `Duration` | Quick sliding TTL override |
| `cacheTags` | `List<String>` | Tags for this entry |
| `cacheConditional` | `bool` | Enable ETag/If-None-Match |
| `cacheDedup` | `bool` | Enable/disable dedup for this request |
| `cacheKeyBuilder` | `CacheKeyBuilder` | Custom key generation |
| `cacheSerialize` | `SerializeCache` | Custom data serializer |
| `cacheDeserialize` | `DeserializeCache` | Custom data deserializer |

## CacheControl modes

```dart
// Force network, skip cache
dio.get('/data', options: Options(extra: {'cacheControl': CacheControl.forceRefresh}));

// Only return from cache
dio.get('/data', options: Options(extra: {'cacheControl': CacheControl.onlyCache}));

// Skip cache entirely, don't store
dio.get('/data', options: Options(extra: {'cacheControl': CacheControl.noStore}));
```

## Stale-while-revalidate

Serve stale data instantly while re-fetching in the background:

```dart
final dio = Dio()..interceptors.add(DioCacheInterceptor(
  options: DioCacheOptions(
    expiration: const Duration(minutes: 5),
    staleWhileRevalidate: const Duration(minutes: 1),
  ),
));
// First call: network (500ms)
// Second call after 6 minutes: stale cache NOW + background re-fetch
```

## License

AGPL v3 + Commercial — contact developers@purplesoft.io
