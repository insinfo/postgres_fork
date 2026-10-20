part of postgres.connection;

/// Configuração de um [PostgreSQLPool].
class PostgreSQLPoolSettings {
  /// Número máximo de conexões abertas ao mesmo tempo.
  final int maxConnectionCount;

  /// Conexões abertas há mais tempo que isso são fechadas ao serem
  /// devolvidas (null = sem limite).
  final Duration? maxConnectionAge;

  /// Conexões usadas por mais tempo que isso (somando as sessões) são
  /// fechadas ao serem devolvidas (null = sem limite).
  final Duration? maxSessionUse;

  /// Conexões cujas sessões falharam esse número de vezes são fechadas ao
  /// serem devolvidas (null = sem limite).
  final int? maxErrorCount;

  /// Conexões usadas por esse número de sessões são fechadas ao serem
  /// devolvidas (null = sem limite).
  final int? maxUseCount;

  /// Uma conexão ociosa por mais tempo que isso é testada (`SELECT 1`) antes
  /// de ser entregue a uma sessão; se falhar, é fechada e outra é usada
  /// (null = nunca testa).
  final Duration? idleTestThreshold;

  /// Espera máxima por uma conexão livre; ao expirar, a sessão falha com
  /// [TimeoutException] (null = espera sem limite).
  final Duration? acquireTimeout;

  /// Chamado depois de abrir cada conexão (por exemplo, para executar `SET`).
  /// Se falhar, a conexão é fechada e a sessão falha com o erro.
  final Future<void> Function(PostgreSQLConnection connection)? onOpen;

  /// Novas tentativas padrão de [PostgreSQLPool.run], [PostgreSQLPool.runTx]
  /// e [PostgreSQLPool.withConnection] (null = sem novas tentativas).
  final PgRetryOptions? retryOptions;

  const PostgreSQLPoolSettings({
    this.maxConnectionCount = 10,
    this.maxConnectionAge = const Duration(hours: 12),
    this.maxSessionUse = const Duration(hours: 8),
    this.maxErrorCount = 128,
    this.maxUseCount,
    this.idleTestThreshold = const Duration(minutes: 1),
    this.acquireTimeout,
    this.onOpen,
    this.retryOptions,
  });
}

/// Pool de conexões [PostgreSQLConnection].
///
/// As conexões são criadas por `connectionFactory` (com todas as opções de
/// [PostgreSQLConnection]) e abertas sob demanda, até
/// [PostgreSQLPoolSettings.maxConnectionCount]. Cada sessão ([run], [runTx],
/// [withConnection] ou um dos métodos de [PostgreSQLExecutionContext]) usa
/// uma conexão com exclusividade e a devolve ao terminar; quem chega quando
/// todas estão em uso espera, em ordem de chegada.
///
/// Uma conexão é fechada em vez de voltar ao pool quando: foi fechada (por
/// exemplo, pelo servidor); a sessão falhou com [TimeoutException] (a
/// consulta pode continuar rodando no servidor); a sessão deixou uma
/// transação aberta (um `BEGIN` sem `COMMIT`/`ROLLBACK`); ou atingiu um dos
/// limites de [PostgreSQLPoolSettings]. Erros de SQL comuns (por exemplo,
/// violação de unicidade) não fecham a conexão.
///
/// Configurações de sessão alteradas com `SET` continuam valendo para as
/// próximas sessões da mesma conexão; prefira os parâmetros de startup da
/// conexão ou [PostgreSQLPoolSettings.onOpen].
class PostgreSQLPool implements PostgreSQLExecutionContext {
  PostgreSQLPool(PostgreSQLConnection Function() connectionFactory,
      {this.settings = const PostgreSQLPoolSettings()})
      : _connectionFactory = connectionFactory {
    _core = PoolCore<PostgreSQLConnection>(
      limits: PoolLimits(
        maxConnectionCount: settings.maxConnectionCount,
        maxConnectionAge: settings.maxConnectionAge,
        maxSessionUse: settings.maxSessionUse,
        maxErrorCount: settings.maxErrorCount,
        maxUseCount: settings.maxUseCount,
        idleTestThreshold: settings.idleTestThreshold,
        acquireTimeout: settings.acquireTimeout,
      ),
      open: _openConnection,
      close: (c) => c.close(),
      isClosed: (c) => c.isClosed,
      test: (c) => c.execute('SELECT 1', timeoutInSeconds: 5),
      shouldDiscard: _isInTransaction,
    );
  }

  final PostgreSQLConnection Function() _connectionFactory;
  final PostgreSQLPoolSettings settings;
  late final PoolCore<PostgreSQLConnection> _core;

  /// Estado atual do pool.
  PoolStatus get status => _core.status;

  /// Se [close] já foi chamado.
  bool get isClosed => _core.isClosed;

  Future<PostgreSQLConnection> _openConnection() async {
    final connection = _connectionFactory();
    await connection.open();
    final onOpen = settings.onOpen;
    if (onOpen != null) {
      try {
        await onOpen(connection);
      } catch (_) {
        await connection.close();
        rethrow;
      }
    }
    return connection;
  }

  /// A conexão ficou ociosa dentro de uma transação (um `BEGIN` sem
  /// `COMMIT`/`ROLLBACK`): não pode ser entregue a outra sessão.
  static bool _isInTransaction(PostgreSQLConnection connection) =>
      connection._connectionState
          is _PostgreSQLConnectionStateReadyInTransaction;

  /// Executa [fn] com uma conexão exclusiva do pool.
  ///
  /// Com [retryOptions] (ou [PostgreSQLPoolSettings.retryOptions]), [fn] é
  /// executada de novo, com outra conexão, quando falha com um erro aceito
  /// por [PgRetryOptions.retryIf].
  Future<R> withConnection<R>(
      Future<R> Function(PostgreSQLConnection connection) fn,
      {PgRetryOptions? retryOptions}) {
    final options = retryOptions ?? settings.retryOptions;
    Future<R> once() => _core.use(fn);
    return options == null ? once() : options.retry(once);
  }

  /// Executa [fn] fora de transação, com uma conexão exclusiva (ver
  /// [withConnection]).
  Future<R> run<R>(Future<R> Function(PostgreSQLExecutionContext ctx) fn,
          {PgRetryOptions? retryOptions}) =>
      withConnection(fn, retryOptions: retryOptions);

  /// Executa [fn] numa transação ([PostgreSQLConnection.transaction]). Com
  /// [retryOptions], a transação inteira é repetida (com outra conexão)
  /// quando falha com um erro aceito por [PgRetryOptions.retryIf] (por
  /// padrão, falha de serialização e deadlock).
  ///
  /// Se a transação for cancelada com
  /// [PostgreSQLExecutionContext.cancelTransaction], o [PostgreSQLRollback]
  /// é lançado (ou devolvido, se for compatível com [R]).
  Future<R> runTx<R>(Future<R> Function(PostgreSQLExecutionContext ctx) fn,
      {PgRetryOptions? retryOptions, int? commitTimeoutInSeconds}) {
    return withConnection((connection) async {
      final result = await connection.transaction(fn,
          commitTimeoutInSeconds: commitTimeoutInSeconds);
      if (result is R) return result;
      if (result is PostgreSQLRollback) throw result;
      return result as R;
    }, retryOptions: retryOptions);
  }

  /// Fecha o pool. Ver [PoolCore.close].
  Future<void> close({bool force = false}) => _core.close(force: force);

  /// Sessões esperando uma conexão.
  @override
  int get queueSize => _core.status.waitingCount;

  /// Não faz nada: o pool não é uma transação. Use [runTx].
  @override
  void cancelTransaction({String? reason}) {}

  @override
  Future<PostgreSQLResult> query(
    String fmtString, {
    dynamic substitutionValues,
    bool? allowReuse,
    int? timeoutInSeconds,
    bool? useSimpleQueryProtocol,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
  }) =>
      withConnection((c) => c.query(fmtString,
          substitutionValues: substitutionValues,
          allowReuse: allowReuse,
          timeoutInSeconds: timeoutInSeconds,
          useSimpleQueryProtocol: useSimpleQueryProtocol,
          placeholderIdentifier: placeholderIdentifier));

  @override
  Future<int> execute(
    String fmtString, {
    dynamic substitutionValues = const <String, dynamic>{},
    int? timeoutInSeconds,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
  }) =>
      withConnection((c) => c.execute(fmtString,
          substitutionValues: substitutionValues,
          timeoutInSeconds: timeoutInSeconds,
          placeholderIdentifier: placeholderIdentifier));

  @override
  Future<List<Map<String, Map<String, dynamic>>>> mappedResultsQuery(
    String fmtString, {
    dynamic substitutionValues = const <String, dynamic>{},
    bool? allowReuse,
    int? timeoutInSeconds,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
  }) =>
      withConnection((c) => c.mappedResultsQuery(fmtString,
          substitutionValues: substitutionValues,
          allowReuse: allowReuse,
          timeoutInSeconds: timeoutInSeconds,
          placeholderIdentifier: placeholderIdentifier));

  @override
  Future<List<Map<String, dynamic>>> queryAsMap(
    String fmtString, {
    dynamic substitutionValues = const <String, dynamic>{},
    bool? allowReuse,
    int? timeoutInSeconds,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
  }) =>
      withConnection((c) => c.queryAsMap(fmtString,
          substitutionValues: substitutionValues,
          allowReuse: allowReuse,
          timeoutInSeconds: timeoutInSeconds,
          placeholderIdentifier: placeholderIdentifier));

  /// [PostgreSQLConnection.queryStream] com uma conexão do pool, que fica
  /// ocupada até o stream terminar ou ser cancelado.
  Stream<PostgreSQLResultRow> queryStream(
    String fmtString, {
    dynamic substitutionValues,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
    int fetchSize = 1000,
    int? timeoutInSeconds,
  }) async* {
    if (fetchSize < 1) {
      throw ArgumentError.value(fetchSize, 'fetchSize', 'Must be positive');
    }
    final lease = await _core.acquire();
    Object? error;
    try {
      yield* lease.connection.queryStream(fmtString,
          substitutionValues: substitutionValues,
          placeholderIdentifier: placeholderIdentifier,
          fetchSize: fetchSize,
          timeoutInSeconds: timeoutInSeconds);
    } catch (e) {
      error = e;
      rethrow;
    } finally {
      lease.release(error: error);
    }
  }

  /// [PostgreSQLConnection.copyFrom] com uma conexão do pool.
  Future<int> copyFrom(String sql, Stream<List<int>> data,
          {dynamic substitutionValues,
          PlaceholderIdentifier placeholderIdentifier =
              PlaceholderIdentifier.atSign,
          int? timeoutInSeconds}) =>
      _core.use((c) => c.copyFrom(sql, data,
          substitutionValues: substitutionValues,
          placeholderIdentifier: placeholderIdentifier,
          timeoutInSeconds: timeoutInSeconds));

  /// [PostgreSQLConnection.copyTo] com uma conexão do pool.
  Future<int> copyTo(String sql, void Function(Uint8List data) onData,
          {dynamic substitutionValues,
          PlaceholderIdentifier placeholderIdentifier =
              PlaceholderIdentifier.atSign,
          int? timeoutInSeconds}) =>
      _core.use((c) => c.copyTo(sql, onData,
          substitutionValues: substitutionValues,
          placeholderIdentifier: placeholderIdentifier,
          timeoutInSeconds: timeoutInSeconds));

  /// [PostgreSQLConnection.copyRows] com uma conexão do pool.
  Future<int> copyRows(
          String table, List<String> columns, Iterable<List<Object?>> rows,
          {String? schema, int? timeoutInSeconds}) =>
      _core.use((c) => c.copyRows(table, columns, rows,
          schema: schema, timeoutInSeconds: timeoutInSeconds));
}
