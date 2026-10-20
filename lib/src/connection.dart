library postgres.connection;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres_fork/postgres.dart';

import 'auth/auth.dart';
import 'client_messages.dart';
import 'message_window.dart';
import 'pool_core.dart';
import 'query.dart';
import 'query_cache.dart';
import 'query_queue.dart';
import 'server_messages.dart';
import 'shared_messages.dart';
import 'utils/buffer.dart';

part 'connection_fsm.dart';
part 'exceptions.dart';
part 'pool.dart';
part 'transaction_proxy.dart';

/// Instances of this class connect to and communicate with a PostgreSQL database.
///
/// The primary type of this library, a connection is responsible for connecting to databases and executing queries.
/// A connection may be opened with [open] after it is created.
class PostgreSQLConnection extends Object
    with _PostgreSQLExecutionContextMixin
    implements PostgreSQLExecutionContext {
  /// Creates an instance of [PostgreSQLConnection].
  ///
  /// [host] must be a hostname, e.g. "foobar.com" or IP address. Do not include scheme or port.
  /// [port] is the port to connect to the database on. It is typically 5432 for default PostgreSQL settings.
  /// [databaseName] is the name of the database to connect to.
  /// [username] and [password] are optional if the database requires user authentication.
  /// [timeoutInSeconds] refers to the amount of time [PostgreSQLConnection] will wait while establishing a connection before it gives up.
  /// [queryTimeoutInSeconds] refers to the default timeout for [PostgreSQLExecutionContext]'s execute and query methods.
  /// [timeZone] is the timeZone the connection is in. Defaults to 'UTC'.
  /// [useSSL] when true, uses a secure socket when connecting to a PostgreSQL database.
  /// [allowClearTextPassword] when true, allows sending the password during authentication in clear text. Use only when required by the database server and under encrypted connections, this feature may lead to security issues.
  /// [timeZone] = default = TimeZoneSettings('UTC') | String 'UTC'
  /// [decodingSettings] controls how some types (interval, time, timetz,
  /// inet and cidr) are decoded; see [DecodingSettings].
  /// [applicationName] and [startupParameters] are session parameters sent in
  /// the startup message (for example `search_path` or `statement_timeout`),
  /// avoiding `SET` commands after connecting.
  /// [sslMode] chooses how SSL is used (see [PgSslMode]); when null, [useSSL]
  /// decides as before.
  /// [cancelQueryOnTimeout] also cancels the query on the server when it
  /// exceeds its timeout (see [cancelQuery]).
  /// [maxPreparedStatements] limits the prepared statements kept by this
  /// connection (least recently used are closed); the server may keep one
  /// extra statement until the next extended-protocol query. Default: no
  /// limit.
  PostgreSQLConnection(
    this.host,
    this.port,
    this.databaseName, {
    this.encoding = utf8,
    this.username,
    this.password,
    this.timeoutInSeconds = 30,
    this.queryTimeoutInSeconds = 30,
    Object timeZone = 'UTC',
    this.useSSL = false,
    this.isUnixSocket = false,
    this.allowClearTextPassword = false,
    this.replicationMode = ReplicationMode.none,
    this.decodingSettings = const DecodingSettings(),
    this.applicationName,
    Map<String, String> startupParameters = const {},
    this.sslMode,
    this.cancelQueryOnTimeout = false,
    int? maxPreparedStatements,
  })  : startupParameters = Map.unmodifiable(startupParameters),
        _cache = QueryCache(maxSize: maxPreparedStatements) {
    if (maxPreparedStatements != null && maxPreparedStatements < 1) {
      throw ArgumentError.value(maxPreparedStatements, 'maxPreparedStatements',
          'Must be at least 1');
    }
    _checkStartupParameters(this.startupParameters);
    if (timeZone is String) {
      this.timeZone = TimeZoneSettings(timeZone);
    } else if (timeZone is TimeZoneSettings) {
      this.timeZone = timeZone;
    }

    _connectionState = _PostgreSQLConnectionStateClosed();
    _connectionState.connection = this;
  }

  final StreamController<Notification> _notifications =
      StreamController<Notification>.broadcast();

  final StreamController<ServerMessage> _messages =
      StreamController<ServerMessage>.broadcast();

  /// Hostname of database this connection refers to.
  final String host;

  /// Port of database this connection refers to.
  final int port;

  /// Name of database this connection refers to.
  final String databaseName;

  /// Username for authenticating this connection.
  final String? username;

  /// Password for authenticating this connection.
  final String? password;

  /// Whether or not this connection should connect securely.
  final bool useSSL;

  /// The amount of time this connection will wait during connecting before giving up.
  final int timeoutInSeconds;

  /// The default timeout for [PostgreSQLExecutionContext]'s execute and query methods.
  final int queryTimeoutInSeconds;

  /// The timeZone of this connection for date operations that don't specify a timeZone.
  TimeZoneSettings timeZone = TimeZoneSettings('UTC');

  /// How some types (interval, time, timetz, inet and cidr) are decoded.
  final DecodingSettings decodingSettings;

  /// The `application_name` sent in the startup message, if any.
  final String? applicationName;

  /// Additional session parameters sent in the startup message.
  final Map<String, String> startupParameters;

  /// SSL mode. When null, [useSSL] decides: [PgSslMode.require] when true,
  /// [PgSslMode.disable] when false.
  final PgSslMode? sslMode;

  /// When true, a query that exceeds its timeout is also cancelled on the
  /// server with a CancelRequest (see [cancelQuery]). Otherwise (default)
  /// only the client stops waiting and the server keeps running the query.
  final bool cancelQueryOnTimeout;

  /// The SSL mode actually used by this connection.
  PgSslMode get effectiveSslMode =>
      sslMode ?? (useSSL ? PgSslMode.require : PgSslMode.disable);

  bool _usingSsl = false;
  bool _hasBackendKey = false;

  /// Um COPY FROM STDIN está esperando um flush do socket (durante o flush
  /// o socket não aceita close()).
  bool _copyFlushing = false;

  /// Numeração dos cursores de [queryStream].
  int _cursorCounter = 0;

  /// All parameters sent in the startup message besides user, database,
  /// replication, client_encoding and TimeZone.
  Map<String, String> get _extraStartupParameters => {
        if (applicationName != null) 'application_name': applicationName!,
        ...startupParameters,
      };

  /// The processID of this backend.
  int get processID => _processID;

  /// If true, connection is made via unix socket.
  final bool isUnixSocket;

  /// If true, allows password in clear text for authentication.
  final bool allowClearTextPassword;

  /// The replication mode for connecting in streaming replication mode.
  ///
  /// When the value is set to either [ReplicationMode.physical] or [ReplicationMode.logical],
  /// the query protocol will no longer work as the connection will be switched to a replication
  /// connection. In other words, using the default [query] or [mappedResultsQuery] will cause
  /// the database to throw an error and drop the connection.
  ///
  /// Use [query] `useSimpleQueryProtocol` set to `true` or [execute] for executing statements
  /// while in replication mode.
  ///
  /// For more info, see [Streaming Replication Protocol]
  ///
  /// [Streaming Replication Protocol]: https://www.postgresql.org/docs/current/protocol-replication.html
  final ReplicationMode replicationMode;

  /// Stream of notification from the database.
  ///
  /// Listen to this [Stream] to receive events from PostgreSQL NOTIFY commands.
  ///
  /// To determine whether or not the NOTIFY came from this instance, compare [processID]
  /// to [Notification.processID].
  Stream<Notification> get notifications => _notifications.stream;

  /// Stream of server messages
  ///
  /// Listen to this [Stream] to receive events for all PostgreSQL server messages
  ///
  /// This includes all messages whether from Extended Query Protocol, Simple Query Protocol
  /// or Streaming Replication Protocol.
  Stream<ServerMessage> get messages => _messages.stream;

  /// Reports on the latest known status of the connection: whether it was open or failed for some reason.
  ///
  /// This is `true` when this instance is first created and after it has been closed or encountered an unrecoverable error.
  /// If a connection has already been opened and this value is now true, the connection cannot be reopened and a instance
  /// must be created.
  bool get isClosed => _connectionState is _PostgreSQLConnectionStateClosed;

  /// Settings values from the connected database.
  ///
  /// After connecting to a database, this map will contain the settings values that the database returns.
  /// Prior to connection, it is the empty map.
  final Map<String, String> settings = {};

  final QueryCache _cache;
  final _oidCache = _OidCache();
  Socket? _socket;
  late MessageFramer _framer;
  late int _processID;
  // ignore: unused_field
  late int _secretKey;

  bool _hasConnectedPreviously = false;
  late _PostgreSQLConnectionState _connectionState;

  @override
  PostgreSQLExecutionContext get _transaction => this;

  @override
  PostgreSQLConnection get _connection => this;

  Socket? get socket => _socket;

  /// dataBase charset
  final Encoding encoding;

  /// Establishes a connection with a PostgreSQL database.
  ///
  /// This method will return a [Future] that completes when the connection is established. Queries can be executed
  /// on this connection afterwards. If the connection fails to be established for any reason - including authentication -
  /// the returned [Future] will return with an error.
  ///
  /// Connections may not be reopened after they are closed or opened more than once. If a connection has already been
  /// opened and this method is called, an exception will be thrown.
  Future open() async {
    if (_hasConnectedPreviously) {
      throw PostgreSQLException(
          'Attempting to reopen a closed connection. Create a instance instead.');
    }

    try {
      _hasConnectedPreviously = true;
      if (isUnixSocket) {
        _socket = await Socket.connect(
                InternetAddress(host, type: InternetAddressType.unix), port)
            .timeout(Duration(seconds: timeoutInSeconds));
      } else {
        _socket = await Socket.connect(host, port)
            .timeout(Duration(seconds: timeoutInSeconds));
      }

      _framer = MessageFramer(encoding, timeZone, decodingSettings,
          replicationMode != ReplicationMode.none);
      // ignore: cancel_subscriptions
      StreamSubscription<Uint8List>? plainSubscription;
      final mode = effectiveSslMode;
      if (mode != PgSslMode.disable) {
        final negotiation = await _negotiateSsl(_socket!, mode,
            timeout: timeoutInSeconds);
        if (negotiation.secureSocket != null) {
          _socket = negotiation.secureSocket;
          _usingSsl = true;
        } else {
          // PgSslMode.prefer e o servidor não aceita SSL: segue sem SSL,
          // reaproveitando a inscrição já feita no socket.
          plainSubscription = negotiation.plainSubscription;
        }
      }

      final connectionComplete = Completer();
      if (plainSubscription != null) {
        plainSubscription
          ..onData(_readData)
          ..onError(_close)
          ..onDone(_close);
      } else {
        _socket!.listen(_readData, onError: _close, onDone: _close);
      }

      _transitionToState(
          _PostgreSQLConnectionStateSocketConnected(connectionComplete));

      await connectionComplete.future
          .timeout(Duration(seconds: timeoutInSeconds));
    } on TimeoutException catch (e, st) {
      final err = PostgreSQLException(
          'Failed to connect to database $host:$port/$databaseName failed to connect.');
      await _close(err, st);
      rethrow;
    } catch (e, st) {
      await _close(e, st);

      rethrow;
    }
  }

  /// Closes a connection.
  ///
  /// After the returned [Future] completes, this connection can no longer be used to execute queries. Any queries in progress or queued are cancelled.
  Future close() => _close();

  /// Adds a Client Message to the existing connection
  ///
  /// This is a low level API and the message must follow the protocol of this
  /// connection. It's the responsiblity of the caller to ensure this message
  /// does not interfere with any running queries or transactions.
  void addMessage(ClientMessage message) {
    if (isClosed) {
      throw PostgreSQLException(
          'Attempting to add a message, but connection is not open.');
    }
    _socket!.add(message.asBytes());
  }

  /// Executes a series of queries inside a transaction on this connection.
  ///
  /// Queries executed inside [queryBlock] will be grouped together in a transaction. The return value of the [queryBlock]
  /// will be the wrapped in the [Future] returned by this method if the transaction completes successfully.
  ///
  /// If a query or execution fails - for any reason - within a transaction block,
  /// the transaction will fail and previous statements within the transaction will not be committed. The [Future]
  /// returned from this method will be completed with the error from the first failing query.
  ///
  /// Transactions may be cancelled by invoking [PostgreSQLExecutionContext.cancelTransaction]
  /// within the transaction. This will cause this method to return a [Future] with a value of [PostgreSQLRollback]. This method does not throw an exception
  /// if the transaction is cancelled in this way.
  ///
  /// All queries within a transaction block must be executed using the [PostgreSQLExecutionContext] passed into the [queryBlock].
  /// You must not issue queries to the receiver of this method from within the [queryBlock], otherwise the connection will deadlock.
  ///
  /// Queries within a transaction may be executed asynchronously or be awaited on. The order is still guaranteed. Example:
  ///
  ///         connection.transaction((ctx) {
  ///           var rows = await ctx.query("SELECT id FROM t");
  ///           if (!rows.contains([2])) {
  ///             ctx.query("INSERT INTO t (id) VALUES (2)");
  ///           }
  ///         });
  ///
  /// If specified, the final `"COMMIT"` query of the transaction will use
  /// [commitTimeoutInSeconds] as its timeout, otherwise the connection's
  /// default query timeout will be used.
  Future transaction(
    Future Function(PostgreSQLExecutionContext connection) queryBlock, {
    int? commitTimeoutInSeconds,
  }) async {
    if (isClosed) {
      throw PostgreSQLException(
          'Attempting to execute query, but connection is not open.');
    }

    final proxy = _TransactionProxy(this, queryBlock, commitTimeoutInSeconds);
    // Se o BEGIN falhar (por exemplo, a conexão foi fechada com a transação
    // na fila), o erro é lançado abaixo e proxy.future também falha: sem
    // isto, esse segundo erro ficava sem tratamento.
    proxy.future.ignore();

    await _enqueue(proxy._beginQuery);

    return await proxy.future;
  }

  @override
  void cancelTransaction({String? reason}) {
    // Default is no-op
  }

  ////////

  void _transitionToState(_PostgreSQLConnectionState newState) {
    if (identical(newState, _connectionState)) {
      return;
    }

    _connectionState.onExit();

    _connectionState = newState;
    _connectionState.connection = this;

    _transitionToState(_connectionState.onEnter());
  }

  Future _close([dynamic error, StackTrace? trace]) async {
    final previousState = _connectionState;
    _connectionState = _PostgreSQLConnectionStateClosed();
    // As consultas de uma transação em andamento ficam na fila da própria
    // transação: elas também falham (antes ficavam esperando o timeout).
    final transaction = switch (previousState) {
      _PostgreSQLConnectionStateBusy(:final query) => query.transaction,
      _PostgreSQLConnectionStateReadyInTransaction(:final transaction) =>
        transaction,
      _ => null,
    };
    if (transaction is _TransactionProxy) {
      transaction._queue.cancel(error, trace);
    }

    if (_socket != null) {
      if (_copyFlushing) {
        _socket!.destroy();
      } else {
        await _socket!.close();
      }
    }
    await _notifications.close();

    await _messages.close();

    _queue.cancel(error, trace);
  }

  void _readData(List<int> bytes) {
    // Note that the way this method works, if a query is in-flight, and we move to the closed state
    // manually, the delivery of the bytes from the socket is sent to the 'Closed State',
    // and the state node managing delivering data to the query no longer exists. Therefore,
    // as soon as a close occurs, we detach the data stream from anything that actually does
    // anything with that data.
    try {
      _framer.addBytes(castBytes(bytes));
    } catch (e, st) {
      // Uma mensagem que não pode ser lida (por exemplo, texto que o
      // encoding da conexão não decodifica) deixa o framer fora de
      // sincronia: a conexão é fechada com o erro, em vez de o erro escapar
      // sem tratamento e as consultas ficarem esperando.
      _close(e, st);
      return;
    }
    while (_framer.hasMessage) {
      final msg = _framer.popMessage();
      try {
        if (_messages.hasListener) {
          _messages.add(msg);
        }
        if (msg is ErrorResponseMessage) {
          final state = _connectionState;
          final exception = PostgreSQLException._(msg.fields);
          if ((exception.severity == PostgreSQLSeverity.fatal ||
                  exception.severity == PostgreSQLSeverity.panic) &&
              (state is _PostgreSQLConnectionStateIdle ||
                  state is _PostgreSQLConnectionStateBusy ||
                  state is _PostgreSQLConnectionStateReadyInTransaction)) {
            // O servidor vai encerrar a conexão (por exemplo,
            // pg_terminate_backend): a consulta em execução e as que estão
            // na fila (inclusive as de uma transação) falham na hora com o
            // erro do servidor. Antes, as da transação esperavam o timeout.
            _close(exception);
            return;
          }
          _transitionToState(_connectionState.onErrorResponse(msg));
        } else if (msg is ParameterStatusMessage) {
          // Mudanças feitas depois da conexão (SET application_name, SET
          // TimeZone...) também atualizam [settings].
          settings[msg.name] = msg.value;
          _transitionToState(_connectionState.onMessage(msg));
        } else if (msg is NotificationResponseMessage) {
          _notifications
              .add(Notification(msg.processID, msg.channel, msg.payload));
        } else {
          _transitionToState(_connectionState.onMessage(msg));
        }
      } catch (e, st) {
        _close(e, st);
      }
    }
  }

  /// Envia um SSLRequest e, conforme a resposta e o [mode], devolve o socket
  /// seguro ou (apenas em [PgSslMode.prefer]) a inscrição no socket sem SSL.
  Future<_SslNegotiation> _negotiateSsl(Socket originalSocket, PgSslMode mode,
      {int timeout = 30}) async {
    final sslCompleter = Completer<int>();

    // ignore: cancel_subscriptions
    final subscription = originalSocket.listen((data) {
      if (sslCompleter.isCompleted) return;
      if (data.length != 1) {
        sslCompleter.completeError(PostgreSQLException(
            'Could not initialize SSL connection, received unknown byte stream.'));
        return;
      }

      sslCompleter.complete(data.first);
    },
        onDone: () {
          if (!sslCompleter.isCompleted) {
            sslCompleter.completeError(PostgreSQLException(
                'Could not initialize SSL connection, connection closed during handshake.'));
          }
        },
        onError: (Object e, StackTrace st) {
          if (!sslCompleter.isCompleted) sslCompleter.completeError(e, st);
        });

    final byteBuffer = ByteData(8);
    byteBuffer.setUint32(0, 8);
    byteBuffer.setUint32(4, 80877103);
    originalSocket.add(byteBuffer.buffer.asUint8List());

    final responseByte =
        await sslCompleter.future.timeout(Duration(seconds: timeout));
    if (responseByte != 83) {
      if (mode == PgSslMode.prefer) {
        return _SslNegotiation(null, subscription);
      }
      throw PostgreSQLException(
          'The database server is not accepting SSL connections.');
    }

    final secure = await SecureSocket.secure(originalSocket,
            host: mode == PgSslMode.verifyFull ? host : null,
            onBadCertificate:
                mode == PgSslMode.verifyFull ? null : (certificate) => true)
        .timeout(Duration(seconds: timeout));
    return _SslNegotiation(secure, null);
  }

  /// Cancela, no servidor, a consulta em execução nesta conexão (envia um
  /// CancelRequest por uma conexão separada, como o libpq).
  ///
  /// Não faz nada se a conexão estiver fechada. A consulta cancelada falha
  /// com o SQLSTATE [PgErrorCode.queryCanceled]. Se nenhuma consulta estiver
  /// em execução quando o pedido chegar ao servidor, ele é ignorado.
  Future<void> cancelQuery() async {
    if (isClosed || !_hasBackendKey) return;
    Socket socket;
    if (isUnixSocket) {
      socket = await Socket.connect(
              InternetAddress(host, type: InternetAddressType.unix), port)
          .timeout(Duration(seconds: timeoutInSeconds));
    } else {
      socket = await Socket.connect(host, port)
          .timeout(Duration(seconds: timeoutInSeconds));
    }
    try {
      if (_usingSsl) {
        final negotiation = await _negotiateSsl(socket, effectiveSslMode,
            timeout: timeoutInSeconds);
        socket = negotiation.secureSocket ?? socket;
      }
      final request = ByteData(16)
        ..setInt32(0, 16)
        ..setInt32(4, 80877102)
        ..setInt32(8, _processID)
        ..setInt32(12, _secretKey);
      socket.add(request.buffer.asUint8List());
      await socket.flush();
    } finally {
      socket.destroy();
    }
  }

  /// Passa a receber notificações do canal [channel] (`LISTEN`). As
  /// notificações chegam em [notifications] (ou [notificationsFor]).
  Future<void> listen(String channel) =>
      execute('LISTEN ${_quoteIdentifier(channel)}');

  /// Deixa de receber notificações de [channel], ou de todos os canais se
  /// [channel] for omitido (`UNLISTEN`).
  Future<void> unlisten([String? channel]) => execute(channel == null
      ? 'UNLISTEN *'
      : 'UNLISTEN ${_quoteIdentifier(channel)}');

  /// Envia uma notificação para [channel] (`pg_notify`).
  Future<void> notify(String channel, [String? payload]) => query(
      'SELECT pg_notify(@channel:text, @payload:text)',
      substitutionValues: {'channel': channel, 'payload': payload ?? ''});

  /// Notificações recebidas apenas do canal [channel].
  Stream<Notification> notificationsFor(String channel) =>
      notifications.where((n) => n.channel == channel);

}

/// Parâmetros que o driver já envia na mensagem de startup (ou reservados
/// pelo protocolo) e por isso não podem ser informados em
/// `startupParameters`.
const _reservedStartupParameters = {
  'user',
  'database',
  'replication',
  'client_encoding',
  'timezone',
};

void _checkStartupParameters(Map<String, String> parameters) {
  for (final name in parameters.keys) {
    final lower = name.toLowerCase();
    if (_reservedStartupParameters.contains(lower) ||
        lower.startsWith('_pq_') ||
        name.isEmpty) {
      throw ArgumentError.value(name, 'startupParameters',
          'This parameter is set by the driver (or reserved by the protocol)');
    }
  }
}

class _SslNegotiation {
  final SecureSocket? secureSocket;
  final StreamSubscription<Uint8List>? plainSubscription;

  _SslNegotiation(this.secureSocket, this.plainSubscription);
}

String _quoteIdentifier(String identifier) =>
    '"${identifier.replaceAll('"', '""')}"';

class _TransactionRollbackException implements Exception {
  _TransactionRollbackException(this.reason);

  String reason;
}

/// Represents a notification from PostgreSQL.
///
/// Instances of this type are created and sent via [PostgreSQLConnection.notifications].
class Notification {
  /// Creates an instance of this type.
  Notification(this.processID, this.channel, this.payload);

  /// The backend ID from which the notification was generated.
  final int processID;

  /// The name of the PostgreSQL channel that this notification occurred on.
  final String channel;

  /// An optional data payload accompanying this notification.
  final String payload;
}

class _OidCache {
  final _tableOIDNameMap = <int, String>{};
  int _queryCount = 0;

  int get queryCount => _queryCount;

  void clear() {
    _queryCount = 0;
    _tableOIDNameMap.clear();
  }

  Future<List<FieldDescription>> _resolveTableNames(
      _PostgreSQLExecutionContextMixin c,
      List<FieldDescription?>? columns) async {
    if (columns == null) return [];
    //todo (joeconwaystk): If this was a cached query, resolving is table oids is unnecessary.
    // It's not a significant impact here, but an area for optimization. This includes
    // assigning resolvedTableName
    final unresolvedTableOIDs = columns
        .where((f) => f != null)
        .map((f) => f!.tableID)
        .toSet()
        .where((oid) => oid > 0 && !_tableOIDNameMap.containsKey(oid))
        .toList()
      ..sort();

    if (unresolvedTableOIDs.isNotEmpty) {
      await _resolveTableOIDs(c, unresolvedTableOIDs);
    }

    return columns
        .map((c) => c!.change(tableName: _tableOIDNameMap[c.tableID]))
        .toList();
  }

  Future _resolveTableOIDs(
      _PostgreSQLExecutionContextMixin c, List<int> oids) async {
    _queryCount++;
    final unresolvedIDString = oids.join(',');
    final tableNames = await c._query(
      "SELECT oid::int8, relname FROM pg_class WHERE relkind='r' AND oid IN ($unresolvedIDString)",
      placeholderIdentifier: PlaceholderIdentifier.atSign,
      allowReuse: false, // inlined OIDs would make it difficult anyway
      resolveOids: false,
    );

    // Associa pelo OID: antes os nomes eram associados pela posição, e um
    // OID sem linha (uma view, por exemplo) deslocava os nomes dos demais.
    for (final row in tableNames) {
      if (row[1] != null) {
        _tableOIDNameMap[row[0] as int] = row[1] as String;
      }
    }
  }
}

abstract mixin class _PostgreSQLExecutionContextMixin
    implements PostgreSQLExecutionContext {
  final _queue = QueryQueue();

  PostgreSQLConnection get _connection;

  PostgreSQLExecutionContext get _transaction;

  @override
  int get queueSize => _queue.length;

  /// Break change
  @override
  Future<PostgreSQLResult> query(
    String fmtString, {
    dynamic substitutionValues,
    bool? allowReuse,
    int? timeoutInSeconds,
    bool? useSimpleQueryProtocol,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
  }) =>
      _query(fmtString,
          substitutionValues: substitutionValues,
          allowReuse: allowReuse ?? true,
          useSimpleQueryProtocol: useSimpleQueryProtocol ?? false,
          timeoutInSeconds: timeoutInSeconds,
          placeholderIdentifier: placeholderIdentifier);

  Future<PostgreSQLResult> _query(
    String fmtString, {
    dynamic substitutionValues,
    required bool allowReuse,
    required PlaceholderIdentifier placeholderIdentifier,
    int? timeoutInSeconds,
    bool resolveOids = true,
    bool useSimpleQueryProtocol = false,
  }) async {
    timeoutInSeconds ??= _connection.queryTimeoutInSeconds;

    if (useSimpleQueryProtocol) {
      // re-route the query to the `_execute` method which will execute the query
      // using the Simple Query Protocol.
      return _execute(fmtString,
          timeoutInSeconds: timeoutInSeconds,
          onlyReturnAffectedRows: false,
          substitutionValues: substitutionValues,
          placeholderIdentifier: placeholderIdentifier);
    }

    if (_connection.isClosed) {
      throw PostgreSQLException(
          'Attempting to execute query, but connection is not open.');
    }

    final query = Query<List<List<dynamic>>>(fmtString, substitutionValues,
        _connection, _transaction, StackTrace.current,
        placeholderIdentifier: placeholderIdentifier);
    if (allowReuse) {
      query.statementIdentifier = _connection._cache.identifierForQuery(query);
    }

    final queryResult =
        await _enqueue(query, timeoutInSeconds: timeoutInSeconds);
    var columnDescriptions = query.fieldDescriptions;
    if (resolveOids) {
      columnDescriptions = await _connection._oidCache
          ._resolveTableNames(this, columnDescriptions);
    }
    final metaData = _PostgreSQLResultMetaData(columnDescriptions!);

    return _PostgreSQLResult(
        queryResult.affectedRowCount,
        metaData,
        queryResult.value!
            .map((columns) => _PostgreSQLResultRow(metaData, columns))
            .toList());
  }

  @override
  Future<List<Map<String, Map<String, dynamic>>>> mappedResultsQuery(
    String fmtString, {
    dynamic substitutionValues = const <String, dynamic>{},
    bool? allowReuse,
    int? timeoutInSeconds,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
  }) async {
    final rs = await query(fmtString,
        substitutionValues: substitutionValues,
        allowReuse: allowReuse ?? false,
        timeoutInSeconds: timeoutInSeconds,
        placeholderIdentifier: placeholderIdentifier);

    return rs.map((row) => row.toTableColumnMap()).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> queryAsMap(
    String fmtString, {
    dynamic substitutionValues = const <String, dynamic>{},
    bool? allowReuse,
    int? timeoutInSeconds,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
  }) async {
    final rs = await query(fmtString,
        substitutionValues: substitutionValues,
        allowReuse: allowReuse ?? false,
        timeoutInSeconds: timeoutInSeconds,
        placeholderIdentifier: placeholderIdentifier);

    return rs.map((row) => row.toColumnMap()).toList();
  }

  @override
  Future<int> execute(
    String fmtString, {
    dynamic substitutionValues = const <String, dynamic>{},
    int? timeoutInSeconds,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
  }) async {
    final result = await _execute(
      fmtString,
      substitutionValues: substitutionValues,
      // O timeout informado era ignorado (sempre usava o da conexão).
      timeoutInSeconds: timeoutInSeconds ?? _connection.queryTimeoutInSeconds,
      onlyReturnAffectedRows: true,
      placeholderIdentifier: placeholderIdentifier,
    );
    return result.affectedRowCount;
  }

  /// Executa [fmtString] pelo protocolo simples ("Simple Query Protocol").
  ///
  /// É usado por [execute] (que devolve só o número de linhas afetadas) e por
  /// [query] com `useSimpleQueryProtocol: true` (que devolve as linhas, em
  /// texto). As duas formas públicas foram mantidas na 3.0.0 porque mudar o
  /// retorno de [execute] ou remover `useSimpleQueryProtocol` quebraria o
  /// código que já as usa.
  Future<PostgreSQLResult> _execute(
    String fmtString, {
    dynamic substitutionValues = const <String, dynamic>{},
    required int timeoutInSeconds,
    required bool onlyReturnAffectedRows,
    required PlaceholderIdentifier placeholderIdentifier,
  }) async {
    if (_connection.isClosed) {
      throw PostgreSQLException(
          'Attempting to execute query, but connection is not open.');
    }

    final query = Query<dynamic>(
      fmtString, substitutionValues, _connection,
      _transaction, StackTrace.current,
      // useSendSimple escolhe o protocolo simples; onlyReturnAffectedRowCount
      // apenas descarta as linhas (usado por [execute]).
      useSendSimple: true,
      onlyReturnAffectedRowCount: onlyReturnAffectedRows,
      placeholderIdentifier: placeholderIdentifier,
    );

    final result = await _enqueue(query, timeoutInSeconds: timeoutInSeconds);

    final affectedRowCount = result.affectedRowCount;
    final columnDescriptions = query.fieldDescriptions ?? [];
    final metaData = _PostgreSQLResultMetaData(columnDescriptions);

    final value = result.value;
    late final List<PostgreSQLResultRow> rows;
    if (value != null && value is List<List>) {
      rows = value
          .map((columns) => _PostgreSQLResultRow(metaData, columns))
          .toList();
    } else {
      rows = [];
    }

    return _PostgreSQLResult(
      affectedRowCount,
      metaData,
      rows,
    );
  }

  @override
  void cancelTransaction({String? reason});

  /// Executa um `COPY ... FROM STDIN` enviando [data] (no formato indicado
  /// no próprio comando: texto, CSV ou binário) e devolve o número de linhas
  /// copiadas.
  ///
  /// [sql] é enviado como está (sem placeholders), exceto quando
  /// [substitutionValues] é informado. Os blocos de [data] são enviados à
  /// medida que chegam, com controle de fluxo; um bloco não pode ser
  /// alterado depois de emitido. Se [data] emitir um erro, o COPY é
  /// abortado no servidor (nada é gravado) e o erro é lançado; a conexão
  /// continua utilizável. Erros do servidor (por exemplo, uma linha
  /// inválida) interrompem o envio e são lançados como
  /// [PostgreSQLException].
  ///
  /// O tempo limite ([timeoutInSeconds], ou `queryTimeoutInSeconds` da
  /// conexão) vale para o COPY inteiro; ao expirar, o COPY é abortado.
  ///
  /// Para gravar valores Dart, veja [copyRows].
  Future<int> copyFrom(String sql, Stream<List<int>> data,
      {dynamic substitutionValues,
      PlaceholderIdentifier placeholderIdentifier =
          PlaceholderIdentifier.atSign,
      int? timeoutInSeconds}) async {
    final query = _copyQuery(sql, substitutionValues, placeholderIdentifier)
      ..copyInData = data;
    final result = await _enqueue(query,
        timeoutInSeconds: timeoutInSeconds ?? _connection.queryTimeoutInSeconds);
    return result.affectedRowCount;
  }

  /// Executa um `COPY ... TO STDOUT`, entregando a [onData] o conteúdo de
  /// cada mensagem de dados (no formato texto, uma linha por chamada; veja
  /// [PgCopy.decodeTextRow]), e devolve o número de linhas copiadas.
  ///
  /// Se [onData] lançar uma exceção, os dados restantes são descartados e a
  /// exceção é lançada ao final do COPY; a conexão continua utilizável.
  Future<int> copyTo(String sql, void Function(Uint8List data) onData,
      {dynamic substitutionValues,
      PlaceholderIdentifier placeholderIdentifier =
          PlaceholderIdentifier.atSign,
      int? timeoutInSeconds}) async {
    final query = _copyQuery(sql, substitutionValues, placeholderIdentifier)
      ..copyOutHandler = onData;
    final result = await _enqueue(query,
        timeoutInSeconds: timeoutInSeconds ?? _connection.queryTimeoutInSeconds);
    return result.affectedRowCount;
  }

  /// Insere [rows] em [table] com `COPY ... FROM STDIN` (formato texto),
  /// muito mais rápido que INSERTs para muitas linhas. Devolve o número de
  /// linhas inseridas.
  ///
  /// [table], [schema] e [columns] são nomes (entre aspas no SQL gerado,
  /// portanto diferenciam maiúsculas de minúsculas). Cada linha deve ter um
  /// valor por coluna; os tipos aceitos estão em [PgCopy.encodeTextValue].
  /// Se uma linha for inválida, nada é inserido.
  Future<int> copyRows(
      String table, List<String> columns, Iterable<List<Object?>> rows,
      {String? schema, int? timeoutInSeconds}) {
    if (columns.isEmpty) {
      throw ArgumentError.value(columns, 'columns', 'Must not be empty');
    }
    final target = schema == null
        ? _quoteIdentifier(table)
        : '${_quoteIdentifier(schema)}.${_quoteIdentifier(table)}';
    final sql = 'COPY $target (${columns.map(_quoteIdentifier).join(', ')}) '
        'FROM STDIN';
    return copyFrom(
        sql,
        PgCopy.encodeTextRows(rows,
            encoding: _connection.encoding, columnCount: columns.length),
        timeoutInSeconds: timeoutInSeconds);
  }

  /// Executa [fmtString] (um `SELECT`, `VALUES` ou `TABLE`) com um cursor
  /// no servidor e entrega as linhas aos poucos, em lotes de [fetchSize]
  /// (`DECLARE ... CURSOR` e `FETCH`).
  ///
  /// O próximo lote só é buscado quando o consumidor do stream pede mais
  /// dados (respeita pause), então no máximo uns dois lotes ficam na memória,
  /// mesmo para milhões de linhas. Cancelar a inscrição fecha o cursor. Os
  /// parâmetros e placeholders funcionam como em [query]; [timeoutInSeconds]
  /// vale para cada lote.
  ///
  /// Na conexão, o cursor roda numa transação própria, que ocupa a conexão
  /// até o stream terminar ou ser cancelado (as outras consultas esperam).
  /// Dentro de [PostgreSQLConnection.transaction], o stream deve ser
  /// consumido antes de o bloco terminar; senão ele recebe um [StateError]
  /// e o cursor é fechado antes do COMMIT. Um erro numa consulta do cursor
  /// desfaz a transação, como qualquer outra consulta.
  Stream<PostgreSQLResultRow> queryStream(
    String fmtString, {
    dynamic substitutionValues,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
    int fetchSize = 1000,
    int? timeoutInSeconds,
  }) {
    if (fetchSize < 1) {
      throw ArgumentError.value(fetchSize, 'fetchSize', 'Must be positive');
    }
    return _CursorStream(this, fmtString, substitutionValues,
            placeholderIdentifier, fetchSize, timeoutInSeconds)
        ._controller
        .stream;
  }

  Query<dynamic> _copyQuery(String sql, dynamic substitutionValues,
      PlaceholderIdentifier placeholderIdentifier) {
    if (_connection.isClosed) {
      throw PostgreSQLException(
          'Attempting to execute query, but connection is not open.');
    }
    return Query<dynamic>(sql, substitutionValues ?? const <String, dynamic>{},
        _connection, _transaction, StackTrace.current,
        useSendSimple: true,
        onlyReturnAffectedRowCount: true,
        placeholderIdentifier: placeholderIdentifier)
      ..rawStatement = substitutionValues == null;
  }

  Future<QueryResult<T>> _enqueue<T>(Query<T> query,
      {int timeoutInSeconds = 30}) async {
    if (_queue.add(query)) {
      _connection._transitionToState(_connection._connectionState.awake());

      try {
        final result =
            await query.future.timeout(Duration(seconds: timeoutInSeconds));
        _connection._cache.add(query);
        _queue.remove(query);
        return result!;
      } catch (e, st) {
        if (e is TimeoutException) {
          // Interrompe o envio de dados de um COPY FROM STDIN em andamento.
          query.abandon();
        }
        if (e is TimeoutException && _connection.cancelQueryOnTimeout) {
          // Só cancela se esta consulta for a que está em execução: se ela
          // ainda estiver na fila, basta removê-la.
          final state = _connection._connectionState;
          if (state is _PostgreSQLConnectionStateBusy &&
              identical(state.query, query)) {
            unawaited(_connection.cancelQuery().catchError((_) {}));
          }
        }
        _queue.remove(query);
        if (query.statementIdentifier != null &&
            e is PostgreSQLException &&
            (e.code == '26000' || e.code == '0A000')) {
          // O prepared statement não existe mais no servidor (DEALLOCATE,
          // DISCARD ALL, pooler) ou o plano dele não vale mais (ALTER TABLE
          // mudou o tipo do resultado: "cached plan must not change result
          // type"). Antes ele ficava no cache e toda execução seguinte
          // falhava; agora a próxima o prepara de novo.
          _connection._cache.invalidate(query.statement);
        }
        await _onQueryError(query, e, st);
        rethrow;
      }
    } else {
      // wrap the synchronous future in an async future to ensure that
      // the caller behaves correctly in this condition. otherwise,
      // the caller would complete synchronously. This future
      // will always complete as a cancellation error.
      return Future(() async => (await query.future)!);
    }
  }

  Future _onQueryError(Query query, dynamic error, [StackTrace? trace]) async {}
}

class _PostgreSQLResultMetaData {
  final List<ColumnDescription> columnDescriptions;
  late List<String?> _tableNames;

  _PostgreSQLResultMetaData(this.columnDescriptions) {
    _tableNames =
        columnDescriptions.map((column) => column.tableName).toSet().toList();
  }

  List<String?> get tableNames {
    return _tableNames;
  }
}

class _PostgreSQLResult extends UnmodifiableListView<PostgreSQLResultRow>
    implements PostgreSQLResult {
  @override
  final int affectedRowCount;
  final _PostgreSQLResultMetaData _metaData;

  _PostgreSQLResult(
      this.affectedRowCount, this._metaData, List<PostgreSQLResultRow> rows)
      : super(rows);

  @override
  List<ColumnDescription> get columnDescriptions =>
      _metaData.columnDescriptions;
}

class _PostgreSQLResultRow extends UnmodifiableListView
    implements PostgreSQLResultRow {
  final _PostgreSQLResultMetaData _metaData;

  _PostgreSQLResultRow(this._metaData, List columns) : super(columns);

  @override
  List<ColumnDescription> get columnDescriptions =>
      _metaData.columnDescriptions;

  @override
  Map<String, Map<String, dynamic>> toTableColumnMap() {
    final rowMap = <String, Map<String, dynamic>>{};
    for (final tableName in _metaData.tableNames) {
      rowMap[tableName ?? ''] = <String, dynamic>{};
    }
    for (var i = 0; i < _metaData.columnDescriptions.length; i++) {
      final col = _metaData.columnDescriptions[i];
      rowMap[col.tableName]![col.columnName] = this[i];
    }
    return rowMap;
  }

  @override
  Map<String, dynamic> toColumnMap() {
    final rowMap = <String, dynamic>{};
    for (var i = 0; i < _metaData.columnDescriptions.length; i++) {
      final col = _metaData.columnDescriptions[i];
      rowMap[col.columnName] = this[i];
    }
    return rowMap;
  }
}

/// COPY em qualquer [PostgreSQLExecutionContext] de uma
/// [PostgreSQLConnection], inclusive o contexto recebido em
/// [PostgreSQLConnection.transaction]. Os métodos estão documentados em
/// [PostgreSQLConnection.copyFrom], [PostgreSQLConnection.copyTo] e
/// [PostgreSQLConnection.copyRows].
extension PgCopyExecutionContext on PostgreSQLExecutionContext {
  Future<int> copyFrom(String sql, Stream<List<int>> data,
      {dynamic substitutionValues,
      PlaceholderIdentifier placeholderIdentifier =
          PlaceholderIdentifier.atSign,
      int? timeoutInSeconds}) {
    final self = this;
    if (self is PostgreSQLPool) {
      return self.copyFrom(sql, data,
          substitutionValues: substitutionValues,
          placeholderIdentifier: placeholderIdentifier,
          timeoutInSeconds: timeoutInSeconds);
    }
    return _copyContext.copyFrom(sql, data,
        substitutionValues: substitutionValues,
        placeholderIdentifier: placeholderIdentifier,
        timeoutInSeconds: timeoutInSeconds);
  }

  Future<int> copyTo(String sql, void Function(Uint8List data) onData,
      {dynamic substitutionValues,
      PlaceholderIdentifier placeholderIdentifier =
          PlaceholderIdentifier.atSign,
      int? timeoutInSeconds}) {
    final self = this;
    if (self is PostgreSQLPool) {
      return self.copyTo(sql, onData,
          substitutionValues: substitutionValues,
          placeholderIdentifier: placeholderIdentifier,
          timeoutInSeconds: timeoutInSeconds);
    }
    return _copyContext.copyTo(sql, onData,
        substitutionValues: substitutionValues,
        placeholderIdentifier: placeholderIdentifier,
        timeoutInSeconds: timeoutInSeconds);
  }

  Future<int> copyRows(
      String table, List<String> columns, Iterable<List<Object?>> rows,
      {String? schema, int? timeoutInSeconds}) {
    final self = this;
    if (self is PostgreSQLPool) {
      return self.copyRows(table, columns, rows,
          schema: schema, timeoutInSeconds: timeoutInSeconds);
    }
    return _copyContext.copyRows(table, columns, rows,
        schema: schema, timeoutInSeconds: timeoutInSeconds);
  }

  _PostgreSQLExecutionContextMixin get _copyContext {
    final self = this;
    if (self is _PostgreSQLExecutionContextMixin) return self;
    throw UnsupportedError('COPY is only supported by PostgreSQLConnection, '
        'its transactions and PostgreSQLPool, not by $runtimeType.');
  }
}

/// Stream de linhas de um cursor no servidor (ver
/// [PostgreSQLConnection.queryStream]).
class _CursorStream {
  _CursorStream(this._owner, this._sql, this._substitutionValues,
      this._placeholderIdentifier, this._fetchSize, this._timeoutInSeconds) {
    _controller = StreamController<PostgreSQLResultRow>(
        onListen: _start, onResume: _wake, onCancel: _onCancel);
  }

  final _PostgreSQLExecutionContextMixin _owner;
  final String _sql;
  final dynamic _substitutionValues;
  final PlaceholderIdentifier _placeholderIdentifier;
  final int _fetchSize;
  final int? _timeoutInSeconds;

  late final StreamController<PostgreSQLResultRow> _controller;

  /// Completa quando o cursor foi fechado (ou falhou) e o stream encerrado.
  final _finished = Completer<void>();

  Completer<void>? _wakeUp;
  bool _cancelled = false;
  Object? _abortError;

  void _wake() {
    final wakeUp = _wakeUp;
    _wakeUp = null;
    wakeUp?.complete();
  }

  Future<void> _onCancel() {
    _cancelled = true;
    _wake();
    return _finished.future;
  }

  /// Interrompe o stream (a transação está terminando).
  void _abort(Object error) {
    _abortError ??= error;
    _wake();
  }

  void _finish([Object? error, StackTrace? stackTrace]) {
    if (_finished.isCompleted) return;
    if (error != null && !_cancelled) {
      _controller.addError(error, stackTrace);
    }
    unawaited(_controller.close());
    _finished.complete();
  }

  void _start() {
    final owner = _owner;
    if (owner is _TransactionProxy) {
      if (owner._isFinished) {
        _finish(StateError('The transaction has already finished.'));
        return;
      }
      owner._activeStreams.add(this);
      _fetch(owner).then((_) => _finish(), onError: _finish).whenComplete(
          () => owner._activeStreams.remove(this));
    } else {
      // Na conexão: uma transação só para o cursor.
      Object? fetchError;
      StackTrace? fetchStackTrace;
      (owner as PostgreSQLConnection)
          .transaction((tx) async {
            try {
              await _fetch(tx as _TransactionProxy);
            } catch (e, st) {
              fetchError = e;
              fetchStackTrace = st;
              rethrow;
            }
          })
          .then((_) => _finish(),
              onError: (Object e, StackTrace st) =>
                  _finish(fetchError ?? e, fetchStackTrace ?? st));
    }
  }

  Future<void> _fetch(_TransactionProxy tx) async {
    final name = '"pg_stream_cursor_${tx._connection._cursorCounter++}"';
    await tx.query('DECLARE $name NO SCROLL CURSOR FOR $_sql',
        substitutionValues: _substitutionValues,
        placeholderIdentifier: _placeholderIdentifier,
        // O statement inclui o nome do cursor: não vale a pena guardar.
        allowReuse: false,
        timeoutInSeconds: _timeoutInSeconds);
    while (!_cancelled && _abortError == null) {
      if (_controller.isPaused) {
        final wakeUp = _wakeUp = Completer<void>();
        await wakeUp.future;
        continue;
      }
      // O FETCH não pode usar o cache de statements: a descrição das colunas
      // depende do cursor, e o cache é por texto SQL.
      final rows = await tx.query('FETCH FORWARD $_fetchSize FROM $name',
          allowReuse: false, timeoutInSeconds: _timeoutInSeconds);
      for (final row in rows) {
        _controller.add(row);
      }
      if (rows.length < _fetchSize) break;
    }
    if (!tx._hasRolledBack && !tx._hasFailed) {
      await tx.execute('CLOSE $name', timeoutInSeconds: _timeoutInSeconds);
    }
    final abortError = _abortError;
    if (abortError != null) {
      Error.throwWithStackTrace(abortError, StackTrace.current);
    }
  }
}

/// [queryStream] em qualquer [PostgreSQLExecutionContext] de uma
/// [PostgreSQLConnection], inclusive o contexto recebido em
/// [PostgreSQLConnection.transaction] (ver [PostgreSQLConnection.queryStream]).
extension PgQueryStreamExecutionContext on PostgreSQLExecutionContext {
  Stream<PostgreSQLResultRow> queryStream(
    String fmtString, {
    dynamic substitutionValues,
    PlaceholderIdentifier placeholderIdentifier = PlaceholderIdentifier.atSign,
    int fetchSize = 1000,
    int? timeoutInSeconds,
  }) {
    final self = this;
    if (self is _PostgreSQLExecutionContextMixin) {
      return self.queryStream(fmtString,
          substitutionValues: substitutionValues,
          placeholderIdentifier: placeholderIdentifier,
          fetchSize: fetchSize,
          timeoutInSeconds: timeoutInSeconds);
    }
    if (self is PostgreSQLPool) {
      return self.queryStream(fmtString,
          substitutionValues: substitutionValues,
          placeholderIdentifier: placeholderIdentifier,
          fetchSize: fetchSize,
          timeoutInSeconds: timeoutInSeconds);
    }
    throw UnsupportedError('queryStream is only supported by '
        'PostgreSQLConnection, its transactions and PostgreSQLPool, not by '
        '$runtimeType.');
  }
}
