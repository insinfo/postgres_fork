/// Tipos de fuso horário usados pelo driver.
///
/// Valores `timestamptz` decodificados com um [TimeZoneSettings] diferente de
/// UTC (e sem `forceDecodeTimestamptzAsUTC`) são devolvidos como [TZDateTime].
/// Antes estes tipos vinham do pacote `pg_timezone`.
library postgres_fork.timezone;

import 'src/timezone_settings.dart';

export 'src/timezone/database.dart' show LocationNotFoundException;
export 'src/timezone/date_time.dart' show TZDateTime;
export 'src/timezone/location.dart' show Location, TimeZone, TzInstant;
export 'src/timezone/tz_data.dart' show tzdbVersion;
