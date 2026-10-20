// Núcleo do pool (sem banco): conexões falsas.

import 'dart:async';
import 'dart:math';

import 'package:postgres_fork/src/pool_core.dart';
import 'package:test/test.dart';

class _Fake {
  _Fake(this.id);
  final int id;
  bool closed = false;
  bool dirty = false;
  bool failTest = false;
}

class _Harness {
  _Harness(PoolLimits limits, {this.failOpen = false}) {
    core = PoolCore<_Fake>(
      limits: limits,
      open: () async {
        await Future<void>.delayed(Duration.zero);
        if (failOpen) throw StateError('open failed');
        final f = _Fake(++opened);
        all.add(f);
        return f;
      },
      close: (f) async {
        f.closed = true;
        closedCount++;
      },
      isClosed: (f) => f.closed,
      test: (f) async {
        tested++;
        if (f.failTest) throw StateError('test failed');
      },
      shouldDiscard: (f) => f.dirty,
    );
  }

  late final PoolCore<_Fake> core;
  bool failOpen;
  int opened = 0;
  int closedCount = 0;
  int tested = 0;
  final all = <_Fake>[];
}

void main() {
  test('limite de conexões e reutilização', () async {
    final h = _Harness(const PoolLimits(maxConnectionCount: 3));
    var inUse = 0;
    var maxInUse = 0;
    final ids = <int>{};
    await Future.wait(List.generate(50, (i) {
      return h.core.use((f) async {
        inUse++;
        maxInUse = max(maxInUse, inUse);
        ids.add(f.id);
        await Future<void>.delayed(Duration(milliseconds: i % 3));
        inUse--;
      });
    }));
    expect(maxInUse, 3);
    expect(h.opened, 3);
    expect(ids, {1, 2, 3});
    expect(h.core.status.idleCount, 3);
    expect(h.core.status.activeCount, 0);
  });

  test('fila em ordem de chegada', () async {
    final h = _Harness(const PoolLimits(maxConnectionCount: 1));
    final order = <int>[];
    final gate = Completer<void>();
    final first = h.core.use((_) => gate.future);
    await Future<void>.delayed(Duration.zero);
    final others = [
      for (var i = 0; i < 5; i++) h.core.use((_) async => order.add(i))
    ];
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.core.status.waitingCount, 5);
    gate.complete();
    await first;
    await Future.wait(others);
    expect(order, [0, 1, 2, 3, 4]);
  });

  test('acquireTimeout', () async {
    final h = _Harness(const PoolLimits(
        maxConnectionCount: 1,
        acquireTimeout: Duration(milliseconds: 50)));
    final gate = Completer<void>();
    final busy = h.core.use((_) => gate.future);
    await expectLater(
        h.core.use((_) async {}), throwsA(isA<TimeoutException>()));
    expect(h.core.status.waitingCount, 0);
    gate.complete();
    await busy;
    await h.core.use((_) async {});
  });

  test('falha ao abrir libera a vaga e acorda quem espera', () async {
    final h = _Harness(const PoolLimits(maxConnectionCount: 1),
        failOpen: true);
    final results = await Future.wait(List.generate(
        3,
        (_) => h.core
            .use((_) async => 'ok')
            .then((v) => v, onError: (Object e) => 'erro')));
    expect(results, ['erro', 'erro', 'erro']);
    expect(h.core.status.connectionCount, 0);
    h.failOpen = false;
    expect(await h.core.use((f) async => f.id), 1);
  });

  test('descarte: TimeoutException, conexão fechada, shouldDiscard', () async {
    final h = _Harness(const PoolLimits(maxConnectionCount: 2));
    await expectLater(
        h.core.use<void>((_) async => throw TimeoutException('x')),
        throwsA(isA<TimeoutException>()));
    await expectLater(h.core.use<void>((_) async => throw StateError('sql')),
        throwsStateError);
    // Erro comum: a conexão volta ao pool.
    expect(h.core.status.idleCount, 1);
    await h.core.use((f) async => f.closed = true);
    await h.core.use((f) async => f.dirty = true);
    await Future<void>.delayed(Duration.zero);
    expect(h.core.status.idleCount, 0);
    expect(h.core.status.connectionCount, 0);
    expect(h.closedCount, 2); // a fechada pela sessão não é fechada de novo
  });

  test('limites de uso, erros e idade', () async {
    final uses = _Harness(const PoolLimits(maxConnectionCount: 1, maxUseCount: 3));
    final ids = <int>[];
    for (var i = 0; i < 7; i++) {
      await uses.core.use((f) async => ids.add(f.id));
    }
    expect(ids, [1, 1, 1, 2, 2, 2, 3]);

    final errors =
        _Harness(const PoolLimits(maxConnectionCount: 1, maxErrorCount: 2));
    for (var i = 0; i < 2; i++) {
      await errors.core
          .use<void>((_) async => throw StateError('x'))
          .catchError((_) {});
    }
    expect(await errors.core.use((f) async => f.id), 2);

    final age = _Harness(const PoolLimits(
        maxConnectionCount: 1, maxConnectionAge: Duration(milliseconds: 30)));
    expect(await age.core.use((f) async => f.id), 1);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(await age.core.use((f) async => f.id), 2);
  });

  test('teste de conexão ociosa', () async {
    final h = _Harness(const PoolLimits(
        maxConnectionCount: 1, idleTestThreshold: Duration(milliseconds: 20)));
    await h.core.use((f) async {});
    expect(await h.core.use((f) async => f.id), 1);
    expect(h.tested, 0);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    h.all.first.failTest = true;
    expect(await h.core.use((f) async => f.id), 2);
    expect(h.tested, 1);
    expect(h.all.first.closed, isTrue);
  });

  test('close espera as sessões; force fecha as conexões em uso', () async {
    final h = _Harness(const PoolLimits(maxConnectionCount: 2));
    final gate = Completer<void>();
    final running = h.core.use((_) => gate.future);
    await h.core.use((_) async {});
    await Future<void>.delayed(Duration.zero);
    final waiting = h.core.use((_) async {});
    var closed = false;
    final closing = h.core.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(closed, isFalse);
    await expectLater(h.core.use((_) async {}), throwsStateError);
    gate.complete();
    await running;
    await closing;
    expect(h.core.status.connectionCount, 0);
    expect(h.all.every((f) => f.closed), isTrue);
    // A sessão que já tinha a conexão terminou; a outra conseguiu uma
    // conexão (2 vagas) ou falhou com StateError.
    await waiting.catchError((_) {});

    final f = _Harness(const PoolLimits(maxConnectionCount: 1));
    final stuck = f.core.use((c) async {
      while (!c.closed) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await f.core.close(force: true);
    await stuck;
    expect(f.core.status.connectionCount, 0);
  });

  test('estresse aleatório: invariantes', () async {
    final random = Random(11);
    final h = _Harness(const PoolLimits(
        maxConnectionCount: 4,
        maxUseCount: 7,
        acquireTimeout: Duration(seconds: 5)));
    var inUse = 0;
    var maxInUse = 0;
    final usedConcurrently = <_Fake>{};
    var ok = 0;
    var failed = 0;
    await Future.wait(List.generate(400, (i) async {
      await Future<void>.delayed(Duration(microseconds: random.nextInt(2000)));
      try {
        await h.core.use((f) async {
          expect(usedConcurrently.add(f), isTrue,
              reason: 'conexão entregue a duas sessões');
          inUse++;
          maxInUse = max(maxInUse, inUse);
          await Future<void>.delayed(Duration(microseconds: random.nextInt(800)));
          inUse--;
          usedConcurrently.remove(f);
          switch (random.nextInt(10)) {
            case 0:
              throw TimeoutException('t');
            case 1:
              throw StateError('e');
            case 2:
              f.closed = true;
          }
        });
        ok++;
      } catch (_) {
        failed++;
      }
    }));
    expect(ok + failed, 400);
    expect(maxInUse, lessThanOrEqualTo(4));
    expect(h.core.status.activeCount, 0);
    expect(h.core.status.waitingCount, 0);
    expect(h.core.status.connectionCount, h.core.status.idleCount);
    await h.core.close();
    expect(h.all.every((f) => f.closed), isTrue);
  });
}
