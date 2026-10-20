part of postgres.connection;

typedef _TransactionQuerySignature = Future<dynamic> Function(
    PostgreSQLExecutionContext connection);

class _TransactionProxy extends Object
    with _PostgreSQLExecutionContextMixin
    implements PostgreSQLExecutionContext {
  _TransactionProxy(
      this._connection, this.executionBlock, this.commitTimeoutInSeconds) {
    _beginQuery = Query<int>(
        'BEGIN', <String, dynamic>{}, _connection, this, StackTrace.current,
        onlyReturnAffectedRowCount: true,
        useSendSimple: true,
        placeholderIdentifier: PlaceholderIdentifier.atSign);

    _beginQuery.future
        .then(startTransaction)
        .catchError((Object err, StackTrace st) {
      Future(() {
        _completer.completeError(err, st);
      });
    });
  }

  late Query<dynamic> _beginQuery;
  final _completer = Completer();

  Future get future => _completer.future;

  @override
  final PostgreSQLConnection _connection;

  @override
  PostgreSQLExecutionContext get _transaction => this;

  final _TransactionQuerySignature executionBlock;
  final int? commitTimeoutInSeconds;
  bool _hasFailed = false;
  bool _hasRolledBack = false;

  /// COMMIT ou ROLLBACK já foi executado (ou a transação falhou).
  bool get _isFinished => _completer.isCompleted || _hasRolledBack || _hasFailed;

  /// Streams de [PgQueryStreamExecutionContext.queryStream] ainda em
  /// andamento nesta transação.
  final _activeStreams = <_CursorStream>{};

  /// Interrompe os streams ainda ativos (com [error]) e espera os cursores
  /// serem fechados.
  Future<void> _abortStreams(Object error) async {
    if (_activeStreams.isEmpty) return;
    final streams = List.of(_activeStreams);
    for (final s in streams) {
      s._abort(error);
    }
    await Future.wait(streams.map((s) => s._finished.future));
  }

  @override
  void cancelTransaction({String? reason}) {
    throw _TransactionRollbackException(reason ?? 'Reason not given.');
  }

  Future startTransaction(dynamic _) async {
    dynamic result;
    try {
      result = await executionBlock(this);

      // Place another event in the queue so that any non-awaited futures
      // in the executionBlock are given a chance to run
      await Future(() => null);
    } on _TransactionRollbackException catch (rollback) {
      await _cancelAndRollback(rollback);

      return;
    } catch (e, st) {
      await _transactionFailed(e, st);

      return;
    }

    // Streams não consumidos até o fim do bloco são interrompidos (com
    // erro) e seus cursores fechados antes do COMMIT.
    await _abortStreams(StateError(
        'The transaction finished before the stream was fully consumed.'));

    // If we have queries pending, we need to wait for them to complete
    // before finishing !!!!
    if (_queue.isNotEmpty) {
      // ignore the error from this query if there is one, it'll pop up elsewhere
      await _queue.last.future.catchError((_) {return null;});
    }

    if (!_hasRolledBack && !_hasFailed) {
      await execute('COMMIT', timeoutInSeconds: commitTimeoutInSeconds);
      _completer.complete(result);
    }
  }

  Future _cancelAndRollback(dynamic object, [StackTrace? trace]) async {
    if (_hasRolledBack) {
      return;
    }

    _hasRolledBack = true;
    for (final s in List.of(_activeStreams)) {
      s._abort(PostgreSQLException(
          'The transaction was rolled back before the stream was fully consumed.'));
    }
    // We'll wrap each query in an error handler here to make sure the query cancellation error
    // is only emitted from the transaction itself.
    for (final q in _queue) {
      unawaited(q.future.catchError((_) {return null;}));
    }

    final err = PostgreSQLException('Query failed prior to execution. '
        "This query's transaction encountered an error earlier in the transaction "
        'that prevented this query from executing.');
    _queue.cancel(err);

    // Com a conexão fechada não há o que desfazer (e o ROLLBACK só
    // terminaria pelo timeout).
    if (!_connection.isClosed) {
      final rollback = Query<int>('ROLLBACK', <String, dynamic>{}, _connection,
          _transaction, StackTrace.current,
          onlyReturnAffectedRowCount: true,
          useSendSimple: true,
          placeholderIdentifier: PlaceholderIdentifier.atSign);
      _queue.addEvenIfCancelled(rollback);

      _connection._transitionToState(_connection._connectionState.awake());

      try {
        await rollback.future.timeout(Duration(seconds: 30));
      } finally {
        _queue.remove(rollback);
      }
    }

    if (object is _TransactionRollbackException) {
      _completer.complete(PostgreSQLRollback._(object.reason));
    } else {
      _completer.completeError(object as Object, trace);
    }
  }

  Future _transactionFailed(dynamic error, [StackTrace? trace]) async {
    if (_hasFailed) {
      return;
    }

    _hasFailed = true;

    await _cancelAndRollback(error, trace);
  }

  @override
  Future _onQueryError(Query query, dynamic error, [StackTrace? trace]) {
    // _onQueryError roda na zona de quem executou a consulta: um erro dentro
    // de um savepoint ativo desta transação é tratado pelo próprio savepoint.
    final scope = Zone.current[_savepointZoneKey];
    if (scope is _Savepoint && scope.active && identical(scope.owner, this)) {
      return Future.value();
    }
    return _transactionFailed(error, trace);
  }

  int _savepointCounter = 0;

  Future<T> savepoint<T>(
      Future<T> Function(PostgreSQLExecutionContext ctx) block) async {
    final sp = _Savepoint(this, 'pg_savepoint_${_savepointCounter++}');
    await execute('SAVEPOINT ${sp.name}');
    T result;
    try {
      result = await runZoned(() => block(this),
          zoneValues: {_savepointZoneKey: sp});
    } on _TransactionRollbackException {
      // cancelTransaction(): desfaz a transação inteira.
      sp.active = false;
      rethrow;
    } catch (_) {
      // A partir daqui, erros (inclusive do ROLLBACK TO) falham a transação.
      sp.active = false;
      if (!_hasFailed && !_hasRolledBack) {
        await execute('ROLLBACK TO SAVEPOINT ${sp.name}');
      }
      rethrow;
    }
    sp.active = false;
    await execute('RELEASE SAVEPOINT ${sp.name}');
    return result;
  }
}

const _savepointZoneKey = #postgres_fork.savepoint;

class _Savepoint {
  _Savepoint(this.owner, this.name);

  final _TransactionProxy owner;
  final String name;
  bool active = true;
}

/// Savepoints dentro de [PostgreSQLConnection.transaction].
extension PgSavepointExecutionContext on PostgreSQLExecutionContext {
  /// Executa [block] dentro de um `SAVEPOINT` da transação atual.
  ///
  /// Se [block] lançar uma exceção (por exemplo, uma consulta que falhou), as
  /// alterações feitas dentro dele são desfeitas com `ROLLBACK TO SAVEPOINT`
  /// e a exceção é relançada; a transação continua válida e pode seguir com
  /// outras consultas ou ser confirmada. Sem exceção, o savepoint é liberado
  /// (`RELEASE SAVEPOINT`) e o valor de [block] é devolvido.
  ///
  /// Consultas executadas dentro de [block] (no contexto recebido ou no da
  /// transação) que falharem não desfazem a transação inteira, desde que
  /// sejam aguardadas antes de [block] terminar. Savepoints podem ser
  /// aninhados. [PostgreSQLExecutionContext.cancelTransaction] dentro de
  /// [block] continua desfazendo a transação inteira.
  ///
  /// Só pode ser usado no contexto recebido por
  /// [PostgreSQLConnection.transaction]; em outro contexto lança
  /// [StateError].
  Future<T> savepoint<T>(
      Future<T> Function(PostgreSQLExecutionContext ctx) block) {
    final self = this;
    if (self is _TransactionProxy) return self.savepoint(block);
    throw StateError('savepoint() can only be used inside transaction().');
  }
}

/// Represents a rollback from a transaction.
///
/// If a transaction is cancelled using [PostgreSQLExecutionContext.cancelTransaction], the value of the [Future]
/// returned from [PostgreSQLConnection.transaction] will be an instance of this type. [reason] will be the [String]
/// value of the optional argument to [PostgreSQLExecutionContext.cancelTransaction].
///
/// [PostgreSQLPool.runTx] lança este objeto quando o tipo de retorno não o
/// aceita (por isso ele implementa [Exception]).
class PostgreSQLRollback implements Exception {
  PostgreSQLRollback._(this.reason);

  /// The reason the transaction was cancelled.
  final String reason;

  @override
  String toString() => 'PostgreSQLRollback: $reason';
}
