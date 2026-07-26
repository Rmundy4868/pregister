import 'package:flutter/widgets.dart';

import '../vregister/vregister_screen.dart';
import 'register_screen.dart';

const String _appVariant = String.fromEnvironment(
  'APP_VARIANT',
  defaultValue: 'register',
);

bool get isVRegisterVariant => _appVariant.toLowerCase() == 'vregister';

String get activeRegisterVariant => isVRegisterVariant ? 'vregister' : 'register';

Widget buildRegisterVariantScreen({Map<String, String>? startupContextOverride}) {
  if (isVRegisterVariant) {
    return VRegisterScreen(startupContextOverride: startupContextOverride);
  }

  return RegisterScreen(startupContextOverride: startupContextOverride);
}
