/// How values of type `interval` are decoded.
enum IntervalDecoding {
  /// Decodes as [Duration] (default, same behavior as previous versions).
  ///
  /// Intervals with months or days cannot be represented as a [Duration]
  /// (a month has no fixed length and a day may have 23 or 25 hours); for
  /// those values an [UnimplementedError] is thrown, the query fails and the
  /// connection remains usable. Use [pgInterval] to read them.
  duration,

  /// Decodes every interval as a `PgInterval` (months, days and
  /// microseconds), without losing information.
  pgInterval,
}

/// How values of the types `time`, `timetz`, `inet` and `cidr` (and arrays
/// of them) are decoded.
enum ExtendedTypeDecoding {
  /// Decodes as `PgTime`, `PgTimeTz` and `PgInet` (default).
  objects,

  /// Decodes as a [String] in the same format PostgreSQL uses for text
  /// output (for example `13:45:10.5`, `13:45:10.5-03`, `192.168.1.10/24`).
  text,

  /// Returns the raw bytes of the binary representation (`Uint8List`), as
  /// previous versions did for these types.
  bytes,
}

/// How values of the types `timestamp` (without time zone) and `date` are
/// decoded.
enum TimestampDecoding {
  /// Follows [TimeZoneSettings.forceDecodeTimestampAsUTC] and
  /// [TimeZoneSettings.forceDecodeDateAsUTC] (default, unchanged behavior).
  timeZoneSettings,

  /// Decodes as a local [DateTime] (`isUtc == false`) with exactly the same
  /// date and time fields stored in the database (the "wall clock" value).
  /// Useful when `timestamp` columns store the local time of the application
  /// and the application runs in that same time zone.
  localWallClock,
}

/// How values of type `numeric` (and `numeric[]`) are decoded.
enum NumericDecoding {
  /// Decodes as a [String] with the exact value (default, same behavior as
  /// previous versions), e.g. `'1234.50'`, `'NaN'`, `'Infinity'`.
  string,

  /// Decodes as a `PgDecimal` (arbitrary precision, keeps the scale).
  decimal,
}

/// Options for decoding values received from the server.
class DecodingSettings {
  /// How values of type `interval` are decoded.
  final IntervalDecoding interval;

  /// How values of the types `time`, `timetz`, `inet` and `cidr` are
  /// decoded.
  final ExtendedTypeDecoding extendedTypes;

  /// How values of the types `timestamp` and `date` are decoded.
  final TimestampDecoding timestamp;

  /// How values of type `numeric` are decoded.
  final NumericDecoding numeric;

  const DecodingSettings({
    this.interval = IntervalDecoding.duration,
    this.extendedTypes = ExtendedTypeDecoding.objects,
    this.timestamp = TimestampDecoding.timeZoneSettings,
    this.numeric = NumericDecoding.string,
  });
}
