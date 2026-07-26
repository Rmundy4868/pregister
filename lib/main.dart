import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login/login_screen.dart';
import 'master_console/master_console_login_screen.dart';
import 'supabase_config.dart';

const _brandBlue = Color(0xFF8FB7E8);
const _appShell = String.fromEnvironment('APP_SHELL', defaultValue: 'register');
const _showSupabaseConfigGate = bool.fromEnvironment(
  'SHOW_SUPABASE_CONFIG_GATE',
  defaultValue: false,
);

void _logRuntimeError(Object error, StackTrace stackTrace, {String? source}) {
  final label = source == null ? 'RUNTIME ERROR' : 'RUNTIME ERROR ($source)';
  debugPrint('========== $label ==========');
  debugPrint(error.toString());
  debugPrint('---------- STACK TRACE ----------');
  debugPrint(stackTrace.toString());
  debugPrint('=================================');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    _logRuntimeError(
      details.exception,
      details.stack ?? StackTrace.current,
      source: 'FlutterError.onError',
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    _logRuntimeError(error, stack, source: 'PlatformDispatcher.onError');
    return true;
  };

    final missingSupabaseConfig =
      SupabaseConfig.url.isEmpty ||
      SupabaseConfig.anonKey.isEmpty ||
      !SupabaseConfig.hasValidUrl ||
      SupabaseConfig.hasPlaceholderValues;

    final shouldShowConfigGate =
      _showSupabaseConfigGate && missingSupabaseConfig;

  if (!missingSupabaseConfig) {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
    );
  }

  // Set system UI overlay style to match the app theme
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: _brandBlue,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: _brandBlue,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(MyApp(missingSupabaseConfig: shouldShowConfigGate));
}

class MyApp extends StatelessWidget {
  const MyApp({required this.missingSupabaseConfig, super.key});

  final bool missingSupabaseConfig;

  @override
  Widget build(BuildContext context) {
    final seeded = ColorScheme.fromSeed(seedColor: _brandBlue);
    final showMasterConsole = _appShell.toLowerCase() == 'master_console';
    return MaterialApp(
      title: showMasterConsole ? 'PaaayIT Master Console' : 'PaaayIT.com',
      debugShowCheckedModeBanner: false,
      theme:
          ThemeData.from(
            colorScheme: seeded.copyWith(
              surface: Colors.white,
              surfaceContainerLowest: Colors.white,
              surfaceContainerLow: Colors.white,
              surfaceContainer: Colors.white,
              surfaceContainerHigh: const Color(0xFFF5F9FF),
              surfaceContainerHighest: const Color(0xFFEEF5FF),
            ),
          ).copyWith(
            scaffoldBackgroundColor: Colors.white,
            appBarTheme: const AppBarTheme(
              backgroundColor: _brandBlue,
              foregroundColor: Colors.black87,
            ),
            dialogTheme: const DialogThemeData(backgroundColor: Colors.white),
            snackBarTheme: const SnackBarThemeData(
              backgroundColor: Colors.red,
              contentTextStyle: TextStyle(color: Colors.white),
              actionTextColor: Colors.white,
            ),
          ),
      home: missingSupabaseConfig
          ? const MissingSupabaseConfigScreen()
          : (showMasterConsole
                ? const MasterConsoleLoginScreen()
                : const LoginScreen()),
    );
  }
}

class MissingSupabaseConfigScreen extends StatelessWidget {
  const MissingSupabaseConfigScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configuration Required')),
      body: const Padding(
        padding: EdgeInsets.all(16),
        child: SelectableText(
          'Supabase config is missing.\n\n'
          'Run with:\n'
          'flutter run -d windows --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY\n\n'
          'License key, terminal number, and optional location are entered and saved in-app.',
        ),
      ),
    );
  }
}
