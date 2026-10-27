import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app/guitarbook_app.dart';

void main() {
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString(
      'assets/fonts/OFL-NotoSerif.txt',
    );
    yield LicenseEntryWithLineBreaks(['Noto Serif'], license);
  });
  runApp(const GuitarbookApp());
}
