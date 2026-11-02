export 'gamepad_trigger_source_stub.dart'
    if (dart.library.io) 'gamepad_trigger_source_io.dart'
    if (dart.library.js_interop) 'gamepad_trigger_source_web.dart';
