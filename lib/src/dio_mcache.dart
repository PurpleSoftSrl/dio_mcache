import 'dart:async';
import 'package:dio/dio.dart';
import 'package:mcache_dart/mcache_dart.dart';

// ── Enums ──────────────────────────────────────────────────

enum CacheControl {
  normal,        // use cache if available, store response
  forceRefresh,  // skip cache, force network, store response
  onlyCache,     // return only from cache, fail if miss
  noCache,       // skip cache entirely, store response
  noStore,       // skip cache entirely, do NOT store response
}

// ── Core types ─────────────────────────────────────────────

class CachedResponse {
  final dynamic data;
  final int statusCode;
  final Map<String, List<String>> headers;
  final DateTime cachedAt;
  final List<String> tags;

  CachedResponse({
    required this.data,
    required this.statusCode,
    required this.headers,
    DateTime? cachedAt,
    this.tags = const [],
  }) : cachedAt = cachedAt ?? DateTime.now();
}

typedef CacheKeyBuilder = String Function(RequestOptions options);
typedef ShouldCacheResponse = bool Function(Response response);
typedef ShouldCacheRequest = bool Function(RequestOptions options);
typedef SerializeCache = dynamic Function(dynamic data);
typedef DeserializeCache = dynamic Function(dynamic data);

// ── Cache policy ───────────────────────────────────────────

class CachePolicy {
  final Duration? expiration;
  final Duration? slidingExpiration;
  final Duration? staleWhileRevalidate;
  final CacheItemPriority? priority;
  final int? maxResponseSize;
  final bool? cacheRequest;
  final bool? cacheResponse;
  final List<String> tags;
  final SerializeCache? serialize;
  final DeserializeCache? deserialize;

  const CachePolicy({
    this.expiration,
    this.slidingExpiration,
    this.staleWhileRevalidate,
    this.priority,
    this.maxResponseSize,
    this.cacheRequest,
    this.cacheResponse,
    this.tags = const [],
    this.serialize,
    this.deserialize,
  });

  CachePolicy merge(CachePolicy other) => CachePolicy(
    expiration: other.expiration ?? expiration,
    slidingExpiration: other.slidingExpiration ?? slidingExpiration,
    staleWhileRevalidate: other.staleWhileRevalidate ?? staleWhileRevalidate,
    priority: other.priority ?? priority,
    maxResponseSize: other.maxResponseSize ?? maxResponseSize,
    cacheRequest: other.cacheRequest ?? cacheRequest,
    cacheResponse: other.cacheResponse ?? cacheResponse,
    tags: [...tags, ...other.tags],
    serialize: other.serialize ?? serialize,
    deserialize: other.deserialize ?? deserialize,
  );
}

// ── Main options ───────────────────────────────────────────

class DioCacheOptions {
  final Duration? expiration;
  final Duration? slidingExpiration;
  final Duration? staleWhileRevalidate;
  final CacheItemPriority priority;
  final int? maxResponseSize;
  final CacheKeyBuilder? keyBuilder;
  final ShouldCacheResponse? shouldCacheResponse;
  final ShouldCacheRequest? shouldCacheRequest;
  final Set<String> cacheMethods;
  final bool autoInvalidateOnMutation;
  final Map<String, CachePolicy> policies;
  final bool enableDeduplication;

  const DioCacheOptions({
    this.expiration,
    this.slidingExpiration,
    this.staleWhileRevalidate,
    this.priority = CacheItemPriority.normal,
    this.maxResponseSize,
    this.keyBuilder,
    this.shouldCacheResponse,
    this.shouldCacheRequest,
    this.cacheMethods = const {'GET'},
    this.autoInvalidateOnMutation = true,
    this.policies = const {},
    this.enableDeduplication = false,
  });

  CachePolicy toPolicy() => CachePolicy(
    expiration: expiration,
    slidingExpiration: slidingExpiration,
    staleWhileRevalidate: staleWhileRevalidate,
    priority: priority,
    maxResponseSize: maxResponseSize,
  );
}

// ── Request deduplication ──────────────────────────────────

class _DedupEntry {
  final Completer<Response> completer;
  final DateTime createdAt;
  _DedupEntry() : completer = Completer<Response>(), createdAt = DateTime.now();
}

// ── Interceptor ────────────────────────────────────────────

class DioCacheInterceptor extends Interceptor {
  final MemoryCache _cache;
  final DioCacheOptions _options;
  final Map<String, Set<String>> _tagIndex = {};
  final Map<String, _DedupEntry> _dedup = {};
  final Map<String, Set<String>> _pathKeyIndex = {};

  DioCacheInterceptor({
    MemoryCache? cache,
    DioCacheOptions? options,
  })  : _cache = cache ?? MemoryCache(),
        _options = options ?? const DioCacheOptions();

  MemoryCache get cache => _cache;

  // ── Per-request resolution ───────────────────────────────

  CachePolicy _resolvePolicy(RequestOptions options) {
    final extra = options.extra;
    var policy = _options.toPolicy();

    // Named policy from global config
    final policyName = extra['cachePolicy'];
    if (policyName is String && _options.policies.containsKey(policyName)) {
      policy = policy.merge(_options.policies[policyName]!);
    }

    // Per-request override via extra
    final perReq = extra['perRequestCacheOptions'];
    if (perReq is CachePolicy) {
      policy = policy.merge(perReq);
    }

    // Individual extra keys override for simplicity
    if (extra['cacheExpiration'] is Duration) {
      policy = policy.merge(CachePolicy(expiration: extra['cacheExpiration'] as Duration));
    }
    if (extra['cacheSlidingExpiration'] is Duration) {
      policy = policy.merge(CachePolicy(slidingExpiration: extra['cacheSlidingExpiration'] as Duration));
    }
    if (extra['cacheTags'] is List) {
      policy = policy.merge(CachePolicy(tags: List<String>.from(extra['cacheTags'] as List)));
    }
    if (extra['cacheSerialize'] is SerializeCache) {
      policy = policy.merge(CachePolicy(serialize: extra['cacheSerialize'] as SerializeCache));
    }
    if (extra['cacheDeserialize'] is DeserializeCache) {
      policy = policy.merge(CachePolicy(deserialize: extra['cacheDeserialize'] as DeserializeCache));
    }

    return policy;
  }

  String _buildKey(RequestOptions options) {
    final builder = _options.keyBuilder;
    if (builder != null) return builder(options);

    final perReqKeyBuilder = options.extra['cacheKeyBuilder'];
    if (perReqKeyBuilder is CacheKeyBuilder) return perReqKeyBuilder(options);

    final qp = options.queryParameters.isNotEmpty
        ? options.queryParameters.entries
            .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
            .join('&')
        : '';
    final url = '${options.baseUrl}${options.path}';
    var key = '${options.method}:$url${qp.isNotEmpty ? '?$qp' : ''}';

    // Include body hash for POST/PUT/etc if they're cacheable
    if (options.data != null && _options.cacheMethods.contains(options.method.toUpperCase())) {
      key += ':body:${options.data.hashCode}';
    }

    return key;
  }

  // ── Dedup helpers ────────────────────────────────────────

  Future<Response>? _dedupRequest(RequestOptions options, String key) {
    if (!_options.enableDeduplication) return null;

    // Check per-request override
    final perReqDedup = options.extra['cacheDedup'];
    if (perReqDedup is bool && !perReqDedup) return null;

    if (_dedup.containsKey(key)) {
      return _dedup[key]!.completer.future;
    }
    _dedup[key] = _DedupEntry();
    return null;
  }

  void _resolveDedup(String key, Response response) {
    final entry = _dedup.remove(key);
    entry?.completer.complete(response);
  }

  void _rejectDedup(String key, Object error) {
    final entry = _dedup.remove(key);
    entry?.completer.completeError(error);
  }

  // ── onRequest ────────────────────────────────────────────

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    final cacheControl = _getCacheControl(options);
    final policy = _resolvePolicy(options);

    if (cacheControl == CacheControl.noCache || cacheControl == CacheControl.noStore) {
      handler.next(options);
      return;
    }

    final key = _buildKey(options);

    // Dedup check
    final dedupFuture = _dedupRequest(options, key);
    if (dedupFuture != null) {
      try {
        final response = await dedupFuture;
        handler.resolve(response);
      } catch (_) {
        handler.next(options);
      }
      return;
    }

    // Only cache configured methods
    final method = options.method.toUpperCase();
    if (!_options.cacheMethods.contains(method) &&
        policy.cacheRequest != true) {
      handler.next(options);
      return;
    }

    if (_options.shouldCacheRequest?.call(options) == false) {
      handler.next(options);
      return;
    }

    if (cacheControl != CacheControl.forceRefresh) {
      final cached = _cache.get(key);
      if (cached is CachedResponse) {
        // Deserialize if needed
        final data = policy.deserialize != null
            ? policy.deserialize!(cached.data)
            : cached.data;

        if (cacheControl == CacheControl.onlyCache) {
          handler.resolve(_buildResponse(options, data, cached));
          return;
        }

        final staleDuration = policy.staleWhileRevalidate ??
            _options.staleWhileRevalidate;
        if (staleDuration != null) {
          final age = DateTime.now().difference(cached.cachedAt);
          if (age < staleDuration) {
            handler.resolve(_buildResponse(options, data, cached));
            // Re-fetch in background (stale-while-revalidate)
            _revalidateInBackground(options, key, policy);
            return;
          }
        }

        handler.resolve(_buildResponse(options, data, cached));
        return;
      }
    }

    // Conditional request — add If-None-Match header if available
    if (options.extra['cacheConditional'] == true) {
      final cached = _cache.get(key);
      if (cached is CachedResponse) {
        final etag = cached.headers['etag']?.firstOrNull ??
            cached.headers['ETag']?.firstOrNull;
        final lastModified = cached.headers['last-modified']?.firstOrNull ??
            cached.headers['Last-Modified']?.firstOrNull;
        if (etag != null) {
          options.headers['If-None-Match'] = etag;
        }
        if (lastModified != null) {
          options.headers['If-Modified-Since'] = lastModified;
        }
      }
    }

    handler.next(options);
  }

  Future<void> _revalidateInBackground(
      RequestOptions options, String key, CachePolicy policy) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: options.baseUrl,
        headers: Map.from(options.headers),
      ));
      final response = await dio.request(
        options.path,
        data: options.data,
        queryParameters: options.queryParameters,
        options: Options(method: options.method),
      );
      _storeResponse(key, response, policy);
    } catch (_) {
      // Background revalidation failure — ignore
    }
  }

  // ── onResponse ───────────────────────────────────────────

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final cacheControl = _getCacheControl(response.requestOptions);
    final policy = _resolvePolicy(response.requestOptions);
    final key = _buildKey(response.requestOptions);

    // Resolve any pending dedup
    _resolveDedup(key, response);

    if (cacheControl == CacheControl.noStore) {
      handler.next(response);
      return;
    }

    if (_options.shouldCacheResponse?.call(response) == false &&
        policy.cacheResponse != true) {
      handler.next(response);
      return;
    }

    final statusCode = response.statusCode ?? 0;

    // Conditional 304 — return cached version
    if (statusCode == 304 && response.requestOptions.extra['cacheConditional'] == true) {
      final cached = _cache.get(key);
      if (cached is CachedResponse) {
        final data = policy.deserialize != null
            ? policy.deserialize!(cached.data)
            : cached.data;
        handler.resolve(_buildResponse(response.requestOptions, data, cached));
        return;
      }
    }

    if (statusCode < 200 || statusCode >= 400) {
      handler.next(response);
      return;
    }

    _storeResponse(key, response, policy);
    handler.next(response);
  }

  void _storeResponse(String key, Response response, CachePolicy policy) {
    final maxSize = policy.maxResponseSize ?? _options.maxResponseSize;
    if (maxSize != null && _estimateSize(response.data) > maxSize) return;

    if (_options.autoInvalidateOnMutation &&
        response.requestOptions.method.toUpperCase() != 'GET') {
      _invalidateRelatedGetKeys(response.requestOptions.path);
    }

    // Serialize if needed
    final data = policy.serialize != null
        ? policy.serialize!(response.data)
        : response.data;

    final tags = policy.tags;
    for (final tag in tags) {
      _tagIndex.putIfAbsent(tag, () => {}).add(key);
    }

    // Track key for path-based invalidation
    final pathBase = response.requestOptions.path.split('/').take(3).join('/');
    _pathKeyIndex.putIfAbsent(pathBase, () => {}).add(key);

    final opts = MemoryCacheEntryOptions()
      ..priority = policy.priority ?? _options.priority;
    final exp = policy.expiration ?? _options.expiration;
    if (exp != null) {
      opts.absoluteExpirationRelativeToNow = exp;
    }
    final slideExp = policy.slidingExpiration ?? _options.slidingExpiration;
    if (slideExp != null) {
      opts.slidingExpiration = slideExp;
    }

    _cache.set(key, CachedResponse(
      data: data,
      statusCode: response.statusCode ?? 200,
      headers: _extractHeaders(response),
      tags: tags,
    ), opts);
  }

  // ── Invalidation ─────────────────────────────────────────

  void _invalidateRelatedGetKeys(String path) {
    final base = path.split('/').take(3).join('/');
    for (final key in _pathKeyIndex[base] ?? {}) {
      _cache.remove(key);
    }
    _pathKeyIndex.remove(base);
  }

  void invalidateByTag(String tag) {
    for (final key in _tagIndex[tag] ?? {}) {
      _cache.remove(key);
    }
    _tagIndex.remove(tag);
  }

  void invalidateByPathPattern(RegExp pattern) {
    final toRemove = <String>[];
    for (final entry in _pathKeyIndex.entries) {
      if (pattern.hasMatch(entry.key)) {
        toRemove.add(entry.key);
      }
    }
    for (final base in toRemove) {
      for (final key in _pathKeyIndex[base] ?? {}) {
        _cache.remove(key);
      }
      _pathKeyIndex.remove(base);
    }
  }

  // ── Helpers ──────────────────────────────────────────────

  CacheControl _getCacheControl(RequestOptions options) {
    final raw = options.extra['cacheControl'];
    if (raw is CacheControl) return raw;
    if (raw is String) {
      return CacheControl.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => CacheControl.normal,
      );
    }
    return CacheControl.normal;
  }

  Response _buildResponse(
      RequestOptions options, dynamic data, CachedResponse cached) {
    return Response(
      requestOptions: options,
      data: data,
      statusCode: cached.statusCode,
      headers: Headers.fromMap(cached.headers),
      extra: {'fromCache': true, 'cachedAt': cached.cachedAt},
    );
  }

  Map<String, List<String>> _extractHeaders(Response response) {
    final map = <String, List<String>>{};
    response.headers.forEach((name, values) => map[name] = values);
    return map;
  }

  static int _estimateSize(dynamic v) {
    if (v == null) return 0;
    if (v is String) return 50 + v.length * 2;
    if (v is List) return 40 + v.length * 8;
    if (v is Map) return 40 + v.length * 64;
    return 128;
  }
  // ── onError ─────────────────────────────────────────────

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final key = _buildKey(err.requestOptions);
    _rejectDedup(key, err);
    handler.next(err);
  }
}

// ── Extension ──────────────────────────────────────────────

extension CacheControlExtension on RequestOptions {
  CacheControl get cacheControl {
    final raw = extra['cacheControl'];
    if (raw is CacheControl) return raw;
    if (raw is String) {
      return CacheControl.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => CacheControl.normal,
      );
    }
    return CacheControl.normal;
  }

  set cacheControl(CacheControl value) => extra['cacheControl'] = value;
}
