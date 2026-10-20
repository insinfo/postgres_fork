part of postgres.connection;

abstract class _PostgreSQLConnectionState {
  PostgreSQLConnection? connection;

  _PostgreSQLConnectionState onEnter() {
    return this;
  }

  _PostgreSQLConnectionState awake() {
    return this;
  }

  _PostgreSQLConnectionState onMessage(ServerMessage message) {
    return this;
  }

  _PostgreSQLConnectionState onErrorResponse(ErrorResponseMessage message) {
    final exception = PostgreSQLException._(message.fields);

    if (exception.severity == PostgreSQLSeverity.fatal ||
        exception.severity == PostgreSQLSeverity.panic) {
      return _PostgreSQLConnectionStateClosed();
    }

    return this;
  }

  void onExit() {}
}

/*
  Closed State; starts here and ends here.
 */

class _PostgreSQLConnectionStateClosed extends _PostgreSQLConnectionState {}

/*
  Socket connected, prior to any PostgreSQL handshaking - initiates that handshaking
 */

class _PostgreSQLConnectionStateSocketConnected
    extends _PostgreSQLConnectionState {
  _PostgreSQLConnectionStateSocketConnected(this.completer);

  Completer completer;

  @override
  _PostgreSQLConnectionState onEnter() {
    final startupMessage = StartupMessage(
        connection!.databaseName, connection!.timeZone,
        username: connection!.username,
        replication: connection!.replicationMode,
        encoding: connection!.encoding,
        parameters: connection!._extraStartupParameters);

    connection!._socket!.add(startupMessage.asBytes());

    return _PostgreSQLConnectionStateAuthenticating(completer);
  }

  @override
  _PostgreSQLConnectionState onErrorResponse(ErrorResponseMessage message) {
    final exception = PostgreSQLException._(message.fields);

    completer.completeError(exception);

    return _PostgreSQLConnectionStateClosed();
  }

  @override
  _PostgreSQLConnectionState onMessage(ServerMessage message) {
    completer.completeError(PostgreSQLException(
        'Unsupported message "$message", closing connection.'));

    return _PostgreSQLConnectionStateClosed();
  }
}

/*
  Authenticating state
 */

class _PostgreSQLConnectionStateAuthenticating
    extends _PostgreSQLConnectionState {
  _PostgreSQLConnectionStateAuthenticating(this.completer);

  Completer completer;
  late PostgresAuthenticator _authenticator;

  @override
  _PostgreSQLConnectionState onEnter() {
    return this;
  }

  @override
  _PostgreSQLConnectionState onErrorResponse(ErrorResponseMessage message) {
    final exception = PostgreSQLException._(message.fields);

    completer.completeError(exception);

    return _PostgreSQLConnectionStateClosed();
  }

  PostgresAuthConnection _authConnection() {
    final connection = this.connection!;
    return PostgresAuthConnection(
      connection.username,
      connection.password,
      (msg) => connection.socket!.add(msg.asBytes()),
    );
  }

  @override
  _PostgreSQLConnectionState onMessage(ServerMessage message) {
    if (message is AuthenticationMessage) {
      // Pass on the pending op to subsequent stages
      switch (message.type) {
        case AuthenticationMessage.KindOK:
          return _PostgreSQLConnectionStateAuthenticated(completer);
        case AuthenticationMessage.KindMD5Password:
          // this means the server is requesting an md5 challenge
          // so the password must not be null
          if (connection!.password == null) {
            completer.completeError(PostgreSQLException(
              'Password is required for "${connection!.username}" user to establish a connection',
            ));
            break;
          }
          _authenticator = createAuthenticator(_authConnection(),
              AuthenticationScheme.md5, connection!.encoding);
          continue authMsg;
        case AuthenticationMessage.KindClearTextPassword:
          if (connection!.allowClearTextPassword) {
            _authenticator = createAuthenticator(_authConnection(),
                AuthenticationScheme.clear, connection!.encoding);
            continue authMsg;
          } else {
            completer.completeError(PostgreSQLException(
                'type ${message.type} connections disabled. Set AllowClearTextPassword flag on PostgreSQLConnection to enable this feature.'));
            break;
          }
        case AuthenticationMessage.KindSASL:
          // this means the server is requesting a scram-sha-256 challenge
          // so the password must not be null
          if (connection!.password == null) {
            completer.completeError(PostgreSQLException(
              'Password is required for "${connection!.username}" user to establish a connection',
            ));
            break;
          }
          _authenticator = createAuthenticator(
              _authConnection(), AuthenticationScheme.scramSha256, connection!.encoding);
          continue authMsg;
        authMsg:
        case AuthenticationMessage.KindSASLContinue:
        case AuthenticationMessage.KindSASLFinal:
          try {
            _authenticator.onMessage(message);
            return this;
          } catch (e, st) {
            // an exception occurred in the authenticator that isn't a PostgreSQL
            // Exception (e.g. `Null check operator used on a null value`)
            completer.completeError(e, st);
            break;
          }
      }

      completer.completeError(PostgreSQLException(
          'Unsupported authentication type ${message.type}, closing connection.'));
    } else if (message is ParameterStatusMessage) {
      connection!.settings[message.name] = message.value;
    } else if (message is BackendKeyMessage) {
      connection!._processID = message.processID;
      connection!._secretKey = message.secretKey;
      connection!._hasBackendKey = true;
    } else if (message is ReadyForQueryMessage) {
      if (message.state == ReadyForQueryMessage.StateIdle) {
        return _PostgreSQLConnectionStateIdle(openCompleter: completer);
      }
    }

    return this;
  }
}

/*
  Authenticated state
 */

class _PostgreSQLConnectionStateAuthenticated
    extends _PostgreSQLConnectionState {
  _PostgreSQLConnectionStateAuthenticated(this.completer);

  Completer completer;

  @override
  _PostgreSQLConnectionState onErrorResponse(ErrorResponseMessage message) {
    final exception = PostgreSQLException._(message.fields);

    completer.completeError(exception);

    return _PostgreSQLConnectionStateClosed();
  }

  @override
  _PostgreSQLConnectionState onMessage(ServerMessage message) {
    if (message is ParameterStatusMessage) {
      connection!.settings[message.name] = message.value;
    } else if (message is BackendKeyMessage) {
      connection!._processID = message.processID;
      connection!._secretKey = message.secretKey;
      connection!._hasBackendKey = true;
    } else if (message is ReadyForQueryMessage) {
      if (message.state == ReadyForQueryMessage.StateIdle) {
        return _PostgreSQLConnectionStateIdle(openCompleter: completer);
      }
    }

    return this;
  }
}

/*
  Ready/idle state
 */

class _PostgreSQLConnectionStateIdle extends _PostgreSQLConnectionState {
  _PostgreSQLConnectionStateIdle({this.openCompleter});

  Completer? openCompleter;

  @override
  _PostgreSQLConnectionState awake() {
    final pendingQuery = connection!._queue.pending;
    if (pendingQuery != null) {
      return processQuery(pendingQuery);
    }

    return this;
  }

  _PostgreSQLConnectionState processQuery(Query<dynamic> q) {
    try {
      if (q.useSendSimple) {
        q.sendSimple(connection!._socket!);
        return _PostgreSQLConnectionStateBusy(q);
      }

      final cached = connection!._cache[q.statement];
      q.sendExtended(connection!._socket!,
          cacheQuery: cached,
          closeStatements: connection!._cache.takePendingCloses());

      return _PostgreSQLConnectionStateBusy(q);
    } catch (e, st) {
      scheduleMicrotask(() {
        q.completeError(e, st);
        connection!._transitionToState(_PostgreSQLConnectionStateIdle());
      });

      return _PostgreSQLConnectionStateDeferredFailure();
    }
  }

  @override
  _PostgreSQLConnectionState onEnter() {
    openCompleter?.complete();

    return awake();
  }

  @override
  _PostgreSQLConnectionState onMessage(ServerMessage message) {
    return this;
  }
}

/*
  Busy state, query in progress
 */

class _PostgreSQLConnectionStateBusy extends _PostgreSQLConnectionState {
  _PostgreSQLConnectionStateBusy(this.query);

  Query<dynamic> query;
  PostgreSQLException? returningException;
  int rowsAffected = 0;

  /// Erro ao decodificar uma linha (por exemplo, um tipo não suportado).
  /// A consulta falha com ele, mas a conexão continua utilizável.
  Object? decodeError;
  StackTrace? decodeStackTrace;

  @override
  _PostgreSQLConnectionState onErrorResponse(ErrorResponseMessage message) {
    // If we get an error here, then we should eat the rest of the messages
    // and we are always confirmed to get a _ReadyForQueryMessage to finish up.
    // We should only report the error once that is done.
    final exception = PostgreSQLException._(message.fields);
    returningException ??= exception;
    // O servidor encerrou um COPY FROM STDIN em andamento.
    if (_pumping) _stopPumping();

    if (exception.severity == PostgreSQLSeverity.fatal ||
        exception.severity == PostgreSQLSeverity.panic) {
      return _PostgreSQLConnectionStateClosed();
    }

    return this;
  }

  @override
  _PostgreSQLConnectionState onMessage(ServerMessage message) {
    // We ignore NoData, as it doesn't tell us anything we don't already know
    // or care about.

    if (message is ReadyForQueryMessage) {
      if (_pumping) {
        // Um envio de dados de COPY ainda está em andamento (por exemplo,
        // esperando um flush): o socket só é liberado para a próxima
        // consulta quando ele terminar (ver _pumpCopyIn).
        _deferredReady = message;
        _stopPumping();
        return this;
      }
      if (message.state == ReadyForQueryMessage.StateTransactionError) {
        if (copyError != null) {
          query.completeError(copyError!, copyStackTrace);
        } else {
          query.completeError(returningException!);
        }
        return _PostgreSQLConnectionStateReadyInTransaction(
            query.transaction as _PostgreSQLExecutionContextMixin);
      }
      if (copyError != null) {
        query.completeError(copyError!, copyStackTrace);
      } else if (returningException != null) {
        query.completeError(returningException!);
      } else if (decodeError != null) {
        query.completeError(decodeError!, decodeStackTrace);
      } else {
        query.complete(rowsAffected);
      }

      if (message.state == ReadyForQueryMessage.StateTransaction) {
        return _PostgreSQLConnectionStateReadyInTransaction(
            query.transaction as _PostgreSQLExecutionContextMixin);
      }

      return _PostgreSQLConnectionStateIdle();
    } else if (message is CommandCompleteMessage) {
      rowsAffected = message.rowsAffected;
      final tag = message.commandTag;
      if (tag == 'DISCARD ALL' || tag == 'DEALLOCATE ALL') {
        // O servidor removeu todos os prepared statements (inclusive o
        // desta consulta, se for um): o cache não vale mais.
        connection!._cache.clear();
        query.cache = null;
      }
    } else if (message is RowDescriptionMessage) {
      if (query.useSendSimple) {
        // Protocolo simples com vários comandos: o resultado é o do último
        // que devolve linhas (como no libpq). Antes as linhas de todos
        // ficavam juntas com a descrição de colunas do último.
        query.rows.clear();
      }
      query.fieldDescriptions = message.fieldDescriptions;
    } else if (message is NoDataMessage) {
      // Comando sem linhas (DDL, SET, INSERT sem RETURNING...): sem isto o
      // statement nunca era considerado válido pelo cache e cada execução
      // com allowReuse preparava um novo statement nomeado no servidor.
      query.fieldDescriptions ??= const [];
    } else if (message is DataRowMessage) {
      if (decodeError == null) {
        try {
          query.addRow(message.values);
        } catch (e, st) {
          // Continua consumindo as mensagens até o ReadyForQuery para manter
          // a conexão sincronizada; o erro é entregue à consulta no fim.
          decodeError = e;
          decodeStackTrace = st;
        }
      }
    } else if (message is ParameterDescriptionMessage) {
      final validationException =
          query.validateParameters(message.parameterTypeIDs);
      if (validationException != null) {
        query.cache = null;
      }
      returningException ??= validationException;
    } else if (message is CopyInResponseMessage) {
      _startCopyIn();
    } else if (message is CopyDataMessage) {
      _copyOut(message.bytes);
    }

    return this;
  }

  /*
    COPY
   */

  /// Faz flush no socket depois de cada bloco deste tamanho, para que um
  /// COPY grande não acumule todos os dados na memória.
  static const _copyFlushThreshold = 1 << 20;

  /// Erro do lado do cliente durante um COPY (falha no stream de dados,
  /// exceção no handler do COPY TO, COPY FROM STDIN sem dados). Tem
  /// prioridade sobre o erro que o servidor devolve em resposta ao CopyFail.
  Object? copyError;
  StackTrace? copyStackTrace;

  bool _pumping = false;
  bool _stopCopy = false;
  StreamIterator<List<int>>? _copyIterator;
  ReadyForQueryMessage? _deferredReady;

  void _startCopyIn() {
    final data = query.copyInData;
    if (data == null) {
      copyError ??= PostgreSQLException(
          'COPY ... FROM STDIN can only be executed with copyFrom().');
      _sendCopyEnd(CopyFailMessage(
          'COPY FROM STDIN without data', connection!.encoding));
      return;
    }
    if (query.isAbandoned) {
      _sendCopyEnd(
          CopyFailMessage('COPY canceled by the client', connection!.encoding));
      return;
    }
    _pumping = true;
    query.onAbandon = _stopPumping;
    unawaited(_pumpCopyIn(data));
  }

  void _stopPumping() {
    _stopCopy = true;
    // Completa com false um moveNext pendente.
    _copyIterator?.cancel().catchError((_) {});
  }

  /// Envia CopyDone ou CopyFail. No protocolo estendido o servidor ignora o
  /// Sync recebido durante o COPY, então outro Sync é necessário.
  void _sendCopyEnd(ClientMessage end) {
    connection!._socket!.add(ClientMessage.aggregateBytes(
        [end, if (!query.useSendSimple) const SyncMessage()]));
  }

  Future<void> _pumpCopyIn(Stream<List<int>> data) async {
    final conn = connection!;
    final socket = conn._socket!;
    final iterator = _copyIterator = StreamIterator(data);
    Object? streamError;
    StackTrace? streamStackTrace;
    var socketFailed = false;
    var pending = 0;
    try {
      while (!_stopCopy) {
        bool hasNext;
        try {
          hasNext = await iterator.moveNext();
        } catch (e, st) {
          streamError = e;
          streamStackTrace = st;
          break;
        }
        if (!hasNext || _stopCopy) break;
        if (!identical(conn._connectionState, this)) {
          socketFailed = true;
          break;
        }
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        try {
          final header = ByteData(5)
            ..setUint8(0, SharedMessages.copyDataIdentifier)
            ..setInt32(1, chunk.length + 4);
          socket.add(header.buffer.asUint8List());
          socket.add(chunk);
          pending += chunk.length;
          if (pending >= _copyFlushThreshold) {
            pending = 0;
            conn._copyFlushing = true;
            try {
              await socket.flush();
            } finally {
              conn._copyFlushing = false;
            }
          }
        } catch (_) {
          socketFailed = true;
          break;
        }
      }
    } finally {
      _pumping = false;
      _copyIterator = null;
      query.onAbandon = null;
      unawaited(iterator.cancel().catchError((_) {}));
    }

    if (!socketFailed && identical(conn._connectionState, this)) {
      // Depois de um erro do servidor o COPY já terminou e o que fosse
      // enviado seria descartado.
      final serverEnded = returningException != null || _deferredReady != null;
      try {
        if (streamError != null) {
          copyError ??= streamError;
          copyStackTrace ??= streamStackTrace;
          if (!serverEnded) {
            _sendCopyEnd(
                CopyFailMessage('COPY data stream failed', conn.encoding));
          }
        } else if (_stopCopy) {
          if (!serverEnded) {
            _sendCopyEnd(
                CopyFailMessage('COPY canceled by the client', conn.encoding));
          }
        } else {
          _sendCopyEnd(CopyDoneMessage(4));
        }
      } catch (_) {
        // Socket fechado: a conexão é encerrada pelo onError/onDone.
      }
    }

    final ready = _deferredReady;
    if (ready != null && identical(conn._connectionState, this)) {
      _deferredReady = null;
      try {
        conn._transitionToState(onMessage(ready));
      } catch (e, st) {
        unawaited(conn._close(e, st));
      }
    }
  }

  void _copyOut(Uint8List bytes) {
    final handler = query.copyOutHandler;
    if (handler == null || copyError != null || query.isAbandoned) return;
    try {
      handler(bytes);
    } catch (e, st) {
      // Continua consumindo os dados até o fim do COPY; o erro é entregue à
      // consulta no ReadyForQuery.
      copyError = e;
      copyStackTrace = st;
    }
  }
}

/* Idle Transaction State */

class _PostgreSQLConnectionStateReadyInTransaction
    extends _PostgreSQLConnectionState {
  _PostgreSQLConnectionStateReadyInTransaction(this.transaction);

  _PostgreSQLExecutionContextMixin transaction;

  @override
  _PostgreSQLConnectionState onEnter() {
    return awake();
  }

  @override
  _PostgreSQLConnectionState awake() {
    final pendingQuery = transaction._queue.pending;
    if (pendingQuery != null) {
      return processQuery(pendingQuery);
    }

    return this;
  }

  _PostgreSQLConnectionState processQuery(Query<dynamic> q) {
    try {
      if (q.useSendSimple) {
        q.sendSimple(connection!._socket!);
        return _PostgreSQLConnectionStateBusy(q);
      }

      final cached = connection!._cache[q.statement];
      q.sendExtended(connection!._socket!,
          cacheQuery: cached,
          closeStatements: connection!._cache.takePendingCloses());

      return _PostgreSQLConnectionStateBusy(q);
    } catch (e, st) {
      scheduleMicrotask(() {
        q.completeError(e, st);
      });

      return this;
    }
  }
}

/*
  Hack for deferred error
 */

class _PostgreSQLConnectionStateDeferredFailure
    extends _PostgreSQLConnectionState {}
