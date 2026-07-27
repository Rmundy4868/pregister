import 'dart:async';

import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../debug/transaction_integrity_check.dart';
import '../login/login_screen.dart';
import '../register/batch_functions_selection_screen.dart';
import '../register/closed_batch_browser_screen.dart';
import '../register/dejavoo_sale_dialog.dart';
import '../register/reports_selection_screen.dart';
import '../register/view_transactions_report_screen.dart';
import '../scheduler/tee_sheet_window.dart';
import '../services/license_service.dart';
import '../services/dejavoo_service.dart';
import '../services/hosted_payment_service.dart';
import '../services/integrity_check_store.dart';
import '../services/paaayit_request_service.dart';
import '../services/transaction_flow_parameters.dart';
import '../services/transaction_sync_service.dart';
import '../settings/settings_window.dart';
import '../settings/terminal_manager_v2.dart';
import '../supabase_config.dart';
import '../terminal_config.dart';
import '../widgets/paaayit_request_dialog.dart';
import '../widgets/register_sale_logo.dart';
import '../widgets/receipt_actions_dialog.dart';
import '../widgets/standard_action_button.dart';
import '../widgets/terminal_ambient_background.dart';
import '../utils/receipt_id_format.dart';
import 'package:url_launcher/url_launcher.dart';

enum _TerminalKeyboardMode { alphanumeric, numeric }

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, this.startupContextOverride});

  final Map<String, String>? startupContextOverride;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  static const bool _showTemporaryRefundVerification = true;
  static const String _paymentApiBaseUrl = String.fromEnvironment(
    'PAYMENT_API_BASE_URL',
    defaultValue: 'http://127.0.0.1:3000',
  );
  static const bool _forceFirstStartOfDayWarmup = bool.fromEnvironment(
    'FORCE_FIRST_START_OF_DAY_WARMUP',
    defaultValue: false,
  );
  static const bool _enableCardTerminalWarmup = bool.fromEnvironment(
    'ENABLE_CARD_TERMINAL_WARMUP',
    defaultValue: false,
  );
  static const bool _cashTrackingEnabled = false;
  static const Color _saleAccentGreen = Color(0xFF4CBB17);
  static const Color _themeYellow = Color(0xFFFADA00);
  static const Color _themeRed = Color(0xFFD32F2F);
  static const Color _themeOrange = Color(0xFFF57C00);
  final List<double> _items = [];
  final List<double> _itemTaxes = [];
  final List<_ReceiptItemEntry> _receiptEntries = [];
  final List<String> _paymentHistory = [];
  final List<String> _lastTransactionInfoLines = [];
  final List<String> _lastCustomerInfoLines = [];
  // Structured card payment data for terminal-only receipt format.
  final List<Map<String, String>> _cardPaymentDetails = [];

  final TextEditingController _customerNumberController =
      TextEditingController();
  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();
  final TextEditingController _address1Controller = TextEditingController();
  final TextEditingController _address2Controller = TextEditingController();
  final TextEditingController _cityController = TextEditingController();
  final TextEditingController _stateController = TextEditingController();
  final TextEditingController _zipController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _messageBoxController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final _transactionSyncService = TransactionSyncService();

  List<Map<String, dynamic>> _openBatchCards = [];
  bool _batchLoading = false;
  int _activeHeaderBatchNumber = 1;

  String _postedCustomerNumber = '';
  String _postedFullName = '';
  String _postedAddress1 = '';
  String _postedAddress2 = '';
  String _postedCityStateZip = '';
  String _postedPhone = '';
  String _postedEmail = '';
  bool _isLeftMenuExpanded = false;
  String _currentInput = '';
  double _cashPaid = 0;
  Timer? _keypadCursorTimer;
  Timer? _autoCloseTimer;
  Timer? _batchReconcileDebounceTimer;
  bool _showKeypadCursor = true;
  bool _autoCloseInFlight = false;
  bool _batchReconcileInFlight = false;
  bool _isGratuityAdjustEnabled = false;
  bool _terminalWarmingUp = false;
  bool _startupCardRouteShown = false;
  String _resolvedTerminalConfigId = '';
  String _lastBatchReconcileReason = 'startup';
  String _terminalActiveScreen = 'sale';
  bool _terminalScreenTransitionForward = true;
  final GlobalKey _terminalViewportKey = GlobalKey();

  String _terminalName = 'TEST_TERMINAL';
  String _staffName = 'TEST_STAFF';
  String _staffId = '';
  String _locationName = '';
  String _locationAddress1 = '';
  String _locationAddress2 = '';
  String _locationCity = '';
  String _locationState = '';
  String _locationZip = '';
  String _locationPhone = '';
  bool _printTipSuggestions = true;
  double _tipSuggestion1Pct = 18;
  double _tipSuggestion2Pct = 20;
  double _tipSuggestion3Pct = 25;
  String _tipSuggestionBase = 'subtotal';
  String _receiptCardSignatureMessage = '';
  String _receiptMiscMessage = '';
  String _defaultReceiptPrinter = '';
  String _invoiceReference = '';
  String _pendingTransactionId = '';
  String _lastReceiptIdDisplay = '';
  TransactionFlowParameters _transactionFlowParameters =
      const TransactionFlowParameters(
        staffTrackingEnabled: false,
        customerTrackingEnabled: false,
        integrityChecksEnabled: false,
        enableProcessorSurcharge: false,
        receiptPreviewEnabled: {'sale': true, 'void': true, 'return': true},
        receiptCopyCount: {'sale': 2, 'void': 2, 'return': 2},
        receiptReplyToEmail: '',
        customerFieldModes: {
          'invoice_reference': CustomerFieldMode.optional,
          'customer_id': CustomerFieldMode.optional,
          'first_name': CustomerFieldMode.optional,
          'last_name': CustomerFieldMode.optional,
          'address1': CustomerFieldMode.optional,
          'address2': CustomerFieldMode.optional,
          'city': CustomerFieldMode.optional,
          'state': CustomerFieldMode.optional,
          'zip': CustomerFieldMode.optional,
          'email': CustomerFieldMode.optional,
        },
      );

  double get total => _items.fold(0.0, (a, b) => a + b);
  double get _totalTax => _itemTaxes.fold(0.0, (a, b) => a + b);
  double get _subTotal => total + _totalTax;
  double get _totalPaid => _cashPaid;
  double get _balance => _subTotal - _totalPaid;

  String _formatTime(DateTime dt) {
    final hour24 = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final suffix = hour24 >= 12 ? 'PM' : 'AM';
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    return '$hour12:$minute $suffix';
  }

  String _formatShortDate(DateTime dt) {
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final year = (dt.year % 100).toString().padLeft(2, '0');
    return '$month/$day/$year';
  }

  String _formatReceiptCityStateZip() {
    final city = _locationCity.trim();
    final state = _locationState.trim();
    final zip = _locationZip.trim();

    final cityState = city.isNotEmpty && state.isNotEmpty
        ? '$city, $state'
        : city.isNotEmpty
        ? city
        : state;

    if (zip.isEmpty) return cityState;
    if (cityState.isEmpty) return zip;
    return '$cityState $zip';
  }

  String _formatReceiptPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 10) {
      return '(${digits.substring(0, 3)}) ${digits.substring(3, 6)}-${digits.substring(6)}';
    }
    if (digits.length == 11 && digits.startsWith('1')) {
      return '+1 (${digits.substring(1, 4)}) ${digits.substring(4, 7)}-${digits.substring(7)}';
    }
    return raw.trim();
  }

  String _preferredReceiptValue(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final text = candidate?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _formatReceiptCustomerCityStateZip({
    required String city,
    required String state,
    required String zip,
  }) {
    final trimmedCity = city.trim();
    final trimmedState = state.trim();
    final trimmedZip = zip.trim();

    final cityState = trimmedCity.isNotEmpty && trimmedState.isNotEmpty
        ? '$trimmedCity, $trimmedState'
        : trimmedCity.isNotEmpty
        ? trimmedCity
        : trimmedState;

    if (trimmedZip.isEmpty) return cityState;
    if (cityState.isEmpty) return trimmedZip;
    return '$cityState $trimmedZip';
  }

  Map<String, dynamic> _buildCurrentReceiptCustomerTrackingData() {
    final firstName = _preferredReceiptValue([
      _postedFullName,
      _firstNameController.text,
    ]);
    final lastName = _preferredReceiptValue([_lastNameController.text]);

    return {
      'first_name': firstName,
      'last_name': lastName,
      'name': _preferredReceiptValue([_postedFullName, '$firstName $lastName']),
      'customer_number': _preferredReceiptValue([
        _postedCustomerNumber,
        _customerNumberController.text,
      ]),
      'address_1': _preferredReceiptValue([
        _postedAddress1,
        _address1Controller.text,
      ]),
      'address_2': _preferredReceiptValue([
        _postedAddress2,
        _address2Controller.text,
      ]),
      'city': _preferredReceiptValue([_cityController.text]),
      'state': _preferredReceiptValue([_stateController.text]),
      'zip': _preferredReceiptValue([_zipController.text]),
      'phone': _preferredReceiptValue([_postedPhone, _phoneController.text]),
      'email': _preferredReceiptValue([_postedEmail, _emailController.text]),
      'invoice_reference': _preferredReceiptValue([_invoiceReference]),
    };
  }

  Map<String, dynamic> _buildReceiptCustomerTrackingDataFromDetail(
    Map<String, dynamic> detail,
  ) {
    final merged = <String, dynamic>{};
    dynamic snapshotRaw = detail['customer_snapshot'];

    final headerRaw = detail['transaction_headers'];
    if (snapshotRaw == null && headerRaw is Map) {
      final headerMap = Map<String, dynamic>.from(headerRaw);
      snapshotRaw = headerMap['customer_snapshot'];
      final headerInvoice =
          headerMap['invoice_reference']?.toString().trim() ?? '';
      if (headerInvoice.isNotEmpty &&
          (detail['invoice_reference']?.toString().trim() ?? '').isEmpty) {
        merged['invoice_reference'] = headerInvoice;
      }
    }

    if (snapshotRaw is Map) {
      merged.addAll(Map<String, dynamic>.from(snapshotRaw));
    } else if (snapshotRaw is String) {
      try {
        final decoded = jsonDecode(snapshotRaw);
        if (decoded is Map) {
          merged.addAll(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // Ignore malformed snapshot payloads and fall back to detail fields.
      }
    }

    for (final entry in detail.entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }

    return merged;
  }

  void _appendCustomerTrackingInfoWidgets(
    List<pw.Widget> widgets, {
    required Map<String, dynamic> data,
  }) {
    final firstName = _preferredReceiptValue([
      data['first_name'],
      data['firstName'],
    ]);
    final lastName = _preferredReceiptValue([
      data['last_name'],
      data['lastName'],
    ]);
    final fullName = _preferredReceiptValue([
      '$firstName $lastName',
      data['name'],
      data['customer_name'],
      data['customerName'],
    ]);
    final address1 = _preferredReceiptValue([
      data['address_1'],
      data['address1'],
      data['street'],
    ]);
    final address2 = _preferredReceiptValue([
      data['address_2'],
      data['address2'],
    ]);
    final city = _preferredReceiptValue([data['city']]);
    final state = _preferredReceiptValue([data['state']]);
    final zip = _preferredReceiptValue([
      data['zip'],
      data['postal_code'],
      data['postalCode'],
    ]);
    final cityStateZip = _formatReceiptCustomerCityStateZip(
      city: city,
      state: state,
      zip: zip,
    );
    final customerId = _preferredReceiptValue([
      data['customer_number'],
      data['customer_id'],
      data['customerId'],
    ]);
    final phone = _preferredReceiptValue([
      data['phone'],
      data['phone_number'],
      data['phoneNumber'],
    ]);
    final email = _preferredReceiptValue([data['email']]);
    final invoiceReference = _preferredReceiptValue([
      data['invoice_reference'],
      data['invoiceReference'],
    ]);

    final otherLines = <String>[
      if (customerId.isNotEmpty) 'Customer ID: $customerId',
      if (phone.isNotEmpty) 'Phone: ${_formatReceiptPhone(phone)}',
      if (email.isNotEmpty) 'Email: $email',
      if (invoiceReference.isNotEmpty) 'Invoice/Reference: $invoiceReference',
    ];

    final hasTrackingData =
        fullName.isNotEmpty ||
        address1.isNotEmpty ||
        address2.isNotEmpty ||
        cityStateZip.isNotEmpty ||
        otherLines.isNotEmpty;
    if (!hasTrackingData) return;

    widgets.add(pw.SizedBox(height: 2));
    widgets.add(
      pw.Text(
        'Customer / Tracking info',
        style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
      ),
    );
    if (fullName.isNotEmpty) {
      widgets.add(pw.Text(fullName, style: const pw.TextStyle(fontSize: 8.5)));
    }
    if (address1.isNotEmpty) {
      widgets.add(pw.Text(address1, style: const pw.TextStyle(fontSize: 8.5)));
    }
    if (address2.isNotEmpty) {
      widgets.add(pw.Text(address2, style: const pw.TextStyle(fontSize: 8.5)));
    }
    if (cityStateZip.isNotEmpty) {
      widgets.add(
        pw.Text(cityStateZip, style: const pw.TextStyle(fontSize: 8.5)),
      );
    }
    for (final line in otherLines) {
      widgets.add(pw.Text(line, style: const pw.TextStyle(fontSize: 8.5)));
    }
    widgets.add(pw.SizedBox(height: 4));
  }

  bool _parseStartupBool(String? raw, {bool fallback = false}) {
    final normalized = raw?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) return fallback;
    return normalized == 'true' ||
        normalized == '1' ||
        normalized == 'yes' ||
        normalized == 'y';
  }

  double _parseStartupDouble(String? raw, double fallback) {
    return double.tryParse(raw?.trim() ?? '') ?? fallback;
  }

  String _normalizeTipSuggestionBase(String? raw) {
    final normalized = raw?.trim().toLowerCase() ?? '';
    return normalized == 'total' ? 'total' : 'subtotal';
  }

  String _formatTipSuggestionPercent(double value) {
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
  }

  double _receiptTipSuggestionBaseAmount() {
    final configuredBase = _tipSuggestionBase == 'total' ? _subTotal : total;
    if (configuredBase > 0) {
      return configuredBase;
    }

    // Terminal-only receipts can have no line items, leaving subtotal/total at 0.
    // In that case, derive tip base from captured payment amount(s).
    if (_cardPaymentDetails.isNotEmpty) {
      var paymentBase = 0.0;
      for (final payment in _cardPaymentDetails) {
        final normalized = payment['amount']
            ?.toString()
            .replaceAll(RegExp(r'[^0-9.\-]'), '')
            .trim();
        final parsedAmount = double.tryParse(normalized ?? '') ?? 0.0;
        paymentBase += parsedAmount.abs();
      }
      if (paymentBase > 0) {
        return paymentBase;
      }
    }

    return _subTotal > 0 ? _subTotal : total;
  }

  List<String> _receiptMessageLines(String raw) {
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  void _appendReceiptMessageWidgets(List<pw.Widget> widgets) {
    final signatureLines = _receiptMessageLines(_receiptCardSignatureMessage);
    final miscLines = _receiptMessageLines(_receiptMiscMessage);
    if (signatureLines.isEmpty && miscLines.isEmpty) {
      return;
    }

    widgets.add(pw.SizedBox(height: 10));

    for (final line in signatureLines) {
      widgets.add(
        pw.Center(
          child: pw.Text(
            line,
            style: const pw.TextStyle(fontSize: 8.5),
            textAlign: pw.TextAlign.center,
          ),
        ),
      );
    }

    if (signatureLines.isNotEmpty && miscLines.isNotEmpty) {
      widgets.add(pw.SizedBox(height: 4));
      widgets.add(pw.Divider(thickness: 0.6));
      widgets.add(pw.SizedBox(height: 4));
    }

    for (final line in miscLines) {
      widgets.add(
        pw.Center(
          child: pw.Text(
            line,
            style: const pw.TextStyle(fontSize: 8.5),
            textAlign: pw.TextAlign.center,
          ),
        ),
      );
    }
  }

  void _appendSaleReceiptTipSection(List<pw.Widget> widgets) {
    widgets.add(pw.SizedBox(height: 8));
    widgets.add(pw.SizedBox(height: 4));

    if (_isGratuityAdjustEnabled && _printTipSuggestions) {
      final baseAmount = _receiptTipSuggestionBaseAmount();
      final suggestionPcts = [
        _tipSuggestion1Pct,
        _tipSuggestion2Pct,
        _tipSuggestion3Pct,
      ].where((value) => value > 0).toList();

      if (suggestionPcts.isNotEmpty) {
        widgets.add(
          pw.Text(
            'Suggested Tip',
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
        );
        widgets.add(pw.SizedBox(height: 8));
        widgets.add(
          pw.Row(
            children: [
              pw.Expanded(
                flex: 3,
                child: pw.Text(
                  'Tip %',
                  style: pw.TextStyle(
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.Expanded(
                flex: 3,
                child: pw.Text(
                  'Tip Amt',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.Expanded(
                flex: 3,
                child: pw.Text(
                  'Total',
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
        widgets.add(pw.SizedBox(height: 2));

        for (final pct in suggestionPcts) {
          final suggestionAmount = baseAmount * (pct / 100);
          final lineTotal = baseAmount + suggestionAmount;
          widgets.add(
            pw.Row(
              children: [
                pw.Expanded(
                  flex: 3,
                  child: pw.Text(
                    '[ ] ${_formatTipSuggestionPercent(pct)}%',
                    style: const pw.TextStyle(fontSize: 8.5),
                  ),
                ),
                pw.Expanded(
                  flex: 3,
                  child: pw.Text(
                    '\$${suggestionAmount.toStringAsFixed(2)}',
                    textAlign: pw.TextAlign.center,
                    style: const pw.TextStyle(fontSize: 8.5),
                  ),
                ),
                pw.Expanded(
                  flex: 3,
                  child: pw.Text(
                    '\$${lineTotal.toStringAsFixed(2)}',
                    textAlign: pw.TextAlign.right,
                    style: const pw.TextStyle(fontSize: 8.5),
                  ),
                ),
              ],
            ),
          );
        }

        widgets.add(pw.SizedBox(height: 16));
        widgets.add(
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Tip Amount', style: const pw.TextStyle(fontSize: 8.5)),
              pw.Text('____________', style: const pw.TextStyle(fontSize: 8.5)),
            ],
          ),
        );
        widgets.add(pw.SizedBox(height: 12));
        widgets.add(
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Total', style: const pw.TextStyle(fontSize: 8.5)),
              pw.Text('____________', style: const pw.TextStyle(fontSize: 8.5)),
            ],
          ),
        );
        widgets.add(pw.SizedBox(height: 12));
      }
    }

    _appendReceiptSignatureLine(widgets);
  }

  void _appendReceiptSignatureLine(List<pw.Widget> widgets) {
    widgets.add(pw.SizedBox(height: 6));
    widgets.add(
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Text('Signature:', style: const pw.TextStyle(fontSize: 8.5)),
          pw.SizedBox(width: 6),
          pw.Expanded(
            child: pw.Container(
              height: 9,
              decoration: const pw.BoxDecoration(
                border: pw.Border(bottom: pw.BorderSide(width: 0.7)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _voidOriginalAmount(Map<String, dynamic> detail) {
    return (detail['amount'] as num?)?.toDouble().abs() ?? 0;
  }

  double _voidSurchargeAmount(Map<String, dynamic> detail) {
    return ((detail['surcharge_amount'] ?? detail['fee_amount']) as num?)
            ?.toDouble()
            .abs() ??
        0;
  }

  double _voidTipAdjustmentAmount(Map<String, dynamic> detail) {
    return (detail['tip_adjustment_total'] as num?)?.toDouble() ?? 0;
  }

  double _voidRegisterAmount(Map<String, dynamic> detail) {
    final displayAmount = (detail['display_amount'] as num?)?.toDouble();
    if (displayAmount != null && displayAmount > 0) {
      return displayAmount;
    }

    return _voidOriginalAmount(detail) +
        _voidSurchargeAmount(detail) +
        _voidTipAdjustmentAmount(detail);
  }

  bool _voidAuditMatches(Map<String, dynamic> detail) {
    final calculatedAmount =
        _voidOriginalAmount(detail) +
        _voidSurchargeAmount(detail) +
        _voidTipAdjustmentAmount(detail);
    return (calculatedAmount - _voidRegisterAmount(detail)).abs() <= 0.01;
  }

  void _appendReceiptFooterWidgets(List<pw.Widget> widgets, String? copyLabel) {
    widgets.add(pw.SizedBox(height: 12));
    widgets.add(
      pw.Center(
        child: pw.Text(
          'Thank You',
          style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
        ),
      ),
    );
    widgets.addAll(
      List<pw.Widget>.generate(
        4,
        (_) => pw.SizedBox(height: 12),
        growable: false,
      ),
    );
    widgets.add(pw.SizedBox(height: 8));
    final footerCopyLabel = (copyLabel ?? '').trim().isNotEmpty
        ? copyLabel!.trim()
        : 'Merchant Copy';
    widgets.add(
      pw.Center(
        child: pw.Text(
          footerCopyLabel,
          style: const pw.TextStyle(fontSize: 8.5),
          textAlign: pw.TextAlign.center,
        ),
      ),
    );
    widgets.add(pw.SizedBox(height: 12));
  }

  String _formatReceiptSku(_ReceiptItemEntry entry) {
    final skuLabel = entry.skuLabel?.trim();
    if (skuLabel != null && skuLabel.isNotEmpty) {
      return skuLabel;
    }

    return entry.itemSku % 1 == 0
        ? entry.itemSku.toStringAsFixed(0)
        : entry.itemSku.toStringAsFixed(2);
  }

  double _receiptRowSkuValue(_ReceiptItemEntry entry) {
    final skuLabel = entry.skuLabel?.trim();
    if (skuLabel == null || skuLabel.isEmpty) {
      return entry.itemSku;
    }

    return double.tryParse(skuLabel) ?? entry.itemSku;
  }

  Future<Uint8List> _buildReceiptPdfBytes(
    PdfPageFormat format, {
    String? copyLabel,
  }) async {
    final pdf = pw.Document();
    final now = DateTime.now();
    final cityStateZip = _formatReceiptCityStateZip();
    final formattedPhone = _formatReceiptPhone(_locationPhone);
    // Keep customer phone state referenced after removing Transaction Info section.
    if (_postedPhone.isNotEmpty) {}

    pdf.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 72),
        build: (context) {
          final widgets = <pw.Widget>[];

          widgets.add(pw.SizedBox(height: 12));

          widgets.add(
            pw.Center(
              child: pw.Text(
                _locationName.isNotEmpty ? _locationName : 'Location',
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
                textAlign: pw.TextAlign.center,
              ),
            ),
          );

          if (_locationAddress1.trim().isNotEmpty) {
            widgets.add(
              pw.Center(
                child: pw.Text(
                  _locationAddress1.trim(),
                  style: const pw.TextStyle(fontSize: 8.5),
                  textAlign: pw.TextAlign.center,
                ),
              ),
            );
          }

          if (_locationAddress2.trim().isNotEmpty) {
            widgets.add(
              pw.Center(
                child: pw.Text(
                  _locationAddress2.trim(),
                  style: const pw.TextStyle(fontSize: 8.5),
                  textAlign: pw.TextAlign.center,
                ),
              ),
            );
          }

          if (cityStateZip.isNotEmpty) {
            widgets.add(
              pw.Center(
                child: pw.Text(
                  cityStateZip,
                  style: const pw.TextStyle(fontSize: 8.5),
                  textAlign: pw.TextAlign.center,
                ),
              ),
            );
          }

          if (_locationPhone.trim().isNotEmpty) {
            widgets.add(
              pw.Center(
                child: pw.Text(
                  formattedPhone,
                  style: const pw.TextStyle(fontSize: 8.5),
                  textAlign: pw.TextAlign.center,
                ),
              ),
            );
          }

          widgets.add(pw.SizedBox(height: 4));
          widgets.add(pw.Divider(thickness: 0.6));
          widgets.add(
            pw.Text(
              '${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}/${now.year}  ${_formatTime(now)}',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
          );
          widgets.add(
            pw.Text(
              'Terminal: $_terminalName  Staff: $_staffName',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
          );
          _appendCustomerTrackingInfoWidgets(
            widgets,
            data: _buildCurrentReceiptCustomerTrackingData(),
          );
          widgets.add(pw.SizedBox(height: 4));

          final isTerminalOnlyMode = _receiptEntries.isEmpty;

          if (isTerminalOnlyMode) {
            // ----------------------------------------------------------------
            // Terminal-only receipt: payment section only, no items/totals.
            // ----------------------------------------------------------------
            widgets.add(pw.Divider(thickness: 0.6));

            if (_cardPaymentDetails.isEmpty) {
              widgets.add(
                pw.Text('No payments.', style: const pw.TextStyle(fontSize: 8)),
              );
            } else {
              for (final p in _cardPaymentDetails) {
                final amountValue =
                    double.tryParse((p['amount'] ?? '').toString()) ?? 0.0;
                final feeAmount =
                    double.tryParse((p['feeAmount'] ?? '').toString()) ?? 0.0;
                if ((p['processorRef'] ?? '').isNotEmpty) {
                  widgets.add(
                    pw.Text(
                      'Processor Ref: ${p['processorRef']}',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                  );
                }
                if ((p['card'] ?? '').isNotEmpty) {
                  widgets.add(
                    pw.Text(
                      'Card: ${p['card']}',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                  );
                }
                if ((p['auth'] ?? '').isNotEmpty) {
                  widgets.add(
                    pw.Text(
                      'Auth: ${p['auth']}',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                  );
                }
                if ((p['name'] ?? '').isNotEmpty) {
                  widgets.add(
                    pw.Text(
                      'Cardholder: ${p['name']}',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                  );
                }
                if (_lastReceiptIdDisplay.trim().isNotEmpty) {
                  widgets.add(
                    pw.Text(
                      'Receipt ID: $_lastReceiptIdDisplay',
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                  );
                }
                widgets.add(pw.SizedBox(height: 12));
                widgets.add(
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'Amount: ',
                        style: pw.TextStyle(
                          fontSize: 11,
                          fontWeight: pw.FontWeight.normal,
                        ),
                      ),
                      pw.Text(
                        '\$${p['amount'] ?? ''}',
                        style: pw.TextStyle(
                          fontSize: 11,
                          fontWeight: pw.FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                );
                if (feeAmount > 0) {
                  widgets.add(
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text(
                          'Surcharge: ',
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.normal,
                          ),
                        ),
                        pw.Text(
                          '\$${feeAmount.toStringAsFixed(2)}',
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  );
                  final totalWithSurcharge = amountValue + feeAmount;
                  widgets.add(pw.SizedBox(height: 2));
                  widgets.add(
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text(
                          'Total: ',
                          style: pw.TextStyle(
                            fontSize: 12,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          '\$${totalWithSurcharge.toStringAsFixed(2)}',
                          style: pw.TextStyle(
                            fontSize: 12,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                widgets.add(pw.SizedBox(height: 6));
              }
            }
          } else {
            // ----------------------------------------------------------------
            // Full receipt: items, payments, subtotal/tax/total.
            // ----------------------------------------------------------------
            widgets.add(
              pw.Text(
                'ITEMS',
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 2));

            for (var i = 0; i < _receiptEntries.length; i++) {
              final item = _receiptEntries[i];
              final tax = i < _itemTaxes.length ? _itemTaxes[i] : 0.0;
              widgets.add(
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      item.description,
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text(
                          'SKU ${_formatReceiptSku(item)}',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                        pw.Text(
                          '\$${item.itemSku.toStringAsFixed(2)}',
                          style: const pw.TextStyle(fontSize: 8.5),
                        ),
                      ],
                    ),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Tax', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text(
                          '\$${tax.toStringAsFixed(2)}',
                          style: const pw.TextStyle(fontSize: 8.5),
                        ),
                      ],
                    ),
                    pw.SizedBox(height: 3),
                  ],
                ),
              );
            }

            widgets.add(pw.Divider(thickness: 0.6));
            widgets.add(
              pw.Text(
                'PAYMENTS',
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 2));

            if (_paymentHistory.isEmpty) {
              widgets.add(
                pw.Text('No payments.', style: const pw.TextStyle(fontSize: 8)),
              );
            } else {
              for (final payment in _paymentHistory) {
                widgets.add(
                  pw.Text(payment, style: const pw.TextStyle(fontSize: 8.5)),
                );
                widgets.add(pw.SizedBox(height: 4));
              }
            }

            widgets.add(pw.Divider(thickness: 0.6));
            widgets.add(
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Subtotal', style: const pw.TextStyle(fontSize: 9.5)),
                  pw.Text(
                    '\$${total.toStringAsFixed(2)}',
                    style: const pw.TextStyle(fontSize: 9.5),
                  ),
                ],
              ),
            );
            widgets.add(
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Tax', style: const pw.TextStyle(fontSize: 9.5)),
                  pw.Text(
                    '\$${_totalTax.toStringAsFixed(2)}',
                    style: const pw.TextStyle(fontSize: 9.5),
                  ),
                ],
              ),
            );
            widgets.add(pw.SizedBox(height: 2));
            widgets.add(
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'TOTAL',
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    '\$${_subTotal.toStringAsFixed(2)}',
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
            );
          } // end full receipt

          _appendSaleReceiptTipSection(widgets);

          _appendReceiptMessageWidgets(widgets);
          _appendReceiptFooterWidgets(widgets, copyLabel);

          return widgets;
        },
      ),
    );

    return pdf.save();
  }

  Future<Uint8List> _buildVoidReceiptPdfBytes(
    PdfPageFormat format, {
    required Map<String, dynamic> detail,
    required String voidReferenceId,
    String? copyLabel,
  }) async {
    final pdf = pw.Document();
    final now = DateTime.now();
    final originalAmount = _voidOriginalAmount(detail);
    final surchargeAmount = _voidSurchargeAmount(detail);
    final tipAdjustmentAmount = _voidTipAdjustmentAmount(detail);
    final amount = _voidRegisterAmount(detail);
    final auditMatches = _voidAuditMatches(detail);
    final cardType = (detail['voided_card_type'] ?? detail['card_type'] ?? '')
        .toString();
    final cardLast4 =
        (detail['voided_card_last4'] ?? detail['card_last4'] ?? '').toString();
    final cardholderName =
        (detail['voided_cardholder_name'] ?? detail['cardholder_name'] ?? '')
            .toString()
            .trim();
    final authCode = (detail['voided_auth_code'] ?? detail['auth_code'] ?? '')
        .toString();
    final originalReferenceId =
        (detail['voided_reference_id'] ?? detail['reference_id'] ?? '')
            .toString();
    final invoiceReference = (detail['invoice_reference'] ?? '')
        .toString()
        .trim();
    final cityStateZip = _formatReceiptCityStateZip();
    final formattedPhone = _formatReceiptPhone(_locationPhone);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 72),
        build: (_) {
          final widgets = <pw.Widget>[
            pw.SizedBox(height: 12),
            pw.Center(
              child: pw.Text(
                _locationName.isNotEmpty ? _locationName : 'Location',
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
                textAlign: pw.TextAlign.center,
              ),
            ),
            if (_locationAddress1.trim().isNotEmpty)
              pw.Center(
                child: pw.Text(
                  _locationAddress1.trim(),
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
              ),
            if (_locationAddress2.trim().isNotEmpty)
              pw.Center(
                child: pw.Text(
                  _locationAddress2.trim(),
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
              ),
            if (cityStateZip.isNotEmpty)
              pw.Center(
                child: pw.Text(
                  cityStateZip,
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
              ),
            if (_locationPhone.trim().isNotEmpty)
              pw.Center(
                child: pw.Text(
                  formattedPhone,
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
              ),
            pw.SizedBox(height: 4),
            pw.Divider(thickness: 0.6),
            pw.Text(
              'VOID RECEIPT  ${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}/${now.year}  ${_formatTime(now)}',
              style: pw.TextStyle(
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.Text(
              'Terminal: $_terminalName  Staff: $_staffName',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
          ];
          _appendCustomerTrackingInfoWidgets(
            widgets,
            data: _buildReceiptCustomerTrackingDataFromDetail({
              ...detail,
              'invoice_reference': invoiceReference,
            }),
          );
          widgets.addAll([
            pw.SizedBox(height: 2),
            pw.Text(
              'Card: ${cardType.isEmpty ? 'Card' : cardType}${cardLast4.isEmpty ? '' : ' ****$cardLast4'}',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            if (cardholderName.isNotEmpty)
              pw.Text(
                'Cardholder: $cardholderName',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            if (authCode.isNotEmpty)
              pw.Text(
                'Auth: $authCode',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            if (originalReferenceId.isNotEmpty)
              pw.Text(
                'Original Ref: $originalReferenceId',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            pw.Text(
              'Void Ref: $voidReferenceId',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            pw.Text(
              'Original Sale: \$${originalAmount.toStringAsFixed(2)}',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            if (surchargeAmount > 0)
              pw.Text(
                'Surcharge: \$${surchargeAmount.toStringAsFixed(2)}',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            if (tipAdjustmentAmount > 0)
              pw.Text(
                'Tip Adjustment: \$${tipAdjustmentAmount.toStringAsFixed(2)}',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            pw.Text(
              'Confirmed Register Amount: \$${amount.toStringAsFixed(2)}',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            pw.Text(
              'iPOS Void Amount: \$${amount.toStringAsFixed(2)}',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            pw.Text(
              'Audit: ${auditMatches ? 'MATCH' : 'REVIEW'}',
              style: pw.TextStyle(
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Divider(thickness: 0.6),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Voided Amount',
                  style: const pw.TextStyle(fontSize: 9.5),
                ),
                pw.Text(
                  '\$${amount.toStringAsFixed(2)}',
                  style: pw.TextStyle(
                    fontSize: 9.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 8),
            pw.Center(
              child: pw.Text(
                'Transaction Voided',
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
          ]);
          _appendReceiptSignatureLine(widgets);
          _appendReceiptMessageWidgets(widgets);
          _appendReceiptFooterWidgets(widgets, copyLabel);
          return widgets;
        },
      ),
    );

    return pdf.save();
  }

  Future<Printer?> _resolvePreferredReceiptPrinter() async {
    final preferredName = _defaultReceiptPrinter.trim();
    if (preferredName.isEmpty) {
      return null;
    }

    try {
      final printers = await Printing.listPrinters();
      final exact = printers.where(
        (printer) =>
            printer.name.trim().toLowerCase() == preferredName.toLowerCase(),
      );
      if (exact.isNotEmpty) {
        return exact.first;
      }

      final loose = printers.where(
        (printer) => printer.name.trim().toLowerCase().contains(
          preferredName.toLowerCase(),
        ),
      );
      if (loose.isNotEmpty) {
        return loose.first;
      }
    } catch (_) {
      // Fall through to the first available printer.
    }

    return null;
  }

  Future<Printer?> _resolveAnyReceiptPrinter() async {
    try {
      final printers = await Printing.listPrinters();
      if (printers.isNotEmpty) {
        return printers.first;
      }
    } catch (_) {
      // No printer list available.
    }

    return null;
  }

  Future<void> _printReceiptPdf({
    required String name,
    required Future<Uint8List> Function(PdfPageFormat format) onLayout,
  }) async {
    if (kIsWeb) {
      await Printing.layoutPdf(name: name, onLayout: onLayout);
      return;
    }

    final printer =
        await _resolvePreferredReceiptPrinter() ??
        await _resolveAnyReceiptPrinter();
    if (printer != null) {
      await Printing.directPrintPdf(
        printer: printer,
        name: name,
        onLayout: onLayout,
      );
      return;
    }

    await Printing.layoutPdf(name: name, onLayout: onLayout);
  }

  Future<_ReceiptOutputOptions> _loadReceiptOutputOptions(
    String receiptType,
  ) async {
    await _loadTransactionFlowParameters();
    return _ReceiptOutputOptions(
      previewEnabled: _transactionFlowParameters.receiptPreviewFor(receiptType),
      copyCount: _transactionFlowParameters.receiptCopyCountFor(receiptType),
    );
  }

  String _receiptCopyLabel(int copyIndex) {
    if (copyIndex <= 1) return 'Merchant Copy';
    if (copyIndex == 2) return 'Customer Copy';
    return 'Additional Copy ${copyIndex - 2}';
  }

  Future<void> _showReceiptPrintPreview({String? copyLabel}) async {
    if (!mounted) return;

    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: (MediaQuery.of(dialogContext).size.width - 24).clamp(
            280.0,
            420.0,
          ),
          height: 740,
          child: Column(
            children: [
              if ((copyLabel ?? '').trim().isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Text(
                    copyLabel!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PdfPreview(
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  maxPageWidth: 320,
                  initialPageFormat: receiptFormat,
                  build: (format) => _buildReceiptPdfBytes(
                    receiptFormat,
                    copyLabel: copyLabel,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runSaleReceiptOutputFlow() async {
    final options = await _loadReceiptOutputOptions('sale');

    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    if (options.copyCount == 9 || options.copyCount == 0) {
      await _showReceiptPrintPreview(copyLabel: _receiptCopyLabel(1));
      await _showReceiptPrintPreview(copyLabel: _receiptCopyLabel(2));
      return;
    }

    for (var i = 1; i <= options.copyCount; i++) {
      final copyLabel = _receiptCopyLabel(i);
      if (options.previewEnabled) {
        await _showReceiptPrintPreview(copyLabel: copyLabel);
      } else {
        await _printReceiptPdf(
          name: 'Sale Receipt - $copyLabel',
          onLayout: (format) =>
              _buildReceiptPdfBytes(receiptFormat, copyLabel: copyLabel),
        );
      }
    }
  }

  Future<void> _runSingleSaleReceiptCopyFlow({
    required String copyLabel,
  }) async {
    final options = await _loadReceiptOutputOptions('sale');

    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    if (options.previewEnabled) {
      await _showReceiptPrintPreview(copyLabel: copyLabel);
      return;
    }

    await _printReceiptPdf(
      name: 'Sale Receipt - $copyLabel',
      onLayout: (format) =>
          _buildReceiptPdfBytes(receiptFormat, copyLabel: copyLabel),
    );
  }

  Future<void> _runSingleVoidReceiptCopyFlow({
    required Map<String, dynamic> detail,
    required String voidReferenceId,
    required String copyLabel,
  }) async {
    final options = await _loadReceiptOutputOptions('void');
    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    if (options.previewEnabled) {
      await _showVoidReceiptPrintPreview(
        detail: detail,
        voidReferenceId: voidReferenceId,
        copyLabel: copyLabel,
      );
      return;
    }

    await _printReceiptPdf(
      name: 'Void Receipt - $copyLabel',
      onLayout: (format) => _buildVoidReceiptPdfBytes(
        receiptFormat,
        detail: detail,
        voidReferenceId: voidReferenceId,
        copyLabel: copyLabel,
      ),
    );
  }

  Future<void> _runSingleReturnReceiptCopyFlow({
    required Map<String, dynamic> detail,
    required double amount,
    required String returnReferenceId,
    String? refundNote,
    required String copyLabel,
  }) async {
    final options = await _loadReceiptOutputOptions('return');
    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    if (options.previewEnabled) {
      await _showReturnReceiptPrintPreview(
        detail: detail,
        amount: amount,
        returnReferenceId: returnReferenceId,
        refundNote: refundNote,
        copyLabel: copyLabel,
      );
      return;
    }

    await _printReceiptPdf(
      name: 'Return Receipt - $copyLabel',
      onLayout: (format) => _buildReturnReceiptPdfBytes(
        receiptFormat,
        detail: detail,
        amount: amount,
        returnReferenceId: returnReferenceId,
        refundNote: refundNote,
        copyLabel: copyLabel,
      ),
    );
  }

  Future<void> _emailSaleReceiptPdf({
    required String recipientEmail,
    required double amountPaid,
  }) async {
    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    final bytes = await _buildReceiptPdfBytes(
      receiptFormat,
      copyLabel: 'Customer Email Copy',
    );
    final filename =
        'pregister-sale-receipt-${DateTime.now().millisecondsSinceEpoch}.pdf';
    final locationText = _locationName.trim().isEmpty
        ? 'your location'
        : _locationName.trim();

    final resolvedAmount = amountPaid > 0 ? amountPaid : _subTotal;

    await _transactionSyncService.emailReceiptPdf(
      recipientEmail: recipientEmail,
      pdfBytes: bytes,
      filename: filename,
      subject: 'Your Receipt from $locationText',
      textBody:
          'Location Name: $locationText\n'
          'Thank you for your payment of '
          '\$${resolvedAmount.toStringAsFixed(2)}. '
          'Your receipt is attached.',
      replyTo: _transactionFlowParameters.receiptReplyToEmail,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Receipt emailed to $recipientEmail.')),
    );
  }

  Future<void> _emailVoidReceiptPdf({
    required String recipientEmail,
    required Map<String, dynamic> detail,
    required String voidReferenceId,
    required double amount,
  }) async {
    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    final bytes = await _buildVoidReceiptPdfBytes(
      receiptFormat,
      detail: detail,
      voidReferenceId: voidReferenceId,
      copyLabel: 'Customer Email Copy',
    );
    final filename =
        'pregister-void-receipt-${DateTime.now().millisecondsSinceEpoch}.pdf';
    final locationText = _locationName.trim().isEmpty
        ? 'your location'
        : _locationName.trim();

    await _transactionSyncService.emailReceiptPdf(
      recipientEmail: recipientEmail,
      pdfBytes: bytes,
      filename: filename,
      subject: 'Your Void Receipt from $locationText',
      textBody:
          'Location Name: $locationText\n'
          'Your void receipt for '
          '\$${amount.toStringAsFixed(2)} is attached.',
      replyTo: _transactionFlowParameters.receiptReplyToEmail,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Void receipt emailed to $recipientEmail.')),
    );
  }

  Future<void> _emailReturnReceiptPdf({
    required String recipientEmail,
    required Map<String, dynamic> detail,
    required double amount,
    required String returnReferenceId,
    String? refundNote,
  }) async {
    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    final bytes = await _buildReturnReceiptPdfBytes(
      receiptFormat,
      detail: detail,
      amount: amount,
      returnReferenceId: returnReferenceId,
      refundNote: refundNote,
      copyLabel: 'Customer Email Copy',
    );
    final filename =
        'pregister-return-receipt-${DateTime.now().millisecondsSinceEpoch}.pdf';
    final locationText = _locationName.trim().isEmpty
        ? 'your location'
        : _locationName.trim();

    await _transactionSyncService.emailReceiptPdf(
      recipientEmail: recipientEmail,
      pdfBytes: bytes,
      filename: filename,
      subject: 'Your Return Receipt from $locationText',
      textBody:
          'Location Name: $locationText\n'
          'Your return receipt for '
          '\$${amount.toStringAsFixed(2)} is attached.',
      replyTo: _transactionFlowParameters.receiptReplyToEmail,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Return receipt emailed to $recipientEmail.')),
    );
  }

  Future<void> _showPostTransactionReceiptActionsDialog({
    required String title,
    required double amount,
    required String cardType,
    required String cardLast4,
    required String authCode,
    required String initialEmail,
    required Future<void> Function() onPrintCustomer,
    required Future<void> Function(String recipientEmail) onEmailReceipt,
  }) async {
    if (!mounted) return;

    await showReceiptActionsDialog(
      context: context,
      title: title,
      amount: amount,
      cardType: cardType,
      cardLast4: cardLast4,
      authCode: authCode,
      initialEmail: initialEmail,
      onPrintCustomer: onPrintCustomer,
      onEmailReceipt: onEmailReceipt,
      emailValidator: _isValidEmailFormat,
    );
  }

  Future<void> _showTerminalApprovedActionsDialog({
    required double amount,
    required DejavooSaleResult result,
  }) async {
    if (!mounted) return;

    final initialEmail =
        (_postedEmail.isNotEmpty ? _postedEmail : _emailController.text).trim();
    final emailController = TextEditingController(text: initialEmail);
    String? emailError;
    String? emailSentMessage;
    var isWorking = false;

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              Future<void> runAction(Future<void> Function() action) async {
                setDialogState(() {
                  isWorking = true;
                });
                try {
                  await action();
                } finally {
                  if (dialogContext.mounted) {
                    setDialogState(() {
                      isWorking = false;
                    });
                  }
                }
              }

              return AlertDialog(
                title: const Text('Card Approved'),
                content: SizedBox(
                  width: (MediaQuery.of(dialogContext).size.width - 64).clamp(
                    240.0,
                    420.0,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Amount: \$${amount.toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Card: ${result.cardType ?? 'Card'} ${((result.last4 ?? '').trim().isNotEmpty) ? '****${result.last4}' : ''}',
                      ),
                      Text('Auth: ${result.authCode ?? ''}'),
                      const SizedBox(height: 16),
                      const Text(
                        'Receipt Actions',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: isWorking
                                ? null
                                : () => runAction(
                                    () => _runSingleSaleReceiptCopyFlow(
                                      copyLabel: 'Customer Copy',
                                    ),
                                  ),
                            icon: const Icon(Icons.receipt_long_outlined),
                            label: const Text('Print Customer'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          labelText: 'Email Receipt To',
                          hintText: 'name@domain.com',
                          errorText: emailError,
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (_) {
                          if (emailError != null || emailSentMessage != null) {
                            setDialogState(() {
                              emailError = null;
                              emailSentMessage = null;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: isWorking
                            ? null
                            : () async {
                                final email = emailController.text.trim();
                                if (email.isEmpty ||
                                    !_isValidEmailFormat(email)) {
                                  setDialogState(() {
                                    emailError =
                                        'Enter a valid email address to continue.';
                                  });
                                  return;
                                }

                                await runAction(() async {
                                  try {
                                    await _emailSaleReceiptPdf(
                                      recipientEmail: email,
                                      amountPaid: amount,
                                    );
                                    if (dialogContext.mounted) {
                                      setDialogState(() {
                                        emailError = null;
                                        emailSentMessage =
                                            'Receipt email sent to $email.';
                                      });
                                    }
                                  } catch (error) {
                                    final message = error
                                        .toString()
                                        .replaceFirst('Exception: ', '')
                                        .trim();
                                    if (dialogContext.mounted) {
                                      setDialogState(() {
                                        emailSentMessage = null;
                                        emailError = message.isNotEmpty
                                            ? message
                                            : 'Unable to send receipt email right now.';
                                      });
                                    }
                                  }
                                });
                              },
                        icon: const Icon(Icons.email_outlined),
                        label: const Text('Email Receipt'),
                      ),
                      if (emailSentMessage != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD1FADF),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            emailSentMessage!,
                            style: const TextStyle(
                              color: Color(0xFF065F46),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  FilledButton(
                    onPressed: isWorking
                        ? null
                        : () => Navigator.of(dialogContext).pop(),
                    child: const Text('Done'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      emailController.dispose();
    }
  }

  Future<void> _runVoidReceiptOutputFlow({
    required Map<String, dynamic> detail,
    required String voidReferenceId,
  }) async {
    final options = await _loadReceiptOutputOptions('void');

    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    if (options.copyCount == 9 || options.copyCount == 0) {
      await _showVoidReceiptPrintPreview(
        detail: detail,
        voidReferenceId: voidReferenceId,
        copyLabel: _receiptCopyLabel(1),
      );
      await _showVoidReceiptPrintPreview(
        detail: detail,
        voidReferenceId: voidReferenceId,
        copyLabel: _receiptCopyLabel(2),
      );
      return;
    }

    for (var i = 1; i <= options.copyCount; i++) {
      final copyLabel = _receiptCopyLabel(i);
      if (options.previewEnabled) {
        await _showVoidReceiptPrintPreview(
          detail: detail,
          voidReferenceId: voidReferenceId,
          copyLabel: copyLabel,
        );
      } else {
        await _printReceiptPdf(
          name: 'Void Receipt - $copyLabel',
          onLayout: (format) => _buildVoidReceiptPdfBytes(
            receiptFormat,
            detail: detail,
            voidReferenceId: voidReferenceId,
            copyLabel: copyLabel,
          ),
        );
      }
    }
  }

  Future<Uint8List> _buildReturnReceiptPdfBytes(
    PdfPageFormat format, {
    required Map<String, dynamic> detail,
    required double amount,
    required String returnReferenceId,
    String? refundNote,
    String? copyLabel,
  }) async {
    final pdf = pw.Document();
    final now = DateTime.now();
    final cardType = (detail['card_type'] ?? '').toString();
    final cardLast4 = (detail['card_last4'] ?? '').toString();
    final originalReferenceId = (detail['reference_id'] ?? '').toString();
    final invoiceReference = (detail['invoice_reference'] ?? '')
        .toString()
        .trim();
    final cityStateZip = _formatReceiptCityStateZip();
    final formattedPhone = _formatReceiptPhone(_locationPhone);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 72),
        build: (_) {
          final widgets = <pw.Widget>[
            pw.SizedBox(height: 12),
            pw.Center(
              child: pw.Text(
                _locationName.isNotEmpty ? _locationName : 'Location',
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            if (_locationAddress1.trim().isNotEmpty)
              pw.Center(
                child: pw.Text(
                  _locationAddress1.trim(),
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
              ),
            if (_locationAddress2.trim().isNotEmpty)
              pw.Center(
                child: pw.Text(
                  _locationAddress2.trim(),
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
              ),
            if (cityStateZip.isNotEmpty)
              pw.Center(
                child: pw.Text(
                  cityStateZip,
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
              ),
            if (_locationPhone.trim().isNotEmpty)
              pw.Center(
                child: pw.Text(
                  formattedPhone,
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
              ),
            pw.SizedBox(height: 4),
            pw.Divider(thickness: 0.6),
            pw.Text(
              'RETURN RECEIPT  ${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}/${now.year}  ${_formatTime(now)}',
              style: pw.TextStyle(
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.Text(
              'Terminal: $_terminalName  Staff: $_staffName',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
          ];
          _appendCustomerTrackingInfoWidgets(
            widgets,
            data: _buildReceiptCustomerTrackingDataFromDetail({
              ...detail,
              'invoice_reference': invoiceReference,
            }),
          );
          widgets.addAll([
            pw.SizedBox(height: 2),
            pw.Text(
              'Card: ${cardType.isEmpty ? 'Card' : cardType}${cardLast4.isEmpty ? '' : ' ****$cardLast4'}',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            if (originalReferenceId.isNotEmpty)
              pw.Text(
                'Original Ref: $originalReferenceId',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            if ((refundNote ?? '').trim().isNotEmpty)
              pw.Text(
                'Refund Note: ${refundNote!.trim()}',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            pw.Text(
              'Return Ref: $returnReferenceId',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            pw.SizedBox(height: 6),
            pw.Divider(thickness: 0.6),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Returned Amount',
                  style: const pw.TextStyle(fontSize: 9.5),
                ),
                pw.Text(
                  '\$${amount.toStringAsFixed(2)}',
                  style: pw.TextStyle(
                    fontSize: 9.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 8),
            pw.Center(
              child: pw.Text(
                'Transaction Returned',
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
          ]);
          _appendReceiptSignatureLine(widgets);
          _appendReceiptMessageWidgets(widgets);
          _appendReceiptFooterWidgets(widgets, copyLabel);
          return widgets;
        },
      ),
    );

    return pdf.save();
  }

  Future<void> _showVoidReceiptPrintPreview({
    required Map<String, dynamic> detail,
    required String voidReferenceId,
    String? copyLabel,
  }) async {
    if (!mounted) return;

    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: (MediaQuery.of(dialogContext).size.width - 24).clamp(
            280.0,
            420.0,
          ),
          height: 740,
          child: Column(
            children: [
              if ((copyLabel ?? '').trim().isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Text(
                    copyLabel!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: 'Do Not Print',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PdfPreview(
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  maxPageWidth: 320,
                  initialPageFormat: receiptFormat,
                  build: (format) => _buildVoidReceiptPdfBytes(
                    receiptFormat,
                    detail: detail,
                    voidReferenceId: voidReferenceId,
                    copyLabel: copyLabel,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showReturnReceiptPrintPreview({
    required Map<String, dynamic> detail,
    required double amount,
    required String returnReferenceId,
    String? refundNote,
    String? copyLabel,
  }) async {
    if (!mounted) return;

    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: (MediaQuery.of(dialogContext).size.width - 24).clamp(
            280.0,
            420.0,
          ),
          height: 740,
          child: Column(
            children: [
              if ((copyLabel ?? '').trim().isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Text(
                    copyLabel!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: 'Do Not Print',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PdfPreview(
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  maxPageWidth: 320,
                  initialPageFormat: receiptFormat,
                  build: (format) => _buildReturnReceiptPdfBytes(
                    receiptFormat,
                    detail: detail,
                    amount: amount,
                    returnReferenceId: returnReferenceId,
                    refundNote: refundNote,
                    copyLabel: copyLabel,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runReturnReceiptOutputFlow({
    required Map<String, dynamic> detail,
    required double amount,
    required String returnReferenceId,
    String? refundNote,
  }) async {
    final options = await _loadReceiptOutputOptions('return');

    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    if (options.copyCount == 9 || options.copyCount == 0) {
      await _showReturnReceiptPrintPreview(
        detail: detail,
        amount: amount,
        returnReferenceId: returnReferenceId,
        refundNote: refundNote,
        copyLabel: _receiptCopyLabel(1),
      );
      await _showReturnReceiptPrintPreview(
        detail: detail,
        amount: amount,
        returnReferenceId: returnReferenceId,
        refundNote: refundNote,
        copyLabel: _receiptCopyLabel(2),
      );
      return;
    }

    for (var i = 1; i <= options.copyCount; i++) {
      final copyLabel = _receiptCopyLabel(i);
      if (options.previewEnabled) {
        await _showReturnReceiptPrintPreview(
          detail: detail,
          amount: amount,
          returnReferenceId: returnReferenceId,
          refundNote: refundNote,
          copyLabel: copyLabel,
        );
      } else {
        await _printReceiptPdf(
          name: 'Return Receipt - $copyLabel',
          onLayout: (format) => _buildReturnReceiptPdfBytes(
            receiptFormat,
            detail: detail,
            amount: amount,
            returnReferenceId: returnReferenceId,
            refundNote: refundNote,
            copyLabel: copyLabel,
          ),
        );
      }
    }
  }

  Future<Uint8List> _buildOpenBatchReportPdfBytes(PdfPageFormat format) async {
    final pdf = pw.Document();
    final now = DateTime.now();
    const reportTitleFontSize = 9.0;
    const reportSummaryFontSize = 7.0;
    const reportRowTitleFontSize = 7.5;
    const reportRowDetailFontSize = 6.5;
    const reportBlankLineHeight = 8.0;
    const reportBlankLinesTopBottom = 4;
    double parseMoney(dynamic value) {
      if (value == null) return 0.0;
      if (value is num) return value.toDouble();
      final parsed = double.tryParse(value.toString().trim());
      return parsed ?? 0.0;
    }

    final sourceRows = await _transactionSyncService.getOpenBatchCardDetails();

    final openBatchRows = sourceRows
        .where(
          (row) =>
              (row['batch_status']?.toString().trim().toLowerCase() ?? '') ==
              'o',
        )
        .toList();
    final openBatchSnapshot = _transactionSyncService
        .buildOpenBatchIntegritySnapshot(openBatchRows);
    final reportRows = List<Map<String, dynamic>>.from(
      openBatchSnapshot['rows'] as List,
    );

    final approvedRows = reportRows
        .where((r) => r['status'] == 'approved')
        .toList();
    final refundRows = reportRows
        .where(
          (r) => r['status'] == 'approved' && r['subtype']?.toString() == 'r',
        )
        .toList();
    final voidedRows = reportRows
        .where((r) => r['status'] == 'voided')
        .toList();

    final totals = Map<String, dynamic>.from(
      openBatchSnapshot['totals'] as Map<String, dynamic>? ??
          const <String, dynamic>{},
    );
    final originalTotal = parseMoney(totals['saleAmount']);
    final surchargeTotal = parseMoney(totals['surchargeAmount']);
    final tipTotal = parseMoney(totals['tipAdjustAmount']);
    final refundTotal = parseMoney(totals['refundAmount']);
    final finalTotal = parseMoney(totals['netAmount']);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        build: (_) {
          final widgets = <pw.Widget>[
            for (var i = 0; i < reportBlankLinesTopBottom; i++)
              pw.SizedBox(height: reportBlankLineHeight),
            pw.Center(
              child: pw.Text(
                'OPEN BATCH REPORT',
                style: pw.TextStyle(
                  fontSize: reportTitleFontSize,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              'Terminal: $_terminalName',
              style: const pw.TextStyle(fontSize: reportSummaryFontSize),
            ),
            pw.Text(
              'Location: $_locationName',
              style: const pw.TextStyle(fontSize: reportSummaryFontSize),
            ),
            pw.Text(
              'Printed: ${now.toLocal()}',
              style: const pw.TextStyle(fontSize: reportSummaryFontSize),
            ),
            pw.SizedBox(height: 6),
            pw.Divider(),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Approved: ${approvedRows.length}',
                  style: const pw.TextStyle(fontSize: reportSummaryFontSize),
                ),
                pw.Text(
                  'Refunds: ${refundRows.length}',
                  style: const pw.TextStyle(fontSize: reportSummaryFontSize),
                ),
                pw.Text(
                  'Voided: ${voidedRows.length}',
                  style: const pw.TextStyle(fontSize: reportSummaryFontSize),
                ),
                pw.Text(
                  'Final: \$${finalTotal.toStringAsFixed(2)}',
                  style: pw.TextStyle(
                    fontSize: reportSummaryFontSize,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Original: \$${originalTotal.toStringAsFixed(2)}',
                  style: const pw.TextStyle(fontSize: reportSummaryFontSize),
                ),
                pw.Text(
                  'Tips: \$${tipTotal.toStringAsFixed(2)}',
                  style: const pw.TextStyle(fontSize: reportSummaryFontSize),
                ),
                pw.Text(
                  'Surcharge: \$${surchargeTotal.toStringAsFixed(2)}',
                  style: const pw.TextStyle(fontSize: reportSummaryFontSize),
                ),
                pw.Text(
                  'Refund: -\$${refundTotal.toStringAsFixed(2)}',
                  style: const pw.TextStyle(fontSize: reportSummaryFontSize),
                ),
              ],
            ),
            pw.Divider(),
          ];

          for (final row in reportRows) {
            final isVoided = row['status'] == 'voided';
            final isRefund = row['subtype']?.toString() == 'r';
            final amount =
                ((row['display_amount'] ?? row['amount']) as num?)
                    ?.toDouble()
                    .abs() ??
                0;
            final originalAmount =
                (row['amount'] as num?)?.toDouble().abs() ?? 0;
            final surchargeAmount =
                ((row['surcharge_amount'] as num?)?.toDouble() ?? 0).abs();
            final tipAdjustmentTotal =
                (row['tip_adjustment_total'] as num?)?.toDouble() ?? 0;
            final cardType =
                (isVoided ? row['voided_card_type'] : row['card_type'])
                    ?.toString() ??
                'Card';
            final last4 =
                (isVoided ? row['voided_card_last4'] : row['card_last4'])
                    ?.toString() ??
                '';
            final txnSeq = row['txn_seq']?.toString().trim() ?? '';
            final authCode =
                (isVoided ? row['voided_auth_code'] : row['auth_code'])
                    ?.toString() ??
                '';
            final invoiceReference =
                row['invoice_reference']?.toString().trim() ?? '';
            final cardholderName =
                (isVoided
                        ? row['voided_cardholder_name']
                        : row['cardholder_name'])
                    ?.toString()
                    .trim() ??
                '';
            final createdAt = row['created_at'] != null
                ? DateTime.tryParse(row['created_at'].toString())?.toLocal()
                : null;
            final transactionDateStr = createdAt != null
                ? _formatDateTimeForReport(createdAt)
                : '';

            widgets.add(
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    '${isVoided
                        ? '[VOIDED] '
                        : isRefund
                        ? '[REFUND] '
                        : ''}\$${amount.toStringAsFixed(2)}  $cardType${last4.isNotEmpty ? ' ****$last4' : ''}',
                    style: pw.TextStyle(
                      fontSize: reportRowTitleFontSize,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (transactionDateStr.isNotEmpty || authCode.isNotEmpty)
                    pw.Text(
                      [
                        if (transactionDateStr.isNotEmpty)
                          'Transaction Date: $transactionDateStr',
                        if (authCode.isNotEmpty) 'Auth: $authCode',
                      ].join('  '),
                      style: const pw.TextStyle(
                        fontSize: reportRowDetailFontSize,
                      ),
                    ),
                  if (!isVoided && !isRefund)
                    pw.Text(
                      'Transaction #: ${txnSeq.isNotEmpty ? txnSeq : 'N/A'}',
                      style: const pw.TextStyle(
                        fontSize: reportRowDetailFontSize,
                      ),
                    ),
                  if (!isVoided && !isRefund)
                    pw.Text(
                      'Original Transaction Amount: \$${originalAmount.toStringAsFixed(2)}',
                      style: const pw.TextStyle(
                        fontSize: reportRowDetailFontSize,
                      ),
                    ),
                  if (!isVoided && !isRefund && surchargeAmount > 0)
                    pw.Text(
                      'Surcharge: \$${surchargeAmount.toStringAsFixed(2)}',
                      style: const pw.TextStyle(
                        fontSize: reportRowDetailFontSize,
                      ),
                    ),
                  if (cardholderName.isNotEmpty)
                    pw.Text(
                      'Cardholder: $cardholderName',
                      style: const pw.TextStyle(
                        fontSize: reportRowDetailFontSize,
                      ),
                    ),
                  if (invoiceReference.isNotEmpty)
                    pw.Text(
                      'Invoice/Reference: $invoiceReference',
                      style: const pw.TextStyle(
                        fontSize: reportRowDetailFontSize,
                      ),
                    ),
                  if (!isVoided && !isRefund && tipAdjustmentTotal > 0)
                    pw.Text(
                      'Includes Tip Adjustment: +\$${tipAdjustmentTotal.toStringAsFixed(2)}',
                      style: const pw.TextStyle(
                        fontSize: reportRowDetailFontSize,
                      ),
                    ),
                  pw.Text(
                    'Processor Ref: ${(row['reference_id'] ?? row['id']).toString()}',
                    style: const pw.TextStyle(
                      fontSize: reportRowDetailFontSize,
                    ),
                  ),
                  pw.SizedBox(height: 4),
                ],
              ),
            );
          }

          widgets.add(pw.Divider());
          for (var i = 0; i < 6; i++) {
            widgets.add(pw.SizedBox(height: reportBlankLineHeight));
          }
          widgets.add(
            pw.Center(
              child: pw.Text(
                'END OF OPEN BATCH REPORT',
                style: const pw.TextStyle(fontSize: reportRowDetailFontSize),
              ),
            ),
          );
          for (var i = 0; i < reportBlankLinesTopBottom; i++) {
            widgets.add(pw.SizedBox(height: reportBlankLineHeight));
          }
          return widgets;
        },
      ),
    );

    return pdf.save();
  }

  Future<void> _showOpenBatchPrintPreview() async {
    if (!mounted) return;
    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: (MediaQuery.of(dialogContext).size.width - 24).clamp(
            280.0,
            420.0,
          ),
          height: 700,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: 'Do Not Print',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PdfPreview(
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  maxPageWidth: 320,
                  initialPageFormat: receiptFormat,
                  build: (format) =>
                      _buildOpenBatchReportPdfBytes(receiptFormat),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDateTimeForReport(DateTime dateTime) {
    final local = dateTime.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final yyyy = local.year.toString().padLeft(4, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    final sec = local.second.toString().padLeft(2, '0');
    return '$mm/$dd/$yyyy $hh:$min:$sec';
  }

  Map<String, dynamic> _buildBatchCloseReportPayload({
    required bool accepted,
    required String processorStatus,
    required String processorMessage,
    required DateTime closedAt,
    required List<Map<String, dynamic>> batchRows,
  }) {
    int intOf(dynamic value) {
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    double doubleOf(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0.0;
    }

    final snapshot = _transactionSyncService.buildOpenBatchIntegritySnapshot(
      batchRows,
    );
    final totals = Map<String, dynamic>.from(
      snapshot['totals'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    );

    final approvedCount = intOf(totals['approvedCount']);
    final voidedCount = intOf(totals['voidedCount']);
    final salesWithTipCount = intOf(totals['salesWithTipCount']);
    final refundCount = intOf(totals['refundCount']);
    final voidCount = intOf(totals['voidCount']);
    final salesWithTipAmount = doubleOf(totals['salesWithTipAmount']);
    final refundSignedAmount = doubleOf(totals['refundSignedAmount']);
    final voidSignedAmount = doubleOf(totals['voidSignedAmount']);
    final netAmount = doubleOf(totals['netAmount']);
    final saleAmount = doubleOf(totals['saleAmount']);
    final tipAdjustAmount = doubleOf(totals['tipAdjustAmount']);
    final totalAmount = netAmount;
    final activeLicense = LicenseService().activeContext;
    final organizationName = activeLicense?.organizationName ?? '';
    final organizationNumber = activeLicense?.organizationNumber ?? '';

    final transactions = batchRows.map((row) {
      final amount = (row['amount'] is num)
          ? (row['amount'] as num).toDouble()
          : 0;
      final feeAmount = (row['fee_amount'] is num)
          ? (row['fee_amount'] as num).toDouble()
          : 0;
      return {
        'id': row['id']?.toString() ?? '',
        'transactionHeaderId': row['transaction_header_id']?.toString() ?? '',
        'amount': amount,
        'feeAmount': feeAmount,
        'cardType': row['card_type']?.toString() ?? '',
        'cardLast4': row['card_last4']?.toString() ?? '',
        'authCode': row['auth_code']?.toString() ?? '',
        'invoiceReference': row['invoice_reference']?.toString() ?? '',
        'referenceId': row['reference_id']?.toString() ?? '',
        'status': row['status']?.toString() ?? '',
        'subtype': row['subtype']?.toString() ?? '',
        'createdAt': row['created_at']?.toString() ?? '',
        'transactionDate': row['created_at']?.toString() ?? '',
        'closeStatus': accepted ? 'Accepted' : 'Not Accepted',
      };
    }).toList();

    return {
      'version': 2,
      'reportType': 'batch_close',
      'header': {
        'accepted': accepted,
        'processorStatus': processorStatus,
        'processorMessage': processorMessage,
        'terminalName': _terminalName,
        'locationName': _locationName,
        'organizationName': organizationName,
        'organizationNumber': organizationNumber,
        'closedAt': closedAt.toUtc().toIso8601String(),
        'approvedCount': approvedCount,
        'voidedCount': voidedCount,
        'transactionCount': batchRows.length,
        'salesWithTipCount': salesWithTipCount,
        'refundCount': refundCount,
        'voidCount': voidCount,
        'salesWithTipAmount': salesWithTipAmount,
        'refundSignedAmount': refundSignedAmount,
        'voidSignedAmount': voidSignedAmount,
        'netAmount': netAmount,
        'originalTotal': saleAmount,
        'tipTotal': tipAdjustAmount,
        'finalTotal': netAmount,
        'totalAmount': totalAmount,
      },
      'transactions': transactions,
    };
  }

  Future<Uint8List> _buildBatchCloseReportPdfBytes(
    PdfPageFormat format,
    Map<String, dynamic> report,
  ) async {
    final pdf = pw.Document();
    final header = Map<String, dynamic>.from(
      report['header'] as Map<String, dynamic>? ?? <String, dynamic>{},
    );
    final transactions = (report['transactions'] as List? ?? const <dynamic>[])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();

    final closedAt = DateTime.tryParse(header['closedAt']?.toString() ?? '');
    final accepted = header['accepted'] == true;
    final integrityStatus = header['integrityStatus']?.toString() ?? '';
    final integritySummary = header['integritySummary']?.toString() ?? '';

    pdf.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        build: (_) {
          final widgets = <pw.Widget>[
            pw.Center(
              child: pw.Text(
                'BATCH CLOSE REPORT',
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              'Close Status: ${header['processorStatus'] ?? (accepted ? 'Accepted' : 'Not Accepted')}',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              'Processor Message: ${header['processorMessage'] ?? ''}',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Organization: ${header['organizationName'] ?? ''}${(header['organizationNumber']?.toString().isNotEmpty ?? false) ? ' (${header['organizationNumber']})' : ''}',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            pw.Text(
              'Location: ${header['locationName'] ?? ''}',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            pw.Text(
              'Terminal: ${header['terminalName'] ?? ''}',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            pw.Text(
              'Close Time: ${closedAt != null ? _formatDateTimeForReport(closedAt) : (header['closedAt'] ?? '')}',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            if (integrityStatus.isNotEmpty)
              pw.Text(
                'Integrity: $integrityStatus${integritySummary.isNotEmpty ? ' — $integritySummary' : ''}',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            pw.SizedBox(height: 6),
            pw.Divider(),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Approved: ${header['approvedCount'] ?? 0}',
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
                pw.Text(
                  'Voided: ${header['voidedCount'] ?? 0}',
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
                pw.Text(
                  'Total: \$${((header['totalAmount'] is num) ? (header['totalAmount'] as num).toDouble() : 0).toStringAsFixed(2)}',
                  style: pw.TextStyle(
                    fontSize: 8.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (header['salesWithTipAmount'] != null ||
                header['refundSignedAmount'] != null ||
                header['voidSignedAmount'] != null)
              pw.Text(
                'Sales+Surch+Tip: \$${((header['salesWithTipAmount'] is num) ? (header['salesWithTipAmount'] as num).toDouble() : 0).toStringAsFixed(2)}   '
                'Refunds: ${((header['refundSignedAmount'] is num) ? (header['refundSignedAmount'] as num).toDouble() : 0).toStringAsFixed(2)}   '
                'Voids: ${((header['voidSignedAmount'] is num) ? (header['voidSignedAmount'] as num).toDouble() : 0).toStringAsFixed(2)}',
                style: const pw.TextStyle(fontSize: 8.2),
              ),
            pw.Divider(),
          ];

          for (final row in transactions) {
            final rawAmount =
                ((row['amount'] is num) ? (row['amount'] as num).toDouble() : 0)
                    .abs();
            final feeAmount =
                ((row['feeAmount'] is num)
                        ? (row['feeAmount'] as num).toDouble()
                        : 0)
                    .abs();
            final subtype = (row['subtype']?.toString().toLowerCase() ?? '')
                .trim();
            final amount = (subtype == 'r' || subtype == 'v')
                ? -rawAmount
                : rawAmount;
            final cardType = row['cardType']?.toString() ?? 'Card';
            final last4 = row['cardLast4']?.toString() ?? '';
            final authCode = row['authCode']?.toString() ?? '';
            final invoiceReference =
                row['invoiceReference']?.toString().trim() ?? '';
            final processorReference =
                row['referenceId']?.toString().trim() ?? '';
            final localStatus = row['status']?.toString() ?? '';
            final closeStatus = row['closeStatus']?.toString() ?? '';
            final createdAt = DateTime.tryParse(
              (row['transactionDate'] ?? row['createdAt'])?.toString() ?? '',
            );
            final transactionDateStr = createdAt != null
                ? _formatDateTimeForReport(createdAt.toLocal())
                : '';

            widgets.add(
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    '\$${amount.toStringAsFixed(2)}  $cardType${last4.isNotEmpty ? ' ****$last4' : ''}',
                    style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'Close: $closeStatus   Local: ${localStatus.isEmpty ? 'unknown' : localStatus}${transactionDateStr.isNotEmpty ? '   Transaction Date: $transactionDateStr' : ''}${authCode.isNotEmpty ? '   Auth: $authCode' : ''}',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                  if (feeAmount > 0)
                    pw.Text(
                      'Surcharge: \$${feeAmount.toStringAsFixed(2)}',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  if (invoiceReference.isNotEmpty)
                    pw.Text(
                      'Invoice/Reference: $invoiceReference',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  if (processorReference.isNotEmpty)
                    pw.Text(
                      'Processor Ref: $processorReference',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  pw.SizedBox(height: 4),
                ],
              ),
            );
          }

          widgets.add(pw.Divider());
          widgets.add(
            pw.Center(
              child: pw.Text(
                'END OF BATCH CLOSE REPORT',
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          );

          return widgets;
        },
      ),
    );

    return pdf.save();
  }

  Future<void> _showBatchCloseReportPrintPreview(
    Map<String, dynamic> report,
  ) async {
    if (!mounted) return;
    const receiptFormat = PdfPageFormat(
      80 * PdfPageFormat.mm,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    );

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: (MediaQuery.of(dialogContext).size.width - 24).clamp(
            280.0,
            420.0,
          ),
          height: 700,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: 'Do Not Print',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PdfPreview(
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  maxPageWidth: 320,
                  initialPageFormat: receiptFormat,
                  build: (format) =>
                      _buildBatchCloseReportPdfBytes(receiptFormat, report),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPreviousBatchReportsDialog() async {
    var beginDate = DateTime.now().subtract(const Duration(days: 7));
    var endDate = DateTime.now();
    var loading = true;
    var integrityLoading = false;
    String? loadError;
    String? integrityMessage;
    List<Map<String, dynamic>> reports = const [];
    Map<String, dynamic>? selectedRow;
    final activeLicense = LicenseService().activeContext;

    IconData? integrityIconFor(String status) {
      switch (status) {
        case 'verified':
          return Icons.verified;
        case 'partial':
          return Icons.warning_amber_rounded;
        case 'failed':
          return Icons.error_outline;
        case 'unavailable':
          return Icons.info_outline;
      }
      return null;
    }

    Color integrityColorFor(BuildContext context, String status) {
      final cs = Theme.of(context).colorScheme;
      switch (status) {
        case 'verified':
          return Colors.blue;
        case 'partial':
          return Colors.orange;
        case 'failed':
          return cs.error;
        case 'unavailable':
          return cs.onSurfaceVariant;
      }
      return cs.onSurfaceVariant;
    }

    Future<void> loadReports(
      void Function(void Function()) setDialogState,
    ) async {
      setDialogState(() {
        loading = true;
        loadError = null;
      });
      try {
        final result = await _transactionSyncService
            .getBatchCloseReportsProcessorFirst(
              beginDate: beginDate,
              endDate: endDate,
              tpn: TerminalConfig.spinTpn,
              authKey: TerminalConfig.spinAuthKey,
              sandbox: SupabaseConfig.spinSandbox,
              terminalName: _terminalName,
              locationName: _locationName,
              organizationName: activeLicense?.organizationName ?? '',
              organizationNumber: activeLicense?.organizationNumber ?? '',
            );
        if (!mounted) return;
        setDialogState(() {
          reports = result;
          loading = false;
          integrityMessage = null;
          if (selectedRow != null &&
              !reports.any(
                (r) => r['id']?.toString() == selectedRow!['id']?.toString(),
              )) {
            selectedRow = null;
          }
        });
      } catch (error) {
        setDialogState(() {
          loading = false;
          loadError = error.toString();
        });
      }
    }

    Future<void> verifySelectedBatch(
      void Function(void Function()) setDialogState,
    ) async {
      if (selectedRow == null || integrityLoading) return;

      final report = Map<String, dynamic>.from(
        selectedRow!['report'] as Map<String, dynamic>? ??
            const <String, dynamic>{},
      );

      setDialogState(() {
        integrityLoading = true;
        integrityMessage = null;
      });

      final verifiedReport = await _transactionSyncService
          .verifyBatchReportIntegrity(
            report: report,
            tpn: TerminalConfig.spinTpn,
            authKey: TerminalConfig.spinAuthKey,
            sandbox: SupabaseConfig.spinSandbox,
          );

      if (!mounted) return;
      setDialogState(() {
        integrityLoading = false;
        integrityMessage = Map<String, dynamic>.from(
          verifiedReport['header'] as Map<String, dynamic>? ??
              const <String, dynamic>{},
        )['integritySummary']?.toString();

        final nextSelected = {...selectedRow!, 'report': verifiedReport};
        selectedRow = nextSelected;
        reports = reports.map((row) {
          if (row['id']?.toString() != nextSelected['id']?.toString()) {
            return row;
          }
          return {...row, 'report': verifiedReport};
        }).toList();
      });
    }

    Future<void> pickBeginDate(
      BuildContext dialogContext,
      void Function(void Function()) setDialogState,
    ) async {
      final picked = await showDatePicker(
        context: dialogContext,
        firstDate: DateTime(2020, 1, 1),
        lastDate: DateTime.now().add(const Duration(days: 365)),
        initialDate: beginDate,
      );
      if (picked == null) return;
      setDialogState(() {
        beginDate = picked;
        if (endDate.isBefore(beginDate)) {
          endDate = beginDate;
        }
      });
      await loadReports(setDialogState);
    }

    Future<void> pickEndDate(
      BuildContext dialogContext,
      void Function(void Function()) setDialogState,
    ) async {
      final picked = await showDatePicker(
        context: dialogContext,
        firstDate: DateTime(2020, 1, 1),
        lastDate: DateTime.now().add(const Duration(days: 365)),
        initialDate: endDate,
      );
      if (picked == null) return;
      setDialogState(() {
        endDate = picked;
        if (endDate.isBefore(beginDate)) {
          beginDate = endDate;
        }
      });
      await loadReports(setDialogState);
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (loading && reports.isEmpty && loadError == null) {
            unawaited(loadReports(setDialogState));
          }

          return AlertDialog(
            title: const Text('Print Previous Batch'),
            content: SizedBox(
              width: 720,
              height: 500,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => unawaited(
                            pickBeginDate(dialogContext, setDialogState),
                          ),
                          icon: const Icon(Icons.date_range),
                          label: Text(
                            'Begin: ${_formatDateTimeForReport(beginDate).split(' ').first}',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => unawaited(
                            pickEndDate(dialogContext, setDialogState),
                          ),
                          icon: const Icon(Icons.date_range),
                          label: Text(
                            'End: ${_formatDateTimeForReport(endDate).split(' ').first}',
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => unawaited(loadReports(setDialogState)),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: loading
                        ? const Center(child: CircularProgressIndicator())
                        : loadError != null
                        ? Align(
                            alignment: Alignment.topLeft,
                            child: Text('Failed to load reports: $loadError'),
                          )
                        : reports.isEmpty
                        ? const Align(
                            alignment: Alignment.topLeft,
                            child: Text(
                              'No batch-close reports found for the selected date range.\n\nPrevious Batch now reads from card_batch_headers and card_batch_details records created at close time.',
                            ),
                          )
                        : ListView.separated(
                            itemCount: reports.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final row = reports[index];
                              final report = Map<String, dynamic>.from(
                                row['report'] as Map<String, dynamic>? ??
                                    const <String, dynamic>{},
                              );
                              final header = Map<String, dynamic>.from(
                                report['header'] as Map<String, dynamic>? ??
                                    const <String, dynamic>{},
                              );
                              final closedAt = DateTime.tryParse(
                                header['closedAt']?.toString() ?? '',
                              );
                              final selected =
                                  selectedRow?['id']?.toString() ==
                                  row['id']?.toString();
                              final totalAmount = (header['totalAmount'] is num)
                                  ? (header['totalAmount'] as num).toDouble()
                                  : 0;
                              final batchNumber =
                                  header['batchNumber']?.toString() ?? '';
                              final integrityStatus =
                                  header['integrityStatus']?.toString() ?? '';
                              final integrityIcon = integrityIconFor(
                                integrityStatus,
                              );
                              final reportTransactions =
                                  (report['transactions'] as List? ??
                                          const <dynamic>[])
                                      .whereType<Map>()
                                      .map(
                                        (entry) =>
                                            Map<String, dynamic>.from(entry),
                                      )
                                      .toList();
                              DateTime? latestTransactionDate;
                              for (final transaction in reportTransactions) {
                                final parsed = DateTime.tryParse(
                                  (transaction['transactionDate'] ??
                                              transaction['createdAt'])
                                          ?.toString() ??
                                      '',
                                )?.toLocal();
                                if (parsed == null) continue;
                                if (latestTransactionDate == null ||
                                    parsed.isAfter(latestTransactionDate)) {
                                  latestTransactionDate = parsed;
                                }
                              }

                              return ListTile(
                                selected: selected,
                                selectedTileColor: Theme.of(
                                  context,
                                ).colorScheme.primaryContainer.withAlpha(80),
                                onTap: () {
                                  setDialogState(() {
                                    selectedRow = row;
                                  });
                                },
                                title: Text(
                                  '${batchNumber.isNotEmpty ? 'Batch #$batchNumber • ' : ''}${header['processorStatus'] ?? 'Batch Close'}  •  \$${totalAmount.toStringAsFixed(2)}',
                                ),
                                subtitle: Text(
                                  'Closed: ${closedAt != null ? _formatDateTimeForReport(closedAt) : (header['closedAt'] ?? row['created_at'] ?? '')}\n'
                                  'Terminal: ${header['terminalName'] ?? ''}   Location: ${header['locationName'] ?? ''}\n'
                                  'Latest Transaction Date: ${latestTransactionDate != null ? _formatDateTimeForReport(latestTransactionDate) : 'N/A'}',
                                ),
                                trailing: integrityIcon == null
                                    ? null
                                    : Icon(
                                        integrityIcon,
                                        color: integrityColorFor(
                                          context,
                                          integrityStatus,
                                        ),
                                      ),
                                isThreeLine: true,
                              );
                            },
                          ),
                  ),
                  if (selectedRow != null) ...[
                    const SizedBox(height: 10),
                    Builder(
                      builder: (context) {
                        final selectedReport = Map<String, dynamic>.from(
                          selectedRow!['report'] as Map<String, dynamic>? ??
                              const <String, dynamic>{},
                        );
                        final selectedHeader = Map<String, dynamic>.from(
                          selectedReport['header'] as Map<String, dynamic>? ??
                              const <String, dynamic>{},
                        );
                        final integrityStatus =
                            selectedHeader['integrityStatus']?.toString() ?? '';
                        final integritySummary =
                            integrityMessage ??
                            selectedHeader['integritySummary']?.toString() ??
                            'Processor integrity has not been checked for this batch yet.';
                        final icon = integrityIconFor(integrityStatus);
                        return Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (integrityLoading)
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else if (icon != null)
                                Icon(
                                  icon,
                                  color: integrityColorFor(
                                    context,
                                    integrityStatus,
                                  ),
                                  size: 18,
                                )
                              else
                                Icon(
                                  Icons.help_outline,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                  size: 18,
                                ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  integritySummary,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              if (loadError != null)
                TextButton.icon(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(
                      ClipboardData(
                        text:
                            'Print Previous Batch\n\nFailed to load reports: $loadError',
                      ),
                    );
                    if (!mounted) return;
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Error copied.')),
                    );
                  },
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy Error'),
                ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
              OutlinedButton(
                onPressed: selectedRow == null || integrityLoading
                    ? null
                    : () => unawaited(verifySelectedBatch(setDialogState)),
                child: const Text('Verify Integrity'),
              ),
              FilledButton(
                onPressed: selectedRow == null
                    ? null
                    : () => unawaited(
                        _showBatchCloseReportPrintPreview(
                          Map<String, dynamic>.from(
                            selectedRow!['report'] as Map<String, dynamic>,
                          ),
                        ),
                      ),
                child: const Text('Preview & Print'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _keypadCursorTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() {
        _showKeypadCursor = !_showKeypadCursor;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(_focusNode);
      unawaited(_checkTenantScope());
      unawaited(_announceCardRouteOnStartup());
      unawaited(_loadTransactionFlowParameters());
      unawaited(_refreshActiveHeaderBatchNumber());
      unawaited(_loadOpenBatch());
      unawaited(_runAutoCloseBatchCheck());
      unawaited(_warmUpCardTerminalIfNeeded());
    });
    _autoCloseTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_runAutoCloseBatchCheck());
    });
  }

  ({int hour, int minute})? _parseMilitaryTime(String input) {
    final normalized = input.trim();
    if (normalized.isEmpty) return null;
    final match = RegExp(
      r'^(\d{1,2}):(\d{2})(?::\d{2})?$',
    ).firstMatch(normalized);
    if (match == null) return null;
    final hour = int.tryParse(match.group(1)!);
    final minute = int.tryParse(match.group(2)!);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return (hour: hour, minute: minute);
  }

  Future<void> _runAutoCloseBatchCheck() async {
    if (!mounted || _autoCloseInFlight) return;
    _autoCloseInFlight = true;
    try {
      final settings = await _transactionSyncService
          .getTerminalAutoCloseBatchSettings();
      if (settings == null || !settings.enabled) return;

      final parsed = _parseMilitaryTime(settings.time24h);
      if (parsed == null) return;

      final now = DateTime.now();
      final scheduledToday = DateTime(
        now.year,
        now.month,
        now.day,
        parsed.hour,
        parsed.minute,
      );
      if (now.isBefore(scheduledToday)) return;

      final ctx = LicenseService().activeContext;
      if (ctx == null || ctx.organizationId.isEmpty || ctx.terminalId.isEmpty) {
        return;
      }

      final runKey =
          'auto_close_done_${ctx.organizationId}_${ctx.terminalId}_${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(runKey) == true) return;

      await _loadOpenBatch();
      final openCount = _openBatchCards
          .where((r) => r['status'] == 'approved')
          .length;
      if (openCount == 0) {
        await prefs.setBool(runKey, true);
        return;
      }

      final closed = await _closeBatch(skipConfirm: true, isAutoClose: true);
      if (closed) {
        await prefs.setBool(runKey, true);
      }
    } catch (_) {
      // Keep startup resilient; failures are retried on the next timer tick.
    } finally {
      _autoCloseInFlight = false;
    }
  }

  String _buildTerminalWarmUpRunKey(DateTime now) {
    final ctx = LicenseService().activeContext;
    final orgPart = (ctx?.organizationId ?? 'org').replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '_',
    );
    final terminalSource = (ctx?.terminalId ?? '').isNotEmpty
        ? ctx!.terminalId
        : TerminalConfig.spinTpn;
    final terminalPart =
        (terminalSource.isNotEmpty ? terminalSource : 'terminal').replaceAll(
          RegExp(r'[^A-Za-z0-9_-]'),
          '_',
        );
    final dayStamp =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    return 'terminal_warmup_done_${orgPart}_${terminalPart}_$dayStamp';
  }

  Future<bool> _warmUpCardTerminalIfNeeded({bool force = false}) async {
    if (!_enableCardTerminalWarmup) {
      return true;
    }

    if (!TerminalConfig.hasPhysicalCardReader) {
      return true;
    }

    if (!TerminalConfig.isPaymentConfigured) {
      // Let normal card-flow validation handle missing terminal credentials.
      return true;
    }

    if (_terminalWarmingUp) {
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    final runKey = _buildTerminalWarmUpRunKey(DateTime.now());

    if (_forceFirstStartOfDayWarmup) {
      await prefs.remove(runKey);
    }

    if (!force && prefs.getBool(runKey) == true) {
      return true;
    }

    final warmed = await _warmUpCardTerminal();
    if (warmed) {
      await prefs.setBool(runKey, true);
    }
    return warmed;
  }

  Future<bool> _runWarmUpPrimeSale(DejavooService service) async {
    final referenceId =
        'WARMUP-${DateTime.now().millisecondsSinceEpoch}-${TerminalConfig.spinTpn}';

    // Trigger one payment flow at startup so key injection/restart occurs
    // before any customer sale. We auto-cancel to avoid waiting for user input.
    final abortTimer = Timer(const Duration(seconds: 8), () {
      unawaited(service.cancel());
    });

    try {
      final result = await service
          .sale(amount: 0.01, referenceId: referenceId)
          .timeout(
            const Duration(seconds: 35),
            onTimeout: () {
              unawaited(service.cancel());
              return DejavooSaleResult.cancelled();
            },
          );

      final message = result.message.toLowerCase();
      final likelyConnectivityIssue =
          message.contains('network error') || message.contains('timed out');

      return !likelyConnectivityIssue;
    } catch (_) {
      return false;
    } finally {
      abortTimer.cancel();
      await service.setDeviceReadyForNextTransaction();
      await Future<void>.delayed(const Duration(seconds: 2));
      await service.showDeviceMessage(message: 'Ready');
    }
  }

  /// Warms up the card terminal at startup so injection key downloads happen
  /// now, before the first customer transaction. It runs a short prime-sale
  /// call that is auto-cancelled so any one-time key-injection restart is
  /// absorbed during startup instead of during the first customer payment.
  /// Shows a banner while waiting and sets a 90-second safety timeout so the
  /// UI never stays locked indefinitely.
  Future<bool> _warmUpCardTerminal() async {
    if (!TerminalConfig.isPaymentConfigured) return true;
    if (mounted) setState(() => _terminalWarmingUp = true);
    var warmed = false;
    // Safety: clear the banner after 90 s no matter what.
    final safetyTimer = Timer(const Duration(seconds: 90), () {
      if (mounted) setState(() => _terminalWarmingUp = false);
    });
    try {
      final service = DejavooService(
        tpn: TerminalConfig.spinTpn,
        authKey: TerminalConfig.spinAuthKey,
        sandbox: SupabaseConfig.spinSandbox,
        requestProcessorSurcharge: false,
      );
      await service.showDeviceMessage(message: 'Starting PaaayIT...');
      warmed = await _runWarmUpPrimeSale(service);
    } catch (_) {
      // Best-effort — never block or surface startup errors from this.
    } finally {
      safetyTimer.cancel();
      if (mounted) setState(() => _terminalWarmingUp = false);
    }
    return warmed;
  }

  Future<void> _checkTenantScope() async {
    _transactionSyncService.clearTenantScopeCache();
    final startupContext = Map<String, String>.from(
      await _transactionSyncService.getStartupContext(),
    );

    final override = widget.startupContextOverride;
    if (override != null && override.isNotEmpty) {
      startupContext.addAll(override);
    }

    if (!mounted) return;
    final gratuityFlag =
        startupContext['gratuityEnabled'] ??
        startupContext['tipAdjustEnabled'] ??
        startupContext['allowGratuityAdjustments'] ??
        startupContext['allowTipAdjustments'] ??
        startupContext['allow_tip_adjustments'] ??
        '';
    setState(() {
      _terminalName = startupContext['terminalName'] ?? _terminalName;
      _staffName = startupContext['staffName'] ?? _staffName;
      _locationName = startupContext['locationName'] ?? _locationName;
      _locationAddress1 =
          startupContext['locationAddress1'] ?? _locationAddress1;
      _locationAddress2 =
          startupContext['locationAddress2'] ?? _locationAddress2;
      _locationCity = startupContext['locationCity'] ?? _locationCity;
      _locationState = startupContext['locationState'] ?? _locationState;
      _locationZip = startupContext['locationZip'] ?? _locationZip;
      _locationPhone = startupContext['locationPhone'] ?? _locationPhone;
      _printTipSuggestions = _parseStartupBool(
        startupContext['printTipSuggestions'],
        fallback: _printTipSuggestions,
      );
      _tipSuggestion1Pct = _parseStartupDouble(
        startupContext['tipSuggestion1Pct'],
        _tipSuggestion1Pct,
      );
      _tipSuggestion2Pct = _parseStartupDouble(
        startupContext['tipSuggestion2Pct'],
        _tipSuggestion2Pct,
      );
      _tipSuggestion3Pct = _parseStartupDouble(
        startupContext['tipSuggestion3Pct'],
        _tipSuggestion3Pct,
      );
      _tipSuggestionBase = _normalizeTipSuggestionBase(
        startupContext['tipSuggestionBase'],
      );
      _receiptCardSignatureMessage =
          startupContext['receiptCardSignatureMessage'] ??
          _receiptCardSignatureMessage;
      _receiptMiscMessage =
          startupContext['receiptMiscMessage'] ?? _receiptMiscMessage;
      _defaultReceiptPrinter =
          startupContext['defaultReceiptPrinter'] ?? _defaultReceiptPrinter;
      if (gratuityFlag.trim().isNotEmpty) {
        final normalized = gratuityFlag.trim().toLowerCase();
        _isGratuityAdjustEnabled =
            normalized == 'true' ||
            normalized == '1' ||
            normalized == 'yes' ||
            normalized == 'y';
      }
    });

    final resolvedAllowTips = _isGratuityAdjustEnabled ? 'true' : 'false';
    debugPrint(
      '[StartupContext] location="${startupContext['locationName'] ?? ''}" '
      'allow_tip_adjustments=$gratuityFlag '
      'resolved_allow_tip_adjustments=$resolvedAllowTips',
    );

    if (mounted && SupabaseConfig.debugMode) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Startup: allow_tip_adjustments=$gratuityFlag '
            '-> resolved=$resolvedAllowTips',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _ensureTerminalConfigResolvedForSession({
    bool forceRefresh = false,
  }) async {
    final context = LicenseService().activeContext;
    final terminalId = (context?.terminalId ?? '').trim();
    final terminalNumber = (context?.terminalNumber ?? '').trim();
    if (terminalId.isEmpty) return;

    final terminalChanged = _resolvedTerminalConfigId != terminalId;
    if (!forceRefresh && !terminalChanged) return;

    await TerminalConfig.loadForTerminalId(
      terminalId,
      terminalNumber: terminalNumber,
      forceRefresh: forceRefresh || terminalChanged,
    );
    _resolvedTerminalConfigId = terminalId;
  }

  Future<void> _announceCardRouteOnStartup() async {
    if (_startupCardRouteShown) return;

    await _ensureTerminalConfigResolvedForSession(forceRefresh: true);
    if (!mounted) return;

    final activeCtx = LicenseService().activeContext;
    final terminalNumber = (activeCtx?.terminalNumber ?? '').trim();
    final terminalName = (activeCtx?.terminalName ?? '').trim();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Startup card route: ${TerminalConfig.cardReaderType} '
          '(physical=${TerminalConfig.hasPhysicalCardReader}) '
          '| terminal: ${terminalNumber.isNotEmpty ? terminalNumber : 'unknown'}'
          '${terminalName.isNotEmpty ? ' - $terminalName' : ''}',
        ),
        duration: const Duration(seconds: 4),
      ),
    );

    debugPrint(
      '[CardFlow][Startup] terminalNumber=$terminalNumber terminalName=$terminalName '
      'cardReaderType=${TerminalConfig.cardReaderType} hasPhysical=${TerminalConfig.hasPhysicalCardReader}',
    );

    _startupCardRouteShown = true;
  }

  Future<void> _loadTransactionFlowParameters() async {
    final params = await TransactionFlowParameters.load();
    if (!mounted) return;
    setState(() {
      _transactionFlowParameters = params;
    });
  }

  @override
  void dispose() {
    _keypadCursorTimer?.cancel();
    _autoCloseTimer?.cancel();
    _batchReconcileDebounceTimer?.cancel();
    _focusNode.dispose();
    _customerNumberController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _address1Controller.dispose();
    _address2Controller.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _zipController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _messageBoxController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _append(String s) {
    if (!RegExp(r'^\d$').hasMatch(s)) return;
    setState(() {
      final currentCents = _currentInput.isEmpty
          ? 0
          : ((double.tryParse(_currentInput) ?? 0) * 100).round();
      final nextCents = (currentCents * 10) + int.parse(s);
      _currentInput = (nextCents / 100).toStringAsFixed(2);
    });
  }

  void _backspace() {
    setState(() {
      final currentCents = _currentInput.isEmpty
          ? 0
          : ((double.tryParse(_currentInput) ?? 0) * 100).round();
      if (currentCents <= 0) return;
      final nextCents = currentCents ~/ 10;
      _currentInput = nextCents == 0
          ? ''
          : (nextCents / 100).toStringAsFixed(2);
    });
  }

  void _clearCurrentInput() {
    setState(() {
      _currentInput = '';
    });
  }

  String _formatAmountForDisplay(String rawAmount) {
    final parsed = double.tryParse(rawAmount);
    if (parsed == null) return rawAmount;

    final normalized = parsed.toStringAsFixed(2);
    final parts = normalized.split('.');
    final whole = parts[0].replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    final fractional = parts.length > 1 ? parts[1] : '00';
    return '$whole.$fractional';
  }

  Future<String?> _promptForReceiptDescription() async {
    _descriptionController.clear();

    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Receipt Description'),
        content: TextField(
          controller: _descriptionController,
          autofocus: true,
          maxLength: 120,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          decoration: const InputDecoration(
            labelText: 'Description',
            border: OutlineInputBorder(),
            isDense: true,
            counterText: '',
          ),
          onSubmitted: (_) {
            Navigator.of(dialogContext).pop(_descriptionController.text.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(_descriptionController.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _addItem() async {
    final rawSku = _currentInput.trim();
    final isAccountPayment = rawSku.isEmpty;
    final itemSku = isAccountPayment ? 1.0 : double.tryParse(rawSku);

    if (!isAccountPayment && (itemSku == null || itemSku <= 0)) return;

    final description = await _promptForReceiptDescription();
    if (description == null) return;

    setState(() {
      _items.add(itemSku!);
      _itemTaxes.add(0.0);
      _receiptEntries.add(
        _ReceiptItemEntry(
          itemSku: itemSku,
          description: description,
          skuLabel: isAccountPayment ? '0001' : null,
        ),
      );
      _currentInput = '';
      _descriptionController.clear();
    });
  }

  void _clearItems({bool clearCustomerInfo = false}) {
    setState(() {
      _items.clear();
      _itemTaxes.clear();
      _receiptEntries.clear();
      _paymentHistory.clear();
      _cardPaymentDetails.clear();
      _currentInput = '';
      _cashPaid = 0;
      _descriptionController.clear();
      _lastReceiptIdDisplay = '';

      if (clearCustomerInfo) {
        _clearCustomerForm();
        _messageBoxController.clear();
        _invoiceReference = '';
        _postedCustomerNumber = '';
        _postedFullName = '';
        _postedAddress1 = '';
        _postedAddress2 = '';
        _postedCityStateZip = '';
        _postedPhone = '';
        _postedEmail = '';
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(_focusNode);
    });
  }

  Future<double?> _promptCashTenderedAmount() async {
    final amountDue = _balance > 0 ? _balance : 0.0;
    final cashController = TextEditingController(
      text: amountDue.toStringAsFixed(2),
    );
    cashController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: cashController.text.length,
    );
    bool overwriteOnNextInput = true;
    String? inputError;

    final amount = await showDialog<double>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final addCashTextColor = Theme.of(context).colorScheme.primary;

          void setCaretToEnd() {
            cashController.selection = TextSelection.collapsed(
              offset: cashController.text.length,
            );
          }

          void appendDigit(String digit) {
            setDialogState(() {
              final baseCents = overwriteOnNextInput
                  ? 0
                  : ((double.tryParse(cashController.text.trim()) ?? 0) * 100)
                        .round();
              final nextCents = (baseCents * 10) + int.parse(digit);
              cashController.text = (nextCents / 100).toStringAsFixed(2);
              overwriteOnNextInput = false;
              inputError = null;
              setCaretToEnd();
            });
          }

          void backspace() {
            setDialogState(() {
              final currentCents =
                  ((double.tryParse(cashController.text.trim()) ?? 0) * 100)
                      .round();
              if (currentCents <= 0) {
                cashController.text = '0.00';
                overwriteOnNextInput = true;
                inputError = null;
                setCaretToEnd();
                return;
              }
              final nextCents = currentCents ~/ 10;
              cashController.text = (nextCents / 100).toStringAsFixed(2);
              overwriteOnNextInput = false;
              inputError = null;
              setCaretToEnd();
            });
          }

          void clearAmount() {
            setDialogState(() {
              cashController.text = '0.00';
              overwriteOnNextInput = true;
              inputError = null;
              setCaretToEnd();
            });
          }

          void submitAmount() {
            final parsed = double.tryParse(cashController.text.trim());
            if (parsed == null || parsed <= 0) {
              setDialogState(() {
                inputError = 'Enter a valid payment amount.';
              });
              return;
            }
            Navigator.of(dialogContext).pop(parsed);
          }

          const cashPadButtons = [
            '7',
            '8',
            '9',
            '4',
            '5',
            '6',
            '1',
            '2',
            '3',
            'Clear',
            '0',
            '<',
          ];

          Widget buildPadButton(String value) {
            final isClear = value == 'Clear';
            final isBackspace = value == '<';
            return Padding(
              padding: const EdgeInsets.all(2),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isClear
                      ? _themeRed
                      : isBackspace
                      ? _themeYellow
                      : null,
                ),
                onPressed: () {
                  if (isBackspace) {
                    backspace();
                    return;
                  }
                  if (isClear) {
                    clearAmount();
                    return;
                  }
                  appendDigit(value);
                },
                child: isBackspace
                    ? const Icon(Icons.backspace_outlined, color: Colors.white)
                    : Text(
                        value,
                        style: TextStyle(
                          fontSize: isClear ? 14 : 20,
                          fontWeight: FontWeight.w700,
                          color: isClear ? Colors.white : null,
                        ),
                      ),
              ),
            );
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF8FB7E8),
            title: Text(
              'Cash Tendered',
              style: TextStyle(color: addCashTextColor),
            ),
            content: Focus(
              autofocus: true,
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent) {
                  return KeyEventResult.ignored;
                }

                final key = event.logicalKey;
                if (key == LogicalKeyboardKey.numpad0 ||
                    key == LogicalKeyboardKey.digit0) {
                  appendDigit('0');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad1 ||
                    key == LogicalKeyboardKey.digit1) {
                  appendDigit('1');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad2 ||
                    key == LogicalKeyboardKey.digit2) {
                  appendDigit('2');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad3 ||
                    key == LogicalKeyboardKey.digit3) {
                  appendDigit('3');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad4 ||
                    key == LogicalKeyboardKey.digit4) {
                  appendDigit('4');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad5 ||
                    key == LogicalKeyboardKey.digit5) {
                  appendDigit('5');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad6 ||
                    key == LogicalKeyboardKey.digit6) {
                  appendDigit('6');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad7 ||
                    key == LogicalKeyboardKey.digit7) {
                  appendDigit('7');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad8 ||
                    key == LogicalKeyboardKey.digit8) {
                  appendDigit('8');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad9 ||
                    key == LogicalKeyboardKey.digit9) {
                  appendDigit('9');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpadDecimal ||
                    key == LogicalKeyboardKey.period) {
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.backspace ||
                    key == LogicalKeyboardKey.delete) {
                  backspace();
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.numpadEnter) {
                  submitAmount();
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.escape) {
                  Navigator.of(dialogContext).pop();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: SizedBox(
                width: (MediaQuery.of(dialogContext).size.width - 96).clamp(
                  220.0,
                  340.0,
                ),
                height: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        'Balance Due: \$${amountDue.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: addCashTextColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: cashController,
                      autofocus: true,
                      readOnly: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textInputAction: TextInputAction.done,
                      textAlign: TextAlign.right,
                      style: TextStyle(color: addCashTextColor),
                      onTap: () {
                        setCaretToEnd();
                      },
                      onChanged: (_) {
                        overwriteOnNextInput = false;
                        if (inputError != null) {
                          setDialogState(() {
                            inputError = null;
                          });
                        }
                      },
                      onSubmitted: (_) => submitAmount(),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white,
                        prefixText: '\$ ',
                        prefixStyle: TextStyle(
                          color: addCashTextColor,
                          fontWeight: FontWeight.w700,
                        ),
                        hintText: 'Enter amount',
                        hintStyle: TextStyle(color: addCashTextColor),
                        border: const OutlineInputBorder(),
                        errorText: inputError,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: GridView.count(
                        crossAxisCount: 3,
                        childAspectRatio: 1.9,
                        physics: const NeverScrollableScrollPhysics(),
                        children: cashPadButtons.map(buildPadButton).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  foregroundColor: addCashTextColor,
                ),
                onPressed: submitAmount,
                child: const Text('Add Cash'),
              ),
            ],
          );
        },
      ),
    );

    cashController.dispose();
    return amount;
  }

  // ignore: unused_element
  Future<double?> _promptCardTenderedAmount() async {
    final amountDue = _balance > 0 ? _balance : 0.0;
    if (amountDue <= 0) {
      return null;
    }

    final cardController = TextEditingController(
      text: amountDue.toStringAsFixed(2),
    );
    cardController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: cardController.text.length,
    );
    bool overwriteOnNextInput = true;
    String? inputError;

    final amount = await showDialog<double>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final cs = Theme.of(context).colorScheme;

          void setCaretToEnd() {
            cardController.selection = TextSelection.collapsed(
              offset: cardController.text.length,
            );
          }

          void appendDigit(String digit) {
            setDialogState(() {
              final baseCents = overwriteOnNextInput
                  ? 0
                  : ((double.tryParse(cardController.text.trim()) ?? 0) * 100)
                        .round();
              final nextCents = (baseCents * 10) + int.parse(digit);
              cardController.text = (nextCents / 100).toStringAsFixed(2);
              overwriteOnNextInput = false;
              inputError = null;
              setCaretToEnd();
            });
          }

          void backspace() {
            setDialogState(() {
              final currentCents =
                  ((double.tryParse(cardController.text.trim()) ?? 0) * 100)
                      .round();
              if (currentCents <= 0) {
                cardController.text = '0.00';
                overwriteOnNextInput = true;
                inputError = null;
                setCaretToEnd();
                return;
              }
              final nextCents = currentCents ~/ 10;
              cardController.text = (nextCents / 100).toStringAsFixed(2);
              overwriteOnNextInput = false;
              inputError = null;
              setCaretToEnd();
            });
          }

          void clearAmount() {
            setDialogState(() {
              cardController.text = '0.00';
              overwriteOnNextInput = true;
              inputError = null;
              setCaretToEnd();
            });
          }

          void submitAmount() {
            final parsed = double.tryParse(cardController.text.trim());
            if (parsed == null || parsed <= 0) {
              setDialogState(() {
                inputError = 'Enter a valid card amount.';
              });
              return;
            }
            if (parsed > amountDue) {
              setDialogState(() {
                inputError =
                    'Card amount cannot exceed balance due (\$${amountDue.toStringAsFixed(2)}).';
              });
              return;
            }
            Navigator.of(dialogContext).pop(parsed);
          }

          const padButtons = [
            '7',
            '8',
            '9',
            '4',
            '5',
            '6',
            '1',
            '2',
            '3',
            'Clear',
            '0',
            '<',
          ];

          Widget buildPadButton(String value) {
            final isClear = value == 'Clear';
            final isBackspace = value == '<';
            return Padding(
              padding: const EdgeInsets.all(2),
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  backgroundColor: isClear
                      ? _themeRed
                      : isBackspace
                      ? _themeYellow
                      : null,
                ),
                onPressed: () {
                  if (isBackspace) {
                    backspace();
                    return;
                  }
                  if (isClear) {
                    clearAmount();
                    return;
                  }
                  appendDigit(value);
                },
                child: isBackspace
                    ? const Icon(Icons.backspace_outlined, color: Colors.white)
                    : Text(
                        value,
                        style: TextStyle(
                          fontSize: isClear ? 14 : 20,
                          fontWeight: FontWeight.w700,
                          color: isClear ? Colors.white : null,
                        ),
                      ),
              ),
            );
          }

          return AlertDialog(
            title: Row(
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.88, end: 1.08),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeInOut,
                  builder: (context, value, child) {
                    return Transform.scale(scale: value, child: child);
                  },
                  child: Icon(
                    Icons.attach_money_rounded,
                    color: cs.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 8),
                const Text('Card Payment Amount'),
              ],
            ),
            content: Focus(
              autofocus: true,
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent) {
                  return KeyEventResult.ignored;
                }

                final key = event.logicalKey;
                if (key == LogicalKeyboardKey.numpad0 ||
                    key == LogicalKeyboardKey.digit0) {
                  appendDigit('0');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad1 ||
                    key == LogicalKeyboardKey.digit1) {
                  appendDigit('1');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad2 ||
                    key == LogicalKeyboardKey.digit2) {
                  appendDigit('2');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad3 ||
                    key == LogicalKeyboardKey.digit3) {
                  appendDigit('3');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad4 ||
                    key == LogicalKeyboardKey.digit4) {
                  appendDigit('4');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad5 ||
                    key == LogicalKeyboardKey.digit5) {
                  appendDigit('5');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad6 ||
                    key == LogicalKeyboardKey.digit6) {
                  appendDigit('6');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad7 ||
                    key == LogicalKeyboardKey.digit7) {
                  appendDigit('7');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad8 ||
                    key == LogicalKeyboardKey.digit8) {
                  appendDigit('8');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpad9 ||
                    key == LogicalKeyboardKey.digit9) {
                  appendDigit('9');
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.numpadDecimal ||
                    key == LogicalKeyboardKey.period) {
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.backspace ||
                    key == LogicalKeyboardKey.delete) {
                  backspace();
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.numpadEnter) {
                  submitAmount();
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.escape) {
                  Navigator.of(dialogContext).pop();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: SizedBox(
                width: (MediaQuery.of(dialogContext).size.width - 96).clamp(
                  220.0,
                  340.0,
                ),
                height: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        'Balance Due: \$${amountDue.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: cardController,
                      autofocus: true,
                      readOnly: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textInputAction: TextInputAction.done,
                      textAlign: TextAlign.right,
                      onTap: () {
                        setCaretToEnd();
                      },
                      onChanged: (_) {
                        overwriteOnNextInput = false;
                        if (inputError != null) {
                          setDialogState(() {
                            inputError = null;
                          });
                        }
                      },
                      onSubmitted: (_) => submitAmount(),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white,
                        prefixText: '\$ ',
                        prefixStyle: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w700,
                        ),
                        hintText: 'Enter card amount',
                        border: const OutlineInputBorder(),
                        errorText: inputError,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: GridView.count(
                        crossAxisCount: 3,
                        childAspectRatio: 1.9,
                        physics: const NeverScrollableScrollPhysics(),
                        children: padButtons.map(buildPadButton).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submitAmount,
                child: const Text('Use Card Amount'),
              ),
            ],
          );
        },
      ),
    );

    cardController.dispose();
    return amount;
  }

  /// Builds a customer info snapshot for ledger storage.
  Map<String, dynamic> _buildCustomerSnapshot() {
    final snapshot = <String, dynamic>{};
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final fullName = '$firstName $lastName'.trim();
    if (fullName.isNotEmpty) snapshot['name'] = fullName;
    if (_customerNumberController.text.trim().isNotEmpty) {
      snapshot['customer_number'] = _customerNumberController.text.trim();
    }
    if (_address1Controller.text.trim().isNotEmpty) {
      snapshot['address_1'] = _address1Controller.text.trim();
    }
    if (_address2Controller.text.trim().isNotEmpty) {
      snapshot['address_2'] = _address2Controller.text.trim();
    }
    if (_cityController.text.trim().isNotEmpty) {
      snapshot['city'] = _cityController.text.trim();
    }
    if (_stateController.text.trim().isNotEmpty) {
      snapshot['state'] = _stateController.text.trim();
    }
    if (_zipController.text.trim().isNotEmpty) {
      snapshot['zip'] = _zipController.text.trim();
    }
    if (_phoneController.text.trim().isNotEmpty) {
      snapshot['phone'] = _phoneController.text.trim();
    }
    if (_emailController.text.trim().isNotEmpty) {
      snapshot['email'] = _emailController.text.trim();
    }
    if (_invoiceReference.trim().isNotEmpty) {
      snapshot['invoice_reference'] = _invoiceReference.trim();
    }
    return snapshot;
  }

  bool _isCustomerFieldVisible(String key) {
    return _transactionFlowParameters.modeFor(key) != CustomerFieldMode.hidden;
  }

  bool _isCustomerFieldRequired(String key) {
    return _transactionFlowParameters.modeFor(key) ==
        CustomerFieldMode.required;
  }

  String _nextTransactionId() {
    return 'POS-${DateTime.now().millisecondsSinceEpoch}';
  }

  String _nextHostedPaymentReferenceId() {
    return 'PAAAYIT-${DateTime.now().microsecondsSinceEpoch}';
  }

  Future<void> _persistLatestTransactionIntegritySnapshot({
    required String transactionHeaderId,
    String transactionDetailId = '',
    required double amount,
    double feeAmount = 0,
    required int expectedBatchNumber,
    required String paymentType,
    required String subtype,
    required String status,
    required String processorReferenceId,
    String authCode = '',
    String cardLast4 = '',
    String cardType = '',
  }) async {
    final snapshot = <String, dynamic>{
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'transactionHeaderId': transactionHeaderId.trim(),
      'transactionDetailId': transactionDetailId.trim(),
      'amount': amount,
      'feeAmount': feeAmount,
      'expectedBatchNumber': expectedBatchNumber,
      'paymentType': paymentType,
      'subtype': subtype,
      'status': status,
      'processorReferenceId': processorReferenceId,
      'authCode': authCode,
      'cardLast4': cardLast4,
      'cardType': cardType,
      'invoiceReference': _invoiceReference,
      'staffId': _staffId,
      'terminalName': _terminalName,
      'customerSnapshot': _buildCustomerSnapshot(),
    };

    try {
      await IntegrityCheckStore.saveLatestTransactionSnapshot(snapshot);
    } catch (error) {
      debugPrint('Failed to persist integrity snapshot: $error');
    }
  }

  Future<void> _runInlineTransactionIntegrityCheck({
    required String transactionHeaderId,
    required String transactionDetailId,
    required double amount,
    double feeAmount = 0,
    required int expectedBatchNumber,
    required String paymentType,
    required String subtype,
    required String status,
    required String processorReferenceId,
    required String authCode,
    required String cardLast4,
    required String cardType,
    required String invoiceReference,
    required String serverId,
    required String staffName,
    required String terminalName,
  }) async {
    if (!mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        title: Text('Transaction Integrity Check'),
        content: SizedBox(
          height: 72,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );

    final result = await _buildInlineTransactionIntegrityResult(
      transactionHeaderId: transactionHeaderId,
      transactionDetailId: transactionDetailId,
      amount: amount,
      feeAmount: feeAmount,
      expectedBatchNumber: expectedBatchNumber,
      paymentType: paymentType,
      subtype: subtype,
      status: status,
      processorReferenceId: processorReferenceId,
      authCode: authCode,
      cardLast4: cardLast4,
      cardType: cardType,
      invoiceReference: invoiceReference,
      serverId: serverId,
      staffName: staffName,
      terminalName: terminalName,
    );

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final overallPass = result.passed;
        final bannerColor = overallPass
            ? const Color(0xFF2E7D32)
            : Theme.of(dialogContext).colorScheme.error;

        String buildCopyText() {
          final buf = StringBuffer();
          buf.writeln(
            overallPass
                ? 'PASS - Inline Transaction Integrity Check'
                : 'FAIL - Inline Transaction Integrity Check',
          );
          if (result.error != null) {
            buf.writeln('Error: ${result.error}');
          }
          buf.writeln();
          buf.writeln('--- Record Checks ---');
          for (final line in result.recordChecks) {
            buf.writeln('${line.passed ? '[PASS]' : '[FAIL]'} ${line.label}');
            buf.writeln('  Expected: ${line.expected ?? '-'}');
            buf.writeln('  Actual:   ${line.actual ?? '-'}');
          }
          buf.writeln();
          buf.writeln('--- Field Checks ---');
          for (final line in result.fieldChecks) {
            buf.writeln('${line.passed ? '[PASS]' : '[FAIL]'} ${line.label}');
            buf.writeln('  Expected: ${line.expected ?? '-'}');
            buf.writeln('  Actual:   ${line.actual ?? '-'}');
          }
          return buf.toString();
        }

        Widget buildLine(_InlineIntegrityCheckLine line) {
          return ListTile(
            dense: true,
            leading: Icon(
              line.passed ? Icons.check_circle : Icons.cancel,
              color: line.passed
                  ? const Color(0xFF2E7D32)
                  : Theme.of(dialogContext).colorScheme.error,
            ),
            title: SelectableText(line.label),
            subtitle: SelectableText(
              'Expected: ${line.expected ?? '-'}\nActual: ${line.actual ?? '-'}',
            ),
          );
        }

        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 20,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900, maxHeight: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  color: bannerColor,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: SelectableText(
                    overallPass
                        ? 'PASS - Inline Transaction Integrity Check'
                        : 'FAIL - Inline Transaction Integrity Check',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (result.error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                    child: SelectableText(
                      result.error!,
                      style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(10),
                    children: [
                      const Text(
                        'Record Checks',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ...result.recordChecks.map(buildLine),
                      const SizedBox(height: 10),
                      const Text(
                        'Field Checks',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ...result.fieldChecks.map(buildLine),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: buildCopyText()),
                          );
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Integrity results copied to clipboard',
                              ),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy All'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<_InlineIntegrityCheckResult> _buildInlineTransactionIntegrityResult({
    required String transactionHeaderId,
    required String transactionDetailId,
    required double amount,
    double feeAmount = 0,
    required int expectedBatchNumber,
    required String paymentType,
    required String subtype,
    required String status,
    required String processorReferenceId,
    required String authCode,
    required String cardLast4,
    required String cardType,
    required String invoiceReference,
    required String serverId,
    required String staffName,
    required String terminalName,
  }) async {
    var headerId = transactionHeaderId.trim();
    var detailId = transactionDetailId.trim();

    try {
      final client = Supabase.instance.client;

      if (headerId.isEmpty || detailId.isEmpty) {
        final baseQuery = client
            .from('transaction_details')
            .select()
            .eq('status', 'approved');

        final fallbackQuery = processorReferenceId.trim().isNotEmpty
            ? baseQuery.eq('reference_id', processorReferenceId.trim())
            : baseQuery;

        final detailRows = await fallbackQuery
            .order('created_at', ascending: false)
            .limit(20);

        if (detailRows.isNotEmpty) {
          final candidates = detailRows
              .map((r) => Map<String, dynamic>.from(r as Map))
              .where(
                (r) => (_inlineToDouble(r['amount']) - amount).abs() < 0.0001,
              )
              .toList();

          final picked = candidates.isNotEmpty ? candidates.first : null;
          if (picked != null) {
            detailId = detailId.isEmpty
                ? (picked['id']?.toString().trim() ?? '')
                : detailId;
            headerId = headerId.isEmpty
                ? (picked['transaction_header_id']?.toString().trim() ?? '')
                : headerId;
          }
        }
      }

      Map<String, dynamic>? header;
      if (headerId.isNotEmpty) {
        final headerRow = await client
            .from('transaction_headers')
            .select()
            .eq('id', headerId)
            .maybeSingle();
        if (headerRow != null) header = Map<String, dynamic>.from(headerRow);
      }

      Map<String, dynamic>? detail;
      if (detailId.isNotEmpty) {
        final detailRow = await client
            .from('transaction_details')
            .select()
            .eq('id', detailId)
            .maybeSingle();
        if (detailRow != null) detail = Map<String, dynamic>.from(detailRow);
      }

      if (detail == null && headerId.isNotEmpty) {
        final rows = await client
            .from('transaction_details')
            .select()
            .eq('transaction_header_id', headerId)
            .order('created_at', ascending: false)
            .limit(1);
        if ((rows as List).isNotEmpty) {
          detail = Map<String, dynamic>.from(rows.first as Map);
          detailId = detail['id']?.toString() ?? detailId;
        }
      }

      Map<String, dynamic>? batchDetail;
      Map<String, dynamic>? batchHeader;
      if (detail != null) {
        final batchRows = await client
            .from('card_batch_details')
            .select()
            .eq('transaction_detail_id', detail['id']?.toString() ?? '')
            .order('created_at', ascending: false)
            .limit(1);

        if ((batchRows as List).isNotEmpty) {
          batchDetail = Map<String, dynamic>.from(batchRows.first as Map);
        }

        final batchHeaderId =
            batchDetail?['card_batch_header_id']?.toString() ?? '';
        if (batchHeaderId.isNotEmpty) {
          final batchHeaderRow = await client
              .from('card_batch_headers')
              .select()
              .eq('id', batchHeaderId)
              .maybeSingle();
          if (batchHeaderRow != null) {
            batchHeader = Map<String, dynamic>.from(batchHeaderRow);
          }
        }
      }

      final batchStatus =
          (detail?['batch_status']?.toString().trim().toLowerCase() ?? '');
      final expectsBatchMirror = batchStatus == 'c';

      final recordChecks = <_InlineIntegrityCheckLine>[
        _InlineIntegrityCheckLine(
          label: 'transaction_headers record exists',
          passed: header != null,
          expected: headerId,
          actual: header?['id']?.toString() ?? '(missing)',
        ),
        _InlineIntegrityCheckLine(
          label: 'transaction_details record exists',
          passed: detail != null,
          expected: detailId.isEmpty ? '(latest by header)' : detailId,
          actual: detail?['id']?.toString() ?? '(missing)',
        ),
        _InlineIntegrityCheckLine(
          label: 'batch state tracked on transaction_details',
          passed: (detail?['batch_status']?.toString().trim() ?? '').isNotEmpty,
          expected: 'batch_status populated',
          actual: detail?['batch_status']?.toString() ?? '(missing)',
        ),
        _InlineIntegrityCheckLine(
          label: 'card_batch_details linkage for transaction',
          passed: expectsBatchMirror ? batchDetail != null : true,
          expected: expectsBatchMirror
              ? 'present for closed batch (batch_status=c)'
              : 'optional until close',
          actual: batchDetail == null
              ? '(missing)'
              : (batchDetail['id']?.toString() ?? '(missing)'),
        ),
        _InlineIntegrityCheckLine(
          label: 'card_batch_headers linkage for batch detail',
          passed: batchDetail == null
              ? !expectsBatchMirror
              : batchHeader != null,
          expected: expectsBatchMirror
              ? 'present when batch detail exists'
              : 'optional until close',
          actual: batchHeader == null
              ? '(missing)'
              : (batchHeader['id']?.toString() ?? '(missing)'),
        ),
      ];

      final headerReceiptId = header?['receipt_id']?.toString().trim() ?? '';
      final detailReceiptId = detail?['receipt_id']?.toString().trim() ?? '';

      final fieldChecks = <_InlineIntegrityCheckLine>[
        _inlineCmp(
          label: 'header.id',
          expected: headerId,
          actual: header?['id']?.toString() ?? '',
        ),
        _inlineCmpMoney(
          label: 'header.total',
          expected: amount,
          actual: _inlineToDouble(header?['total']),
        ),
        _inlineCmpMoney(
          label: 'header.fee_amount',
          expected: feeAmount,
          actual: _inlineToDouble(header?['fee_amount']),
        ),
        _InlineIntegrityCheckLine(
          label: 'header.invoice_reference',
          passed:
              (invoiceReference.isEmpty &&
                  (header?['invoice_reference']?.toString().trim().isEmpty ??
                      true)) ||
              (invoiceReference.isNotEmpty &&
                  header?['invoice_reference']?.toString().trim() ==
                      invoiceReference.trim()),
          expected: invoiceReference.isNotEmpty
              ? invoiceReference
              : '(not entered)',
          actual:
              (header?['invoice_reference']?.toString().trim().isEmpty ?? true)
              ? '(not entered)'
              : header?['invoice_reference']?.toString() ?? '',
        ),
        _InlineIntegrityCheckLine(
          label: 'header.server_id',
          passed:
              (serverId.isEmpty &&
                  (header?['server_id']?.toString().trim().isEmpty ?? true)) ||
              (serverId.isNotEmpty &&
                  header?['server_id']?.toString().trim() == serverId.trim()),
          expected: serverId.isNotEmpty ? serverId : '(not entered)',
          actual: (header?['server_id']?.toString().trim().isEmpty ?? true)
              ? '(not entered)'
              : header?['server_id']?.toString() ?? '',
        ),
        _inlineCmp(
          label: 'header.staff_name',
          expected: staffName,
          actual: header?['staff_name']?.toString() ?? '',
        ),
        _inlineCmp(
          label: 'header.terminal_name',
          expected: terminalName,
          actual: header?['terminal_name']?.toString() ?? '',
        ),
        _InlineIntegrityCheckLine(
          label: 'header.batch_number',
          passed:
              _inlineToInt(header?['batch_number']) > 0 &&
              _inlineToInt(header?['batch_number']) == expectedBatchNumber,
          expected: expectedBatchNumber.toString(),
          actual: _inlineToInt(header?['batch_number']) > 0
              ? _inlineToInt(header?['batch_number']).toString()
              : '(missing)',
        ),
        _InlineIntegrityCheckLine(
          label: 'header.txn_seq',
          passed: _inlineToInt(header?['txn_seq']) > 0,
          expected: '> 0',
          actual: _inlineToInt(header?['txn_seq']) > 0
              ? _inlineToInt(header?['txn_seq']).toString()
              : '(missing)',
        ),
        _InlineIntegrityCheckLine(
          label: 'header.receipt_id format',
          passed: RegExp(r'^\d{6}-\d{3}-\d{6}$').hasMatch(headerReceiptId),
          expected: 'NNNNNN-NNN-NNNNNN',
          actual: headerReceiptId.isEmpty ? '(missing)' : headerReceiptId,
        ),
        _inlineCmpMoney(
          label: 'detail.amount',
          expected: amount,
          actual: _inlineToDouble(detail?['amount']),
        ),
        _inlineCmpMoney(
          label: 'detail.fee_amount',
          expected: feeAmount,
          actual: _inlineToDouble(detail?['fee_amount']),
        ),
        _inlineCmp(
          label: 'detail.payment_type',
          expected: paymentType,
          actual: detail?['payment_type']?.toString() ?? '',
        ),
        _inlineCmp(
          label: 'detail.subtype',
          expected: subtype,
          actual: detail?['subtype']?.toString() ?? '',
        ),
        _inlineCmp(
          label: 'detail.status',
          expected: status,
          actual: detail?['status']?.toString() ?? '',
        ),
        _inlineCmp(
          label: 'detail.reference_id (processor)',
          expected: processorReferenceId,
          actual: detail?['reference_id']?.toString() ?? '',
        ),
        _inlineCmp(
          label: 'detail.auth_code',
          expected: authCode,
          actual: detail?['auth_code']?.toString() ?? '',
        ),
        _inlineCmp(
          label: 'detail.card_last4',
          expected: cardLast4,
          actual: detail?['card_last4']?.toString() ?? '',
        ),
        _inlineCmp(
          label: 'detail.card_type',
          expected: cardType,
          actual: detail?['card_type']?.toString() ?? '',
        ),
        _InlineIntegrityCheckLine(
          label: 'detail.receipt_id matches header',
          passed:
              headerReceiptId.isNotEmpty && detailReceiptId == headerReceiptId,
          expected: headerReceiptId.isEmpty
              ? '(header receipt_id present)'
              : headerReceiptId,
          actual: detailReceiptId.isEmpty ? '(missing)' : detailReceiptId,
        ),
        if (batchDetail != null)
          _inlineCmp(
            label: 'batch_detail.transaction_detail_id',
            expected: detail?['id']?.toString() ?? '',
            actual: batchDetail['transaction_detail_id']?.toString() ?? '',
          ),
        if (batchDetail != null)
          _inlineCmp(
            label: 'batch_detail.transaction_header_id',
            expected: headerId,
            actual: batchDetail['transaction_header_id']?.toString() ?? '',
          ),
        if (batchDetail != null)
          _inlineCmpMoney(
            label: 'batch_detail.amount',
            expected: amount,
            actual: _inlineToDouble(batchDetail['amount']),
          ),
        if (batchDetail != null)
          _inlineCmpMoney(
            label: 'batch_detail.fee_amount',
            expected: feeAmount,
            actual: _inlineToDouble(batchDetail['fee_amount']),
          ),
        if (batchDetail != null)
          _inlineCmp(
            label: 'batch_detail.reference_id',
            expected: processorReferenceId,
            actual: batchDetail['reference_id']?.toString() ?? '',
          ),
        if (batchDetail != null)
          _inlineCmp(
            label: 'batch_detail.auth_code',
            expected: authCode,
            actual: batchDetail['auth_code']?.toString() ?? '',
          ),
        if (batchDetail != null)
          _inlineCmp(
            label: 'batch_detail.card_last4',
            expected: cardLast4,
            actual: batchDetail['card_last4']?.toString() ?? '',
          ),
      ];

      return _InlineIntegrityCheckResult(
        recordChecks: recordChecks,
        fieldChecks: fieldChecks,
      );
    } catch (error) {
      return _InlineIntegrityCheckResult(
        recordChecks: const [],
        fieldChecks: const [],
        error: 'Inline integrity check failed: $error',
      );
    }
  }

  double _inlineToDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  int _inlineToInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }

  _InlineIntegrityCheckLine _inlineCmp({
    required String label,
    required String expected,
    required String actual,
  }) {
    return _InlineIntegrityCheckLine(
      label: label,
      passed: expected.trim() == actual.trim(),
      expected: expected,
      actual: actual,
    );
  }

  _InlineIntegrityCheckLine _inlineCmpMoney({
    required String label,
    required double expected,
    required double actual,
  }) {
    final passed = (expected - actual).abs() < 0.01;
    return _InlineIntegrityCheckLine(
      label: label,
      passed: passed,
      expected: expected.toStringAsFixed(2),
      actual: actual.toStringAsFixed(2),
    );
  }

  Future<void> _startCardFlow() async {
    final activeCtx = LicenseService().activeContext;
    if (mounted) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Card button pressed: preparing card reader...'),
          duration: Duration(seconds: 1),
        ),
      );
    }

    final terminalId = (activeCtx?.terminalId ?? '').trim();
    final terminalNumber = (activeCtx?.terminalNumber ?? '').trim();
    final terminalName = (activeCtx?.terminalName ?? '').trim();
    await _ensureTerminalConfigResolvedForSession(forceRefresh: true);

    if (mounted) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Card reader mode: ${TerminalConfig.cardReaderType} (physical=${TerminalConfig.hasPhysicalCardReader}) | terminal: ${terminalNumber.isNotEmpty ? terminalNumber : 'unknown'}${terminalName.isNotEmpty ? ' - $terminalName' : ''}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    debugPrint(
      '[CardFlow] terminalId=$terminalId terminalNumber=$terminalNumber terminalName=$terminalName cardReaderType=${TerminalConfig.cardReaderType} hasPhysical=${TerminalConfig.hasPhysicalCardReader}',
    );

    final warmed = await _warmUpCardTerminalIfNeeded();
    if (!warmed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Card reader warm-up did not complete. Attempting live transaction now...',
            ),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }

    final allowed = await _runTransactionPreflight();
    if (!allowed) return;
    await _payByCard();
  }

  Future<void> _startCashFlow() async {
    final allowed = await _runTransactionPreflight();
    if (!allowed) return;
    await _payCash();
  }

  Future<bool> _runTransactionPreflight() async {
    await _loadTransactionFlowParameters();

    if (_transactionFlowParameters.staffTrackingEnabled) {
      final enteredStaffId = await _promptStaffIdWithNumberPad();
      if (enteredStaffId == null) return false;
      setState(() {
        _staffId = enteredStaffId;
      });
    } else if (_staffId.isNotEmpty) {
      setState(() {
        _staffId = '';
      });
    }

    if (_transactionFlowParameters.customerTrackingEnabled) {
      final confirmed = await _showTransactionCustomerInfoDialog();
      return confirmed;
    }

    _invoiceReference = '';
    _pendingTransactionId = '';
    return true;
  }

  Future<String?> _promptStaffIdWithNumberPad() async {
    var digits = '';
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void appendDigit(String digit) {
              if (digits.length < 6) {
                setDialogState(() {
                  digits = '$digits$digit';
                });
              }
            }

            void backspace() {
              if (digits.isEmpty) return;
              setDialogState(() {
                digits = digits.substring(0, digits.length - 1);
              });
            }

            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 4.0, sigmaY: 4.0),
              child: Focus(
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  final key = event.logicalKey;
                  final digitMap = <LogicalKeyboardKey, String>{
                    LogicalKeyboardKey.digit0: '0',
                    LogicalKeyboardKey.digit1: '1',
                    LogicalKeyboardKey.digit2: '2',
                    LogicalKeyboardKey.digit3: '3',
                    LogicalKeyboardKey.digit4: '4',
                    LogicalKeyboardKey.digit5: '5',
                    LogicalKeyboardKey.digit6: '6',
                    LogicalKeyboardKey.digit7: '7',
                    LogicalKeyboardKey.digit8: '8',
                    LogicalKeyboardKey.digit9: '9',
                    LogicalKeyboardKey.numpad0: '0',
                    LogicalKeyboardKey.numpad1: '1',
                    LogicalKeyboardKey.numpad2: '2',
                    LogicalKeyboardKey.numpad3: '3',
                    LogicalKeyboardKey.numpad4: '4',
                    LogicalKeyboardKey.numpad5: '5',
                    LogicalKeyboardKey.numpad6: '6',
                    LogicalKeyboardKey.numpad7: '7',
                    LogicalKeyboardKey.numpad8: '8',
                    LogicalKeyboardKey.numpad9: '9',
                  };
                  final digit = digitMap[key];
                  if (digit != null) {
                    appendDigit(digit);
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.backspace) {
                    backspace();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: AlertDialog(
                  title: const Text('Enter Staff ID'),
                  content: SizedBox(
                    width: 320,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black26),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            digits.isEmpty ? '' : digits,
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        GridView.count(
                          crossAxisCount: 3,
                          shrinkWrap: true,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                          childAspectRatio: 1.6,
                          children: [
                            for (final n in [
                              '1',
                              '2',
                              '3',
                              '4',
                              '5',
                              '6',
                              '7',
                              '8',
                              '9',
                            ])
                              FilledButton(
                                onPressed: () => appendDigit(n),
                                child: Text(n),
                              ),
                            FilledButton.tonal(
                              onPressed: () {
                                setDialogState(() {
                                  digits = '';
                                });
                              },
                              child: const Text('Clear'),
                            ),
                            FilledButton(
                              onPressed: () => appendDigit('0'),
                              child: const Text('0'),
                            ),
                            FilledButton.tonal(
                              onPressed: backspace,
                              child: const Icon(Icons.backspace_outlined),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: digits.trim().isEmpty
                          ? null
                          : () =>
                                Navigator.of(dialogContext).pop(digits.trim()),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    return result;
  }

  Future<bool> _showTransactionCustomerInfoDialog() async {
    final transactionIdController = TextEditingController(
      text: _invoiceReference,
    );
    final transactionIdFocusNode = FocusNode();
    String? emailError;
    const fieldScale = 1.25;

    // Schedule focus exactly once — not inside the builder which reruns on
    // every setDialogState call (which would jump focus back on email changes).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      transactionIdFocusNode.requestFocus();
    });

    final confirmed = await (() async {
      if (!mounted) return false;

      final resultCompleter = Completer<bool>();
      late OverlayEntry entry;
      BuildContext? dialogBuilderContext;
      bool overlayActive = true;

      final overlayState = Overlay.of(context, rootOverlay: true);
      Rect? anchorRect;
      final anchorContext = _terminalViewportKey.currentContext;
      if (anchorContext != null) {
        final overlayBox =
            overlayState.context.findRenderObject() as RenderBox?;
        final anchorBox = anchorContext.findRenderObject() as RenderBox?;
        if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
          final topLeft = anchorBox.localToGlobal(
            Offset.zero,
            ancestor: overlayBox,
          );
          anchorRect = topLeft & anchorBox.size;
        }
      }

      void closeDialog([bool value = false]) {
        if (!overlayActive) return;
        overlayActive = false;
        entry.remove();
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(value);
        }
      }

      bool canUpdateDialog() {
        return overlayActive &&
            mounted &&
            (dialogBuilderContext?.mounted ?? false);
      }

      final dialogWidget = StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          dialogBuilderContext = dialogContext;
          final scheme = Theme.of(dialogContext).colorScheme;
          final titleStyle = TextStyle(
            fontSize: 16 * fieldScale,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          );
          final actionTextStyle = TextStyle(
            fontSize: 13 * fieldScale,
            fontWeight: FontWeight.w600,
          );
          final fields = <Widget>[];

          void safeSet(void Function() update) {
            if (!canUpdateDialog()) return;
            setDialogState(update);
          }

          void addField({
            required String key,
            required String label,
            required TextEditingController controller,
            TextInputType keyboardType = TextInputType.text,
            int? maxLength,
            FocusNode? focusNode,
          }) {
            if (!_isCustomerFieldVisible(key)) return;
            final required = _isCustomerFieldRequired(key);
            fields.add(
              _buildCustomerField(
                label: required ? '$label *' : label,
                controller: controller,
                keyboardType: keyboardType,
                maxLength: maxLength,
                focusNode: focusNode,
                sizeScale: fieldScale,
              ),
            );
          }

          addField(
            key: 'invoice_reference',
            label: 'Invoice / Reference',
            controller: transactionIdController,
            maxLength: 24,
            focusNode: transactionIdFocusNode,
          );
          addField(
            key: 'customer_id',
            label: 'Customer ID',
            controller: _customerNumberController,
          );
          addField(
            key: 'first_name',
            label: 'First Name',
            controller: _firstNameController,
          );
          addField(
            key: 'last_name',
            label: 'Last Name',
            controller: _lastNameController,
          );
          addField(
            key: 'address1',
            label: 'Address 1',
            controller: _address1Controller,
          );
          addField(
            key: 'address2',
            label: 'Address 2',
            controller: _address2Controller,
          );
          addField(key: 'city', label: 'City', controller: _cityController);
          addField(key: 'state', label: 'State', controller: _stateController);
          addField(key: 'zip', label: 'Zip', controller: _zipController);

          if (_isCustomerFieldVisible('email')) {
            final required = _isCustomerFieldRequired('email');
            fields.add(
              _buildCustomerField(
                label: required ? 'Email *' : 'Email',
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                errorText: emailError,
                sizeScale: fieldScale,
                onChanged: (value) {
                  final nextError = _isValidEmailFormat(value)
                      ? null
                      : 'Enter a valid email address';
                  if (nextError != emailError) {
                    safeSet(() {
                      emailError = nextError;
                    });
                  }
                },
              ),
            );
          }

          bool missingRequired() {
            bool isMissing(String key, String value) {
              return _isCustomerFieldRequired(key) && value.trim().isEmpty;
            }

            return isMissing(
                  'invoice_reference',
                  transactionIdController.text,
                ) ||
                isMissing('customer_id', _customerNumberController.text) ||
                isMissing('first_name', _firstNameController.text) ||
                isMissing('last_name', _lastNameController.text) ||
                isMissing('address1', _address1Controller.text) ||
                isMissing('address2', _address2Controller.text) ||
                isMissing('city', _cityController.text) ||
                isMissing('state', _stateController.text) ||
                isMissing('zip', _zipController.text) ||
                isMissing('email', _emailController.text);
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 6.0, sigmaY: 6.0),
                  child: Container(color: Colors.black26),
                ),
              ),
              Center(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final dialogWidth = (constraints.maxWidth - 28)
                        .clamp(250.0, 360.0)
                        .toDouble();
                    final dialogHeight = (constraints.maxHeight - 32)
                        .clamp(320.0, 760.0)
                        .toDouble();

                    return ConstrainedBox(
                      constraints: BoxConstraints.tightFor(
                        width: dialogWidth,
                        height: dialogHeight,
                      ),
                      child: Material(
                        elevation: 18,
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(18),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Customer / Transaction Info',
                                textAlign: TextAlign.center,
                                style: titleStyle,
                              ),
                              SizedBox(height: 10 * fieldScale),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: Column(children: fields),
                                ),
                              ),
                              SizedBox(height: 10 * fieldScale),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextButton(
                                      onPressed: () => closeDialog(false),
                                      style: TextButton.styleFrom(
                                        minimumSize: Size(
                                          double.infinity,
                                          40 * fieldScale,
                                        ),
                                      ),
                                      child: Text(
                                        'Cancel',
                                        style: actionTextStyle,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: FilledButton(
                                      onPressed: () {
                                        if (missingRequired()) {
                                          ScaffoldMessenger.of(
                                            dialogContext,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Please complete all required fields.',
                                              ),
                                            ),
                                          );
                                          return;
                                        }
                                        if (!_isValidEmailFormat(
                                          _emailController.text,
                                        )) {
                                          safeSet(() {
                                            emailError =
                                                'Enter a valid email address';
                                          });
                                          return;
                                        }

                                        _invoiceReference =
                                            transactionIdController.text.trim();
                                        _pendingTransactionId = '';

                                        closeDialog(true);
                                      },
                                      style: FilledButton.styleFrom(
                                        minimumSize: Size(
                                          double.infinity,
                                          40 * fieldScale,
                                        ),
                                      ),
                                      child: Text(
                                        'Continue',
                                        style: actionTextStyle,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      );

      entry = OverlayEntry(
        builder: (_) {
          if (anchorRect == null) {
            return dialogWidget;
          }
          return Stack(
            children: [
              Positioned(
                left: anchorRect.left,
                top: anchorRect.top,
                width: anchorRect.width,
                height: anchorRect.height,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: dialogWidget,
                ),
              ),
            ],
          );
        },
      );

      overlayState.insert(entry);
      return resultCompleter.future;
    })();

    transactionIdController.dispose();
    transactionIdFocusNode.dispose();
    return confirmed == true;
  }

  Future<void> _payCash() async {
    if (total <= 0) return;

    final paymentAmount = await _promptCashTenderedAmount();
    if (paymentAmount == null) return;

    final changeGiven = (paymentAmount - _balance).clamp(0.0, double.infinity);

    setState(() {
      _cashPaid += paymentAmount;
      _paymentHistory.add('Cash: \$${paymentAmount.toStringAsFixed(2)}');
      _lastTransactionInfoLines
        ..clear()
        ..add('Amount: \$${paymentAmount.toStringAsFixed(2)}')
        ..add('Payment: Cash');
      _lastCustomerInfoLines
        ..clear()
        ..addAll(_buildCurrentTransactionCustomerInfoLines());
      _currentInput = '';
    });

    final headerId = await _transactionSyncService.createTransactionHeader(
      subtotal: total,
      tax: _totalTax,
      total: _subTotal,
      batchNumber: _activeHeaderBatchNumber,
      serverId: _staffId,
      staffName: _staffName,
      terminalName: _terminalName,
      invoiceReference: _invoiceReference,
      customerSnapshot: _buildCustomerSnapshot(),
    );

    if (headerId != null && headerId.isNotEmpty) {
      _lastReceiptIdDisplay = await _transactionSyncService
          .getReceiptIdDisplayForHeader(headerId);
    } else {
      _lastReceiptIdDisplay = '';
    }

    if (headerId != null) {
      await _transactionSyncService.saveTransactionDetail(
        transactionHeaderId: headerId,
        paymentType: 'c',
        subtype: 's',
        amount: paymentAmount,
        status: 'approved',
        cashTendered: paymentAmount,
        cashChange: changeGiven > 0 ? changeGiven : null,
      );
    } else {
      debugPrint(
        '_payCash: createTransactionHeader returned null — ledger row NOT saved',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '⚠ Ledger write failed — header not created. Check debug logs.',
            ),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 6),
          ),
        );
      }
    }

    // Legacy table shim
    await _transactionSyncService.saveTransaction(
      paymentType: 'cash',
      amount: paymentAmount,
      success: true,
      message: 'Cash payment posted: \$${paymentAmount.toStringAsFixed(2)}',
      transactionHeaderId: headerId,
    );

    _pendingTransactionId = '';
  }

  Future<void> _loadOpenBatch() async {
    if (!mounted) return;
    setState(() => _batchLoading = true);
    final rows = await _transactionSyncService.getOpenBatchCardDetails();
    final openRows = rows
        .where(
          (row) =>
              (row['batch_status']?.toString().trim().toLowerCase() ?? '') ==
              'o',
        )
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    if (!mounted) return;
    setState(() {
      _openBatchCards = openRows;
      _batchLoading = false;
    });
  }

  Future<void> _refreshActiveHeaderBatchNumber() async {
    final batchNumber = await _transactionSyncService
        .resolveActiveHeaderBatchNumber();
    if (!mounted) return;
    setState(() {
      _activeHeaderBatchNumber = batchNumber > 0 ? batchNumber : 1;
    });
  }

  void _scheduleBatchReconcile({
    required String reason,
    Duration delay = const Duration(milliseconds: 900),
  }) {
    _lastBatchReconcileReason = reason;
    _batchReconcileDebounceTimer?.cancel();
    _batchReconcileDebounceTimer = Timer(delay, () {
      unawaited(_runBatchReconcile());
    });
  }

  Future<void> _runBatchReconcile() async {
    if (!mounted || _batchReconcileInFlight) return;
    _batchReconcileInFlight = true;
    try {
      await _loadOpenBatch();

      final suppressedIds = _openBatchCards
          .where((r) => (r['subtype']?.toString() ?? '') == 'v')
          .map((r) => r['original_detail_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty);
      final openIds = {
        ..._openBatchCards
            .map((row) => row['id']?.toString() ?? '')
            .where((id) => id.isNotEmpty),
        ...suppressedIds,
      }.toList();
      if (openIds.isEmpty) return;

      final hasApproved = _openBatchCards.any(
        (row) => (row['status']?.toString() ?? '').toLowerCase() == 'approved',
      );
      final hasSaleRows = _openBatchCards.any(
        (row) => (row['subtype']?.toString().toLowerCase() ?? '').trim() == 's',
      );
      if (hasApproved || hasSaleRows) return;

      final closed = await _transactionSyncService.markBatchClosed(openIds);
      if (closed && mounted) {
        await _loadOpenBatch();
      }
    } catch (error) {
      debugPrint('batch reconcile failed ($_lastBatchReconcileReason): $error');
    } finally {
      _batchReconcileInFlight = false;
    }
  }

  Future<void> _voidCard(
    Map<String, dynamic> detail, {
    bool skipConfirmation = false,
  }) async {
    if (!skipConfirmation) {
      final cs = Theme.of(context).colorScheme;
      final confirmed = await showDialog<bool>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) => AlertDialog(
          title: const Text('Void Transaction?'),
          content: Text(
            'Void \$${_voidRegisterAmount(detail).toStringAsFixed(2)} '
            '${detail['card_type'] ?? ''} ****${detail['card_last4'] ?? ''}?\n\n'
            'This will cancel the unsettled authorization at the processor.\n\n'
            'Original Sale: \$${_voidOriginalAmount(detail).toStringAsFixed(2)}\n'
            'Surcharge: \$${_voidSurchargeAmount(detail).toStringAsFixed(2)}\n'
            'Tip Adjustment: \$${_voidTipAdjustmentAmount(detail).toStringAsFixed(2)}\n'
            'Confirmed Register Amount: \$${_voidRegisterAmount(detail).toStringAsFixed(2)}\n'
            'iPOS Void Amount: \$${_voidRegisterAmount(detail).toStringAsFixed(2)}',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx, rootNavigator: true).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cs.error),
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
              child: const Text('Void'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final tpn = TerminalConfig.spinTpn;
    final authKey = TerminalConfig.spinAuthKey;
    var gatewayToken = detail['gateway_token']?.toString().trim() ?? '';
    final referenceId = detail['reference_id']?.toString() ?? '';

    if (gatewayToken.isEmpty) {
      final raw = detail['gateway_raw'];
      Map<String, dynamic>? rawMap;
      if (raw is Map) {
        rawMap = Map<String, dynamic>.from(raw);
      } else if (raw is String && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            rawMap = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
      }

      if (rawMap != null) {
        gatewayToken =
            (rawMap['gatewayToken'] ??
                    rawMap['gateway_token'] ??
                    rawMap['TransactionId'] ??
                    rawMap['transactionId'] ??
                    rawMap['transaction_id'] ??
                    '')
                .toString()
                .trim();
      }
    }

    if (tpn.isEmpty || authKey.isEmpty) {
      if (!mounted) return;
      await _showCardTerminalNotConfiguredError();
      return;
    }

    final service = DejavooService(
      tpn: tpn,
      authKey: authKey,
      sandbox: SupabaseConfig.spinSandbox,
      requestProcessorSurcharge: false,
    );

    BuildContext? voidProgressDialogContext;
    var voidProgressVisible = false;

    Future<void> showVoidProgressDialog() async {
      if (!mounted || voidProgressVisible) return;
      voidProgressVisible = true;
      final ready = Completer<void>();

      unawaited(
        showDialog<void>(
          context: context,
          useRootNavigator: true,
          barrierDismissible: false,
          builder: (dialogContext) {
            voidProgressDialogContext = dialogContext;
            if (!ready.isCompleted) ready.complete();
            return PopScope(
              canPop: false,
              child: AlertDialog(
                content: SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.sync, size: 36),
                      SizedBox(height: 12),
                      Text(
                        'Processing Void',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Contacting processor and finalizing transaction...',
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 12),
                      LinearProgressIndicator(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );

      await ready.future.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
    }

    void hideVoidProgressDialog() {
      if (!voidProgressVisible) return;
      final dialogCtx = voidProgressDialogContext;
      if (dialogCtx != null && dialogCtx.mounted) {
        Navigator.of(dialogCtx, rootNavigator: true).pop();
      }
      voidProgressDialogContext = null;
      voidProgressVisible = false;
    }

    await showVoidProgressDialog();

    late final DejavooVoidResult result;
    try {
      final voidAmount = _voidRegisterAmount(detail);
      result = await service.voidSale(
        referenceId: referenceId,
        gatewayToken: gatewayToken,
        amount: voidAmount,
        paymentType: 'Credit',
      );
    } catch (error) {
      hideVoidProgressDialog();
      await _showCopyableOperationErrorDialog(
        title: 'Void Transaction Failed',
        message: 'Processor request failed: $error',
      );
      return;
    }

    if (!mounted) return;

    if (result.success) {
      final voidAmount = _voidRegisterAmount(detail);
      await _transactionSyncService.recordVoid(
        transactionHeaderId: detail['transaction_header_id']?.toString() ?? '',
        originalDetailId: detail['id']?.toString() ?? '',
        amount: voidAmount,
        referenceId: referenceId,
        authCode: detail['auth_code']?.toString() ?? '',
        cardLast4: detail['card_last4']?.toString() ?? '',
        cardType: detail['card_type']?.toString() ?? '',
      );

      await service.showDeviceMessage(message: 'Transaction Voided');
      hideVoidProgressDialog();
      try {
        await _runVoidReceiptOutputFlow(
          detail: detail,
          voidReferenceId: referenceId,
        );
        final customerTrackingData =
            _buildReceiptCustomerTrackingDataFromDetail(detail);
        final initialEmail = _preferredReceiptValue([
          customerTrackingData['email'],
          _postedEmail,
          _emailController.text,
        ]);
        final voidedAmount = _voidRegisterAmount(detail);
        await _showPostTransactionReceiptActionsDialog(
          title: 'Receipt Complete',
          amount: voidedAmount,
          cardType: _preferredReceiptValue([
            detail['voided_card_type'],
            detail['card_type'],
            'Card',
          ]),
          cardLast4: _preferredReceiptValue([
            detail['voided_card_last4'],
            detail['card_last4'],
          ]),
          authCode: _preferredReceiptValue([
            detail['voided_auth_code'],
            detail['auth_code'],
          ]),
          initialEmail: initialEmail,
          onPrintCustomer: () => _runSingleVoidReceiptCopyFlow(
            detail: detail,
            voidReferenceId: referenceId,
            copyLabel: 'Customer Copy',
          ),
          onEmailReceipt: (recipientEmail) => _emailVoidReceiptPdf(
            recipientEmail: recipientEmail,
            detail: detail,
            voidReferenceId: referenceId,
            amount: voidedAmount,
          ),
        );
      } finally {
        await service.setDeviceReadyForNextTransaction();
      }

      await _loadOpenBatch();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transaction voided successfully.')),
      );
      _scheduleBatchReconcile(reason: 'void-success');
    } else {
      final errorParts = <String>[
        result.message,
        'reference_id: $referenceId',
        if (gatewayToken.isNotEmpty) 'gateway_token: $gatewayToken',
        if (result.rawResponse != null && result.rawResponse!.trim().isNotEmpty)
          'raw_response: ${result.rawResponse!}',
      ];
      hideVoidProgressDialog();
      await _showCopyableOperationErrorDialog(
        title: 'Void Transaction Failed',
        message: errorParts.join('\n\n'),
      );
    }
  }

  Future<void> _refundClosedCard(Map<String, dynamic> detail) async {
    final originalAmount =
        ((detail['original_amount'] ?? detail['amount']) as num?)
            ?.toDouble()
            .abs() ??
        0;
    final surchargeAmount =
        ((detail['surcharge_amount'] ?? detail['fee_amount']) as num?)
            ?.toDouble()
            .abs() ??
        0;
    final tipAdjustmentAmount =
        (detail['tip_adjustment_total'] as num?)?.toDouble() ?? 0;
    final grossOriginalAmount = detail['display_amount'] != null
        ? ((detail['display_amount'] as num?)?.toDouble().abs() ?? 0)
        : originalAmount + surchargeAmount + tipAdjustmentAmount;
    final refundableAmount =
        (detail['refundable_amount'] as num?)?.toDouble().abs() ??
        grossOriginalAmount;
    final refundedAmount =
        (detail['refunded_amount'] as num?)?.toDouble().abs() ?? 0;
    final referenceId = detail['reference_id']?.toString() ?? '';
    final transactionHeaderId =
        detail['transaction_header_id']?.toString() ?? '';
    final originalDetailId = detail['id']?.toString() ?? '';
    final cardType = detail['card_type']?.toString() ?? '';
    final cardLast4 = detail['card_last4']?.toString() ?? '';
    var gatewayToken = detail['gateway_token']?.toString().trim() ?? '';

    if (gatewayToken.isEmpty) {
      final raw = detail['gateway_raw'];
      Map<String, dynamic>? rawMap;
      if (raw is Map) {
        rawMap = Map<String, dynamic>.from(raw);
      } else if (raw is String && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            rawMap = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
      }

      if (rawMap != null) {
        gatewayToken =
            (rawMap['gatewayToken'] ??
                    rawMap['gateway_token'] ??
                    rawMap['TransactionId'] ??
                    rawMap['transactionId'] ??
                    rawMap['transaction_id'] ??
                    rawMap['RefNum'] ??
                    '')
                .toString()
                .trim();
      }
    }

    if (refundableAmount <= 0 ||
        referenceId.isEmpty ||
        transactionHeaderId.isEmpty ||
        originalDetailId.isEmpty) {
      if (!mounted) return;
      await _showCopyableOperationErrorDialog(
        title: 'Refund Reference Data Missing',
        message:
            'This closed sale is missing the reference data required to process a refund.\n\n'
            'A settled sale must include transaction_header_id, original detail id, processor reference id, and a positive refundable amount.',
      );
      return;
    }

    final refundRequest = await _promptRefundRequest(
      detail: detail,
      maxAmount: refundableAmount,
    );
    if (refundRequest == null || !mounted) return;

    final amount = refundRequest.amount;
    final reason = refundRequest.reason.trim();
    final refundRequestReferenceId =
        'RF-${DateTime.now().millisecondsSinceEpoch}';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Process Refund?'),
        content: Text(
          'Refund \$${amount.toStringAsFixed(2)} '
          '${cardType.isNotEmpty ? cardType : 'Card'}'
          '${cardLast4.isNotEmpty ? ' ****$cardLast4' : ''}?\n\n'
          'Original Sale: \$${originalAmount.toStringAsFixed(2)}\n'
          'Surcharge: \$${surchargeAmount.toStringAsFixed(2)}\n'
          'Tip Adjustment: \$${tipAdjustmentAmount.toStringAsFixed(2)}\n'
          'Total Eligible: \$${grossOriginalAmount.toStringAsFixed(2)}\n'
          'Previously Refunded: \$${refundedAmount.toStringAsFixed(2)}\n'
          'Remaining After This Refund: \$${(refundableAmount - amount).toStringAsFixed(2)}'
          '${reason.isNotEmpty ? '\n\nRefund Reason: $reason' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _themeOrange),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Refund'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final tpn = TerminalConfig.spinTpn;
    final authKey = TerminalConfig.spinAuthKey;
    if (tpn.isEmpty || authKey.isEmpty) {
      if (!mounted) return;
      await _showCardTerminalNotConfiguredError();
      return;
    }

    final service = DejavooService(
      tpn: tpn,
      authKey: authKey,
      sandbox: SupabaseConfig.spinSandbox,
      requestProcessorSurcharge: false,
    );
    final messenger = ScaffoldMessenger.of(context);

    BuildContext? refundProgressDialogContext;
    var refundProgressVisible = false;

    Future<void> showRefundProgressDialog() async {
      if (!mounted || refundProgressVisible) return;
      refundProgressVisible = true;
      final ready = Completer<void>();

      unawaited(
        showDialog<void>(
          context: context,
          useRootNavigator: true,
          barrierDismissible: false,
          builder: (dialogContext) {
            refundProgressDialogContext = dialogContext;
            if (!ready.isCompleted) ready.complete();
            return PopScope(
              canPop: false,
              child: AlertDialog(
                content: SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.reply_rounded, size: 36),
                      SizedBox(height: 12),
                      Text(
                        'Processing Refund',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Contacting processor and finalizing return...',
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 12),
                      LinearProgressIndicator(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );

      await ready.future.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
    }

    void hideRefundProgressDialog() {
      if (!refundProgressVisible) return;
      final dialogCtx = refundProgressDialogContext;
      if (dialogCtx != null && dialogCtx.mounted) {
        Navigator.of(dialogCtx, rootNavigator: true).pop();
      }
      refundProgressDialogContext = null;
      refundProgressVisible = false;
    }

    await showRefundProgressDialog();

    late final DejavooRefundResult result;
    try {
      result = await service.refundSale(
        amount: amount,
        // Use the original sale processor reference for a linked iPOS return.
        referenceId: referenceId,
        gatewayToken: gatewayToken,
      );
    } catch (error) {
      hideRefundProgressDialog();
      await _showCopyableOperationErrorDialog(
        title: 'Refund Failed',
        message: 'Processor request failed: $error',
      );
      return;
    }
    if (!mounted) return;

    if (result.success) {
      try {
        final refundDetailId = await _transactionSyncService.recordRefund(
          transactionHeaderId: transactionHeaderId,
          originalDetailId: originalDetailId,
          amount: amount,
          referenceId: refundRequestReferenceId,
          authCode: result.authCode ?? '',
          cardLast4: result.last4 ?? cardLast4,
          cardType: result.cardType ?? cardType,
          gatewayRaw: {
            'refund_reason': reason,
            'refund_entry_mode': 'manual_partial',
            'original_reference_id': referenceId,
            'refund_request_reference_id': refundRequestReferenceId,
            'original_sale_amount': originalAmount,
            'refunded_amount_before': refundedAmount,
            'refunded_amount_after': refundedAmount + amount,
            'refundable_amount_before': refundableAmount,
          },
        );
        if (!mounted) return;
        if (refundDetailId == null || refundDetailId.isEmpty) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text(
                'Refund approved, but the ledger verification row was not returned.',
              ),
            ),
          );
          return;
        }

        await service.showDeviceMessage(message: 'Refund Approved');
        if (_showTemporaryRefundVerification) {
          final verification = await _transactionSyncService
              .verifyRefundPersistence(
                refundDetailId: refundDetailId,
                originalDetailId: originalDetailId,
                transactionHeaderId: transactionHeaderId,
              );
          if (!mounted) return;
          await _showRefundVerificationDialog(verification);
        } else {
          messenger.showSnackBar(
            const SnackBar(content: Text('Refund processed successfully.')),
          );
        }
        hideRefundProgressDialog();
        await _runReturnReceiptOutputFlow(
          detail: detail,
          amount: amount,
          returnReferenceId: refundRequestReferenceId,
          refundNote: reason,
        );
        final customerTrackingData =
            _buildReceiptCustomerTrackingDataFromDetail(detail);
        final initialEmail = _preferredReceiptValue([
          customerTrackingData['email'],
          _postedEmail,
          _emailController.text,
        ]);
        await _showPostTransactionReceiptActionsDialog(
          title: 'Receipt Complete',
          amount: amount,
          cardType: _preferredReceiptValue([
            result.cardType,
            detail['card_type'],
            'Card',
          ]),
          cardLast4: _preferredReceiptValue([
            result.last4,
            detail['card_last4'],
          ]),
          authCode: _preferredReceiptValue([
            result.authCode,
            detail['auth_code'],
          ]),
          initialEmail: initialEmail,
          onPrintCustomer: () => _runSingleReturnReceiptCopyFlow(
            detail: detail,
            amount: amount,
            returnReferenceId: refundRequestReferenceId,
            refundNote: reason,
            copyLabel: 'Customer Copy',
          ),
          onEmailReceipt: (recipientEmail) => _emailReturnReceiptPdf(
            recipientEmail: recipientEmail,
            detail: detail,
            amount: amount,
            returnReferenceId: refundRequestReferenceId,
            refundNote: reason,
          ),
        );
        _scheduleBatchReconcile(reason: 'refund-success');
      } finally {
        await service.setDeviceReadyForNextTransaction();
      }
    } else {
      try {
        hideRefundProgressDialog();
        await _showCopyableOperationErrorDialog(
          title: 'Refund Failed',
          message: result.message,
        );
      } finally {
        await service.setDeviceReadyForNextTransaction();
      }
    }
  }

  Future<({double amount, String reason})?> _promptRefundRequest({
    required Map<String, dynamic> detail,
    required double maxAmount,
  }) async {
    final amountController = TextEditingController(
      text: maxAmount.toStringAsFixed(2),
    );
    amountController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: amountController.text.length,
    );
    final reasonController = TextEditingController();
    final reasonFocusNode = FocusNode();
    final amountDisplayFocusNode = FocusNode();
    final keypadFocusNode = FocusNode();
    bool overwriteOnNextInput = true;
    String? amountError;
    String? reasonError;

    final cardType = detail['card_type']?.toString().trim() ?? 'Card';
    final cardLast4 = detail['card_last4']?.toString().trim() ?? '';
    final invoiceReference =
        detail['invoice_reference']?.toString().trim() ?? '';
    final refundedAmount =
        (detail['refunded_amount'] as num?)?.toDouble().abs() ?? 0;

    if (!mounted) {
      amountController.dispose();
      reasonController.dispose();
      reasonFocusNode.dispose();
      amountDisplayFocusNode.dispose();
      keypadFocusNode.dispose();
      return null;
    }

    final resultCompleter = Completer<({double amount, String reason})?>();
    late OverlayEntry entry;
    BuildContext? dialogBuilderContext;
    bool overlayActive = true;

    final overlayState = Overlay.of(context, rootOverlay: true);
    Rect? anchorRect;
    final anchorContext = _terminalViewportKey.currentContext;
    if (anchorContext != null) {
      final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
      final anchorBox = anchorContext.findRenderObject() as RenderBox?;
      if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
        final topLeft = anchorBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        anchorRect = topLeft & anchorBox.size;
      }
    }

    void closeDialog([({double amount, String reason})? value]) {
      if (!overlayActive) return;
      overlayActive = false;
      entry.remove();
      if (!resultCompleter.isCompleted) {
        resultCompleter.complete(value);
      }
    }

    bool canUpdateDialog() {
      return overlayActive &&
          mounted &&
          (dialogBuilderContext?.mounted ?? false);
    }

    final dialogWidget = StatefulBuilder(
      builder: (context, setDialogState) {
        dialogBuilderContext = context;
        final cs = Theme.of(context).colorScheme;

        void setCaretToEnd() {
          amountController.selection = TextSelection.collapsed(
            offset: amountController.text.length,
          );
        }

        void safeSet(void Function() update) {
          if (!canUpdateDialog()) return;
          setDialogState(update);
        }

        void appendDigit(String digit) {
          safeSet(() {
            final baseCents = overwriteOnNextInput
                ? 0
                : ((double.tryParse(amountController.text.trim()) ?? 0) * 100)
                      .round();
            final nextCents = (baseCents * 10) + int.parse(digit);
            amountController.text = (nextCents / 100).toStringAsFixed(2);
            overwriteOnNextInput = false;
            amountError = null;
            setCaretToEnd();
          });
        }

        void backspace() {
          safeSet(() {
            final currentCents =
                ((double.tryParse(amountController.text.trim()) ?? 0) * 100)
                    .round();
            if (currentCents <= 0) {
              amountController.text = '0.00';
              overwriteOnNextInput = true;
              amountError = null;
              setCaretToEnd();
              return;
            }
            final nextCents = currentCents ~/ 10;
            amountController.text = (nextCents / 100).toStringAsFixed(2);
            overwriteOnNextInput = false;
            amountError = null;
            setCaretToEnd();
          });
        }

        void clearAmount() {
          safeSet(() {
            amountController.text = '0.00';
            overwriteOnNextInput = true;
            amountError = null;
            setCaretToEnd();
          });
        }

        void submitRefund() {
          final parsed = double.tryParse(amountController.text.trim());
          if (parsed == null || parsed <= 0) {
            safeSet(() {
              amountError = 'Enter a valid refund amount.';
            });
            return;
          }
          if (parsed > maxAmount) {
            safeSet(() {
              amountError =
                  'Refund amount cannot exceed remaining refundable balance (\$${maxAmount.toStringAsFixed(2)}).';
            });
            return;
          }
          if (reasonController.text.trim().length > 120) {
            safeSet(() {
              reasonError = 'Keep refund reason under 120 characters.';
            });
            return;
          }
          closeDialog((amount: parsed, reason: reasonController.text.trim()));
        }

        const padButtons = [
          '7',
          '8',
          '9',
          '4',
          '5',
          '6',
          '1',
          '2',
          '3',
          'Clear',
          '0',
          '<',
        ];

        Widget buildPadButton(String value) {
          final isClear = value == 'Clear';
          final isBackspace = value == '<';
          return Padding(
            padding: const EdgeInsets.all(2),
            child: FilledButton.tonal(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 46),
                backgroundColor: isClear
                    ? _themeRed
                    : isBackspace
                    ? _themeYellow
                    : null,
              ),
              onPressed: () {
                if (isBackspace) {
                  backspace();
                  return;
                }
                if (isClear) {
                  clearAmount();
                  return;
                }
                appendDigit(value);
              },
              child: isBackspace
                  ? const Icon(Icons.backspace_outlined, color: Colors.white)
                  : Text(
                      value,
                      style: TextStyle(
                        fontSize: isClear ? 13 : 18,
                        fontWeight: FontWeight.w700,
                        color: isClear ? Colors.white : null,
                      ),
                    ),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(color: Colors.black26),
              ),
            ),
            Center(
              child: LayoutBuilder(
                builder: (context, viewportConstraints) {
                  final dialogMaxWidth = (viewportConstraints.maxWidth - 20)
                      .clamp(300.0, 390.0)
                      .toDouble();
                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: dialogMaxWidth,
                      maxHeight: 620,
                    ),
                    child: AlertDialog(
                      insetPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      titlePadding: const EdgeInsets.fromLTRB(14, 10, 10, 2),
                      contentPadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      title: Row(
                        children: [
                          Icon(
                            Icons.reply_rounded,
                            color: _themeOrange,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Refund Amount',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          _buildKeyboardLaunchButton(
                            controller: reasonController,
                            title: 'Refund Reason Keyboard',
                            tooltip: 'Show keyboard for reason',
                          ),
                        ],
                      ),
                      content: Focus(
                        focusNode: keypadFocusNode,
                        autofocus: true,
                        onKeyEvent: (_, event) {
                          if (event is! KeyDownEvent) {
                            return KeyEventResult.ignored;
                          }

                          final key = event.logicalKey;
                          if (reasonFocusNode.hasFocus) {
                            if (key == LogicalKeyboardKey.escape) {
                              closeDialog();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          }

                          if (key == LogicalKeyboardKey.numpad0 ||
                              key == LogicalKeyboardKey.digit0) {
                            appendDigit('0');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad1 ||
                              key == LogicalKeyboardKey.digit1) {
                            appendDigit('1');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad2 ||
                              key == LogicalKeyboardKey.digit2) {
                            appendDigit('2');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad3 ||
                              key == LogicalKeyboardKey.digit3) {
                            appendDigit('3');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad4 ||
                              key == LogicalKeyboardKey.digit4) {
                            appendDigit('4');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad5 ||
                              key == LogicalKeyboardKey.digit5) {
                            appendDigit('5');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad6 ||
                              key == LogicalKeyboardKey.digit6) {
                            appendDigit('6');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad7 ||
                              key == LogicalKeyboardKey.digit7) {
                            appendDigit('7');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad8 ||
                              key == LogicalKeyboardKey.digit8) {
                            appendDigit('8');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad9 ||
                              key == LogicalKeyboardKey.digit9) {
                            appendDigit('9');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.backspace ||
                              key == LogicalKeyboardKey.delete) {
                            backspace();
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.enter ||
                              key == LogicalKeyboardKey.numpadEnter) {
                            submitRefund();
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.escape) {
                            closeDialog();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: SizedBox(
                          width: (dialogMaxWidth - 50).clamp(240.0, 340.0),
                          height: 525,
                          child: Column(
                            mainAxisSize: MainAxisSize.max,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '$cardType${cardLast4.isNotEmpty ? ' ****$cardLast4' : ''}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (invoiceReference.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 1),
                                  child: Text(
                                    'Invoice/Reference: $invoiceReference',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              Text(
                                'Already Refunded: \$${refundedAmount.toStringAsFixed(2)}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                'Remaining Refundable: \$${maxAmount.toStringAsFixed(2)}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: _themeOrange,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: amountController,
                                focusNode: amountDisplayFocusNode,
                                autofocus: false,
                                readOnly: true,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: cs.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  filled: true,
                                  fillColor: Colors.white,
                                  prefixText: '\$ ',
                                  prefixStyle: TextStyle(
                                    color: cs.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  labelText: 'Refund Amount',
                                  labelStyle: const TextStyle(fontSize: 11),
                                  hintText: 'Enter refund amount',
                                  errorText: amountError,
                                  border: const OutlineInputBorder(),
                                ),
                                onTap: setCaretToEnd,
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: GridView.count(
                                  crossAxisCount: 3,
                                  childAspectRatio: 1.72,
                                  physics: const NeverScrollableScrollPhysics(),
                                  children: padButtons
                                      .map(buildPadButton)
                                      .toList(),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: reasonController,
                                focusNode: reasonFocusNode,
                                maxLength: 120,
                                style: const TextStyle(fontSize: 12),
                                decoration: InputDecoration(
                                  isDense: true,
                                  counterStyle: const TextStyle(fontSize: 10),
                                  labelText: 'Refund Reference / Reason',
                                  labelStyle: const TextStyle(fontSize: 11),
                                  hintText: 'Optional note for this refund',
                                  hintStyle: const TextStyle(fontSize: 11),
                                  errorText: reasonError,
                                  border: const OutlineInputBorder(),
                                ),
                                onChanged: (_) {
                                  if (reasonError != null) {
                                    safeSet(() {
                                      reasonError = null;
                                    });
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: closeDialog,
                          child: const Text(
                            'Cancel',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _themeOrange,
                          ),
                          onPressed: submitRefund,
                          child: const Text(
                            'Process Refund',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );

    entry = OverlayEntry(
      builder: (_) {
        if (anchorRect == null) {
          return dialogWidget;
        }
        return Stack(
          children: [
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: dialogWidget,
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(entry);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (keypadFocusNode.canRequestFocus) {
        keypadFocusNode.requestFocus();
      }
    });
    final result = await resultCompleter.future;

    amountController.dispose();
    reasonController.dispose();
    reasonFocusNode.dispose();
    amountDisplayFocusNode.dispose();
    keypadFocusNode.dispose();
    return result;
  }

  Future<double?> _promptTipAdjustmentAmount({
    required double saleAmount,
    required double currentTipAmount,
    required String saleReferenceId,
    required String cardType,
    required String cardLast4,
    String invoiceReference = '',
  }) async {
    final amountController = TextEditingController(
      text: currentTipAmount.toStringAsFixed(2),
    );
    amountController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: amountController.text.length,
    );
    final amountDisplayFocusNode = FocusNode();
    final keypadFocusNode = FocusNode();
    bool overwriteOnNextInput = true;
    String? amountError;

    if (!mounted) {
      amountController.dispose();
      amountDisplayFocusNode.dispose();
      keypadFocusNode.dispose();
      return null;
    }

    final resultCompleter = Completer<double?>();
    late OverlayEntry entry;
    BuildContext? dialogBuilderContext;
    bool overlayActive = true;

    final overlayState = Overlay.of(context, rootOverlay: true);
    Rect? anchorRect;
    final anchorContext = _terminalViewportKey.currentContext;
    if (anchorContext != null) {
      final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
      final anchorBox = anchorContext.findRenderObject() as RenderBox?;
      if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
        final topLeft = anchorBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        anchorRect = topLeft & anchorBox.size;
      }
    }

    void closeDialog([double? value]) {
      if (!overlayActive) return;
      overlayActive = false;
      entry.remove();
      if (!resultCompleter.isCompleted) {
        resultCompleter.complete(value);
      }
    }

    bool canUpdateDialog() {
      return overlayActive &&
          mounted &&
          (dialogBuilderContext?.mounted ?? false);
    }

    final dialogWidget = StatefulBuilder(
      builder: (context, setDialogState) {
        dialogBuilderContext = context;
        final cs = Theme.of(context).colorScheme;

        void setCaretToEnd() {
          amountController.selection = TextSelection.collapsed(
            offset: amountController.text.length,
          );
        }

        void safeSet(void Function() update) {
          if (!canUpdateDialog()) return;
          setDialogState(update);
        }

        void appendDigit(String digit) {
          safeSet(() {
            final baseCents = overwriteOnNextInput
                ? 0
                : ((double.tryParse(amountController.text.trim()) ?? 0) * 100)
                      .round();
            final nextCents = (baseCents * 10) + int.parse(digit);
            amountController.text = (nextCents / 100).toStringAsFixed(2);
            overwriteOnNextInput = false;
            amountError = null;
            setCaretToEnd();
          });
        }

        void backspace() {
          safeSet(() {
            final currentCents =
                ((double.tryParse(amountController.text.trim()) ?? 0) * 100)
                    .round();
            if (currentCents <= 0) {
              amountController.text = '0.00';
              overwriteOnNextInput = true;
              amountError = null;
              setCaretToEnd();
              return;
            }
            final nextCents = currentCents ~/ 10;
            amountController.text = (nextCents / 100).toStringAsFixed(2);
            overwriteOnNextInput = false;
            amountError = null;
            setCaretToEnd();
          });
        }

        void clearAmount() {
          safeSet(() {
            amountController.text = '0.00';
            overwriteOnNextInput = true;
            amountError = null;
            setCaretToEnd();
          });
        }

        void submitTipAmount() {
          final parsed = double.tryParse(amountController.text.trim());
          if (parsed == null || parsed < 0) {
            safeSet(() {
              amountError = 'Enter a valid tip amount (0.00 or greater).';
            });
            return;
          }
          closeDialog(parsed);
        }

        const padButtons = [
          '7',
          '8',
          '9',
          '4',
          '5',
          '6',
          '1',
          '2',
          '3',
          'Clear',
          '0',
          '<',
        ];

        Widget buildPadButton(String value) {
          final isClear = value == 'Clear';
          final isBackspace = value == '<';
          return Padding(
            padding: const EdgeInsets.all(2),
            child: FilledButton.tonal(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 46),
                backgroundColor: isClear
                    ? _themeRed
                    : isBackspace
                    ? _themeYellow
                    : null,
              ),
              onPressed: () {
                if (isBackspace) {
                  backspace();
                  return;
                }
                if (isClear) {
                  clearAmount();
                  return;
                }
                appendDigit(value);
              },
              child: isBackspace
                  ? const Icon(Icons.backspace_outlined, color: Colors.white)
                  : Text(
                      value,
                      style: TextStyle(
                        fontSize: isClear ? 13 : 18,
                        fontWeight: FontWeight.w700,
                        color: isClear ? Colors.white : null,
                      ),
                    ),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(color: Colors.black26),
              ),
            ),
            Center(
              child: LayoutBuilder(
                builder: (context, viewportConstraints) {
                  final dialogMaxWidth = (viewportConstraints.maxWidth - 20)
                      .clamp(300.0, 390.0)
                      .toDouble();
                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: dialogMaxWidth,
                      maxHeight: 580,
                    ),
                    child: AlertDialog(
                      insetPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      titlePadding: const EdgeInsets.fromLTRB(14, 10, 10, 2),
                      contentPadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      title: Row(
                        children: [
                          Icon(
                            Icons.tips_and_updates_outlined,
                            color: _themeOrange,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Tip Adjustment',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      content: Focus(
                        focusNode: keypadFocusNode,
                        autofocus: true,
                        onKeyEvent: (_, event) {
                          if (event is! KeyDownEvent) {
                            return KeyEventResult.ignored;
                          }

                          final key = event.logicalKey;
                          if (key == LogicalKeyboardKey.numpad0 ||
                              key == LogicalKeyboardKey.digit0) {
                            appendDigit('0');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad1 ||
                              key == LogicalKeyboardKey.digit1) {
                            appendDigit('1');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad2 ||
                              key == LogicalKeyboardKey.digit2) {
                            appendDigit('2');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad3 ||
                              key == LogicalKeyboardKey.digit3) {
                            appendDigit('3');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad4 ||
                              key == LogicalKeyboardKey.digit4) {
                            appendDigit('4');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad5 ||
                              key == LogicalKeyboardKey.digit5) {
                            appendDigit('5');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad6 ||
                              key == LogicalKeyboardKey.digit6) {
                            appendDigit('6');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad7 ||
                              key == LogicalKeyboardKey.digit7) {
                            appendDigit('7');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad8 ||
                              key == LogicalKeyboardKey.digit8) {
                            appendDigit('8');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad9 ||
                              key == LogicalKeyboardKey.digit9) {
                            appendDigit('9');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.backspace ||
                              key == LogicalKeyboardKey.delete) {
                            backspace();
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.enter ||
                              key == LogicalKeyboardKey.numpadEnter) {
                            submitTipAmount();
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.escape) {
                            closeDialog();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: SizedBox(
                          width: (dialogMaxWidth - 50).clamp(240.0, 340.0),
                          height: 485,
                          child: Column(
                            mainAxisSize: MainAxisSize.max,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '$cardType${cardLast4.isNotEmpty ? ' ****$cardLast4' : ''}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (invoiceReference.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 1),
                                  child: Text(
                                    'Invoice/Reference: $invoiceReference',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              Text(
                                'Original Sale Amount: \$${saleAmount.toStringAsFixed(2)}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                'Current Tip: \$${currentTipAmount.toStringAsFixed(2)}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: _themeOrange,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (saleReferenceId.isNotEmpty)
                                Text(
                                  'Processor Ref: $saleReferenceId',
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: amountController,
                                focusNode: amountDisplayFocusNode,
                                autofocus: false,
                                readOnly: true,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: cs.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  filled: true,
                                  fillColor: Colors.white,
                                  prefixText: '\$ ',
                                  prefixStyle: TextStyle(
                                    color: cs.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  labelText: 'Tip Amount',
                                  labelStyle: const TextStyle(fontSize: 11),
                                  hintText: 'Enter tip amount',
                                  errorText: amountError,
                                  border: const OutlineInputBorder(),
                                ),
                                onTap: setCaretToEnd,
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: GridView.count(
                                  crossAxisCount: 3,
                                  childAspectRatio: 1.72,
                                  physics: const NeverScrollableScrollPhysics(),
                                  children: padButtons
                                      .map(buildPadButton)
                                      .toList(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: closeDialog,
                          child: const Text(
                            'Cancel',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _themeOrange,
                          ),
                          onPressed: submitTipAmount,
                          child: const Text(
                            'Apply Tip',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );

    entry = OverlayEntry(
      builder: (_) {
        if (anchorRect == null) {
          return dialogWidget;
        }
        return Stack(
          children: [
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: dialogWidget,
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(entry);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (keypadFocusNode.canRequestFocus) {
        keypadFocusNode.requestFocus();
      }
    });

    final result = await resultCompleter.future;
    amountController.dispose();
    amountDisplayFocusNode.dispose();
    keypadFocusNode.dispose();
    return result;
  }

  Future<void> _miscRefund() async {
    final refundRequest = await _promptMiscRefundRequest();
    if (refundRequest == null || !mounted) return;

    final amount = refundRequest.amount;
    final reason = refundRequest.reason.trim();
    final refundRequestReferenceId =
        'RF-${DateTime.now().millisecondsSinceEpoch}';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Process Misc Refund?'),
        content: Text(
          'Refund \$${amount.toStringAsFixed(2)} — no linked sale.\n'
          'A new transaction record will be created.'
          '${reason.isNotEmpty ? '\n\nReason: $reason' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _themeOrange),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Refund'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final tpn = TerminalConfig.spinTpn;
    final authKey = TerminalConfig.spinAuthKey;
    if (tpn.isEmpty || authKey.isEmpty) {
      if (!mounted) return;
      await _showCardTerminalNotConfiguredError();
      return;
    }

    final service = DejavooService(
      tpn: tpn,
      authKey: authKey,
      sandbox: SupabaseConfig.spinSandbox,
      requestProcessorSurcharge: false,
    );

    BuildContext? refundProgressDialogContext;
    var refundProgressVisible = false;

    Future<void> showRefundProgressDialog() async {
      if (!mounted || refundProgressVisible) return;
      refundProgressVisible = true;
      final ready = Completer<void>();
      unawaited(
        showDialog<void>(
          context: context,
          useRootNavigator: true,
          barrierDismissible: false,
          builder: (dialogContext) {
            refundProgressDialogContext = dialogContext;
            if (!ready.isCompleted) ready.complete();
            return PopScope(
              canPop: false,
              child: AlertDialog(
                content: SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.reply_rounded, size: 36),
                      SizedBox(height: 12),
                      Text(
                        'Processing Misc Refund',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Contacting processor and finalizing return...',
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 12),
                      LinearProgressIndicator(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
      await ready.future.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
    }

    void hideRefundProgressDialog() {
      if (!refundProgressVisible) return;
      final dialogCtx = refundProgressDialogContext;
      if (dialogCtx != null && dialogCtx.mounted) {
        Navigator.of(dialogCtx, rootNavigator: true).pop();
      }
      refundProgressDialogContext = null;
      refundProgressVisible = false;
    }

    await showRefundProgressDialog();

    late final DejavooRefundResult result;
    try {
      result = await service.refundSale(
        amount: amount,
        referenceId: refundRequestReferenceId,
      );
    } catch (error) {
      hideRefundProgressDialog();
      await _showCopyableOperationErrorDialog(
        title: 'Misc Refund Failed',
        message: 'Processor request failed: $error',
      );
      return;
    }
    if (!mounted) return;

    if (result.success) {
      try {
        final headerId = await _transactionSyncService.createTransactionHeader(
          subtotal: amount,
          tax: 0,
          total: amount,
        );
        if (!mounted) return;
        if (headerId != null && headerId.isNotEmpty) {
          await _transactionSyncService.recordRefund(
            transactionHeaderId: headerId,
            amount: amount,
            referenceId: refundRequestReferenceId,
            authCode: result.authCode ?? '',
            cardLast4: result.last4 ?? '',
            cardType: result.cardType ?? '',
            gatewayRaw: {
              'refund_reason': reason,
              'refund_entry_mode': 'misc',
              'refund_request_reference_id': refundRequestReferenceId,
            },
          );
        } else {
          debugPrint(
            '_miscRefund: createTransactionHeader returned null — detail NOT saved',
          );
        }
        await service.showDeviceMessage(message: 'Refund Approved');
        hideRefundProgressDialog();
        await _runReturnReceiptOutputFlow(
          detail: const {},
          amount: amount,
          returnReferenceId: refundRequestReferenceId,
          refundNote: reason,
        );
        final initialEmail = _preferredReceiptValue([
          _postedEmail,
          _emailController.text,
        ]);
        await _showPostTransactionReceiptActionsDialog(
          title: 'Receipt Complete',
          amount: amount,
          cardType: _preferredReceiptValue([result.cardType, 'Card']),
          cardLast4: _preferredReceiptValue([result.last4]),
          authCode: _preferredReceiptValue([result.authCode]),
          initialEmail: initialEmail,
          onPrintCustomer: () => _runSingleReturnReceiptCopyFlow(
            detail: const {},
            amount: amount,
            returnReferenceId: refundRequestReferenceId,
            refundNote: reason,
            copyLabel: 'Customer Copy',
          ),
          onEmailReceipt: (recipientEmail) => _emailReturnReceiptPdf(
            recipientEmail: recipientEmail,
            detail: const {},
            amount: amount,
            returnReferenceId: refundRequestReferenceId,
            refundNote: reason,
          ),
        );
        _scheduleBatchReconcile(reason: 'misc-refund');
      } finally {
        await service.setDeviceReadyForNextTransaction();
      }
    } else {
      try {
        hideRefundProgressDialog();
        await _showCopyableOperationErrorDialog(
          title: 'Misc Refund Failed',
          message: result.message,
        );
      } finally {
        await service.setDeviceReadyForNextTransaction();
      }
    }
  }

  Future<({double amount, String reason})?> _promptMiscRefundRequest() async {
    final amountController = TextEditingController(text: '0.00');
    amountController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: amountController.text.length,
    );
    final reasonController = TextEditingController();
    final reasonFocusNode = FocusNode();
    final amountDisplayFocusNode = FocusNode();
    final keypadFocusNode = FocusNode();
    bool overwriteOnNextInput = true;
    String? amountError;

    if (!mounted) {
      amountController.dispose();
      reasonController.dispose();
      reasonFocusNode.dispose();
      amountDisplayFocusNode.dispose();
      keypadFocusNode.dispose();
      return null;
    }

    final resultCompleter = Completer<({double amount, String reason})?>();
    late OverlayEntry entry;
    BuildContext? dialogBuilderContext;
    bool overlayActive = true;

    final overlayState = Overlay.of(context, rootOverlay: true);
    Rect? anchorRect;
    final anchorContext = _terminalViewportKey.currentContext;
    if (anchorContext != null) {
      final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
      final anchorBox = anchorContext.findRenderObject() as RenderBox?;
      if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
        final topLeft = anchorBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        anchorRect = topLeft & anchorBox.size;
      }
    }

    void closeDialog([({double amount, String reason})? value]) {
      if (!overlayActive) return;
      overlayActive = false;
      entry.remove();
      if (!resultCompleter.isCompleted) {
        resultCompleter.complete(value);
      }
    }

    bool canUpdateDialog() {
      return overlayActive &&
          mounted &&
          (dialogBuilderContext?.mounted ?? false);
    }

    final dialogWidget = StatefulBuilder(
      builder: (context, setDialogState) {
        dialogBuilderContext = context;
        final cs = Theme.of(context).colorScheme;

        void setCaretToEnd() {
          amountController.selection = TextSelection.collapsed(
            offset: amountController.text.length,
          );
        }

        void safeSet(void Function() update) {
          if (!canUpdateDialog()) return;
          setDialogState(update);
        }

        void appendDigit(String digit) {
          safeSet(() {
            final baseCents = overwriteOnNextInput
                ? 0
                : ((double.tryParse(amountController.text.trim()) ?? 0) * 100)
                      .round();
            final nextCents = (baseCents * 10) + int.parse(digit);
            amountController.text = (nextCents / 100).toStringAsFixed(2);
            overwriteOnNextInput = false;
            amountError = null;
            setCaretToEnd();
          });
        }

        void backspace() {
          safeSet(() {
            final currentCents =
                ((double.tryParse(amountController.text.trim()) ?? 0) * 100)
                    .round();
            if (currentCents <= 0) {
              amountController.text = '0.00';
              overwriteOnNextInput = true;
              amountError = null;
              setCaretToEnd();
              return;
            }
            final nextCents = currentCents ~/ 10;
            amountController.text = (nextCents / 100).toStringAsFixed(2);
            overwriteOnNextInput = false;
            amountError = null;
            setCaretToEnd();
          });
        }

        void clearAmount() {
          safeSet(() {
            amountController.text = '0.00';
            overwriteOnNextInput = true;
            amountError = null;
            setCaretToEnd();
          });
        }

        void submitRefund() {
          final parsed = double.tryParse(amountController.text.trim());
          if (parsed == null || parsed <= 0) {
            safeSet(() {
              amountError = 'Enter a valid refund amount.';
            });
            return;
          }
          closeDialog((amount: parsed, reason: reasonController.text.trim()));
        }

        const padButtons = [
          '7',
          '8',
          '9',
          '4',
          '5',
          '6',
          '1',
          '2',
          '3',
          'Clear',
          '0',
          '<',
        ];

        Widget buildPadButton(String value) {
          final isClear = value == 'Clear';
          final isBackspace = value == '<';
          return Padding(
            padding: const EdgeInsets.all(2),
            child: FilledButton.tonal(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 46),
                backgroundColor: isClear
                    ? _themeRed
                    : isBackspace
                    ? _themeYellow
                    : null,
              ),
              onPressed: () {
                if (isBackspace) {
                  backspace();
                  return;
                }
                if (isClear) {
                  clearAmount();
                  return;
                }
                appendDigit(value);
              },
              child: isBackspace
                  ? const Icon(Icons.backspace_outlined, color: Colors.white)
                  : Text(
                      value,
                      style: TextStyle(
                        fontSize: isClear ? 13 : 18,
                        fontWeight: FontWeight.w700,
                        color: isClear ? Colors.white : null,
                      ),
                    ),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(color: Colors.black26),
              ),
            ),
            Center(
              child: LayoutBuilder(
                builder: (context, viewportConstraints) {
                  final dialogMaxWidth = (viewportConstraints.maxWidth - 20)
                      .clamp(300.0, 390.0)
                      .toDouble();
                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: dialogMaxWidth,
                      maxHeight: 580,
                    ),
                    child: AlertDialog(
                      insetPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      titlePadding: const EdgeInsets.fromLTRB(14, 10, 10, 2),
                      contentPadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      title: Row(
                        children: [
                          Icon(
                            Icons.reply_rounded,
                            color: _themeOrange,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Misc Refund',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          _buildKeyboardLaunchButton(
                            controller: reasonController,
                            title: 'Refund Reason Keyboard',
                            tooltip: 'Show keyboard for reason',
                          ),
                        ],
                      ),
                      content: Focus(
                        focusNode: keypadFocusNode,
                        autofocus: true,
                        onKeyEvent: (_, event) {
                          if (event is! KeyDownEvent) {
                            return KeyEventResult.ignored;
                          }
                          final key = event.logicalKey;
                          if (reasonFocusNode.hasFocus) {
                            if (key == LogicalKeyboardKey.escape) {
                              closeDialog();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          }
                          if (key == LogicalKeyboardKey.numpad0 ||
                              key == LogicalKeyboardKey.digit0) {
                            appendDigit('0');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad1 ||
                              key == LogicalKeyboardKey.digit1) {
                            appendDigit('1');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad2 ||
                              key == LogicalKeyboardKey.digit2) {
                            appendDigit('2');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad3 ||
                              key == LogicalKeyboardKey.digit3) {
                            appendDigit('3');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad4 ||
                              key == LogicalKeyboardKey.digit4) {
                            appendDigit('4');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad5 ||
                              key == LogicalKeyboardKey.digit5) {
                            appendDigit('5');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad6 ||
                              key == LogicalKeyboardKey.digit6) {
                            appendDigit('6');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad7 ||
                              key == LogicalKeyboardKey.digit7) {
                            appendDigit('7');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad8 ||
                              key == LogicalKeyboardKey.digit8) {
                            appendDigit('8');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.numpad9 ||
                              key == LogicalKeyboardKey.digit9) {
                            appendDigit('9');
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.backspace ||
                              key == LogicalKeyboardKey.delete) {
                            backspace();
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.enter ||
                              key == LogicalKeyboardKey.numpadEnter) {
                            submitRefund();
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.escape) {
                            closeDialog();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: SizedBox(
                          width: (dialogMaxWidth - 50).clamp(240.0, 340.0),
                          height: 490,
                          child: Column(
                            mainAxisSize: MainAxisSize.max,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'No linked sale — standalone return',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: amountController,
                                focusNode: amountDisplayFocusNode,
                                autofocus: false,
                                readOnly: true,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: cs.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  prefixText: '\$ ',
                                  prefixStyle: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurfaceVariant,
                                  ),
                                  errorText: amountError,
                                  errorStyle: const TextStyle(fontSize: 10),
                                  border: const OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: reasonController,
                                focusNode: reasonFocusNode,
                                maxLines: 2,
                                maxLength: 120,
                                style: const TextStyle(fontSize: 11),
                                textInputAction: TextInputAction.done,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  hintText: 'Refund reason (optional)',
                                  hintStyle: TextStyle(fontSize: 11),
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Expanded(
                                child: GridView.count(
                                  crossAxisCount: 3,
                                  childAspectRatio: 1.6,
                                  physics: const NeverScrollableScrollPhysics(),
                                  children: padButtons
                                      .map(buildPadButton)
                                      .toList(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: closeDialog,
                          child: const Text(
                            'Cancel',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _themeOrange,
                          ),
                          onPressed: submitRefund,
                          child: const Text(
                            'Next',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );

    entry = OverlayEntry(
      builder: (_) {
        if (anchorRect == null) {
          return dialogWidget;
        }
        return Stack(
          children: [
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: dialogWidget,
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(entry);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (keypadFocusNode.canRequestFocus) {
        keypadFocusNode.requestFocus();
      }
    });
    final result = await resultCompleter.future;

    amountController.dispose();
    reasonController.dispose();
    reasonFocusNode.dispose();
    amountDisplayFocusNode.dispose();
    keypadFocusNode.dispose();
    return result;
  }

  Future<void> _showTransactionTypeDialog() async {
    if (!mounted) return;

    Future<void> openNext(Future<void> Function() action) async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      await action();
    }

    final completer = Completer<void>();
    late OverlayEntry entry;
    bool overlayActive = true;

    final overlayState = Overlay.of(context, rootOverlay: true);
    Rect? anchorRect;
    final anchorContext = _terminalViewportKey.currentContext;
    if (anchorContext != null) {
      final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
      final anchorBox = anchorContext.findRenderObject() as RenderBox?;
      if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
        final topLeft = anchorBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        anchorRect = topLeft & anchorBox.size;
      }
    }

    void closeDialog() {
      if (!overlayActive) return;
      overlayActive = false;
      entry.remove();
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    final dialogWidget = Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(color: Colors.black26),
          ),
        ),
        Center(
          child: LayoutBuilder(
            builder: (context, viewportConstraints) {
              final dialogMaxWidth = (viewportConstraints.maxWidth - 20)
                  .clamp(280.0, 380.0)
                  .toDouble();
              return ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: dialogMaxWidth,
                  maxHeight: 220,
                ),
                child: AlertDialog(
                  insetPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  titlePadding: const EdgeInsets.fromLTRB(14, 10, 8, 2),
                  contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  title: const Text(
                    'Transaction Type',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                  content: SizedBox(
                    width: (dialogMaxWidth - 40).clamp(220.0, 340.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Material(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                closeDialog();
                                unawaited(
                                  openNext(_showVoidableTransactionsDialog),
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                    width: 1,
                                  ),
                                ),
                                child: const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 52,
                                      height: 52,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Color(0xFFFFEBEE),
                                          borderRadius: BorderRadius.all(
                                            Radius.circular(18),
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.block,
                                          size: 28,
                                          color: Color(0xFFC62828),
                                        ),
                                      ),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      'Void',
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w400,
                                        height: 1.1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Material(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                closeDialog();
                                unawaited(
                                  openNext(_showRefundClosedTransactionsDialog),
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                    width: 1,
                                  ),
                                ),
                                child: const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 52,
                                      height: 52,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Color(0xFFFFF3E0),
                                          borderRadius: BorderRadius.all(
                                            Radius.circular(18),
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.reply_rounded,
                                          size: 28,
                                          color: Color(0xFFEF6C00),
                                        ),
                                      ),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      'Refund',
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w400,
                                        height: 1.1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: closeDialog,
                      child: const Text(
                        'Close',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );

    entry = OverlayEntry(
      builder: (_) {
        if (anchorRect == null) {
          return dialogWidget;
        }
        return Stack(
          children: [
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: dialogWidget,
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(entry);
    await completer.future;
  }

  Future<void> _showVoidableTransactionsDialog() async {
    if (!mounted) return;

    final completer = Completer<void>();
    late OverlayEntry entry;

    bool loading = true;
    String? loadError;
    String? selectedId;
    String searchQuery = '';
    bool showSearchKeyboard = false;
    List<Map<String, dynamic>> rows = const [];
    final voidListController = ScrollController();
    final searchController = TextEditingController();
    BuildContext? dialogBuilderContext;
    bool overlayActive = true;

    final overlayState = Overlay.of(context, rootOverlay: true);
    Rect? anchorRect;
    final anchorContext = _terminalViewportKey.currentContext;
    if (anchorContext != null) {
      final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
      final anchorBox = anchorContext.findRenderObject() as RenderBox?;
      if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
        final topLeft = anchorBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        anchorRect = topLeft & anchorBox.size;
      }
    }

    void closeDialog() {
      if (!overlayActive) return;
      overlayActive = false;
      entry.remove();
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    bool canUpdateDialog() {
      return overlayActive &&
          mounted &&
          (dialogBuilderContext?.mounted ?? false);
    }

    void safeSetDialogState(
      void Function(void Function()) setDialogState,
      void Function() update,
    ) {
      if (!canUpdateDialog()) return;
      setDialogState(update);
    }

    Future<void> loadRows(void Function(void Function()) setDialogState) async {
      safeSetDialogState(setDialogState, () {
        loading = true;
        loadError = null;
      });
      try {
        final fetchedRows = await _transactionSyncService
            .getOpenBatchCardDetails();
        if (!canUpdateDialog()) return;

        final openRows = fetchedRows
            .map((row) => Map<String, dynamic>.from(row))
            .where(
              (row) =>
                  (row['batch_status']?.toString().trim().toLowerCase() ??
                      '') ==
                  'o',
            )
            .toList();

        final openBatchSnapshot = _transactionSyncService
            .buildOpenBatchIntegritySnapshot(openRows);
        final loaded = List<Map<String, dynamic>>.from(
          openBatchSnapshot['rows'] as List,
        );

        safeSetDialogState(setDialogState, () {
          rows = loaded;
          loading = false;
          if (selectedId != null &&
              !rows.any((row) => row['id']?.toString() == selectedId)) {
            selectedId = null;
          }
          selectedId ??= rows.isNotEmpty ? rows.first['id']?.toString() : null;
        });
      } catch (error) {
        safeSetDialogState(setDialogState, () {
          loading = false;
          loadError = error.toString();
        });
      }
    }

    Future<bool> confirmVoidInFront(Map<String, dynamic> row) async {
      final completer = Completer<bool>();
      final amount = _voidRegisterAmount(row);
      final originalAmount = _voidOriginalAmount(row);
      final surchargeAmount = _voidSurchargeAmount(row);
      final tipAdjustmentAmount = _voidTipAdjustmentAmount(row);
      final cardType = row['card_type']?.toString() ?? '';
      final last4 = row['card_last4']?.toString() ?? '';
      final cs = Theme.of(context).colorScheme;

      late OverlayEntry confirmEntry;
      void resolve(bool value) {
        if (confirmEntry.mounted) {
          confirmEntry.remove();
        }
        if (!completer.isCompleted) {
          completer.complete(value);
        }
      }

      confirmEntry = OverlayEntry(
        builder: (_) => Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(color: Colors.black38),
              ),
            ),
            Center(
              child: LayoutBuilder(
                builder: (context, viewportConstraints) {
                  final dialogMaxWidth = (viewportConstraints.maxWidth - 20)
                      .clamp(280.0, 420.0)
                      .toDouble();
                  return ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: dialogMaxWidth),
                    child: AlertDialog(
                      title: const Text('Void Transaction?'),
                      content: Text(
                        'Void \$${amount.toStringAsFixed(2)} '
                        '$cardType ****$last4?\n\n'
                        'This will cancel the unsettled authorization at the processor.\n\n'
                        'Original Sale: \$${originalAmount.toStringAsFixed(2)}\n'
                        'Surcharge: \$${surchargeAmount.toStringAsFixed(2)}\n'
                        'Tip Adjustment: \$${tipAdjustmentAmount.toStringAsFixed(2)}\n'
                        'Confirmed Register Amount: \$${amount.toStringAsFixed(2)}\n'
                        'iPOS Void Amount: \$${amount.toStringAsFixed(2)}',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => resolve(false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: cs.error,
                          ),
                          onPressed: () => resolve(true),
                          child: const Text('Void'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );

      overlayState.insert(confirmEntry);
      return completer.future;
    }

    Future<void> runVoid(
      Map<String, dynamic> row,
      void Function(void Function()) setDialogState,
    ) async {
      final confirmed = await confirmVoidInFront(row);
      if (!confirmed) return;
      closeDialog();
      await _voidCard(row, skipConfirmation: true);
    }

    final dialogWidget = StatefulBuilder(
      builder: (context, setDialogState) {
        dialogBuilderContext = context;

        if (loading && rows.isEmpty && loadError == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!canUpdateDialog()) return;
            unawaited(loadRows(setDialogState));
          });
        }

        final selectedRow = selectedId == null
            ? null
            : rows.firstWhere(
                (row) => row['id']?.toString() == selectedId,
                orElse: () => <String, dynamic>{},
              );
        String searchableDate(DateTime? value) {
          if (value == null) return '';
          return _formatShortDate(value);
        }

        final q = searchQuery.trim().toLowerCase();
        final filteredRows = q.isEmpty
            ? rows
            : rows.where((row) {
                final amount =
                    ((row['display_amount'] ?? row['amount']) as num?)
                        ?.toDouble()
                        .abs() ??
                    0;
                final amountText = amount.toStringAsFixed(2).toLowerCase();
                final authCode =
                    row['auth_code']?.toString().trim().toLowerCase() ?? '';
                final last4 =
                    row['card_last4']?.toString().trim().toLowerCase() ?? '';
                final createdAt = row['created_at'] != null
                    ? DateTime.tryParse(row['created_at'].toString())?.toLocal()
                    : null;
                final dateKey = searchableDate(createdAt);
                final timeKey = createdAt != null
                    ? _formatTime(createdAt).toLowerCase()
                    : '';
                final invoiceReference =
                    row['invoice_reference']?.toString().trim().toLowerCase() ??
                    '';
                final txnSeq =
                    row['txn_seq']?.toString().trim().toLowerCase() ?? '';
                final referenceId = (row['reference_id'] ?? row['id'])
                    .toString()
                    .toLowerCase();
                final haystack =
                    '$amountText $authCode $last4 $dateKey $timeKey $invoiceReference $txnSeq $referenceId';
                return haystack.contains(q);
              }).toList();

        final hasSelection =
            selectedRow != null &&
            selectedRow.isNotEmpty &&
            filteredRows.any((row) => row['id']?.toString() == selectedId);

        void applySearchText(String next) {
          safeSetDialogState(setDialogState, () {
            searchController.text = next;
            searchController.selection = TextSelection.collapsed(
              offset: searchController.text.length,
            );
            searchQuery = next;
          });
        }

        Widget buildSearchKey(
          String key, {
          int flex = 1,
          VoidCallback? onPressed,
          Color? color,
        }) {
          return Expanded(
            flex: flex,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: EdgeInsets.zero,
                  backgroundColor: color,
                ),
                onPressed:
                    onPressed ??
                    () => applySearchText('${searchController.text}$key'),
                child: Center(
                  child: Text(
                    key,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(color: Colors.black26),
              ),
            ),
            Center(
              child: LayoutBuilder(
                builder: (context, viewportConstraints) {
                  final dialogMaxHeight = viewportConstraints.maxHeight * 0.97;
                  final contentHeight = dialogMaxHeight - 96;
                  final dialogMaxWidth = (viewportConstraints.maxWidth - 20)
                      .clamp(300.0, 1000.0);
                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: dialogMaxWidth,
                      maxHeight: dialogMaxHeight,
                    ),
                    child: AlertDialog(
                      insetPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      titlePadding: const EdgeInsets.fromLTRB(14, 10, 8, 2),
                      contentPadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      title: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Void Open Transaction',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () =>
                                unawaited(loadRows(setDialogState)),
                            tooltip: 'Refresh',
                            iconSize: 16,
                            splashRadius: 16,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                      content: SizedBox(
                        width: dialogMaxWidth,
                        height: contentHeight,
                        child: loading
                            ? const Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : loadError != null
                            ? Align(
                                alignment: Alignment.topLeft,
                                child: Text(
                                  'Failed to load voidable transactions: $loadError',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              )
                            : rows.isEmpty
                            ? const Align(
                                alignment: Alignment.topLeft,
                                child: Text(
                                  'No open card transactions are currently eligible for void.',
                                  style: TextStyle(fontSize: 11),
                                ),
                              )
                            : Column(
                                children: [
                                  TextField(
                                    controller: searchController,
                                    style: const TextStyle(fontSize: 11),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      hintText:
                                          'Search auth, date, amount, last4...',
                                      hintStyle: const TextStyle(fontSize: 11),
                                      prefixIcon: const Icon(
                                        Icons.search,
                                        size: 16,
                                      ),
                                      suffixIcon: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (searchQuery.trim().isNotEmpty)
                                            IconButton(
                                              tooltip: 'Clear search',
                                              iconSize: 14,
                                              splashRadius: 14,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              onPressed: () {
                                                safeSetDialogState(
                                                  setDialogState,
                                                  () {
                                                    searchController.clear();
                                                    searchQuery = '';
                                                  },
                                                );
                                              },
                                              icon: const Icon(Icons.clear),
                                            ),
                                          IconButton(
                                            tooltip: showSearchKeyboard
                                                ? 'Hide keyboard'
                                                : 'Show keyboard',
                                            iconSize: 15,
                                            splashRadius: 14,
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () {
                                              safeSetDialogState(
                                                setDialogState,
                                                () {
                                                  showSearchKeyboard =
                                                      !showSearchKeyboard;
                                                },
                                              );
                                            },
                                            icon: Icon(
                                              showSearchKeyboard
                                                  ? Icons.keyboard_hide_outlined
                                                  : Icons.keyboard_alt_outlined,
                                            ),
                                          ),
                                        ],
                                      ),
                                      border: const OutlineInputBorder(),
                                    ),
                                    onChanged: (value) {
                                      safeSetDialogState(setDialogState, () {
                                        searchQuery = value;
                                      });
                                    },
                                  ),
                                  const SizedBox(height: 6),
                                  Expanded(
                                    child: filteredRows.isEmpty
                                        ? const Align(
                                            alignment: Alignment.topLeft,
                                            child: Text(
                                              'No transactions match search criteria.',
                                              style: TextStyle(fontSize: 11),
                                            ),
                                          )
                                        : Scrollbar(
                                            controller: voidListController,
                                            thumbVisibility: true,
                                            interactive: true,
                                            thickness: 10,
                                            radius: const Radius.circular(8),
                                            child: ListView.separated(
                                              controller: voidListController,
                                              physics: const BouncingScrollPhysics(
                                                parent:
                                                    AlwaysScrollableScrollPhysics(),
                                              ),
                                              itemCount: filteredRows.length,
                                              separatorBuilder: (_, _) =>
                                                  const Divider(height: 1),
                                              itemBuilder: (context, index) {
                                                final row = filteredRows[index];
                                                final id =
                                                    row['id']?.toString() ?? '';
                                                final isSelected =
                                                    id == selectedId;
                                                final invoiceReference =
                                                    row['invoice_reference']
                                                        ?.toString()
                                                        .trim() ??
                                                    '';
                                                final amount =
                                                    ((row['display_amount'] ??
                                                                row['amount'])
                                                            as num?)
                                                        ?.toDouble()
                                                        .abs() ??
                                                    0;
                                                final originalAmount =
                                                    (row['amount'] as num?)
                                                        ?.toDouble()
                                                        .abs() ??
                                                    0;
                                                final surchargeAmount =
                                                    ((row['surcharge_amount']
                                                                    as num?)
                                                                ?.toDouble() ??
                                                            0)
                                                        .abs();
                                                final tipAdjustmentTotal =
                                                    (row['tip_adjustment_total']
                                                            as num?)
                                                        ?.toDouble() ??
                                                    0;
                                                final authCode =
                                                    row['auth_code']
                                                        ?.toString() ??
                                                    '';
                                                final txnSeq =
                                                    row['txn_seq']
                                                        ?.toString()
                                                        .trim() ??
                                                    '';
                                                final createdAt =
                                                    row['created_at'] != null
                                                    ? DateTime.tryParse(
                                                        row['created_at']
                                                            .toString(),
                                                      )?.toLocal()
                                                    : null;
                                                final dateStr =
                                                    createdAt != null
                                                    ? _formatShortDate(
                                                        createdAt,
                                                      )
                                                    : '';
                                                final timeStr =
                                                    createdAt != null
                                                    ? _formatTime(createdAt)
                                                    : '';
                                                final cardType =
                                                    row['card_type']
                                                            ?.toString()
                                                            .trim()
                                                            .isNotEmpty ==
                                                        true
                                                    ? row['card_type']
                                                          .toString()
                                                          .trim()
                                                    : 'Card';
                                                final last4 =
                                                    row['card_last4']
                                                        ?.toString() ??
                                                    '';

                                                return ListTile(
                                                  dense: true,
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  minLeadingWidth: 18,
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 0,
                                                      ),
                                                  selected: isSelected,
                                                  selectedTileColor:
                                                      Theme.of(context)
                                                          .colorScheme
                                                          .primaryContainer
                                                          .withAlpha(70),
                                                  onTap: () {
                                                    safeSetDialogState(
                                                      setDialogState,
                                                      () {
                                                        selectedId = id;
                                                      },
                                                    );
                                                  },
                                                  leading: Icon(
                                                    Icons.credit_card,
                                                    size: 15,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                                  ),
                                                  title: Text(
                                                    '\$${amount.toStringAsFixed(2)}  $cardType${last4.isNotEmpty ? ' ****$last4' : ''}',
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                                  subtitle: Text(
                                                    [
                                                      'Transaction #: ${txnSeq.isNotEmpty ? txnSeq : 'N/A'}',
                                                      'Original Transaction Amount: \$${originalAmount.toStringAsFixed(2)}',
                                                      if (surchargeAmount > 0)
                                                        'Surcharge: \$${surchargeAmount.toStringAsFixed(2)}',
                                                      if (dateStr.isNotEmpty ||
                                                          timeStr.isNotEmpty)
                                                        [dateStr, timeStr]
                                                            .where(
                                                              (part) => part
                                                                  .isNotEmpty,
                                                            )
                                                            .join(' '),
                                                      if (authCode.isNotEmpty)
                                                        'Auth: $authCode',
                                                      if (tipAdjustmentTotal >
                                                          0)
                                                        'Includes Tip Adjustment: +\$${tipAdjustmentTotal.toStringAsFixed(2)}',
                                                      if (invoiceReference
                                                          .isNotEmpty)
                                                        'Invoice/Reference: $invoiceReference',
                                                      'Processor Ref: ${(row['reference_id'] ?? row['id']).toString()}',
                                                    ].join('\n'),
                                                    style: const TextStyle(
                                                      fontSize: 9.5,
                                                      height: 1.15,
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                  ),
                                  if (showSearchKeyboard) ...[
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        for (final key in [
                                          '1',
                                          '2',
                                          '3',
                                          '4',
                                          '5',
                                          '6',
                                          '7',
                                          '8',
                                          '9',
                                          '0',
                                        ])
                                          buildSearchKey(key),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        for (final key in [
                                          'Q',
                                          'W',
                                          'E',
                                          'R',
                                          'T',
                                          'Y',
                                          'U',
                                          'I',
                                          'O',
                                          'P',
                                        ])
                                          buildSearchKey(key),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        for (final key in [
                                          'A',
                                          'S',
                                          'D',
                                          'F',
                                          'G',
                                          'H',
                                          'J',
                                          'K',
                                          'L',
                                        ])
                                          buildSearchKey(key),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        for (final key in [
                                          'Z',
                                          'X',
                                          'C',
                                          'V',
                                          'B',
                                          'N',
                                          'M',
                                        ])
                                          buildSearchKey(key),
                                        buildSearchKey(
                                          'BS',
                                          onPressed: () {
                                            final text = searchController.text;
                                            if (text.isEmpty) return;
                                            applySearchText(
                                              text.substring(
                                                0,
                                                text.length - 1,
                                              ),
                                            );
                                          },
                                          color: _themeYellow,
                                        ),
                                        buildSearchKey(
                                          'CLR',
                                          onPressed: () => applySearchText(''),
                                          color: _themeRed,
                                        ),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        buildSearchKey(
                                          'SPACE',
                                          flex: 4,
                                          onPressed: () => applySearchText(
                                            '${searchController.text} ',
                                          ),
                                        ),
                                        buildSearchKey('-'),
                                        buildSearchKey('/'),
                                        buildSearchKey('.'),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                      ),
                      actions: [
                        if (loadError != null)
                          TextButton.icon(
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              await Clipboard.setData(
                                ClipboardData(
                                  text:
                                      'Void Open Transaction\n\nFailed to load voidable transactions: $loadError',
                                ),
                              );
                              if (!mounted) return;
                              messenger.showSnackBar(
                                const SnackBar(content: Text('Error copied.')),
                              );
                            },
                            icon: const Icon(Icons.copy_all_outlined, size: 15),
                            label: const Text(
                              'Copy Error',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                        TextButton(
                          onPressed: closeDialog,
                          child: const Text(
                            'Close',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _themeRed,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                          ),
                          onPressed: hasSelection
                              ? () => unawaited(
                                  runVoid(selectedRow, setDialogState),
                                )
                              : null,
                          child: const Text(
                            'Void Selected',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );

    entry = OverlayEntry(
      builder: (_) {
        if (anchorRect == null) {
          return dialogWidget;
        }
        return Stack(
          children: [
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: dialogWidget,
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(entry);
    await completer.future;
    voidListController.dispose();
    searchController.dispose();
  }

  Future<void> _showRefundVerificationDialog(
    RefundVerificationResult result,
  ) async {
    final allPass = result.passed;
    final passColor = Colors.blue;
    final failColor = Colors.red;

    String headerValue(String key) {
      final value = result.headerRow?[key];
      return value?.toString() ?? '(missing)';
    }

    String refundValue(String key) {
      final value = result.refundRow?[key];
      return value?.toString() ?? '(missing)';
    }

    final reportText = _buildRefundVerificationReportText(result);

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              allPass ? Icons.check_circle : Icons.warning_amber_rounded,
              color: allPass ? passColor : failColor,
              size: 22,
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Temp Refund Verification',
                style: TextStyle(fontSize: 16),
              ),
            ),
            const Text(
              'DEV TOOL',
              style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
            ),
          ],
        ),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: allPass
                        ? Colors.blue.shade50
                        : Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    allPass
                        ? 'PASS — Refund row and header totals look correct.'
                        : 'FAIL — One or more refund checks failed.',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: allPass
                          ? Colors.blue.shade800
                          : Colors.orange.shade800,
                    ),
                  ),
                ),
                if (result.fetchError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Fetch error: ${result.fetchError}',
                    style: const TextStyle(color: Colors.red),
                  ),
                ],
                const SizedBox(height: 12),
                for (final check in result.checks)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          check.passed
                              ? Icons.check_circle_outline
                              : Icons.cancel_outlined,
                          size: 18,
                          color: check.passed ? passColor : failColor,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.black87,
                              ),
                              children: [
                                TextSpan(
                                  text: '${check.label}: ',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                TextSpan(
                                  text: check.detail,
                                  style: TextStyle(
                                    color: check.passed
                                        ? Colors.black87
                                        : Colors.red,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Refund Row',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                Text('id: ${refundValue('id')}'),
                Text('subtype: ${refundValue('subtype')}'),
                Text('amount: ${refundValue('amount')}'),
                Text('batch_status: ${refundValue('batch_status')}'),
                Text(
                  'original_detail_id: ${refundValue('original_detail_id')}',
                ),
                const SizedBox(height: 10),
                const Text(
                  'Header Summary',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                Text('id: ${headerValue('id')}'),
                Text('total: ${headerValue('total')}'),
                Text('amount_paid: ${headerValue('amount_paid')}'),
                Text('amount_due: ${headerValue('amount_due')}'),
                Text('status: ${headerValue('status')}'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: reportText));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Refund verification report copied.'),
                ),
              );
            },
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Copy Report'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCopyableOperationErrorDialog({
    required String title,
    required String message,
  }) async {
    final reportText = '$title\n\n$message';

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 22),
            const SizedBox(width: 8),
            Expanded(child: Text(title)),
          ],
        ),
        content: SizedBox(
          width: 560,
          child: SelectionArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.red.shade800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(message, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: reportText));
              if (!mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('$title copied.')));
            },
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Copy Error'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCardTerminalNotConfiguredError() async {
    await _showCopyableOperationErrorDialog(
      title: 'Card Terminal Not Configured',
      message:
          'SPIN_TPN and SPIN_AUTH_KEY must be set.\n\n'
          'Get these from the iPOSpays portal:\n'
          'S.T.E.A.M -> Edit Parameters -> select TPN -> Integrations -> SPIn -> Mode: Cloud',
    );
  }

  Future<void> _startManualCardFlow() async {
    if (!mounted) return;

    final cardAmount = double.tryParse(_currentInput.trim());
    if (cardAmount == null || cardAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter amount first, then press Card.')),
      );
      return;
    }

    final messenger = ScaffoldMessenger.of(context);

    // Refresh terminal config to ensure latest hpp token is loaded
    await _ensureTerminalConfigResolvedForSession(forceRefresh: true);

    final hppAuthToken = TerminalConfig.cardReaderHppAuthToken.trim();
    if (hppAuthToken.isEmpty) {
      if (!mounted) return;
      final terminalId = (LicenseService().activeContext?.terminalId ?? '')
          .trim();
      await _showCopyableOperationErrorDialog(
        title: 'Hosted Payment Not Configured',
        message:
            'This terminal has no card reader, so Card should use Hosted Payment Page.\n\n'
            'Set card_reader_hpp_auth_token in terminal settings for this terminal and try again.\n\n'
            '[DEBUG] Terminal ID: $terminalId\n'
            '[DEBUG] card_reader_type: ${TerminalConfig.cardReaderType}\n'
            '[DEBUG] HPP Token: (empty)\n'
            '[DEBUG] Loader: ${TerminalConfig.lastLoadDebug}',
      );
      return;
    }

    final referenceId = _pendingTransactionId.trim().isNotEmpty
        ? _pendingTransactionId.trim()
        : _nextHostedPaymentReferenceId();

    final service = HostedPaymentService();
    BuildContext? progressContext;
    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          progressContext = ctx;
          return const AlertDialog(
            title: Text('Processing Card'),
            content: SizedBox(
              height: 88,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 14),
                  Text('Preparing hosted payment page...'),
                ],
              ),
            ),
          );
        },
      );
    }

    late final HostedPaymentLinkResult result;
    try {
      result = await service.createPaymentLink(
        amount: cardAmount,
        referenceId: referenceId,
        hppAuthToken: hppAuthToken,
      );
    } finally {
      if (progressContext != null && progressContext!.mounted) {
        Navigator.of(progressContext!, rootNavigator: true).pop();
      }
    }

    if (!mounted) return;
    if (!result.success) {
      await _showCopyableOperationErrorDialog(
        title: 'Hosted Payment Failed',
        message: result.message,
      );
      return;
    }

    final paymentUri = Uri.tryParse(result.paymentUrl);
    if (paymentUri == null) {
      await _showCopyableOperationErrorDialog(
        title: 'Hosted Payment Failed',
        message: 'Hosted payment URL is invalid: ${result.paymentUrl}',
      );
      return;
    }

    var launched = await launchUrl(
      paymentUri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      launched = await launchUrl(paymentUri, mode: LaunchMode.platformDefault);
    }

    if (!launched) {
      await _showCopyableOperationErrorDialog(
        title: 'Hosted Payment URL',
        message:
            'Could not open the hosted payment page automatically.\n\n'
            'Open this URL manually:\n${result.paymentUrl}',
      );
      return;
    }

    final resolvedReference = result.referenceId.trim().isNotEmpty
        ? result.referenceId.trim()
        : referenceId;

    setState(() {
      final lines = <String>[
        'Amount: \$${cardAmount.toStringAsFixed(2)}',
        'Payment: Hosted Payment Page',
        'Status: Sent to hosted page (awaiting completion)',
        'Ref: $resolvedReference',
      ];
      _paymentHistory.add(lines.join('\n'));
      _lastTransactionInfoLines
        ..clear()
        ..addAll(lines);
      _lastCustomerInfoLines
        ..clear()
        ..addAll(_buildCurrentTransactionCustomerInfoLines());
    });

    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Hosted payment page opened. Complete payment there to finish transaction.',
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _findApprovedHostedPaymentDetail({
    required String referenceId,
    required double expectedAmount,
  }) async {
    final ref = referenceId.trim();
    if (ref.isEmpty) return null;

    final activeCtx = LicenseService().activeContext;
    var query = Supabase.instance.client
        .from('transaction_details')
        .select(
          'id,transaction_header_id,organization_id,location_id,payment_type,subtype,amount,fee_amount,status,batch_status,reference_id,auth_code,card_last4,card_type,gateway_provider,gateway_token,gateway_raw,created_at',
        )
        .eq('reference_id', ref);

    final orgId = (activeCtx?.organizationId ?? '').trim();
    final locId = (activeCtx?.locationId ?? '').trim();
    if (orgId.isNotEmpty && locId.isNotEmpty) {
      query = query.eq('organization_id', orgId).eq('location_id', locId);
    }

    final rows = List<Map<String, dynamic>>.from(
      await query.order('created_at', ascending: false).limit(25),
    );
    if (rows.isEmpty) return null;

    double parseMoney(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    final amountNeedle = expectedAmount.abs();
    Map<String, dynamic>? best;
    var bestScore = -1;

    for (final row in rows) {
      final status = (row['status']?.toString().toLowerCase() ?? '').trim();
      if (status != 'approved') continue;

      final subtype = (row['subtype']?.toString().toLowerCase() ?? '').trim();
      final paymentType = (row['payment_type']?.toString().toLowerCase() ?? '')
          .trim();
      final amount = parseMoney(row['amount']).abs();

      var score = 0;
      if (paymentType == 'd' || paymentType == 'card') score += 20;
      if (subtype == 's') score += 20;
      if ((amount - amountNeedle).abs() <= 0.01) score += 40;
      if ((row['auth_code']?.toString().trim() ?? '').isNotEmpty) score += 8;
      if ((row['card_last4']?.toString().trim() ?? '').isNotEmpty) score += 8;

      if (score > bestScore) {
        bestScore = score;
        best = row;
      }
    }

    return best;
  }

  Future<void> _applyHostedKeyedPaymentToSale({
    required double requestedAmount,
    required String referenceId,
    required Map<String, dynamic> detail,
  }) async {
    if (!mounted) return;

    double parseMoney(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    final amountPaid = parseMoney(detail['amount']).abs();
    final feeAmount = parseMoney(detail['fee_amount']).abs();
    final effectiveAmount = amountPaid > 0 ? amountPaid : requestedAmount;

    final headerId = detail['transaction_header_id']?.toString().trim() ?? '';
    if (headerId.isNotEmpty) {
      _lastReceiptIdDisplay = await _transactionSyncService
          .getReceiptIdDisplayForHeader(headerId);
    } else {
      _lastReceiptIdDisplay = '';
    }

    final authCode = detail['auth_code']?.toString().trim() ?? '';
    final cardLast4 = detail['card_last4']?.toString().trim() ?? '';
    final cardType = detail['card_type']?.toString().trim() ?? 'Card';
    final providerRef =
        detail['reference_id']?.toString().trim().isNotEmpty == true
        ? detail['reference_id'].toString().trim()
        : referenceId;

    setState(() {
      final displayReceiptId = formatReceiptIdForDisplay(_lastReceiptIdDisplay);
      final cardLine =
          '$cardType${cardLast4.isNotEmpty ? ' ****$cardLast4' : ''}';
      final lines = <String>[
        'Amount: \$${effectiveAmount.toStringAsFixed(2)}',
        if (feeAmount > 0) 'Surcharge: \$${feeAmount.toStringAsFixed(2)}',
        if (displayReceiptId.isNotEmpty) 'Receipt ID: $displayReceiptId',
        'Card: $cardLine',
        if (authCode.isNotEmpty) 'Auth: $authCode',
        if (providerRef.isNotEmpty) 'Ref: $providerRef',
      ];

      _cardPaymentDetails.add({
        'amount': effectiveAmount.toStringAsFixed(2),
        'feeAmount': feeAmount.toStringAsFixed(2),
        'processorRef': providerRef,
        'card': cardLine,
        'auth': authCode,
        'name': '',
      });

      _paymentHistory.add(lines.join('\n'));
      _lastTransactionInfoLines
        ..clear()
        ..addAll(lines);
      _lastCustomerInfoLines
        ..clear()
        ..addAll(_buildCurrentTransactionCustomerInfoLines());
      _currentInput = '';
    });

    await _transactionSyncService.saveTransaction(
      paymentType: 'card',
      amount: effectiveAmount,
      success: true,
      message:
          'Hosted keyed payment approved: \$${effectiveAmount.toStringAsFixed(2)} Auth:$authCode RefId:$providerRef',
      transactionHeaderId: headerId.isNotEmpty ? headerId : null,
    );

    final detailId = detail['id']?.toString().trim() ?? '';
    if (_transactionFlowParameters.integrityChecksEnabled &&
        headerId.isNotEmpty &&
        detailId.isNotEmpty) {
      await _runInlineTransactionIntegrityCheck(
        transactionHeaderId: headerId,
        transactionDetailId: detailId,
        amount: effectiveAmount,
        feeAmount: feeAmount,
        expectedBatchNumber: _activeHeaderBatchNumber,
        paymentType: 'd',
        subtype: 's',
        status: 'approved',
        processorReferenceId: providerRef,
        authCode: authCode,
        cardLast4: cardLast4,
        cardType: cardType,
        invoiceReference: _invoiceReference,
        serverId: _staffId,
        staffName: _staffName,
        terminalName: _terminalName,
      );
      if (!mounted) return;
    }

    var saleReceiptCopyCount = 2;
    try {
      final saleReceiptOptions = await _loadReceiptOutputOptions('sale');
      saleReceiptCopyCount = saleReceiptOptions.copyCount;
    } catch (_) {
      // Keep default behavior if receipt options cannot be loaded.
    }

    try {
      await _runSaleReceiptOutputFlow();
    } catch (_) {}

    if (saleReceiptCopyCount != 2) {
      final initialEmail = _preferredReceiptValue([
        _postedEmail,
        _emailController.text,
      ]);
      await _showPostTransactionReceiptActionsDialog(
        title: 'Card Approved',
        amount: effectiveAmount + feeAmount,
        cardType: _preferredReceiptValue([cardType, 'Card']),
        cardLast4: _preferredReceiptValue([cardLast4]),
        authCode: _preferredReceiptValue([authCode]),
        initialEmail: initialEmail,
        onPrintCustomer: () =>
            _runSingleSaleReceiptCopyFlow(copyLabel: 'Customer Copy'),
        onEmailReceipt: (recipientEmail) => _emailSaleReceiptPdf(
          recipientEmail: recipientEmail,
          amountPaid: effectiveAmount + feeAmount,
        ),
      );
      if (!mounted) return;
    }

    _clearItems(clearCustomerInfo: true);
    unawaited(_loadOpenBatch());
    _scheduleBatchReconcile(reason: 'hosted-keyed-approved');
    _pendingTransactionId = '';
  }

  Future<void> _startKeyCardInfoFlow() async {
    if (!mounted) return;

    final cardAmount = double.tryParse(_currentInput.trim());
    if (cardAmount == null || cardAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter amount first, then press Key Card Info.'),
        ),
      );
      return;
    }

    final allowed = await _runTransactionPreflight();
    if (!allowed || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    await _ensureTerminalConfigResolvedForSession(forceRefresh: true);

    final hppAuthToken = TerminalConfig.cardReaderHppAuthToken.trim();
    if (hppAuthToken.isEmpty) {
      final terminalId = (LicenseService().activeContext?.terminalId ?? '')
          .trim();
      await _showCopyableOperationErrorDialog(
        title: 'Hosted Payment Not Configured',
        message:
            'Set card_reader_hpp_auth_token in terminal settings for this terminal and try again.\n\n'
            '[DEBUG] Terminal ID: $terminalId\n'
            '[DEBUG] card_reader_type: ${TerminalConfig.cardReaderType}\n'
            '[DEBUG] HPP Token: (empty)\n'
            '[DEBUG] Loader: ${TerminalConfig.lastLoadDebug}',
      );
      return;
    }

    final referenceId = _pendingTransactionId.trim().isNotEmpty
        ? _pendingTransactionId.trim()
        : _nextHostedPaymentReferenceId();

    final activeContext = LicenseService().activeContext;
    if (activeContext == null) {
      await _showCopyableOperationErrorDialog(
        title: 'Hosted Payment Not Ready',
        message: 'License context is not available for this terminal.',
      );
      return;
    }

    final requestService = PaaayitRequestService();
    final result = await requestService.createRequest(
      organizationId: activeContext.organizationId,
      locationId: activeContext.locationId,
      terminalId: activeContext.terminalId,
      merchantId: TerminalConfig.spinTpn.trim(),
      transactionReferenceId: referenceId,
      customerEmail:
          'keycard+${referenceId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase()}@paaayit.local',
      customerName: 'Key Card Info',
      amount: cardAmount,
      hppAuthToken: hppAuthToken,
      calculateFee: _transactionFlowParameters.enableProcessorSurcharge,
      sendPaymentLink: false,
      requestCardToken: true,
      requestTitle: 'Key Card Info',
      paymentReference: referenceId,
    );

    if (!mounted) return;
    if (!result.success) {
      await _showCopyableOperationErrorDialog(
        title: 'Hosted Payment Failed',
        message: result.message,
      );
      return;
    }

    final referenceForPolling =
        result.hppTransactionReferenceId.trim().isNotEmpty
        ? result.hppTransactionReferenceId.trim()
        : referenceId;
    final paymentUri = Uri.tryParse(result.paymentUrl);
    if (paymentUri == null) {
      await _showCopyableOperationErrorDialog(
        title: 'Hosted Payment Failed',
        message: 'Hosted payment URL is invalid: ${result.paymentUrl}',
      );
      return;
    }

    Map<String, dynamic>? approved;
    var cancelled = false;
    Timer? pollTimer;
    var checking = false;
    var pollCount = 0;
    var statusText = 'Waiting for hosted payment completion...';
    var paymentLinkOpenInFlight = false;
    var paymentLinkOpened = false;
    var paymentLinkError = '';
    var connectingToSecureForm = false;

    Future<void> openPaymentLink(StateSetter setDialogState) async {
      if (paymentLinkOpenInFlight) return;
      paymentLinkOpenInFlight = true;

      try {
        if (!mounted) return;
        setDialogState(() {
          connectingToSecureForm = true;
        });

        var launched = await launchUrl(
          paymentUri,
          mode: LaunchMode.externalApplication,
        );
        if (!launched) {
          launched = await launchUrl(
            paymentUri,
            mode: LaunchMode.platformDefault,
          );
        }

        if (!mounted) return;
        setDialogState(() {
          paymentLinkOpened = launched;
          paymentLinkError = launched
              ? ''
              : 'Unable to open the secure card form automatically. Please check the browser and continue payment there.';
          statusText = launched
              ? 'Payment link opened in the browser. Waiting for approval...'
              : 'Payment link created. Open it manually to continue.';
        });
      } catch (error) {
        if (!mounted) return;
        setDialogState(() {
          paymentLinkOpened = false;
          paymentLinkError = 'Could not open the payment link: $error';
          statusText = 'Payment link created, but automatic launch failed.';
        });
      } finally {
        if (mounted) {
          setDialogState(() {
            connectingToSecureForm = false;
          });
        }
        paymentLinkOpenInFlight = false;
      }
    }

    Future<void> triggerHostedPaymentCancel() async {
      try {
        await requestService.cancelRequest(
          requestId: result.requestId,
          hppTransactionReferenceId: referenceForPolling,
          cancelReason: 'Cancelled from Key Card Info polling screen.',
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Hosted payment link cancelled. Close browser tab if it is still visible.',
            ),
          ),
        );
      } catch (error) {
        debugPrint('[HPP Cancel] ref=$referenceForPolling error=$error');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not cancel hosted payment link: $error'),
          ),
        );
      }
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        Future<void> runPoll(StateSetter setDialogState) async {
          if (checking || !mounted || !dialogContext.mounted) return;
          checking = true;
          pollCount += 1;

          try {
            try {
              await requestService.tempSyncPaid(
                hppTransactionReferenceId: referenceForPolling,
                expectedRequestNumber: result.requestNumber.trim().isNotEmpty
                    ? result.requestNumber.trim()
                    : null,
                expectedAmount: cardAmount,
              );
            } catch (error) {
              debugPrint(
                '[HPP TempSync] ref=$referenceForPolling attempt=$pollCount error=$error',
              );

              final errorText = error.toString().toLowerCase();
              if (pollCount >= 3 &&
                  errorText.contains('verification_call_failed')) {
                setDialogState(() {
                  statusText =
                      'Provider verification failed. Waiting for provider callback...';
                });
              }
            }

            final row = await _findApprovedHostedPaymentDetail(
              referenceId: referenceForPolling,
              expectedAmount: cardAmount,
            );

            if (!mounted || !dialogContext.mounted) return;

            if (row != null) {
              approved = row;
              pollTimer?.cancel();
              Navigator.of(dialogContext).pop();
              return;
            }

            setDialogState(() {
              statusText = 'Checking payment... attempt $pollCount';
            });
          } catch (error) {
            if (!mounted || !dialogContext.mounted) return;
            setDialogState(() {
              statusText =
                  'Check failed on attempt $pollCount. Retrying automatically...';
            });
            debugPrint('[HPP Poll] attempt=$pollCount error=$error');
          } finally {
            checking = false;
          }
        }

        return StatefulBuilder(
          builder: (context, setDialogState) {
            if (!paymentLinkOpened && !paymentLinkOpenInFlight) {
              unawaited(openPaymentLink(setDialogState));
            }

            pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
              unawaited(runPoll(setDialogState));
            });

            const pollingIcons = <IconData>[
              Icons.sync,
              Icons.autorenew,
              Icons.radar,
              Icons.wifi_tethering,
            ];
            final pollingIcon = pollingIcons[pollCount % pollingIcons.length];

            return AlertDialog(
              title: const Text(
                'Key Card Info',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: .2,
                ),
              ),
              content: SizedBox(
                width: 700,
                height: 560,
                child: Stack(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Center(
                          child: SizedBox(
                            width: 260,
                            child: RegisterSaleLogo(height: 54, widthFactor: 1),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Amount: \$${cardAmount.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            letterSpacing: .2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Reference: $referenceForPolling',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 14),
                        Center(
                          child: SizedBox(
                            width: 158,
                            height: 158,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                SizedBox(
                                  width: 156,
                                  height: 156,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 4,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.primary.withAlpha(35),
                                  ),
                                ),
                                Container(
                                  width: 148,
                                  height: 148,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Theme.of(context).colorScheme.primary,
                                        Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer,
                                      ],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary.withAlpha(110),
                                        blurRadius: 24,
                                        spreadRadius: 3,
                                        offset: const Offset(0, 10),
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    pollingIcon,
                                    size: 71,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Center(
                          child: Text(
                            'Attempt $pollCount',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Center(
                          child: Text(
                            'Auto-checking every 2 seconds',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withAlpha(140),
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Polling Secure Card Form',
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                statusText,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Please complete payment in the browser. This screen will automatically continue once approved.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              if (paymentLinkError.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Text(
                                  paymentLinkError,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (connectingToSecureForm)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black26,
                          alignment: Alignment.center,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 360),
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: const [
                                    Icon(Icons.lock_outline, size: 36),
                                    SizedBox(height: 12),
                                    Text(
                                      'Connecting to Secure Card Form',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 16,
                                      ),
                                    ),
                                    SizedBox(height: 12),
                                    CircularProgressIndicator(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelled = true;
                    pollTimer?.cancel();
                    unawaited(triggerHostedPaymentCancel());
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        );
      },
    );

    pollTimer?.cancel();

    if (!mounted || cancelled || approved == null) {
      return;
    }

    await _applyHostedKeyedPaymentToSale(
      requestedAmount: cardAmount,
      referenceId: referenceForPolling,
      detail: approved!,
    );
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Keyed card payment applied.')),
    );
  }

  Future<void> _finalizeApprovedCardSale({
    required double cardAmount,
    required DejavooSaleResult result,
    required String referenceId,
  }) async {
    if (!mounted) return;

    // Create transaction header first so both detail + screen_receipts share the same ID
    final feeAmount = result.feeAmount;
    final headerId = await _transactionSyncService.createTransactionHeader(
      subtotal: cardAmount,
      tax: 0,
      total: cardAmount,
      feeAmount: feeAmount,
      batchNumber: _activeHeaderBatchNumber,
      serverId: _staffId,
      staffName: _staffName,
      terminalName: _terminalName,
      invoiceReference: _invoiceReference,
      customerSnapshot: _buildCustomerSnapshot(),
    );

    if (headerId != null && headerId.isNotEmpty) {
      _lastReceiptIdDisplay = await _transactionSyncService
          .getReceiptIdDisplayForHeader(headerId);
    } else {
      _lastReceiptIdDisplay = '';
    }

    setState(() {
      final displayReceiptId = formatReceiptIdForDisplay(_lastReceiptIdDisplay);
      final cardholderText = (result.cardholderName ?? '').trim();
      final cardLine =
          '${result.cardType ?? 'Card'}${(result.last4 ?? '').trim().isNotEmpty ? ' ****${result.last4}' : ''}';
      final processorLines = <String>[
        'Amount: \$${cardAmount.toStringAsFixed(2)}',
        if (feeAmount > 0) 'Surcharge: \$${feeAmount.toStringAsFixed(2)}',
        if (displayReceiptId.isNotEmpty) 'Receipt ID: $displayReceiptId',
        if (cardLine.trim().isNotEmpty) 'Card: $cardLine',
        if ((result.authCode ?? '').trim().isNotEmpty)
          'Auth: ${result.authCode!.trim()}',
        if (cardholderText.isNotEmpty) 'Name: $cardholderText',
        if ((result.referenceId ?? referenceId).trim().isNotEmpty)
          'Ref: ${(result.referenceId ?? referenceId).trim()}',
      ];
      _cardPaymentDetails.add({
        'amount': cardAmount.toStringAsFixed(2),
        'feeAmount': feeAmount.toStringAsFixed(2),
        'processorRef': (result.referenceId ?? referenceId).trim(),
        'card':
            '${result.cardType ?? 'Card'}${(result.last4 ?? '').trim().isNotEmpty ? ' ****${result.last4}' : ''}',
        'auth': result.authCode ?? '',
        'name': cardholderText,
      });
      _paymentHistory.add(processorLines.join('\n'));
      _lastTransactionInfoLines
        ..clear()
        ..addAll(processorLines);
      _lastCustomerInfoLines
        ..clear()
        ..addAll(_buildCurrentTransactionCustomerInfoLines());
      _currentInput = '';
    });

    Map<String, dynamic>? gatewayRaw;
    if (result.rawResponse != null && result.rawResponse!.isNotEmpty) {
      try {
        gatewayRaw = Map<String, dynamic>.from(
          jsonDecode(result.rawResponse!) as Map,
        );
      } catch (_) {}
    }

    String detailId = '';
    if (headerId != null) {
      detailId =
          await _transactionSyncService.saveTransactionDetail(
            transactionHeaderId: headerId,
            paymentType: 'd',
            subtype: 's',
            amount: cardAmount,
            feeAmount: feeAmount,
            status: 'approved',
            referenceId: result.referenceId ?? referenceId,
            gatewayProvider: 'dejavoo',
            gatewayToken: result.gatewayToken ?? '',
            authCode: result.authCode ?? '',
            cardLast4: result.last4 ?? '',
            cardType: result.cardType ?? '',
            gatewayRaw: gatewayRaw,
          ) ??
          '';
    }

    await _transactionSyncService.saveTransaction(
      paymentType: 'card',
      amount: cardAmount,
      success: true,
      message:
          'Card approved: \$${cardAmount.toStringAsFixed(2)} '
          'Auth:${result.authCode ?? ''} '
          'RefId:${result.referenceId ?? referenceId}',
      transactionHeaderId: headerId,
    );

    await _persistLatestTransactionIntegritySnapshot(
      transactionHeaderId: headerId ?? '',
      transactionDetailId: detailId,
      amount: cardAmount,
      feeAmount: feeAmount,
      expectedBatchNumber: _activeHeaderBatchNumber,
      paymentType: 'd',
      subtype: 's',
      status: 'approved',
      processorReferenceId: result.referenceId ?? referenceId,
      authCode: result.authCode ?? '',
      cardLast4: result.last4 ?? '',
      cardType: result.cardType ?? '',
    );

    var saleReceiptCopyCount = 2;
    try {
      final saleReceiptOptions = await _loadReceiptOutputOptions('sale');
      saleReceiptCopyCount = saleReceiptOptions.copyCount;
    } catch (_) {
      // Keep default behavior if receipt options cannot be loaded.
    }

    try {
      await _runSaleReceiptOutputFlow();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Auto-print failed: $error')));
      }
    }

    if (saleReceiptCopyCount != 2) {
      await _showTerminalApprovedActionsDialog(
        amount: cardAmount + feeAmount,
        result: result,
      );
      if (!mounted) return;
    }

    if (_transactionFlowParameters.integrityChecksEnabled) {
      await _runInlineTransactionIntegrityCheck(
        transactionHeaderId: headerId ?? '',
        transactionDetailId: detailId,
        amount: cardAmount,
        feeAmount: feeAmount,
        expectedBatchNumber: _activeHeaderBatchNumber,
        paymentType: 'd',
        subtype: 's',
        status: 'approved',
        processorReferenceId: result.referenceId ?? referenceId,
        authCode: result.authCode ?? '',
        cardLast4: result.last4 ?? '',
        cardType: result.cardType ?? '',
        invoiceReference: _invoiceReference,
        serverId: _staffId,
        staffName: _staffName,
        terminalName: _terminalName,
      );
      if (!mounted) return;
    }

    _clearItems(clearCustomerInfo: true);
    unawaited(_loadOpenBatch());
    _scheduleBatchReconcile(reason: 'card-sale-approved');
    _pendingTransactionId = '';
  }

  Future<void> _showTerminalTextKeyboard({
    required TextEditingController controller,
    required String title,
    _TerminalKeyboardMode mode = _TerminalKeyboardMode.alphanumeric,
  }) async {
    if (!mounted) return;

    final completer = Completer<void>();
    late OverlayEntry entry;
    bool overlayActive = true;
    String value = controller.text;
    BuildContext? dialogBuilderContext;

    final overlayState = Overlay.of(context, rootOverlay: true);
    Rect? anchorRect;
    final anchorContext = _terminalViewportKey.currentContext;
    if (anchorContext != null) {
      final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
      final anchorBox = anchorContext.findRenderObject() as RenderBox?;
      if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
        final topLeft = anchorBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        anchorRect = topLeft & anchorBox.size;
      }
    }

    void closeDialog([bool apply = false]) {
      if (!overlayActive) return;
      overlayActive = false;
      entry.remove();
      if (apply) {
        controller.text = value;
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    bool canUpdateDialog() {
      return overlayActive &&
          mounted &&
          (dialogBuilderContext?.mounted ?? false);
    }

    final letterRows = <List<String>>[
      ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
      ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
      ['Z', 'X', 'C', 'V', 'B', 'N', 'M'],
    ];
    const numberRow = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
    final isNumericOnly = mode == _TerminalKeyboardMode.numeric;

    final dialogWidget = StatefulBuilder(
      builder: (context, setDialogState) {
        dialogBuilderContext = context;

        void safeSet(void Function() update) {
          if (!canUpdateDialog()) return;
          setDialogState(update);
        }

        Widget buildKey(String key, {Color? color}) {
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  backgroundColor: color,
                ),
                onPressed: () {
                  safeSet(() {
                    value += key;
                  });
                },
                child: Text(
                  key,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          );
        }

        Widget buildRow(List<String> keys) {
          return Row(children: [for (final key in keys) buildKey(key)]);
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(color: Colors.black26),
              ),
            ),
            Center(
              child: LayoutBuilder(
                builder: (context, viewportConstraints) {
                  final dialogMaxWidth = (viewportConstraints.maxWidth - 20)
                      .clamp(300.0, 430.0)
                      .toDouble();
                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: dialogMaxWidth,
                      maxHeight: 320,
                    ),
                    child: AlertDialog(
                      insetPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      titlePadding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
                      contentPadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      title: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      content: SizedBox(
                        width: (dialogMaxWidth - 40).clamp(240.0, 390.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Theme.of(context).dividerColor,
                                ),
                              ),
                              child: Text(
                                value.isEmpty ? '(empty)' : value,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            const SizedBox(height: 6),
                            buildRow(numberRow),
                            if (!isNumericOnly) ...[
                              const SizedBox(height: 2),
                              for (final row in letterRows) buildRow(row),
                            ],
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                if (!isNumericOnly)
                                  Expanded(
                                    flex: 2,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 2,
                                        vertical: 2,
                                      ),
                                      child: FilledButton.tonal(
                                        onPressed: () {
                                          safeSet(() {
                                            value += ' ';
                                          });
                                        },
                                        child: const Text(
                                          'SPACE',
                                          style: TextStyle(fontSize: 11),
                                        ),
                                      ),
                                    ),
                                  ),
                                buildKey('-'),
                                if (!isNumericOnly) buildKey('/'),
                                buildKey('.'),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                      vertical: 2,
                                    ),
                                    child: FilledButton.tonal(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: _themeYellow,
                                      ),
                                      onPressed: () {
                                        safeSet(() {
                                          if (value.isNotEmpty) {
                                            value = value.substring(
                                              0,
                                              value.length - 1,
                                            );
                                          }
                                        });
                                      },
                                      child: const Icon(
                                        Icons.backspace_outlined,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                      vertical: 2,
                                    ),
                                    child: FilledButton.tonal(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: _themeRed,
                                      ),
                                      onPressed: () {
                                        safeSet(() {
                                          value = '';
                                        });
                                      },
                                      child: const Text(
                                        'CLR',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => closeDialog(false),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        FilledButton(
                          onPressed: () => closeDialog(true),
                          child: const Text(
                            'Use Text',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );

    entry = OverlayEntry(
      builder: (_) {
        if (anchorRect == null) {
          return dialogWidget;
        }
        return Stack(
          children: [
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: dialogWidget,
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(entry);
    await completer.future;
  }

  Widget _buildKeyboardLaunchButton({
    required TextEditingController controller,
    required String title,
    TextInputType keyboardType = TextInputType.text,
    String tooltip = 'Show keyboard',
    double iconSize = 16,
  }) {
    final mode =
        keyboardType == TextInputType.number ||
            keyboardType == TextInputType.phone ||
            keyboardType == TextInputType.datetime ||
            keyboardType == const TextInputType.numberWithOptions() ||
            keyboardType ==
                const TextInputType.numberWithOptions(decimal: true) ||
            keyboardType ==
                const TextInputType.numberWithOptions(signed: true) ||
            keyboardType ==
                const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                )
        ? _TerminalKeyboardMode.numeric
        : _TerminalKeyboardMode.alphanumeric;

    return IconButton(
      tooltip: tooltip,
      iconSize: iconSize,
      splashRadius: 16,
      visualDensity: VisualDensity.compact,
      onPressed: () => unawaited(
        _showTerminalTextKeyboard(
          controller: controller,
          title: title,
          mode: mode,
        ),
      ),
      icon: const Icon(Icons.keyboard_alt_outlined),
    );
  }

  String _buildRefundVerificationReportText(RefundVerificationResult result) {
    final lines = <String>[
      'TEMP REFUND VERIFICATION',
      result.passed
          ? 'PASS - Refund row and header totals look correct.'
          : 'FAIL - One or more refund checks failed.',
    ];

    if (result.fetchError != null && result.fetchError!.isNotEmpty) {
      lines.add('fetch_error=${result.fetchError}');
    }

    lines.add('');
    lines.add('Checks');
    for (final check in result.checks) {
      lines.add(
        '${check.passed ? 'PASS' : 'FAIL'} | ${check.label} | ${check.detail}',
      );
    }

    void appendSection(String title, Map<String, dynamic>? row) {
      lines.add('');
      lines.add(title);
      if (row == null || row.isEmpty) {
        lines.add('(missing)');
        return;
      }
      final sortedKeys = row.keys.toList()..sort();
      for (final key in sortedKeys) {
        lines.add('$key=${row[key]}');
      }
    }

    appendSection('Refund Row', result.refundRow);
    appendSection('Original Row', result.originalRow);
    appendSection('Header Row', result.headerRow);

    return lines.join('\n');
  }

  Future<void> _showRefundClosedTransactionsDialog() async {
    if (!mounted) return;

    final completer = Completer<void>();
    late OverlayEntry entry;

    bool loading = true;
    bool refundInFlight = false;
    String searchQuery = '';
    bool showSearchKeyboard = false;
    List<Map<String, dynamic>> rows = const [];
    String? loadError;
    final refundListController = ScrollController();
    final searchController = TextEditingController();
    BuildContext? dialogBuilderContext;
    bool overlayActive = true;

    final overlayState = Overlay.of(context, rootOverlay: true);
    Rect? anchorRect;
    final anchorContext = _terminalViewportKey.currentContext;
    if (anchorContext != null) {
      final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
      final anchorBox = anchorContext.findRenderObject() as RenderBox?;
      if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
        final topLeft = anchorBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        anchorRect = topLeft & anchorBox.size;
      }
    }

    void closeDialog() {
      if (!overlayActive) return;
      overlayActive = false;
      entry.remove();
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    bool canUpdateDialog() {
      return overlayActive &&
          mounted &&
          (dialogBuilderContext?.mounted ?? false);
    }

    void safeSetDialogState(
      void Function(void Function()) setDialogState,
      void Function() update,
    ) {
      if (!canUpdateDialog()) return;
      setDialogState(update);
    }

    Future<void> loadRows(void Function(void Function()) setDialogState) async {
      safeSetDialogState(setDialogState, () {
        loading = true;
        loadError = null;
      });
      try {
        final loaded = await _transactionSyncService
            .getRefundableClosedCardDetails();
        safeSetDialogState(setDialogState, () {
          rows = loaded;
          loading = false;
        });
      } catch (error) {
        safeSetDialogState(setDialogState, () {
          loadError = error.toString();
          loading = false;
        });
      }
    }

    final dialogWidget = StatefulBuilder(
      builder: (context, setDialogState) {
        dialogBuilderContext = context;

        if (loading && rows.isEmpty && loadError == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!canUpdateDialog()) return;
            unawaited(loadRows(setDialogState));
          });
        }

        String searchableDate(DateTime? value) {
          if (value == null) return '';
          return _formatShortDate(value);
        }

        final q = searchQuery.trim().toLowerCase();
        final filteredRows = q.isEmpty
            ? rows
            : rows.where((row) {
                final amount =
                    ((row['display_amount'] ??
                                row['original_amount'] ??
                                row['amount'])
                            as num?)
                        ?.toDouble()
                        .abs() ??
                    0;
                final amountKey = amount.toStringAsFixed(2).toLowerCase();
                final authCode =
                    row['auth_code']?.toString().trim().toLowerCase() ?? '';
                final last4 =
                    row['card_last4']?.toString().trim().toLowerCase() ?? '';
                final receiptId =
                    row['receipt_id']?.toString().trim().toLowerCase() ?? '';
                final createdAt = row['created_at'] != null
                    ? DateTime.tryParse(row['created_at'].toString())?.toLocal()
                    : null;
                final dateKey = searchableDate(createdAt);
                final timeKey = createdAt != null
                    ? _formatTime(createdAt).toLowerCase()
                    : '';
                final invoiceReference =
                    row['invoice_reference']?.toString().trim().toLowerCase() ??
                    '';
                final haystack =
                    '$amountKey $authCode $last4 $receiptId $dateKey $timeKey $invoiceReference';
                return haystack.contains(q);
              }).toList();

        void applySearchText(String next) {
          safeSetDialogState(setDialogState, () {
            searchController.text = next;
            searchController.selection = TextSelection.collapsed(
              offset: searchController.text.length,
            );
            searchQuery = next;
          });
        }

        Widget buildSearchKey(
          String key, {
          int flex = 1,
          VoidCallback? onPressed,
          Color? color,
        }) {
          return Expanded(
            flex: flex,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: EdgeInsets.zero,
                  backgroundColor: color,
                ),
                onPressed:
                    onPressed ??
                    () => applySearchText('${searchController.text}$key'),
                child: Center(
                  child: Text(
                    key,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(color: Colors.black26),
              ),
            ),
            Center(
              child: LayoutBuilder(
                builder: (context, viewportConstraints) {
                  final dialogMaxHeight = viewportConstraints.maxHeight * 0.97;
                  final contentHeight = dialogMaxHeight - 96;
                  final dialogMaxWidth = (viewportConstraints.maxWidth - 20)
                      .clamp(300.0, 1000.0);
                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: dialogMaxWidth,
                      maxHeight: dialogMaxHeight,
                    ),
                    child: AlertDialog(
                      insetPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      titlePadding: const EdgeInsets.fromLTRB(14, 10, 8, 2),
                      contentPadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      title: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Refund Closed Sale',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Refresh',
                            onPressed: refundInFlight
                                ? null
                                : () => unawaited(loadRows(setDialogState)),
                            iconSize: 16,
                            splashRadius: 16,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                      content: SizedBox(
                        width: dialogMaxWidth,
                        height: contentHeight,
                        child: loading
                            ? const Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : loadError != null
                            ? Align(
                                alignment: Alignment.topLeft,
                                child: Text(
                                  'Failed to load refundable sales: $loadError',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              )
                            : rows.isEmpty
                            ? const Align(
                                alignment: Alignment.topLeft,
                                child: Text(
                                  'No closed card sales are currently eligible for refund.',
                                  style: TextStyle(fontSize: 11),
                                ),
                              )
                            : Column(
                                children: [
                                  TextField(
                                    controller: searchController,
                                    style: const TextStyle(fontSize: 11),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      hintText:
                                          'Search date, last4, auth code, receipt ID...',
                                      hintStyle: const TextStyle(fontSize: 11),
                                      prefixIcon: const Icon(
                                        Icons.search,
                                        size: 16,
                                      ),
                                      suffixIcon: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (searchQuery.trim().isNotEmpty)
                                            IconButton(
                                              tooltip: 'Clear search',
                                              iconSize: 14,
                                              splashRadius: 14,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              onPressed: () {
                                                safeSetDialogState(
                                                  setDialogState,
                                                  () {
                                                    searchController.clear();
                                                    searchQuery = '';
                                                  },
                                                );
                                              },
                                              icon: const Icon(Icons.clear),
                                            ),
                                          IconButton(
                                            tooltip: showSearchKeyboard
                                                ? 'Hide keyboard'
                                                : 'Show keyboard',
                                            iconSize: 15,
                                            splashRadius: 14,
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () {
                                              safeSetDialogState(
                                                setDialogState,
                                                () {
                                                  showSearchKeyboard =
                                                      !showSearchKeyboard;
                                                },
                                              );
                                            },
                                            icon: Icon(
                                              showSearchKeyboard
                                                  ? Icons.keyboard_hide_outlined
                                                  : Icons.keyboard_alt_outlined,
                                            ),
                                          ),
                                        ],
                                      ),
                                      border: const OutlineInputBorder(),
                                    ),
                                    onChanged: (value) {
                                      safeSetDialogState(setDialogState, () {
                                        searchQuery = value;
                                      });
                                    },
                                  ),
                                  const SizedBox(height: 6),
                                  Expanded(
                                    child: filteredRows.isEmpty
                                        ? const Align(
                                            alignment: Alignment.topLeft,
                                            child: Text(
                                              'No transactions match search criteria.',
                                              style: TextStyle(fontSize: 11),
                                            ),
                                          )
                                        : Scrollbar(
                                            controller: refundListController,
                                            thumbVisibility: true,
                                            interactive: true,
                                            thickness: 10,
                                            radius: const Radius.circular(8),
                                            child: ListView.separated(
                                              controller: refundListController,
                                              physics: const BouncingScrollPhysics(
                                                parent:
                                                    AlwaysScrollableScrollPhysics(),
                                              ),
                                              itemCount: filteredRows.length,
                                              separatorBuilder: (_, _) =>
                                                  const Divider(height: 1),
                                              itemBuilder: (context, index) {
                                                final row = filteredRows[index];
                                                final amount =
                                                    ((row['display_amount'] ??
                                                                row['original_amount'] ??
                                                                row['amount'])
                                                            as num?)
                                                        ?.toDouble()
                                                        .abs() ??
                                                    0;
                                                final surchargeAmount =
                                                    ((row['surcharge_amount'] ??
                                                                row['fee_amount'])
                                                            as num?)
                                                        ?.toDouble()
                                                        .abs() ??
                                                    0;
                                                final tipAdjustment =
                                                    (row['tip_adjustment_total']
                                                            as num?)
                                                        ?.toDouble() ??
                                                    0;
                                                final receiptId =
                                                    row['receipt_id']
                                                        ?.toString()
                                                        .trim() ??
                                                    '';
                                                final cardType =
                                                    row['card_type']
                                                        ?.toString() ??
                                                    'Card';
                                                final last4 =
                                                    row['card_last4']
                                                        ?.toString() ??
                                                    '';
                                                final authCode =
                                                    row['auth_code']
                                                        ?.toString() ??
                                                    '';
                                                final invoiceReference =
                                                    row['invoice_reference']
                                                        ?.toString()
                                                        .trim() ??
                                                    '';
                                                final createdAt =
                                                    row['created_at'] != null
                                                    ? DateTime.tryParse(
                                                        row['created_at']
                                                            .toString(),
                                                      )?.toLocal()
                                                    : null;
                                                final dateStr =
                                                    createdAt != null
                                                    ? _formatShortDate(
                                                        createdAt,
                                                      )
                                                    : '';
                                                final timeStr =
                                                    createdAt != null
                                                    ? _formatTime(createdAt)
                                                    : '';

                                                return ListTile(
                                                  dense: true,
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  minLeadingWidth: 18,
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 0,
                                                      ),
                                                  leading: Icon(
                                                    Icons.reply,
                                                    size: 15,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                                  ),
                                                  title: Text(
                                                    '\$${amount.toStringAsFixed(2)}  $cardType${last4.isNotEmpty ? ' ****$last4' : ''}',
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                  subtitle: Text(
                                                    [
                                                      if (dateStr.isNotEmpty ||
                                                          timeStr.isNotEmpty)
                                                        [dateStr, timeStr]
                                                            .where(
                                                              (part) => part
                                                                  .isNotEmpty,
                                                            )
                                                            .join(' '),
                                                      if (authCode.isNotEmpty)
                                                        'Auth: $authCode',
                                                      if (receiptId.isNotEmpty)
                                                        'Receipt ID: $receiptId',
                                                      if (invoiceReference
                                                          .isNotEmpty)
                                                        'Invoice/Reference: $invoiceReference',
                                                      'Surcharge: \$${surchargeAmount.toStringAsFixed(2)}  Tip Adj: \$${tipAdjustment.toStringAsFixed(2)}',
                                                      'Remaining refundable: \$${((row['refundable_amount'] as num?)?.toDouble().abs() ?? amount).toStringAsFixed(2)}',
                                                    ].join('\n'),
                                                    style: TextStyle(
                                                      fontSize: 9.5,
                                                      height: 1.15,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                    ),
                                                  ),
                                                  trailing: TextButton(
                                                    onPressed: refundInFlight
                                                        ? null
                                                        : () async {
                                                            safeSetDialogState(
                                                              setDialogState,
                                                              () {
                                                                refundInFlight =
                                                                    true;
                                                              },
                                                            );
                                                            closeDialog();
                                                            await _refundClosedCard(
                                                              row,
                                                            );
                                                          },
                                                    child: const Text(
                                                      'REFUND',
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                  ),
                                  if (showSearchKeyboard) ...[
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        for (final key in [
                                          '1',
                                          '2',
                                          '3',
                                          '4',
                                          '5',
                                          '6',
                                          '7',
                                          '8',
                                          '9',
                                          '0',
                                        ])
                                          buildSearchKey(key),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        for (final key in [
                                          'Q',
                                          'W',
                                          'E',
                                          'R',
                                          'T',
                                          'Y',
                                          'U',
                                          'I',
                                          'O',
                                          'P',
                                        ])
                                          buildSearchKey(key),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        for (final key in [
                                          'A',
                                          'S',
                                          'D',
                                          'F',
                                          'G',
                                          'H',
                                          'J',
                                          'K',
                                          'L',
                                        ])
                                          buildSearchKey(key),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        for (final key in [
                                          'Z',
                                          'X',
                                          'C',
                                          'V',
                                          'B',
                                          'N',
                                          'M',
                                        ])
                                          buildSearchKey(key),
                                        buildSearchKey(
                                          'BS',
                                          onPressed: () {
                                            final text = searchController.text;
                                            if (text.isEmpty) return;
                                            applySearchText(
                                              text.substring(
                                                0,
                                                text.length - 1,
                                              ),
                                            );
                                          },
                                          color: _themeYellow,
                                        ),
                                        buildSearchKey(
                                          'CLR',
                                          onPressed: () => applySearchText(''),
                                          color: _themeRed,
                                        ),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        buildSearchKey(
                                          'SPACE',
                                          flex: 4,
                                          onPressed: () => applySearchText(
                                            '${searchController.text} ',
                                          ),
                                        ),
                                        buildSearchKey('-'),
                                        buildSearchKey('/'),
                                        buildSearchKey('.'),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                      ),
                      actions: [
                        if (loadError != null)
                          TextButton.icon(
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              await Clipboard.setData(
                                ClipboardData(
                                  text:
                                      'Refund Closed Sale\n\nFailed to load refundable sales: $loadError',
                                ),
                              );
                              if (!mounted) return;
                              messenger.showSnackBar(
                                const SnackBar(content: Text('Error copied.')),
                              );
                            },
                            icon: const Icon(Icons.copy_all_outlined, size: 15),
                            label: const Text(
                              'Copy Error',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                        Opacity(
                          opacity: refundInFlight ? 0.38 : 1.0,
                          child: Material(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: refundInFlight
                                  ? null
                                  : () async {
                                      safeSetDialogState(setDialogState, () {
                                        refundInFlight = true;
                                      });
                                      closeDialog();
                                      await _miscRefund();
                                    },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 26,
                                      height: 26,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFFF3E0),
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: const Icon(
                                        Icons.reply_rounded,
                                        size: 14,
                                        color: Color(0xFFEF6C00),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Misc Refund',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w400,
                                        height: 1.1,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: refundInFlight ? null : closeDialog,
                          child: const Text(
                            'Close',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );

    entry = OverlayEntry(
      builder: (_) {
        if (anchorRect == null) {
          return dialogWidget;
        }
        return Stack(
          children: [
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: dialogWidget,
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(entry);
    await completer.future;
    refundListController.dispose();
    searchController.dispose();
  }

  Future<bool> _closeBatch({
    bool skipConfirm = false,
    bool isAutoClose = false,
  }) async {
    BuildContext? closingBatchDialogContext;
    var closingBatchDialogVisible = false;

    Future<void> showClosingBatchDialog() async {
      if (!mounted || closingBatchDialogVisible) return;
      closingBatchDialogVisible = true;
      final ready = Completer<void>();

      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          useRootNavigator: true,
          builder: (dialogContext) {
            closingBatchDialogContext = dialogContext;
            if (!ready.isCompleted) {
              ready.complete();
            }
            return PopScope(
              canPop: false,
              child: AlertDialog(
                content: SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      SizedBox(
                        width: 42,
                        height: 42,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                      SizedBox(height: 16),
                      Text(
                        'Closing Batch',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Settling card transactions with processor. Please wait...',
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 12),
                      LinearProgressIndicator(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );

      await ready.future.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
    }

    void hideClosingBatchDialog() {
      if (!closingBatchDialogVisible) return;
      final dialogCtx = closingBatchDialogContext;
      if (dialogCtx != null) {
        Navigator.of(dialogCtx, rootNavigator: true).pop();
      }
      closingBatchDialogContext = null;
      closingBatchDialogVisible = false;
    }

    String money(dynamic value) {
      final parsed = value is num
          ? value.toDouble()
          : double.tryParse(value?.toString() ?? '') ?? 0;
      final abs = parsed.abs().toStringAsFixed(2);
      return parsed < 0 ? '-\$$abs' : '\$$abs';
    }

    Future<String> showPreCloseAuditDialog(Map<String, dynamic> audit) async {
      final status = (audit['status']?.toString().toLowerCase() ?? '').trim();
      final local = Map<String, dynamic>.from(
        audit['local'] as Map<String, dynamic>? ?? const <String, dynamic>{},
      );
      final processor = Map<String, dynamic>.from(
        audit['processor'] as Map<String, dynamic>? ??
            const <String, dynamic>{},
      );
      final balanced = status == 'balanced';

      Widget metricRow({
        required String label,
        required dynamic count,
        required dynamic amount,
      }) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF244366),
                  ),
                ),
              ),
              Text(
                '${count ?? 0}',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 92,
                child: Text(
                  money(amount),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      }

      Widget totalsCard({
        required String title,
        required IconData icon,
        required Map<String, dynamic> values,
        required Color border,
        required Color background,
      }) {
        return Container(
          constraints: const BoxConstraints(minWidth: 250, maxWidth: 360),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: const Color(0xFF0A4FAF)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF143C73),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              metricRow(
                label: 'Sales + Surcharge + Tip Adj',
                count:
                    values['salesWithTipCount'] ??
                    ((values['saleCount'] as num?)?.toInt() ?? 0) +
                        ((values['tipAdjustCount'] as num?)?.toInt() ?? 0),
                amount:
                    values['salesWithTipAmount'] ??
                    ((values['saleAmount'] as num?)?.toDouble() ?? 0) +
                        ((values['tipAdjustAmount'] as num?)?.toDouble() ?? 0),
              ),
              metricRow(
                label: 'Refunds',
                count: values['refundCount'],
                amount:
                    values['refundSignedAmount'] ??
                    -((values['refundAmount'] as num?)?.toDouble() ?? 0),
              ),
              metricRow(
                label: 'Voids',
                count: values['voidCount'],
                amount:
                    values['voidSignedAmount'] ??
                    -((values['voidAmount'] as num?)?.toDouble() ?? 0),
              ),
              const Divider(height: 14),
              metricRow(label: 'Net', count: '', amount: values['netAmount']),
            ],
          ),
        );
      }

      final result = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 20,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 760,
                maxHeight: MediaQuery.of(ctx).size.height * 0.62,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: balanced
                            ? const [Color(0xFF0C6A3E), Color(0xFF2E9B6B)]
                            : const [Color(0xFF6C1F1F), Color(0xFFAF3D3D)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          balanced
                              ? Icons.verified_rounded
                              : Icons.warning_amber_rounded,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            balanced
                                ? 'Pre-Close Batch Audit: Balanced'
                                : 'Pre-Close Batch Audit: Action Required',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        totalsCard(
                          title: 'Local Batch Totals',
                          icon: Icons.storage_rounded,
                          values: local,
                          border: const Color(0xFFCFE1FA),
                          background: const Color(0xFFF5F9FF),
                        ),
                        totalsCard(
                          title: 'Processor Batch Totals (iPOS)',
                          icon: Icons.cloud_done_rounded,
                          values: processor,
                          border: const Color(0xFFD6EAD8),
                          background: const Color(0xFFF5FCF6),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop('cancel'),
                          child: const Text('Cancel'),
                        ),
                        if (balanced) ...[
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () => Navigator.of(ctx).pop('proceed'),
                            child: const Text('Proceed to Close Batch'),
                          ),
                        ] else ...[
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop('force'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF9A1F1F),
                              side: const BorderSide(color: Color(0xFFD99C9C)),
                            ),
                            child: const Text('Force Close (Override)'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      return result ?? 'cancel';
    }

    final batchRowsSnapshot = _openBatchCards
        .map((row) => Map<String, dynamic>.from(row))
        .toList();

    Future<int?> saveAndShowBatchReport({
      required bool accepted,
      required String processorStatus,
      required String processorMessage,
      String? processorCloseResponseRaw,
    }) async {
      final closedAt = DateTime.now();
      final activeLicense = LicenseService().activeContext;
      var report = _buildBatchCloseReportPayload(
        accepted: accepted,
        processorStatus: processorStatus,
        processorMessage: processorMessage,
        closedAt: closedAt,
        batchRows: batchRowsSnapshot,
      );

      if (accepted &&
          (processorCloseResponseRaw ?? '').trim().isNotEmpty &&
          TerminalConfig.spinTpn.isNotEmpty &&
          TerminalConfig.spinAuthKey.isNotEmpty) {
        report = await _transactionSyncService.verifyBatchReportIntegrity(
          report: report,
          tpn: TerminalConfig.spinTpn,
          authKey: TerminalConfig.spinAuthKey,
          sandbox: SupabaseConfig.spinSandbox,
        );
      }

      final closedBatchNumber = await _transactionSyncService
          .saveBatchCloseReport(
            accepted: accepted,
            processorStatus: processorStatus,
            processorMessage: processorMessage,
            terminalName: _terminalName,
            locationName: _locationName,
            organizationName: activeLicense?.organizationName ?? '',
            organizationNumber: activeLicense?.organizationNumber ?? '',
            closedAt: closedAt,
            batchRows: batchRowsSnapshot,
            reportOverride: report,
            processorCloseResponseRaw: processorCloseResponseRaw,
          );

      if (accepted && closedBatchNumber != null && mounted) {
        setState(() {
          _activeHeaderBatchNumber = closedBatchNumber + 1;
        });
      }

      if (!isAutoClose && mounted) {
        hideClosingBatchDialog();
        await _showBatchCloseReportPrintPreview(report);
      }

      return closedBatchNumber;
    }

    final approvedOpenIds = _openBatchCards
        .where((r) => r['status'] == 'approved')
        .map((r) => r['id'].toString())
        .toList();
    // Also include original_detail_id from void rows — the original sale row
    // is hidden from _openBatchCards (dedup logic) but still has batch_status='o'
    // in the DB.  We must close it too or it reappears after batch close.
    final suppressedOriginalIds = _openBatchCards
        .where((r) => (r['subtype']?.toString() ?? '') == 'v')
        .map((r) => r['original_detail_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    final allOpenIds = {
      ..._openBatchCards
          .map((r) => r['id'].toString())
          .where((id) => id.isNotEmpty),
      ...suppressedOriginalIds,
    }.toList();
    final openCount = approvedOpenIds.length;
    if (allOpenIds.isEmpty) return true;

    final tpn = TerminalConfig.spinTpn;
    final authKey = TerminalConfig.spinAuthKey;

    if (openCount <= 0) {
      final closed = await _transactionSyncService.markBatchClosed(allOpenIds);
      if (!closed) {
        await saveAndShowBatchReport(
          accepted: false,
          processorStatus: 'Not Accepted',
          processorMessage:
              'Processor close not required, but local batch rows could not be marked closed.',
        );
        if (!mounted) return false;
        await _showCopyableOperationErrorDialog(
          title: 'Batch close persistence failed',
          message:
              'Processor close was not required, but open batch rows could not be marked closed in the ledger.\n\nRetry after confirming backend is running on port 3000 and try Refresh in Open Batch.',
        );
        return false;
      }

      await saveAndShowBatchReport(
        accepted: true,
        processorStatus: 'Accepted (No Processor Call)',
        processorMessage:
            'No approved open transactions; open batch rows were closed locally.',
      );

      await _loadOpenBatch();
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAutoClose
                ? 'Auto-close complete: open voids cleared from batch.'
                : 'Open voids cleared from batch.',
          ),
        ),
      );
      return true;
    }

    if (tpn.isEmpty || authKey.isEmpty) {
      if (!mounted) return false;
      await _showCardTerminalNotConfiguredError();
      return false;
    }

    var forceCloseOverride = false;

    if (!skipConfirm) {
      final audit = await _transactionSyncService.buildPreCloseBatchAudit(
        localRows: batchRowsSnapshot,
        tpn: tpn,
        authKey: authKey,
        sandbox: SupabaseConfig.spinSandbox,
      );
      if (!mounted) return false;
      final decision = await showPreCloseAuditDialog(audit);
      if (!mounted || decision == 'cancel') return false;
      forceCloseOverride = decision == 'force';
    }

    final service = DejavooService(
      tpn: tpn,
      authKey: authKey,
      sandbox: SupabaseConfig.spinSandbox,
      requestProcessorSurcharge: false,
    );
    await showClosingBatchDialog();
    try {
      final result = await service.closeBatch();
      if (!mounted) return false;

      if (result.success) {
        final closed = await _transactionSyncService.markBatchClosed(
          allOpenIds,
        );
        if (!closed) {
          await saveAndShowBatchReport(
            accepted: false,
            processorStatus: 'Not Accepted',
            processorMessage:
                'Processor settlement succeeded, but local batch rows could not be marked closed.',
          );
          if (!mounted) return false;
          await _showCopyableOperationErrorDialog(
            title: 'Batch close persistence failed',
            message:
                'Processor settlement succeeded, but local open-batch rows could not be marked closed.\n\nRetry after confirming backend is running on port 3000 and then click Refresh in Open Batch.',
          );
          return false;
        }

        await saveAndShowBatchReport(
          accepted: true,
          processorStatus: forceCloseOverride
              ? 'Accepted (Force Close Override)'
              : 'Accepted',
          processorMessage: forceCloseOverride
              ? '${result.message} | FORCE_CLOSE_OVERRIDE: pre-close audit mismatch was overridden by operator.'
              : result.message,
          processorCloseResponseRaw: result.rawResponse,
        );

        await _loadOpenBatch();
        if (!mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isAutoClose
                  ? 'Auto-close complete: batch settled successfully.'
                  : 'Batch closed and settled successfully.',
            ),
          ),
        );
        _scheduleBatchReconcile(
          reason: isAutoClose ? 'auto-close-success' : 'manual-close-success',
        );
        return true;
      } else {
        final isAlreadyClosedAtProcessor =
            result.statusCode == '1012' &&
            (result.detailedMessage ?? '').toLowerCase().contains(
              'no transaction in the batch',
            );

        if (isAlreadyClosedAtProcessor) {
          final closed = await _transactionSyncService.markBatchClosed(
            allOpenIds,
          );
          if (!closed) {
            await saveAndShowBatchReport(
              accepted: false,
              processorStatus: 'Not Accepted',
              processorMessage:
                  'Processor reported already closed, but local batch rows could not be synchronized.',
            );
            if (!mounted) return false;
            await _showCopyableOperationErrorDialog(
              title: 'Batch close persistence failed',
              message:
                  'Processor reports no open transactions in batch, but local open-batch rows could not be marked closed.\n\nRetry after confirming backend is running on port 3000 and click Refresh in Open Batch.',
            );
            return false;
          }

          await saveAndShowBatchReport(
            accepted: true,
            processorStatus: 'Accepted (Already Closed)',
            processorMessage:
                'Processor reported no open transactions; local rows synchronized.',
            processorCloseResponseRaw: result.rawResponse,
          );

          await _loadOpenBatch();
          if (!mounted) return false;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Processor batch already closed; local open batch synchronized.',
              ),
            ),
          );
          _scheduleBatchReconcile(reason: 'processor-already-closed');
          return true;
        }

        await saveAndShowBatchReport(
          accepted: false,
          processorStatus: 'Not Accepted',
          processorMessage: result.message,
          processorCloseResponseRaw: result.rawResponse,
        );

        await _showCopyableOperationErrorDialog(
          title: 'Close batch failed',
          message: result.message,
        );
        return false;
      }
    } finally {
      try {
        await service.setDeviceReadyForNextTransaction();
      } catch (_) {
        // Best-effort: do not block close-batch completion if ready reset fails.
      }
      hideClosingBatchDialog();
    }
  }

  Future<void> _payByCard() async {
    if (!mounted) return;

    final hasTerminalCredentials =
        TerminalConfig.spinTpn.trim().isNotEmpty &&
        TerminalConfig.spinAuthKey.trim().isNotEmpty;

    if (TerminalConfig.hasPhysicalCardReader || hasTerminalCredentials) {
      await _payByDejavooTerminal();
      return;
    }

    await _startManualCardFlow();
  }

  // ignore: unused_element
  Future<void> _payByKeyedCard() async {
    // No-reader mode routes to hosted payment page using the terminal-level
    // HPP token, not direct PAN submission to terminal/reader paths.
    await _startManualCardFlow();
  }

  Future<void> _payByDejavooTerminal() async {
    if (!mounted) return;

    final cardAmount = double.tryParse(_currentInput.trim());
    if (cardAmount == null || cardAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter amount first, then press Card.')),
      );
      return;
    }

    final tpn = TerminalConfig.spinTpn;
    final authKey = TerminalConfig.spinAuthKey;

    if (tpn.isEmpty || authKey.isEmpty) {
      if (!mounted) return;
      await _showCardTerminalNotConfiguredError();
      return;
    }

    final referenceId = _pendingTransactionId.trim().isNotEmpty
        ? _pendingTransactionId.trim()
        : _nextTransactionId();

    final result = await showDejavooSaleDialog(
      context: context,
      amount: cardAmount,
      tpn: tpn,
      authKey: authKey,
      requestProcessorSurcharge:
          _transactionFlowParameters.enableProcessorSurcharge,
      sandbox: SupabaseConfig.spinSandbox,
      viewportAnchorKey: _terminalViewportKey,
    );

    if (!mounted) return;
    if (result == null || !result.isApproved) return;

    await _finalizeApprovedCardSale(
      cardAmount: cardAmount,
      result: result,
      referenceId: referenceId,
    );
  }

  // ignore: unused_element
  Future<void> _closeTransaction({String? transactionHeaderId}) async {
    if (!mounted) return;

    final balance = _balance;
    if (balance < 0) {
      final change = balance.abs();
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Change Due'),
          content: Text('Change: \$${change.toStringAsFixed(2)}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      await _transactionSyncService.saveScreenReceipts(
        receiptRows: _buildScreenReceiptRows(),
        transactionHeaderId: transactionHeaderId,
      );
      if (!mounted) return;
      _clearItems(clearCustomerInfo: true);
      return;
    }

    if (balance.abs() < 0.0001) {
      await _transactionSyncService.saveScreenReceipts(
        receiptRows: _buildScreenReceiptRows(),
        transactionHeaderId: transactionHeaderId,
      );
      if (!mounted) return;
      await _runSaleReceiptOutputFlow();
      if (!mounted) return;
      _clearItems(clearCustomerInfo: true);
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Balance Due'),
        content: Text('Balance due: \$${balance.toStringAsFixed(2)}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _buildScreenReceiptRows() {
    if (_receiptEntries.isEmpty) return const [];

    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < _receiptEntries.length; i++) {
      final entry = _receiptEntries[i];
      final tax = i < _itemTaxes.length ? _itemTaxes[i] : 0.0;
      final extCost = entry.itemSku;

      rows.add({
        'item_sku': _receiptRowSkuValue(entry),
        'item_cost': entry.itemSku,
        'ext_cost': extCost < 0 ? 0.0 : extCost,
        'qty': 1,
        'description': entry.description,
        'discount_type': 'None',
        'discount_amount': 0.0,
        'total_tax': tax,
      });
    }

    return rows;
  }

  Future<void> _showCurrentBatch() async {
    bool ascending = false;
    bool autoRefresh = false;
    int autoRefreshIntervalSeconds = 5;
    bool dialogOpen = true;
    Timer? autoRefreshTimer;

    Future<List<Map<String, dynamic>>> loadRows() {
      return _transactionSyncService.getCurrentBatchTransactions(
        ascending: ascending,
      );
    }

    var rowsFuture = loadRows();

    void restartAutoRefresh(void Function(void Function()) setDialogState) {
      autoRefreshTimer?.cancel();
      if (!autoRefresh) return;

      autoRefreshTimer = Timer.periodic(
        Duration(seconds: autoRefreshIntervalSeconds),
        (_) {
          if (!dialogOpen) return;
          setDialogState(() {
            rowsFuture = loadRows();
          });
        },
      );
    }

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Row(
              children: [
                const Expanded(child: Text('Current Batch')),
                TextButton(
                  onPressed: () {
                    setDialogState(() {
                      ascending = false;
                      rowsFuture = loadRows();
                    });
                  },
                  child: const Text('Newest'),
                ),
                TextButton(
                  onPressed: () {
                    setDialogState(() {
                      ascending = true;
                      rowsFuture = loadRows();
                    });
                  },
                  child: const Text('Oldest'),
                ),
                TextButton(
                  onPressed: () {
                    setDialogState(() {
                      rowsFuture = loadRows();
                    });
                  },
                  child: const Text('Refresh'),
                ),
              ],
            ),
            content: SizedBox(
              width: 620,
              height: 420,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Checkbox(
                        value: autoRefresh,
                        onChanged: (value) {
                          setDialogState(() {
                            autoRefresh = value ?? false;
                            if (autoRefresh) {
                              rowsFuture = loadRows();
                            }
                            restartAutoRefresh(setDialogState);
                          });
                        },
                      ),
                      const Text('Auto-refresh'),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: autoRefreshIntervalSeconds,
                        items: const [
                          DropdownMenuItem(value: 5, child: Text('5s')),
                          DropdownMenuItem(value: 10, child: Text('10s')),
                          DropdownMenuItem(value: 30, child: Text('30s')),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setDialogState(() {
                            autoRefreshIntervalSeconds = value;
                            if (autoRefresh) {
                              restartAutoRefresh(setDialogState);
                            }
                          });
                        },
                      ),
                    ],
                  ),
                  Expanded(
                    child: FutureBuilder<List<Map<String, dynamic>>>(
                      future: rowsFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }

                        if (snapshot.hasError) {
                          final errorText =
                              'Failed to load batch: ${snapshot.error}';
                          return Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(errorText),
                                const SizedBox(height: 12),
                                TextButton.icon(
                                  onPressed: () async {
                                    final messenger = ScaffoldMessenger.of(
                                      context,
                                    );
                                    await Clipboard.setData(
                                      ClipboardData(text: errorText),
                                    );
                                    if (!mounted) return;
                                    messenger.showSnackBar(
                                      const SnackBar(
                                        content: Text('Error copied.'),
                                      ),
                                    );
                                  },
                                  icon: const Icon(Icons.copy_all_outlined),
                                  label: const Text('Copy Error'),
                                ),
                              ],
                            ),
                          );
                        }

                        final rows = snapshot.data ?? const [];
                        if (rows.isEmpty) {
                          return const Center(
                            child: Text('No transactions found.'),
                          );
                        }

                        return ListView.separated(
                          itemCount: rows.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 12),
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            final rowText = row.entries
                                .map((entry) => '${entry.key}: ${entry.value}')
                                .join('\n');
                            return Text(rowText);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
    } finally {
      dialogOpen = false;
      autoRefreshTimer?.cancel();
    }
  }

  Future<void> _openTableListWindow(String tableName, String title) async {
    if (!mounted) return;

    if (tableName == 'terminals') {
      await showDialog<void>(
        context: context,
        builder: (_) => const TerminalManagerV2Dialog(),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (_) => TableListWindow(tableName: tableName, title: title),
    );
  }

  Future<void> _openSettingsWindow() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => SettingsWindow(
        onOpenTable: (tableName, title) {
          Navigator.of(dialogContext).pop();
          unawaited(_openTableListWindow(tableName, title));
        },
        onShowPaymentDiagnostics: () {
          Navigator.of(dialogContext).pop();
          unawaited(_showPaymentDiagnosticsDialog());
        },
      ),
    );
  }

  String _maskDiagnosticValue(String value, {int head = 4, int tail = 2}) {
    final normalized = value.trim();
    if (normalized.isEmpty) return '';
    if (normalized.length <= head + tail) {
      return '${normalized.substring(0, 1)}***';
    }
    return '${normalized.substring(0, head)}***${normalized.substring(normalized.length - tail)}';
  }

  Future<void> _showPaymentDiagnosticsDialog() async {
    if (!mounted) return;

    final activeContext = LicenseService().activeContext;
    final rows = <MapEntry<String, String>>[
      MapEntry('captured_at', DateTime.now().toIso8601String()),
      MapEntry(
        'payment_api_base_url',
        _paymentApiBaseUrl.replaceAll(RegExp(r'/+$'), ''),
      ),
      MapEntry('supabase_url', SupabaseConfig.url),
      MapEntry('spin_sandbox', SupabaseConfig.spinSandbox.toString()),
      MapEntry('debug_mode', SupabaseConfig.debugMode.toString()),
      MapEntry('organization_id', activeContext?.organizationId ?? ''),
      MapEntry('organization_number', activeContext?.organizationNumber ?? ''),
      MapEntry('organization_name', activeContext?.organizationName ?? ''),
      MapEntry('location_id', activeContext?.locationId ?? ''),
      MapEntry('location_name', activeContext?.locationName ?? ''),
      MapEntry('terminal_id', activeContext?.terminalId ?? ''),
      MapEntry('terminal_number', activeContext?.terminalNumber ?? ''),
      MapEntry('terminal_name', activeContext?.terminalName ?? ''),
      MapEntry('card_reader_type', TerminalConfig.cardReaderType),
      MapEntry(
        'has_physical_card_reader',
        TerminalConfig.hasPhysicalCardReader.toString(),
      ),
      MapEntry('spin_tpn', TerminalConfig.spinTpn.trim()),
      MapEntry(
        'spin_auth_key',
        TerminalConfig.spinAuthKey.trim().isEmpty
            ? ''
            : _maskDiagnosticValue(TerminalConfig.spinAuthKey.trim()),
      ),
      MapEntry(
        'hpp_auth_token_present',
        TerminalConfig.cardReaderHppAuthToken.trim().isNotEmpty.toString(),
      ),
      MapEntry(
        'hpp_auth_token',
        TerminalConfig.cardReaderHppAuthToken.trim().isEmpty
            ? ''
            : _maskDiagnosticValue(
                TerminalConfig.cardReaderHppAuthToken.trim(),
                head: 6,
                tail: 4,
              ),
      ),
      MapEntry(
        'payment_configured',
        TerminalConfig.isPaymentConfigured.toString(),
      ),
      MapEntry('terminal_loader_debug', TerminalConfig.lastLoadDebug),
    ];

    final copyBuffer = rows
        .map(
          (entry) =>
              '${entry.key}: ${entry.value.isEmpty ? '(empty)' : entry.value}',
        )
        .join('\n');

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Payment Diagnostics'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: rows
                  .map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SelectableText(
                        '${entry.key}: ${entry.value.isEmpty ? '(empty)' : entry.value}',
                        style: const TextStyle(fontSize: 12, height: 1.35),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: copyBuffer));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Payment diagnostics copied to clipboard.'),
                ),
              );
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Future<void> _openTeeSheetWindow() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => const TeeSheetWindow(),
    );
  }

  // ignore: unused_element
  Future<void> _showTerminalFunctionsDialog() async {
    await _loadOpenBatch();
    if (!mounted) return;

    final approvedCount = _openBatchCards
        .where((r) => (r['status']?.toString() ?? '') == 'approved')
        .length;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Functions'),
        content: SizedBox(
          width: (MediaQuery.of(dialogContext).size.width - 64).clamp(
            240.0,
            420.0,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Open Batch Items: $approvedCount',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  unawaited(_showOpenBatchFunctionsDialog());
                },
                icon: _batchLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.view_list_rounded),
                label: const Text('Open Batch'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  unawaited(_showPreviousBatchReportsDialog());
                },
                icon: const Icon(Icons.history),
                label: const Text('View / Print Previous Batch'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  unawaited(_showTransactionTypeDialog());
                },
                icon: const Icon(Icons.reply),
                label: const Text('Voids & Refunds'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: approvedCount > 0
                    ? () {
                        Navigator.of(dialogContext).pop();
                        unawaited(_closeBatch());
                      }
                    : null,
                icon: const Icon(Icons.task_alt_rounded),
                label: const Text('Close Batch'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showOpenBatchFunctionsDialog() async {
    bool loading = true;
    String? loadError;
    String? selectedId;
    String searchQuery = '';
    bool showSearchKeyboard = false;
    var initialLoadQueued = false;
    List<Map<String, dynamic>> rows = const [];
    final tipAdjustListController = ScrollController();
    final searchController = TextEditingController();

    Future<void> loadRows(void Function(void Function()) setDialogState) async {
      setDialogState(() {
        loading = true;
        loadError = null;
      });
      try {
        await _loadOpenBatch();
        if (!mounted) return;
        final loaded = _openBatchCards
            .map((row) => Map<String, dynamic>.from(row))
            .where(
              (row) =>
                  (row['batch_status']?.toString().trim().toLowerCase() ??
                      '') ==
                  'o',
            )
            .toList();
        setDialogState(() {
          rows = loaded;
          loading = false;
          if (selectedId != null &&
              !rows.any((row) => row['id']?.toString() == selectedId)) {
            selectedId = null;
          }
          selectedId ??= rows.isNotEmpty ? rows.first['id']?.toString() : null;
        });
      } catch (error) {
        setDialogState(() {
          loading = false;
          loadError = error.toString();
        });
      }
    }

    Future<void> runAdjustGratuity(
      Map<String, dynamic> row,
      void Function(void Function()) setDialogState,
    ) async {
      if (!_isGratuityAdjustEnabled) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Gratuity Not Enabled'),
            content: const Text(
              'Tip adjustment is not activated for this terminal yet.',
            ),
            actions: [
              if (loadError != null)
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text:
                            'Open Batch\n\nFailed to load open batch: $loadError',
                      ),
                    );
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Error copied.')),
                    );
                  },
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy Error'),
                ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
        return;
      }

      final subtype = row['subtype']?.toString() ?? '';
      if (subtype != 's') {
        if (!mounted) return;
        await _showCopyableOperationErrorDialog(
          title: 'Tip Adjustment Not Available',
          message: 'Tip adjustment is only available for approved sale rows.',
        );
        return;
      }

      final gatewayProvider =
          (row['gateway_provider']?.toString().toLowerCase() ?? '').trim();

      final originalDetailId = row['id']?.toString() ?? '';
      Map<String, dynamic>? latestAdjustment;
      DateTime? latestAdjustmentAt;
      for (final candidate in rows) {
        final candidateSubtype =
            (candidate['subtype']?.toString().toLowerCase() ?? '').trim();
        final candidateOriginal =
            candidate['original_detail_id']?.toString().trim() ?? '';
        final candidateStatus =
            (candidate['status']?.toString().toLowerCase() ?? '').trim();
        if (candidateSubtype != 'a' ||
            candidateOriginal != originalDetailId ||
            candidateStatus != 'approved') {
          continue;
        }
        final parsedAt = DateTime.tryParse(
          candidate['created_at']?.toString() ?? '',
        );
        if (latestAdjustment == null) {
          latestAdjustment = candidate;
          latestAdjustmentAt = parsedAt;
          continue;
        }
        if (latestAdjustmentAt == null) {
          latestAdjustment = candidate;
          latestAdjustmentAt = parsedAt;
          continue;
        }
        if (parsedAt != null && parsedAt.isAfter(latestAdjustmentAt)) {
          latestAdjustment = candidate;
          latestAdjustmentAt = parsedAt;
        }
      }
      final currentTipAmount = latestAdjustment == null
          ? 0.0
          : ((latestAdjustment['amount'] as num?)?.toDouble() ?? 0.0);

      final saleAmount = (row['amount'] as num?)?.toDouble().abs() ?? 0;
      if (saleAmount <= 0) {
        if (!mounted) return;
        await _showCopyableOperationErrorDialog(
          title: 'Invalid Sale Amount',
          message: 'This sale row has no positive amount to adjust.',
        );
        return;
      }

      final surchargeAmountRaw = row['fee_amount'];
      final surchargeAmount = surchargeAmountRaw is num
          ? surchargeAmountRaw.toDouble().abs()
          : (double.tryParse(surchargeAmountRaw?.toString().trim() ?? '0') ?? 0)
                .abs();
      final saleAmountWithSurcharge = saleAmount + surchargeAmount;

      final saleReferenceId = row['reference_id']?.toString().trim() ?? '';
      if (saleReferenceId.isEmpty) {
        if (!mounted) return;
        await _showCopyableOperationErrorDialog(
          title: 'Missing Processor Reference',
          message:
              'Tip adjustment requires the original processor reference id.',
        );
        return;
      }

      final tipAmount = await _promptTipAdjustmentAmount(
        saleAmount: saleAmountWithSurcharge,
        currentTipAmount: currentTipAmount,
        saleReferenceId: saleReferenceId,
        cardType: row['card_type']?.toString().trim().isNotEmpty == true
            ? row['card_type'].toString().trim()
            : 'Card',
        cardLast4: row['card_last4']?.toString().trim() ?? '',
        invoiceReference: row['invoice_reference']?.toString().trim() ?? '',
      );

      if (tipAmount == null || !mounted) return;
      if ((tipAmount - currentTipAmount).abs() < 0.000001) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Tip amount unchanged.')));
        return;
      }

      final tpn = TerminalConfig.spinTpn;
      final authKey = TerminalConfig.spinAuthKey;
      if (tpn.isEmpty || authKey.isEmpty) {
        await _showCardTerminalNotConfiguredError();
        return;
      }

      final service = DejavooService(
        tpn: tpn,
        authKey: authKey,
        sandbox: SupabaseConfig.spinSandbox,
        requestProcessorSurcharge: false,
      );

      BuildContext? progressDialogContext;
      var progressVisible = false;

      Future<void> showProgressDialog() async {
        if (!mounted || progressVisible) return;
        progressVisible = true;
        final ready = Completer<void>();

        unawaited(
          showDialog<void>(
            context: context,
            useRootNavigator: true,
            barrierDismissible: false,
            builder: (dialogContext) {
              progressDialogContext = dialogContext;
              if (!ready.isCompleted) ready.complete();
              return PopScope(
                canPop: false,
                child: AlertDialog(
                  content: SizedBox(
                    width: 320,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.tips_and_updates_outlined, size: 36),
                        SizedBox(height: 12),
                        Text(
                          'Processing Tip Adjustment',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Contacting processor and finalizing update...',
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 12),
                        LinearProgressIndicator(),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );

        await ready.future.timeout(
          const Duration(milliseconds: 300),
          onTimeout: () {},
        );
      }

      void hideProgressDialog() {
        if (!progressVisible) return;
        final dialogCtx = progressDialogContext;
        if (dialogCtx != null && dialogCtx.mounted) {
          Navigator.of(dialogCtx, rootNavigator: true).pop();
        }
        progressDialogContext = null;
        progressVisible = false;
      }

      await showProgressDialog();

      late final DejavooTipAdjustResult result;
      try {
        result = await service.tipAdjust(
          amount: saleAmount,
          tipAmount: tipAmount,
          referenceId: saleReferenceId,
          gatewayProvider: gatewayProvider,
        );
      } catch (error) {
        hideProgressDialog();
        await _showCopyableOperationErrorDialog(
          title: 'Tip Adjustment Failed',
          message: 'Processor request failed: $error',
        );
        return;
      }

      if (!mounted) return;

      if (result.success) {
        try {
          final headerId =
              row['transaction_header_id']?.toString().trim() ?? '';
          if (headerId.isEmpty) {
            throw Exception(
              'Missing transaction header id for open-batch detail row.',
            );
          }

          final tipAdjustReferenceId =
              'TA-${DateTime.now().millisecondsSinceEpoch}';
          await _transactionSyncService.saveTransactionDetail(
            transactionHeaderId: headerId,
            paymentType: 'd',
            subtype: 'a',
            amount: tipAmount,
            status: 'approved',
            referenceId: tipAdjustReferenceId,
            gatewayProvider: 'dejavoo',
            gatewayToken: result.gatewayToken ?? '',
            authCode: result.authCode ?? '',
            cardLast4: row['card_last4']?.toString() ?? '',
            cardType: row['card_type']?.toString() ?? '',
            originalDetailId: originalDetailId,
            gatewayRaw: {
              'operation': 'tip_adjust',
              'tip_amount': tipAmount,
              'previous_tip_amount': currentTipAmount,
              'original_sale_amount': saleAmount,
              'original_sale_reference_id': saleReferenceId,
              if (result.referenceId?.isNotEmpty == true)
                'gateway_reference_id': result.referenceId,
              if (result.rawResponse != null)
                'gateway_response': result.rawResponse,
            },
          );

          await service.showDeviceMessage(message: 'Tip Adjustment Approved');
          hideProgressDialog();
          await service.setDeviceReadyForNextTransaction();
          await loadRows(setDialogState);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Tip adjusted to \$${tipAmount.toStringAsFixed(2)} successfully.',
              ),
            ),
          );
          _scheduleBatchReconcile(reason: 'tip-adjust-success');
        } catch (error) {
          hideProgressDialog();
          await _showCopyableOperationErrorDialog(
            title: 'Tip Adjustment Ledger Save Failed',
            message: 'Gateway approved, but local save failed: $error',
          );
        }
      } else {
        final errorParts = <String>[
          result.message,
          'reference_id: $saleReferenceId',
          if (result.gatewayToken?.isNotEmpty == true)
            'gateway_token: ${result.gatewayToken}',
          if (result.rawResponse != null)
            'raw_response: ${jsonEncode(result.rawResponse)}',
        ];
        hideProgressDialog();
        await _showCopyableOperationErrorDialog(
          title: 'Tip Adjustment Failed',
          message: errorParts.join('\n\n'),
        );
      }
    }

    if (!mounted) return;

    final completer = Completer<void>();
    late OverlayEntry entry;
    BuildContext? dialogBuilderContext;
    var overlayActive = true;

    final overlayState = Overlay.of(context, rootOverlay: true);
    Rect? anchorRect;
    final anchorContext = _terminalViewportKey.currentContext;
    if (anchorContext != null) {
      final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
      final anchorBox = anchorContext.findRenderObject() as RenderBox?;
      if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
        final topLeft = anchorBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        anchorRect = topLeft & anchorBox.size;
      }
    }

    void closeDialog() {
      if (!overlayActive) return;
      overlayActive = false;
      entry.remove();
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    bool canUpdateDialog() {
      return overlayActive &&
          mounted &&
          (dialogBuilderContext?.mounted ?? false);
    }

    final dialogWidget = StatefulBuilder(
      builder: (context, setDialogState) {
        dialogBuilderContext = context;

        if (loading &&
            rows.isEmpty &&
            loadError == null &&
            !initialLoadQueued) {
          initialLoadQueued = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!canUpdateDialog()) return;
            unawaited(loadRows(setDialogState));
          });
        }

        final openBatchSnapshot = _transactionSyncService
            .buildOpenBatchIntegritySnapshot(rows);
        final displayRows = List<Map<String, dynamic>>.from(
          openBatchSnapshot['rows'] as List,
        );
        final totals = Map<String, dynamic>.from(
          openBatchSnapshot['totals'] as Map<String, dynamic>? ??
              const <String, dynamic>{},
        );
        final originalTotal = ((totals['saleAmount'] as num?)?.toDouble() ?? 0)
            .abs();
        final surchargeTotal =
            ((totals['surchargeAmount'] as num?)?.toDouble() ?? 0).abs();
        final tipTotal = ((totals['tipAdjustAmount'] as num?)?.toDouble() ?? 0)
            .abs();
        final refundTotal = ((totals['refundAmount'] as num?)?.toDouble() ?? 0)
            .abs();
        final finalTotal = (totals['netAmount'] as num?)?.toDouble() ?? 0;

        final q = searchQuery.trim().toLowerCase();
        final filteredRows = q.isEmpty
            ? displayRows
            : displayRows.where((row) {
                final txn =
                    row['txn_seq']?.toString().trim().toLowerCase() ?? '';
                final auth =
                    row['auth_code']?.toString().trim().toLowerCase() ?? '';
                final last4 =
                    row['card_last4']?.toString().trim().toLowerCase() ?? '';
                final haystack = '$txn $auth $last4';
                return haystack.contains(q);
              }).toList();

        void applySearchText(String next) {
          setDialogState(() {
            searchController.text = next;
            searchController.selection = TextSelection.collapsed(
              offset: searchController.text.length,
            );
            searchQuery = next;
          });
        }

        Widget buildSearchKey(
          String key, {
          int flex = 1,
          VoidCallback? onPressed,
          Color? color,
        }) {
          return Expanded(
            flex: flex,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: EdgeInsets.zero,
                  backgroundColor: color,
                ),
                onPressed:
                    onPressed ??
                    () => applySearchText('${searchController.text}$key'),
                child: Center(
                  child: Text(
                    key,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(color: Colors.black26),
              ),
            ),
            Center(
              child: LayoutBuilder(
                builder: (context, viewportConstraints) {
                  final dialogMaxHeight = viewportConstraints.maxHeight * 0.9;
                  final contentHeight = dialogMaxHeight - 96;
                  final dialogMaxWidth = (viewportConstraints.maxWidth - 20)
                      .clamp(300.0, 1000.0);
                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: dialogMaxWidth,
                      maxHeight: dialogMaxHeight,
                    ),
                    child: AlertDialog(
                      insetPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      titlePadding: const EdgeInsets.fromLTRB(14, 10, 8, 2),
                      contentPadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      title: const Text(
                        'Open Transactions',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      content: SizedBox(
                        width: dialogMaxWidth,
                        height: contentHeight,
                        child: loading
                            ? const Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : loadError != null
                            ? Align(
                                alignment: Alignment.topLeft,
                                child: Text(
                                  'Failed to load open batch: $loadError',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              )
                            : displayRows.isEmpty
                            ? const Align(
                                alignment: Alignment.topLeft,
                                child: Text(
                                  'No open card transactions.',
                                  style: TextStyle(fontSize: 11),
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.fromLTRB(
                                      10,
                                      8,
                                      10,
                                      8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerLow,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.outlineVariant,
                                      ),
                                    ),
                                    child: Wrap(
                                      spacing: 12,
                                      runSpacing: 6,
                                      children: [
                                        Text(
                                          'Original: \$${originalTotal.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        Text(
                                          'Tip: \$${tipTotal.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        Text(
                                          'Surcharge: \$${surchargeTotal.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        Text(
                                          'Refund: -\$${refundTotal.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        Text(
                                          'Final: \$${finalTotal.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: searchController,
                                    style: const TextStyle(fontSize: 11),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      hintText:
                                          'Search Transaction #, Auth Code, Last 4...',
                                      hintStyle: const TextStyle(fontSize: 11),
                                      prefixIcon: const Icon(
                                        Icons.search,
                                        size: 16,
                                      ),
                                      suffixIcon: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (searchQuery.trim().isNotEmpty)
                                            IconButton(
                                              tooltip: 'Clear search',
                                              iconSize: 14,
                                              splashRadius: 14,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              onPressed: () {
                                                setDialogState(() {
                                                  searchController.clear();
                                                  searchQuery = '';
                                                });
                                              },
                                              icon: const Icon(Icons.clear),
                                            ),
                                          IconButton(
                                            tooltip: showSearchKeyboard
                                                ? 'Hide keyboard'
                                                : 'Show keyboard',
                                            iconSize: 15,
                                            splashRadius: 14,
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () {
                                              setDialogState(() {
                                                showSearchKeyboard =
                                                    !showSearchKeyboard;
                                              });
                                            },
                                            icon: Icon(
                                              showSearchKeyboard
                                                  ? Icons.keyboard_hide_outlined
                                                  : Icons.keyboard_alt_outlined,
                                            ),
                                          ),
                                        ],
                                      ),
                                      border: const OutlineInputBorder(),
                                    ),
                                    onChanged: (value) {
                                      setDialogState(() {
                                        searchQuery = value;
                                      });
                                    },
                                  ),
                                  const SizedBox(height: 6),
                                  Expanded(
                                    child: filteredRows.isEmpty
                                        ? const Align(
                                            alignment: Alignment.topLeft,
                                            child: Text(
                                              'No transactions match search criteria.',
                                              style: TextStyle(fontSize: 11),
                                            ),
                                          )
                                        : Scrollbar(
                                            controller: tipAdjustListController,
                                            thumbVisibility: true,
                                            interactive: true,
                                            thickness: 10,
                                            radius: const Radius.circular(8),
                                            child: ListView.separated(
                                              controller:
                                                  tipAdjustListController,
                                              physics: const BouncingScrollPhysics(
                                                parent:
                                                    AlwaysScrollableScrollPhysics(),
                                              ),
                                              itemCount: filteredRows.length,
                                              separatorBuilder: (_, _) =>
                                                  const Divider(height: 1),
                                              itemBuilder: (context, index) {
                                                final row = filteredRows[index];
                                                final id =
                                                    row['id']?.toString() ?? '';
                                                final isSelected =
                                                    id == selectedId;
                                                final subtype =
                                                    row['subtype']
                                                        ?.toString() ??
                                                    's';
                                                final status =
                                                    row['status']
                                                        ?.toString()
                                                        .toLowerCase()
                                                        .trim() ??
                                                    '';
                                                final invoiceReference =
                                                    row['invoice_reference']
                                                        ?.toString()
                                                        .trim() ??
                                                    '';
                                                final txnSeq =
                                                    row['txn_seq']
                                                        ?.toString()
                                                        .trim() ??
                                                    '';
                                                final authCode =
                                                    row['auth_code']
                                                        ?.toString()
                                                        .trim() ??
                                                    '';
                                                final originalAmount =
                                                    (row['amount'] as num?)
                                                        ?.toDouble()
                                                        .abs() ??
                                                    0;
                                                final surchargeAmount =
                                                    ((row['surcharge_amount']
                                                                    as num?)
                                                                ?.toDouble() ??
                                                            0)
                                                        .abs();
                                                final amount =
                                                    ((row['display_amount'] ??
                                                                row['amount'])
                                                            as num?)
                                                        ?.toDouble()
                                                        .abs() ??
                                                    0;
                                                final tipAdjustmentTotal =
                                                    (row['tip_adjustment_total']
                                                            as num?)
                                                        ?.toDouble() ??
                                                    0;
                                                final cardType =
                                                    row['card_type']
                                                        ?.toString() ??
                                                    'Card';
                                                final last4 =
                                                    row['card_last4']
                                                        ?.toString() ??
                                                    '';
                                                final hasTipAdjustment =
                                                    tipAdjustmentTotal > 0;
                                                final transactionAt =
                                                    DateTime.tryParse(
                                                      row['created_at']
                                                              ?.toString() ??
                                                          '',
                                                    )?.toLocal();
                                                final transactionDateText =
                                                    transactionAt != null
                                                    ? _formatDateTimeForReport(
                                                        transactionAt,
                                                      )
                                                    : '';

                                                return ListTile(
                                                  dense: true,
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  minLeadingWidth: 18,
                                                  contentPadding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 0,
                                                      ),
                                                  selected: isSelected,
                                                  tileColor:
                                                      !isSelected &&
                                                          hasTipAdjustment
                                                      ? const Color(0xFFFFF3E0)
                                                      : null,
                                                  selectedTileColor:
                                                      const Color(0xFFDCEBFF),
                                                  onTap: () {
                                                    setDialogState(() {
                                                      selectedId = id;
                                                    });
                                                  },
                                                  leading: Icon(
                                                    Icons.credit_card,
                                                    size: 15,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                                  ),
                                                  title: Text(
                                                    '\$${amount.toStringAsFixed(2)}  $cardType${last4.isNotEmpty ? ' ****$last4' : ''}',
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                  subtitle: Text(
                                                    [
                                                      'Transaction #: ${txnSeq.isNotEmpty ? txnSeq : 'N/A'}',
                                                      'Original Transaction Amount: \$${originalAmount.toStringAsFixed(2)}',
                                                      if (surchargeAmount > 0)
                                                        'Surcharge: \$${surchargeAmount.toStringAsFixed(2)}',
                                                      'Auth Code: ${authCode.isNotEmpty ? authCode : 'N/A'}',
                                                      if (transactionDateText
                                                          .isNotEmpty)
                                                        'Transaction Date: $transactionDateText',
                                                      if (tipAdjustmentTotal >
                                                          0)
                                                        'Includes Tip Adjustment: +\$${tipAdjustmentTotal.toStringAsFixed(2)}',
                                                      if (invoiceReference
                                                          .isNotEmpty)
                                                        'Invoice/Reference: $invoiceReference',
                                                      'Processor Ref: ${(row['reference_id'] ?? row['id']).toString()}',
                                                    ].join('\n'),
                                                    style: TextStyle(
                                                      fontSize: 9.5,
                                                      height: 1.15,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                    ),
                                                  ),
                                                  trailing:
                                                      (_isGratuityAdjustEnabled &&
                                                          subtype == 's' &&
                                                          status == 'approved')
                                                      ? StandardActionButton(
                                                          label: 'Adjust Tip',
                                                          icon: Icons
                                                              .tips_and_updates_outlined,
                                                          iconColor:
                                                              const Color(
                                                                0xFFEF6C00,
                                                              ),
                                                          iconBackgroundColor:
                                                              const Color(
                                                                0xFFFFF3E0,
                                                              ),
                                                          labelFontScale: 0.8,
                                                          compact: true,
                                                          onTap: () => unawaited(
                                                            runAdjustGratuity(
                                                              row,
                                                              setDialogState,
                                                            ),
                                                          ),
                                                        )
                                                      : null,
                                                );
                                              },
                                            ),
                                          ),
                                  ),
                                  if (showSearchKeyboard) ...[
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        for (final key in [
                                          '1',
                                          '2',
                                          '3',
                                          '4',
                                          '5',
                                          '6',
                                          '7',
                                          '8',
                                          '9',
                                          '0',
                                        ])
                                          buildSearchKey(key),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        for (final key in [
                                          'Q',
                                          'W',
                                          'E',
                                          'R',
                                          'T',
                                          'Y',
                                          'U',
                                          'I',
                                          'O',
                                          'P',
                                        ])
                                          buildSearchKey(key),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        for (final key in [
                                          'A',
                                          'S',
                                          'D',
                                          'F',
                                          'G',
                                          'H',
                                          'J',
                                          'K',
                                          'L',
                                        ])
                                          buildSearchKey(key),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        for (final key in [
                                          'Z',
                                          'X',
                                          'C',
                                          'V',
                                          'B',
                                          'N',
                                          'M',
                                        ])
                                          buildSearchKey(key),
                                        buildSearchKey(
                                          'BS',
                                          onPressed: () {
                                            final text = searchController.text;
                                            if (text.isEmpty) return;
                                            applySearchText(
                                              text.substring(
                                                0,
                                                text.length - 1,
                                              ),
                                            );
                                          },
                                          color: _themeYellow,
                                        ),
                                        buildSearchKey(
                                          'CLR',
                                          onPressed: () => applySearchText(''),
                                          color: _themeRed,
                                        ),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        buildSearchKey(
                                          'SPACE',
                                          flex: 4,
                                          onPressed: () => applySearchText(
                                            '${searchController.text} ',
                                          ),
                                        ),
                                        buildSearchKey('-'),
                                        buildSearchKey('/'),
                                        buildSearchKey('.'),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                      ),
                      actions: [
                        if (loadError != null)
                          TextButton.icon(
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              await Clipboard.setData(
                                ClipboardData(
                                  text:
                                      'Open Transactions\n\nFailed to load open batch: $loadError',
                                ),
                              );
                              if (!mounted) return;
                              messenger.showSnackBar(
                                const SnackBar(content: Text('Error copied.')),
                              );
                            },
                            icon: const Icon(Icons.copy_all_outlined, size: 15),
                            label: const Text(
                              'Copy Error',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                        TextButton(
                          onPressed: closeDialog,
                          child: const Text(
                            'Close',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );

    entry = OverlayEntry(
      builder: (_) {
        if (anchorRect == null) {
          return dialogWidget;
        }
        return Stack(
          children: [
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: dialogWidget,
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(entry);
    await completer.future;
    tipAdjustListController.dispose();
    searchController.dispose();
  }

  Widget _buildNumberPad() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      children: [
        _buildNumberPadRow(['1', '2', '3'], theme),
        const SizedBox(height: 6),
        _buildNumberPadRow(['4', '5', '6'], theme),
        const SizedBox(height: 6),
        _buildNumberPadRow(['7', '8', '9'], theme),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildNumberPadKey(
              onTap: _clearCurrentInput,
              theme: theme,
              backgroundColor: _themeRed,
              child: Text(
                'Clear',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 6),
            _buildNumberPadKey(
              onTap: () => _append('0'),
              theme: theme,
              child: Text(
                '0',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w400,
                  color: cs.onSecondaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 6),
            _buildNumberPadKey(
              onTap: _backspace,
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

  Widget _buildNumberPadRow(List<String> digits, ThemeData theme) {
    final cs = theme.colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < digits.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          _buildNumberPadKey(
            onTap: () => _append(digits[i]),
            theme: theme,
            child: Text(
              digits[i],
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w400,
                color: cs.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNumberPadKey({
    required VoidCallback onTap,
    required Widget child,
    required ThemeData theme,
    Color? backgroundColor,
  }) {
    final cs = theme.colorScheme;
    const keyWidth = 80.0;
    const keyHeight = 52.0;
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

  void _openTerminalSaleScreen() {
    if (_terminalActiveScreen == 'sale') return;
    setState(() {
      _terminalActiveScreen = 'sale';
      _terminalScreenTransitionForward = false;
    });
  }

  Future<bool> _showReturnToLoginConfirmInViewport() async {
    final completer = Completer<bool>();
    late OverlayEntry entry;

    final overlayState = Overlay.of(context, rootOverlay: true);
    Rect? anchorRect;
    final anchorContext = _terminalViewportKey.currentContext;
    if (anchorContext != null) {
      final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
      final anchorBox = anchorContext.findRenderObject() as RenderBox?;
      if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
        final topLeft = anchorBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        anchorRect = topLeft & anchorBox.size;
      }
    }

    void closeWith(bool value) {
      if (!completer.isCompleted) {
        completer.complete(value);
      }
      entry.remove();
    }

    final dialogWidget = Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(color: Colors.black26),
          ),
        ),
        Center(
          child: LayoutBuilder(
            builder: (context, viewportConstraints) {
              final dialogMaxWidth = (viewportConstraints.maxWidth - 20)
                  .clamp(280.0, 360.0)
                  .toDouble();
              return ConstrainedBox(
                constraints: BoxConstraints(maxWidth: dialogMaxWidth),
                child: AlertDialog(
                  title: const Text('Return to Login?'),
                  content: const Text(
                    'This will clear the current register session and return to the login screen.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => closeWith(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => closeWith(true),
                      child: const Text('Return to Login'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );

    entry = OverlayEntry(
      builder: (_) {
        if (anchorRect == null) {
          return dialogWidget;
        }
        return Stack(
          children: [
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: dialogWidget,
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(entry);
    return completer.future;
  }

  Future<T?> _showTerminalOverlayInViewport<T>({
    required Widget Function(void Function([T? result])) builder,
  }) async {
    final completer = Completer<T?>();
    late OverlayEntry entry;

    final overlayState = Overlay.of(context, rootOverlay: true);
    Rect? anchorRect;
    final anchorContext = _terminalViewportKey.currentContext;
    if (anchorContext != null) {
      final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
      final anchorBox = anchorContext.findRenderObject() as RenderBox?;
      if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
        final topLeft = anchorBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        anchorRect = topLeft & anchorBox.size;
      }
    }

    void closeWith([T? result]) {
      if (!completer.isCompleted) {
        completer.complete(result);
      }
      entry.remove();
    }

    final content = Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => closeWith(),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(color: Colors.black26),
            ),
          ),
        ),
        Positioned.fill(
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            child: builder(closeWith),
          ),
        ),
      ],
    );

    entry = OverlayEntry(
      builder: (_) {
        if (anchorRect == null) {
          return content;
        }
        return Stack(
          children: [
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              width: anchorRect.width,
              height: anchorRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: content,
              ),
            ),
          ],
        );
      },
    );

    overlayState.insert(entry);
    return completer.future;
  }

  Future<void> _returnToLoginScreen() async {
    if (!mounted) return;

    final confirm = await _showReturnToLoginConfirmInViewport();

    if (confirm != true || !mounted) return;

    _clearItems(clearCustomerInfo: true);
    _transactionSyncService.clearTenantScopeCache();

    setState(() {
      _openBatchCards = [];
      _batchLoading = false;
      _terminalActiveScreen = 'sale';
      _terminalScreenTransitionForward = false;
      _lastBatchReconcileReason = 'logout';
      _lastTransactionInfoLines.clear();
      _lastCustomerInfoLines.clear();
    });

    if (!mounted) return;
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  Future<void> _openReportsScreen() async {
    final selectedReport = await _showTerminalOverlayInViewport<String>(
      builder: (closeWith) => ReportsSelectionScreen(
        embedded: true,
        tipsAllowed: _isGratuityAdjustEnabled,
        onClose: () => closeWith(),
        onSelectReport: (reportId) => closeWith(reportId),
      ),
    );

    if (!mounted || selectedReport == null) return;

    if (selectedReport == ReportsSelectionScreen.viewTransactionsReportId) {
      await _showTerminalOverlayInViewport<void>(
        builder: (closeWith) => ViewTransactionsReportScreen(
          embedded: true,
          onClose: () => closeWith(),
        ),
      );
      return;
    }

    if (selectedReport == ReportsSelectionScreen.tipAdjustmentsReportId) {
      await _showOpenBatchFunctionsDialog();
    }
  }

  Future<void> _openBatchFunctionsScreen() async {
    final selectedFunction = await _showTerminalOverlayInViewport<String>(
      builder: (closeWith) => BatchFunctionsSelectionScreen(
        embedded: true,
        onClose: () => closeWith(),
        onSelectFunction: (functionId) => closeWith(functionId),
      ),
    );

    if (!mounted || selectedFunction == null) return;

    if (selectedFunction ==
        BatchFunctionsSelectionScreen.openBatchReportFunctionId) {
      await _showOpenBatchPrintPreview();
      return;
    }

    if (selectedFunction == BatchFunctionsSelectionScreen.openBatchFunctionId) {
      await _showOpenBatchFunctionsDialog();
      return;
    }

    if (selectedFunction ==
        BatchFunctionsSelectionScreen.closedBatchFunctionId) {
      final activeLicense = LicenseService().activeContext;
      await _showTerminalOverlayInViewport<void>(
        builder: (closeWith) => ClosedBatchBrowserScreen(
          embedded: true,
          onClose: () => closeWith(),
          tpn: TerminalConfig.spinTpn,
          authKey: TerminalConfig.spinAuthKey,
          terminalName: _terminalName,
          locationName: _locationName,
          organizationName: activeLicense?.organizationName ?? '',
          organizationNumber: activeLicense?.organizationNumber ?? '',
        ),
      );
      return;
    }

    if (selectedFunction ==
        BatchFunctionsSelectionScreen.closeBatchFunctionId) {
      await _closeBatch();
    }
  }

  Future<void> _showPaaayitRequestDialog() async {
    final ctx = LicenseService().activeContext;
    if (ctx == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('License context not available.')),
        );
      }
      return;
    }

    final hppAuthToken = TerminalConfig.cardReaderHppAuthToken.trim();
    final merchantId = TerminalConfig.spinTpn.trim();
    if (merchantId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Merchant ID/TPN is not configured for this terminal.',
            ),
          ),
        );
      }
      return;
    }

    if (mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PaaayitRequestDialog(
          organizationId: ctx.organizationId,
          locationId: ctx.locationId,
          terminalId: ctx.terminalId,
          merchantId: merchantId,
          hppAuthToken: hppAuthToken,
          enableProcessorSurcharge:
              _transactionFlowParameters.enableProcessorSurcharge,
          onClose: () {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Payment link sent to customer.'),
                  duration: Duration(seconds: 3),
                ),
              );
            }
          },
        ),
      );
    }
  }

  _QuickActionVisual _quickActionVisualForLabel(String label) {
    switch (label) {
      case 'Customer':
        return const _QuickActionVisual(
          iconColor: Color(0xFF1565C0),
          backgroundColor: Color(0xFFE3F2FD),
        );
      case 'PaaayIT NOW':
        return const _QuickActionVisual(
          iconColor: Color(0xFF0D47A1),
          backgroundColor: Color(0xFFFFFCF6),
        );
      case 'View Open Batch':
        return const _QuickActionVisual(
          iconColor: Color(0xFF00695C),
          backgroundColor: Color(0xFFE0F2F1),
        );
      case 'Voids & Refunds':
        return const _QuickActionVisual(
          iconColor: Color(0xFFEF6C00),
          backgroundColor: Color(0xFFFFF3E0),
        );
      case 'Clear Sale':
        return const _QuickActionVisual(
          iconColor: Color(0xFFAD1457),
          backgroundColor: Color(0xFFFCE4EC),
        );
      case 'Batch Functions':
        return const _QuickActionVisual(
          iconColor: Color(0xFF455A64),
          backgroundColor: Color(0xFFECEFF1),
        );
      case 'Close Batch':
        return const _QuickActionVisual(
          iconColor: Color(0xFF2E7D32),
          backgroundColor: Color(0xFFE8F5E9),
        );
      case 'Reports & Processes':
        return const _QuickActionVisual(
          iconColor: Color(0xFF4A148C),
          backgroundColor: Color(0xFFEDE7F6),
        );
      default:
        return const _QuickActionVisual(
          iconColor: Color(0xFF37474F),
          backgroundColor: Color(0xFFF5F7FA),
        );
    }
  }

  double _quickActionFontSizeForLabel(String label) {
    return 11.0;
  }

  Widget _buildTerminalSaleContent({
    required Color numberPadDisplayBackgroundColor,
    required Color paymentsAreaBackgroundColor,
    required ColorScheme cs,
  }) {
    final customerLabel = _postedFullName.isNotEmpty
        ? _postedFullName
        : [
            _firstNameController.text.trim(),
            _lastNameController.text.trim(),
          ].where((s) => s.isNotEmpty).join(' ');
    final customerNumber = _postedCustomerNumber.isNotEmpty
        ? _postedCustomerNumber
        : _customerNumberController.text.trim();
    final customerAddress1 = _postedAddress1.isNotEmpty
        ? _postedAddress1
        : _address1Controller.text.trim();
    final customerAddress2 = _postedAddress2.isNotEmpty
        ? _postedAddress2
        : _address2Controller.text.trim();
    final customerCityStateZip = _postedCityStateZip.isNotEmpty
        ? _postedCityStateZip
        : [
            _cityController.text.trim(),
            _stateController.text.trim(),
            _zipController.text.trim(),
          ].where((s) => s.isNotEmpty).join(' ');
    final customerEmail = _postedEmail.isNotEmpty
        ? _postedEmail
        : _emailController.text.trim();
    final invoiceReference = _invoiceReference.trim();

    final currentCustomerInfoLines = <String>[];
    final staffIdValue = _staffId.trim();
    if (staffIdValue.isNotEmpty) {
      currentCustomerInfoLines.add('Staff ID #: $staffIdValue');
    }
    if (customerNumber.trim().isNotEmpty) {
      currentCustomerInfoLines.add(customerNumber.trim());
    }
    if (customerLabel.trim().isNotEmpty) {
      currentCustomerInfoLines.add(customerLabel.trim());
    }
    if (customerAddress1.trim().isNotEmpty) {
      currentCustomerInfoLines.add(customerAddress1.trim());
    }
    if (customerAddress2.trim().isNotEmpty) {
      currentCustomerInfoLines.add(customerAddress2.trim());
    }
    if (customerCityStateZip.trim().isNotEmpty) {
      currentCustomerInfoLines.add(customerCityStateZip.trim());
    }
    if (customerEmail.trim().isNotEmpty) {
      currentCustomerInfoLines.add(customerEmail.trim());
    }
    if (invoiceReference.isNotEmpty) {
      currentCustomerInfoLines.add('Invoice/Reference: $invoiceReference');
    }

    final hasCurrentCustomerDetails =
        customerNumber.trim().isNotEmpty ||
        customerLabel.trim().isNotEmpty ||
        customerAddress1.trim().isNotEmpty ||
        customerAddress2.trim().isNotEmpty ||
        customerCityStateZip.trim().isNotEmpty ||
        customerEmail.trim().isNotEmpty ||
        invoiceReference.isNotEmpty;

    final customerInfoLines = hasCurrentCustomerDetails
        ? currentCustomerInfoLines
        : List<String>.from(_lastCustomerInfoLines);

    final processorInfoLines = List<String>.from(_lastTransactionInfoLines);

    final hasCustomerInfo = customerInfoLines.isNotEmpty;
    final processorTextAlign = hasCustomerInfo
        ? TextAlign.right
        : TextAlign.left;

    String infoValue(String value, String fallback) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? fallback : trimmed;
    }

    final quickButtons =
        <({String label, IconData icon, VoidCallback onPressed})>[
          (
            label: 'Customer',
            icon: Icons.person_outline,
            onPressed: () => unawaited(_showTransactionCustomerInfoDialog()),
          ),
          (
            label: 'View Open Batch',
            icon: Icons.view_list_rounded,
            onPressed: () => unawaited(_showOpenBatchFunctionsDialog()),
          ),
          (
            label: 'Voids & Refunds',
            icon: Icons.reply,
            onPressed: () => unawaited(_showTransactionTypeDialog()),
          ),
          (
            label: 'PaaayIT NOW',
            icon: Icons.rocket_launch_rounded,
            onPressed: () => unawaited(_showPaaayitRequestDialog()),
          ),
          (
            label: 'Clear Sale',
            icon: Icons.delete_sweep_outlined,
            onPressed: () => _clearItems(clearCustomerInfo: true),
          ),
          (
            label: 'Batch Functions',
            icon: Icons.settings,
            onPressed: () => unawaited(_openBatchFunctionsScreen()),
          ),
          (
            label: 'Close Batch',
            icon: Icons.lock_clock_outlined,
            onPressed: () => unawaited(_closeBatch()),
          ),
          (
            label: 'Reports & Processes',
            icon: Icons.assessment_outlined,
            onPressed: () => unawaited(_openReportsScreen()),
          ),
        ];

    return Column(
      key: const ValueKey('sale-screen'),
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cs.outlineVariant, width: 1.1),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              infoValue(_locationName, 'Not set'),
                              textAlign: TextAlign.left,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            infoValue(_terminalName, 'Not set'),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        'Staff: ${infoValue(_staffName, 'Not set')}',
                        textAlign: TextAlign.left,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Transaction Info',
                              textAlign: TextAlign.left,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (processorInfoLines.isNotEmpty)
                            const Expanded(
                              child: Text(
                                'Last Transaction Processed',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      if (hasCustomerInfo && processorInfoLines.isNotEmpty)
                        for (
                          int i = 0;
                          i <
                              (customerInfoLines.length >
                                      processorInfoLines.length
                                  ? customerInfoLines.length
                                  : processorInfoLines.length);
                          i++
                        )
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  i < customerInfoLines.length
                                      ? customerInfoLines[i]
                                      : '',
                                  textAlign: TextAlign.left,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  i < processorInfoLines.length
                                      ? processorInfoLines[i]
                                      : '',
                                  textAlign: processorTextAlign,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          )
                      else if (hasCustomerInfo)
                        for (final line in customerInfoLines)
                          Text(
                            line,
                            textAlign: TextAlign.left,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          )
                      else if (processorInfoLines.isNotEmpty)
                        for (final line in processorInfoLines)
                          Text(
                            line,
                            textAlign: processorTextAlign,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          )
                      else
                        const Text(
                          'No transaction data yet',
                          textAlign: TextAlign.left,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    return GridView.builder(
                      itemCount: quickButtons.length,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: 0,
                        crossAxisSpacing: 0,
                        mainAxisExtent: 84,
                      ),
                      itemBuilder: (context, index) {
                        final button = quickButtons[index];
                        final visual = _quickActionVisualForLabel(button.label);
                        return Padding(
                          padding: const EdgeInsets.all(3),
                          child: Material(
                            color: visual.backgroundColor,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: button.onPressed,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: visual.backgroundColor,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: cs.outlineVariant,
                                    width: 1,
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      width: 26,
                                      height: 26,
                                      decoration: BoxDecoration(
                                        color: visual.backgroundColor,
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: button.label == 'PaaayIT NOW'
                                          ? AnimatedScale(
                                              duration: const Duration(
                                                milliseconds: 500,
                                              ),
                                              curve: Curves.easeInOut,
                                              scale: _showKeypadCursor
                                                  ? 1.15
                                                  : 0.9,
                                              child: AnimatedContainer(
                                                duration: const Duration(
                                                  milliseconds: 500,
                                                ),
                                                curve: Curves.easeInOut,
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color:
                                                          (_showKeypadCursor
                                                                  ? const Color(
                                                                      0xFFD32F2F,
                                                                    )
                                                                  : const Color(
                                                                      0xFF0D47A1,
                                                                    ))
                                                              .withAlpha(
                                                                _showKeypadCursor
                                                                    ? 90
                                                                    : 35,
                                                              ),
                                                      blurRadius:
                                                          _showKeypadCursor
                                                          ? 9
                                                          : 4,
                                                      spreadRadius:
                                                          _showKeypadCursor
                                                          ? 1.2
                                                          : 0.0,
                                                    ),
                                                  ],
                                                ),
                                                child:
                                                    TweenAnimationBuilder<
                                                      double
                                                    >(
                                                      duration: const Duration(
                                                        milliseconds: 500,
                                                      ),
                                                      curve: Curves.easeInOut,
                                                      tween: Tween<double>(
                                                        begin: 0,
                                                        end: _showKeypadCursor
                                                            ? 1
                                                            : 0,
                                                      ),
                                                      builder:
                                                          (
                                                            context,
                                                            t,
                                                            _,
                                                          ) => Icon(
                                                            button.icon,
                                                            size: 15.5,
                                                            color:
                                                                Color.lerp(
                                                                  const Color(
                                                                    0xFF0D47A1,
                                                                  ),
                                                                  const Color(
                                                                    0xFFD32F2F,
                                                                  ),
                                                                  t,
                                                                ) ??
                                                                const Color(
                                                                  0xFF0D47A1,
                                                                ),
                                                          ),
                                                    ),
                                              ),
                                            )
                                          : Icon(
                                              button.icon,
                                              size: 15.5,
                                              color: visual.iconColor,
                                            ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      button.label,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: _quickActionFontSizeForLabel(
                                          button.label,
                                        ),
                                        fontWeight: FontWeight.w700,
                                        height: 1.1,
                                        color: button.label == 'PaaayIT NOW'
                                            ? const Color(0xFF0D47A1)
                                            : cs.onSurface,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 1,
                  ),
                  alignment: Alignment.centerRight,
                  decoration: BoxDecoration(
                    color: numberPadDisplayBackgroundColor,
                    border: Border.all(color: cs.outlineVariant, width: 1.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        _currentInput.isEmpty
                            ? '\$0.00'
                            : '\$${_formatAmountForDisplay(_currentInput)}',
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1F2328),
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      if (_focusNode.hasFocus) ...[
                        const SizedBox(width: 4),
                        Opacity(
                          opacity: _showKeypadCursor ? 1 : 0,
                          child: Container(
                            width: 2,
                            height: 32,
                            color: cs.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: paymentsAreaBackgroundColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cs.outlineVariant, width: 1.3),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _buildNumberPad(),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(58),
                    ),
                    onPressed: _terminalWarmingUp
                        ? null
                        : () => unawaited(_startCardFlow()),
                    icon: _terminalWarmingUp
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.credit_card),
                    label: Text(
                      _terminalWarmingUp ? 'Initializing...' : 'Card',
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: _terminalWarmingUp
                        ? null
                        : () => unawaited(_startKeyCardInfoFlow()),
                    icon: const Icon(Icons.keyboard_alt_outlined),
                    label: const Text('Key Card Info'),
                  ),
                ),
                if (_cashTrackingEnabled) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                      ),
                      onPressed: () => unawaited(_startCashFlow()),
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('Cash'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTerminalFunctionsContent({required ColorScheme cs}) {
    final approvedCount = _openBatchCards
        .where((r) => (r['status']?.toString() ?? '') == 'approved')
        .length;

    return SingleChildScrollView(
      key: const ValueKey('functions-screen'),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F7FA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.outlineVariant, width: 1.1),
            ),
            child: Row(
              children: [
                Text(
                  'Open Batch Items: $approvedCount',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (_batchLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: () => unawaited(_showOpenBatchFunctionsDialog()),
            icon: const Icon(Icons.view_list_rounded),
            label: const Text('Open Batch'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () => unawaited(_showPreviousBatchReportsDialog()),
            icon: const Icon(Icons.history),
            label: const Text('View / Print Previous Batch'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () => unawaited(_showTransactionTypeDialog()),
            icon: const Icon(Icons.reply),
            label: const Text('Voids & Refunds'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: approvedCount > 0
                ? () => unawaited(_closeBatch())
                : null,
            icon: const Icon(Icons.task_alt_rounded),
            label: const Text('Close Batch'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _openTerminalSaleScreen,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back To Sale'),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _buildReceiptTotalLine({
    required String label,
    required double value,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 110,
          child: Text(
            '\$${value.toStringAsFixed(2)}',
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 15,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildPaymentHistoryEntry(String entry) {
    final lines = entry.split('\n');
    final firstLine = lines.first;
    final otherLines = lines.skip(1).toList();

    return RichText(
      text: TextSpan(
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 14,
        ),
        children: [
          TextSpan(
            text: firstLine,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          if (otherLines.isNotEmpty)
            TextSpan(text: '\n${otherLines.join('\n')}'),
        ],
      ),
    );
  }

  Widget _buildLeftMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    if (_isLeftMenuExpanded) {
      return SizedBox(
        width: double.infinity,
        child: TextButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, color: Theme.of(context).colorScheme.primary),
          label: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          ),
        ),
      );
    }

    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: Icon(icon, color: Theme.of(context).colorScheme.primary),
    );
  }

  // ignore: unused_element
  Widget _buildLeftMenu() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: _isLeftMenuExpanded ? 210 : 62,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          Align(
            alignment: _isLeftMenuExpanded
                ? Alignment.centerRight
                : Alignment.center,
            child: IconButton(
              tooltip: _isLeftMenuExpanded ? 'Collapse Menu' : 'Expand Menu',
              onPressed: () {
                setState(() {
                  _isLeftMenuExpanded = !_isLeftMenuExpanded;
                });
              },
              icon: Icon(_isLeftMenuExpanded ? Icons.menu_open : Icons.menu),
            ),
          ),
          if (_isLeftMenuExpanded)
            const Padding(
              padding: EdgeInsets.only(left: 10, right: 10, bottom: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Menu',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          const Divider(height: 1),
          _buildLeftMenuItem(
            icon: Icons.receipt_long,
            label: 'Current Batch',
            onPressed: _showCurrentBatch,
          ),
          _buildLeftMenuItem(
            icon: Icons.settings,
            label: 'Settings',
            onPressed: _openSettingsWindow,
          ),
          _buildLeftMenuItem(
            icon: Icons.health_and_safety_outlined,
            label: 'Payment Diagnostics',
            onPressed: _showPaymentDiagnosticsDialog,
          ),
          _buildLeftMenuItem(
            icon: Icons.lock_clock_outlined,
            label: 'Close Batch',
            onPressed: () => unawaited(_closeBatch()),
          ),
          _buildLeftMenuItem(
            icon: Icons.refresh,
            label: 'Refresh Context',
            onPressed: _checkTenantScope,
          ),
          const Divider(height: 1),
          if (_transactionFlowParameters.integrityChecksEnabled)
            _buildLeftMenuItem(
              icon: Icons.bug_report,
              label: 'Test: Last Txn',
              onPressed: () => showTransactionIntegrityCheck(context),
            ),
        ],
      ),
    );
  }

  Widget _buildCustomerField({
    required String label,
    required TextEditingController controller,
    TextInputType keyboardType = TextInputType.text,
    TextInputAction textInputAction = TextInputAction.next,
    FocusNode? focusNode,
    Iterable<String>? autofillHints,
    List<TextInputFormatter>? inputFormatters,
    int? maxLength,
    ValueChanged<String>? onChanged,
    String? errorText,
    bool isLastField = false,
    double sizeScale = 1.0,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: 6 * sizeScale),
      child: TextField(
        focusNode: focusNode,
        autofocus: focusNode != null ? false : false,
        controller: controller,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        autofillHints: autofillHints,
        inputFormatters: inputFormatters,
        maxLength: maxLength,
        onChanged: onChanged,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        onSubmitted: (_) {
          if (isLastField) {
            FocusScope.of(context).unfocus();
            return;
          }
          FocusScope.of(context).nextFocus();
        },
        style: TextStyle(fontSize: 12 * sizeScale),
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          labelStyle: TextStyle(fontSize: 11 * sizeScale, color: Colors.grey),
          floatingLabelStyle: TextStyle(
            fontSize: 11 * sizeScale,
            color: Theme.of(context).colorScheme.primary,
          ),
          hintStyle: TextStyle(fontSize: 12 * sizeScale, color: Colors.grey),
          errorText: errorText,
          errorStyle: TextStyle(fontSize: 10 * sizeScale),
          filled: true,
          fillColor: Colors.white,
          contentPadding: EdgeInsets.symmetric(
            horizontal: 8 * sizeScale,
            vertical: 6 * sizeScale,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8 * sizeScale),
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1.2,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8 * sizeScale),
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1.2,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8 * sizeScale),
            borderSide: BorderSide(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.65),
              width: 1.5,
            ),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8 * sizeScale),
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.error.withValues(alpha: 0.7),
              width: 1.3,
            ),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8 * sizeScale),
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.error,
              width: 1.5,
            ),
          ),
        ),
      ),
    );
  }

  bool _isValidEmailFormat(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return true;
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    return emailRegex.hasMatch(trimmed);
  }

  void _clearCustomerForm() {
    _customerNumberController.clear();
    _firstNameController.clear();
    _lastNameController.clear();
    _address1Controller.clear();
    _address2Controller.clear();
    _cityController.clear();
    _stateController.clear();
    _zipController.clear();
    _phoneController.clear();
    _emailController.clear();
  }

  List<String> _buildCurrentTransactionCustomerInfoLines() {
    final customerLabel = _postedFullName.isNotEmpty
        ? _postedFullName
        : [
            _firstNameController.text.trim(),
            _lastNameController.text.trim(),
          ].where((s) => s.isNotEmpty).join(' ');
    final customerNumber = _postedCustomerNumber.isNotEmpty
        ? _postedCustomerNumber
        : _customerNumberController.text.trim();
    final customerAddress1 = _postedAddress1.isNotEmpty
        ? _postedAddress1
        : _address1Controller.text.trim();
    final customerAddress2 = _postedAddress2.isNotEmpty
        ? _postedAddress2
        : _address2Controller.text.trim();
    final customerCityStateZip = _postedCityStateZip.isNotEmpty
        ? _postedCityStateZip
        : [
            _cityController.text.trim(),
            _stateController.text.trim(),
            _zipController.text.trim(),
          ].where((s) => s.isNotEmpty).join(' ');
    final customerEmail = _postedEmail.isNotEmpty
        ? _postedEmail
        : _emailController.text.trim();
    final invoiceReference = _invoiceReference.trim();

    final lines = <String>[];
    final staffIdValue = _staffId.trim();
    lines.add('Staff ID #: $staffIdValue');
    if (customerNumber.trim().isNotEmpty) {
      lines.add(customerNumber.trim());
    }
    if (customerLabel.trim().isNotEmpty) {
      lines.add(customerLabel.trim());
    }
    if (customerAddress1.trim().isNotEmpty) {
      lines.add(customerAddress1.trim());
    }
    if (customerAddress2.trim().isNotEmpty) {
      lines.add(customerAddress2.trim());
    }
    if (customerCityStateZip.trim().isNotEmpty) {
      lines.add(customerCityStateZip.trim());
    }
    if (customerEmail.trim().isNotEmpty) {
      lines.add(customerEmail.trim());
    }
    if (invoiceReference.isNotEmpty) {
      lines.add('Invoice/Reference: $invoiceReference');
    }

    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final numberPadDisplayBackgroundColor = cs.surfaceContainerHigh;
    final paymentsAreaBackgroundColor = cs.surfaceContainer;
    final mainTextColor = cs.onSurface;

    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: (event) {
        if (event is KeyDownEvent) {
          final key = event.logicalKey;

          if (key == LogicalKeyboardKey.numpad0 ||
              key == LogicalKeyboardKey.digit0) {
            _append('0');
            return;
          }
          if (key == LogicalKeyboardKey.numpad1 ||
              key == LogicalKeyboardKey.digit1) {
            _append('1');
            return;
          }
          if (key == LogicalKeyboardKey.numpad2 ||
              key == LogicalKeyboardKey.digit2) {
            _append('2');
            return;
          }
          if (key == LogicalKeyboardKey.numpad3 ||
              key == LogicalKeyboardKey.digit3) {
            _append('3');
            return;
          }
          if (key == LogicalKeyboardKey.numpad4 ||
              key == LogicalKeyboardKey.digit4) {
            _append('4');
            return;
          }
          if (key == LogicalKeyboardKey.numpad5 ||
              key == LogicalKeyboardKey.digit5) {
            _append('5');
            return;
          }
          if (key == LogicalKeyboardKey.numpad6 ||
              key == LogicalKeyboardKey.digit6) {
            _append('6');
            return;
          }
          if (key == LogicalKeyboardKey.numpad7 ||
              key == LogicalKeyboardKey.digit7) {
            _append('7');
            return;
          }
          if (key == LogicalKeyboardKey.numpad8 ||
              key == LogicalKeyboardKey.digit8) {
            _append('8');
            return;
          }
          if (key == LogicalKeyboardKey.numpad9 ||
              key == LogicalKeyboardKey.digit9) {
            _append('9');
            return;
          }
          if (key == LogicalKeyboardKey.numpadDecimal ||
              key == LogicalKeyboardKey.period) {
            return;
          }

          if (key == LogicalKeyboardKey.backspace ||
              key == LogicalKeyboardKey.delete) {
            _backspace();
            return;
          }

          if (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter) {
            unawaited(_addItem());
            return;
          }

          if (key == LogicalKeyboardKey.escape) {
            _clearItems();
            return;
          }

          final label = key.keyLabel.toLowerCase();
          if (_cashTrackingEnabled && label == 'c') {
            unawaited(_startCashFlow());
            return;
          }
          if (label == 'p') {
            if (!_terminalWarmingUp) unawaited(_startCardFlow());
            return;
          }
        }
      },
      child: Scaffold(
        body: DefaultTextStyle.merge(
          style: TextStyle(color: mainTextColor),
          child: TerminalAmbientBackground(
            style: AmbientBackgroundStyle.cinematic,
            child: SafeArea(
              child: Center(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const frameAspect = 19.5 / 9;
                    final usableWidth = (constraints.maxWidth - 24)
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

                    final terminalWorkingCanvas = KeyedSubtree(
                      key: _terminalViewportKey,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(screenCornerRadius),
                        child: Container(
                          color: Colors.white,
                          child: Stack(
                            children: [
                              Column(
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        const Center(child: RegisterSaleLogo()),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                              onTap: () => unawaited(
                                                _returnToLoginScreen(),
                                              ),
                                              child: Container(
                                                width: 18,
                                                height: 18,
                                                decoration: BoxDecoration(
                                                  color: _saleAccentGreen,
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                ),
                                                child: Icon(
                                                  Icons.arrow_back_ios_new,
                                                  color: Colors.white,
                                                  size: 11,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              child: Center(
                                                child: Text(
                                                  _terminalActiveScreen ==
                                                          'functions'
                                                      ? 'FUNCTIONS'
                                                      : 'SALE',
                                                  style: TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w800,
                                                    letterSpacing: 0.3,
                                                    color:
                                                        _terminalActiveScreen ==
                                                            'sale'
                                                        ? _saleAccentGreen
                                                        : null,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                              onTap: () => unawaited(
                                                _openSettingsWindow(),
                                              ),
                                              child: Container(
                                                width: 18,
                                                height: 18,
                                                decoration: BoxDecoration(
                                                  color: cs
                                                      .surfaceContainerHighest,
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                ),
                                                child: Icon(
                                                  Icons.settings,
                                                  size: 13,
                                                  color: cs.onSurfaceVariant,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (_terminalWarmingUp)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 5,
                                      ),
                                      color: const Color(0xFFFFF3CD),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width: 12,
                                            height: 12,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.5,
                                              color: const Color(0xFF856404),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              'Card terminal initializing — card payments will be available shortly.',
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: const Color(0xFF856404),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  Expanded(
                                    child: AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 280,
                                      ),
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      transitionBuilder: (child, animation) {
                                        final begin =
                                            _terminalScreenTransitionForward
                                            ? const Offset(1, 0)
                                            : const Offset(-1, 0);
                                        return ClipRect(
                                          child: SlideTransition(
                                            position: Tween<Offset>(
                                              begin: begin,
                                              end: Offset.zero,
                                            ).animate(animation),
                                            child: child,
                                          ),
                                        );
                                      },
                                      child:
                                          _terminalActiveScreen == 'functions'
                                          ? _buildTerminalFunctionsContent(
                                              cs: cs,
                                            )
                                          : _buildTerminalSaleContent(
                                              numberPadDisplayBackgroundColor:
                                                  numberPadDisplayBackgroundColor,
                                              paymentsAreaBackgroundColor:
                                                  paymentsAreaBackgroundColor,
                                              cs: cs,
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                              if (_terminalWarmingUp)
                                Positioned.fill(
                                  child: ColoredBox(
                                    color: const Color(0xF2FFFFFF),
                                    child: Center(
                                      child: Container(
                                        width: 280,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 20,
                                          vertical: 18,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFFF3CD),
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          border: Border.all(
                                            color: const Color(0xFF856404),
                                            width: 1.1,
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Color(0x22000000),
                                              blurRadius: 10,
                                              offset: Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: const [
                                            RegisterSaleLogo(),
                                            SizedBox(height: 10),
                                            Text(
                                              'PaaayIT is starting...',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFF856404),
                                              ),
                                            ),
                                            SizedBox(height: 8),
                                            SizedBox(
                                              width: 22,
                                              height: 22,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.4,
                                                color: Color(0xFF856404),
                                              ),
                                            ),
                                            SizedBox(height: 8),
                                            Text(
                                              'Preparing card terminal for today',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: Color(0xFF856404),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );

                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(10),
                      child: isNativeMobileDevice
                          ? SizedBox(
                              width: frameWidth,
                              height: frameHeight,
                              child: terminalWorkingCanvas,
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
                                    child: terminalWorkingCanvas,
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
}

class _QuickActionVisual {
  const _QuickActionVisual({
    required this.iconColor,
    required this.backgroundColor,
  });

  final Color iconColor;
  final Color backgroundColor;
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
      composing: TextRange.empty,
    );
  }
}

class PhoneNumberTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digitsOnly = newValue.text.replaceAll(RegExp(r'\D'), '');
    final limited = digitsOnly.length > 10
        ? digitsOnly.substring(0, 10)
        : digitsOnly;

    if (limited.isEmpty) {
      return const TextEditingValue(text: '');
    }

    String formatted;
    if (limited.length <= 3) {
      formatted = '($limited';
    } else if (limited.length <= 6) {
      formatted = '(${limited.substring(0, 3)}) ${limited.substring(3)}';
    } else {
      formatted =
          '(${limited.substring(0, 3)}) ${limited.substring(3, 6)}-${limited.substring(6)}';
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

class _ReceiptItemEntry {
  const _ReceiptItemEntry({
    required this.itemSku,
    required this.description,
    this.skuLabel,
  });

  final double itemSku;
  final String description;
  final String? skuLabel;
}

class _ReceiptOutputOptions {
  const _ReceiptOutputOptions({
    required this.previewEnabled,
    required this.copyCount,
  });

  final bool previewEnabled;
  final int copyCount;
}

class _InlineIntegrityCheckResult {
  const _InlineIntegrityCheckResult({
    required this.recordChecks,
    required this.fieldChecks,
    this.error,
  });

  final List<_InlineIntegrityCheckLine> recordChecks;
  final List<_InlineIntegrityCheckLine> fieldChecks;
  final String? error;

  bool get passed =>
      error == null &&
      recordChecks.every((line) => line.passed) &&
      fieldChecks.every((line) => line.passed);
}

class _InlineIntegrityCheckLine {
  const _InlineIntegrityCheckLine({
    required this.label,
    required this.passed,
    this.expected,
    this.actual,
  });

  final String label;
  final bool passed;
  final String? expected;
  final String? actual;
}
