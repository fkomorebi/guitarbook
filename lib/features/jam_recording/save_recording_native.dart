import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

Future<String> saveRecording(Uint8List wav) async {
  final directory = await getApplicationDocumentsDirectory();
  final recordings = Directory('${directory.path}/Guitarbook Recordings');
  await recordings.create(recursive: true);
  final file = File(
    '${recordings.path}/jam-${DateTime.now().microsecondsSinceEpoch}.wav',
  );
  await file.writeAsBytes(wav, flush: true);
  return file.path;
}
