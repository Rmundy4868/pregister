import 'dart:convert';
// ignore_for_file: deprecated_member_use

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../debug/integrity_checks_screen.dart';
import '../services/license_service.dart';
import '../services/settings_data_service.dart';
import '../services/transaction_flow_parameters.dart';
import '../terminal_config.dart';
import '../utils/text_file_save.dart';
import 'staff_manager_v2.dart';
import 'terminal_manager_v3.dart';

class SettingsWindow extends StatelessWidget {
  const SettingsWindow({required this.onOpenTable, super.key});

  final void Function(String tableName, String title) onOpenTable;

  @override
  Widget build(BuildContext context) {
    const compactButtonStyle = ButtonStyle(
      visualDensity: VisualDensity.compact,
      textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
    );
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      title: const Text('Settings', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 270,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              style: compactButtonStyle,
              onPressed: () =>
                  onOpenTable('organizations', 'Organization Setup'),
              child: const Text('Organization Setup'),
            ),
            const SizedBox(height: 4),
            ElevatedButton(
              style: compactButtonStyle,
              onPressed: () => onOpenTable('locations', 'Locations'),
              child: const Text('Update Locations'),
            ),
            const SizedBox(height: 4),
            ElevatedButton(
              style: compactButtonStyle,
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => const TerminalManagerV3Dialog(),
                );
              },
              child: const Text('Update Terminals'),
            ),
            const SizedBox(height: 4),
            ElevatedButton(
              style: compactButtonStyle,
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => const StaffManagerV2Dialog(),
                );
              },
              child: const Text('Staff Management'),
            ),
            const SizedBox(height: 4),
            ElevatedButton(
              style: compactButtonStyle,
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (dialogContext) =>
                      const _ReceiptOperatingParametersDialog(),
                );
              },
              child: const Text('Operating Parameters'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: compactButtonStyle,
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ReceiptOperatingParametersDialog extends StatefulWidget {
  const _ReceiptOperatingParametersDialog();

  @override
  State<_ReceiptOperatingParametersDialog> createState() =>
      _ReceiptOperatingParametersDialogState();
}

class _ReceiptOperatingParametersDialogState
    extends State<_ReceiptOperatingParametersDialog> {
  static const Map<String, String> _receiptTypes = {
    'sale': 'Sale',
    'void': 'Void',
    'return': 'Return',
  };

  final Map<String, bool> _previewEnabled = {
    'sale': true,
    'void': true,
    'return': true,
  };
  final Map<String, int> _copyCount = {'sale': 2, 'void': 2, 'return': 2};
  final Map<String, CustomerFieldMode> _customerFieldModes =
      TransactionFlowParameters.defaultCustomerFieldModes();
  final TextEditingController _receiptReplyToEmailController =
      TextEditingController();

  bool _staffTrackingEnabled = false;
  bool _customerTrackingEnabled = false;
  bool _integrityChecksEnabled = false;
  bool _enableProcessorSurcharge = false;

  bool _loading = true;
  bool _saving = false;
  bool _receiptReplyToLoadedWithValue = false;

  static const Map<String, String> _customerFieldLabels = {
    'invoice_reference': 'Invoice / Reference',
    'customer_id': 'Customer ID',
    'first_name': 'First Name',
    'last_name': 'Last Name',
    'address1': 'Address 1',
    'address2': 'Address 2',
    'city': 'City',
    'state': 'State',
    'zip': 'Zip',
    'email': 'Email',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _receiptReplyToEmailController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final txFlowParams = await TransactionFlowParameters.load();
    for (final type in _receiptTypes.keys) {
      _previewEnabled[type] = txFlowParams.receiptPreviewFor(type);
      _copyCount[type] = txFlowParams.receiptCopyCountFor(type);
    }
    _staffTrackingEnabled = txFlowParams.staffTrackingEnabled;
    _customerTrackingEnabled = txFlowParams.customerTrackingEnabled;
    _integrityChecksEnabled = txFlowParams.integrityChecksEnabled;
    _enableProcessorSurcharge = txFlowParams.enableProcessorSurcharge;
    _receiptReplyToEmailController.text = txFlowParams.receiptReplyToEmail;
    _receiptReplyToLoadedWithValue = txFlowParams.receiptReplyToEmail
        .trim()
        .isNotEmpty;
    for (final entry in txFlowParams.customerFieldModes.entries) {
      _customerFieldModes[entry.key] = entry.value;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
    });

    await TransactionFlowParameters(
      staffTrackingEnabled: _staffTrackingEnabled,
      customerTrackingEnabled: _customerTrackingEnabled,
      integrityChecksEnabled: _integrityChecksEnabled,
      enableProcessorSurcharge: _enableProcessorSurcharge,
      customerFieldModes: Map<String, CustomerFieldMode>.from(
        _customerFieldModes,
      ),
      receiptPreviewEnabled: Map<String, bool>.from(_previewEnabled),
      receiptCopyCount: Map<String, int>.from(_copyCount),
      receiptReplyToEmail: _receiptReplyToEmailController.text.trim(),
    ).save();

    if (!mounted) return;
    setState(() {
      _saving = false;
    });
    Navigator.of(context).pop();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Operating parameters saved.')),
    );
  }

  Widget _buildTypeCard(String type, String label) {
    final preview = _previewEnabled[type] ?? true;
    final copies = _copyCount[type] ?? 2;
    const dropdownTextStyle = TextStyle(fontSize: 13, color: Colors.black87);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$label Receipt Output',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
            ),
            const SizedBox(height: 2),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Print Preview',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                'Show preview before printing this receipt type',
                style: TextStyle(fontSize: 11),
              ),
              value: preview,
              onChanged: (value) {
                setState(() {
                  _previewEnabled[type] = value;
                });
              },
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Number of receipt copies',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                DropdownButton<int>(
                  value: copies,
                  isDense: true,
                  dropdownColor: Colors.white,
                  style: dropdownTextStyle,
                  items: List.generate(
                    10,
                    (index) => DropdownMenuItem(
                      value: index + 1,
                      child: Text(
                        index + 1 == 9 ? '9 (Preview Only)' : '${index + 1}',
                        style: dropdownTextStyle,
                      ),
                    ),
                  ),
                  selectedItemBuilder: (context) => List.generate(
                    10,
                    (index) => Text(
                      index + 1 == 9 ? '9 (Preview Only)' : '${index + 1}',
                      style: dropdownTextStyle,
                    ),
                  ),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _copyCount[type] = value;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 2),
            const Text(
              'Copy 9 = Preview only (merchant + customer). Copy 1 = Merchant, Copy 2 = Customer, Copy 3+ = Additional copies.',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionFlowCard() {
    final replyToText = _receiptReplyToEmailController.text.trim();
    final hasReplyTo = replyToText.isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Transaction Flow Parameters',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Staff ID Tracking',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                'Prompt for Staff ID after Card/Cash is pressed.',
                style: TextStyle(fontSize: 11),
              ),
              value: _staffTrackingEnabled,
              onChanged: (value) {
                setState(() {
                  _staffTrackingEnabled = value;
                });
              },
            ),
            const SizedBox(height: 2),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Customer Info Tracking',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                'Prompt for customer/transaction information before processing.',
                style: TextStyle(fontSize: 11),
              ),
              value: _customerTrackingEnabled,
              onChanged: (value) {
                setState(() {
                  _customerTrackingEnabled = value;
                });
              },
            ),
            const SizedBox(height: 2),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Integrity Checks',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                'Enable temporary process/database integrity diagnostics.',
                style: TextStyle(fontSize: 11),
              ),
              value: _integrityChecksEnabled,
              onChanged: (value) {
                setState(() {
                  _integrityChecksEnabled = value;
                });
              },
            ),
            const SizedBox(height: 2),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Enable Processor Surcharge',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                'When enabled, card/online payment requests ask the processor to calculate surcharge eligibility and amount.',
                style: TextStyle(fontSize: 11),
              ),
              value: _enableProcessorSurcharge,
              onChanged: (value) {
                setState(() {
                  _enableProcessorSurcharge = value;
                });
              },
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
                onPressed: _integrityChecksEnabled
                    ? () => showIntegrityChecksWorkbench(context)
                    : null,
                icon: const Icon(Icons.verified_outlined, size: 16),
                label: const Text('Integrity Checks'),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _receiptReplyToEmailController,
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Receipt Reply-To Email (Optional)',
                hintText: 'receipts@yourdomain.com',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 4),
            if (hasReplyTo)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1, right: 4),
                    child: Icon(Icons.info_outline, size: 14),
                  ),
                  Expanded(
                    child: Text(
                      _receiptReplyToLoadedWithValue
                          ? 'Loaded from terminal/location settings. This value may be inherited from your location default.'
                          : 'This terminal will use the entered Reply-To address for receipt emails.',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              )
            else
              const Text(
                'Leave blank to inherit your location default Reply-To on save.',
                style: TextStyle(fontSize: 11),
              ),
            if (_customerTrackingEnabled) ...[
              const SizedBox(height: 6),
              const Text(
                'Field State: Required / Optional / Hide',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              ...TransactionFlowParameters.customerFieldKeys.map((fieldKey) {
                final mode =
                    _customerFieldModes[fieldKey] ?? CustomerFieldMode.optional;
                final label = _customerFieldLabels[fieldKey] ?? fieldKey;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      DropdownButton<CustomerFieldMode>(
                        value: mode,
                        isDense: true,
                        dropdownColor: Colors.white,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black87,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: CustomerFieldMode.required,
                            child: Text(
                              'Required',
                              style: TextStyle(color: Colors.black87),
                            ),
                          ),
                          DropdownMenuItem(
                            value: CustomerFieldMode.optional,
                            child: Text(
                              'Optional',
                              style: TextStyle(color: Colors.black87),
                            ),
                          ),
                          DropdownMenuItem(
                            value: CustomerFieldMode.hidden,
                            child: Text(
                              'Hide',
                              style: TextStyle(color: Colors.black87),
                            ),
                          ),
                        ],
                        selectedItemBuilder: (context) => const [
                          Text(
                            'Required',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.black87,
                            ),
                          ),
                          Text(
                            'Optional',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.black87,
                            ),
                          ),
                          Text(
                            'Hide',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _customerFieldModes[fieldKey] = value;
                          });
                        },
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const compactButtonStyle = ButtonStyle(
      visualDensity: VisualDensity.compact,
      textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
    );
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      title: const Text('Operating Parameters', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ..._receiptTypes.entries.map(
                      (entry) => _buildTypeCard(entry.key, entry.value),
                    ),
                    _buildTransactionFlowCard(),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          style: compactButtonStyle,
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: compactButtonStyle,
          onPressed: _loading || _saving ? null : _save,
          child: Text(_saving ? 'Saving...' : 'Save'),
        ),
      ],
    );
  }
}

class TableListWindow extends StatefulWidget {
  const TableListWindow({
    required this.tableName,
    required this.title,
    super.key,
  });

  final String tableName;
  final String title;

  @override
  State<TableListWindow> createState() => _TableListWindowState();
}

class _LocationEditorSeed {
  final String locationId;
  final String organizationId;
  final String organizationName;
  final String organizationNumber;
  final String name;
  final String address;
  final String address2;
  final String city;
  final String state;
  final String zip;
  final String phone;
  final String terminalLicenses;
  final String terminalsActive;
  final bool allowTipAdjustments;
  final bool printTipSuggestions;
  final String tipSuggestion1Pct;
  final String tipSuggestion2Pct;
  final String tipSuggestion3Pct;
  final String tipSuggestionBase;
  final String receiptCardSignatureMessage;
  final String receiptMiscMessage;
  final String receiptReplyToEmail;

  const _LocationEditorSeed({
    required this.locationId,
    required this.organizationId,
    required this.organizationName,
    required this.organizationNumber,
    required this.name,
    required this.address,
    required this.address2,
    required this.city,
    required this.state,
    required this.zip,
    required this.phone,
    required this.terminalLicenses,
    required this.terminalsActive,
    required this.allowTipAdjustments,
    required this.printTipSuggestions,
    required this.tipSuggestion1Pct,
    required this.tipSuggestion2Pct,
    required this.tipSuggestion3Pct,
    required this.tipSuggestionBase,
    required this.receiptCardSignatureMessage,
    required this.receiptMiscMessage,
    required this.receiptReplyToEmail,
  });
}

class _TableListWindowState extends State<TableListWindow> {
  final SettingsDataService _settingsDataService = SettingsDataService();
  final ScrollController _organizationVerticalScrollController =
      ScrollController();
  final ScrollController _organizationHorizontalScrollController =
      ScrollController();
  final Map<String, bool> _locationTipAdjustmentsCache = <String, bool>{};
  late Future<List<Map<String, dynamic>>> _rowsFuture;
  int? _organizationSortColumnIndex;
  bool _organizationSortAscending = true;

  static const Map<String, String> _staffRoleOptions = {
    'admin': 'Administrator',
    'manager': 'Manager',
    'cashier': 'Cashier',
  };

  @override
  void initState() {
    super.initState();
    _rowsFuture = _loadRows();
  }

  @override
  void dispose() {
    _organizationVerticalScrollController.dispose();
    _organizationHorizontalScrollController.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _rowsFuture = _loadRows();
    });
  }

  bool _asBool(dynamic value, {bool defaultValue = true}) {
    if (value is bool) return value;
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == 'true' ||
        normalized == 't' ||
        normalized == '1' ||
        normalized == 'yes' ||
        normalized == 'y') {
      return true;
    }
    if (normalized == 'false' ||
        normalized == 'f' ||
        normalized == '0' ||
        normalized == 'no' ||
        normalized == 'n') {
      return false;
    }
    return defaultValue;
  }

  bool? _asOptionalBool(dynamic value) {
    if (value == null) return null;
    final normalized = value.toString().trim().toLowerCase();
    if (normalized == 'true' ||
        normalized == 't' ||
        normalized == '1' ||
        normalized == 'yes' ||
        normalized == 'y') {
      return true;
    }
    if (normalized == 'false' ||
        normalized == 'f' ||
        normalized == '0' ||
        normalized == 'no' ||
        normalized == 'n') {
      return false;
    }
    return null;
  }

  bool? _extractAllowTipAdjustments(Map<String, dynamic>? row) {
    if (row == null) return null;
    return _asOptionalBool(
      row['allow_tip_adjustments'] ?? row['allowTipAdjustments'],
    );
  }

  bool? _extractPrintTipSuggestions(Map<String, dynamic>? row) {
    if (row == null) return null;
    return _asOptionalBool(
      row['print_tip_suggestions'] ?? row['printTipSuggestions'],
    );
  }

  String _extractLocationString(Map<String, dynamic>? row, List<String> keys) {
    if (row == null) return '';
    for (final key in keys) {
      final value = row[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  Future<List<Map<String, dynamic>>>
  _loadOrganizationsForActiveLicense() async {
    final rows = await _settingsDataService.fetchTableRows(
      tableName: 'organizations',
    );
    final activeOrganizationNumber =
        LicenseService().activeContext?.organizationNumber.trim() ?? '';

    if (activeOrganizationNumber.isEmpty) {
      return const [];
    }

    return rows.where((row) {
      final rowOrganizationNumber =
          row['organization_number']?.toString().trim() ?? '';
      return rowOrganizationNumber == activeOrganizationNumber;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> _loadRows() async {
    if (widget.tableName == 'organizations') {
      return _loadOrganizationsForActiveLicense();
    }

    final activeLocationId =
        LicenseService().activeContext?.locationId.trim() ?? '';
    var rows = await _settingsDataService.fetchTableRows(
      tableName: widget.tableName,
    );

    if (widget.tableName != 'locations') {
      return rows;
    }

    if (activeLocationId.isNotEmpty) {
      rows = rows
          .where((row) => row['id']?.toString().trim() == activeLocationId)
          .toList();
    }

    if (rows.isEmpty) {
      final licenseService = LicenseService();
      final activeContext = licenseService.activeContext;
      final storedLicenseKey = await licenseService.getStoredLicenseKey();

      final lookupTokens = <String>[
        activeContext?.licenseKey ?? '',
        storedLicenseKey ?? '',
        activeContext?.organizationNumber ?? '',
      ]..removeWhere((value) => value.trim().isEmpty);

      List<Map<String, String>> fallbackLocationOptions = const [];
      for (final token in lookupTokens) {
        fallbackLocationOptions = await licenseService
            .fetchLocationOptionsForLicense(token);
        if (fallbackLocationOptions.isNotEmpty) {
          break;
        }
      }

      if (fallbackLocationOptions.isNotEmpty) {
        rows = fallbackLocationOptions
            .map(
              (option) => <String, dynamic>{
                'id': option['id'] ?? '',
                'name': option['name'] ?? '',
                'organization_id': activeContext?.organizationId ?? '',
                'organization_number': activeContext?.organizationNumber ?? '',
                'allow_tip_adjustments':
                    _locationTipAdjustmentsCache[option['id'] ?? ''],
              },
            )
            .toList();
        if (activeLocationId.isNotEmpty) {
          rows = rows
              .where((row) => row['id']?.toString().trim() == activeLocationId)
              .toList();
        }
      }
    }

    final enrichedRows = <Map<String, dynamic>>[];
    for (final row in rows) {
      final mutable = Map<String, dynamic>.from(row);
      final locationId = mutable['id']?.toString().trim() ?? '';

      if (locationId.isNotEmpty) {
        try {
          final details = await _settingsDataService.getLocationDetailsById(
            locationId,
          );
          if (!mounted) return rows;
          final detailsId = details['id']?.toString().trim() ?? '';
          if (detailsId.isNotEmpty) {
            mutable['name'] = details['name'] ?? mutable['name'];
            mutable['organization_id'] =
                details['organization_id'] ?? mutable['organization_id'];
            mutable['address'] =
                details['address'] ??
                details['address_1'] ??
                mutable['address'];
            mutable['address_2'] = details['address_2'] ?? mutable['address_2'];
            mutable['city'] = details['city'] ?? mutable['city'];
            mutable['state'] = details['state'] ?? mutable['state'];
            mutable['zip'] = details['zip'] ?? mutable['zip'];
            mutable['phone'] = details['phone'] ?? mutable['phone'];
            mutable['allow_tip_adjustments'] =
                details['allow_tip_adjustments'] ??
                mutable['allow_tip_adjustments'];
            mutable['print_tip_suggestions'] =
                details['print_tip_suggestions'] ??
                mutable['print_tip_suggestions'];
            mutable['tip_suggestion_1_pct'] =
                details['tip_suggestion_1_pct'] ??
                mutable['tip_suggestion_1_pct'];
            mutable['tip_suggestion_2_pct'] =
                details['tip_suggestion_2_pct'] ??
                mutable['tip_suggestion_2_pct'];
            mutable['tip_suggestion_3_pct'] =
                details['tip_suggestion_3_pct'] ??
                mutable['tip_suggestion_3_pct'];
            mutable['tip_suggestion_base'] =
                details['tip_suggestion_base'] ??
                mutable['tip_suggestion_base'];
            mutable['receipt_card_signature_message'] =
                details['receipt_card_signature_message'] ??
                mutable['receipt_card_signature_message'];
            mutable['receipt_misc_message'] =
                details['receipt_misc_message'] ??
                mutable['receipt_misc_message'];
          }
        } catch (_) {}
      }

      final extractedAllowTipAdjustments = _extractAllowTipAdjustments(mutable);
      final cachedAllowTipAdjustments = locationId.isNotEmpty
          ? _locationTipAdjustmentsCache[locationId]
          : null;
      if (extractedAllowTipAdjustments != null) {
        mutable['allow_tip_adjustments'] = extractedAllowTipAdjustments;
        if (locationId.isNotEmpty) {
          _locationTipAdjustmentsCache[locationId] =
              extractedAllowTipAdjustments;
        }
      } else if (cachedAllowTipAdjustments != null) {
        mutable['allow_tip_adjustments'] = cachedAllowTipAdjustments;
      } else {
        mutable['allow_tip_adjustments'] = null;
      }
      final organizationId = mutable['organization_id']?.toString() ?? '';
      if (organizationId.isNotEmpty) {
        final organization = await _settingsDataService
            .getOrganizationDetailsById(organizationId);
        final organizationNumber = organization['organization_number'] ?? '';
        final organizationName = organization['name'] ?? '';

        if (organizationNumber.isNotEmpty) {
          mutable['organization_number'] = organizationNumber;
        }
        if (organizationName.isNotEmpty) {
          mutable['organization_name'] = organizationName;
        }
      }
      enrichedRows.add(mutable);
    }

    return enrichedRows;
  }

  Widget _buildOrganizationsTable(
    List<Map<String, dynamic>> rows, {
    required bool includeActions,
  }) {
    const columns = ['name', 'license_key'];
    final sortedRows = List<Map<String, dynamic>>.from(rows);

    if (_organizationSortColumnIndex == null) {
      final defaultIndex = columns.indexOf('name');
      if (defaultIndex >= 0) {
        _organizationSortColumnIndex = defaultIndex;
        _organizationSortAscending = true;
      }
    }

    if (_organizationSortColumnIndex != null &&
        _organizationSortColumnIndex! >= 0 &&
        _organizationSortColumnIndex! < columns.length) {
      final sortColumn = columns[_organizationSortColumnIndex!];
      sortedRows.sort((a, b) {
        final aValue = (a[sortColumn] ?? '').toString().toLowerCase();
        final bValue = (b[sortColumn] ?? '').toString().toLowerCase();
        final comparison = aValue.compareTo(bValue);
        return _organizationSortAscending ? comparison : -comparison;
      });
    }

    return Scrollbar(
      controller: _organizationVerticalScrollController,
      thumbVisibility: true,
      interactive: true,
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.vertical,
      child: SingleChildScrollView(
        controller: _organizationVerticalScrollController,
        primary: false,
        scrollDirection: Axis.vertical,
        child: Scrollbar(
          controller: _organizationHorizontalScrollController,
          thumbVisibility: true,
          interactive: true,
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: _organizationHorizontalScrollController,
            primary: false,
            scrollDirection: Axis.horizontal,
            child: DataTable(
              sortColumnIndex: _organizationSortColumnIndex,
              sortAscending: _organizationSortAscending,
              columns: [
                ...columns.asMap().entries.map(
                  (entry) => DataColumn(
                    label: Text(entry.value == 'name' ? 'Name' : 'License Key'),
                    onSort: (columnIndex, ascending) {
                      setState(() {
                        _organizationSortColumnIndex = columnIndex;
                        _organizationSortAscending = ascending;
                      });
                    },
                  ),
                ),
                if (includeActions) const DataColumn(label: SizedBox.shrink()),
              ],
              rows: sortedRows
                  .map(
                    (row) => DataRow(
                      cells: [
                        ...columns.map(
                          (column) =>
                              DataCell(SelectableText('${row[column] ?? ''}')),
                        ),
                        if (includeActions)
                          DataCell(
                            ElevatedButton.icon(
                              onPressed: () => _editRow(row),
                              icon: const Icon(Icons.edit, size: 16),
                              label: const Text('Edit'),
                            ),
                          ),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLocationsTable(List<Map<String, dynamic>> rows) {
    return Scrollbar(
      controller: _organizationVerticalScrollController,
      thumbVisibility: true,
      interactive: true,
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.vertical,
      child: SingleChildScrollView(
        controller: _organizationVerticalScrollController,
        primary: false,
        scrollDirection: Axis.vertical,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Location Name')),
            DataColumn(label: SizedBox.shrink()),
          ],
          rows: rows
              .map(
                (row) => DataRow(
                  cells: [
                    DataCell(SelectableText('${row['name'] ?? ''}')),
                    DataCell(
                      ElevatedButton.icon(
                        onPressed: () => _editRow(row),
                        icon: const Icon(Icons.edit, size: 16),
                        label: const Text('Edit'),
                      ),
                    ),
                  ],
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _buildTerminalsTable(List<Map<String, dynamic>> rows) {
    const preferredOrder = [
      'id',
      'organization_id',
      'location_id',
      'location_name',
      'terminal_number',
      'terminal_name',
      'name',
      'code',
      'is_active',
      'registered_device_id',
      'registered_device_label',
      'last_seen_at',
      'spin_tpn',
      'spin_auth_key',
      'card_reader_type',
      'card_reader_hpp_auth_token',
      'auto_close_batch_enabled',
      'auto_close_batch_time',
    ];

    final discovered = <String>{};
    for (final row in rows) {
      for (final key in row.keys) {
        if (key.trim().isNotEmpty) {
          discovered.add(key);
        }
      }
    }

    final columns = <String>[
      ...preferredOrder.where(discovered.contains),
      ...discovered.where((key) => !preferredOrder.contains(key)).toList()
        ..sort(),
    ];

    String displayValueForColumn(String column, dynamic value) {
      final text = (value ?? '').toString();
      if (column == 'is_active') {
        return text.toLowerCase() == 'true' ? 'TRUE' : 'FALSE';
      }
      return text;
    }

    return Scrollbar(
      controller: _organizationVerticalScrollController,
      thumbVisibility: true,
      interactive: true,
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.vertical,
      child: SingleChildScrollView(
        controller: _organizationVerticalScrollController,
        primary: false,
        scrollDirection: Axis.vertical,
        child: Scrollbar(
          controller: _organizationHorizontalScrollController,
          thumbVisibility: true,
          interactive: true,
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: _organizationHorizontalScrollController,
            primary: false,
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                ...columns.map((column) => DataColumn(label: Text(column))),
                const DataColumn(label: Text('Actions')),
              ],
              rows: rows
                  .map(
                    (row) => DataRow(
                      cells: [
                        ...columns.map(
                          (column) => DataCell(
                            SelectableText(
                              displayValueForColumn(column, row[column]),
                            ),
                          ),
                        ),
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: () => _editRow(row),
                                child: const Text('Edit'),
                              ),
                              const SizedBox(width: 6),
                              TextButton(
                                onPressed: () => _deleteRow(row),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  String _staffRoleLabel(String value) {
    return _staffRoleOptions[value.trim().toLowerCase()] ?? value;
  }

  String _normalizeStaffRoleValue(String value) {
    switch (value.trim().toLowerCase()) {
      case 'administrator':
      case 'admin':
        return 'admin';
      case 'manager':
        return 'manager';
      case 'cashier':
        return 'cashier';
      default:
        return 'cashier';
    }
  }

  bool _isValidStaffPin(String value) {
    return RegExp(r'^\d{1,6}$').hasMatch(value.trim());
  }

  // ignore: unused_element
  Widget _buildStaffTable(List<Map<String, dynamic>> rows) {
    const columns = [
      'first_name',
      'last_name',
      'email',
      'phone',
      'role',
      'pin',
      'is_active',
      'organization_id',
      'location_id',
    ];

    String displayValueForColumn(String column, dynamic value) {
      final text = (value ?? '').toString();
      if (column == 'phone') {
        return _formatPhoneNumber(text);
      }
      if (column == 'role') {
        return _staffRoleLabel(text);
      }
      if (column == 'is_active') {
        return text.toLowerCase() == 'true' ? 'TRUE' : 'FALSE';
      }
      return text;
    }

    return Scrollbar(
      controller: _organizationVerticalScrollController,
      thumbVisibility: true,
      interactive: true,
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.vertical,
      child: SingleChildScrollView(
        controller: _organizationVerticalScrollController,
        primary: false,
        scrollDirection: Axis.vertical,
        child: Scrollbar(
          controller: _organizationHorizontalScrollController,
          thumbVisibility: true,
          interactive: true,
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: _organizationHorizontalScrollController,
            primary: false,
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('first_name')),
                DataColumn(label: Text('last_name')),
                DataColumn(label: Text('email')),
                DataColumn(label: Text('phone')),
                DataColumn(label: Text('role')),
                DataColumn(label: Text('pin')),
                DataColumn(label: Text('is_active')),
                DataColumn(label: Text('organization_id')),
                DataColumn(label: Text('location_id')),
                DataColumn(label: Text('Actions')),
              ],
              rows: rows
                  .map(
                    (row) => DataRow(
                      cells: [
                        ...columns.map(
                          (column) => DataCell(
                            SelectableText(
                              displayValueForColumn(column, row[column]),
                            ),
                          ),
                        ),
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: () => _editRow(row),
                                child: const Text('Edit'),
                              ),
                              const SizedBox(width: 6),
                              TextButton(
                                onPressed: () => _deleteRow(row),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  String _formatRow(Map<String, dynamic> row) {
    if (row.isEmpty) return '(empty row)';
    return row.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
  }

  String _userFacingError(Object error) {
    var text = error.toString().trim();
    text = text.replaceFirst(RegExp(r'^Exception:\s*'), '');
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    if (text.length > 220) {
      text = '${text.substring(0, 220)}...';
    }
    return text;
  }

  Future<void> _offerDeactivationCleanup({
    required BuildContext context,
    required String terminalNumber,
  }) async {
    if (!kIsWeb) return;
    final fileName = 'PaaayIT-Terminal-$terminalNumber.url';
    final psContent =
        r'$file = [System.Environment]::GetFolderPath("Desktop") + '
        '"\\\\$fileName"\r\n'
        r'if (Test-Path $file) { Remove-Item $file -Force; '
        'Write-Host \'Shortcut removed.\' } else { '
        'Write-Host \'Shortcut not found on Desktop.\' }\r\n';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Terminal Deactivated'),
        content: Text(
          'The terminal has been deactivated.\n\n'
          'Download the cleanup script to remove the desktop shortcut "$fileName" for this terminal.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Skip'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await _downloadTextFileFromSettings(
                psContent,
                'Remove-PaaayIT-Terminal-$terminalNumber.ps1',
              );
            },
            icon: const Icon(Icons.download),
            label: const Text('Download Cleanup Script'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadTextFileFromSettings(
    String content,
    String filename,
  ) async {
    await saveTextFile(content: content, fileName: filename);
  }

  void _showErrorSnackBar(String message) {
    _showErrorSnackBarWithMessenger(
      ScaffoldMessenger.maybeOf(context),
      message,
    );
  }

  void _showErrorSnackBarWithMessenger(
    ScaffoldMessengerState? messenger,
    String message,
  ) {
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(days: 1),
        showCloseIcon: true,
        content: Text(message),
        action: SnackBarAction(
          label: 'Copy',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: message));
          },
        ),
      ),
    );
  }

  void _showInfoSnackBarWithMessenger(
    ScaffoldMessengerState? messenger,
    String message,
  ) {
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatPhoneNumber(String input) {
    final digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';

    final limited = digits.length > 10 ? digits.substring(0, 10) : digits;
    final area = limited.length >= 3 ? limited.substring(0, 3) : limited;
    final middle = limited.length > 3
        ? limited.substring(3, limited.length >= 6 ? 6 : limited.length)
        : '';
    final last = limited.length > 6 ? limited.substring(6) : '';

    if (limited.length <= 3) {
      return '($area';
    }
    if (limited.length <= 6) {
      return '($area) $middle';
    }
    return '($area) $middle-$last';
  }

  String _normalizeTimeForInput(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return '';
    final match = RegExp(r'^(\d{1,2}:\d{2}(?::\d{2})?)').firstMatch(raw);
    return match?.group(1) ?? raw;
  }

  Future<void> _confirmAndDeleteRow({
    required Object id,
    required Map<String, dynamic> row,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final locationName = row['name']?.toString().trim() ?? '';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          widget.tableName == 'locations' ? 'Delete Location' : 'Delete Row',
        ),
        content: Text(
          widget.tableName == 'locations'
              ? 'Delete location: ${locationName.isNotEmpty ? locationName : 'Unknown Location'}?'
              : 'Delete row with id: $id?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              widget.tableName == 'locations' ? 'Delete Location' : 'Delete',
            ),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    try {
      if (widget.tableName == 'locations') {
        await _settingsDataService.deleteLocationForm(
          id: id,
          name: locationName,
        );
      } else {
        await _settingsDataService.deleteRow(
          tableName: widget.tableName,
          id: id,
        );
      }

      if (!mounted) return;
      _refresh();
    } catch (error) {
      _showErrorSnackBarWithMessenger(
        messenger,
        'Delete failed: ${_userFacingError(error)}',
      );
    }
  }

  Future<Map<String, dynamic>?> _showStaffFormDialog({
    required Map<String, dynamic>? initialRow,
    required String organizationId,
    required String locationId,
    required String organizationName,
    required String locationName,
  }) async {
    final organizationIdController = TextEditingController(
      text: organizationId,
    );
    final locationIdController = TextEditingController(text: locationId);
    final organizationNameController = TextEditingController(
      text: organizationName,
    );
    final locationNameController = TextEditingController(text: locationName);
    final firstNameController = TextEditingController(
      text: initialRow?['first_name']?.toString() ?? '',
    );
    final lastNameController = TextEditingController(
      text: initialRow?['last_name']?.toString() ?? '',
    );
    final emailController = TextEditingController(
      text: initialRow?['email']?.toString() ?? '',
    );
    final phoneController = TextEditingController(
      text: _formatPhoneNumber(initialRow?['phone']?.toString() ?? ''),
    );
    final pinController = TextEditingController(
      text: initialRow?['pin']?.toString() ?? '',
    );

    var selectedRole = _normalizeStaffRoleValue(
      initialRow?['role']?.toString() ?? 'cashier',
    );
    var isActive = _asBool(initialRow?['is_active'], defaultValue: true);

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (builderContext, setDialogState) => AlertDialog(
          title: Text(initialRow == null ? 'Add Staff' : 'Edit Staff'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (organizationIdController.text.trim().isEmpty ||
                      locationIdController.text.trim().isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        'Current organization or location context is missing. Staff cannot be saved until both values are available.',
                        style: TextStyle(
                          color: Theme.of(builderContext).colorScheme.error,
                        ),
                      ),
                    ),
                  TextField(
                    controller: organizationNameController,
                    readOnly: true,
                    enabled: false,
                    decoration: const InputDecoration(
                      labelText: 'Organization Name',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: locationNameController,
                    readOnly: true,
                    enabled: false,
                    decoration: const InputDecoration(
                      labelText: 'Location Name',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: firstNameController,
                    autofocus: initialRow == null,
                    decoration: const InputDecoration(
                      labelText: 'First Name *',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: pinController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'PIN *',
                      hintText: 'Up to 6 digits',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: lastNameController,
                    decoration: const InputDecoration(labelText: 'Last Name'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      TextInputFormatter.withFunction((oldValue, newValue) {
                        final formatted = _formatPhoneNumber(newValue.text);
                        return TextEditingValue(
                          text: formatted,
                          selection: TextSelection.collapsed(
                            offset: formatted.length,
                          ),
                        );
                      }),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Phone Number',
                      hintText: '(555) 123-4567',
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: selectedRole,
                    decoration: const InputDecoration(labelText: 'Role'),
                    items: _staffRoleOptions.entries
                        .map(
                          (entry) => DropdownMenuItem<String>(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        selectedRole = value;
                      });
                    },
                  ),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Is Active'),
                    value: isActive,
                    onChanged: (value) {
                      setDialogState(() {
                        isActive = value;
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (organizationIdController.text.trim().isEmpty ||
                    locationIdController.text.trim().isEmpty) {
                  _showErrorSnackBar(
                    'Organization ID and Location ID are required.',
                  );
                  return;
                }
                if (firstNameController.text.trim().isEmpty) {
                  _showErrorSnackBar('First Name is required.');
                  return;
                }
                if (!_isValidStaffPin(pinController.text)) {
                  _showErrorSnackBar(
                    'PIN must be numeric and no more than 6 digits.',
                  );
                  return;
                }

                Navigator.pop(dialogContext, {
                  'organizationId': organizationIdController.text.trim(),
                  'locationId': locationIdController.text.trim(),
                  'firstName': firstNameController.text.trim(),
                  'lastName': lastNameController.text.trim(),
                  'email': emailController.text.trim(),
                  'phone': phoneController.text.trim(),
                  'pin': pinController.text.trim(),
                  'role': selectedRole,
                  'isActive': isActive,
                });
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    organizationIdController.dispose();
    locationIdController.dispose();
    organizationNameController.dispose();
    locationNameController.dispose();
    firstNameController.dispose();
    lastNameController.dispose();
    emailController.dispose();
    phoneController.dispose();
    pinController.dispose();
    return result;
  }

  // ignore: unused_element
  Future<Map<String, dynamic>?> _openStaffForm({
    Map<String, dynamic>? initialRow,
  }) async {
    final activeContext = LicenseService().activeContext;
    final licenseService = LicenseService();

    final organizationId =
        initialRow?['organization_id']?.toString() ??
        activeContext?.organizationId ??
        '';
    final locationId =
        initialRow?['location_id']?.toString() ??
        activeContext?.locationId ??
        '';

    var organizationName = initialRow?['organization_name']?.toString() ?? '';
    if (organizationId.trim().isNotEmpty) {
      final organizationDetails = await _settingsDataService
          .getOrganizationDetailsById(organizationId);
      if (!mounted) return null;
      organizationName = organizationDetails['name'] ?? organizationName;
    }

    var locationName =
        initialRow?['location_name']?.toString() ??
        initialRow?['name']?.toString() ??
        '';
    if (locationId.trim().isNotEmpty) {
      final locationDetails = await _settingsDataService.getLocationDetailsById(
        locationId,
      );
      if (!mounted) return null;
      locationName = locationDetails['name'] ?? locationName;
    }

    if (locationName.trim().isEmpty &&
        locationId.trim().isNotEmpty &&
        activeContext?.locationId == locationId) {
      locationName = (await licenseService.getStoredLocationName()) ?? '';
      if (!mounted) return null;
    }

    return _showStaffFormDialog(
      initialRow: initialRow,
      organizationId: organizationId,
      locationId: locationId,
      organizationName: organizationName,
      locationName: locationName,
    );
  }

  Future<Map<String, dynamic>?> _showTerminalFormDialog({
    required Map<String, dynamic>? initialRow,
    required String locationId,
    required String organizationName,
    required String locationName,
  }) async {
    final organizationNameController = TextEditingController(
      text: organizationName,
    );
    final locationNameController = TextEditingController(text: locationName);
    final terminalNumberController = TextEditingController(
      text: initialRow?['terminal_number']?.toString() ?? '',
    );
    final terminalNameController = TextEditingController(
      text:
          initialRow?['terminal_name']?.toString() ??
          initialRow?['name']?.toString() ??
          '',
    );
    final codeController = TextEditingController(
      text: initialRow?['code']?.toString() ?? '',
    );
    final registeredDeviceController = TextEditingController(
      text:
          initialRow?['registered_device_label']?.toString() ??
          initialRow?['registered_device_id']?.toString() ??
          '',
    );
    final hppAuthTokenController = TextEditingController(
      text:
          initialRow?['card_reader_hpp_auth_token']?.toString() ??
          initialRow?['cardReaderHppAuthToken']?.toString() ??
          '',
    );
    final receiptPrinterNameController = TextEditingController(
      text:
          initialRow?['receipt_printer_name']?.toString() ??
          initialRow?['receiptPrinterName']?.toString() ??
          '',
    );
    final autoCloseTimeController = TextEditingController(
      text: _normalizeTimeForInput(initialRow?['auto_close_batch_time']),
    );

    final installedPrinterNames = <String>[];
    try {
      final printers = await Printing.listPrinters();
      for (final printer in printers) {
        final name = printer.name.trim();
        if (name.isNotEmpty && !installedPrinterNames.contains(name)) {
          installedPrinterNames.add(name);
        }
      }
      installedPrinterNames.sort();
    } catch (_) {
      // Keep manual input fallback when printer enumeration is unavailable.
    }
    if (!mounted) return null;
    var selectedReceiptPrinter = receiptPrinterNameController.text.trim();
    if (selectedReceiptPrinter.isNotEmpty &&
        !installedPrinterNames.contains(selectedReceiptPrinter)) {
      installedPrinterNames.insert(0, selectedReceiptPrinter);
    }

    var isActive = _asBool(initialRow?['is_active'], defaultValue: true);
    var autoCloseEnabled = _asBool(
      initialRow?['auto_close_batch_enabled'],
      defaultValue: false,
    );
    var cardReaderType =
        ((initialRow?['card_reader_type'] ?? initialRow?['cardReaderType'])
            ?.toString()
            .trim()
            .toLowerCase() ??
        TerminalConfig.cardReaderNone);
    if (cardReaderType != TerminalConfig.cardReaderNone) {
      cardReaderType = TerminalConfig.cardReaderDejavooP12;
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (builderContext, setDialogState) => AlertDialog(
          title: Text(initialRow == null ? 'Add Terminal' : 'Edit Terminal'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: organizationNameController,
                    enabled: false,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Organization Name',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: locationNameController,
                    enabled: false,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Location Name',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: terminalNumberController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Terminal Number *',
                      hintText: '0001',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: terminalNameController,
                    decoration: const InputDecoration(
                      labelText: 'Terminal Name *',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: codeController,
                    decoration: const InputDecoration(labelText: 'Code'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: cardReaderType,
                    decoration: const InputDecoration(labelText: 'Card Reader'),
                    items: const [
                      DropdownMenuItem(
                        value: TerminalConfig.cardReaderNone,
                        child: Text('No Card Reader'),
                      ),
                      DropdownMenuItem(
                        value: TerminalConfig.cardReaderDejavooP12,
                        child: Text('DejaVoo P12'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        cardReaderType = value;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      cardReaderType == TerminalConfig.cardReaderNone
                          ? 'This terminal will use keyed card-entry screens instead of a connected reader.'
                          : 'Use the connected DejaVoo P12 reader for card-present payments.',
                      style: Theme.of(builderContext).textTheme.bodySmall,
                    ),
                  ),
                  if (cardReaderType == TerminalConfig.cardReaderNone) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: hppAuthTokenController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'HPP Auth Token (for email/SMS links)',
                        hintText:
                            'Paste your Hosted Payment Page JWT token here',
                        helperText:
                            'Required for keyed card entry and transaction links',
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  if (installedPrinterNames.isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: selectedReceiptPrinter.isEmpty
                          ? null
                          : selectedReceiptPrinter,
                      decoration: const InputDecoration(
                        labelText: 'Default Receipt Printer',
                        helperText: 'Receipts will use this printer by default',
                      ),
                      items: [
                        const DropdownMenuItem<String>(
                          value: '',
                          child: Text('None'),
                        ),
                        ...installedPrinterNames.map(
                          (printerName) => DropdownMenuItem<String>(
                            value: printerName,
                            child: Text(printerName),
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          selectedReceiptPrinter = (value ?? '').trim();
                          receiptPrinterNameController.text =
                              selectedReceiptPrinter;
                        });
                      },
                    )
                  else ...[
                    TextField(
                      controller: receiptPrinterNameController,
                      decoration: const InputDecoration(
                        labelText: 'Default Receipt Printer',
                        hintText: 'e.g. STAR TSP100',
                        helperText:
                            'Enter the exact printer name. Browse can help you find it, then save it here.',
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.print_outlined, size: 16),
                        label: const Text('Browse Printers…'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                        onPressed: () async {
                          try {
                            final printers = await Printing.listPrinters();
                            if (!builderContext.mounted) return;

                            final names =
                                printers
                                    .map((p) => p.name.trim())
                                    .where((n) => n.isNotEmpty)
                                    .toSet()
                                    .toList()
                                  ..sort();

                            if (names.isNotEmpty) {
                              final picked = await showDialog<String>(
                                context: builderContext,
                                builder: (pickerContext) => SimpleDialog(
                                  title: const Text('Select Receipt Printer'),
                                  children: [
                                    ...names.map(
                                      (name) => SimpleDialogOption(
                                        onPressed: () => Navigator.of(
                                          pickerContext,
                                        ).pop(name),
                                        child: Text(name),
                                      ),
                                    ),
                                  ],
                                ),
                              );

                              if (picked != null && picked.trim().isNotEmpty) {
                                setDialogState(() {
                                  selectedReceiptPrinter = picked.trim();
                                  receiptPrinterNameController.text =
                                      selectedReceiptPrinter;
                                });
                              }
                              return;
                            }
                          } catch (_) {
                            // Fall through to OS print dialog fallback.
                          }

                          // Browser fallback: show OS print dialog to inspect
                          // installed printers, then prompt to save the chosen
                          // name into this form field.
                          try {
                            await Printing.layoutPdf(
                              name: 'Printer Browser — pregister',
                              onLayout: (_) async {
                                final doc = pw.Document();
                                doc.addPage(
                                  pw.Page(
                                    pageFormat: const PdfPageFormat(
                                      80 * PdfPageFormat.mm,
                                      40 * PdfPageFormat.mm,
                                    ),
                                    build: (_) => pw.Center(
                                      child: pw.Text(
                                        'Cancel this dialog\nto note your receipt printer name.',
                                        textAlign: pw.TextAlign.center,
                                        style: const pw.TextStyle(fontSize: 10),
                                      ),
                                    ),
                                  ),
                                );
                                return doc.save();
                              },
                            );
                          } catch (_) {
                            // Ignore — user may have cancelled.
                          }

                          if (!builderContext.mounted) return;
                          final nameController = TextEditingController(
                            text: receiptPrinterNameController.text,
                          );
                          final enteredName = await showDialog<String>(
                            context: builderContext,
                            builder: (nameContext) => AlertDialog(
                              title: const Text('Save Printer Name'),
                              content: TextField(
                                controller: nameController,
                                autofocus: true,
                                decoration: const InputDecoration(
                                  labelText: 'Printer name from dialog',
                                  hintText: 'e.g. STAR TSP100',
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(nameContext).pop(),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(
                                    nameContext,
                                  ).pop(nameController.text.trim()),
                                  child: const Text('Use Name'),
                                ),
                              ],
                            ),
                          );

                          if (enteredName != null &&
                              enteredName.trim().isNotEmpty) {
                            setDialogState(() {
                              selectedReceiptPrinter = enteredName.trim();
                              receiptPrinterNameController.text =
                                  selectedReceiptPrinter;
                            });
                          }
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto-close batch enabled'),
                    value: autoCloseEnabled,
                    onChanged: (value) {
                      setDialogState(() {
                        autoCloseEnabled = value;
                        if (!value) autoCloseTimeController.clear();
                      });
                    },
                  ),
                  TextField(
                    controller: autoCloseTimeController,
                    enabled: autoCloseEnabled,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9:]')),
                      LengthLimitingTextInputFormatter(8),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Auto-close time (24h)',
                      hintText: 'HH:mm or HH:mm:ss',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: registeredDeviceController,
                    enabled: false,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Registered Device',
                    ),
                  ),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Is Active'),
                    value: isActive,
                    onChanged: (value) {
                      setDialogState(() {
                        isActive = value;
                      });
                    },
                  ),
                  if (initialRow != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () async {
                          final dialogNavigator = Navigator.of(dialogContext);
                          final confirmed = await showDialog<bool>(
                            context: dialogContext,
                            builder: (confirmContext) => AlertDialog(
                              title: const Text('Deactivate Terminal'),
                              content: const Text(
                                'This will deactivate the terminal and unbind any registered device. Continue?',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(confirmContext, false),
                                  child: const Text('Cancel'),
                                ),
                                ElevatedButton(
                                  onPressed: () =>
                                      Navigator.pop(confirmContext, true),
                                  child: const Text('Deactivate'),
                                ),
                              ],
                            ),
                          );

                          if (confirmed != true) return;

                          // Offer cleanup script download before closing
                          if (context.mounted) {
                            await _offerDeactivationCleanup(
                              context: dialogContext,
                              terminalNumber: terminalNumberController.text
                                  .trim(),
                            );
                          }

                          dialogNavigator.pop({
                            'locationId': locationId,
                            'terminalNumber': terminalNumberController.text
                                .trim(),
                            'name': terminalNameController.text.trim(),
                            'code': codeController.text.trim(),
                            'cardReaderType': cardReaderType,
                            'cardReaderHppAuthToken': hppAuthTokenController
                                .text
                                .trim(),
                            'autoCloseBatchEnabled': autoCloseEnabled,
                            'autoCloseBatchTime': autoCloseTimeController.text
                                .trim(),
                            'isActive': false,
                          });
                        },
                        icon: const Icon(Icons.warning_amber_rounded),
                        label: const Text('Deactivate Terminal'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final terminalNumber = terminalNumberController.text.trim();
                final terminalName = terminalNameController.text.trim();

                if (locationId.trim().isEmpty) {
                  _showErrorSnackBar(
                    'Location is required for terminal setup.',
                  );
                  return;
                }
                if (!RegExp(r'^\d{4}$').hasMatch(terminalNumber)) {
                  _showErrorSnackBar(
                    'Terminal Number must be exactly 4 digits.',
                  );
                  return;
                }
                if (terminalName.isEmpty) {
                  _showErrorSnackBar('Terminal Name is required.');
                  return;
                }
                final autoCloseTime = autoCloseTimeController.text.trim();
                if (autoCloseEnabled) {
                  final valid = RegExp(
                    r'^(\d{1,2}):(\d{2})(?::\d{2})?$',
                  ).hasMatch(autoCloseTime);
                  if (!valid) {
                    _showErrorSnackBar(
                      'Auto-close time must be HH:mm or HH:mm:ss in 24-hour format.',
                    );
                    return;
                  }
                }

                Navigator.pop(dialogContext, {
                  'locationId': locationId,
                  'terminalNumber': terminalNumber,
                  'name': terminalName,
                  'code': codeController.text.trim(),
                  'cardReaderType': cardReaderType,
                  'cardReaderHppAuthToken': hppAuthTokenController.text.trim(),
                  'receiptPrinterName': receiptPrinterNameController.text
                      .trim(),
                  'autoCloseBatchEnabled': autoCloseEnabled,
                  'autoCloseBatchTime': autoCloseTime,
                  'isActive': isActive,
                });
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    organizationNameController.dispose();
    locationNameController.dispose();
    terminalNumberController.dispose();
    terminalNameController.dispose();
    codeController.dispose();
    registeredDeviceController.dispose();
    hppAuthTokenController.dispose();
    receiptPrinterNameController.dispose();
    autoCloseTimeController.dispose();
    return result;
  }

  Future<Map<String, dynamic>?> _openTerminalForm({
    Map<String, dynamic>? initialRow,
  }) async {
    Map<String, dynamic>? effectiveRow = initialRow;
    final initialTerminalId = (initialRow?['id'] ?? '').toString().trim();
    if (initialTerminalId.isNotEmpty) {
      final terminalDetails = await _settingsDataService.getTerminalDetailsById(
        initialTerminalId,
      );
      if (!mounted) return null;
      if (terminalDetails != null) {
        effectiveRow = {
          ...?initialRow,
          ...terminalDetails,
          // Keep table/UI aliases expected by dialog fields.
          'terminal_name':
              terminalDetails['terminal_name'] ??
              terminalDetails['name'] ??
              initialRow?['terminal_name'],
          'card_reader_type':
              terminalDetails['card_reader_type'] ??
              initialRow?['card_reader_type'],
          'card_reader_hpp_auth_token':
              terminalDetails['card_reader_hpp_auth_token'] ??
              initialRow?['card_reader_hpp_auth_token'],
        };
      }
    }

    final activeContext = LicenseService().activeContext;

    final organizationId =
        effectiveRow?['organization_id']?.toString() ??
        activeContext?.organizationId ??
        '';
    final locationId =
        effectiveRow?['location_id']?.toString() ??
        activeContext?.locationId ??
        '';

    var organizationName = '';
    if (organizationId.trim().isNotEmpty) {
      final organizationDetails = await _settingsDataService
          .getOrganizationDetailsById(organizationId);
      if (!mounted) return null;
      organizationName = organizationDetails['name'] ?? '';
    }

    var locationName = effectiveRow?['location_name']?.toString() ?? '';
    if (locationName.trim().isEmpty && locationId.trim().isNotEmpty) {
      final locationDetails = await _settingsDataService.getLocationDetailsById(
        locationId,
      );
      if (!mounted) return null;
      locationName = locationDetails['name'] ?? '';
    }

    if (locationName.trim().isEmpty &&
        activeContext?.locationId == locationId &&
        locationId.trim().isNotEmpty) {
      locationName = (await LicenseService().getStoredLocationName()) ?? '';
      if (!mounted) return null;
    }

    return _showTerminalFormDialog(
      initialRow: effectiveRow,
      locationId: locationId,
      organizationName: organizationName,
      locationName: locationName,
    );
  }

  Future<Map<String, dynamic>?> _openRowEditor({
    Map<String, dynamic>? initialRow,
  }) async {
    final encoder = const JsonEncoder.withIndent('  ');
    final controller = TextEditingController(
      text: initialRow == null ? '{\n\n}' : encoder.convert(initialRow),
    );

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(initialRow == null ? 'Add Row' : 'Edit Row'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: controller,
            maxLines: 16,
            decoration: const InputDecoration(
              labelText: 'Row JSON',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              try {
                final decoded = jsonDecode(controller.text.trim());
                if (decoded is! Map) {
                  throw const FormatException('JSON must be an object');
                }

                Navigator.pop(
                  dialogContext,
                  Map<String, dynamic>.from(decoded),
                );
              } catch (error) {
                _showErrorSnackBar('Invalid JSON: ${_userFacingError(error)}');
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    controller.dispose();
    return result;
  }

  Future<Map<String, String>?> _showLocationEditorDialog({
    required _LocationEditorSeed seed,
    required bool isEditing,
  }) async {
    final orgIdController = TextEditingController(text: seed.organizationId);
    final orgNameController = TextEditingController(
      text: seed.organizationName,
    );
    final orgNumberController = TextEditingController(
      text: seed.organizationNumber,
    );
    final nameController = TextEditingController(text: seed.name);
    final addressController = TextEditingController(text: seed.address);
    final address2Controller = TextEditingController(text: seed.address2);
    final cityController = TextEditingController(text: seed.city);
    final stateController = TextEditingController(text: seed.state);
    final zipController = TextEditingController(text: seed.zip);
    final phoneController = TextEditingController(text: seed.phone);
    final terminalLicensesController = TextEditingController(
      text: seed.terminalLicenses,
    );
    final terminalsActiveController = TextEditingController(
      text: seed.terminalsActive,
    );
    final tipSuggestion1PctController = TextEditingController(
      text: seed.tipSuggestion1Pct,
    );
    final tipSuggestion2PctController = TextEditingController(
      text: seed.tipSuggestion2Pct,
    );
    final tipSuggestion3PctController = TextEditingController(
      text: seed.tipSuggestion3Pct,
    );
    final receiptCardSignatureMessageController = TextEditingController(
      text: seed.receiptCardSignatureMessage,
    );
    final receiptMiscMessageController = TextEditingController(
      text: seed.receiptMiscMessage,
    );
    final receiptReplyToEmailController = TextEditingController(
      text: seed.receiptReplyToEmail,
    );

    var allowTipAdjustmentsEnabled = seed.allowTipAdjustments;
    var printTipSuggestionsEnabled = seed.printTipSuggestions;
    var tipSuggestionBase = seed.tipSuggestionBase;

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (builderContext, setDialogState) => AlertDialog(
          title: Text(isEditing ? 'Edit Location' : 'Add Location'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isEditing && orgNumberController.text.trim().isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        'Organization context is missing. Save will use license activation fallback to create/select the location.',
                        style: TextStyle(
                          color: Theme.of(builderContext).colorScheme.error,
                        ),
                      ),
                    ),
                  TextField(
                    controller: orgNameController,
                    enabled: false,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Organization Name',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: orgIdController,
                    enabled: false,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Organization ID',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: orgNumberController,
                    enabled: false,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Organization Number',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameController,
                    autofocus: !isEditing,
                    decoration: const InputDecoration(
                      labelText: 'Location Name *',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: addressController,
                    decoration: const InputDecoration(labelText: 'Address'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: address2Controller,
                    decoration: const InputDecoration(labelText: 'Address 2'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: cityController,
                    decoration: const InputDecoration(labelText: 'City'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: stateController,
                    decoration: const InputDecoration(labelText: 'State'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: zipController,
                    decoration: const InputDecoration(labelText: 'ZIP'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      TextInputFormatter.withFunction((oldValue, newValue) {
                        final formatted = _formatPhoneNumber(newValue.text);
                        return TextEditingValue(
                          text: formatted,
                          selection: TextSelection.collapsed(
                            offset: formatted.length,
                          ),
                        );
                      }),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Phone Number',
                      hintText: '(555) 123-4567',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: terminalLicensesController,
                    enabled: false,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Terminal Licenses',
                      hintText: 'Display only',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: terminalsActiveController,
                    enabled: false,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Terminals Active',
                      hintText: 'Display only',
                    ),
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow Tip Adjustments'),
                    subtitle: const Text(
                      'Enable post-sale tip adjust for this location.',
                    ),
                    value: allowTipAdjustmentsEnabled,
                    onChanged: (value) {
                      setDialogState(() {
                        allowTipAdjustmentsEnabled = value;
                      });
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Print Tip Suggestions'),
                    subtitle: const Text(
                      'Show suggested tip percentages and write-in lines on sale receipts.',
                    ),
                    value: printTipSuggestionsEnabled,
                    onChanged: allowTipAdjustmentsEnabled
                        ? (value) {
                            setDialogState(() {
                              printTipSuggestionsEnabled = value;
                            });
                          }
                        : null,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: tipSuggestionBase,
                    decoration: const InputDecoration(
                      labelText: 'Tip Suggestion Base',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'subtotal',
                        child: Text('Subtotal (pre-tax)'),
                      ),
                      DropdownMenuItem(
                        value: 'total',
                        child: Text('Total (with tax)'),
                      ),
                    ],
                    onChanged: allowTipAdjustmentsEnabled
                        ? (value) {
                            setDialogState(() {
                              tipSuggestionBase = value ?? 'subtotal';
                            });
                          }
                        : null,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: tipSuggestion1PctController,
                          enabled: allowTipAdjustmentsEnabled,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d{0,3}(\.\d{0,2})?$'),
                            ),
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Tip % 1',
                            hintText: '18',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: tipSuggestion2PctController,
                          enabled: allowTipAdjustmentsEnabled,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d{0,3}(\.\d{0,2})?$'),
                            ),
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Tip % 2',
                            hintText: '20',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: tipSuggestion3PctController,
                          enabled: allowTipAdjustmentsEnabled,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d{0,3}(\.\d{0,2})?$'),
                            ),
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Tip % 3',
                            hintText: '25',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: receiptCardSignatureMessageController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Card Signature Message',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: receiptMiscMessageController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Miscellaneous Message',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: receiptReplyToEmailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Receipt Reply-To Email',
                      hintText: 'receipts@yourdomain.com',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.trim().isEmpty) {
                  _showErrorSnackBar('Location Name is required.');
                  return;
                }

                final terminalLicenses =
                    int.tryParse(terminalLicensesController.text.trim()) ?? 0;
                final terminalsActive =
                    int.tryParse(terminalsActiveController.text.trim()) ?? 0;

                if (terminalLicenses < 0 || terminalsActive < 0) {
                  _showErrorSnackBar('Terminal values cannot be negative.');
                  return;
                }
                if (terminalLicenses > 0 &&
                    terminalsActive > terminalLicenses) {
                  _showErrorSnackBar(
                    'Terminals Active cannot exceed Terminal Licenses.',
                  );
                  return;
                }

                final tipSuggestionValues = [
                  tipSuggestion1PctController.text.trim(),
                  tipSuggestion2PctController.text.trim(),
                  tipSuggestion3PctController.text.trim(),
                ].map(double.tryParse).toList();
                if (tipSuggestionValues.any((value) => value == null)) {
                  _showErrorSnackBar(
                    'Tip suggestion percentages must be valid numbers.',
                  );
                  return;
                }
                if (tipSuggestionValues.any(
                  (value) => value! < 0 || value > 100,
                )) {
                  _showErrorSnackBar(
                    'Tip suggestion percentages must be between 0 and 100.',
                  );
                  return;
                }

                Navigator.pop(dialogContext, {
                  'organizationId': orgIdController.text.trim(),
                  'organizationName': orgNameController.text.trim(),
                  'organizationNumber': orgNumberController.text.trim(),
                  'name': nameController.text.trim(),
                  'address': addressController.text.trim(),
                  'address2': address2Controller.text.trim(),
                  'city': cityController.text.trim(),
                  'state': stateController.text.trim(),
                  'zip': zipController.text.trim(),
                  'phone': phoneController.text.trim(),
                  'terminalLicenses': terminalLicensesController.text.trim(),
                  'terminalsActive': terminalsActiveController.text.trim(),
                  'allowTipAdjustments': allowTipAdjustmentsEnabled
                      ? 'true'
                      : 'false',
                  'printTipSuggestions': printTipSuggestionsEnabled
                      ? 'true'
                      : 'false',
                  'tipSuggestion1Pct': tipSuggestion1PctController.text.trim(),
                  'tipSuggestion2Pct': tipSuggestion2PctController.text.trim(),
                  'tipSuggestion3Pct': tipSuggestion3PctController.text.trim(),
                  'tipSuggestionBase': tipSuggestionBase,
                  'receiptCardSignatureMessage':
                      receiptCardSignatureMessageController.text.trim(),
                  'receiptMiscMessage': receiptMiscMessageController.text
                      .trim(),
                  'receiptReplyToEmail': receiptReplyToEmailController.text
                      .trim(),
                });
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    orgIdController.dispose();
    orgNameController.dispose();
    orgNumberController.dispose();
    nameController.dispose();
    addressController.dispose();
    address2Controller.dispose();
    cityController.dispose();
    stateController.dispose();
    zipController.dispose();
    phoneController.dispose();
    terminalLicensesController.dispose();
    terminalsActiveController.dispose();
    tipSuggestion1PctController.dispose();
    tipSuggestion2PctController.dispose();
    tipSuggestion3PctController.dispose();
    receiptCardSignatureMessageController.dispose();
    receiptMiscMessageController.dispose();
    receiptReplyToEmailController.dispose();
    return result;
  }

  Future<_LocationEditorSeed?> _buildLocationEditorSeedForCreate() async {
    var organizationId = '';
    var organizationName = '';
    var organizationNumber = '';

    final activeContext = LicenseService().activeContext;
    final activeOrganizationId = activeContext?.organizationId ?? '';
    final activeOrganizationNumber = activeContext?.organizationNumber ?? '';

    if (activeOrganizationId.isNotEmpty) {
      organizationId = activeOrganizationId;
    }

    if (activeOrganizationNumber.isNotEmpty) {
      organizationNumber = activeOrganizationNumber;
    } else {
      final defaultOrganizationNumber = await _settingsDataService
          .getDefaultOrganizationNumber();
      if (!mounted) return null;
      organizationNumber = defaultOrganizationNumber ?? '';
    }

    final orgDetails = await _settingsDataService
        .getOrganizationDetailsByNumber(organizationNumber.trim());
    if (!mounted) return null;

    final resolvedOrganizationId = (orgDetails['id'] ?? '').trim();
    final resolvedOrganizationName = (orgDetails['name'] ?? '').trim();

    if (resolvedOrganizationId.isNotEmpty) {
      organizationId = resolvedOrganizationId;
    }
    if (resolvedOrganizationName.isNotEmpty) {
      organizationName = resolvedOrganizationName;
    }

    return _LocationEditorSeed(
      locationId: '',
      organizationId: organizationId,
      organizationName: organizationName,
      organizationNumber: organizationNumber,
      name: '',
      address: '',
      address2: '',
      city: '',
      state: '',
      zip: '',
      phone: '',
      terminalLicenses: '1',
      terminalsActive: '0',
      allowTipAdjustments: false,
      printTipSuggestions: true,
      tipSuggestion1Pct: '18',
      tipSuggestion2Pct: '20',
      tipSuggestion3Pct: '25',
      tipSuggestionBase: 'subtotal',
      receiptCardSignatureMessage: '',
      receiptMiscMessage: '',
      receiptReplyToEmail: '',
    );
  }

  Future<_LocationEditorSeed?> _buildLocationEditorSeedForEdit(
    Map<String, dynamic> initialRow,
  ) async {
    final locationId = initialRow['id']?.toString().trim() ?? '';
    if (locationId.isEmpty) {
      _showErrorSnackBar('Cannot edit location without a location id.');
      return null;
    }

    final effective = Map<String, dynamic>.from(initialRow);
    try {
      final latest = await _settingsDataService.getLocationDetailsById(
        locationId,
      );
      if (!mounted) return null;
      final latestId = latest['id']?.toString().trim() ?? '';
      if (latestId.isNotEmpty) {
        effective.addAll({
          'id': latest['id'],
          'organization_id': latest['organization_id'],
          'name': latest['name'],
          'address': latest['address'] ?? latest['address_1'],
          'address_2': latest['address_2'],
          'city': latest['city'],
          'state': latest['state'],
          'zip': latest['zip'],
          'phone': latest['phone'],
          'allow_tip_adjustments': latest['allow_tip_adjustments'],
          'print_tip_suggestions': latest['print_tip_suggestions'],
          'tip_suggestion_1_pct': latest['tip_suggestion_1_pct'],
          'tip_suggestion_2_pct': latest['tip_suggestion_2_pct'],
          'tip_suggestion_3_pct': latest['tip_suggestion_3_pct'],
          'tip_suggestion_base': latest['tip_suggestion_base'],
          'receipt_card_signature_message':
              latest['receipt_card_signature_message'],
          'receipt_misc_message': latest['receipt_misc_message'],
          'receipt_reply_to_email': latest['receipt_reply_to_email'],
        });
      }
    } catch (_) {}

    final organizationId =
        effective['organization_id']?.toString().trim() ?? '';
    var organizationName =
        effective['organization_name']?.toString().trim() ?? '';
    var organizationNumber =
        effective['organization_number']?.toString().trim() ?? '';

    if (organizationId.isNotEmpty) {
      final orgDetails = await _settingsDataService.getOrganizationDetailsById(
        organizationId,
      );
      if (!mounted) return null;
      if ((orgDetails['name'] ?? '').trim().isNotEmpty) {
        organizationName = orgDetails['name']!.trim();
      }
      if ((orgDetails['organization_number'] ?? '').trim().isNotEmpty) {
        organizationNumber = orgDetails['organization_number']!.trim();
      }
    }

    var allowTipAdjustments =
        _extractAllowTipAdjustments(effective) ??
        _locationTipAdjustmentsCache[locationId];

    if (allowTipAdjustments == null) {
      try {
        allowTipAdjustments = await _settingsDataService
            .getLocationAllowTipAdjustmentsByLicenseContext(
              locationId: locationId,
              locationName: effective['name']?.toString() ?? '',
            );
      } catch (_) {}
    }

    if (allowTipAdjustments == null) {
      _showErrorSnackBar(
        'Unable to resolve current Allow Tip Adjustments value for this location. '
        'Refresh and try again so we do not overwrite it incorrectly.',
      );
      return null;
    }

    _locationTipAdjustmentsCache[locationId] = allowTipAdjustments;

    return _LocationEditorSeed(
      locationId: locationId,
      organizationId: organizationId,
      organizationName: organizationName,
      organizationNumber: organizationNumber,
      name: effective['name']?.toString() ?? '',
      address:
          (effective['address'] ?? effective['address_1'])?.toString() ?? '',
      address2: effective['address_2']?.toString() ?? '',
      city: effective['city']?.toString() ?? '',
      state: effective['state']?.toString() ?? '',
      zip: effective['zip']?.toString() ?? '',
      phone: _formatPhoneNumber(
        (effective['phone'] ?? effective['phone_number'])?.toString() ?? '',
      ),
      terminalLicenses: effective['terminal_licenses']?.toString() ?? '',
      terminalsActive: effective['terminals_active']?.toString() ?? '',
      allowTipAdjustments: allowTipAdjustments,
      printTipSuggestions: _extractPrintTipSuggestions(effective) ?? true,
      tipSuggestion1Pct:
          _extractLocationString(effective, [
            'tip_suggestion_1_pct',
            'tipSuggestion1Pct',
          ]).isEmpty
          ? '18'
          : _extractLocationString(effective, [
              'tip_suggestion_1_pct',
              'tipSuggestion1Pct',
            ]),
      tipSuggestion2Pct:
          _extractLocationString(effective, [
            'tip_suggestion_2_pct',
            'tipSuggestion2Pct',
          ]).isEmpty
          ? '20'
          : _extractLocationString(effective, [
              'tip_suggestion_2_pct',
              'tipSuggestion2Pct',
            ]),
      tipSuggestion3Pct:
          _extractLocationString(effective, [
            'tip_suggestion_3_pct',
            'tipSuggestion3Pct',
          ]).isEmpty
          ? '25'
          : _extractLocationString(effective, [
              'tip_suggestion_3_pct',
              'tipSuggestion3Pct',
            ]),
      tipSuggestionBase:
          _extractLocationString(effective, [
                'tip_suggestion_base',
                'tipSuggestionBase',
              ]).toLowerCase() ==
              'total'
          ? 'total'
          : 'subtotal',
      receiptCardSignatureMessage: _extractLocationString(effective, [
        'receipt_card_signature_message',
        'receiptCardSignatureMessage',
      ]),
      receiptMiscMessage: _extractLocationString(effective, [
        'receipt_misc_message',
        'receiptMiscMessage',
      ]),
      receiptReplyToEmail: _extractLocationString(effective, [
        'receipt_reply_to_email',
        'receiptReplyToEmail',
      ]),
    );
  }

  Future<Map<String, String>?> _openLocationForm({
    Map<String, dynamic>? initialRow,
  }) async {
    final isEditing = initialRow != null;
    final seed = isEditing
        ? await _buildLocationEditorSeedForEdit(initialRow)
        : await _buildLocationEditorSeedForCreate();
    if (!mounted || seed == null) return null;

    return _showLocationEditorDialog(seed: seed, isEditing: isEditing);
  }

  Future<Map<String, String>?> _openOrganizationForm({
    Map<String, dynamic>? initialRow,
  }) async {
    final isEditing = initialRow != null;
    final orgNumberController = TextEditingController(
      text: initialRow?['organization_number']?.toString() ?? '',
    );
    final nameController = TextEditingController(
      text: initialRow?['name']?.toString() ?? '',
    );
    final licenseKeyController = TextEditingController(
      text: initialRow?['license_key']?.toString() ?? '',
    );

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            initialRow == null ? 'Add Organization' : 'Edit Organization',
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: orgNumberController,
                    enabled: !isEditing,
                    readOnly: isEditing,
                    decoration: const InputDecoration(
                      labelText: 'Organization Number',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: licenseKeyController,
                    enabled: !isEditing,
                    readOnly: isEditing,
                    decoration: const InputDecoration(labelText: 'License Key'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(dialogContext, {
                  'organizationNumber': orgNumberController.text.trim(),
                  'name': nameController.text.trim(),
                  'licenseKey': licenseKeyController.text.trim(),
                });
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    orgNumberController.dispose();
    nameController.dispose();
    licenseKeyController.dispose();
    return result;
  }

  Future<void> _addRow() async {
    final messenger = ScaffoldMessenger.maybeOf(context);

    if (widget.tableName == 'organizations') {
      final formValues = await _openOrganizationForm();
      if (formValues == null) return;

      try {
        await _settingsDataService.insertOrganizationForm(
          organizationNumber: formValues['organizationNumber'] ?? '',
          name: formValues['name'] ?? '',
          licenseKey: formValues['licenseKey'] ?? '',
        );
        if (!mounted) return;
        _refresh();
      } catch (error) {
        _showErrorSnackBarWithMessenger(
          messenger,
          'Add Organization failed: ${_userFacingError(error)}',
        );
      }
      return;
    }

    if (widget.tableName == 'locations') {
      final formValues = await _openLocationForm();
      if (formValues == null) return;

      try {
        await _settingsDataService.insertLocationForm(
          organizationId: formValues['organizationId'] ?? '',
          organizationNumber: formValues['organizationNumber'] ?? '',
          name: formValues['name'] ?? '',
          address: formValues['address'] ?? '',
          address2: formValues['address2'] ?? '',
          city: formValues['city'] ?? '',
          state: formValues['state'] ?? '',
          zip: formValues['zip'] ?? '',
          phone: formValues['phone'] ?? '',
          terminalLicenses: int.tryParse(formValues['terminalLicenses'] ?? ''),
          terminalsActive: int.tryParse(formValues['terminalsActive'] ?? ''),
          allowTipAdjustments:
              (formValues['allowTipAdjustments'] ?? '').toLowerCase() == 'true',
          printTipSuggestions:
              (formValues['printTipSuggestions'] ?? '').toLowerCase() == 'true',
          tipSuggestion1Pct: formValues['tipSuggestion1Pct'] ?? '18',
          tipSuggestion2Pct: formValues['tipSuggestion2Pct'] ?? '20',
          tipSuggestion3Pct: formValues['tipSuggestion3Pct'] ?? '25',
          tipSuggestionBase: formValues['tipSuggestionBase'] ?? 'subtotal',
          receiptCardSignatureMessage:
              formValues['receiptCardSignatureMessage'] ?? '',
          receiptMiscMessage: formValues['receiptMiscMessage'] ?? '',
          receiptReplyToEmail: formValues['receiptReplyToEmail'] ?? '',
        );
        if (!mounted) return;
        _showInfoSnackBarWithMessenger(messenger, 'Location saved.');
        _refresh();
      } catch (error) {
        _showErrorSnackBarWithMessenger(
          messenger,
          'Add Location failed: ${_userFacingError(error)}',
        );
      }
      return;
    }

    if (widget.tableName == 'staff') {
      _showInfoSnackBarWithMessenger(
        messenger,
        'Use Staff Management.',
      );
      return;
    }

    if (widget.tableName == 'terminals') {
      final formValues = await _openTerminalForm();
      if (formValues == null) return;

      try {
        await _settingsDataService.insertTerminalForm(
          locationId: formValues['locationId']?.toString() ?? '',
          terminalNumber: formValues['terminalNumber']?.toString() ?? '',
          name: formValues['name']?.toString() ?? '',
          code: formValues['code']?.toString() ?? '',
          cardReaderType: formValues['cardReaderType']?.toString() ?? '',
          cardReaderHppAuthToken:
              formValues['cardReaderHppAuthToken']?.toString() ?? '',
          isActive: formValues['isActive'] as bool? ?? true,
          receiptPrinterName:
              formValues['receiptPrinterName']?.toString() ?? '',
          autoCloseBatchEnabled:
              formValues['autoCloseBatchEnabled'] as bool?,
          autoCloseBatchTime: formValues['autoCloseBatchTime']?.toString(),
        );
        if (!mounted) return;
        _showInfoSnackBarWithMessenger(messenger, 'Terminal saved.');
        _refresh();
      } catch (error) {
        _showErrorSnackBarWithMessenger(
          messenger,
          'Add Terminal failed: ${_userFacingError(error)}',
        );
      }
      return;
    }

    final newRow = await _openRowEditor();
    if (newRow == null) return;

    try {
      await _settingsDataService.insertRow(
        tableName: widget.tableName,
        row: newRow,
      );
      if (!mounted) return;
      _refresh();
    } catch (error) {
      _showErrorSnackBarWithMessenger(
        messenger,
        'Insert failed: ${_userFacingError(error)}',
      );
    }
  }

  Future<void> _editRow(Map<String, dynamic> row) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final id = row['id'];

    if (id == null) {
      _showErrorSnackBar('This row has no id field to update.');
      return;
    }

    if (widget.tableName == 'organizations') {
      final formValues = await _openOrganizationForm(initialRow: row);
      if (formValues == null) return;

      try {
        await _settingsDataService.updateOrganizationForm(
          id: id,
          organizationNumber: formValues['organizationNumber'] ?? '',
          name: formValues['name'] ?? '',
          licenseKey: formValues['licenseKey'] ?? '',
        );
        if (!mounted) return;
        _refresh();
      } catch (error) {
        _showErrorSnackBarWithMessenger(
          messenger,
          'Update failed: ${_userFacingError(error)}',
        );
      }
      return;
    }

    if (widget.tableName == 'locations') {
      final formValues = await _openLocationForm(initialRow: row);
      if (formValues == null) return;

      try {
        final expectedAllowTipAdjustments =
            (formValues['allowTipAdjustments'] ?? '').toLowerCase() == 'true';
        await _settingsDataService.updateLocationForm(
          id: id,
          organizationId: formValues['organizationId'] ?? '',
          organizationNumber: formValues['organizationNumber'] ?? '',
          name: formValues['name'] ?? '',
          address: formValues['address'] ?? '',
          address2: formValues['address2'] ?? '',
          city: formValues['city'] ?? '',
          state: formValues['state'] ?? '',
          zip: formValues['zip'] ?? '',
          phone: formValues['phone'] ?? '',
          terminalLicenses: int.tryParse(formValues['terminalLicenses'] ?? ''),
          terminalsActive: int.tryParse(formValues['terminalsActive'] ?? ''),
          allowTipAdjustments:
              (formValues['allowTipAdjustments'] ?? '').toLowerCase() == 'true',
          printTipSuggestions:
              (formValues['printTipSuggestions'] ?? '').toLowerCase() == 'true',
          tipSuggestion1Pct: formValues['tipSuggestion1Pct'] ?? '18',
          tipSuggestion2Pct: formValues['tipSuggestion2Pct'] ?? '20',
          tipSuggestion3Pct: formValues['tipSuggestion3Pct'] ?? '25',
          tipSuggestionBase: formValues['tipSuggestionBase'] ?? 'subtotal',
          receiptCardSignatureMessage:
              formValues['receiptCardSignatureMessage'] ?? '',
          receiptMiscMessage: formValues['receiptMiscMessage'] ?? '',
          receiptReplyToEmail: formValues['receiptReplyToEmail'] ?? '',
        );
        if (!mounted) return;

        _locationTipAdjustmentsCache[id.toString()] =
            expectedAllowTipAdjustments;
        _showInfoSnackBarWithMessenger(
          messenger,
          'Location updated. Allow Tip Adjustments: '
          '${expectedAllowTipAdjustments ? 'ON' : 'OFF'}.',
        );
        _refresh();
      } catch (error) {
        _showErrorSnackBarWithMessenger(
          messenger,
          'Update failed: ${_userFacingError(error)}',
        );
      }
      return;
    }

    if (widget.tableName == 'staff') {
      _showInfoSnackBarWithMessenger(
        messenger,
        'Use Staff Management.',
      );
      return;
    }

    if (widget.tableName == 'terminals') {
      final formValues = await _openTerminalForm(initialRow: row);
      if (formValues == null) return;

      try {
        await _settingsDataService.updateTerminalForm(
          id: id,
          locationId: formValues['locationId']?.toString() ?? '',
          terminalNumber: formValues['terminalNumber']?.toString() ?? '',
          name: formValues['name']?.toString() ?? '',
          code: formValues['code']?.toString() ?? '',
          cardReaderType: formValues['cardReaderType']?.toString() ?? '',
          cardReaderHppAuthToken:
              formValues['cardReaderHppAuthToken']?.toString() ?? '',
          isActive: formValues['isActive'] as bool? ?? true,
          receiptPrinterName:
              formValues['receiptPrinterName']?.toString() ?? '',
          autoCloseBatchEnabled:
              formValues['autoCloseBatchEnabled'] as bool?,
          autoCloseBatchTime: formValues['autoCloseBatchTime']?.toString(),
        );
        if (!mounted) return;
        _showInfoSnackBarWithMessenger(messenger, 'Terminal updated.');
        _refresh();
      } catch (error) {
        _showErrorSnackBarWithMessenger(
          messenger,
          'Update failed: ${_userFacingError(error)}',
        );
      }
      return;
    }

    final updated = await _openRowEditor(initialRow: row);
    if (updated == null) return;

    updated.remove('id');
    if (updated.isEmpty) {
      _showErrorSnackBar('No editable fields provided.');
      return;
    }

    try {
      await _settingsDataService.updateRow(
        tableName: widget.tableName,
        id: id,
        row: updated,
      );
      if (!mounted) return;
      _refresh();
    } catch (error) {
      _showErrorSnackBarWithMessenger(
        messenger,
        'Update failed: ${_userFacingError(error)}',
      );
    }
  }

  Future<void> _deleteRow(Map<String, dynamic> row) async {
    if (widget.tableName == 'organizations') {
      _showErrorSnackBar('Organizations cannot be deleted.');
      return;
    }

    final id = row['id'];
    if (id == null) {
      _showErrorSnackBar('This row has no id field to delete.');
      return;
    }

    if (widget.tableName == 'terminals') {
      _showErrorSnackBar(
        'Terminals cannot be deleted. Use Edit to deactivate them instead.',
      );
      return;
    }

    if (widget.tableName == 'locations') {
      _showErrorSnackBar('Locations cannot be deleted from this screen.');
      return;
    }

    if (!mounted) return;

    await _confirmAndDeleteRow(id: id, row: row);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(
              widget.tableName == 'organizations'
                  ? 'Organization Setup'
                  : widget.title,
            ),
          ),
          if (widget.tableName == 'terminals')
            TextButton(onPressed: _addRow, child: const Text('Add Terminal')),
          if (widget.tableName != 'organizations' &&
              widget.tableName != 'locations' &&
              widget.tableName != 'staff' &&
              widget.tableName != 'terminals')
            IconButton(
              tooltip: 'Add Row',
              onPressed: _addRow,
              icon: const Icon(Icons.add),
            ),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 360,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _rowsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              final errorText =
                  'Failed to load ${widget.tableName}: ${snapshot.error}';
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(errorText, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: errorText));
                        if (!context.mounted) return;
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          const SnackBar(content: Text('Error copied.')),
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
              return Center(
                child: Text('No rows found in ${widget.tableName}.'),
              );
            }

            if (widget.tableName == 'organizations') {
              return _buildOrganizationsTable(rows, includeActions: true);
            }

            if (widget.tableName == 'locations') {
              return _buildLocationsTable(rows);
            }

            if (widget.tableName == 'staff') {
              return const Center(
                child: Text('Use Staff Management.'),
              );
            }

            if (widget.tableName == 'terminals') {
              return _buildTerminalsTable(rows);
            }

            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (context, index) => const Divider(height: 12),
              itemBuilder: (context, index) {
                final row = rows[index];
                final hasRowId = row['id'] != null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(_formatRow(row)),
                    const SizedBox(height: 6),
                    if (hasRowId)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => _editRow(row),
                            child: const Text('Edit'),
                          ),
                          const SizedBox(width: 6),
                          TextButton(
                            onPressed: () => _deleteRow(row),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
