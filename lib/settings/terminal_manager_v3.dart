import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

import '../services/license_service.dart';
import '../services/settings_data_service.dart';
import '../terminal_config.dart';
import '../terminal/terminal_activation_screen.dart';
import '../utils/text_file_save.dart';

class TerminalManagerV3Dialog extends StatefulWidget {
  const TerminalManagerV3Dialog({super.key});

  @override
  State<TerminalManagerV3Dialog> createState() =>
      _TerminalManagerV3DialogState();
}

class _TerminalManagerV3DialogState extends State<TerminalManagerV3Dialog> {
  // Define the `_selectedCardReader` field in the state class
  String _selectedCardReader = 'none';
  String _terminalStatusFilter = 'active';
  List<String> _installedPrinterNames = <String>[];

  // Editor panel — update only (terminals are created through activation)
  Widget _buildEditorPanel(BuildContext context) {
    final isEditing = _selectedTerminal != null;
    final selectedPrinter = _receiptPrinterController.text.trim();
    final selectedInstalledPrinter =
        _installedPrinterNames.contains(selectedPrinter)
        ? selectedPrinter
        : null;
    if (!isEditing) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Select a terminal from the list to edit its settings.\n\nNew terminals are added automatically during the activation process.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Edit Terminal',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _terminalNumberController,
          decoration: const InputDecoration(
            labelText: 'Terminal Number (4 digits)',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          keyboardType: TextInputType.number,
          maxLength: 4,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _terminalNameController,
          decoration: const InputDecoration(
            labelText: 'Terminal Name',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _hppTokenController,
          decoration: const InputDecoration(
            labelText: 'HPP Auth Token',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _spinTpnController,
          decoration: const InputDecoration(
            labelText: 'SPIn TPN',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _spinAuthKeyController,
          decoration: const InputDecoration(
            labelText: 'SPIn Auth Key',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: selectedInstalledPrinter,
                decoration: const InputDecoration(
                  labelText: 'Installed Receipt Printers',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                hint: const Text('Select installed printer'),
                isExpanded: true,
                items: _installedPrinterNames
                    .map(
                      (name) => DropdownMenuItem<String>(
                        value: name,
                        child: Text(name, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _installedPrinterNames.isEmpty
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() {
                          _receiptPrinterController.text = value;
                        });
                      },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Refresh printers',
              onPressed: _loadInstalledPrinters,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _receiptPrinterController,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Default Receipt Printer Name',
            hintText: 'Manual override if not listed',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Auto-close batch enabled'),
          value: _autoCloseEnabled,
          subtitle: _autoCloseResolved
              ? null
              : const Text(
                  'Auto-close is unresolved for this terminal until detail read succeeds.',
                ),
          onChanged: _autoCloseResolved
              ? (value) {
                  setState(() {
                    _autoCloseEnabled = value;
                    if (!value) _autoCloseTimeController.clear();
                  });
                }
              : null,
        ),
        TextField(
          controller: _autoCloseTimeController,
          enabled: _autoCloseResolved && _autoCloseEnabled,
          decoration: const InputDecoration(
            labelText: 'Auto-close time (24h)',
            hintText: 'HH:mm or HH:mm:ss',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _selectedCardReader,
          items: const [
            DropdownMenuItem(value: 'none', child: Text('None')),
            DropdownMenuItem(value: 'dejavoo_p12', child: Text('DeJavoo P12')),
          ],
          onChanged: (value) {
            setState(() {
              _selectedCardReader =
                  value ?? 'none'; // Default to 'none' if value is null
            });
          },
          decoration: const InputDecoration(
            labelText: 'Card Reader',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                icon: Icon(isEditing ? Icons.save : Icons.add),
                label: Text('Save Terminal'),
                onPressed: _isSaving ? null : _onSaveTerminal,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            if (isEditing) ...[
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _isSaving ? null : _onDeactivateTerminal,
                icon: const Icon(Icons.warning_amber_rounded),
                label: const Text('Deactivate'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: _isSaving ? null : _onCancelEdit,
                child: const Text('Cancel'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  void _onCancelEdit() {
    setState(() {
      _selectedTerminal = null;
      _terminalNumberController.clear();
      _terminalNameController.clear();
      _hppTokenController.clear();
      _spinTpnController.clear();
      _spinAuthKeyController.clear();
      _receiptPrinterController.clear();
      _autoCloseTimeController.clear();
      _autoCloseEnabled = false;
      _autoCloseResolved = true;
    });
  }

  Future<void> _onSaveTerminal() async {
    final terminalNumber = _terminalNumberController.text.trim();
    final terminalName = _terminalNameController.text.trim();
    final hppToken = _hppTokenController.text.trim();
    final spinTpn = _spinTpnController.text.trim();
    final spinAuthKey = _spinAuthKeyController.text.trim();
    final receiptPrinterName = _receiptPrinterController.text.trim();
    final autoCloseTime = _autoCloseTimeController.text.trim();
    if (terminalNumber.isEmpty || terminalNumber.length != 4) {
      _showMessage('Terminal number must be 4 digits.', isError: true);
      return;
    }
    if (terminalName.isEmpty) {
      _showMessage('Terminal name is required.', isError: true);
      return;
    }
    if (!_autoCloseResolved) {
      _showMessage(
        'Auto-close values are unresolved for this terminal. Select the terminal again and retry.',
        isError: true,
      );
      return;
    }
    if (_autoCloseEnabled) {
      final valid = RegExp(
        r'^(\d{1,2}):(\d{2})(?::\d{2})?$',
      ).hasMatch(autoCloseTime);
      if (!valid) {
        _showMessage(
          'Auto-close time must be HH:mm or HH:mm:ss in 24-hour format.',
          isError: true,
        );
        return;
      }
    }
    setState(() {
      _isSaving = true;
    });
    try {
      if (_selectedTerminal == null) {
        _showMessage('Select a terminal from the list to edit.', isError: true);
        setState(() {
          _isSaving = false;
        });
        return;
      }
      // Update existing
      await _dataService.updateTerminalForm(
        id: _pickTerminalId(_selectedTerminal!),
        locationId: _pickLocationId(_selectedTerminal!),
        terminalNumber: terminalNumber,
        name: terminalName,
        code: '',
        spinTpn: spinTpn,
        spinAuthKey: spinAuthKey,
        cardReaderType: _selectedCardReader,
        cardReaderHppAuthToken: hppToken,
        isActive: true,
        receiptPrinterName: receiptPrinterName,
        autoCloseBatchEnabled: _autoCloseEnabled,
        autoCloseBatchTime: autoCloseTime,
      );
      _showMessage('Terminal updated.');
      await _loadAll();
      setState(() {
        _isSaving = false;
        _selectedTerminal = null;
      });
    } catch (e) {
      setState(() {
        _isSaving = false;
      });
      _showMessage('Save failed: $e', isError: true);
    }
  }

  Future<void> _onDeactivateTerminal() async {
    final selected = _selectedTerminal;
    if (selected == null) {
      _showMessage(
        'Select a terminal from the list to deactivate.',
        isError: true,
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Deactivate Terminal'),
        content: const Text('This will deactivate the terminal. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final terminalNumber = _terminalNumberController.text.trim();
    final terminalName = _terminalNameController.text.trim();
    final hppToken = _hppTokenController.text.trim();
    final spinTpn = _spinTpnController.text.trim();
    final spinAuthKey = _spinAuthKeyController.text.trim();
    final receiptPrinterName = _receiptPrinterController.text.trim();
    final autoCloseTime = _autoCloseTimeController.text.trim();

    if (terminalNumber.isEmpty || terminalNumber.length != 4) {
      _showMessage('Terminal number must be 4 digits.', isError: true);
      return;
    }
    if (terminalName.isEmpty) {
      _showMessage('Terminal name is required.', isError: true);
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      await _dataService.updateTerminalForm(
        id: _pickTerminalId(selected),
        locationId: _pickLocationId(selected),
        terminalNumber: terminalNumber,
        name: terminalName,
        code: '',
        spinTpn: spinTpn,
        spinAuthKey: spinAuthKey,
        cardReaderType: _selectedCardReader,
        cardReaderHppAuthToken: hppToken,
        isActive: false,
        receiptPrinterName: receiptPrinterName,
        autoCloseBatchEnabled: _autoCloseEnabled,
        autoCloseBatchTime: autoCloseTime,
      );
      if (mounted) {
        await _offerDeactivationCleanup(
          context: context,
          terminalNumber: terminalNumber,
        );
      }
      await _licenseService.clearActivationState();
      if (!mounted) return;

      _showMessage(
        'Terminal deactivated. Session cleared. Reactivation required.',
      );

      setState(() {
        _isSaving = false;
        _selectedTerminal = null;
      });

      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => const TerminalActivationScreen(),
        ),
        (route) => false,
      );
    } catch (e) {
      setState(() {
        _isSaving = false;
      });
      _showMessage('Deactivate failed: $e', isError: true);
    }
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
              await _downloadTextFileFromTerminalManager(
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

  Future<void> _downloadTextFileFromTerminalManager(
    String content,
    String filename,
  ) async {
    await saveTextFile(content: content, fileName: filename);
  }

  final SettingsDataService _dataService = SettingsDataService();
  final LicenseService _licenseService = LicenseService();

  final TextEditingController _terminalNumberController =
      TextEditingController();
  final TextEditingController _terminalNameController = TextEditingController();
  final TextEditingController _hppTokenController = TextEditingController();
  final TextEditingController _spinTpnController = TextEditingController();
  final TextEditingController _spinAuthKeyController = TextEditingController();
  final TextEditingController _receiptPrinterController =
      TextEditingController();
  final TextEditingController _autoCloseTimeController =
      TextEditingController();

  List<Map<String, dynamic>> _terminals = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _locations = <Map<String, dynamic>>[];

  Map<String, dynamic>? _selectedTerminal;

  bool _isLoading = true;
  bool _isSaving = false;
  bool _autoCloseEnabled = false;
  bool _autoCloseResolved = true;
  String _statusMessage = '';
  bool _statusIsError = false;

  String _pickString(Map<String, dynamic> row, List<String> keys) {
    for (final key in keys) {
      final value = row[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  Future<
    ({
      String organizationId,
      String locationId,
      String locationName,
      bool hasActiveContext,
    })
  >
  _resolveScope() async {
    final active = _licenseService.activeContext;

    final organizationId = (active?.organizationId ?? '').trim();
    final locationId = (active?.locationId ?? '').trim();
    final locationName = (active?.locationName ?? '').trim();
    final hasActiveContext = active != null;

    return (
      organizationId: organizationId,
      locationId: locationId,
      locationName: locationName,
      hasActiveContext: hasActiveContext,
    );
  }

  Future<List<Map<String, dynamic>>> _loadScopedTerminals() async {
    final scope = await _resolveScope();
    final rows = await _dataService.fetchTableRows(
      tableName: 'terminals',
      limit: 500,
    );

    // fetchTableRows('terminals') is already scoped through service RPC/license context.
    // Only apply extra filtering when we have explicit active context identifiers.
    final shouldApplyExtraFilter =
        scope.hasActiveContext &&
        (scope.organizationId.isNotEmpty || scope.locationId.isNotEmpty);

    if (!shouldApplyExtraFilter) {
      return rows;
    }

    final scopedRows = rows.where((row) {
      final rowOrgId = (row['organization_id'] ?? '').toString().trim();
      final rowLocationId = _pickLocationId(row);

      final orgMatches =
          scope.organizationId.isEmpty || rowOrgId == scope.organizationId;

      final locationMatches =
          scope.locationId.isEmpty || rowLocationId == scope.locationId;

      return orgMatches && locationMatches;
    }).toList();

    return scopedRows.isEmpty ? rows : scopedRows;
  }

  Future<List<Map<String, dynamic>>> _hydrateTerminalRowsWithDetails(
    List<Map<String, dynamic>> terminals,
  ) async {
    if (terminals.isEmpty) return terminals;

    final merged = terminals
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);

    final futures = merged.map((row) async {
      final terminalId = _pickTerminalId(row);
      if (terminalId.isEmpty) return row;

      final details = await _dataService.getTerminalDetailsById(terminalId);
      if (details == null) return row;

      row['auto_close_batch_enabled'] =
          details['auto_close_batch_enabled'] ?? row['auto_close_batch_enabled'];
      row['autoCloseBatchEnabled'] =
          details['autoCloseBatchEnabled'] ?? row['autoCloseBatchEnabled'];
      row['auto_close_batch_time'] =
          details['auto_close_batch_time'] ?? row['auto_close_batch_time'];
      row['autoCloseBatchTime'] =
          details['autoCloseBatchTime'] ?? row['autoCloseBatchTime'];
      return row;
    }).toList(growable: false);

    return await Future.wait(futures);
  }

  List<Map<String, dynamic>> _buildScopedLocationsFromTerminals(
    List<Map<String, dynamic>> terminals,
  ) {
    final byId = <String, Map<String, dynamic>>{};
    for (final terminal in terminals) {
      final locationId = _pickLocationId(terminal);
      if (locationId.isEmpty) continue;
      byId[locationId] = {
        'id': locationId,
        'name': (terminal['location_name'] ?? '').toString(),
      };
    }
    return byId.values.toList();
  }

  @override
  void initState() {
    super.initState();
    _loadAll();
    _loadInstalledPrinters();
  }

  Future<void> _loadInstalledPrinters() async {
    try {
      final printers = await Printing.listPrinters();
      final names = <String>{};
      for (final printer in printers) {
        final name = printer.name.trim();
        if (name.isNotEmpty) {
          names.add(name);
        }
      }
      final sorted = names.toList()..sort();
      if (!mounted) return;
      setState(() {
        _installedPrinterNames = sorted;
      });
    } catch (_) {
      // Keep manual input available when printer enumeration is unavailable.
    }
  }

  @override
  void dispose() {
    _terminalNumberController.dispose();
    _terminalNameController.dispose();
    _hppTokenController.dispose();
    _spinTpnController.dispose();
    _spinAuthKeyController.dispose();
    _receiptPrinterController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() {
      _isLoading = true;
    });

    List<Map<String, dynamic>> terminals = <Map<String, dynamic>>[];
    List<Map<String, dynamic>> locations = <Map<String, dynamic>>[];
    Object? terminalLoadError;
    Object? locationLoadError;

    try {
      terminals = await _loadScopedTerminals();
      terminals = await _hydrateTerminalRowsWithDetails(terminals);
    } catch (error) {
      terminalLoadError = error;
      try {
        terminals = await _dataService.fetchTableRows(
          tableName: 'terminals',
          limit: 500,
        );
        terminals = await _hydrateTerminalRowsWithDetails(terminals);
      } catch (_) {}
    }

    try {
      locations = await _dataService.fetchTableRows(
        tableName: 'locations',
        limit: 500,
      );
    } catch (error) {
      locationLoadError = error;
    }

    if (!mounted) return;
    setState(() {
      _terminals = terminals;
      _locations = locations.isNotEmpty
          ? locations
          : _buildScopedLocationsFromTerminals(terminals);
      _isLoading = false;
    });

    if (terminalLoadError != null) {
      _showMessage(
        'Scoped terminal load failed. Fallback list used: $terminalLoadError',
        isError: true,
      );
    }
    if (locationLoadError != null) {
      _showMessage(
        'Locations could not be loaded. You can still edit terminals by existing location id.',
        isError: true,
      );
    }
  }

  String _pickTerminalId(Map<String, dynamic> row) {
    return (row['id'] ?? row['terminal_id'] ?? row['terminalId'] ?? '')
        .toString()
        .trim();
  }

  String _pickTerminalNumber(Map<String, dynamic> row) {
    return _pickString(row, ['terminal_number', 'terminalNumber']);
  }

  String _pickTerminalName(Map<String, dynamic> row) {
    return _pickString(row, ['terminal_name', 'name']);
  }

  String _pickReaderType(Map<String, dynamic> row) {
    final value = _pickString(row, [
      'card_reader_type',
      'cardReaderType',
    ]).toLowerCase();
    if (value == 'none') return 'none';
    if (value == 'dejavoo_p12') return 'dejavoo_p12';
    if (value.isEmpty) return 'none';
    return 'dejavoo_p12';
  }

  bool _pickIsActive(Map<String, dynamic> row) {
    final value = row['is_active'];
    if (value is bool) return value;
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }

  String _pickToken(Map<String, dynamic> row) {
    return _pickString(row, [
      'card_reader_hpp_auth_token',
      'cardReaderHppAuthToken',
    ]);
  }

  String _pickTerminalToken(Map<String, dynamic> row) {
    return _pickString(row, ['terminal_token', 'terminalToken', 'token']);
  }

  String _pickSpinTpn(Map<String, dynamic> row) {
    return _pickString(row, ['spin_tpn', 'spinTpn']);
  }

  String _pickSpinAuthKey(Map<String, dynamic> row) {
    return _pickString(row, ['spin_auth_key', 'spinAuthKey']);
  }

  String _maskToken(String token) {
    final value = token.trim();
    if (value.isEmpty) return '(empty)';
    if (value.length <= 10) return value;
    return '${value.substring(0, 10)}...';
  }

  String _pickReceiptPrinter(Map<String, dynamic> row) {
    return _pickString(row, ['receipt_printer_name', 'receiptPrinterName']);
  }

  bool? _pickAutoCloseEnabledNullable(Map<String, dynamic> row) {
    final value =
        row['auto_close_batch_enabled'] ?? row['autoCloseBatchEnabled'];
    if (value == null) return null;
    if (value is bool) return value;
    final normalized = value.toString().trim().toLowerCase();
    if (normalized.isEmpty || normalized == 'null') return null;
    if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
      return true;
    }
    if (normalized == 'false' || normalized == '0' || normalized == 'no') {
      return false;
    }
    return null;
  }

  String _pickAutoCloseTime(Map<String, dynamic> row) {
    final value = row['auto_close_batch_time'] ?? row['autoCloseBatchTime'];
    if (value == null) return '';
    final text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return '';
    return text;
  }

  String? _pickAutoCloseTimeNullable(Map<String, dynamic> row) {
    final text = _pickAutoCloseTime(row);
    return text.isEmpty ? null : text;
  }

  String _pickLocationId(Map<String, dynamic> row) {
    return (row['location_id'] ?? row['locationId'] ?? '').toString().trim();
  }

  String _locationLabel(String locationId) {
    for (final location in _locations) {
      final id = (location['id'] ?? '').toString().trim();
      if (id == locationId) {
        final name = (location['name'] ?? '').toString().trim();
        if (name.isNotEmpty) return name;
      }
    }
    return locationId;
  }

  void _loadTerminalIntoForm(
    Map<String, dynamic> row, {
    Map<String, dynamic>? details,
  }) {
    final source = details ?? row;

    _selectedTerminal = row;
    _terminalNumberController.text = _pickTerminalNumber(source);
    _terminalNameController.text = _pickTerminalName(source);
    _hppTokenController.text = _pickToken(source);
    _spinTpnController.text = _pickSpinTpn(source);
    _spinAuthKeyController.text = _pickSpinAuthKey(source);
    _receiptPrinterController.text = _pickReceiptPrinter(source);
    final enabledMaybe = _pickAutoCloseEnabledNullable(source);
    final timeMaybe = _pickAutoCloseTimeNullable(source);
    _autoCloseResolved = enabledMaybe != null || timeMaybe != null;
    _autoCloseEnabled = enabledMaybe ?? false;
    _autoCloseTimeController.text = timeMaybe ?? '';
    _selectedCardReader = _pickReaderType(source);
  }

  Future<void> _onSelectTerminal(Map<String, dynamic> row) async {
    final terminalId = _pickTerminalId(row);
    if (terminalId.isEmpty) {
      setState(() {
        _loadTerminalIntoForm(row);
      });
      return;
    }

    try {
      final details = await _dataService.getTerminalDetailsById(terminalId);
      if (!mounted) return;
      setState(() {
        _loadTerminalIntoForm(row, details: details ?? row);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadTerminalIntoForm(row);
      });
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    if (mounted) {
      setState(() {
        _statusMessage = message;
        _statusIsError = isError;
      });
    }

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
  }

  Future<void> _copyStatusMessage() async {
    final text = _statusMessage.trim();
    if (text.isEmpty) return;

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Message copied.')));
  }

  Future<void> _showTokenDialog(String token) async {
    final value = token.trim();
    if (value.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Terminal Token'),
        content: SelectableText(value),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!dialogContext.mounted) return;
              ScaffoldMessenger.maybeOf(
                dialogContext,
              )?.showSnackBar(const SnackBar(content: Text('Token copied.')));
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

  Future<void> _showAutoCloseDiagnostics(Map<String, dynamic> row) async {
    final terminalId = _pickTerminalId(row);
    final terminalNumber = _pickTerminalNumber(row);
    final terminalName = _pickTerminalName(row);

    final listEnabledRaw =
        row['auto_close_batch_enabled'] ?? row['autoCloseBatchEnabled'];
    final listTimeRaw = row['auto_close_batch_time'] ?? row['autoCloseBatchTime'];

    Map<String, dynamic>? details;
    Object? detailError;
    try {
      if (terminalId.isNotEmpty) {
        details = await _dataService.getTerminalDetailsById(terminalId);
      }
    } catch (error) {
      detailError = error;
    }

    final detailEnabledRaw =
        details == null
        ? null
        : (details['auto_close_batch_enabled'] ?? details['autoCloseBatchEnabled']);
    final detailTimeRaw = details == null
        ? null
        : (details['auto_close_batch_time'] ?? details['autoCloseBatchTime']);

    final listResolved =
        listEnabledRaw != null || (listTimeRaw?.toString().trim().isNotEmpty ?? false);
    final detailResolved =
        detailEnabledRaw != null || (detailTimeRaw?.toString().trim().isNotEmpty ?? false);

    final diagnosis = <String>[];
    if (terminalId.isEmpty) {
      diagnosis.add(
        'No terminal id in list row. This is a data-shape problem before SQL lookup.',
      );
    } else if (detailError != null) {
      diagnosis.add(
        'Detail read failed. This is likely SQL/RLS/schema access for terminals detail query.',
      );
    } else if (details == null) {
      diagnosis.add(
        'Detail read returned null. Likely SQL/RLS issue or terminal id not found in terminals table.',
      );
    } else if (!detailResolved && listResolved) {
      diagnosis.add(
        'List row has auto-close values but detail table read does not. This points to SQL column visibility/schema mismatch on direct terminals read.',
      );
    } else if (detailResolved && !listResolved) {
      diagnosis.add(
        'Detail table read has values but list payload does not. This points to RPC/list payload shape mismatch, not DB value loss.',
      );
    } else if (!detailResolved && !listResolved) {
      diagnosis.add(
        'Both list and detail reads show unresolved values. This can be true nulls in DB or missing columns/migration.',
      );
    } else {
      diagnosis.add('Both list and detail reads resolve auto-close values correctly.');
    }

    final report = StringBuffer()
      ..writeln('Auto-close Field Diagnostics')
      ..writeln('')
      ..writeln('Terminal: $terminalNumber | $terminalName')
      ..writeln('Terminal ID: ${terminalId.isEmpty ? '(empty)' : terminalId}')
      ..writeln('')
      ..writeln('List Row Raw Values:')
      ..writeln('  auto_close_batch_enabled: ${listEnabledRaw ?? '(null)'}')
      ..writeln('  auto_close_batch_time: ${listTimeRaw ?? '(null)'}')
      ..writeln('')
      ..writeln('Detail Read Raw Values:')
      ..writeln('  auto_close_batch_enabled: ${detailEnabledRaw ?? '(null)'}')
      ..writeln('  auto_close_batch_time: ${detailTimeRaw ?? '(null)'}')
      ..writeln('')
      ..writeln('Detail Read Error: ${detailError ?? '(none)'}')
      ..writeln('')
      ..writeln('Diagnosis:')
      ..writeln('  ${diagnosis.join(' ')}')
      ..writeln('')
      ..writeln('SQL check:')
      ..writeln("  select id, auto_close_batch_enabled, auto_close_batch_time from public.terminals where id = '$terminalId';");

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Auto-close Diagnostics'),
        content: SizedBox(
          width: 700,
          child: SingleChildScrollView(
            child: SelectableText(report.toString()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report.toString()));
              if (!dialogContext.mounted) return;
              ScaffoldMessenger.maybeOf(dialogContext)?.showSnackBar(
                const SnackBar(content: Text('Diagnostics copied.')),
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

  Widget _buildStatusPanel() {
    if (_statusMessage.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final panelColor = _statusIsError
        ? colorScheme.errorContainer
        : colorScheme.surfaceContainerHighest;
    final textColor = _statusIsError
        ? colorScheme.onErrorContainer
        : colorScheme.onSurfaceVariant;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: panelColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              _statusMessage,
              style: TextStyle(fontSize: 12, color: textColor),
            ),
          ),
          IconButton(
            tooltip: 'Copy message',
            visualDensity: VisualDensity.compact,
            onPressed: _copyStatusMessage,
            icon: const Icon(Icons.copy, size: 18),
          ),
          IconButton(
            tooltip: 'Clear message',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              setState(() {
                _statusMessage = '';
                _statusIsError = false;
              });
            },
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalList() {
    final filtered = _terminals.where((row) {
      final isActive = _pickIsActive(row);
      if (_terminalStatusFilter == 'active') return isActive;
      if (_terminalStatusFilter == 'inactive') return !isActive;
      return true;
    }).toList();

    if (filtered.isEmpty) {
      return const Center(child: Text('No terminals found.'));
    }

    return ListView.separated(
      itemCount: filtered.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final row = filtered[index];
        final activeContext = _licenseService.activeContext;
        final terminalId = _pickTerminalId(row);
        final number = _pickTerminalNumber(row);
        final name = _pickTerminalName(row);
        var reader = _pickReaderType(row);
        final isActive = _pickIsActive(row);
        final locationId = _pickLocationId(row);
        var hppToken = _pickToken(row);
        final terminalToken = _pickTerminalToken(row);
        var spinTpn = _pickSpinTpn(row);
        var spinAuthKey = _pickSpinAuthKey(row);
        final printer = _pickReceiptPrinter(row);
        final autoCloseEnabledMaybe = _pickAutoCloseEnabledNullable(row);
        final autoCloseTimeMaybe = _pickAutoCloseTimeNullable(row);
        final autoCloseResolved =
          autoCloseEnabledMaybe != null || autoCloseTimeMaybe != null;
        final autoCloseEnabled = autoCloseEnabledMaybe ?? false;
        final autoCloseTime = autoCloseTimeMaybe ?? '';

        final isActiveTerminal =
            terminalId.isNotEmpty &&
            terminalId == (activeContext?.terminalId ?? '');
        if (isActiveTerminal) {
          if (spinTpn.isEmpty) spinTpn = TerminalConfig.spinTpn.trim();
          if (spinAuthKey.isEmpty)
            spinAuthKey = TerminalConfig.spinAuthKey.trim();
          if (hppToken.isEmpty) {
            hppToken = TerminalConfig.cardReaderHppAuthToken.trim();
          }
          if (reader == 'none' && TerminalConfig.hasPhysicalCardReader) {
            reader = 'dejavoo_p12';
          }
        }

        final isSelected =
            _selectedTerminal != null &&
            _pickTerminalId(_selectedTerminal!) == terminalId;

        return ListTile(
          dense: true,
          selected: isSelected,
          title: Text('$number  |  $name'),
          subtitle: Text(
            'Status: ${isActive ? 'Active' : 'Inactive'}\nReader: $reader\nLocation: ${_locationLabel(locationId)}\nTerminal Token: ${_maskToken(terminalToken)}\nSPIn TPN: ${spinTpn.isEmpty ? '(empty)' : spinTpn}\nSPIn Auth Key: ${_maskToken(spinAuthKey)}\nCard Reader HPP Token: ${_maskToken(hppToken)}\nReceipt Printer: ${printer.isEmpty ? '(not set)' : printer}\nAuto-close batch enabled: ${autoCloseResolved ? (autoCloseEnabled ? 'true' : 'false') : 'UNKNOWN'}\nAuto-close batch time: ${autoCloseResolved ? (autoCloseTime.isEmpty ? '(not set)' : autoCloseTime) : 'UNKNOWN'}',
          ),
          trailing: Wrap(
            spacing: 4,
            children: [
              if (terminalToken.trim().isNotEmpty)
                TextButton(
                  onPressed: () => _showTokenDialog(terminalToken),
                  child: const Text('View Terminal Token'),
                ),
              IconButton(
                tooltip: 'Auto-close diagnostics',
                visualDensity: VisualDensity.compact,
                onPressed: () => _showAutoCloseDiagnostics(row),
                icon: const Icon(Icons.bug_report_outlined, size: 18),
              ),
            ],
          ),
          onTap: () => _onSelectTerminal(row),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewportHeight = MediaQuery.of(context).size.height;

    return AlertDialog(
      title: const Text('Update Terminals'),
      content: SizedBox(
        width: 900,
        height: viewportHeight * 0.82,
        child: Stack(
          children: [
            Row(
              children: [
                // Terminal List
                Expanded(
                  flex: 5,
                  child: Card(
                    margin: EdgeInsets.zero,
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        _buildStatusPanel(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: Row(
                            children: [
                              const Text('Show:'),
                              const SizedBox(width: 8),
                              DropdownButton<String>(
                                value: _terminalStatusFilter,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'active',
                                    child: Text('Active'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'inactive',
                                    child: Text('Inactive'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'all',
                                    child: Text('All'),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(() {
                                    _terminalStatusFilter = value;
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: _isLoading
                              ? const Center(child: CircularProgressIndicator())
                              : _buildTerminalList(),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // Editor Panel
                Expanded(
                  flex: 4,
                  child: Card(
                    margin: EdgeInsets.zero,
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: SingleChildScrollView(
                        child: _buildEditorPanel(context),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // Add Terminal FAB removed — terminals are created through activation only
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : _loadAll,
          child: const Text('Refresh'),
        ),
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
