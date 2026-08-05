import 'dart:async';

import 'package:reaxdb_dart/src/core/errors/exceptions.dart';
import 'package:reaxdb_dart/src/core/streams/reactive_stream.dart';
import 'package:reaxdb_dart/src/domain/entities/database_entity.dart';
import 'package:test/test.dart';

DatabaseChangeEvent event(String key, [dynamic value]) => DatabaseChangeEvent(
  type: ChangeType.put,
  key: key,
  value: value,
  timestamp: DateTime.now(),
);

void main() {
  group('ReactiveStream operators', () {
    test('operators are immutable: the base stream is unaffected', () async {
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final ReactiveStream base = ReactiveStream(controller.stream);
      final ReactiveStream limited = base.take(1);

      final List<String> baseKeys = [];
      final List<String> limitedKeys = [];
      base.listen((DatabaseChangeEvent e) => baseKeys.add(e.key));
      limited.listen((DatabaseChangeEvent e) => limitedKeys.add(e.key));

      controller.add(event('a'));
      controller.add(event('b'));
      await Future<void>.delayed(Duration.zero);

      expect(
        baseKeys,
        equals(['a', 'b']),
        reason: 'take() must not mutate the base stream',
      );
      expect(limitedKeys, equals(['a']));
      await controller.close();
    });

    test('take keeps per-subscription counters', () async {
      // Old operators captured state outside the transformer, so a second
      // listener shared the first listener's counter.
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final ReactiveStream taken = ReactiveStream(controller.stream).take(2);

      final List<String> first = [];
      final List<String> second = [];
      taken.listen((DatabaseChangeEvent e) => first.add(e.key));
      taken.listen((DatabaseChangeEvent e) => second.add(e.key));

      for (final String key in ['a', 'b', 'c']) {
        controller.add(event(key));
      }
      await Future<void>.delayed(Duration.zero);

      expect(first, equals(['a', 'b']));
      expect(
        second,
        equals(['a', 'b']),
        reason: 'each subscription must count independently',
      );
      await controller.close();
    });

    test('distinct actually suppresses repeated keys', () async {
      // The old distinct() passed every event through.
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final List<String> keys = [];
      ReactiveStream(
        controller.stream,
      ).distinct().listen((DatabaseChangeEvent e) => keys.add(e.key));

      for (final String key in ['a', 'a', 'a', 'b', 'b', 'a']) {
        controller.add(event(key));
      }
      await Future<void>.delayed(Duration.zero);

      expect(keys, equals(['a', 'b', 'a']));
      await controller.close();
    });

    test('distinct supports a custom key selector', () async {
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final List<dynamic> values = [];
      ReactiveStream(controller.stream)
          .distinct((DatabaseChangeEvent e) => e.value)
          .listen((DatabaseChangeEvent e) => values.add(e.value));

      controller.add(event('a', 1));
      controller.add(event('b', 1));
      controller.add(event('c', 2));
      await Future<void>.delayed(Duration.zero);

      expect(values, equals([1, 2]));
      await controller.close();
    });

    test('debounce emits the last event of a burst exactly once', () async {
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final List<String> keys = [];
      ReactiveStream(controller.stream)
          .debounce(const Duration(milliseconds: 30))
          .listen((DatabaseChangeEvent e) => keys.add(e.key));

      controller.add(event('a'));
      controller.add(event('b'));
      controller.add(event('c'));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(keys, equals(['c']));
      await controller.close();
    });

    test('debounce does not double-emit the final event on done', () async {
      // lastEvent was never cleared, so the completion flush re-emitted the
      // event the timer had already delivered.
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final List<String> keys = [];
      bool done = false;
      ReactiveStream(controller.stream)
          .debounce(const Duration(milliseconds: 10))
          .listen(
            (DatabaseChangeEvent e) => keys.add(e.key),
            onDone: () => done = true,
          );

      controller.add(event('a'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await controller.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(keys, equals(['a']), reason: 'exactly one emission');
      expect(done, isTrue);
    });

    test(
      'debounce flushes a pending event when the source completes',
      () async {
        final StreamController<DatabaseChangeEvent> controller =
            StreamController.broadcast();
        final List<String> keys = [];
        ReactiveStream(controller.stream)
            .debounce(const Duration(seconds: 5))
            .listen((DatabaseChangeEvent e) => keys.add(e.key));

        controller.add(event('a'));
        await Future<void>.delayed(Duration.zero);
        await controller.close();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(keys, equals(['a']));
      },
    );

    test('debounce timers are per subscription', () async {
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final ReactiveStream debounced = ReactiveStream(
        controller.stream,
      ).debounce(const Duration(milliseconds: 20));

      final List<String> first = [];
      debounced.listen((DatabaseChangeEvent e) => first.add(e.key));
      controller.add(event('a'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // A listener attaching mid-flight must not reset or share the first
      // listener's timer.
      final List<String> second = [];
      debounced.listen((DatabaseChangeEvent e) => second.add(e.key));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(first, equals(['a']));
      expect(second, isEmpty);
      await controller.close();
    });

    test('throttle drops events inside the window', () async {
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final List<String> keys = [];
      ReactiveStream(controller.stream)
          .throttle(const Duration(milliseconds: 50))
          .listen((DatabaseChangeEvent e) => keys.add(e.key));

      controller.add(event('a'));
      controller.add(event('b'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      controller.add(event('c'));
      await Future<void>.delayed(Duration.zero);

      expect(keys, equals(['a', 'c']));
      await controller.close();
    });

    test('skip ignores the first n events per subscription', () async {
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final List<String> keys = [];
      ReactiveStream(
        controller.stream,
      ).skip(2).listen((DatabaseChangeEvent e) => keys.add(e.key));

      for (final String key in ['a', 'b', 'c', 'd']) {
        controller.add(event(key));
      }
      await Future<void>.delayed(Duration.zero);

      expect(keys, equals(['c', 'd']));
      await controller.close();
    });

    test('buffer groups events and flushes the remainder on done', () async {
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final List<List<DatabaseChangeEvent>> batches = [];
      ReactiveStream(controller.stream).buffer(2).listen(batches.add);

      for (final String key in ['a', 'b', 'c']) {
        controller.add(event(key));
      }
      await Future<void>.delayed(Duration.zero);
      await controller.close();
      await Future<void>.delayed(Duration.zero);

      expect(batches, hasLength(2));
      expect(batches.first.map((e) => e.key), equals(['a', 'b']));
      expect(batches.last.map((e) => e.key), equals(['c']));
    });

    test('bufferTime flushes after the window', () async {
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final List<List<DatabaseChangeEvent>> batches = [];
      ReactiveStream(
        controller.stream,
      ).bufferTime(const Duration(milliseconds: 30)).listen(batches.add);

      controller.add(event('a'));
      controller.add(event('b'));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(batches, hasLength(1));
      expect(batches.single.map((e) => e.key), equals(['a', 'b']));
      await controller.close();
    });

    test('where and map compose', () async {
      final StreamController<DatabaseChangeEvent> controller =
          StreamController.broadcast();
      final List<String> keys = [];
      ReactiveStream(controller.stream)
          .where((DatabaseChangeEvent e) => e.key.startsWith('users:'))
          .map((DatabaseChangeEvent e) => e.key)
          .listen(keys.add);

      controller.add(event('users:1'));
      controller.add(event('orders:1'));
      await Future<void>.delayed(Duration.zero);

      expect(keys, equals(['users:1']));
      await controller.close();
    });
  });

  group('ChangeStreamHub', () {
    test('routes exact, prefix and glob patterns', () async {
      final ChangeStreamHub hub = ChangeStreamHub();
      final List<String> exact = [];
      final List<String> prefixed = [];
      final List<String> globbed = [];
      final List<String> all = [];

      hub.watch('users:1').listen((e) => exact.add(e.key));
      hub.watch('users:*').listen((e) => prefixed.add(e.key));
      hub.watch('users:*:meta').listen((e) => globbed.add(e.key));
      hub.watch('*').listen((e) => all.add(e.key));
      await Future<void>.delayed(Duration.zero);

      hub.publish(event('users:1'));
      hub.publish(event('users:2:meta'));
      hub.publish(event('orders:9'));
      await Future<void>.delayed(Duration.zero);

      expect(exact, equals(['users:1']));
      expect(prefixed, equals(['users:1', 'users:2:meta']));
      expect(globbed, equals(['users:2:meta']));
      expect(all, equals(['users:1', 'users:2:meta', 'orders:9']));
      await hub.close();
    });

    test('controllers are released when the last subscriber leaves', () async {
      // Pattern controllers used to accumulate forever.
      final ChangeStreamHub hub = ChangeStreamHub();
      final List<StreamSubscription<DatabaseChangeEvent>> subscriptions = [];
      for (int i = 0; i < 100; i++) {
        subscriptions.add(hub.watch('pattern$i:*').listen((_) {}));
      }
      await Future<void>.delayed(Duration.zero);
      expect(hub.activePatternCount, equals(100));

      for (final StreamSubscription<DatabaseChangeEvent> subscription
          in subscriptions) {
        await subscription.cancel();
      }
      await Future<void>.delayed(Duration.zero);
      expect(hub.activePatternCount, equals(0));
      await hub.close();
    });

    test('two subscribers to one pattern share a controller', () async {
      final ChangeStreamHub hub = ChangeStreamHub();
      final List<String> a = [];
      final List<String> b = [];
      final StreamSubscription<DatabaseChangeEvent> subA = hub
          .watch('k:*')
          .listen((e) => a.add(e.key));
      hub.watch('k:*').listen((e) => b.add(e.key));
      await Future<void>.delayed(Duration.zero);
      expect(hub.activePatternCount, equals(1));

      hub.publish(event('k:1'));
      await Future<void>.delayed(Duration.zero);
      expect(a, equals(['k:1']));
      expect(b, equals(['k:1']));

      await subA.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(
        hub.activePatternCount,
        equals(1),
        reason: 'controller stays while one subscriber remains',
      );
      await hub.close();
    });

    test('watch with initial snapshot misses no interleaved write', () async {
      final ChangeStreamHub hub = ChangeStreamHub();
      final Completer<void> snapshotGate = Completer<void>();
      final List<String> keys = [];

      hub
          .watch(
            'users:*',
            initialEvents: () async {
              await snapshotGate.future;
              return [event('users:snapshot')];
            },
          )
          .listen((e) => keys.add(e.key));
      await Future<void>.delayed(Duration.zero);

      // A write races the snapshot load: it must be delivered afterwards,
      // not silently dropped.
      hub.publish(event('users:live-during-snapshot'));
      snapshotGate.complete();
      await Future<void>.delayed(Duration.zero);
      hub.publish(event('users:live-after'));
      await Future<void>.delayed(Duration.zero);

      expect(
        keys,
        equals([
          'users:snapshot',
          'users:live-during-snapshot',
          'users:live-after',
        ]),
      );
      await hub.close();
    });

    test('snapshot loader errors surface on the stream', () async {
      final ChangeStreamHub hub = ChangeStreamHub();
      final List<Object> errors = [];
      hub
          .watch('k', initialEvents: () async => throw StateError('boom'))
          .listen((_) {}, onError: errors.add);
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      await hub.close();
    });

    test('publish after close throws DatabaseClosedException', () async {
      final ChangeStreamHub hub = ChangeStreamHub();
      await hub.close();
      expect(
        () => hub.publish(event('k')),
        throwsA(isA<DatabaseClosedException>()),
      );
      expect(() => hub.watch('k'), throwsA(isA<DatabaseClosedException>()));
    });
  });
}
