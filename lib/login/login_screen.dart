import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../register/register_variant_router.dart';
import '../services/license_service.dart';
import '../services/transaction_sync_service.dart';
import '../supabase_config.dart';
import '../terminal_config.dart';
import '../terminal/terminal_activation_screen.dart';
import '../widgets/register_sale_logo.dart';
import '../widgets/terminal_ambient_background.dart';

const _showStartupVariableValidation = bool.fromEnvironment(
  'SHOW_STARTUP_VARIABLE_VALIDATION',
  defaultValue: false,
);

// ---------------------------------------------------------------------------
// Login context — holds every variable resolved after PIN validation.
// ---------------------------------------------------------------------------
class _LoginContext {
  final Map<String, String> startupContext;
  final String organizationId;
  final String organizationName;
  final String licenseKey;
  final String locationId;
  final String locationName;
  final String terminalId;
  final String terminalNumber;
  final String staffId;
  final String staffName;
  final String staffRole;
  final String applicationMode; // 'sandbox' | 'production'

  const _LoginContext({
    required this.startupContext,
    required this.organizationId,
    required this.organizationName,
    required this.licenseKey,
    required this.locationId,
    required this.locationName,
    required this.terminalId,
    required this.terminalNumber,
    required this.staffId,
    required this.staffName,
    required this.staffRole,
    required this.applicationMode,
  });

  bool get isValid =>
      organizationId.isNotEmpty &&
      licenseKey.isNotEmpty &&
      locationId.isNotEmpty &&
      staffId.isNotEmpty &&
      staffName.isNotEmpty;
}

// ---------------------------------------------------------------------------
// LoginScreen
// ---------------------------------------------------------------------------
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const int _maxPinLength = 6;
  static const int _loginTimeoutSeconds = 60;
  static const Color _themeYellow = Color(0xFFFADA00);

  final LicenseService _licenseService = LicenseService();
  final TransactionSyncService _transactionSyncService =
      TransactionSyncService();
  final FocusNode _loginKeyboardFocusNode = FocusNode();

  String _pin = '';
  bool _isAuthenticating = false;
  bool _isInitializingContext = true;
  String? _errorMessage;
  bool _startupValidationShown = false;

  @override
  void initState() {
    super.initState();
    _initializeLicenseContext();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loginKeyboardFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _loginKeyboardFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initializeLicenseContext() async {
    setState(() {
      _isInitializingContext = true;
      _errorMessage = null;
    });

    LicenseActivationResult result;
    final urlToken = Uri.base.queryParameters['tk']?.trim() ?? '';

    if (urlToken.isNotEmpty) {
      result = await _licenseService.resolveFromUrlToken(urlToken);
    } else {
      result = await _licenseService.initializeFromStoredOrDefine();
    }

    if (!mounted) return;

    if (!result.success && result.requiresTerminalRegistration) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => const TerminalActivationScreen(),
        ),
      );
      return;
    }

    // If activation input is required, send operators directly to activation UI
    // instead of leaving them on the PIN pad with a key prompt.
    if (!result.success &&
        result.requiresInput &&
        result.attemptedLicenseKey == null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => const TerminalActivationScreen(),
        ),
      );
      return;
    }

    setState(() {
      _isInitializingContext = false;
      if (!result.success) {
        _pin = '';
        _errorMessage = result.errorMessage?.trim().isNotEmpty == true
            ? result.errorMessage
            : 'Terminal activation is required before PIN login.';
      }
    });

    if (result.success) {
      await _showStartupValidationIfEnabled();
    }
  }

  String _maskSecret(String value, {int head = 3, int tail = 2}) {
    final text = value.trim();
    if (text.isEmpty) return '(empty)';
    if (text.length <= head + tail) {
      return '${text.substring(0, 1)}***';
    }
    return '${text.substring(0, head)}***${text.substring(text.length - tail)}';
  }

  Future<Map<String, String>> _readLocalIdentityValues() async {
    final prefs = await SharedPreferences.getInstance();
    String read(String key) => prefs.getString(key)?.trim() ?? '';
    return {
      'app_license_key': read('app_license_key'),
      'app_terminal_number': read('app_terminal_number'),
      'app_location_name': read('app_location_name'),
      'app_device_id': read('app_device_id'),
      'app_device_label': read('app_device_label'),
      'app_terminal_token': read('app_terminal_token'),
      'app_spin_tpn': read('app_spin_tpn'),
      'app_spin_auth_key': read('app_spin_auth_key').isEmpty
          ? ''
          : _maskSecret(read('app_spin_auth_key')),
    };
  }

  Future<void> _showStartupValidationIfEnabled() async {
    if (!_showStartupVariableValidation ||
        !SupabaseConfig.debugMode ||
        _startupValidationShown ||
        !mounted)
      return;

    _startupValidationShown = true;
    await _ensureLicenseContextReady();
    if (!mounted) return;

    final activeContext = _licenseService.activeContext;
    final startupContext = await _transactionSyncService.getStartupContext();
    final localIdentity = await _readLocalIdentityValues();
    final terminalNumber =
        activeContext?.terminalNumber ?? SupabaseConfig.terminalNumber;
    final terminalId = activeContext?.terminalId ?? '';

    if (terminalId.isNotEmpty) {
      await TerminalConfig.loadForTerminalId(
        terminalId,
        terminalNumber: terminalNumber,
      );
    }

    if (!mounted) return;

    final organizationRows = <MapEntry<String, String>>[
      MapEntry('organization_id', activeContext?.organizationId ?? ''),
      MapEntry('organization_number', activeContext?.organizationNumber ?? ''),
      MapEntry('organization_name', activeContext?.organizationName ?? ''),
      MapEntry('license_key', activeContext?.licenseKey ?? ''),
      MapEntry(
        'terminal_licenses',
        (activeContext?.terminalLicenses ?? 0).toString(),
      ),
      MapEntry(
        'terminals_active',
        (activeContext?.terminalsActive ?? 0).toString(),
      ),
    ];

    final locationRows = <MapEntry<String, String>>[
      MapEntry('location_id', activeContext?.locationId ?? ''),
      MapEntry('location_name', activeContext?.locationName ?? ''),
      MapEntry('location_address_1', startupContext['locationAddress1'] ?? ''),
      MapEntry('location_address_2', startupContext['locationAddress2'] ?? ''),
      MapEntry('location_city', startupContext['locationCity'] ?? ''),
      MapEntry('location_state', startupContext['locationState'] ?? ''),
      MapEntry('location_zip', startupContext['locationZip'] ?? ''),
      MapEntry('location_phone', startupContext['locationPhone'] ?? ''),
      MapEntry(
        'allow_tip_adjustments',
        startupContext['allow_tip_adjustments'] ??
            startupContext['allowTipAdjustments'] ??
            '',
      ),
      MapEntry(
        'print_tip_suggestions',
        startupContext['printTipSuggestions'] ?? '',
      ),
      MapEntry(
        'tip_suggestion_1_pct',
        startupContext['tipSuggestion1Pct'] ?? '',
      ),
      MapEntry(
        'tip_suggestion_2_pct',
        startupContext['tipSuggestion2Pct'] ?? '',
      ),
      MapEntry(
        'tip_suggestion_3_pct',
        startupContext['tipSuggestion3Pct'] ?? '',
      ),
      MapEntry(
        'tip_suggestion_base',
        startupContext['tipSuggestionBase'] ?? '',
      ),
    ];

    final terminalRows = <MapEntry<String, String>>[
      MapEntry('terminal_id', activeContext?.terminalId ?? ''),
      MapEntry('terminal_number', terminalNumber),
      MapEntry('terminal_name', activeContext?.terminalName ?? ''),
      MapEntry('card_reader_type', TerminalConfig.cardReaderType),
      MapEntry(
        'card_reader_hpp_auth_token',
        TerminalConfig.cardReaderHppAuthToken.isEmpty
            ? ''
            : _maskSecret(TerminalConfig.cardReaderHppAuthToken),
      ),
      MapEntry('spin_tpn', TerminalConfig.spinTpn),
      MapEntry(
        'spin_auth_key',
        TerminalConfig.spinAuthKey.isEmpty
            ? ''
            : _maskSecret(TerminalConfig.spinAuthKey),
      ),
      MapEntry(
        'default_receipt_printer',
        startupContext['defaultReceiptPrinter'] ?? '',
      ),
      MapEntry(
        'sale_receipt_preview_enabled',
        startupContext['saleReceiptPreviewEnabled'] ?? '',
      ),
      MapEntry(
        'sale_receipt_copy_count',
        startupContext['saleReceiptCopyCount'] ?? '',
      ),
      MapEntry(
        'void_receipt_preview_enabled',
        startupContext['voidReceiptPreviewEnabled'] ?? '',
      ),
      MapEntry(
        'void_receipt_copy_count',
        startupContext['voidReceiptCopyCount'] ?? '',
      ),
      MapEntry(
        'return_receipt_preview_enabled',
        startupContext['returnReceiptPreviewEnabled'] ?? '',
      ),
      MapEntry(
        'return_receipt_copy_count',
        startupContext['returnReceiptCopyCount'] ?? '',
      ),
      MapEntry(
        'receipt_reply_to_email',
        startupContext['receiptReplyToEmail'] ?? '',
      ),
      MapEntry('terminal_loader_debug', TerminalConfig.lastLoadDebug),
    ];

    final runtimeRows = <MapEntry<String, String>>[
      MapEntry('SUPABASE_URL', SupabaseConfig.url),
      MapEntry('ORGANIZATION_NUMBER_define', SupabaseConfig.organizationNumber),
      MapEntry('TERMINAL_NUMBER_define', SupabaseConfig.terminalNumber),
      MapEntry('LOCATION_NAME_define', SupabaseConfig.locationName),
      MapEntry('APP_DEVICE_ID_define', SupabaseConfig.appDeviceId),
      MapEntry('APP_DEVICE_LABEL_define', SupabaseConfig.appDeviceLabel),
      MapEntry('SPIN_SANDBOX', SupabaseConfig.spinSandbox.toString()),
      MapEntry('DEBUG_MODE', SupabaseConfig.debugMode.toString()),
    ];

    Widget section(String title, List<MapEntry<String, String>> rows) {
      final visibleRows = rows
          .where((entry) => entry.key.trim().isNotEmpty)
          .toList(growable: false);
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            ...visibleRows.map(
              (entry) => SelectableText(
                '${entry.key}: ${entry.value.isEmpty ? '(empty)' : entry.value}',
                style: const TextStyle(fontSize: 12, height: 1.35),
              ),
            ),
          ],
        ),
      );
    }

    final allRows = <MapEntry<String, String>>[
      ...organizationRows,
      ...locationRows,
      ...terminalRows,
      ...runtimeRows,
      ...localIdentity.entries,
    ];

    final copyBuffer = allRows
        .map(
          (entry) =>
              '${entry.key}: ${entry.value.isEmpty ? '(empty)' : entry.value}',
        )
        .join('\n');

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Startup Variable Validation'),
          content: SizedBox(
            width: 760,
            height: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  section(
                    'Organization File (organizations)',
                    organizationRows,
                  ),
                  section('Location File (locations)', locationRows),
                  section('Terminal File (terminals)', terminalRows),
                  section('Runtime Defines / App Config', runtimeRows),
                  section(
                    'Local Identity (shared_preferences)',
                    localIdentity.entries
                        .map((entry) => MapEntry(entry.key, entry.value))
                        .toList(growable: false),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: copyBuffer));
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('Startup variables copied.')),
                );
              },
              child: const Text('Copy All'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _ensureLicenseContextReady() async {
    if (_licenseService.activeContext != null) return true;
    await _initializeLicenseContext();
    return _licenseService.activeContext != null;
  }

  // ---- PIN input ----

  void _onDigit(String digit) {
    if (_isAuthenticating ||
        _isInitializingContext ||
        _pin.length >= _maxPinLength) {
      return;
    }
    setState(() {
      _pin += digit;
      _errorMessage = null;
    });
  }

  void _onBackspace() {
    if (_isAuthenticating || _isInitializingContext || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _onClear() {
    if (_isAuthenticating || _isInitializingContext) return;
    _resetToLoginState();
  }

  /// Cancel: clear all PIN data and return to a clean waiting state.
  void _onCancel() => _resetToLoginState();

  void _resetToLoginState() {
    setState(() {
      _pin = '';
      if (!_isInitializingContext && _licenseService.activeContext != null) {
        _errorMessage = null;
      }
      _isAuthenticating = false;
    });
    _loginKeyboardFocusNode.requestFocus();
  }

  bool _handleLoginKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      unawaited(_onLogin());
      return true;
    }
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      _onBackspace();
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      _onClear();
      return true;
    }

    if (key == LogicalKeyboardKey.numpad0 || key == LogicalKeyboardKey.digit0) {
      _onDigit('0');
      return true;
    }
    if (key == LogicalKeyboardKey.numpad1 || key == LogicalKeyboardKey.digit1) {
      _onDigit('1');
      return true;
    }
    if (key == LogicalKeyboardKey.numpad2 || key == LogicalKeyboardKey.digit2) {
      _onDigit('2');
      return true;
    }
    if (key == LogicalKeyboardKey.numpad3 || key == LogicalKeyboardKey.digit3) {
      _onDigit('3');
      return true;
    }
    if (key == LogicalKeyboardKey.numpad4 || key == LogicalKeyboardKey.digit4) {
      _onDigit('4');
      return true;
    }
    if (key == LogicalKeyboardKey.numpad5 || key == LogicalKeyboardKey.digit5) {
      _onDigit('5');
      return true;
    }
    if (key == LogicalKeyboardKey.numpad6 || key == LogicalKeyboardKey.digit6) {
      _onDigit('6');
      return true;
    }
    if (key == LogicalKeyboardKey.numpad7 || key == LogicalKeyboardKey.digit7) {
      _onDigit('7');
      return true;
    }
    if (key == LogicalKeyboardKey.numpad8 || key == LogicalKeyboardKey.digit8) {
      _onDigit('8');
      return true;
    }
    if (key == LogicalKeyboardKey.numpad9 || key == LogicalKeyboardKey.digit9) {
      _onDigit('9');
      return true;
    }
    return false;
  }

  // ---- Login flow ----

  Future<void> _onLogin() async {
    if (_pin.isEmpty || _isAuthenticating) return;

    final ready = await _ensureLicenseContextReady();
    if (!mounted) return;
    if (!ready) {
      setState(() {
        _pin = '';
        _errorMessage =
            _errorMessage ??
            'Terminal activation is required before PIN login.';
      });
      return;
    }

    setState(() {
      _isAuthenticating = true;
      _errorMessage = null;
    });

    Map<String, String>? rawContext;
    bool timedOut = false;

    try {
      rawContext = await _transactionSyncService
          .getStartupContextForStaffPin(_pin)
          .timeout(
            const Duration(seconds: _loginTimeoutSeconds),
            onTimeout: () {
              timedOut = true;
              return null;
            },
          );
    } catch (_) {
      timedOut = false;
      rawContext = null;
    }

    if (!mounted) return;

    if (timedOut) {
      setState(() => _isAuthenticating = false);
      await _showTimeoutDialog();
      return;
    }

    if (rawContext == null) {
      setState(() {
        _isAuthenticating = false;
        _pin = '';
        _errorMessage = 'Invalid PIN. Please try again.';
      });
      return;
    }

    // Build full validated context
    final licenseCtx = _licenseService.activeContext;
    final loginCtx = _LoginContext(
      startupContext: rawContext,
      organizationId:
          rawContext['organizationId'] ?? licenseCtx?.organizationId ?? '',
      organizationName:
          rawContext['organizationName'] ?? licenseCtx?.organizationName ?? '',
      licenseKey: rawContext['licenseKey'] ?? licenseCtx?.licenseKey ?? '',
      locationId: rawContext['locationId'] ?? licenseCtx?.locationId ?? '',
      locationName:
          rawContext['locationName'] ?? licenseCtx?.locationName ?? '',
      terminalId: rawContext['terminalId'] ?? licenseCtx?.terminalId ?? '',
      terminalNumber:
          rawContext['terminalNumber'] ?? licenseCtx?.terminalNumber ?? '',
      staffId: rawContext['staffId'] ?? '',
      staffName: rawContext['staffName'] ?? '',
      staffRole: rawContext['staffRole'] ?? '',
      applicationMode: SupabaseConfig.spinSandbox ? 'sandbox' : 'production',
    );

    if (!loginCtx.isValid) {
      setState(() {
        _isAuthenticating = false;
        _pin = '';
        _errorMessage = 'Login context incomplete. Contact your administrator.';
      });
      return;
    }

    setState(() => _isAuthenticating = false);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => buildRegisterVariantScreen(
          startupContextOverride: loginCtx.startupContext,
        ),
      ),
    );
  }

  // ---- Dialogs ----

  Future<void> _showTimeoutDialog() async {
    final retry = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Connection Timeout'),
        content: const Text(
          'The application could not be loaded at this time.\n\nDo you wish to try again?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (retry == true) {
      _resetToLoginState();
    } else {
      // User chose No — clear everything and wait; closing the tab terminates the app.
      _resetToLoginState();
      setState(
        () => _errorMessage = 'Login cancelled. Close this tab to exit.',
      );
    }
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final licenseContext = _licenseService.activeContext;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    const frameAspect = 19.5 / 9;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => _loginKeyboardFocusNode.requestFocus(),
      child: KeyboardListener(
        focusNode: _loginKeyboardFocusNode,
        onKeyEvent: (event) {
          if (event is! KeyDownEvent) return;
          _handleLoginKey(event.logicalKey);
        },
        child: Scaffold(
          body: TerminalAmbientBackground(
            style: AmbientBackgroundStyle.cinematic,
            child: SafeArea(
              child: Center(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final usableWidth = (constraints.maxWidth - 20)
                        .clamp(260.0, 560.0)
                        .toDouble();
                    final usableHeight = (constraints.maxHeight - 20)
                        .clamp(520.0, 980.0)
                        .toDouble();
                    final maxWidthByHeight = usableHeight / frameAspect;
                    final frameWidth =
                        (usableWidth < maxWidthByHeight
                                ? usableWidth
                                : maxWidthByHeight)
                            .clamp(260.0, 500.0)
                            .toDouble();
                    final frameHeight = frameWidth * frameAspect;
                    final shellCornerRadius = frameWidth * 0.14;
                    final screenCornerRadius = frameWidth * 0.09;
                    final bezel = frameWidth * 0.05;
                    final isNativeMobileDevice =
                        !kIsWeb &&
                        (defaultTargetPlatform == TargetPlatform.android ||
                            defaultTargetPlatform == TargetPlatform.iOS);

                    final terminalLoginCanvas = ClipRRect(
                      borderRadius: BorderRadius.circular(screenCornerRadius),
                      child: Container(
                        color: Colors.white,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border(
                                  bottom: BorderSide(
                                    color: cs.outlineVariant,
                                    width: 1,
                                  ),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Center(child: RegisterSaleLogo()),
                                  const SizedBox(height: 4),
                                  const Center(
                                    child: Text(
                                      'LOGIN',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.3,
                                        color: Color(0xFF3FBCF3),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (licenseContext != null) ...[
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: cs.surfaceContainerHigh,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Column(
                                          children: [
                                            Text(
                                              licenseContext.organizationName,
                                              style: theme.textTheme.titleSmall
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w700,
                                                    color: cs.onSurface,
                                                  ),
                                              textAlign: TextAlign.center,
                                              overflow: TextOverflow.ellipsis,
                                              maxLines: 2,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '${licenseContext.locationName}  ·  Terminal ${licenseContext.terminalNumber}',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: cs.onSurfaceVariant,
                                                  ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                    ],
                                    Text(
                                      'Enter PIN to Login',
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            letterSpacing: 0.4,
                                          ),
                                    ),
                                    const SizedBox(height: 14),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: List.generate(
                                        _maxPinLength,
                                        (i) => _PinDot(
                                          filled: i < _pin.length,
                                          colorScheme: cs,
                                        ),
                                      ),
                                    ),
                                    AnimatedSize(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      child: _errorMessage != null
                                          ? Padding(
                                              padding: const EdgeInsets.only(
                                                top: 10,
                                              ),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 7,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: cs.errorContainer,
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: Text(
                                                  _errorMessage!,
                                                  style: theme
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color:
                                                            cs.onErrorContainer,
                                                      ),
                                                  textAlign: TextAlign.center,
                                                ),
                                              ),
                                            )
                                          : const SizedBox.shrink(),
                                    ),
                                    const SizedBox(height: 14),
                                    _buildNumPad(theme),
                                    const SizedBox(height: 14),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed:
                                                _isAuthenticating ||
                                                    _isInitializingContext
                                                ? null
                                                : _onCancel,
                                            style: OutlinedButton.styleFrom(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 14,
                                                  ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                            child: const Text('Cancel'),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: FilledButton(
                                            onPressed:
                                                _pin.isNotEmpty &&
                                                    !_isAuthenticating &&
                                                    !_isInitializingContext
                                                ? _onLogin
                                                : null,
                                            style: FilledButton.styleFrom(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 14,
                                                  ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                            child:
                                                (_isAuthenticating ||
                                                    _isInitializingContext)
                                                ? SizedBox(
                                                    width: 18,
                                                    height: 18,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: cs.onPrimary,
                                                        ),
                                                  )
                                                : const Text('Login'),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (_isInitializingContext) ...[
                                      const SizedBox(height: 10),
                                      Text(
                                        'Initializing terminal context...',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: cs.onSurfaceVariant,
                                            ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                    if (SupabaseConfig.debugMode) ...[
                                      const SizedBox(height: 10),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.orange.shade100,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: Text(
                                          'DEBUG MODE',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.orange.shade800,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 1.4,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );

                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(10),
                      child: isNativeMobileDevice
                          ? SizedBox(
                              width: frameWidth,
                              height: frameHeight,
                              child: terminalLoginCanvas,
                            )
                          : SizedBox(
                              width: frameWidth,
                              height: frameHeight,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(
                                          shellCornerRadius,
                                        ),
                                        gradient: const LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                            Color(0xFF4A4F56),
                                            Color(0xFF2E3339),
                                            Color(0xFF15191E),
                                            Color(0xFF2A2F35),
                                          ],
                                          stops: [0.0, 0.25, 0.68, 1.0],
                                        ),
                                        border: Border.all(
                                          color: const Color(0xFF1F2328),
                                          width: 2.2,
                                        ),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Color(0x6A000000),
                                            blurRadius: 28,
                                            offset: Offset(0, 16),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: bezel,
                                    right: bezel,
                                    top: bezel,
                                    bottom: bezel,
                                    child: terminalLoginCanvas,
                                  ),
                                ],
                              ),
                            ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNumPad(ThemeData theme) {
    return Column(
      children: [
        _buildNumRow(['1', '2', '3'], theme),
        const SizedBox(height: 10),
        _buildNumRow(['4', '5', '6'], theme),
        const SizedBox(height: 10),
        _buildNumRow(['7', '8', '9'], theme),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildKey(
              onTap: _onClear,
              theme: theme,
              backgroundColor: const Color(0xFFD32F2F),
              child: Text(
                'Clear',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 10),
            _buildKey(
              onTap: () => _onDigit('0'),
              theme: theme,
              child: Text(
                '0',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 10),
            _buildKey(
              onTap: _onBackspace,
              theme: theme,
              backgroundColor: _themeYellow,
              child: Icon(
                Icons.backspace_outlined,
                size: 20,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNumRow(List<String> digits, ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < digits.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          _buildKey(
            onTap: () => _onDigit(digits[i]),
            theme: theme,
            child: Text(
              digits[i],
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildKey({
    required VoidCallback onTap,
    required Widget child,
    required ThemeData theme,
    Color? backgroundColor,
  }) {
    final cs = theme.colorScheme;
    final keyWidth = ((MediaQuery.sizeOf(context).width - 72) / 3).clamp(
      62.0,
      86.0,
    );
    final keyHeight = (keyWidth * 0.74).clamp(48.0, 64.0);
    return Material(
      color: backgroundColor ?? cs.secondaryContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        splashColor: cs.primary.withAlpha(40),
        highlightColor: cs.primary.withAlpha(20),
        child: SizedBox(
          width: keyWidth,
          height: keyHeight,
          child: Center(child: child),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Animated PIN dot — springs in when filled
// ---------------------------------------------------------------------------
class _PinDot extends StatefulWidget {
  const _PinDot({required this.filled, required this.colorScheme});
  final bool filled;
  final ColorScheme colorScheme;

  @override
  State<_PinDot> createState() => _PinDotState();
}

class _PinDotState extends State<_PinDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut);
  }

  @override
  void didUpdateWidget(_PinDot old) {
    super.didUpdateWidget(old);
    if (widget.filled && !old.filled) {
      _ctrl.forward(from: 0);
    } else if (!widget.filled && old.filled) {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ScaleTransition(
        scale: _scale,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.filled ? cs.primary : Colors.transparent,
            border: Border.all(
              color: widget.filled ? cs.primary : cs.outlineVariant,
              width: 2.2,
            ),
          ),
        ),
      ),
    );
  }
}
