/// Which embedded time zone database is used to decode `timestamptz` values
/// when [TimeZoneSettings.forceDecodeTimestamptzAsUTC] is false.
enum TimeZoneDatabaseVariant {
  /// All IANA zones and links, with the complete history of offset and
  /// daylight saving time changes (default). Recommended: converts past
  /// and future dates with the rules that apply to them, like PostgreSQL.
  full,

  /// The smaller database used by the former `pg_timezone` package: the most
  /// common locations only, with transitions restricted to 5 years before and
  /// after the generation date. Dates outside that window use the offset in
  /// force at its edges, and names outside the list are not found.
  reduced,
}

/// A class to configure time zone settings for decoding timestamps and dates.
class TimeZoneSettings {
  /// The default time zone value.
  ///
  /// The [value] represents the name of the time zone location. Default is 'UTC'.
  String value = 'UTC';

  /// Creates a new instance of [TimeZoneSettings].
  ///
  /// [value] is the name of the time zone location.
  ///
  /// The optional named parameters:
  /// - [forceDecodeTimestamptzAsUTC]: if true, decodes timestamps with timezone (timestamptz) as UTC. If false, decodes them using the timezone defined in the connection.
  /// - [forceDecodeTimestampAsUTC]: if true, decodes timestamps without timezone (timestamp) as UTC. If false, decodes them as local datetime.
  /// - [forceDecodeDateAsUTC]: if true, decodes dates as UTC. If false, decodes them as local datetime.
  /// - [databaseVariant]: the time zone database used for timestamptz
  ///   values (see [TimeZoneDatabaseVariant]); defaults to the full database.
  TimeZoneSettings(
    this.value, {
    this.forceDecodeTimestamptzAsUTC = true,
    this.forceDecodeTimestampAsUTC = true,
    this.forceDecodeDateAsUTC = true,
    this.databaseVariant = TimeZoneDatabaseVariant.full,
  });

  /// The time zone database used to decode timestamptz values when
  /// [forceDecodeTimestamptzAsUTC] is false.
  TimeZoneDatabaseVariant databaseVariant = TimeZoneDatabaseVariant.full;

  /// If true, decodes the timestamp with timezone (timestamptz) as UTC.
  /// If false, decodes the timestamp with timezone using the timezone defined in the connection.
  bool forceDecodeTimestamptzAsUTC = true;

  /// If true, decodes the timestamp without timezone (timestamp) as UTC.
  /// If false, decodes the timestamp without timezone as local datetime.
  bool forceDecodeTimestampAsUTC = true;

  /// If true, decodes the date as UTC.
  /// If false, decodes the date as local datetime.
  bool forceDecodeDateAsUTC = true;

  /// ignore past timestamp transitions and use only current timestamp in local datetime for Timestamp and Date If
  /// forceDecodeTimestampAsUTC and forceDecodeDateAsUTC is false
  //bool ignorePastTimestampUseCurrent = true;
}
