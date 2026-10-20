import 'dart:async';
import 'dart:collection';

/// Limites de um pool de conexões.
class PoolLimits {
  /// Número máximo de conexões abertas ao mesmo tempo.
  final int maxConnectionCount;

  /// Conexões abertas há mais tempo que isso não são mais reutilizadas.
  final Duration? maxConnectionAge;

  /// Conexões usadas (somando o tempo das sessões) por mais tempo que isso
  /// não são mais reutilizadas.
  final Duration? maxSessionUse;

  /// Conexões cujas sessões falharam esse número de vezes não são mais
  /// reutilizadas.
  final int? maxErrorCount;

  /// Conexões usadas por esse número de sessões não são mais reutilizadas.
  final int? maxUseCount;

  /// Uma conexão ociosa por mais tempo que isso é testada antes de ser
  /// entregue a uma sessão.
  final Duration? idleTestThreshold;

  /// Espera máxima por uma conexão livre (null = sem limite).
  final Duration? acquireTimeout;

  const PoolLimits({
    required this.maxConnectionCount,
    this.maxConnectionAge,
    this.maxSessionUse,
    this.maxErrorCount,
    this.maxUseCount,
    this.idleTestThreshold,
    this.acquireTimeout,
  });
}

/// Estado de um pool num instante.
class PoolStatus {
  /// Conexões abertas (ou abrindo).
  final int connectionCount;

  /// Conexões ociosas, prontas para uso.
  final int idleCount;

  /// Conexões em uso por sessões.
  final int activeCount;

  /// Sessões esperando uma conexão.
  final int waitingCount;

  const PoolStatus({
    required this.connectionCount,
    required this.idleCount,
    required this.activeCount,
    required this.waitingCount,
  });

  @override
  String toString() => 'PoolStatus(connections: $connectionCount, '
      'idle: $idleCount, active: $activeCount, waiting: $waitingCount)';
}

class _Pooled<C> {
  _Pooled(this.connection);

  final C connection;
  final DateTime opened = DateTime.now();
  DateTime lastReturned = DateTime.now();
  Duration busy = Duration.zero;
  int uses = 0;
  int errors = 0;
}

/// Conexão emprestada pelo pool. Deve ser devolvida com [release] uma única
/// vez.
class PoolLease<C> {
  PoolLease._(this._pool, this._pooled) : _stopwatch = Stopwatch()..start();

  final PoolCore<C> _pool;
  final _Pooled<C> _pooled;
  final Stopwatch _stopwatch;
  bool _released = false;

  C get connection => _pooled.connection;

  /// Devolve a conexão. [error] é o erro da sessão, se ela falhou; com
  /// [discard] a conexão é fechada em vez de voltar ao pool.
  void release({Object? error, bool discard = false}) {
    if (_released) return;
    _released = true;
    _pooled.busy += _stopwatch.elapsed;
    _pooled.uses++;
    if (error != null) _pooled.errors++;
    _pool._release(this, error: error, discard: discard);
  }
}

/// Núcleo dos pools das APIs v2 e v3: controla as vagas, a fila de espera,
/// a reutilização e o descarte das conexões.
///
/// Regras:
/// - no máximo [PoolLimits.maxConnectionCount] conexões abertas (ou
///   abrindo);
/// - conexões ociosas são reutilizadas da mais recente para a mais antiga;
/// - quem espera é atendido em ordem de chegada; uma conexão devolvida vai
///   direto para o primeiro da fila;
/// - uma conexão é descartada (fechada) quando a sessão pede, quando ela
///   está fechada, quando [shouldDiscard] diz que está num estado inseguro,
///   quando a sessão falhou com [TimeoutException] (a consulta pode
///   continuar rodando) ou quando atinge um dos limites de idade e uso.
class PoolCore<C> {
  PoolCore({
    required this.limits,
    required Future<C> Function() open,
    required Future<void> Function(C connection) close,
    required bool Function(C connection) isClosed,
    Future<void> Function(C connection)? test,
    bool Function(C connection)? shouldDiscard,
  })  : _open = open,
        _close = close,
        _isClosed = isClosed,
        _test = test,
        _shouldDiscard = shouldDiscard {
    if (limits.maxConnectionCount < 1) {
      throw ArgumentError.value(limits.maxConnectionCount,
          'maxConnectionCount', 'Must be at least 1');
    }
  }

  final PoolLimits limits;
  final Future<C> Function() _open;
  final Future<void> Function(C) _close;
  final bool Function(C) _isClosed;
  final Future<void> Function(C)? _test;
  final bool Function(C)? _shouldDiscard;

  final _idle = <_Pooled<C>>[];
  final _active = <_Pooled<C>>{};
  final _waiters = Queue<Completer<_Pooled<C>?>>();
  final _closing = <Future<void>>{};

  /// Conexões abertas ou abrindo (ociosas, em uso, em teste ou abrindo).
  int _total = 0;
  bool _isClosedPool = false;
  Completer<void>? _drained;

  bool get isClosed => _isClosedPool;

  PoolStatus get status => PoolStatus(
        connectionCount: _total,
        idleCount: _idle.length,
        activeCount: _active.length,
        waitingCount: _waiters.length,
      );

  /// Executa [body] com uma conexão do pool e a devolve em seguida.
  Future<R> use<R>(Future<R> Function(C connection) body) async {
    final lease = await acquire();
    try {
      final result = await body(lease.connection);
      lease.release();
      return result;
    } catch (e) {
      lease.release(error: e);
      rethrow;
    }
  }

  /// Empresta uma conexão (abre uma nova se houver vaga, ou espera).
  Future<PoolLease<C>> acquire() async {
    var waitedBefore = false;
    while (true) {
      if (_isClosedPool) throw StateError('The pool is closed.');

      final idle = _takeIdle();
      if (idle != null) {
        if (await _isHealthy(idle)) return _lend(idle);
        _discard(idle);
        continue;
      }

      if (_total < limits.maxConnectionCount) {
        _total++;
        C connection;
        try {
          connection = await _open();
        } catch (_) {
          _total--;
          _checkDrained();
          _wakeOne();
          rethrow;
        }
        final pooled = _Pooled(connection);
        if (_isClosedPool) {
          _discard(pooled);
          throw StateError('The pool is closed.');
        }
        return _lend(pooled);
      }

      final handed = await _wait(first: waitedBefore);
      waitedBefore = true;
      if (handed != null) return _lend(handed);
      // null: uma vaga foi liberada; tenta de novo.
    }
  }

  PoolLease<C> _lend(_Pooled<C> pooled) {
    _active.add(pooled);
    return PoolLease._(this, pooled);
  }

  _Pooled<C>? _takeIdle() {
    while (_idle.isNotEmpty) {
      final pooled = _idle.removeLast();
      if (_isClosed(pooled.connection) || _isRetired(pooled)) {
        _discard(pooled);
        continue;
      }
      return pooled;
    }
    return null;
  }

  Future<bool> _isHealthy(_Pooled<C> pooled) async {
    final threshold = limits.idleTestThreshold;
    final test = _test;
    if (threshold == null || test == null) return true;
    if (DateTime.now().difference(pooled.lastReturned) < threshold) {
      return true;
    }
    try {
      await test(pooled.connection);
      return !_isClosed(pooled.connection);
    } catch (_) {
      return false;
    }
  }

  bool _isRetired(_Pooled<C> pooled) {
    final age = limits.maxConnectionAge;
    if (age != null && DateTime.now().difference(pooled.opened) >= age) {
      return true;
    }
    final sessionUse = limits.maxSessionUse;
    if (sessionUse != null && pooled.busy >= sessionUse) return true;
    final maxErrors = limits.maxErrorCount;
    if (maxErrors != null && pooled.errors >= maxErrors) return true;
    final maxUses = limits.maxUseCount;
    if (maxUses != null && pooled.uses >= maxUses) return true;
    return false;
  }

  Future<_Pooled<C>?> _wait({required bool first}) {
    final waiter = Completer<_Pooled<C>?>();
    // Quem já esperava e foi acordado volta para o início da fila.
    if (first) {
      _waiters.addFirst(waiter);
    } else {
      _waiters.addLast(waiter);
    }
    final timeout = limits.acquireTimeout;
    if (timeout == null) return waiter.future;
    final timer = Timer(timeout, () {
      // Só quem remove o waiter da fila pode completá-lo.
      if (_waiters.remove(waiter)) {
        waiter.completeError(TimeoutException(
            'No connection available in the pool after $timeout.', timeout));
      }
    });
    return waiter.future.whenComplete(timer.cancel);
  }

  void _wakeOne() {
    if (_waiters.isNotEmpty) _waiters.removeFirst().complete(null);
  }

  void _release(PoolLease<C> lease, {Object? error, required bool discard}) {
    final pooled = lease._pooled;
    _active.remove(pooled);
    final connection = pooled.connection;
    if (discard ||
        _isClosedPool ||
        error is TimeoutException ||
        _isClosed(connection) ||
        (_shouldDiscard?.call(connection) ?? false) ||
        _isRetired(pooled)) {
      _discard(pooled);
      return;
    }
    pooled.lastReturned = DateTime.now();
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(pooled);
      return;
    }
    _idle.add(pooled);
  }

  /// Fecha [pooled] e libera a vaga.
  void _discard(_Pooled<C> pooled) {
    _total--;
    late final Future<void> closing;
    closing = Future(() async {
      try {
        if (!_isClosed(pooled.connection)) await _close(pooled.connection);
      } catch (_) {
        // A conexão já estava quebrada.
      }
    }).whenComplete(() {
      _closing.remove(closing);
      _checkDrained();
    });
    _closing.add(closing);
    _wakeOne();
  }

  void _checkDrained() {
    final drained = _drained;
    if (drained != null &&
        !drained.isCompleted &&
        _total == 0 &&
        _closing.isEmpty) {
      drained.complete();
    }
  }

  /// Fecha o pool: novas sessões falham, quem espera recebe [StateError] e
  /// as conexões ociosas são fechadas. As sessões em andamento terminam
  /// normalmente (e suas conexões são fechadas ao serem devolvidas), a menos
  /// que [force] seja true: nesse caso as conexões em uso também são
  /// fechadas. Completa quando todas as conexões estiverem fechadas.
  Future<void> close({bool force = false}) async {
    if (!_isClosedPool) {
      _isClosedPool = true;
      _drained = Completer<void>();
      while (_waiters.isNotEmpty) {
        _waiters.removeFirst().completeError(StateError('The pool is closed.'));
      }
      for (final pooled in List.of(_idle)) {
        _discard(pooled);
      }
      _idle.clear();
    }
    if (force) {
      for (final pooled in List.of(_active)) {
        try {
          await _close(pooled.connection);
        } catch (_) {}
      }
    }
    _checkDrained();
    await _drained!.future;
  }
}
