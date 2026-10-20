// Estado global de fuso horário (localização UTC e localização "local").
//
// Copyright (c) 2015, the timezone project authors.
// Copyright (c) 2024, pg_timezone project authors.
// All rights reserved. Use of this source code is governed by a BSD-style
// license (ver lib/src/timezone/LICENSE).

import 'location.dart';

// ignore: non_constant_identifier_names
final _UTC = Location('UTC', [minTime], [0], [TimeZone.UTC]);

Location _local = _UTC;

/// [Location] UTC.
// ignore: non_constant_identifier_names
Location get UTC => _UTC;

/// [Location] local, usada por [TZDateTime.local] e `toLocal()`.
///
/// Por padrão é UTC. O decodificador de `timestamptz` a define para a
/// localização do fuso da conexão (mesmo comportamento do `pg_timezone`).
Location get local => _local;

/// Define a [Location] local.
void setLocalLocation(Location location) {
  _local = location;
}
