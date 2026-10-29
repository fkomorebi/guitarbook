import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

Future<String> saveRecording(Uint8List wav) async {
  final blob = web.Blob(
    [wav.toJS].toJS,
    web.BlobPropertyBag(type: 'audio/wav'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = 'jam-${DateTime.now().millisecondsSinceEpoch}.wav';
  web.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  Future<void>.delayed(
    const Duration(seconds: 30),
    () => web.URL.revokeObjectURL(url),
  );
  return '已交给浏览器下载，请查看下载记录。';
}
