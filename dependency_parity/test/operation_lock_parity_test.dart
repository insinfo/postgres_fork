// Compara lib/src/utils/operation_lock.dart com `Pool(1)` do pacote `pool`
// 1.5.1, usado apenas via `withResource`.
//
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:math';

import 'package:pool/pool.dart';
import 'package:postgres_fork/src/utils/operation_lock.dart';
import 'package:test/test.dart';

typedef _WithResource = Future<T> Function<T>(FutureOr<T> Function() callback);

/// Executa um cenário aleatório (determinístico pela [seed]) e retorna o log
/// de eventos, incluindo marcadores de microtasks e timers para capturar a
/// ordem exata de intercalação.
Future<List<String>> _runScenario(int seed, _WithResource withResource) async {
  final random = Random(seed);
  final log = <String>[];
  final futures = <Future<void>>[];
  var tick = 0;

  // "Relógio" de microtasks: registra a passagem de microtasks.
  void scheduleTicks(int count) {
    for (var i = 0; i < count; i++) {
      scheduleMicrotask(() => log.add('tick${tick++}'));
    }
  }

  late final Future<void> Function(int id, int kind) run;

  Future<void> body(int id, int kind) async {
    log.add('start$id');
    switch (kind) {
      case 0: // termina imediatamente (síncrono)
        break;
      case 1: // aguarda microtasks
        await Future<void>.value();
        await null;
        break;
      case 2: // aguarda um timer
        await Future<void>.delayed(Duration.zero);
        break;
      case 3: // erro síncrono
        log.add('throwSync$id');
        throw StateError('sync $id');
      case 4: // erro assíncrono
        await Future<void>.value();
        log.add('throwAsync$id');
        throw StateError('async $id');
      case 5: // dispara outra operação de dentro (sem aguardar)
        futures.add(run(id * 100, random.nextInt(3)));
        await Future<void>.value();
        break;
    }
    log.add('end$id');
  }

  run = (int id, int kind) {
    log.add('request$id');
    scheduleTicks(random.nextInt(3));
    final Future<String> future;
    if (kind == 0 && random.nextBool()) {
      // Callback que retorna um valor não-Future.
      future = withResource<String>(() {
        log.add('start$id');
        log.add('end$id');
        return 'sync$id';
      });
    } else {
      future = withResource<String>(() async {
        await body(id, kind);
        return 'value$id';
      });
    }
    return future.then((value) {
      log.add('done$id:$value');
    }, onError: (Object e) {
      log.add('error$id:$e');
    });
  };

  final count = 1 + random.nextInt(8);
  for (var i = 0; i < count; i++) {
    final mode = random.nextInt(3);
    if (mode == 0) {
      futures.add(run(i, random.nextInt(6)));
    } else if (mode == 1) {
      await Future<void>.value();
      futures.add(run(i, random.nextInt(6)));
    } else {
      scheduleMicrotask(() => futures.add(run(i, random.nextInt(6))));
    }
  }
  // Espera até que todas as operações (inclusive as aninhadas) terminem.
  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final pending = List.of(futures);
    await Future.wait(pending);
    if (pending.length == futures.length) break;
  }
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return log;
}

void main() {
  test('mesma ordem de eventos em cenários aleatórios', () async {
    for (var seed = 0; seed < 1500; seed++) {
      final pool = Pool(1);
      final lock = OperationLock();
      final expected = await _runScenario(seed, pool.withResource);
      final actual = await _runScenario(seed, lock.withResource);
      expect(actual, expected, reason: 'seed $seed');
    }
    // Cada cenário espera timers de 1 ms; no Windows a resolução padrão dos
    // timers é ~15,6 ms, então o teste pode levar mais de um minuto.
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('erros são repassados com o mesmo tipo e stack trace do callback',
      () async {
    final pool = Pool(1);
    final lock = OperationLock();
    for (final withResource in <_WithResource>[
      pool.withResource,
      lock.withResource
    ]) {
      final error = StateError('x');
      await expectLater(
          withResource<void>(() => throw error), throwsA(same(error)));
      await expectLater(
          withResource<void>(() async => throw error), throwsA(same(error)));
      // A trava continua utilizável depois de erros.
      expect(await withResource(() => 42), 42);
    }
  });
}
