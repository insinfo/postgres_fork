import 'dart:async';

import '../../postgres_v3_experimental.dart';
import '../pool_core.dart';
import 'connection.dart';

/// Implementação de [PgPool] sobre [PoolCore].
class PgPoolImplementation implements PgPool {
  PgPoolImplementation._(
      this._endpoints, this._sessionSettings, PgPoolSettings settings) {
    _core = PoolCore<PgConnectionImplementation>(
      limits: PoolLimits(
        maxConnectionCount: settings.maxConnectionCount ?? 10,
        maxConnectionAge: settings.maxConnectionAge,
        maxSessionUse: settings.maxSessionUse,
        maxErrorCount: settings.maxErrorCount,
        maxUseCount: settings.maxQueryCount,
        idleTestThreshold: settings.idleTestThreshold,
      ),
      open: _openConnection,
      close: (c) => c.close(),
      isClosed: (c) => c.isClosed,
      test: (c) => c.execute('SELECT 1', timeout: const Duration(seconds: 5)),
    );
  }

  static Future<PgPool> open(
    List<PgEndpoint> endpoints, {
    PgSessionSettings? sessionSettings,
    PgPoolSettings? poolSettings,
  }) async {
    if (endpoints.isEmpty) {
      throw ArgumentError.value(endpoints, 'endpoints', 'Must not be empty');
    }
    return PgPoolImplementation._(List.of(endpoints), sessionSettings,
        poolSettings ?? PgPoolSettings());
  }

  final List<PgEndpoint> _endpoints;
  final PgSessionSettings? _sessionSettings;
  late final PoolCore<PgConnectionImplementation> _core;
  var _nextEndpoint = 0;

  /// Estado atual do pool.
  PoolStatus get status => _core.status;

  Future<PgConnectionImplementation> _openConnection() {
    // Novas conexões alternam entre os endpoints.
    final endpoint = _endpoints[_nextEndpoint++ % _endpoints.length];
    return PgConnectionImplementation.connect(endpoint,
        sessionSettings: _sessionSettings);
  }

  /// Executa [fn] com uma conexão exclusiva do pool. Com [sessionSettings],
  /// [fn] recebe uma conexão nova, aberta só para ela com essas
  /// configurações e fechada em seguida (fora do limite do pool).
  @override
  Future<R> withConnection<R>(
    Future<R> Function(PgConnection connection) fn, {
    PgSessionSettings? sessionSettings,
  }) async {
    if (sessionSettings == null) return _core.use(fn);
    if (_core.isClosed) throw StateError('The pool is closed.');
    final connection = await PgConnectionImplementation.connect(
        _endpoints[_nextEndpoint++ % _endpoints.length],
        sessionSettings: sessionSettings);
    try {
      return await fn(connection);
    } finally {
      await connection.close();
    }
  }

  @override
  Future<R> run<R>(Future<R> Function(PgSession session) fn,
      {PgRetryOptions? retryOptions}) {
    Future<R> once() => _core.use((c) => c.run(fn));
    return retryOptions == null ? once() : retryOptions.retry(once);
  }

  @override
  Future<R> runTx<R>(Future<R> Function(PgSession session) fn,
      {PgRetryOptions? retryOptions}) {
    Future<R> once() => _core.use((c) => c.runTx(fn));
    return retryOptions == null ? once() : retryOptions.retry(once);
  }

  @override
  Future<PgResult> execute(Object query,
          {Object? parameters, Duration? timeout}) =>
      _core.use(
          (c) => c.execute(query, parameters: parameters, timeout: timeout));

  /// Não suportado: um statement preparado pertence a uma conexão, que
  /// voltaria ao pool. Use [withConnection].
  @override
  Future<PgStatement> prepare(Object query, {Duration? timeout}) =>
      Future.error(UnsupportedError(
          'PgPool.prepare is not supported: a prepared statement belongs to '
          'a single connection. Use withConnection.'));

  /// Fecha o pool (ver [PoolCore.close]).
  @override
  Future<void> close({bool force = false}) => _core.close(force: force);
}
