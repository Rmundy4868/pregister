import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../register/register_variant_router.dart';
import '../services/license_service.dart';
import '../supabase_config.dart';

class LicenseGateScreen extends StatefulWidget {
  const LicenseGateScreen({super.key});

  @override
  State<LicenseGateScreen> createState() => _LicenseGateScreenState();
}

class _LicenseGateScreenState extends State<LicenseGateScreen> {
  final LicenseService _licenseService = LicenseService();
  final TextEditingController _licenseController = TextEditingController();
  final TextEditingController _organizationNumberController =
      TextEditingController();
  final FocusNode _licenseFocusNode = FocusNode();

  bool _busy = true;
  bool _loadingOptions = false;
  String? _error;
  String? _setupWarning;
  String _lastLoadedLicenseKey = '';
  List<String> _availableLocations = const [];
  String? _selectedLocationName;
  List<String> _availableTerminals = const ['0001'];
  String? _selectedTerminalNumber = '0001';

  @override
  void initState() {
    super.initState();
    _licenseFocusNode.addListener(_handleLicenseFocusChange);
    _initialize();
  }

  @override
  void dispose() {
    _licenseFocusNode.removeListener(_handleLicenseFocusChange);
    _licenseController.dispose();
    _organizationNumberController.dispose();
    _licenseFocusNode.dispose();
    super.dispose();
  }

  void _handleLicenseFocusChange() {
    if (_licenseFocusNode.hasFocus) return;
    if (_busy || _loadingOptions) return;
    _loadActivationOptions();
  }

  Future<void> _initialize() async {
    final hasLocationUpsertRpc = await _licenseService
        .isUpsertLocationRpcAvailable();
    if (!mounted) return;

    if (!hasLocationUpsertRpc) {
      setState(() {
        _setupWarning =
            'Database setup update needed: run supabase/license_setup.sql to install upsert_location_from_app for Add Location support.';
      });
    }

    final result = await _licenseService.initializeFromStoredOrDefine();
    if (!mounted) return;

    if (result.success) {
      _goToRegister();
      return;
    }

    if (result.requiresTerminalRegistration) {
      _licenseController.text = result.attemptedLicenseKey ?? _licenseController.text;
      await _handleUnregisteredTerminalFlow();
      return;
    }

    setState(() {
      _busy = false;
      _error = result.errorMessage;
      if ((result.attemptedLicenseKey ?? '').isNotEmpty) {
        _licenseController.text = result.attemptedLicenseKey!;
      }
      _selectedTerminalNumber =
          (result.attemptedTerminalNumber ?? '').isNotEmpty
          ? result.attemptedTerminalNumber
          : '0001';
    });

    await _loadActivationOptions(force: true);
  }

  Future<void> _loadActivationOptions({bool force = false}) async {
    final licenseKey = _licenseController.text.trim();
    if (licenseKey.isEmpty) {
      if (!mounted) return;
      setState(() {
        _lastLoadedLicenseKey = '';
        _availableLocations = const [];
        _selectedLocationName = null;
        _availableTerminals = const ['0001'];
        _selectedTerminalNumber = '0001';
      });
      return;
    }

    if (!force && licenseKey == _lastLoadedLicenseKey) {
      return;
    }

    setState(() {
      _loadingOptions = true;
    });

    final locations = await _licenseService.fetchLocationsForLicense(
      licenseKey,
    );
    String? nextLocation = _selectedLocationName;
    if (nextLocation != null && !locations.contains(nextLocation)) {
      nextLocation = null;
    }
    nextLocation ??= locations.isNotEmpty ? locations.first : null;

    final terminals = await _licenseService.fetchTerminalsForLicense(
      rawLicenseKey: licenseKey,
      locationName: nextLocation,
    );

    if (!mounted) return;
    setState(() {
      _loadingOptions = false;
      _lastLoadedLicenseKey = licenseKey;
      _availableLocations = locations;
      _selectedLocationName = nextLocation;
      _availableTerminals = terminals;
      if (_selectedTerminalNumber == null ||
          !_availableTerminals.contains(_selectedTerminalNumber)) {
        _selectedTerminalNumber = _availableTerminals.isNotEmpty
            ? _availableTerminals.first
            : '0001';
      }
    });
  }

  Future<void> _reloadTerminalsForSelectedLocation() async {
    final licenseKey = _licenseController.text.trim();
    if (licenseKey.isEmpty) return;

    setState(() {
      _loadingOptions = true;
    });

    final terminals = await _licenseService.fetchTerminalsForLicense(
      rawLicenseKey: licenseKey,
      locationName: _selectedLocationName,
    );

    if (!mounted) return;
    setState(() {
      _loadingOptions = false;
      _availableTerminals = terminals;
      if (_selectedTerminalNumber == null ||
          !_availableTerminals.contains(_selectedTerminalNumber)) {
        _selectedTerminalNumber = _availableTerminals.isNotEmpty
            ? _availableTerminals.first
            : '0001';
      }
    });
  }

  Future<void> _activate() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await _licenseService.activateLicense(
      _licenseController.text,
      terminalNumber: _selectedTerminalNumber ?? '0001',
      locationName: _selectedLocationName,
    );
    if (!mounted) return;

    if (result.success) {
      _goToRegister();
      return;
    }

    if (result.requiresTerminalRegistration) {
      await _handleUnregisteredTerminalFlow();
      return;
    }

    setState(() {
      _busy = false;
      _error = result.errorMessage;
    });
  }

  Future<void> _handleUnregisteredTerminalFlow() async {
    final input = await _showUnregisteredTerminalDialog();
    if (!mounted) return;

    if (input == null) {
      setState(() {
        _busy = false;
        _error = 'Terminal is not registered for this device.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final lookup = await _licenseService.findOrganizationByNumberAndLicense(
      organizationNumber: input.organizationNumber,
      licenseKey: input.licenseKey,
    );

    if (!mounted) return;
    if (!lookup.found) {
      setState(() {
        _busy = false;
        _error = lookup.errorMessage ?? 'Organization lookup failed.';
      });
      return;
    }

    _licenseController.text = input.licenseKey;
    _organizationNumberController.text = input.organizationNumber;
    await _prefillActivationOptionsFromOrganization(lookup.organizationId);

    if (_availableLocations.isEmpty || _availableTerminals.isEmpty) {
      await _loadActivationOptions(force: true);
    }

    final registerResult = await _licenseService.activateLicense(
      input.licenseKey,
      terminalNumber: _selectedTerminalNumber ?? '0001',
      locationName: _selectedLocationName,
      allowTerminalRegistration: true,
    );

    if (!mounted) return;
    if (registerResult.success) {
      _goToRegister();
      return;
    }

    setState(() {
      _busy = false;
      _error = registerResult.errorMessage;
    });
  }

  Future<({String organizationNumber, String licenseKey})?>
  _showUnregisteredTerminalDialog() async {
    final organizationController = TextEditingController(
      text: _organizationNumberController.text.trim().isNotEmpty
          ? _organizationNumberController.text.trim()
          : SupabaseConfig.organizationNumber,
    );
    final licenseController = TextEditingController(
      text: _licenseController.text.trim(),
    );

    final result = await showDialog<({String organizationNumber, String licenseKey})>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Terminal Not Registered'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter organization number and license key to bind startup variables from Supabase and register this terminal.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: organizationController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Organization Number',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: licenseController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'License Key',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final organizationNumber = organizationController.text.trim();
              final licenseKey = licenseController.text.trim();
              if (organizationNumber.isEmpty || licenseKey.isEmpty) {
                return;
              }
              Navigator.pop(
                dialogContext,
                (
                  organizationNumber: organizationNumber,
                  licenseKey: licenseKey,
                ),
              );
            },
            child: const Text('Lookup and Register'),
          ),
        ],
      ),
    );

    organizationController.dispose();
    licenseController.dispose();
    return result;
  }

  Future<void> _prefillActivationOptionsFromOrganization(String organizationId) async {
    final locations = await _licenseService.fetchLocationsForOrganization(
      organizationId: organizationId,
    );

    final defineLocationName = SupabaseConfig.locationName.trim();
    String? nextLocation = _selectedLocationName;
    if (defineLocationName.isNotEmpty && locations.contains(defineLocationName)) {
      nextLocation = defineLocationName;
    } else if (nextLocation == null || !locations.contains(nextLocation)) {
      nextLocation = locations.isNotEmpty ? locations.first : null;
    }

    final terminals = await _licenseService.fetchTerminalsForOrganization(
      organizationId: organizationId,
      locationName: nextLocation,
    );

    final defineTerminalNumber = SupabaseConfig.terminalNumber.trim();
    String? nextTerminal = _selectedTerminalNumber;
    if (defineTerminalNumber.isNotEmpty && terminals.contains(defineTerminalNumber)) {
      nextTerminal = defineTerminalNumber;
    } else if (nextTerminal == null || !terminals.contains(nextTerminal)) {
      nextTerminal = terminals.isNotEmpty ? terminals.first : '0001';
    }

    if (!mounted) return;
    setState(() {
      _availableLocations = locations;
      _selectedLocationName = nextLocation;
      _availableTerminals = terminals.isNotEmpty ? terminals : const ['0001'];
      _selectedTerminalNumber = nextTerminal;
    });
  }

  void _goToRegister() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => buildRegisterVariantScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final leftGutterWidth = screenWidth >= 1200
        ? (screenWidth * 0.2).clamp(220.0, 420.0)
        : 0.0;

    return Scaffold(
      appBar: AppBar(title: const Text('License Activation')),
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
                      const Text(
                        'Enter the license key for this application install.',
                        style: TextStyle(fontSize: 16),
                      ),
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
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Application License Key',
                        ),
                        onSubmitted: (_) => _loadActivationOptions(force: true),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: (_busy || _loadingOptions)
                              ? null
                              : () => _loadActivationOptions(force: true),
                          child: _loadingOptions
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Load Location/Terminal Options'),
                        ),
                      ),
                      const SizedBox(height: 10),
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
                        onChanged: (_busy || _loadingOptions)
                            ? null
                            : (value) async {
                                setState(() {
                                  _selectedLocationName = value;
                                });
                                await _reloadTerminalsForSelectedLocation();
                              },
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        initialValue: _selectedTerminalNumber,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Terminal Number',
                        ),
                        items: _availableTerminals
                            .map(
                              (terminal) => DropdownMenuItem<String>(
                                value: terminal,
                                child: Text(terminal),
                              ),
                            )
                            .toList(),
                        onChanged: (_busy || _loadingOptions)
                            ? null
                            : (value) {
                                setState(() {
                                  _selectedTerminalNumber = value;
                                });
                              },
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
                              final messenger = ScaffoldMessenger.of(context);
                              await Clipboard.setData(
                                ClipboardData(text: _error!),
                              );
                              if (!mounted) return;
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text('Error copied to clipboard.'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('Copy Error'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _busy ? null : _activate,
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Activate License'),
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


