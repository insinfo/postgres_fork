import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres_fork/postgres.dart';

import '../../postgres_v3_experimental.dart';
import '../auth/auth.dart';
import '../binary_codec.dart';

import '../query.dart';
import '../text_codec.dart';
import '../utils/ascii.dart';
import '../utils/operation_lock.dart';
import '../utils/stream_channel.dart';
import 'protocol.dart';
import 'query_description.dart';

const _debugLog = false;

String identifier(String source) {
  // To avoid complex ambiguity rules, we always wrap identifier in double
  // quotes. That means the only character we need to escape are double quotes
  // in the source.
  final escaped = source.replaceAll('"', '""');
  return '"$escaped"';
}

class _ResolvedSettings {
  final PgEndpoint endpoint;
  final PgSessionSettings? settings;

  final String username;
  final String password;

  final Duration connectTimeout;
  final Duration queryTimeout;
  final TimeZoneSettings timeZone;
  final Encoding encoding;
  final DecodingSettings decoding;

  final StreamChannelTransformer<BaseMessage, BaseMessage>? transformer;

  _ResolvedSettings(
    this.endpoint,
    this.settings,
  )   : username = endpoint.username ?? 'postgres',
        password = endpoint.password ?? 'postgres',
        connectTimeout =
            settings?.connectTimeout ?? const Duration(seconds: 15),
        queryTimeout = settings?.connectTimeout ?? const Duration(minutes: 5),
        timeZone = settings?.timeZone ?? endpoint.timeZone,
        encoding = settings?.encoding ?? endpoint.encoding,
        decoding = settings?.decodingSettings ?? const DecodingSettings(),
        transformer = settings?.transformer;

  bool onBadSslCertificate(X509Certificate certificate) {
    return settings?.onBadSslCertificate?.call(certificate) ?? false;
  }
}

class PgConnectionImplementation implements PgConnection {
  static Future<PgConnectionImplementation> connect(
    PgEndpoint endpoint, {
    PgSessionSettings? sessionSettings,
  }) async {
    final settings = _ResolvedSettings(endpoint, sessionSettings);
    var channel = await _connect(settings);

    if (_debugLog) {
      channel = channel.transform(StreamChannelTransformer(
        StreamTransformer.fromHandlers(
          handleData: (msg, sink) {
            sink.add(msg);
          },
        ),
        StreamSinkTransformer.fromHandlers(handleData: (msg, sink) {
          sink.add(msg);
        }),
      ));
    }

    if (settings.transformer != null) {
      channel = channel.transform(settings.transformer!);
    }

    final connection = PgConnectionImplementation._(channel, settings);
    await connection._startup();
    return connection;
  }

  static Future<StreamChannel<BaseMessage>> _connect(
    _ResolvedSettings settings,
  ) async {
    Socket socket;

    final host = settings.endpoint.host;
    final port = settings.endpoint.port;

    if (settings.endpoint.isUnixSocket) {
      socket =
          await Socket.connect(host, port, timeout: settings.connectTimeout);
    } else {
      socket =
          await Socket.connect(host, port, timeout: settings.connectTimeout);
    }

    final sslCompleter = Completer<int>.sync();
    // ignore: cancel_subscriptions
    final subscription = socket.listen(
      (data) {
        if (data.length != 1) {
          sslCompleter.completeError(PostgreSQLException(
              'Could not initialize SSL connection, received unknown byte stream.'));
          return;
        }

        sslCompleter.complete(data.first);
      },
      onDone: () => sslCompleter.completeError(PostgreSQLException(
          'Could not initialize SSL connection, connection closed during handshake.')),
      onError: sslCompleter.completeError,
    );

    // Query if SSL is possible by sending a SSLRequest message
    final byteBuffer = ByteData(8);
    byteBuffer.setUint32(0, 8);
    byteBuffer.setUint32(4, 80877103);
    socket.add(byteBuffer.buffer.asUint8List());

    final byte = await sslCompleter.future.timeout(settings.connectTimeout);

    Stream<Uint8List> adaptedStream;

    if (byte == $S) {
      // SSL is supported, upgrade!
      subscription.pause();

      socket = await SecureSocket.secure(
        socket,
        onBadCertificate: settings.onBadSslCertificate,
      ).timeout(settings.connectTimeout);

      // We can listen to the secured socket again, the existing subscription is
      // ignored.
      adaptedStream = socket;
    } else {
      // This server does not support SSL
      if (settings.endpoint.requireSsl) {
        throw PostgreSQLException(
            'Server does not support SSL, but it was required.');
      }

      // We've listened to the stream already and sockets are single-subscription
      // streams. Expose it as a new stream.
      adaptedStream = SubscriptionStream(subscription);
    }

    final outgoingSocket = StreamSinkTransformExtension(socket)
        .transform<Uint8List>(
            StreamSinkTransformer.fromHandlers(handleDone: (out) {
      // As per the stream channel's guarantees, closing the sink should close
      // the channel in both directions.
      socket.destroy();
      return out.close();
    }));

    // return StreamChannel<List<int>>(adaptedStream, outgoingSocket).transform(
    //     WrapMessageTransformer(settings.encoding).messageTransformer);

    return StreamChannel<List<int>>(adaptedStream, outgoingSocket).transform(
        messageTransformer(
            settings.encoding, settings.timeZone, settings.decoding));
  }

  final StreamChannel<BaseMessage> _channel;
  late final StreamSubscription<BaseMessage> _serverMessages;

  final _ResolvedSettings _settings;

  final OperationLock _operationLock = OperationLock();
  _PendingOperation? _pending;

  final Map<String, String> _parameters = {};

  var _statementCounter = 0;
  var _portalCounter = 0;

  late final _Channels _channels = _Channels(this);

  @override
  PgChannels get channels => _channels;

  PgConnectionImplementation._(this._channel, this._settings) {
    _serverMessages = _channel.stream.listen(_handleMessage,
        onDone: () => _markClosed(notifyError: true),
        // Erro no socket (por exemplo, conexão encerrada pelo servidor):
        // antes ficava sem tratamento.
        onError: (Object e) => _markClosed(notifyError: true, cause: e));
  }

  Future<void> _startup() {
    return _operationLock.withResource(() {
      final result = _pending = _AuthenticationProcedure(this);

      _channel.sink.add(StartupMessage(
        _settings.endpoint.database,
        _settings.timeZone,
        username: _settings.username,
        encoding: _settings.endpoint.encoding,
        parameters: {
          if (_settings.settings?.applicationName != null)
            'application_name': _settings.settings!.applicationName!,
          ...?_settings.settings?.startupParameters,
        },
      ));

      return result._done.future.whenComplete(() {
        if (identical(_pending, result)) _pending = null;
      });
    });
  }

  Future<void> _handleMessage(BaseMessage message) async {
    _serverMessages.pause();
    try {
      message as ServerMessage;

      if (message is ParameterStatusMessage) {
        _parameters[message.name] = message.value;
      } else if (message is BackendKeyMessage) {
        // ignore for now
      } else if (message is NotificationResponseMessage) {
        _channels.deliverNotification(message);
      } else if (_pending != null) {
        await _pending!.handleMessage(message);
      }
      if (message is ErrorResponseMessage) {
        final severity =
            PostgreSQLException.fromFields(message.fields).severity;
        if (severity == PostgreSQLSeverity.fatal ||
            severity == PostgreSQLSeverity.panic) {
          // O servidor vai encerrar a conexão (por exemplo,
          // pg_terminate_backend); a operação pendente já recebeu o erro.
          await _markClosed(notifyError: false);
        }
      }
    } finally {
      _serverMessages.resume();
    }
  }

  /// Marca a conexão como fechada e encerra a operação pendente (que, sem
  /// isso, esperaria para sempre por mensagens que não vão chegar).
  Future<void> _markClosed({required bool notifyError, Object? cause}) async {
    if (_closedByServer) return;
    _closedByServer = true;
    _isClosed = true;
    final pending = _pending;
    _pending = null;
    if (pending == null) return;
    try {
      if (notifyError) {
        await pending.handleMessage(_connectionClosedError(cause));
      }
      await pending.handleMessage(
          ReadyForQueryMessage(Uint8List.fromList([0x49]), utf8));
    } catch (_) {
      // A operação já tinha terminado.
    }
  }

  bool _closedByServer = false;

  static ErrorResponseMessage _connectionClosedError([Object? cause]) {
    final bytes = BytesBuilder();
    void field(int code, String value) {
      bytes
        ..addByte(code)
        ..add(utf8.encode(value))
        ..addByte(0);
    }

    field(0x53, 'FATAL'); // S
    field(0x43, '08006'); // C: connection_failure
    field(
        0x4D,
        cause == null
            ? 'The connection was closed.'
            : 'The connection was closed: $cause'); // M
    bytes.addByte(0);
    return ErrorResponseMessage(bytes.toBytes(), utf8);
  }

  PostgreSQLException _closedException() => PostgreSQLException(
      'Attempting to execute query, but connection is not open.');

  Future<T> _sendAndWaitForQuery<T extends ServerMessage>(ClientMessage send) {
    final trace = StackTrace.current;

    return _operationLock.withResource(() {
      if (_isClosed) throw _closedException();
      _channel.sink.add(AggregatedClientMessage([send, const SyncMessage()]));

      final completer = Completer<T>();
      final syncComplete = Completer<void>.sync();

      _pending = _CallbackOperation(this, (message) async {
        if (message is T) {
          completer.complete(message);
        } else if (message is ErrorResponseMessage) {
          completer.completeError(
              PostgreSQLException.fromFields(message.fields), trace);
        } else if (message is ReadyForQueryMessage) {
          if (!completer.isCompleted) {
            completer.completeError(
                StateError('Operation did not complete'), trace);
          }

          syncComplete.complete();
        } else {
          completer.completeError(
              StateError('Unexpected message $message'), trace);
        }
      });

      return syncComplete.future
          .whenComplete(() => _pending = null)
          .then((value) => completer.future);
    });
  }

  /// Transação em andamento (iniciada por [runTx]), se houver.
  Completer<void>? _activeTransaction;

  /// Espera a transação em andamento terminar. Usado pelas operações feitas
  /// de fora da transação, para que não sejam executadas dentro dela.
  ///
  /// Sem transação, a operação começa já (sem esperar um evento): assim ela
  /// entra na fila antes de um [close] chamado logo depois. Antes ela
  /// falhava com "connection was closed" em vez de ser executada.
  Future<void>? _waitForTransaction() {
    if (_activeTransaction == null) return null;
    return Future.doWhile(() async {
      if (_activeTransaction == null) return false;
      await _activeTransaction!.future;
      return true;
    });
  }

  @override
  Future<PgStatement> prepare(Object query, {Duration? timeout}) async {
    final wait = _waitForTransaction();
    if (wait != null) await wait;
    return _prepare(query, timeout: timeout);
  }

  @override
  Future<PgResult> execute(Object query,
      {Object? parameters, Duration? timeout}) async {
    final wait = _waitForTransaction();
    if (wait != null) await wait;
    return _execute(query, parameters: parameters, timeout: timeout);
  }

  Future<PgStatement> _prepare(Object query, {Duration? timeout}) async {
    final name = 's/${_statementCounter++}';
    final description = InternalQueryDescription.wrap(query);

    await _sendAndWaitForQuery<ParseCompleteMessage>(ParseMessage(
        description.transformedSql,
        statementName: name,
        types: description.parameterTypes,
        encoding: _settings.endpoint.encoding));

    return _PreparedStatement(description, name, this);
  }

  Future<PgResult> _execute(Object query,
      {Object? parameters, Duration? timeout}) async {
    final description = InternalQueryDescription.wrap(query);
    final variables = description.bindParameters(parameters);

    if (variables.isNotEmpty) {
      // The simple query protocol does not support variables, so we have to
      // prepare a statement explicitly.
      final prepared = await _prepare(description, timeout: timeout);
      try {
        return await prepared.run(variables, timeout: timeout);
      } finally {
        await prepared.dispose();
      }
    } else {
      // Great, we can just run a simple query.
      final controller = StreamController<PgResultRow>();
      final items = <PgResultRow>[];

      final querySubscription = _PgResultStreamSubscription.simpleQuery(
        description.transformedSql,
        this,
        controller,
        controller.stream.listen(items.add),
      );
      await querySubscription.asFuture();
      await querySubscription.cancel();

      return PgResult(items, await querySubscription.affectedRows,
          await querySubscription.schema);
    }
  }

  @override
  Future<R> run<R>(Future<R> Function(PgSession session) fn,
      {PgRetryOptions? retryOptions}) {
    return _withRetry(retryOptions, () => fn(this));
  }

  @override
  Future<R> runTx<R>(Future<R> Function(PgSession session) fn,
      {PgRetryOptions? retryOptions}) {
    return _withRetry(retryOptions, () => _runTransaction(fn));
  }

  Future<R> _runTransaction<R>(Future<R> Function(PgSession session) fn) async {
    await _waitForTransaction();
    // Sem await entre a verificação acima e esta atribuição: nenhuma outra
    // transação pode começar no meio.
    final done = Completer<void>();
    _activeTransaction = done;
    final session = _TransactionSession(this);
    try {
      await _execute('BEGIN');
      try {
        final result = await fn(session);
        session._closed = true;
        await _execute('COMMIT');
        return result;
      } catch (_) {
        session._closed = true;
        try {
          await _execute('ROLLBACK');
        } catch (_) {
          // A conexão pode ter sido perdida; o erro original é o relevante.
        }
        rethrow;
      }
    } finally {
      _activeTransaction = null;
      done.complete();
    }
  }

  Future<R> _withRetry<R>(PgRetryOptions? options, Future<R> Function() body) =>
      options == null ? body() : options.retry(body);

  bool _isClosed = false;

  /// Se a conexão foi fechada (por [close] ou pelo servidor).
  bool get isClosed => _isClosed;

  @override
  Future<void> close() async {
    if (_closedByServer) {
      // O socket já foi encerrado: não há o que enviar.
      try {
        await Future.wait([_channel.sink.close(), _serverMessages.cancel()]);
      } catch (_) {}
      return;
    }
    await _operationLock.withResource(() {
      // Use lock to await earlier operations
      _isClosed = true;
      _channel.sink.add(const TerminateMessage());
    });

    await Future.wait([_channel.sink.close(), _serverMessages.cancel()]);
  }
}

/// Sessão entregue à função de [PgConnectionImplementation.runTx]: executa
/// diretamente na transação (sem esperar por ela) e não pode ser usada depois
/// que a transação termina.
class _TransactionSession implements PgSession {
  final PgConnectionImplementation _connection;
  bool _closed = false;

  _TransactionSession(this._connection);

  void _checkOpen() {
    if (_closed) {
      throw StateError('The transaction session can only be used inside '
          'the runTx callback.');
    }
  }

  @override
  Future<PgStatement> prepare(Object query, {Duration? timeout}) async {
    _checkOpen();
    return _connection._prepare(query, timeout: timeout);
  }

  @override
  Future<PgResult> execute(Object query,
      {Object? parameters, Duration? timeout}) async {
    _checkOpen();
    return _connection._execute(query,
        parameters: parameters, timeout: timeout);
  }

  @override
  Future<void> close() async {
    throw StateError('The transaction session is closed by runTx.');
  }
}

class _PreparedStatement extends PgStatement {
  final InternalQueryDescription _description;
  final String _name;
  final PgConnectionImplementation _connection;

  _PreparedStatement(this._description, this._name, this._connection);

  @override
  PgResultStream bind(Object? parameters) {
    return _BoundStatement(this, _description.bindParameters(parameters));
  }

  @override
  Future<void> dispose() async {
    await _connection._sendAndWaitForQuery<CloseCompleteMessage>(
        CloseMessage.statement(_connection._settings.encoding, _name));
  }
}

class _BoundStatement extends Stream<PgResultRow> implements PgResultStream {
  final _PreparedStatement statement;
  final List<PgTypedParameter> parameters;

  _BoundStatement(this.statement, this.parameters);

  @override
  PgResultStreamSubscription listen(void Function(PgResultRow event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    final controller = StreamController<PgResultRow>();

    // ignore: cancel_subscriptions
    final subscription = controller.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
    return _PgResultStreamSubscription(this, controller, subscription);
  }
}

class _PgResultStreamSubscription
    implements PgResultStreamSubscription, _PendingOperation {
  @override
  final PgConnectionImplementation connection;
  final StreamController<PgResultRow> _controller;
  final StreamSubscription<PgResultRow> _source;

  final Completer<int> _affectedRows = Completer();
  int _lastAffectedRows = 0;
  final Completer<PgResultSchema> _schema = Completer();
  final Completer<void> _done = Completer();
  PgResultSchema? _resultSchema;
  List<int> _columnTypeOids = const [];

  late final _portalName = 'p/${connection._portalCounter++}';

  _PgResultStreamSubscription(
      _BoundStatement statement, this._controller, this._source)
      : connection = statement.statement._connection {
    connection._operationLock.withResource(() async {
      if (connection._isClosed) return _failClosed();
      final List<ParameterValue> values;
      try {
        values = [
          for (final parameter in statement.parameters)
            ParameterValue.binary(parameter.value, parameter.type,
                connection._settings.encoding, connection._settings.timeZone)
        ];
      } catch (e, st) {
        // Valor que não pode ser codificado (por exemplo, uma String num
        // parâmetro int): antes o erro escapava sem tratamento e quem
        // esperava o resultado ficava esperando para sempre.
        _controller.addError(e, st);
        return handleMessage(
            ReadyForQueryMessage(Uint8List.fromList([0x49]), utf8));
      }
      connection._pending = this;

      connection._channel.sink.add(AggregatedClientMessage([
        BindMessage(
          values,
          portalName: _portalName,
          statementName: statement.statement._name,
          encoding: connection._settings.encoding,
        ),
        DescribeMessage.portal(
            portalName: _portalName, encoding: connection._settings.encoding),
        ExecuteMessage(connection._settings.encoding, _portalName),
        SyncMessage(),
      ]));

      await _done.future;
    });
  }

  _PgResultStreamSubscription.simpleQuery(
      String sql, this.connection, this._controller, this._source) {
    connection._operationLock.withResource(() async {
      if (connection._isClosed) return _failClosed();
      connection._pending = this;

      connection._channel.sink
          .add(QueryMessage(sql, connection._settings.encoding));
      await _done.future;
    });
  }

  Future<void> _failClosed() async {
    await handleMessage(PgConnectionImplementation._connectionClosedError());
    await handleMessage(ReadyForQueryMessage(Uint8List.fromList([0x49]), utf8));
  }

  @override
  Future<int> get affectedRows => _affectedRows.future;

  @override
  Future<PgResultSchema> get schema => _schema.future;

  @override
  Future<void> handleMessage(ServerMessage message) async {
    // Mensagens depois do fim (por exemplo, um erro FATAL não solicitado).
    if (_done.isCompleted) return;
    if (message is ErrorResponseMessage) {
      _controller.addError(
          PostgreSQLException.fromFields(message.fields), StackTrace.current);
    } else if (message is BindCompleteMessage) {
      // Nothing to do
    } else if (message is RowDescriptionMessage) {
      _columnTypeOids = [
        for (final field in message.fieldDescriptions) field.typeId
      ];
      final schema = _resultSchema = PgResultSchema([
        for (final field in message.fieldDescriptions)
          PgResultColumn(
            type: PgDataType.byTypeOid[field.typeId] ?? PgDataType.byteArray,
            tableName: field.tableName,
            columnName: field.columnName,
            columnOid: field.columnID,
            tableOid: field.tableID,
            binaryEncoding: field.formatCode != 0,
          ),
      ]);
      // Vários comandos numa consulta simples: cada linha leva o esquema do
      // próprio comando; [schema] é o do primeiro. Antes o segundo
      // RowDescription (ou CommandComplete) lançava "Future already
      // completed" sem tratamento.
      if (!_schema.isCompleted) _schema.complete(schema);
    } else if (message is DataRowMessage) {
      final schema = _resultSchema!;

      final columnValues = <Object?>[];
      try {
        for (var i = 0; i < message.values.length; i++) {
          final field = schema.columns[i];
          final type = field.type;
          if (field.binaryEncoding) {
            final settings = connection._settings;
            final typeOid = _columnTypeOids[i];
            // Mesmo OID usado antes por type.binaryCodec, exceto para os
            // tipos tratados diretamente pelo OID (time, timetz, inet, cidr
            // e arrays), que antes eram lidos como bytea.
            final decoderOid = PostgresBinaryDecoder.decodesByOid(typeOid)
                ? typeOid
                : (type.oid ?? PgDataType.integer.oid!);
            columnValues.add(PostgresBinaryDecoder<Object>(
                    decoderOid, settings.encoding, settings.timeZone,
                    decoding: settings.decoding)
                .convert(message.values[i]));
          } else if (PostgresTextDecoder.supports(type)) {
            columnValues.add(type
                .textCodec(connection._settings.encoding)
                .decode(message.values[i]));
          } else {
            // Consultas sem parâmetros usam o protocolo simples (formato
            // texto): date, timestamptz, numeric, uuid, json... chegam
            // como a String do PostgreSQL (antes a consulta falhava com
            // UnimplementedError).
            final value = message.values[i];
            columnValues.add(value == null
                ? null
                : connection._settings.encoding.decode(value));
          }
        }
      } catch (e, st) {
        // Uma falha de decodificação afeta só esta consulta: o erro é
        // entregue ao consumidor e as próximas mensagens continuam sendo
        // processadas normalmente até o ReadyForQuery.
        _controller.addError(e, st);
        return;
      }

      final row = _ResultRow(schema, columnValues);
      _controller.add(row);
    } else if (message is CommandCompleteMessage) {
      // Com vários comandos, vale o último (como no protocolo v2).
      _lastAffectedRows = message.rowsAffected;
    } else if (message is ReadyForQueryMessage) {
      _done.complete();
      if (identical(connection._pending, this)) connection._pending = null;

      // Make sure the affectedRows and schema futures complete with something
      // after the query is done, even if we didn't get a row description
      // message.
      if (!_affectedRows.isCompleted) {
        _affectedRows.complete(_lastAffectedRows);
      }
      if (!_schema.isCompleted) {
        _schema.complete(PgResultSchema(const []));
      }
      await _controller.close();
    }
  }

  // Forwarding subscription interface to regular stream subscription from
  // controller

  @override
  Future<E> asFuture<E>([E? futureValue]) => _source.asFuture(futureValue);

  @override
  Future<void> cancel() => _source.cancel();

  @override
  bool get isPaused => _source.isPaused;

  @override
  void onData(void Function(PgResultRow data)? handleData) {
    _source.onData(handleData);
  }

  @override
  void onDone(void Function()? handleDone) {
    _source.onDone(handleDone);
  }

  @override
  void onError(Function? handleError) {
    _source.onError(handleError);
  }

  @override
  void pause([Future<void>? resumeSignal]) {
    _source.pause(resumeSignal);
  }

  @override
  void resume() {
    _source.resume();
  }
}

class _Channels implements PgChannels {
  final PgConnectionImplementation _connection;

  final Map<String, List<MultiStreamController<String>>> _activeListeners = {};

  // We are using the pg_notify function in a prepared select statement to
  // efficiently implement [notify].
  Completer<PgStatement>? _notifyStatement;

  _Channels(this._connection);

  @override
  Stream<String> operator [](String channel) {
    return Stream.multi(
      (newListener) {
        newListener.onCancel = () => _unsubscribe(channel, newListener);

        final existingListeners =
            _activeListeners.putIfAbsent(channel, () => []);
        final needsSubscription = existingListeners.isEmpty;
        existingListeners.add(newListener);

        if (needsSubscription) {
          _subscribe(channel, newListener);
        }
      },
      isBroadcast: true,
    );
  }

  void _subscribe(String channel, MultiStreamController firstListener) {
    Future(() async {
      await _connection.execute(PgSql('LISTEN ${identifier(channel)}'));
    }).onError<Object>((error, stackTrace) {
      _activeListeners[channel]?.remove(firstListener);

      firstListener
        ..addError(error, stackTrace)
        ..close();
    });
  }

  Future<void> _unsubscribe(
      String channel, MultiStreamController listener) async {
    final listeners = _activeListeners[channel]!..remove(listener);

    if (listeners.isEmpty) {
      _activeListeners.remove(channel);

      // Send unlisten command
      await _connection.execute(PgSql('UNLISTEN ${identifier(channel)}'));
    }
  }

  void deliverNotification(NotificationResponseMessage msg) {
    final listeners = _activeListeners[msg.channel] ?? const [];

    for (final listener in listeners) {
      listener.add(msg.payload);
    }
  }

  @override
  Future<void> cancelAll() async {
    await _connection.execute(PgSql('UNLISTEN *'));

    for (final entry in _activeListeners.values) {
      for (final listener in entry) {
        await listener.close();
      }
    }
  }

  @override
  Future<void> notify(String channel, [String? payload]) async {
    final statementCompleter = _notifyStatement ??= Completer()
      ..complete(Future(() async {
        return _connection.prepare(PgSql(r'SELECT pg_notify($1, $2)',
            types: [PgDataType.text, PgDataType.text]));
      }));
    final statement = await statementCompleter.future;

    await statement.run([channel, payload]);
  }
}

abstract class _PendingOperation {
  final PgConnectionImplementation connection;

  _PendingOperation(this.connection);

  Future<void> handleMessage(ServerMessage message);
}

class _ResultRow extends UnmodifiableListView<Object?> implements PgResultRow {
  @override
  final PgResultSchema schema;

  _ResultRow(this.schema, super.source);
}

class _CallbackOperation extends _PendingOperation {
  final Future<void> Function(ServerMessage message) handle;

  _CallbackOperation(super.connection, this.handle);

  @override
  Future<void> handleMessage(ServerMessage message) => handle(message);
}

class _AuthenticationProcedure extends _PendingOperation {
  final Completer<void> _done = Completer();

  late PostgresAuthenticator _authenticator;

  _AuthenticationProcedure(super.connection);

  void _initializeAuthenticate(
      AuthenticationMessage message, AuthenticationScheme scheme) {
    final authConnection = PostgresAuthConnection(
      connection._settings.username,
      connection._settings.password,
      connection._channel.sink.add,
    );

    _authenticator = createAuthenticator(
        authConnection, scheme, connection._settings.encoding)
      ..onMessage(message);
  }

  @override
  Future<void> handleMessage(ServerMessage message) async {
    if (_done.isCompleted) return;
    if (message is ErrorResponseMessage) {
      _done.completeError(PostgreSQLException.fromFields(message.fields));
    } else if (message is AuthenticationMessage) {
      switch (message.type) {
        case AuthenticationMessage.KindOK:
          break;
        case AuthenticationMessage.KindMD5Password:
          _initializeAuthenticate(message, AuthenticationScheme.md5);
          break;
        case AuthenticationMessage.KindClearTextPassword:
          if (!connection._settings.endpoint.allowCleartextPassword) {
            _done.completeError(
              PostgreSQLException(
                  'Refused to send clear text password to server',
                  stackTrace: StackTrace.current),
              StackTrace.current,
            );
            return;
          }

          _initializeAuthenticate(message, AuthenticationScheme.clear);
          break;
        case AuthenticationMessage.KindSASL:
          _initializeAuthenticate(message, AuthenticationScheme.scramSha256);
          break;
        case AuthenticationMessage.KindSASLContinue:
        case AuthenticationMessage.KindSASLFinal:
          _authenticator.onMessage(message);
          break;
        default:
          _done.completeError(PostgreSQLException('Unhandled auth mechanism'));
      }
    } else if (message is ReadyForQueryMessage) {
      _done.complete();
    }
  }
}
