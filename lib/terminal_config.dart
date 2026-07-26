import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

/// Runtime terminal configuration resolved from Supabase at startup.
///
/// Payment credentials (TPN, auth key) are stored per-terminal in the
/// `terminals` table and loaded via [applyFromTerminalRecord] (token path)
/// or [loadForTerminalId] (stored-credentials path).
///
/// Fallback chain for each credential:
///   1. Value resolved from Supabase terminal record (preferred)
///   2. dart-define value (dev/testing only)
///   3. Empty string (triggers "not configured" UI)
class TerminalConfig {
  static const String cardReaderNone = 'none';
  static const String cardReaderDejavooP12 = 'dejavoo_p12';
  static const String _definedCardReaderHppAuthToken = String.fromEnvironment(
    'CARD_READER_HPP_AUTH_TOKEN',
    defaultValue: '',
  );

  static String _spinTpn = '';
  static String _spinAuthKey = '';
  static String _cardReaderType = cardReaderNone;
  static String _cardReaderHppAuthToken = '';
  static String _defaultReceiptPrinter = '';
  static String _lastLoadDebug = '';

  /// The SPIn Terminal Parameter Number for this terminal.
  static String get spinTpn {
    if (_spinTpn.isNotEmpty) return _spinTpn;
    return SupabaseConfig.spinTpn;
  }

  /// The SPIn authentication key for this terminal.
  static String get spinAuthKey {
    if (_spinAuthKey.isNotEmpty) return _spinAuthKey;
    return SupabaseConfig.spinAuthKey;
  }

  static String _normalizeCardReaderType(String? raw) {
    final value = (raw ?? '').trim().toLowerCase();
    if (value == cardReaderDejavooP12) return cardReaderDejavooP12;
    if (value == cardReaderNone) return cardReaderNone;

    // Accept common legacy labels as "no reader".
    if (value.isEmpty ||
        value == 'no card reader' ||
        value == 'none selected' ||
        value == 'manual' ||
        value == 'keyed') {
      return cardReaderNone;
    }

    // Fail-safe: unknown values should not force a physical-reader flow.
    return cardReaderNone;
  }

  static String get cardReaderType {
    return _normalizeCardReaderType(_cardReaderType);
  }

  static bool get hasPhysicalCardReader =>
      cardReaderType == cardReaderDejavooP12;

  /// The HPP (Hosted Payment Page) Auth Token for keyed card entry and email/SMS links.
  static String get cardReaderHppAuthToken {
    if (_cardReaderHppAuthToken.trim().isNotEmpty) {
      return _cardReaderHppAuthToken.trim();
    }
    return _definedCardReaderHppAuthToken.trim();
  }

  static String get defaultReceiptPrinter => _defaultReceiptPrinter;
  static String get lastLoadDebug => _lastLoadDebug;

  /// Whether payment credentials are fully configured.
  static bool get isPaymentConfigured =>
      spinTpn.isNotEmpty && spinAuthKey.isNotEmpty;

  /// Called after URL token resolution. Stores credentials in memory.
  static void applyFromTerminalRecord({
    required String spinTpn,
    required String spinAuthKey,
    String? cardReaderType,
    String? cardReaderHppAuthToken,
    String? defaultReceiptPrinter,
  }) {
    _spinTpn = spinTpn.trim();
    _spinAuthKey = spinAuthKey.trim();
    if (cardReaderType != null) {
      _cardReaderType = _normalizeCardReaderType(cardReaderType);
    }
    if (cardReaderHppAuthToken != null) {
      _cardReaderHppAuthToken = cardReaderHppAuthToken.trim();
    }
    if (defaultReceiptPrinter != null) {
      _defaultReceiptPrinter = defaultReceiptPrinter.trim();
    }
  }

  /// Called after stored-credentials startup. Fetches payment config
  /// directly from the terminals table using the resolved terminal ID.
  static Future<void> loadForTerminalId(
    String terminalId, {
    String terminalNumber = '',
    bool forceRefresh = false,
  }) async {
    if (terminalId.isEmpty) return;
    if (!forceRefresh &&
        _spinTpn.isNotEmpty &&
        _spinAuthKey.isNotEmpty &&
        _cardReaderType.isNotEmpty &&
        _cardReaderHppAuthToken.isNotEmpty &&
        _defaultReceiptPrinter.isNotEmpty) {
      return;
    }

    String pickField(Map<String, dynamic> row, List<String> keys) {
      for (final key in keys) {
        final value = row[key]?.toString().trim() ?? '';
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    try {
      Future<List<dynamic>> fetchById() {
        return Supabase.instance.client
            .from('terminals')
            .select(
              'spin_tpn, spin_auth_key, card_reader_type, card_reader_hpp_auth_token, receipt_printer_name',
            )
            .eq('id', terminalId)
            .limit(1);
      }

      Future<List<dynamic>> fetchByTerminalNumber(String number) {
        return Supabase.instance.client
            .from('terminals')
            .select(
              'spin_tpn, spin_auth_key, card_reader_type, card_reader_hpp_auth_token, receipt_printer_name',
            )
            .eq('terminal_number', number)
            .limit(1);
      }

      final normalizedTerminalNumber = terminalNumber.trim();
      final terminalNumberVariants = <String>{};
      if (normalizedTerminalNumber.isNotEmpty) {
        terminalNumberVariants.add(normalizedTerminalNumber);
        final unpadded = normalizedTerminalNumber.replaceFirst(
          RegExp(r'^0+'),
          '',
        );
        final canonical = unpadded.isEmpty ? '0' : unpadded;
        terminalNumberVariants.add(canonical);
        terminalNumberVariants.add(canonical.padLeft(3, '0'));
        terminalNumberVariants.add(canonical.padLeft(4, '0'));
      }

      var rows = await fetchById();
      var source = 'id';

      if (rows.isEmpty && terminalNumberVariants.isNotEmpty) {
        for (final n in terminalNumberVariants) {
          rows = await fetchByTerminalNumber(n);
          if (rows.isNotEmpty) {
            source = 'terminal_number:' + n;
            break;
          }
        }
      }

      if (rows.isEmpty) {
        _lastLoadDebug =
            'No supplemental terminals lookup row found; continuing with activation context.';
        return;
      }

      final row = Map<String, dynamic>.from(rows.first as Map);
      _spinTpn = pickField(row, ['spin_tpn', 'spinTpn']);
      _spinAuthKey = pickField(row, ['spin_auth_key', 'spinAuthKey']);
      _cardReaderType = _normalizeCardReaderType(
        pickField(row, ['card_reader_type', 'cardReaderType']),
      );
      _cardReaderHppAuthToken = pickField(row, [
        'card_reader_hpp_auth_token',
        'cardReaderHppAuthToken',
        'hpp_auth_token',
        'hppAuthToken',
      ]);
      _defaultReceiptPrinter = pickField(row, [
        'receipt_printer_name',
        'receiptPrinterName',
        'default_receipt_printer',
        'defaultReceiptPrinter',
      ]);
      _lastLoadDebug =
          'Loaded terminals row by $source for id=$terminalId terminal_number=$normalizedTerminalNumber, tokenLen=${_cardReaderHppAuthToken.length}, printer="$_defaultReceiptPrinter"';
    } catch (error) {
      // Non-fatal — falls back to dart-define or empty.
      _lastLoadDebug = 'Terminals lookup failed for id=$terminalId: $error';
    }
  }

  /// Clears resolved credentials — call if terminal context is reset.
  static void clear() {
    _spinTpn = '';
    _spinAuthKey = '';
    _cardReaderType = cardReaderNone;
    _cardReaderHppAuthToken = '';
    _defaultReceiptPrinter = '';
    _lastLoadDebug = '';
  }
}
