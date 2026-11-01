export 'effects_backend_stub.dart'
    if (dart.library.io) 'effects_backend_native.dart'
    if (dart.library.js_interop) 'effects_backend_web.dart';
