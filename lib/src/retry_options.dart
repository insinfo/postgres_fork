import 'connection.dart';

/// Opções de nova tentativa (`run`/`runTx` da API v3 e de
/// `PostgreSQLPool`).
class PgRetryOptions {
  /// Número máximo de execuções (incluindo a primeira).
  final int maxAttempts;

  /// Espera antes da segunda execução.
  final Duration delay;

  /// Fator de multiplicação da espera a cada nova tentativa.
  final double backoffFactor;

  /// Espera máxima entre tentativas.
  final Duration maxDelay;

  /// Decide se um erro deve provocar nova tentativa. Por padrão,
  /// [defaultRetryIf].
  final bool Function(Object error)? retryIf;

  const PgRetryOptions({
    this.maxAttempts = 3,
    this.delay = const Duration(milliseconds: 100),
    this.backoffFactor = 2,
    this.maxDelay = const Duration(seconds: 5),
    this.retryIf,
  });

  /// Repete em falha de serialização (SQLSTATE 40001) e deadlock (40P01).
  static bool defaultRetryIf(Object error) =>
      error is PostgreSQLException &&
      (error.code == '40001' || error.code == '40P01');

  /// Executa [body], repetindo conforme estas opções.
  Future<R> retry<R>(Future<R> Function() body) async {
    var attempt = 1;
    var wait = delay;
    final accept = retryIf ?? defaultRetryIf;
    while (true) {
      try {
        return await body();
      } catch (e) {
        if (attempt >= maxAttempts || !accept(e)) rethrow;
      }
      attempt++;
      await Future<void>.delayed(wait);
      final next = wait * backoffFactor;
      wait = next > maxDelay ? maxDelay : next;
    }
  }
}
