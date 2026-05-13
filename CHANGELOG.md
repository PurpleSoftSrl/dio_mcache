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
