import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres_fork/src/decoding_settings.dart';
import 'package:postgres_fork/src/timezone_settings.dart';

import 'src/retry_options.dart';
import 'src/utils/delegating_list.dart';
import 'src/utils/stream_channel.dart';
import 'src/v3/connection.dart';
import 'src/v3/pool.dart';
import 'src/v3/protocol.dart';
import 'src/v3/query_description.dart';
import 'src/v3/types.dart';

export 'src/retry_options.dart';
// Tipos usados por [PgSessionSettings.transformer]. Antes vinham dos pacotes
// `stream_channel` e `async`; agora são implementados pelo próprio pacote.
export 'src/utils/stream_channel.dart'
    show
        StreamChannel,
        StreamChannelMixin,
        StreamChannelTransformer,
        StreamSinkTransformer,
        StreamSinkTransformExtension;
export 'src/v3/types.dart';

abstract class PgPool implements PgSession, PgSessionExecutor {
  static Future<PgPool> open(
    List<PgEndpoint> endpoints, {
    PgSessionSettings? sessionSettings,
    PgPoolSettings? poolSettings,
  }) =>
      PgPoolImplementation.open(endpoints,
          sessionSettings: sessionSettings, poolSettings: poolSettings);

  Future<R> withConnection<R>(
    Future<R> Function(PgConnection connection) fn, {
    PgSessionSettings? sessionSettings,
  });
}

class PgSql {
  factory PgSql(String sql, {List<PgDataType>? types}) =
      InternalQueryDescription.direct;
  factory PgSql.map(String sql, {String substitution}) =
      InternalQueryDescription.map;
}

abstract class PgSession {
  // uses extended query protocol
  Future<PgStatement> prepare(
    Object /* String | PgSql */ query, {
    Duration? timeout,
  });

  Future<PgResult> execute(
    Object /* String | PgSql */ query, {
    Object? /* List<Object?|PgTypedParameter> | Map<String, Object?|PgTypedParameter> */ parameters,
    Duration? timeout,
  });

  Future<void> close();
}

abstract class PgSessionExecutor {
  /// Executa [fn] com uma sessão.
  ///
  /// Com [retryOptions], [fn] é executada de novo quando falha com um erro
  /// aceito por [PgRetryOptions.retryIf].
  Future<R> run<R>(Future<R> Function(PgSession session) fn,
      {PgRetryOptions? retryOptions});

  /// Executa [fn] numa transação: `BEGIN`, a função e `COMMIT`; se a função
  /// lançar um erro, `ROLLBACK` e o erro é relançado.
  ///
  /// Na mesma conexão, operações feitas fora de [fn] esperam a transação
  /// terminar. Com [retryOptions], a transação inteira é repetida quando
  /// falha com um erro aceito por [PgRetryOptions.retryIf] (por padrão,
  /// falha de serialização e deadlock).
  Future<R> runTx<R>(Future<R> Function(PgSession session) fn,
      {PgRetryOptions? retryOptions});
}

abstract class PgConnection implements PgSession, PgSessionExecutor {
  static Future<PgConnection> open(
    PgEndpoint endpoint, {
    PgSessionSettings? sessionSettings,
  }) {
    return PgConnectionImplementation.connect(endpoint,
        sessionSettings: sessionSettings);
  }

  PgChannels get channels;
}

abstract class PgResultStream implements Stream<PgResultRow> {
  @override
  PgResultStreamSubscription listen(void Function(PgResultRow event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError});
}

abstract class PgResultStreamSubscription
    implements StreamSubscription<PgResultRow> {
  Future<int> get affectedRows;
  Future<PgResultSchema> get schema;
}

abstract class PgStatement {
  PgResultStream bind(
      Object? /* List<Object?|PgTypedParameter> | Map<String, Object?|PgTypedParameter> */ parameters);

  Future<PgResult> run(
    Object? /* List<Object?|PgTypedParameter> | Map<String, Object?|PgTypedParameter> */ parameters, {
    Duration? timeout,
  }) async {
    final items = <PgResultRow>[];
    final subscription = bind(parameters).listen(items.add);
    await subscription.asFuture();
    await subscription.cancel();

    return PgResult(
        items, await subscription.affectedRows, await subscription.schema);
  }

  Future<void> dispose();
}

class PgTypedParameter {
  final PgDataType type;
  final Object? value;

  PgTypedParameter(this.type, this.value);
}

abstract class PgResult implements List<PgResultRow> {
  int get affectedRows;
  PgResultSchema get schema;

  factory PgResult(
          List<PgResultRow> rows, int affectedRows, PgResultSchema schema) =
      _PgResult;
}

class _PgResult extends DelegatingList<PgResultRow> implements PgResult {
  @override
  final int affectedRows;

  @override
  final PgResultSchema schema;

  final List<PgResultRow> rows;

  _PgResult(this.rows, this.affectedRows, this.schema) : super(rows);

  @override
  String toString() {
    return 'PgResult(schema = $schema, affectedRows = $affectedRows, rows = $rows)';
  }
}

abstract class PgResultRow implements List<Object?> {
  PgResultSchema get schema;
}

class PgResultSchema {
  final List<PgResultColumn> columns;

  PgResultSchema(this.columns);

  @override
  String toString() {
    return 'PgResultSchema(${columns.join(', ')})';
  }
}

class PgResultColumn {
  final PgDataType type;
  final String? tableName;
  final int? tableOid;
  final String? columnName;
  final int? columnOid;
  final bool binaryEncoding;

  PgResultColumn({
    required this.type,
    this.tableName,
    this.tableOid,
    this.columnName,
    this.columnOid,
    this.binaryEncoding = false,
  });

  @override
  String toString() {
    final buffer = StringBuffer('${type.name} ');
    if (tableName != null && tableName != '') {
      buffer
        ..write(tableName)
        ..write('.');
    } else if (tableOid != null && tableOid != 0) {
      buffer
        ..write('@$tableOid')
        ..write('.');
    }

    if (columnName != null && columnName != '') {
      buffer.write(columnName);
    } else if (columnOid != null && columnOid != 0) {
      buffer.write('@$columnOid');
    }

    return buffer.toString();
  }
}

abstract class PgChannels {
  Stream<String> operator [](String channel);
  Future<void> notify(String channel, [String? payload]);
  Future<void> cancelAll();
}

abstract class PgNotification {}

class PgEndpoint {
  final String host;
  final int port;
  final String database;
  final String? username;
  final String? password;
  final bool requireSsl;
  final bool isUnixSocket;
  final Encoding encoding;
  late TimeZoneSettings timeZone;

  /// Whether the client should send the password to the server in clear-text
  /// for authentication.
  ///
  /// For security reasons, it is recommended to keep this disabled.
  final bool allowCleartextPassword;
  /// [timeZone] = default = TimeZoneSettings('UTC') | String 'UTC'
  PgEndpoint({
    required this.host,
    this.port = 5432,
    required this.database,
    this.username,
    this.password,
    this.requireSsl = false,
    this.isUnixSocket = false,
    this.allowCleartextPassword = false,
    this.encoding = utf8,
    Object timeZone = 'UTC',
  }){
    if (timeZone is String) {
      this.timeZone = TimeZoneSettings(timeZone);
    } else if (timeZone is TimeZoneSettings) {
      this.timeZone = timeZone;
    }
  }
}

class PgSessionSettings {
  // Duration(seconds: 15)
  final Duration? connectTimeout;
  // Duration(minutes: 5)
  final Duration? queryTimeout;
  /// TimeZoneSettings | String
  final TimeZoneSettings? timeZone;
  final Encoding? encoding;
  final bool Function(X509Certificate)? onBadSslCertificate;

  /// An optional [StreamChannelTransformer] sitting behind the postgres client
  /// as implemented in the `posgres` package and the database server.
  ///
  /// The stream channel transformer is able to view, alter, drop, or inject
  /// messages in either direction. This powerful tool can be used to implement
  /// additional or custom functionality, but should also be used with caution
  /// as altering the message flow might break internal invariants of this
  /// package.
  ///
  /// For an example, see `example/v3/transformer.dart`.
  final StreamChannelTransformer<BaseMessage, BaseMessage>? transformer;

  /// How some types (interval, time, timetz, inet and cidr) are decoded.
  final DecodingSettings? decodingSettings;

  /// The `application_name` sent in the startup message, if any.
  final String? applicationName;

  /// Additional session parameters sent in the startup message (for example
  /// `search_path` or `statement_timeout`), avoiding `SET` commands.
  final Map<String, String>? startupParameters;

  PgSessionSettings({
    this.connectTimeout,
    this.queryTimeout,
    this.timeZone,
    this.encoding,
    this.onBadSslCertificate,
    this.transformer,
    this.decodingSettings,
    this.applicationName,
    this.startupParameters,
  });
}

/// Configuração de [PgPool] (campos nulos = sem limite, exceto
/// [maxConnectionCount], cujo padrão é 10).
class PgPoolSettings {
  /// Número máximo de conexões abertas ao mesmo tempo (padrão: 10).
  final int? maxConnectionCount;

  /// Uma conexão ociosa por mais tempo que isso é testada (`SELECT 1`) antes
  /// de ser usada.
  final Duration? idleTestThreshold;

  /// Conexões abertas há mais tempo que isso não são reutilizadas.
  final Duration? maxConnectionAge;

  /// Conexões usadas por mais tempo que isso (somando as sessões) não são
  /// reutilizadas.
  final Duration? maxSessionUse;

  /// Conexões cujas sessões falharam esse número de vezes não são
  /// reutilizadas.
  final int? maxErrorCount;

  /// Conexões usadas por esse número de sessões (`run`, `runTx`, `execute`
  /// ou `withConnection` do pool) não são reutilizadas.
  final int? maxQueryCount;

  PgPoolSettings({
    this.maxConnectionCount,
    this.idleTestThreshold,
    this.maxConnectionAge,
    this.maxSessionUse,
    this.maxErrorCount,
    this.maxQueryCount,
  });
}
