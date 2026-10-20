// Atualiza o banco de fusos horários embutido no driver
// (lib/src/timezone/tz_data.dart) a partir do banco da IANA
// (https://www.iana.org/time-zones).
//
// Baixa o tzdata, compila os fontes com o port Dart do zic
// (scripts/tzdb/zic.dart, sem depender de ferramentas nativas) e gera:
//
//  - o banco completo (padrão do driver): todas as zonas e links, com todo o
//    histórico e transições explícitas até --horizon;
//  - o banco reduzido (o mesmo do antigo pacote pg_timezone): as localizações
//    de scripts/tzdb/common_locations.dart, com transições numa janela de
//    5 anos antes e 5 anos depois de --reference-year.
//
// Uso (na raiz do projeto):
//
//   dart run scripts/update_tzdb.dart                    # versão mais recente
//   dart run scripts/update_tzdb.dart --version 2026e    # versão específica
//   dart run scripts/update_tzdb.dart --source tzdata2026e.tar.gz
//   dart run scripts/update_tzdb.dart --source caminho/do/tzdata/extraido
//
// Opções:
//   --version <v>         versão do tzdata (padrão: latest)
//   --source <arquivo|dir> usa um tzdata local (.tar.gz ou diretório)
//   --reference-year <a>  ano de referência do banco reduzido (padrão: atual)
//   --horizon <a>         gera transições explícitas até 1º de janeiro deste
//                         ano no banco completo (padrão: 2100)
//   --zoneinfo-out <dir>  também grava os arquivos TZif gerados (como zic -d)
//   --output <arquivo>    arquivo Dart gerado
//                         (padrão: lib/src/timezone/tz_data.dart)

import 'dart:io';
import 'dart:typed_data';

import 'tzdb/generate.dart';
import 'tzdb/tar.dart';
import 'tzdb/tz_data_writer.dart';

const _releasesUrl = 'https://data.iana.org/time-zones/releases';
const _latestUrl = 'https://data.iana.org/time-zones/tzdata-latest.tar.gz';

Future<void> main(List<String> args) async {
  var version = 'latest';
  String? source;
  var referenceYear = DateTime.now().year;
  var horizon = 2100;
  String? zoneinfoOut;
  var output = 'lib/src/timezone/tz_data.dart';

  for (var i = 0; i < args.length; i++) {
    String next() {
      if (i + 1 >= args.length) _usage('faltou o valor de ${args[i]}');
      return args[++i];
    }

    switch (args[i]) {
      case '--version':
        version = next();
        break;
      case '--source':
        source = next();
        break;
      case '--reference-year':
        referenceYear = int.parse(next());
        break;
      case '--horizon':
        horizon = int.parse(next());
        break;
      case '--zoneinfo-out':
        zoneinfoOut = next();
        break;
      case '--output':
        output = next();
        break;
      case '-h':
      case '--help':
        _usage();
      default:
        _usage('opção desconhecida: ${args[i]}');
    }
  }

  final files = await _loadSources(source, version);
  stdout.writeln('Compilando os fontes com o zic...');
  final build =
      buildTzdb(files, referenceYear: referenceYear, horizonYear: horizon);

  if (zoneinfoOut != null) {
    for (final entry in build.tzif.entries) {
      final file = File('$zoneinfoOut/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(entry.value);
    }
    stdout.writeln('Arquivos TZif gravados em $zoneinfoOut.');
  }

  writeTzDataFile(
    output,
    version: build.version,
    fullDescription: 'tzdata ${build.version}: ${build.full.length} '
        'localizações (zonas e links), histórico completo, transições '
        'explícitas até $horizon.',
    full: build.full,
    reducedDescription: 'tzdata ${build.version}: ${build.reduced.length} '
        'localizações comuns, transições de ${referenceYear - 5}-01-01 a '
        '${referenceYear + 5}-01-01 (UTC).',
    reduced: build.reduced,
  );
  stdout.writeln('tzdata ${build.version}: ${build.full.length} localizações '
      'no banco completo, ${build.reduced.length} no reduzido. '
      'Gerado $output.');
}

Future<Map<String, Uint8List>> _loadSources(
    String? source, String version) async {
  if (source != null) {
    final type = FileSystemEntity.typeSync(source);
    if (type == FileSystemEntityType.directory) {
      stdout.writeln('Lendo o tzdata de $source...');
      return {
        for (final f in Directory(source).listSync().whereType<File>())
          f.uri.pathSegments.last: f.readAsBytesSync()
      };
    }
    if (type == FileSystemEntityType.file) {
      stdout.writeln('Lendo o tzdata de $source...');
      return readTarArchive(File(source).readAsBytesSync());
    }
    _usage('fonte não encontrada: $source');
  }
  final url = version == 'latest'
      ? _latestUrl
      : '$_releasesUrl/tzdata$version.tar.gz';
  stdout.writeln('Baixando $url...');
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode} ao baixar $url');
    }
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);
    return readTarArchive(builder.toBytes());
  } finally {
    client.close();
  }
}

Never _usage([String? error]) {
  if (error != null) stderr.writeln('erro: $error\n');
  stderr.writeln('uso: dart run scripts/update_tzdb.dart [--version <v>] '
      '[--source <arquivo.tar.gz|diretório>] [--reference-year <ano>] '
      '[--horizon <ano>] [--zoneinfo-out <dir>] [--output <arquivo>]');
  exit(error == null ? 0 : 64);
}
