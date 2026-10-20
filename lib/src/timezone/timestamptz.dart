import '../timezone_settings.dart';
import 'database.dart';
import 'date_time.dart';
import 'env.dart' as tzenv;

/// Converte um `timestamptz` já decodificado como instante UTC ([datetime])
/// para o fuso da conexão ([timeZone]).
///
/// A localização é procurada pelo nome ou pela abreviação atual (ignorando
/// maiúsculas/minúsculas) no banco escolhido em
/// [TimeZoneSettings.databaseVariant]. O resultado é um [TZDateTime] que
/// representa o mesmo instante, com os campos locais calculados pelo
/// deslocamento em vigor naquela data. [database] permite usar outro banco
/// (testes).
DateTime convertTimestamptz(DateTime datetime, TimeZoneSettings timeZone,
    {TimeZoneDatabase? database}) {
  if (timeZone.forceDecodeTimestamptzAsUTC) {
    return datetime;
  }
  if (timeZone.value.toLowerCase() == 'utc') {
    return datetime;
  }

  final pgTimeZone = timeZone.value.toLowerCase();
  final tzLocation =
      (database ?? timeZoneDatabaseFor(timeZone.databaseVariant))
          .find(pgTimeZone);

  if (tzLocation == null) {
    throw LocationNotFoundException(
        'Location with the name "$pgTimeZone" doesn\'t exist');
  }
  // Define a localização "local" (usada por TZDateTime.local e
  // TZDateTime.toLocal()) como a do último valor decodificado, como fazia o
  // pg_timezone; o código que usa toLocal() depende disso. Como o estado é
  // global ao isolate, conexões com fusos diferentes no mesmo isolate fazem
  // toLocal() seguir a última decodificação: nesse caso, prefira
  // TZDateTime.from(valor, localizacao) com a localização desejada.
  tzenv.setLocalLocation(tzLocation);

  // Preserva o instante e calcula os campos locais com o deslocamento em
  // vigor naquele instante (incluindo o horário de verão da época).
  return TZDateTime.from(datetime, tzLocation);
}
