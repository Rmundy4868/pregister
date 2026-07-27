import 'dart:convert';
// ignore_for_file: deprecated_member_use

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../debug/integrity_checks_screen.dart';
import '../services/license_service.dart';
import '../services/settings_data_service.dart';
import '../services/transaction_flow_parameters.dart';
import '../terminal/terminal_activation_screen.dart';
import '../utils/text_file_save.dart';

class SettingsWindow extends StatelessWidget {
  const SettingsWindow({
    required this.onOpenTable,
    this.onShowPaymentDiagnostics,
    super.key,
  });

  final void Function(String tableName, String title) onOpenTable;
  final VoidCallback? onShowPaymentDiagnostics;

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
              onPressed: () => onOpenTable('terminals', 'Terminals'),
              child: const Text('Update Terminals'),
            ),
            const SizedBox(height: 4),
            ElevatedButton(
              style: compactButtonStyle,
              onPressed: () => onOpenTable('staff', 'Staff'),
              child: const Text('Update Staff'),
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
            if (onShowPaymentDiagnostics != null) ...[
              const SizedBox(height: 4),
              ElevatedButton(
                style: compactButtonStyle,
                onPressed: onShowPaymentDiagnostics,
                child: const Text('Payment Diagnostics'),
              ),
            ],
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
  static const String _voidsRefundsIntegrityCheckKey =
      'operating.transaction.voids_refunds_integrity_check';
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

  bool _staffTrackingEnabled = false;
  bool _customerTrackingEnabled = false;
  bool _integrityChecksEnabled = false;
  bool _voidsRefundsIntegrityCheckEnabled = false;
  bool _enableProcessorSurcharge = false;
  String _receiptReplyToEmail = '';

  bool _loading = true;
  bool _saving = false;

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

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final txFlowParams = await TransactionFlowParameters.load();
    for (final type in _receiptTypes.keys) {
      _previewEnabled[type] =
          prefs.getBool('operating.receipts.$type.preview_enabled') ?? true;
      _copyCount[type] =
          (prefs.getInt('operating.receipts.$type.copy_count') ?? 2).clamp(
            1,
            10,
          );
    }
    _staffTrackingEnabled = txFlowParams.staffTrackingEnabled;
    _customerTrackingEnabled = txFlowParams.customerTrackingEnabled;
    _integrityChecksEnabled = txFlowParams.integrityChecksEnabled;
    _voidsRefundsIntegrityCheckEnabled =
        prefs.getBool(_voidsRefundsIntegrityCheckKey) ?? false;
    _enableProcessorSurcharge = txFlowParams.enableProcessorSurcharge;
    _receiptReplyToEmail = txFlowParams.receiptReplyToEmail;
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
    final prefs = await SharedPreferences.getInstance();
    for (final type in _receiptTypes.keys) {
      await prefs.setBool(
        'operating.receipts.$type.preview_enabled',
        _previewEnabled[type] ?? true,
      );
      await prefs.setInt(
        'operating.receipts.$type.copy_count',
        (_copyCount[type] ?? 2).clamp(1, 10),
      );
    }

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
      receiptReplyToEmail: _receiptReplyToEmail,
    ).save();
    await prefs.setBool(
      _voidsRefundsIntegrityCheckKey,
      _voidsRefundsIntegrityCheckEnabled,
    );

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
                  style: const TextStyle(fontSize: 13),
                  items: List.generate(
                    10,
                    (index) => DropdownMenuItem(
                      value: index + 1,
                      child: Text('${index + 1}'),
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
              'Copy 1 = Merchant, Copy 2 = Customer, Copy 3+ = Additional copies.',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionFlowCard() {
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
                'Voids / Refunds Integrity Check',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                'Run pass/fail verification after void and refund ledger changes.',
                style: TextStyle(fontSize: 11),
              ),
              value: _voidsRefundsIntegrityCheckEnabled,
              onChanged: (value) {
                setState(() {
                  _voidsRefundsIntegrityCheckEnabled = value;
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
                        style: const TextStyle(fontSize: 12),
                        items: const [
                          DropdownMenuItem(
                            value: CustomerFieldMode.required,
                            child: Text('Required'),
                          ),
                          DropdownMenuItem(
                            value: CustomerFieldMode.optional,
                            child: Text('Optional'),
                          ),
                          DropdownMenuItem(
                            value: CustomerFieldMode.hidden,
                            child: Text('Hide'),
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

class _TableListWindowState extends State<TableListWindow> {
  final SettingsDataService _settingsDataService = SettingsDataService();
  final ScrollController _organizationVerticalScrollController =
      ScrollController();
  final ScrollController _organizationHorizontalScrollController =
      ScrollController();
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
    if (normalized == 'true') return true;
    if (normalized == 'false') return false;
    return defaultValue;
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

    var rows = await _settingsDataService.fetchTableRows(
      tableName: widget.tableName,
    );

    if (widget.tableName != 'locations') {
      return rows;
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
              },
            )
            .toList();
      }
    }

    final enrichedRows = <Map<String, dynamic>>[];
    for (final row in rows) {
      final mutable = Map<String, dynamic>.from(row);
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

  List<String> _organizationColumns(
    List<Map<String, dynamic>> rows, {
    bool nameFirst = false,
  }) {
    final columns = <String>{};
    for (final row in rows) {
      columns.addAll(row.keys);
    }

    final sorted = columns.toList()..sort();
    final preferredOrder = nameFirst
        ? ['name', 'organization_number', 'license_key', 'id']
        : ['id', 'organization_number', 'name', 'license_key'];

    sorted.sort((a, b) {
      final aIndex = preferredOrder.indexOf(a);
      final bIndex = preferredOrder.indexOf(b);

      if (aIndex >= 0 && bIndex >= 0) {
        return aIndex.compareTo(bIndex);
      }
      if (aIndex >= 0) return -1;
      if (bIndex >= 0) return 1;
      return a.compareTo(b);
    });

    return sorted;
  }

  Widget _buildOrganizationsTable(
    List<Map<String, dynamic>> rows, {
    required bool includeActions,
  }) {
    final columns = _organizationColumns(rows, nameFirst: true);
    final sortedRows = List<Map<String, dynamic>>.from(rows);

    if (_organizationSortColumnIndex == null) {
      final defaultIndex = columns.indexOf('organization_number');
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
                    label: Text(entry.value),
                    onSort: (columnIndex, ascending) {
                      setState(() {
                        _organizationSortColumnIndex = columnIndex;
                        _organizationSortAscending = ascending;
                      });
                    },
                  ),
                ),
                if (includeActions) const DataColumn(label: Text('Actions')),
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
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(
                                  onPressed: () => _editRow(row),
                                  child: const Text('Edit'),
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

  Widget _buildLocationsTable(List<Map<String, dynamic>> rows) {
    const columns = [
      'name',
      'address',
      'address_2',
      'city',
      'state',
      'zip',
      'phone',
      'terminal_licenses',
      'terminals_active',
      'organization_name',
      'organization_number',
    ];

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
                DataColumn(label: Text('location name')),
                DataColumn(label: Text('address')),
                DataColumn(label: Text('address_2')),
                DataColumn(label: Text('city')),
                DataColumn(label: Text('state')),
                DataColumn(label: Text('zip')),
                DataColumn(label: Text('phone')),
                DataColumn(label: Text('terminal_licenses')),
                DataColumn(label: Text('terminals_active')),
                DataColumn(label: Text('organization_name')),
                DataColumn(label: Text('organization_number')),
                DataColumn(label: Text('Actions')),
              ],
              rows: rows
                  .map(
                    (row) => DataRow(
                      cells: [
                        ...columns.map(
                          (column) =>
                              DataCell(SelectableText('${row[column] ?? ''}')),
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

  Widget _buildTerminalsTable(List<Map<String, dynamic>> rows) {
    const columns = [
      'terminal_number',
      'terminal_name',
      'location_name',
      'registered_device_label',
      'is_active',
      'last_seen_at',
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
              columns: const [
                DataColumn(label: Text('terminal_number')),
                DataColumn(label: Text('terminal_name')),
                DataColumn(label: Text('location_name')),
                DataColumn(label: Text('registered_device')),
                DataColumn(label: Text('is_active')),
                DataColumn(label: Text('last_seen_at')),
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
            onPressed: () {
              _downloadTextFileFromSettings(
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

  void _downloadTextFileFromSettings(String content, String filename) {
    saveTextFile(
      content: content,
      fileName: filename,
      mimeType: 'text/plain',
      saveToDownloads: true,
    );
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

    var isActive = _asBool(initialRow?['is_active'], defaultValue: true);

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

                Navigator.pop(dialogContext, {
                  'locationId': locationId,
                  'terminalNumber': terminalNumber,
                  'name': terminalName,
                  'code': codeController.text.trim(),
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
    return result;
  }

  Future<Map<String, dynamic>?> _openTerminalForm({
    Map<String, dynamic>? initialRow,
  }) async {
    final activeContext = LicenseService().activeContext;

    final organizationId =
        initialRow?['organization_id']?.toString() ??
        activeContext?.organizationId ??
        '';
    final locationId =
        initialRow?['location_id']?.toString() ??
        activeContext?.locationId ??
        '';

    var organizationName = '';
    if (organizationId.trim().isNotEmpty) {
      final organizationDetails = await _settingsDataService
          .getOrganizationDetailsById(organizationId);
      if (!mounted) return null;
      organizationName = organizationDetails['name'] ?? '';
    }

    var locationName = initialRow?['location_name']?.toString() ?? '';
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
      initialRow: initialRow,
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

  Future<Map<String, String>?> _showLocationFormDialog({
    required Map<String, dynamic>? initialRow,
    required String organizationId,
    required String organizationName,
    required String organizationNumber,
    required String name,
    required String address,
    required String address2,
    required String city,
    required String state,
    required String zip,
    required String phone,
    required String terminalLicenses,
    required String terminalsActive,
  }) async {
    final orgIdController = TextEditingController(text: organizationId);
    final orgNameController = TextEditingController(text: organizationName);
    final orgNumberController = TextEditingController(text: organizationNumber);
    final nameController = TextEditingController(text: name);
    final addressController = TextEditingController(text: address);
    final address2Controller = TextEditingController(text: address2);
    final cityController = TextEditingController(text: city);
    final stateController = TextEditingController(text: state);
    final zipController = TextEditingController(text: zip);
    final phoneController = TextEditingController(text: phone);
    final terminalLicensesController = TextEditingController(
      text: terminalLicenses,
    );
    final terminalsActiveController = TextEditingController(
      text: terminalsActive,
    );

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(initialRow == null ? 'Add Location' : 'Edit Location'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (initialRow == null &&
                    orgNumberController.text.trim().isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      'Organization context is missing. Save will use license activation fallback to create/select the location.',
                      style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.error,
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
                  autofocus: initialRow == null,
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
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Terminal Licenses',
                    hintText: 'Maximum active terminals',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: terminalsActiveController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Terminals Active',
                    hintText: 'Current active terminals',
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
              if (terminalLicenses > 0 && terminalsActive > terminalLicenses) {
                _showErrorSnackBar(
                  'Terminals Active cannot exceed Terminal Licenses.',
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
              });
            },
            child: const Text('Save'),
          ),
        ],
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
    return result;
  }

  Future<Map<String, String>?> _openLocationForm({
    Map<String, dynamic>? initialRow,
  }) async {
    var organizationId = '';
    var organizationName = '';
    var organizationNumber = '';
    var name = '';
    var address = '';
    var address2 = '';
    var city = '';
    var state = '';
    var zip = '';
    var phone = '';
    var terminalLicenses = '';
    var terminalsActive = '';

    if (initialRow != null) {
      final existingOrganizationId =
          initialRow['organization_id']?.toString() ?? '';
      if (existingOrganizationId.isNotEmpty) {
        final orgDetails = await _settingsDataService
            .getOrganizationDetailsById(existingOrganizationId);
        if (!mounted) return null;
        organizationId = orgDetails['id'] ?? existingOrganizationId;
        organizationName =
            orgDetails['name'] ??
            initialRow['organization_name']?.toString() ??
            '';
        organizationNumber =
            orgDetails['organization_number'] ??
            initialRow['organization_number']?.toString() ??
            '';
      } else {
        organizationId = initialRow['organization_id']?.toString() ?? '';
        organizationName = initialRow['organization_name']?.toString() ?? '';
        organizationNumber =
            initialRow['organization_number']?.toString() ?? '';
      }

      name = initialRow['name']?.toString() ?? '';
      address = initialRow['address']?.toString() ?? '';
      address2 = initialRow['address_2']?.toString() ?? '';
      city = initialRow['city']?.toString() ?? '';
      state = initialRow['state']?.toString() ?? '';
      zip = initialRow['zip']?.toString() ?? '';
      phone = _formatPhoneNumber(
        initialRow['phone']?.toString() ??
            initialRow['phone_number']?.toString() ??
            '',
      );
      terminalLicenses = initialRow['terminal_licenses']?.toString() ?? '';
      terminalsActive = initialRow['terminals_active']?.toString() ?? '';
    } else {
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

      terminalLicenses = '1';
      terminalsActive = '0';
    }

    return _showLocationFormDialog(
      initialRow: initialRow,
      organizationId: organizationId,
      organizationName: organizationName,
      organizationNumber: organizationNumber,
      name: name,
      address: address,
      address2: address2,
      city: city,
      state: state,
      zip: zip,
      phone: phone,
      terminalLicenses: terminalLicenses,
      terminalsActive: terminalsActive,
    );
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
    final autoCloseTimeController = TextEditingController(
      text: _normalizeTimeForInput(initialRow?['auto_close_batch_time']),
    );
    var autoCloseEnabled = _asBool(
      initialRow?['auto_close_batch_enabled'],
      defaultValue: false,
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
                final rawTime = autoCloseTimeController.text.trim();
                if (autoCloseEnabled) {
                  final valid = RegExp(
                    r'^(\d{1,2}):(\d{2})(?::\d{2})?$',
                  ).hasMatch(rawTime);
                  if (!valid) {
                    _showErrorSnackBar(
                      'Auto-close time must be HH:mm or HH:mm:ss in 24-hour format.',
                    );
                    return;
                  }
                }

                Navigator.pop(dialogContext, {
                  'organizationNumber': orgNumberController.text.trim(),
                  'name': nameController.text.trim(),
                  'licenseKey': licenseKeyController.text.trim(),
                  'autoCloseBatchEnabled': autoCloseEnabled ? 'true' : 'false',
                  'autoCloseBatchTime': rawTime,
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
    autoCloseTimeController.dispose();
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
          autoCloseBatchEnabled:
              (formValues['autoCloseBatchEnabled'] ?? '').toLowerCase() ==
              'true',
          autoCloseBatchTime: formValues['autoCloseBatchTime'] ?? '',
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
      final formValues = await _openStaffForm();
      if (formValues == null) return;

      try {
        await _settingsDataService.insertStaffForm(
          organizationId: formValues['organizationId']?.toString() ?? '',
          locationId: formValues['locationId']?.toString() ?? '',
          firstName: formValues['firstName']?.toString() ?? '',
          lastName: formValues['lastName']?.toString() ?? '',
          email: formValues['email']?.toString() ?? '',
          phone: formValues['phone']?.toString() ?? '',
          pin: formValues['pin']?.toString() ?? '',
          role: formValues['role']?.toString() ?? 'cashier',
          isActive: formValues['isActive'] as bool? ?? true,
        );
        if (!mounted) return;
        _showInfoSnackBarWithMessenger(messenger, 'Staff saved.');
        _refresh();
      } catch (error) {
        _showErrorSnackBarWithMessenger(
          messenger,
          'Add Staff failed: ${_userFacingError(error)}',
        );
      }
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
          isActive: formValues['isActive'] as bool? ?? true,
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
          autoCloseBatchEnabled:
              (formValues['autoCloseBatchEnabled'] ?? '').toLowerCase() ==
              'true',
          autoCloseBatchTime: formValues['autoCloseBatchTime'] ?? '',
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

    if (widget.tableName == 'staff') {
      final formValues = await _openStaffForm(initialRow: row);
      if (formValues == null) return;

      try {
        await _settingsDataService.updateStaffForm(
          id: id,
          organizationId: formValues['organizationId']?.toString() ?? '',
          locationId: formValues['locationId']?.toString() ?? '',
          firstName: formValues['firstName']?.toString() ?? '',
          lastName: formValues['lastName']?.toString() ?? '',
          email: formValues['email']?.toString() ?? '',
          phone: formValues['phone']?.toString() ?? '',
          pin: formValues['pin']?.toString() ?? '',
          role: formValues['role']?.toString() ?? 'cashier',
          isActive: formValues['isActive'] as bool? ?? true,
        );
        if (!mounted) return;
        _showInfoSnackBarWithMessenger(messenger, 'Staff updated.');
        _refresh();
      } catch (error) {
        _showErrorSnackBarWithMessenger(
          messenger,
          'Update failed: ${_userFacingError(error)}',
        );
      }
      return;
    }

    if (widget.tableName == 'terminals') {
      final formValues = await _openTerminalForm(initialRow: row);
      if (formValues == null) return;

      try {
        final isActive = formValues['isActive'] as bool? ?? true;
        final activeTerminalId =
            LicenseService().activeContext?.terminalId.trim() ?? '';
        final isCurrentTerminalDeactivated =
            !isActive && activeTerminalId == id.toString().trim();

        await _settingsDataService.updateTerminalForm(
          id: id,
          locationId: formValues['locationId']?.toString() ?? '',
          terminalNumber: formValues['terminalNumber']?.toString() ?? '',
          name: formValues['name']?.toString() ?? '',
          code: formValues['code']?.toString() ?? '',
          isActive: isActive,
        );
        if (!mounted) return;
        if (isCurrentTerminalDeactivated) {
          await LicenseService().clearActivationState();
          if (!mounted) return;
          Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
            MaterialPageRoute<void>(
              builder: (_) => const TerminalActivationScreen(),
            ),
            (route) => false,
          );
          return;
        }
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
    final messenger = ScaffoldMessenger.maybeOf(context);

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
      try {
        final hasDependencies = await _settingsDataService
            .locationHasDependencies(id.toString());
        if (!mounted) return;

        if (hasDependencies) {
          _showErrorSnackBarWithMessenger(
            messenger,
            'Cannot delete location with associated terminals or staff.',
          );
          return;
        }
      } catch (error) {
        _showErrorSnackBarWithMessenger(
          messenger,
          'Unable to validate location delete: ${_userFacingError(error)}',
        );
        return;
      }
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
          if (widget.tableName == 'locations')
            TextButton(onPressed: _addRow, child: const Text('Add Location')),
          if (widget.tableName == 'staff')
            TextButton(onPressed: _addRow, child: const Text('Add Staff')),
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
              return _buildStaffTable(rows);
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
