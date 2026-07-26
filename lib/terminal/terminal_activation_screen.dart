// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../login/login_screen.dart';
import '../services/license_service.dart';
import 'activation_summary_screen.dart';

class TerminalActivationScreen extends StatefulWidget {
  const TerminalActivationScreen({super.key});

  @override
  State<TerminalActivationScreen> createState() => _TerminalActivationScreenState();
}

class _TerminalActivationScreenState extends State<TerminalActivationScreen> {
  final LicenseService _licenseService = LicenseService();
  final TextEditingController _licenseController = TextEditingController();
  final TextEditingController _organizationNumberController =
      TextEditingController();
  final TextEditingController _terminalNumberController = TextEditingController();
  final TextEditingController _terminalNameController = TextEditingController();
  final TextEditingController _masterPinController = TextEditingController();
  final TextEditingController _masterPinConfirmController = TextEditingController();
  final FocusNode _licenseFocusNode = FocusNode();
  final FocusNode _organizationFocusNode = FocusNode();
  final FocusNode _terminalNumberFocusNode = FocusNode();
  final FocusNode _terminalNameFocusNode = FocusNode();
  final FocusNode _masterPinFocusNode = FocusNode();

  bool _busy = false;
  String? _error;
  String? _setupWarning;
  bool _checkingTerminalAvailability = false;
  bool? _isTerminalNumberAvailable;
  String? _terminalAvailabilityMessage;
  String _organizationId = '';
  List<String> _availableLocations = const [];
  String? _selectedLocationName;
  bool _identityValidating = false;
  bool? _identityValidationSuccess;
  String? _identityValidationMessage;
  bool _lookingUpLicense = false;
  Map<String, String>? _orgFieldsFromLicense;
  String? _licenseOnlyError;
  String? _stickyError;
  String? _activationErrorDetails;
  bool _deviceActivationLocked = false;
  String? _deviceActivationMessage;
  final TextEditingController _newLocationController = TextEditingController();
  bool _showNewLocationField = false;

  @override
  void initState() {
    super.initState();
    _licenseFocusNode.addListener(_handleLicenseFieldFocused);
    _licenseFocusNode.addListener(_handleIdentityFocusChange);
    _organizationFocusNode.addListener(_handleIdentityFocusChange);
    _terminalNumberFocusNode.addListener(_handleIdentityFocusChange);
    _initialize();
  }

  @override
  void dispose() {
    _licenseFocusNode.removeListener(_handleLicenseFieldFocused);
    _licenseFocusNode.removeListener(_handleIdentityFocusChange);
    _organizationFocusNode.removeListener(_handleIdentityFocusChange);
    _terminalNumberFocusNode.removeListener(_handleIdentityFocusChange);
    _licenseController.dispose();
    _organizationNumberController.dispose();
    _terminalNumberController.dispose();
    _terminalNameController.dispose();
    _masterPinController.dispose();
    _masterPinConfirmController.dispose();
    _newLocationController.dispose();
    _licenseFocusNode.dispose();
    _organizationFocusNode.dispose();
    _terminalNumberFocusNode.dispose();
    _terminalNameFocusNode.dispose();
    _masterPinFocusNode.dispose();
    super.dispose();
  }

  void _handleLicenseFieldFocused() {
    if (_licenseFocusNode.hasFocus) return;
    _doLicenseLookup();
  }

  Future<void> _doLicenseLookup() async {
    final licenseKey = _licenseController.text.trim();
    if (licenseKey.isEmpty) {
      setState(() {
        _lookingUpLicense = false;
        _orgFieldsFromLicense = null;
        _licenseOnlyError = null;
      });
      return;
    }

    setState(() {
      _lookingUpLicense = true;
      _orgFieldsFromLicense = null;
      _licenseOnlyError = null;
    });

    final result = await _licenseService.findOrganizationByLicenseKey(
      licenseKey: licenseKey,
    );
    if (!mounted) return;

    setState(() {
      _lookingUpLicense = false;
      if (result.found) {
        _orgFieldsFromLicense = result.fields;
        _licenseOnlyError = null;
        final orgNum = result.fields['organization_number'];
        if (orgNum != null &&
            orgNum.isNotEmpty &&
            _organizationNumberController.text.trim().isEmpty) {
          _organizationNumberController.text = orgNum;
        }
      } else {
        _orgFieldsFromLicense = null;
        _licenseOnlyError = result.errorMessage;
      }
    });
  }

  void _handleIdentityFocusChange() {
    if (_busy) return;
    if (_licenseFocusNode.hasFocus || _organizationFocusNode.hasFocus ||
        _terminalNumberFocusNode.hasFocus) { return; }
    _validateEnteredIdentity();
  }

  Future<void> _validateEnteredIdentity() async {
    final licenseKey = _licenseController.text.trim();
    final organizationNumber = _organizationNumberController.text.trim();

    if (licenseKey.isEmpty || organizationNumber.isEmpty) {
      if (!mounted) return;
      setState(() {
        _organizationId = '';
        _availableLocations = const [];
        _selectedLocationName = null;
        _isTerminalNumberAvailable = null;
        _terminalAvailabilityMessage = null;
        _identityValidating = false;
        _identityValidationSuccess = null;
        _identityValidationMessage = null;
      });
      return;
    }

    setState(() {
      _identityValidating = true;
      _identityValidationSuccess = null;
      _identityValidationMessage = null;
    });

    final resolved = await _resolveOrganizationContext(showBusy: false);
    if (!mounted) return;
    setState(() {
      _identityValidating = false;
      if (resolved) {
        _error = null;
        _identityValidationSuccess = true;
        _identityValidationMessage = 'Organization and license validated.';
      } else {
        _identityValidationSuccess = false;
        _identityValidationMessage = _error ?? 'Organization not found.';
      }
    });
    // Terminal availability is checked only when Activate is pressed.
  }

  String _friendlyActivationError(String? rawError) {
    final text = (rawError ?? '').toLowerCase();
    if (text.contains('no terminal is registered to this device') ||
        text.contains('terminal is not registered') ||
        text.contains('is inactive')) {
      return 'Terminal Not Active - Please Register';
    }
    return (rawError ?? 'Activation failed.').trim();
  }

  String _licenseSourceLabel() {
    final value = _licenseController.text.trim();
    if (value.isEmpty) return 'empty';
    return _organizationId.isNotEmpty ? 'validated user input' : 'user input';
  }

  Future<void> _copyToClipboard(String text) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Error copied to clipboard.')),
    );
  }

  String? _normalizeTerminalNumber(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    if (!RegExp(r'^[0-9]{1,4}$').hasMatch(value)) return null;
    return value.padLeft(4, '0');
  }

  void _setError(String message) {
    _error = message;
    _stickyError = message;
  }

  bool get _organizationNumberLocked {
    final value = _orgFieldsFromLicense?['organization_number']?.trim() ?? '';
    return value.isNotEmpty;
  }

  Future<void> _checkTerminalAvailability() async {
    if (_busy) return;

    final contextReady = await _resolveOrganizationContext(showBusy: false);
    if (!contextReady || _organizationId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isTerminalNumberAvailable = null;
        _terminalAvailabilityMessage = 'Enter valid organization and license first.';
        _checkingTerminalAvailability = false;
      });
      return;
    }

    final rawTerminalNumber = _terminalNumberController.text.trim();
    final terminalNumber = _normalizeTerminalNumber(rawTerminalNumber);
    if (rawTerminalNumber.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isTerminalNumberAvailable = null;
        _terminalAvailabilityMessage = 'Enter a terminal number.';
        _checkingTerminalAvailability = false;
      });
      return;
    }

    if (terminalNumber == null) {
      if (!mounted) return;
      setState(() {
        _isTerminalNumberAvailable = false;
        _terminalAvailabilityMessage =
            'Terminal Number must be 1-4 digits (stored as 4 digits, e.g. 0099).';
        _checkingTerminalAvailability = false;
      });
      return;
    }

    if (_terminalNumberController.text.trim() != terminalNumber) {
      _terminalNumberController.value = TextEditingValue(
        text: terminalNumber,
        selection: TextSelection.collapsed(offset: terminalNumber.length),
      );
    }

    setState(() {
      _checkingTerminalAvailability = true;
      _isTerminalNumberAvailable = null;
      _terminalAvailabilityMessage = null;
    });

    final inUse = await _licenseService.isTerminalNumberInUse(
      organizationId: _organizationId,
      terminalNumber: terminalNumber,
      locationName: _selectedLocationName,
    );

    if (!mounted) return;
    if (terminalNumber != _terminalNumberController.text.trim()) return;

    setState(() {
      _checkingTerminalAvailability = false;
      _isTerminalNumberAvailable = !inUse;
      _terminalAvailabilityMessage = inUse
          ? 'Terminal number already in use. Please use a different number.'
          : 'Terminal number is available.';
    });
  }

  Future<bool> _resolveOrganizationContext({required bool showBusy}) async {
    final licenseKey = _licenseController.text.trim();
    final organizationNumber = _organizationNumberController.text.trim();

    if (licenseKey.isEmpty || organizationNumber.isEmpty) {
      if (!mounted) return false;
      setState(() {
        _setError('Organization Number and License Key are required.');
      });
      return false;
    }

    if (showBusy) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }

    final lookup = await _licenseService.findOrganizationByNumberAndLicense(
      organizationNumber: organizationNumber,
      licenseKey: licenseKey,
    );

    if (!mounted) return false;
    if (!lookup.found) {
      if (showBusy) {
        setState(() {
          _busy = false;
        });
      }
      setState(() {
        _setError(lookup.errorMessage ?? 'Organization lookup failed.');
      });
      return false;
    }

    final locations = await _licenseService.fetchOrCreateLocationsForOrganization(
      organizationId: lookup.organizationId,
    );

    if (!mounted) return false;
    if (locations.isEmpty) {
      if (showBusy) {
        setState(() {
          _busy = false;
        });
      }
      setState(() {
        _setError('No locations available and default location could not be created.');
      });
      return false;
    }

    String? nextLocation = _selectedLocationName;
    if (nextLocation == null || !locations.contains(nextLocation)) {
      nextLocation = locations.isNotEmpty ? locations.first : null;
    }

    setState(() {
      _organizationId = lookup.organizationId;
      _availableLocations = locations;
      _selectedLocationName = nextLocation;
      // If no locations found, show inline creation field
      _showNewLocationField = locations.isEmpty;
    });

    if (locations.isEmpty) {
      if (showBusy) setState(() => _busy = false);
      setState(() {
        _setError('No locations found. Enter a location name below to create one.');
      });
      return false;
    }

    return true;
  }

  Future<void> _initialize() async {
    final startupResult = await _licenseService.initializeFromStoredOrDefine();
    if (!mounted) return;
    if (startupResult.success && startupResult.context != null) {
      setState(() {
        _deviceActivationLocked = true;
        _deviceActivationMessage =
            'This device is already activated as terminal '
            '${startupResult.context!.terminalNumber} '
            'for organization ${startupResult.context!.organizationNumber}. '
            'To move this device, deactivate it first from Terminal Settings.';
      });
    }

    final hasLocationUpsertRpc = await _licenseService
        .isUpsertLocationRpcAvailable();
    if (!mounted) return;

    if (!hasLocationUpsertRpc) {
      setState(() {
        _setupWarning =
            'Database setup update needed: run supabase/license_setup.sql to install upsert_location_from_app for Add Location support.';
      });
    }

    setState(() {
      _busy = false;
      _error = null;
      _licenseController.text = '';
      _organizationNumberController.text = '';
      _terminalNumberController.text = '0001';
      _terminalNameController.text = '';
      _masterPinController.text = '';
      _masterPinConfirmController.text = '';
      _availableLocations = const [];
      _newLocationController.text = '';
      _showNewLocationField = false;
      _selectedLocationName = null;
      _organizationId = '';
      _isTerminalNumberAvailable = null;
      _terminalAvailabilityMessage = null;
      _identityValidating = false;
      _identityValidationSuccess = null;
      _identityValidationMessage = null;
      _lookingUpLicense = false;
      _orgFieldsFromLicense = null;
      _licenseOnlyError = null;
      _deviceActivationLocked = _deviceActivationLocked;
      _deviceActivationMessage = _deviceActivationMessage;
    });
  }

  Future<void> _activate() async {
    if (_deviceActivationLocked) {
      setState(() {
        _activationErrorDetails = null;
        _setError(
          'This device is already activated. Deactivate it first before assigning a new terminal.',
        );
      });
      return;
    }

    final rawTerminalNumber = _terminalNumberController.text.trim();
    final normalizedTerminalNumber = _normalizeTerminalNumber(rawTerminalNumber);

    if (rawTerminalNumber.isEmpty) {
      setState(() {
        _activationErrorDetails = null;
        _setError('Terminal Number is required.');
      });
      return;
    }

    if (normalizedTerminalNumber == null) {
      setState(() {
        _activationErrorDetails = null;
        _setError('Terminal Number must be 1-4 digits (stored as 4 digits, e.g. 0099).');
        _isTerminalNumberAvailable = false;
        _terminalAvailabilityMessage =
            'Terminal Number must be 1-4 digits (stored as 4 digits, e.g. 0099).';
      });
      return;
    }

    if (_terminalNumberController.text.trim() != normalizedTerminalNumber) {
      _terminalNumberController.value = TextEditingValue(
        text: normalizedTerminalNumber,
        selection: TextSelection.collapsed(offset: normalizedTerminalNumber.length),
      );
    }

    // Validate terminal name
    final terminalName = _terminalNameController.text.trim();
    if (terminalName.isEmpty) {
      setState(() {
        _activationErrorDetails = null;
        _setError('Terminal Name is required.');
      });
      _terminalNameFocusNode.requestFocus();
      return;
    }

    // Validate master PIN
    final masterPin = _masterPinController.text.trim();
    final masterPinConfirm = _masterPinConfirmController.text.trim();
    if (masterPin.isEmpty) {
      setState(() {
        _activationErrorDetails = null;
        _setError('Master PIN is required to create the default staff account.');
      });
      _masterPinFocusNode.requestFocus();
      return;
    }
    if (!RegExp(r'^[0-9]{4,6}$').hasMatch(masterPin)) {
      setState(() {
        _activationErrorDetails = null;
        _setError('Master PIN must be 4-6 digits.');
      });
      _masterPinFocusNode.requestFocus();
      return;
    }
    if (masterPin != masterPinConfirm) {
      setState(() {
        _activationErrorDetails = null;
        _setError('Master PIN and Confirm PIN do not match.');
      });
      return;
    }

    // If new location field is showing, capture the name BEFORE any async calls
    // that might overwrite _selectedLocationName.
    String? newLocationNameOverride;
    if (_showNewLocationField) {
      final newLocationName = _newLocationController.text.trim();
      if (newLocationName.isEmpty) {
        setState(() => _setError('Please enter a location name.'));
        return;
      }
      newLocationNameOverride = newLocationName;
      _selectedLocationName = newLocationName;
    }

    final terminalNumber = normalizedTerminalNumber;

    final hasContext = await _resolveOrganizationContext(showBusy: true);
    if (!mounted) return;

    // If context resolution failed only because no locations exist yet,
    // we can still proceed — activateLicense will create the location.
    if (!hasContext && !_showNewLocationField) return;

    // Use the override captured before async calls (prevents _resolveOrganizationContext
    // from wiping the new location name).
    final locationNameToUse = newLocationNameOverride ?? _selectedLocationName;

    final inUse = await _licenseService.isTerminalNumberInUse(
      organizationId: _organizationId,
      terminalNumber: terminalNumber,
      locationName: locationNameToUse,
    );
    if (!mounted) return;
    if (inUse) {
      setState(() {
        _activationErrorDetails = null;
        _busy = false;
        _isTerminalNumberAvailable = false;
        _terminalAvailabilityMessage = 'Terminal ID already used.';
        _setError('Terminal ID already used.');
      });
      _terminalNumberFocusNode.requestFocus();
      return;
    }

    setState(() {
      _isTerminalNumberAvailable = true;
      _terminalAvailabilityMessage = 'Terminal number is available.';
    });

    setState(() {
      _busy = true;
      _error = null;
      _activationErrorDetails = null;
    });

    final result = await _licenseService.activateLicense(
      _licenseController.text,
      terminalNumber: terminalNumber,
      terminalName: terminalName,
      locationName: locationNameToUse,
      masterPin: masterPin,
      allowTerminalRegistration: true,
    );
    if (!mounted) return;

    if (result.success) {
      setState(() {
        _activationErrorDetails = null;
        _busy = false;
      });
      final deviceId = await _licenseService.getOrCreateDeviceId();
      final deviceLabel = await _licenseService.getOrCreateDeviceLabel();
      if (!mounted) return;
      // Navigate to summary screen to validate all resolved variables
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ActivationSummaryScreen(
            result: result,
            deviceId: deviceId,
            deviceLabel: deviceLabel,
          ),
        ),
      );
      return;
    }

    setState(() {
      _busy = false;
      final rawError = (result.errorMessage ?? '').trim();
      _activationErrorDetails = rawError.isEmpty ? null : rawError;
      _setError(_friendlyActivationError(result.errorMessage));
    });
  }

  void _goToLogin() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final leftGutterWidth = screenWidth >= 1200
        ? (screenWidth * 0.2).clamp(220.0, 420.0)
        : 0.0;

    return Scaffold(
      appBar: AppBar(title: const Text('Terminal Activation')),
      body: Row(
        children: [
          if (leftGutterWidth > 0) SizedBox(width: leftGutterWidth),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Image.asset(
                            'assets/icons/Blue transparent-logo.png',
                            height: 42,
                            fit: BoxFit.contain,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Activate terminal for this install and bind startup variables.',
                              style: TextStyle(fontSize: 16),
                            ),
                          ),
                        ],
                      ),
                      if (_deviceActivationLocked && _deviceActivationMessage != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            border: Border.all(color: Colors.blue.shade200),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Device Already Activated',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.blue,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _deviceActivationMessage!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 8),
                              FilledButton(
                                onPressed: _goToLogin,
                                child: const Text('Continue to Login'),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (_setupWarning != null) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade100,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _setupWarning!,
                            style: const TextStyle(color: Colors.black87),
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      TextField(
                        controller: _licenseController,
                        focusNode: _licenseFocusNode,
                        enabled: !_busy && !_deviceActivationLocked,
                        textInputAction: TextInputAction.next,
                        onChanged: (_) {
                          setState(() {
                            _organizationId = '';
                            _availableLocations = const [];
                            _selectedLocationName = null;
                            _isTerminalNumberAvailable = null;
                            _terminalAvailabilityMessage = null;
                            _identityValidating = false;
                            _identityValidationSuccess = null;
                            _identityValidationMessage = null;
                            _orgFieldsFromLicense = null;
                            _licenseOnlyError = null;
                          });
                        },
                        onSubmitted: (_) {
                          _doLicenseLookup();
                          _validateEnteredIdentity();
                        },
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Application License Key',
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Application License Key Source: ${_licenseSourceLabel()}',
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                      if (_lookingUpLicense) ...
                        [
                          const SizedBox(height: 8),
                          const Row(
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Looking up organization by license key...',
                                style: TextStyle(fontSize: 12, color: Colors.black54),
                              ),
                            ],
                          ),
                        ]
                      else if (_licenseOnlyError != null) ...
                        [
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              border: Border.all(color: Colors.red.shade200),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(Icons.error_outline,
                                        size: 16, color: Colors.red),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: SelectableText(
                                        _licenseOnlyError!,
                                        style: const TextStyle(
                                            fontSize: 12, color: Colors.red),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () async {
                                      await _copyToClipboard(_licenseOnlyError!);
                                    },
                                    icon: const Icon(Icons.copy, size: 14),
                                    label: const Text('Copy Error',
                                        style: TextStyle(fontSize: 12)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ]
                      else if (_orgFieldsFromLicense != null) ...
                        [
                          const SizedBox(height: 8),
                          Theme(
                            data: Theme.of(context).copyWith(
                              dividerColor: Colors.transparent,
                            ),
                            child: ExpansionTile(
                              initiallyExpanded: true,
                              tilePadding: EdgeInsets.zero,
                              childrenPadding: EdgeInsets.zero,
                              title: const Row(
                                children: [
                                  Icon(Icons.check_circle, size: 16, color: Colors.blue),
                                  SizedBox(width: 6),
                                  Text(
                                    'Organization Record Fields',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.blue,
                                    ),
                                  ),
                                ],
                              ),
                              children: [
                                Container(
                                  constraints: const BoxConstraints(maxHeight: 200),
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.blue.shade200),
                                    borderRadius: BorderRadius.circular(6),
                                    color: Colors.blue.shade50,
                                  ),
                                  child: SingleChildScrollView(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: _orgFieldsFromLicense!.entries
                                          .map(
                                            (e) => Padding(
                                              padding: const EdgeInsets.symmetric(
                                                vertical: 2,
                                              ),
                                              child: SelectableText(
                                                '${e.key}: ${e.value}',
                                                style: const TextStyle(fontSize: 12),
                                              ),
                                            ),
                                          )
                                          .toList(),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      const SizedBox(height: 10),
                      TextField(
                        controller: _organizationNumberController,
                        focusNode: _organizationFocusNode,
                        enabled: !_busy && !_deviceActivationLocked,
                        readOnly: _organizationNumberLocked,
                        textInputAction: TextInputAction.next,
                        onChanged: (_) {
                          setState(() {
                            _organizationId = '';
                            _availableLocations = const [];
                            _selectedLocationName = null;
                            _isTerminalNumberAvailable = null;
                            _terminalAvailabilityMessage = null;
                            _identityValidating = false;
                            _identityValidationSuccess = null;
                            _identityValidationMessage = null;
                          });
                        },
                        onSubmitted: (_) => _validateEnteredIdentity(),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Organization Number',
                          helperText:
                              'Auto-populated from license key when available.',
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (_identityValidating)
                        const Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Checking...',
                              style: TextStyle(fontSize: 12, color: Colors.black54),
                            ),
                          ],
                        )
                      else if (_identityValidationSuccess != null)
                        (_identityValidationSuccess!
                            ? Row(
                                children: [
                                  Icon(
                                    Icons.check_circle,
                                    size: 16,
                                    color: Colors.blue.shade700,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      _identityValidationMessage ?? '',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.blue.shade700,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  border: Border.all(color: Colors.red.shade200),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(Icons.error, size: 16, color: Colors.red),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: SelectableText(
                                        _identityValidationMessage ?? '',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.red,
                                        ),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () => _copyToClipboard(
                                        _identityValidationMessage ?? '',
                                      ),
                                      child: const Text('Copy Error'),
                                    ),
                                  ],
                                ),
                              )),
                      const SizedBox(height: 8),
                      if (_showNewLocationField) ...[  
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            border: Border.all(color: Colors.blue.shade200),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'No locations exist for this organization. Enter a name to create the first one.',
                                style: TextStyle(fontSize: 12, color: Colors.black54),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _newLocationController,
                                enabled: !_busy && !_deviceActivationLocked,
                                textInputAction: TextInputAction.done,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: 'New Location Name',
                                  hintText: 'e.g. Main Office',
                                  isDense: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else
                        DropdownButtonFormField<String>(
                          initialValue: _selectedLocationName,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Location',
                          ),
                          items: _availableLocations
                              .map(
                                (location) => DropdownMenuItem<String>(
                                  value: location,
                                  child: Text(location),
                                ),
                              )
                              .toList(),
                          onChanged: _busy
                              ? null
                              : _deviceActivationLocked
                              ? null
                              : (value) {
                                  setState(() {
                                    _selectedLocationName = value;
                                    _terminalAvailabilityMessage = null;
                                    _isTerminalNumberAvailable = null;
                                  });
                                },
                        ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _terminalNumberController,
                        focusNode: _terminalNumberFocusNode,
                        enabled: !_busy && !_deviceActivationLocked,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(4),
                        ],
                        onChanged: (_) {
                          setState(() {
                            _isTerminalNumberAvailable = null;
                            _terminalAvailabilityMessage = null;
                          });
                        },
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          labelText: 'Terminal Number',
                          suffixIcon: _checkingTerminalAvailability
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    height: 14,
                                    width: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                )
                              : (_isTerminalNumberAvailable == null
                                    ? null
                                    : Icon(
                                        _isTerminalNumberAvailable!
                                            ? Icons.check_circle
                                            : Icons.error,
                                        color: _isTerminalNumberAvailable!
                                          ? Colors.blue
                                            : Colors.red,
                                      )),
                          helperText:
                              'Use 1-4 digits; app stores as 4 digits (e.g. 0099).',
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          OutlinedButton(
                            onPressed: (_busy ||
                                    _checkingTerminalAvailability ||
                                    _deviceActivationLocked)
                                ? null
                                : _checkTerminalAvailability,
                            child: const Text('Check Availability'),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: SelectableText(
                              _terminalAvailabilityMessage ?? '',
                              style: TextStyle(
                                fontSize: 12,
                                color: (_isTerminalNumberAvailable ?? true)
                                    ? Colors.black54
                                    : Colors.red,
                              ),
                            ),
                          ),
                          if ((_terminalAvailabilityMessage ?? '').isNotEmpty &&
                              (_isTerminalNumberAvailable != true))
                            TextButton(
                              onPressed: () =>
                                  _copyToClipboard(_terminalAvailabilityMessage ?? ''),
                              child: const Text('Copy Error'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _terminalNameController,
                        focusNode: _terminalNameFocusNode,
                        enabled: !_busy && !_deviceActivationLocked,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Terminal Name *',
                          hintText: 'e.g. Front Desk, Drive-Through',
                          helperText: 'Friendly label shown on receipts and reports.',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _masterPinController,
                        focusNode: _masterPinFocusNode,
                        enabled: !_busy && !_deviceActivationLocked,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Master PIN *',
                          hintText: '4-6 digits',
                          helperText: 'Sets PIN for the default owner staff account.',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _masterPinConfirmController,
                        enabled: !_busy && !_deviceActivationLocked,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Confirm Master PIN *',
                          hintText: 'Re-enter PIN',
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        SelectableText(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () async {
                              await _copyToClipboard(_error!);
                            },
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('Copy Error'),
                          ),
                        ),
                        if ((_activationErrorDetails ?? '').isNotEmpty &&
                            (_activationErrorDetails != _error)) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              border: Border.all(color: Colors.red.shade200),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Technical Details',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.red,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                SelectableText(
                                  _activationErrorDetails!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.red,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                TextButton.icon(
                                  onPressed: () =>
                                      _copyToClipboard(_activationErrorDetails!),
                                  icon: const Icon(Icons.copy, size: 16),
                                  label: const Text('Copy Technical Details'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                      if (_stickyError != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            border: Border.all(color: Colors.red.shade200),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Last Error (Sticky)',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.red,
                                ),
                              ),
                              const SizedBox(height: 6),
                              SelectableText(
                                _stickyError!,
                                style: const TextStyle(color: Colors.red),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  TextButton.icon(
                                    onPressed: () => _copyToClipboard(_stickyError!),
                                    icon: const Icon(Icons.copy, size: 16),
                                    label: const Text('Copy Error'),
                                  ),
                                  const SizedBox(width: 8),
                                  TextButton(
                                    onPressed: () {
                                      setState(() {
                                        _stickyError = null;
                                      });
                                    },
                                    child: const Text('Clear'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: (_busy || _deviceActivationLocked)
                          ? null
                          : _activate,
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Activate Terminal'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
