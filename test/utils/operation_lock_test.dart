import 'dart:async';

import 'package:postgres_fork/src/utils/operation_lock.dart';
import 'package:test/test.dart';

void main() {
  test('executa as operações uma de cada vez, em ordem de chegada', () async {
    final lock = OperationLock();
    final log = <String>[];
    var running = 0;

    Future<int> op(int id, Duration delay) => lock.withResource(() async {
          running++;
          expect(running, 1);
          log.add('start$id');
          await Future<void>.delayed(delay);
          log.add('end$id');
          running--;
          return id;
        });

    final results = await Future.wait([
      op(1, const Duration(milliseconds: 20)),
      op(2, Duration.zero),
      op(3, const Duration(milliseconds: 5)),
    ]);
    expect(results, [1, 2, 3]);
    expect(log, ['start1', 'end1', 'start2', 'end2', 'start3', 'end3']);
  });

  test('libera a trava quando o callback falha', () async {
    final lock = OperationLock();
    await expectLater(
        lock.withResource<void>(() => throw StateError('sync')),
        throwsStateError);
    await expectLater(
        lock.withResource<void>(() async => throw StateError('async')),
        throwsStateError);
    expect(await lock.withResource(() => 'ok'), 'ok');
  });

  test('aceita callbacks síncronos', () async {
    final lock = OperationLock();
    expect(await lock.withResource(() => 42), 42);
  });

  test('operação enfileirada de dentro de outra roda depois dela', () async {
    final lock = OperationLock();
    final log = <String>[];
    late Future<void> inner;
    await lock.withResource(() async {
      inner = lock.withResource(() => log.add('inner'));
      await Future<void>.delayed(Duration.zero);
      log.add('outer');
    });
    await inner;
    expect(log, ['outer', 'inner']);
  });
}
