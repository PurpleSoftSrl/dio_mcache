## 0.1.1

- Fix pub.dev topics (max 5)

## 0.1.0

- Initial release
- CachePolicy system with named policies and per-request override
- CacheControl: 5 modes (normal, forceRefresh, onlyCache, noCache, noStore)
- Tag-based cache invalidation and path-pattern invalidation
- Request deduplication (prevent concurrent identical network calls)
- Conditional requests (ETag/If-None-Match 304 support)
- Stale-while-revalidate (serve stale + background refresh)
- Custom serialization/deserialization hooks per-request
- Auto-invalidation on POST/PUT/DELETE mutations
- Response filtering callbacks (shouldCacheResponse/shouldCacheRequest)
- Builds on mcache_dart with HashMap + custom LRU
- 34 integration tests against real HTTP server
