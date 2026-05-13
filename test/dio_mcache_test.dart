import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio_mcache/dio_mcache.dart';
import 'package:mcache_dart/mcache_dart.dart';
import 'package:test/test.dart';

HttpServer? _server;
Dio? _dio;
DioCacheInterceptor? _interceptor;
int _requestCount = 0;

Future<void> startServer() async {
  _requestCount = 0;
  _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _server!.listen((req) {
    _requestCount++;
    final path = req.uri.path;
    final statusCode = int.tryParse(req.headers['x-response-status']?.first ?? '') ?? 200;

    if (path == '/etag-test') {
      final etag = req.headers['if-none-match']?.first;
      if (etag == '"abc123"') {
        req.response.statusCode = 304;
        req.response.close();
        return;
      }
      req.response.headers.set('ETag', '"abc123"');
    }

    req.response.statusCode = statusCode;
    req.response.headers.set('content-type', 'application/json');
    req.response.write(jsonEncode({
      'path': path,
      'requestCount': _requestCount,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    }));
    req.response.close();
  });

  final baseUrl = 'http://localhost:${_server!.port}';
  _interceptor = DioCacheInterceptor();
  _dio = Dio(BaseOptions(baseUrl: baseUrl))
    ..interceptors.add(_interceptor!);
}

Future<void> stopServer() async {
  _dio?.close();
  _dio = null;
  await _server?.close(force: true);
  _server = null;
  _interceptor?.cache.clear();
  _interceptor = null;
}

void main() {
  // ═══════════════════════════════════════════════════════════
  // Cache Policy (unit — no server needed)
  // ═══════════════════════════════════════════════════════════
  group('CachePolicy', () {
    test('merge uses other value', () {
      final a = CachePolicy(expiration: const Duration(seconds: 10));
      final b = CachePolicy(expiration: const Duration(seconds: 20));
      expect(a.merge(b).expiration, const Duration(seconds: 20));
    });

    test('merge keeps original when other null', () {
      final a = CachePolicy(expiration: const Duration(seconds: 10));
      final b = CachePolicy();
      expect(a.merge(b).expiration, const Duration(seconds: 10));
    });

    test('merge concatenates tags', () {
      final a = CachePolicy(tags: ['a', 'b']);
      final b = CachePolicy(tags: ['c']);
      expect(a.merge(b).tags, ['a', 'b', 'c']);
    });

    test('merge preserves serialization hooks', () {
      final serialize = (dynamic d) => d.toString();
      final deserialize = (dynamic d) => int.parse(d as String);
      final a = CachePolicy(serialize: serialize);
      final b = CachePolicy(deserialize: deserialize);
      final merged = a.merge(b);
      expect(merged.serialize, same(serialize));
      expect(merged.deserialize, same(deserialize));
    });

    test('all fields independently settable', () {
      final policy = CachePolicy(
        expiration: const Duration(minutes: 5),
        slidingExpiration: const Duration(minutes: 1),
        staleWhileRevalidate: const Duration(seconds: 30),
        priority: CacheItemPriority.high,
        maxResponseSize: 1024,
        cacheRequest: true,
        cacheResponse: false,
        tags: ['test'],
      );
      expect(policy.expiration, const Duration(minutes: 5));
      expect(policy.slidingExpiration, const Duration(minutes: 1));
      expect(policy.staleWhileRevalidate, const Duration(seconds: 30));
      expect(policy.priority, CacheItemPriority.high);
      expect(policy.maxResponseSize, 1024);
      expect(policy.cacheRequest, isTrue);
      expect(policy.cacheResponse, isFalse);
      expect(policy.tags, ['test']);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // DioCacheOptions
  // ═══════════════════════════════════════════════════════════
  group('DioCacheOptions', () {
    test('defaults', () {
      const opts = DioCacheOptions();
      expect(opts.expiration, isNull);
      expect(opts.cacheMethods, {'GET'});
      expect(opts.autoInvalidateOnMutation, isTrue);
      expect(opts.enableDeduplication, isFalse);
      expect(opts.policies, isEmpty);
    });

    test('toPolicy maps all properties', () {
      final opts = DioCacheOptions(
        expiration: const Duration(minutes: 10),
        slidingExpiration: const Duration(seconds: 30),
        staleWhileRevalidate: const Duration(minutes: 1),
        priority: CacheItemPriority.high,
        maxResponseSize: 5000,
      );
      final p = opts.toPolicy();
      expect(p.expiration, const Duration(minutes: 10));
      expect(p.slidingExpiration, const Duration(seconds: 30));
      expect(p.staleWhileRevalidate, const Duration(minutes: 1));
      expect(p.priority, CacheItemPriority.high);
      expect(p.maxResponseSize, 5000);
    });

    test('named policies are stored', () {
      final opts = DioCacheOptions(policies: {
        'short': const CachePolicy(expiration: Duration(seconds: 10)),
        'long': const CachePolicy(expiration: Duration(hours: 24)),
      });
      expect(opts.policies['short']?.expiration, const Duration(seconds: 10));
      expect(opts.policies['long']?.expiration, const Duration(hours: 24));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // CacheControl
  // ═══════════════════════════════════════════════════════════
  group('CacheControl', () {
    test('5 values', () {
      expect(CacheControl.values.length, 5);
    });

    test('RequestOptions extension get/set', () {
      final opts = RequestOptions(path: '/test');
      opts.cacheControl = CacheControl.onlyCache;
      expect(opts.cacheControl, CacheControl.onlyCache);
    });

    test('reads from string', () {
      final opts = RequestOptions(path: '/test',
        extra: {'cacheControl': 'forceRefresh'});
      expect(opts.cacheControl, CacheControl.forceRefresh);
    });

    test('unknown string returns normal', () {
      final opts = RequestOptions(path: '/test',
        extra: {'cacheControl': 'invalid'});
      expect(opts.cacheControl, CacheControl.normal);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Integration — real HTTP server
  // ═══════════════════════════════════════════════════════════
  group('Integration', () {
    setUp(startServer);
    tearDown(stopServer);

    test('cache hit returns cached response', () async {
      final r1 = await _dio!.get('/data');
      expect(r1.extra['fromCache'], isNull);
      final r2 = await _dio!.get('/data');
      expect(r2.extra['fromCache'], isTrue);
      expect(_requestCount, 1);
    });

    test('forceRefresh bypasses cache', () async {
      await _dio!.get('/data');
      await _dio!.get('/data', options: Options(
        extra: {'cacheControl': CacheControl.forceRefresh}));
      expect(_requestCount, 2);
    });

    test('onlyCache does not hit network', () async {
      await _dio!.get('/data');
      final r = await _dio!.get('/data', options: Options(
        extra: {'cacheControl': CacheControl.onlyCache}));
      expect(r.extra['fromCache'], isTrue);
      expect(_requestCount, 1);
    });

    test('noCache skips cache but stores response', () async {
      await _dio!.get('/data');
      final r = await _dio!.get('/data', options: Options(
        extra: {'cacheControl': CacheControl.noCache}));
      expect(r.extra['fromCache'], isNull);
      expect(_requestCount, 2);
      final r3 = await _dio!.get('/data');
      expect(r3.extra['fromCache'], isTrue);
    });

    test('noStore neither reads nor writes cache', () async {
      await _dio!.get('/data');
      await _dio!.get('/data', options: Options(
        extra: {'cacheControl': CacheControl.noStore}));
      await _dio!.get('/data', options: Options(
        extra: {'cacheControl': CacheControl.forceRefresh}));
      expect(_requestCount, 3);
    });

    test('POST not cached by default', () async {
      await _dio!.post('/data');
      await _dio!.post('/data');
      expect(_requestCount, 2);
    });

    test('custom cache methods via options', () async {
      _dio!.interceptors.clear();
      final interceptor = DioCacheInterceptor(
        options: const DioCacheOptions(cacheMethods: {'GET', 'POST'}),
      );
      _dio!.interceptors.add(interceptor);
      await _dio!.post('/data');
      final r = await _dio!.post('/data');
      expect(r.extra['fromCache'], isTrue);
      expect(_requestCount, 1);
    });

    test('custom key builder', () async {
      _dio!.interceptors.clear();
      final interceptor = DioCacheInterceptor(
        options: DioCacheOptions(
          keyBuilder: (opts) => 'custom:${opts.path}',
        ),
      );
      _dio!.interceptors.add(interceptor);
      await _dio!.get('/a');
      await _dio!.get('/b');
      expect(interceptor.cache.count, 2);
    });

    test('expiration evicts entry', () async {
      _dio!.interceptors.clear();
      final interceptor = DioCacheInterceptor(
        options: const DioCacheOptions(expiration: Duration(milliseconds: 50)),
      );
      _dio!.interceptors.add(interceptor);
      await _dio!.get('/data');
      await Future.delayed(const Duration(milliseconds: 100));
      final r = await _dio!.get('/data');
      expect(r.extra['fromCache'], isNull);
      expect(_requestCount, 2);
    });

    test('shouldCacheResponse filter', () async {
      _dio!.interceptors.clear();
      final interceptor = DioCacheInterceptor(
        options: DioCacheOptions(
          cacheMethods: {'GET', 'POST'},
          shouldCacheResponse: (r) => r.statusCode == 201,
        ),
      );
      _dio!.interceptors.add(interceptor);
      await _dio!.post('/data');
      final r = await _dio!.post('/data');
      expect(r.extra['fromCache'], isNull);
      expect(_requestCount, 2);
    });

    test('shouldCacheRequest filter', () async {
      _dio!.interceptors.clear();
      final interceptor = DioCacheInterceptor(
        options: DioCacheOptions(
          shouldCacheRequest: (opts) => !opts.path.contains('skip'),
        ),
      );
      _dio!.interceptors.add(interceptor);
      await _dio!.get('/data');
      await _dio!.get('/skip');
      final r = await _dio!.get('/data');
      expect(r.extra['fromCache'], isTrue);
    });

    test('304 conditional request', () async {
      _dio!.interceptors.clear();
      final interceptor = DioCacheInterceptor();
      _dio!.interceptors.add(interceptor);

      await _dio!.get('/etag-test');
      expect(_requestCount, 1);

      final r2 = await _dio!.get('/etag-test', options: Options(
        extra: {'cacheConditional': true}),
      );
      expect(r2.extra['fromCache'], isTrue);
      expect(_requestCount, 1); // 304 returned from cache, no extra network call
    });

    test('tag invalidation removes tagged entries', () async {
      await _dio!.get('/a', options: Options(
        extra: {'cacheTags': ['group-x']}));
      await _dio!.get('/b', options: Options(
        extra: {'cacheTags': ['group-x']}));
      await _dio!.get('/c', options: Options(
        extra: {'cacheTags': ['group-y']}));

      _interceptor!.invalidateByTag('group-x');

      expect(_interceptor!.cache.count, 1);
      final r = await _dio!.get('/c');
      expect(r.extra['fromCache'], isTrue);
    });

    test('path pattern invalidation', () async {
      await _dio!.get('/users/1');
      await _dio!.get('/users/2');
      await _dio!.get('/products/1');

      _interceptor!.invalidateByPathPattern(RegExp(r'/users/.*'));

      final u1 = await _dio!.get('/users/1');
      expect(u1.extra['fromCache'], isNull);
      final p1 = await _dio!.get('/products/1');
      expect(p1.extra['fromCache'], isTrue);
    });

    test('per-request override via named policy', () async {
      _dio!.interceptors.clear();
      final interceptor = DioCacheInterceptor(
        options: DioCacheOptions(policies: {
          'short': const CachePolicy(expiration: Duration(milliseconds: 20)),
        }),
      );
      _dio!.interceptors.add(interceptor);

      await _dio!.get('/data', options: Options(
        extra: {'cachePolicy': 'short'}));
      await Future.delayed(const Duration(milliseconds: 50));
      final r = await _dio!.get('/data');
      expect(r.extra['fromCache'], isNull);
    });

    test('per-request CachePolicy overrides global', () async {
      _dio!.interceptors.clear();
      final interceptor = DioCacheInterceptor(
        options: const DioCacheOptions(expiration: Duration(hours: 1)),
      );
      _dio!.interceptors.add(interceptor);

      await _dio!.get('/data', options: Options(extra: {
        'perRequestCacheOptions': const CachePolicy(expiration: Duration(milliseconds: 20)),
      }));
      await Future.delayed(const Duration(milliseconds: 50));
      final r = await _dio!.get('/data');
      expect(r.extra['fromCache'], isNull);
    });

    test('quick extra keys work', () async {
      await _dio!.get('/data', options: Options(extra: {
        'cacheExpiration': const Duration(milliseconds: 20),
        'cacheTags': ['ephemeral'],
      }));
      await Future.delayed(const Duration(milliseconds: 50));
      final r = await _dio!.get('/data');
      expect(r.extra['fromCache'], isNull);
      _interceptor!.invalidateByTag('ephemeral');
      expect(_interceptor!.cache.count, 0);
    });

    test('autoInvalidateOnMutation clears related GETs', () async {
      await _dio!.get('/users/1');
      await _dio!.post('/users/1');
      final r = await _dio!.get('/users/1');
      expect(r.extra['fromCache'], isNull);
    });

    test('5xx responses not cached', () async {
      final dio = Dio(BaseOptions(
        baseUrl: 'http://localhost:${_server!.port}',
        validateStatus: (s) => true, // accept all status codes
      ));
      final interceptor = DioCacheInterceptor();
      dio.interceptors.add(interceptor);

      await dio.get('/error', options: Options(
        headers: {'x-response-status': '500'}));
      final r = await dio.get('/error', options: Options(
        headers: {'x-response-status': '500'}));
      expect(r.extra['fromCache'], isNull);
      expect(_requestCount, 2);
    });

    test('max response size filter', () async {
      _dio!.interceptors.clear();
      final interceptor = DioCacheInterceptor(
        options: const DioCacheOptions(maxResponseSize: 10),
      );
      _dio!.interceptors.add(interceptor);
      await _dio!.get('/data');
      final r = await _dio!.get('/data');
      expect(r.extra['fromCache'], isNull);
    });

    test('clear cache', () {
      _interceptor!.cache.set('test', 'value');
      expect(_interceptor!.cache.count, 1);
      _interceptor!.cache.clear();
      expect(_interceptor!.cache.count, 0);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // Deduplication
  // ═══════════════════════════════════════════════════════════
  group('Deduplication', () {
    late HttpServer srv;
    late Dio dio;
    late DioCacheInterceptor interceptor;

    setUp(() async {
      srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((req) async {
        await Future.delayed(const Duration(milliseconds: 100));
        req.response.headers.set('content-type', 'application/json');
        req.response.write(jsonEncode({'path': req.uri.path}));
        req.response.close();
      });
      interceptor = DioCacheInterceptor(
        options: const DioCacheOptions(enableDeduplication: true),
      );
      dio = Dio(BaseOptions(baseUrl: 'http://localhost:${srv.port}'))
        ..interceptors.add(interceptor);
    });

    tearDown(() async {
      dio.close();
      await srv.close(force: true);
    });

    test('concurrent requests deduplicated', () async {
      final futures = List.generate(5, (_) => dio.get('/slow'));
      final results = await Future.wait(futures);
      final first = results.first.data['path'];
      for (final r in results) {
        expect(r.data['path'], first);
      }
    });
  });
}
