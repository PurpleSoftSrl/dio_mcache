import 'package:dio/dio.dart';
import 'package:dio_mcache/dio_mcache.dart';

Future<void> main() async {
  final dio = Dio(BaseOptions(baseUrl: 'https://jsonplaceholder.typicode.com'));

  // Add the cache interceptor
  dio.interceptors.add(DioCacheInterceptor(
    options: DioCacheOptions(
      expiration: const Duration(minutes: 5),
      enableDeduplication: true,
    ),
  ));

  // First request — from network
  final response1 = await dio.get('/posts/1');
  print('First request: ${response1.extra['fromCache']}'); // null (network)

  // Second request — from cache
  final response2 = await dio.get('/posts/1');
  print('Second request: ${response2.extra['fromCache']}'); // true (cache)

  // Force refresh (skip cache)
  final response3 = await dio.get(
    '/posts/1',
    options: Options(extra: {'cacheControl': CacheControl.forceRefresh}),
  );
  print('Force refresh: ${response3.extra['fromCache']}'); // null (network)
}
