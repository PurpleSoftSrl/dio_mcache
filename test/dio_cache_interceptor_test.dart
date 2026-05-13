import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:test/test.dart';

void main() {
  group('CachePolicy', () {
    test('merge uses other value when present', () {
      final a = CachePolicy(expiration: Duration(seconds: 10));
      final b = CachePolicy(expiration: Duration(seconds: 20));
      final merged = a.merge(b);
      expect(merged.expiration, Duration(seconds: 20));
    });

    test('merge keeps original when other is null', () {
      final a = CachePolicy(expiration: Duration(seconds: 10));
      final b = CachePolicy();
      final merged = a.merge(b);
      expect(merged.expiration, Duration(seconds: 10));
    });

    test('merge concatenates tags', () {
      final a = CachePolicy(tags: ['a']);
      final b = CachePolicy(tags: ['b']);
      final merged = a.merge(b);
      expect(merged.tags, ['a', 'b']);
    });
  });

  group('DioCacheOptions', () {
    test('toPolicy creates policy from options', () {
      final opts = DioCacheOptions(
        expiration: Duration(minutes: 5),
        priority: CacheItemPriority.high,
      );
      final policy = opts.toPolicy();
      expect(policy.expiration, Duration(minutes: 5));
      expect(policy.priority, CacheItemPriority.high);
    });
  });

  group('CacheControl', () {
    test('values exist', () {
      expect(CacheControl.values.length, 5);
    });
  });
}
