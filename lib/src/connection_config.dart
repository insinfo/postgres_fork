/// Tipos de configuração de conexão, reunidos num único lugar.
///
/// [ReplicationMode] é definido aqui; [TimeZoneSettings] e
/// [DecodingSettings] continuam em seus arquivos (para não mudar os caminhos
/// de import existentes) e são reexportados.
library;

export 'decoding_settings.dart';
export 'timezone_settings.dart';

/// SSL/TLS usage when connecting.
enum PgSslMode {
  /// Never uses SSL.
  disable,

  /// Uses SSL when the server supports it; otherwise continues without it.
  /// The server certificate is not verified.
  prefer,

  /// Requires SSL; the server certificate is not verified (same as the
  /// `useSSL: true` connection option).
  require,

  /// Requires SSL and verifies the server certificate and host name.
  verifyFull,
}

/// Streaming Replication Protocol Options
///
/// [physical] or [logical] are used to start the connection a streaming
/// replication mode.
///
/// See [Protocol Replication][] for more details.
///
/// [Protocol Replication]: https://www.postgresql.org/docs/current/protocol-replication.html
enum ReplicationMode {
  physical('true'),
  logical('database'),
  none('false');

  final String value;

  const ReplicationMode(this.value);
}
