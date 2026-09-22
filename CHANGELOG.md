## 0.1.5

- Fix: a cache HIT no longer leaks its deduplication entry. A cache hit resolves
  via `handler.resolve` and never reaches `onResponse` (where the dedup entry is
  cleared), so with `enableDeduplication: true` the entry registered in
  `onRequest` was orphaned with an uncompleted completer — the NEXT identical
  request awaited it forever (an infinite spinner on a screen re-opened within
  the TTL). The cache-hit path now resolves the dedup entry with the cached
  response. Regression test added.

## 0.1.4

- Add dartdoc documentation to all public API (20%+ coverage)
- Shorten pubspec description for pub.dev scoring
- Add example/ directory with usage sample
- Bump mcache_dart dependency to ^0.1.9

## 0.1.3

- Align README badges with mcache_dart standard (dynamic pub.dev, CI, Publish, Stars, License)

## 0.1.2

- Rename package to dio_mcache for pub.dev uniqueness
- Configure OIDC automated publishing via GitHub Actions

## 0.1.1

- Fix pub.dev topics (max 5)

## 0.1.0

- Initial release: dio_mcache
- CachePolicy system with named policies and per-request override
- CacheControl: 5 modes (normal, forceRefresh, onlyCache, noCache, noStore)
- Tag-based cache invalidation and path-pattern invalidation
- Request deduplication (prevent concurrent identical network calls)
- Conditional requests (ETag/If-None-Match 304 support)
- Stale-while-revalidate (serve stale + background refresh)
- Custom serialization/deserialization hooks per-request
- Auto-invalidation on POST/PUT/DELETE mutations
- Response filtering callbacks (shouldCacheResponse/shouldCacheRequest)
- Builds on mcache_dart ^0.1.8
- 34 integration tests against real HTTP server
