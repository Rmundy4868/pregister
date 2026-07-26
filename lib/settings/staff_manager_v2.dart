import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/license_service.dart';
import '../services/settings_data_service.dart';
import '../services/supabase_service.dart';

class StaffManagerV2Dialog extends StatefulWidget {
  const StaffManagerV2Dialog({super.key});

  @override
  State<StaffManagerV2Dialog> createState() => _StaffManagerV2DialogState();
}

class _StaffManagerV2DialogState extends State<StaffManagerV2Dialog> {
  final SettingsDataService _dataService = SettingsDataService();

  static const Map<String, String> _staffRoleOptions = {
    'admin': 'Administrator',
    'manager': 'Manager',
    'cashier': 'Cashier',
  };

  bool _loading = true;
  bool _saving = false;
  String _message = '';
  String _selectedStaffId = '';
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];

  String get _activeOrganizationId =>
      LicenseService().activeContext?.organizationId.trim() ?? '';
  String get _activeOrganizationNumber =>
      LicenseService().activeContext?.organizationNumber.trim() ?? '';
  String get _activeLicenseKey =>
      LicenseService().activeContext?.licenseKey.trim() ?? '';
  String get _activeLocationId =>
      LicenseService().activeContext?.locationId.trim() ?? '';
  String get _activeLocationName =>
      LicenseService().activeContext?.locationName.trim() ?? '';

  @override
  void initState() {
    super.initState();
    _loadRows();
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

  bool _asBool(dynamic value, {bool defaultValue = false}) {
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

  String _staffRoleLabel(String value) {
    return _staffRoleOptions[_normalizeStaffRoleValue(value)] ?? value;
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

  String _maskPin(String value) {
    final pin = value.trim();
    if (pin.isEmpty) return '';
    return '****';
  }

  String _fullName(Map<String, dynamic> row) {
    final first = row['first_name']?.toString().trim() ?? '';
    final last = row['last_name']?.toString().trim() ?? '';
    final combined = '$first $last'.trim();
    if (combined.isNotEmpty) return combined;

    final fallback = row['full_name']?.toString().trim() ?? '';
    if (fallback.isNotEmpty) return fallback;

    return 'Unnamed Staff';
  }

  Map<String, dynamic>? get _selectedRow {
    if (_selectedStaffId.isEmpty) return null;
    for (final row in _rows) {
      final id = row['id']?.toString().trim() ?? '';
      if (id == _selectedStaffId) return row;
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _loadRowsViaLicenseRpc() async {
    final lookupKey = _activeLicenseKey.isNotEmpty
        ? _activeLicenseKey
        : _activeOrganizationNumber;
    if (lookupKey.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    try {
      final dynamic response = await SupabaseService.client.rpc(
        'list_staff_from_app',
        params: {
          'p_license_key': lookupKey,
          'p_location_id': _activeLocationId.isEmpty ? null : _activeLocationId,
        },
      );

      if (response is List) {
        return response
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
      }
    } catch (_) {
      // Non-fatal fallback; caller can continue with default behavior.
    }

    return const <Map<String, dynamic>>[];
  }

  Future<void> _loadRows() async {
    setState(() {
      _loading = true;
      _message = '';
    });

    try {
      var rows = await _dataService.fetchTableRows(
        tableName: 'staff',
        limit: 500,
      );
      if (rows.isEmpty) {
        final rpcRows = await _loadRowsViaLicenseRpc();
        if (rpcRows.isNotEmpty) {
          rows = rpcRows;
        }
      }
      final locationScoped = rows.where((row) {
        final orgId = row['organization_id']?.toString().trim() ?? '';
        final locId = row['location_id']?.toString().trim() ?? '';

        if (_activeLocationId.isNotEmpty) {
          return locId == _activeLocationId;
        }
        if (_activeOrganizationId.isNotEmpty) {
          return orgId == _activeOrganizationId;
        }
        return true;
      }).toList();

      final organizationScoped = rows.where((row) {
        final orgId = row['organization_id']?.toString().trim() ?? '';
        if (_activeOrganizationId.isNotEmpty) {
          return orgId == _activeOrganizationId;
        }
        return true;
      }).toList();

      var statusMessage = '';
      var scoped = _activeLocationId.isNotEmpty
          ? (locationScoped.isNotEmpty ? locationScoped : organizationScoped)
          : organizationScoped;

      if (_activeLocationId.isNotEmpty &&
          locationScoped.isEmpty &&
          organizationScoped.isNotEmpty) {
        statusMessage =
            'No staff rows matched active location id $_activeLocationId. '
            'Showing organization-level staff instead.';
      }

      if (scoped.isEmpty && rows.isNotEmpty) {
        scoped = List<Map<String, dynamic>>.from(rows);
        final broadMessage =
            'No staff rows matched active context. Showing all staff rows '
            'to help recover old activation data.';
        statusMessage = statusMessage.isEmpty
            ? broadMessage
            : '$statusMessage\n$broadMessage';
      }

      scoped.sort((a, b) {
        final aName = _fullName(a).toLowerCase();
        final bName = _fullName(b).toLowerCase();
        return aName.compareTo(bName);
      });

      final duplicatePins = <String>{};
      final pinCounts = <String, int>{};
      for (final row in scoped) {
        final pin = row['pin']?.toString().trim() ?? '';
        if (pin.isEmpty) continue;
        pinCounts[pin] = (pinCounts[pin] ?? 0) + 1;
      }
      for (final entry in pinCounts.entries) {
        if (entry.value > 1) {
          duplicatePins.add(entry.key);
        }
      }
      if (duplicatePins.isNotEmpty) {
        final suffix = duplicatePins.toList()..sort();
        final duplicateMsg =
            'Duplicate PIN(s) detected in scope: ${suffix.join(', ')}.';
        statusMessage = statusMessage.isEmpty
            ? duplicateMsg
            : '$statusMessage\n$duplicateMsg';
      }

      if (!mounted) return;
      setState(() {
        _rows = scoped;
        _message = statusMessage;
        if (_selectedStaffId.isNotEmpty) {
          final stillExists = _rows.any(
            (row) => (row['id']?.toString().trim() ?? '') == _selectedStaffId,
          );
          if (!stillExists) {
            _selectedStaffId = '';
          }
        }
      });
    } catch (error) {
      final rpcRows = await _loadRowsViaLicenseRpc();
      if (rpcRows.isNotEmpty) {
        rpcRows.sort((a, b) {
          final aName = _fullName(a).toLowerCase();
          final bName = _fullName(b).toLowerCase();
          return aName.compareTo(bName);
        });
        if (!mounted) return;
        setState(() {
          _rows = rpcRows;
          _message =
              'Loaded staff via license RPC fallback because direct table read failed.';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _message = 'Failed to load staff: $error';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  Future<Map<String, dynamic>?> _openStaffEditor({
    required Map<String, dynamic>? initialRow,
  }) async {
    final orgId =
        (initialRow?['organization_id']?.toString().trim() ??
                _activeOrganizationId)
            .trim();
    final locId =
        (initialRow?['location_id']?.toString().trim() ?? _activeLocationId)
            .trim();

    final orgIdController = TextEditingController(text: orgId);
    final locationIdController = TextEditingController(text: locId);
    final firstNameController = TextEditingController(
      text: initialRow?['first_name']?.toString() ?? '',
    );
    final lastNameController = TextEditingController(
      text: initialRow?['last_name']?.toString() ?? '',
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
    var pinVisible = false;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (builderContext, setDialogState) => AlertDialog(
          title: Text(initialRow == null ? 'Add Staff' : 'Edit Staff'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: orgIdController,
                    readOnly: true,
                    enabled: false,
                    decoration: const InputDecoration(
                      labelText: 'Organization ID',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: locationIdController,
                    readOnly: true,
                    enabled: false,
                    decoration: const InputDecoration(labelText: 'Location ID'),
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
                    controller: lastNameController,
                    decoration: const InputDecoration(labelText: 'Last Name'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: pinController,
                    keyboardType: TextInputType.number,
                    obscureText: !pinVisible,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: InputDecoration(
                      labelText: 'PIN *',
                      hintText: 'Up to 6 digits',
                      suffixIcon: IconButton(
                        tooltip: pinVisible ? 'Hide PIN' : 'Show PIN',
                        onPressed: () {
                          setDialogState(() {
                            pinVisible = !pinVisible;
                          });
                        },
                        icon: Icon(
                          pinVisible
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                        ),
                      ),
                    ),
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
            OutlinedButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () {
                if (orgIdController.text.trim().isEmpty ||
                    locationIdController.text.trim().isEmpty) {
                  _showMessage(
                    'Organization and location context are required.',
                    isError: true,
                  );
                  return;
                }
                if (firstNameController.text.trim().isEmpty) {
                  _showMessage('First Name is required.', isError: true);
                  return;
                }
                if (!_isValidStaffPin(pinController.text)) {
                  _showMessage(
                    'PIN must be numeric and no more than 6 digits.',
                    isError: true,
                  );
                  return;
                }

                Navigator.pop(dialogContext, {
                  'organizationId': orgIdController.text.trim(),
                  'locationId': locationIdController.text.trim(),
                  'firstName': firstNameController.text.trim(),
                  'lastName': lastNameController.text.trim(),
                  'phone': phoneController.text.trim(),
                  'pin': pinController.text.trim(),
                  'role': selectedRole,
                  'isActive': isActive,
                });
              },
              icon: const Icon(Icons.save_rounded),
              label: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    orgIdController.dispose();
    locationIdController.dispose();
    firstNameController.dispose();
    lastNameController.dispose();
    phoneController.dispose();
    pinController.dispose();

    return result;
  }

  Future<void> _saveStaff({required Map<String, dynamic>? initialRow}) async {
    final formValues = await _openStaffEditor(initialRow: initialRow);
    if (formValues == null) return;

    setState(() {
      _saving = true;
      _message = '';
    });

    try {
      if (initialRow == null) {
        await _dataService.insertStaffForm(
          organizationId: formValues['organizationId']?.toString() ?? '',
          locationId: formValues['locationId']?.toString() ?? '',
          firstName: formValues['firstName']?.toString() ?? '',
          lastName: formValues['lastName']?.toString() ?? '',
          phone: formValues['phone']?.toString() ?? '',
          pin: formValues['pin']?.toString() ?? '',
          role: formValues['role']?.toString() ?? 'cashier',
          isActive: formValues['isActive'] as bool? ?? true,
        );
      } else {
        await _dataService.updateStaffForm(
          id: initialRow['id'],
          organizationId: formValues['organizationId']?.toString() ?? '',
          locationId: formValues['locationId']?.toString() ?? '',
          firstName: formValues['firstName']?.toString() ?? '',
          lastName: formValues['lastName']?.toString() ?? '',
          phone: formValues['phone']?.toString() ?? '',
          pin: formValues['pin']?.toString() ?? '',
          role: formValues['role']?.toString() ?? 'cashier',
          isActive: formValues['isActive'] as bool? ?? true,
        );
      }

      if (!mounted) return;
      _showMessage(initialRow == null ? 'Staff saved.' : 'Staff updated.');
      await _loadRows();
    } catch (error) {
      _showMessage('Staff save failed: $error', isError: true);
    } finally {
      if (!mounted) return;
      setState(() {
        _saving = false;
      });
    }
  }

  Future<void> _toggleSelectedActive() async {
    final selected = _selectedRow;
    if (selected == null) {
      _showMessage('Select a staff record first.', isError: true);
      return;
    }

    final currentActive = _asBool(selected['is_active'], defaultValue: true);

    setState(() {
      _saving = true;
      _message = '';
    });

    try {
      await _dataService.updateStaffForm(
        id: selected['id'],
        organizationId: selected['organization_id']?.toString() ?? '',
        locationId: selected['location_id']?.toString() ?? '',
        firstName: selected['first_name']?.toString() ?? '',
        lastName: selected['last_name']?.toString() ?? '',
        phone: selected['phone']?.toString() ?? '',
        pin: selected['pin']?.toString() ?? '',
        role: selected['role']?.toString() ?? 'cashier',
        isActive: !currentActive,
      );

      if (!mounted) return;
      _showMessage(
        !currentActive ? 'Staff marked active.' : 'Staff marked inactive.',
      );
      await _loadRows();
    } catch (error) {
      _showMessage('Unable to change active status: $error', isError: true);
    } finally {
      if (!mounted) return;
      setState(() {
        _saving = false;
      });
    }
  }

  void _showMessage(String text, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedRow;
    final selectedActive = _asBool(selected?['is_active'], defaultValue: true);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Staff Manager V2',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 300,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Organization',
                      ),
                      child: SelectableText(
                        _activeOrganizationNumber.isNotEmpty
                            ? _activeOrganizationNumber
                            : (_activeOrganizationId.isNotEmpty
                                  ? _activeOrganizationId
                                  : '(not resolved)'),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 360,
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Location'),
                      child: SelectableText(
                        _activeLocationName.isNotEmpty
                            ? '$_activeLocationName ($_activeLocationId)'
                            : (_activeLocationId.isNotEmpty
                                  ? _activeLocationId
                                  : '(not resolved)'),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _saving
                        ? null
                        : () => _saveStaff(initialRow: null),
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: const Text('Add Staff'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: (_saving || selected == null)
                        ? null
                        : () => _saveStaff(initialRow: selected),
                    icon: const Icon(Icons.edit_rounded),
                    label: const Text('Edit Selected'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: (_saving || selected == null)
                        ? null
                        : _toggleSelectedActive,
                    icon: Icon(
                      selectedActive
                          ? Icons.person_off_rounded
                          : Icons.person_rounded,
                    ),
                    label: Text(
                      selectedActive ? 'Make Inactive' : 'Make Active',
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _loadRows,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _rows.isEmpty
                      ? const Center(
                          child: Text('No staff found for this location.'),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(10),
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final row = _rows[index];
                            final id = row['id']?.toString().trim() ?? '';
                            final isSelected =
                                id.isNotEmpty && id == _selectedStaffId;
                            final isActive = _asBool(
                              row['is_active'],
                              defaultValue: true,
                            );
                            final roleText = _staffRoleLabel(
                              row['role']?.toString() ?? '',
                            );
                            final pinText = row['pin']?.toString() ?? '';
                            final maskedPinText = _maskPin(pinText);
                            final phoneText = _formatPhoneNumber(
                              row['phone']?.toString() ?? '',
                            );

                            final tileColor = isSelected
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(context).colorScheme.surface;

                            return Material(
                              color: tileColor,
                              borderRadius: BorderRadius.circular(10),
                              child: ListTile(
                                onTap: () {
                                  setState(() {
                                    _selectedStaffId = id;
                                  });
                                },
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                title: Text(
                                  _fullName(row),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(
                                  'Role: $roleText  |  '
                                  'PIN: $maskedPinText\n'
                                  'Phone: $phoneText',
                                ),
                                isThreeLine: true,
                                trailing: Chip(
                                  label: Text(isActive ? 'Active' : 'Inactive'),
                                  backgroundColor: isActive
                                      ? const Color(0xFFD1FADF)
                                      : const Color(0xFFFEE4E2),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              if (_message.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(_message),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
