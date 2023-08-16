import 'package:docker_process/docker_process.dart';

Future main() async {  
  final dp = await DockerProcess.start(
    image: 'image-name',
    name: 'custom_postgres',
    readySignal: (line) => line.contains('Done.'),
  );
  final pr = await dp.exec(<String>['ls', '-l']);
  print(pr.stdout);
  await dp.stop();
}