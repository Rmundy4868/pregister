import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'login/login_screen.dart';
import 'services/license_service.dart';
import 'terminal/terminal_activation_screen.dart';

/// Shown at startup. Resolves terminal identity via:
///   1. URL token (`?tk=<token>`) — web only, primary
///   2. Cached localStorage values — fast subsequent loads
///   3. TerminalActivationScreen — fallback / first-time setup
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  final LicenseService _licenseService = LicenseService();
  static const _timeoutSeconds = 15;
  static const _paymentApiBase = String.fromEnvironment(
    'PAYMENT_API_BASE_URL',
    defaultValue: 'http://localhost:3000',
  );

  bool _timedOut = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// Extracts the ?tk= query parameter from the current URL when running on web.
  String? _getUrlToken() {
    if (!kIsWeb) return null;
    try {
      final uri = Uri.base;
      return uri.queryParameters['tk'];
    } catch (_) {
      return null;
    }
  }

  /// Extracts ?lk= / ?tn= / ?loc= shortcut params from the current URL.
  ({String? lk, String? tn, String? loc}) _getShortcutParams() {
    if (!kIsWeb) return (lk: null, tn: null, loc: null);
    try {
      final params = Uri.base.queryParameters;
      return (
        lk: params['lk']?.trim().isNotEmpty == true ? params['lk']!.trim() : null,
        tn: params['tn']?.trim().isNotEmpty == true ? params['tn']!.trim() : null,
        loc: params['loc']?.trim().isNotEmpty == true ? params['loc']!.trim() : null,
      );
    } catch (_) {
      return (lk: null, tn: null, loc: null);
    }
  }

  Future<void> _bootstrap() async {
    if (mounted) {
      setState(() {
        _timedOut = false;
        _errorMessage = null;
      });
    }

    final backendOk = await _checkPaymentBackendHealth();
    if (!backendOk) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Payment backend is offline.\n\n'
            'Start Node backend and retry.\n'
            'Expected health URL: ${_paymentApiBase.replaceAll(RegExp(r'/+$'), '')}/api/health';
      });
      return;
    }

    LicenseActivationResult result;

    try {
      result = await _resolve().timeout(
        const Duration(seconds: _timeoutSeconds),
        onTimeout: () => const LicenseActivationResult(
          success: false,
          requiresInput: false,
          errorMessage: 'Connection timed out. Check your network and try again.',
        ),
      );
    } catch (error) {
      result = LicenseActivationResult(
        success: false,
        requiresInput: false,
        errorMessage: 'Startup error: $error',
      );
    }

    if (!mounted) return;

    if (result.success) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      );
      return;
    }

    if (result.requiresTerminalRegistration) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const TerminalActivationScreen()),
      );
      return;
    }

    final isTimeout = result.errorMessage?.toLowerCase().contains('timed out') ?? false;
    if (isTimeout) {
      setState(() => _timedOut = true);
      return;
    }

    // requiresInput = true means no credentials at all → first-time activation
    if (result.requiresInput && result.attemptedLicenseKey == null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const TerminalActivationScreen()),
      );
      return;
    }

    // Any other failure: show the error so we can diagnose rather than silently
    // dropping to the activation screen (which would wipe stored credentials).
    if (result.errorMessage != null && result.errorMessage!.isNotEmpty) {
      setState(() => _errorMessage = 'Startup failed: ${result.errorMessage}');
      return;
    }

    // No credentials stored at all → activation screen
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const TerminalActivationScreen()),
    );
  }

  Future<bool> _checkPaymentBackendHealth() async {
    final base = _paymentApiBase.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$base/api/health');
    if (uri == null) return false;

    try {
      final response = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Resolves terminal context using the best available identity source.
  Future<LicenseActivationResult> _resolve() async {
    // 1. URL token — highest priority on web
    final urlToken = _getUrlToken();
    if (urlToken != null && urlToken.isNotEmpty) {
      final tokenResult = await _licenseService.resolveFromUrlToken(urlToken);
      if (tokenResult.success) return tokenResult;

      // Token in URL but resolution failed → show error, do not fall through
      // to activation screen silently (wrong URL or deactivated terminal).
      return LicenseActivationResult(
        success: false,
        requiresInput: false,
        errorMessage: tokenResult.errorMessage ??
            'Terminal token in URL could not be resolved. '
            'Ensure this is the correct terminal URL.',
      );
    }

    // 2. Shortcut params (?lk= / ?tn= / ?loc=) — set by the downloaded .url file.
    //    Silent auto-activation: no registration allowed, just match existing terminal.
    final shortcut = _getShortcutParams();
    if (shortcut.lk != null) {
      final shortcutResult = await _licenseService.activateLicense(
        shortcut.lk!,
        terminalNumber: shortcut.tn ?? '0001',
        locationName: shortcut.loc ?? '',
        allowTerminalRegistration: false,
      );
      if (shortcutResult.success) return shortcutResult;
      // Shortcut params present but failed → fall through to stored/define
      // (could be first time on new machine with same license key).
    }

    // 3. Cached / dart-define identity
    return _licenseService.initializeFromStoredOrDefine();
  }

  @override
  Widget build(BuildContext context) {
    if (_timedOut) {
      return _buildErrorView(
        message: 'Connection timed out.\nCheck your network connection and try again.',
        onRetry: _bootstrap,
      );
    }

    if (_errorMessage != null) {
      return _buildErrorView(message: _errorMessage!, onRetry: _bootstrap, showReactivate: true);
    }

    return const Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(height: 20),
            Text(
              'Starting up…',
              style: TextStyle(
                fontSize: 15,
                color: Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView({
    required String message,
    required VoidCallback onRetry,
    bool showReactivate = false,
  }) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, size: 48, color: Colors.black26),
              const SizedBox(height: 20),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, color: Colors.black54, height: 1.5),
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
              if (showReactivate) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute<void>(
                      builder: (_) => const TerminalActivationScreen(),
                    ),
                  ),
                  child: const Text('Reactivate Terminal'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
