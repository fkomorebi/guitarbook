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
    for (final dependency in [
      ('JUCE', 'assets/licenses/JUCE-LICENSE.md'),
      ('Oboe', 'assets/licenses/Oboe-LICENSE.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([
        dependency.$1,
      ], await rootBundle.loadString(dependency.$2));
    }
  });
  runApp(const GuitarbookApp());
}
