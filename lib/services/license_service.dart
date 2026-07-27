import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../supabase_config.dart';
import '../terminal_config.dart';
import 'supabase_service.dart';

class LicenseContext {
  final String organizationId;
  final String organizationNumber;
  final String organizationName;
  final String locationId;
  final String locationName;
  final String name;
  final String terminalId;
  final String terminalNumber;
  final String terminalName;
  final String licenseKey;
  final int terminalLicenses;
  final int terminalsActive;

  const LicenseContext({
    required this.organizationId,
    required this.organizationNumber,
    required this.organizationName,
    required this.locationId,
    required this.locationName,
    required this.name,
    required this.terminalId,
    required this.terminalNumber,
    required this.terminalName,
    required this.licenseKey,
    this.terminalLicenses = 0,
    this.terminalsActive = 0,
  });
}

class LicenseActivationResult {
  final bool success;
  final bool requiresInput;
  final bool requiresTerminalRegistration;
  final String? errorMessage;
  final LicenseContext? context;
  final String? attemptedLicenseKey;
  final String? attemptedTerminalNumber;
  final String? attemptedLocationName;
  final String defaultStaffId;
  final String defaultStaffName;

  const LicenseActivationResult({
    required this.success,
    this.requiresInput = false,
    this.requiresTerminalRegistration = false,
    this.errorMessage,
    this.context,
    this.attemptedLicenseKey,
    this.attemptedTerminalNumber,
    this.attemptedLocationName,
    this.defaultStaffId = '',
    this.defaultStaffName = '',
  });
}

class OrganizationLookupResult {
  final bool found;
  final String organizationId;
  final String organizationNumber;
  final String organizationName;
  final String? errorMessage;

  const OrganizationLookupResult({
    required this.found,
    this.organizationId = '',
    this.organizationNumber = '',
    this.organizationName = '',
    this.errorMessage,
  });
}

class OrganizationFieldsResult {
  final bool found;
  final Map<String, String> fields;
  final String? errorMessage;

  const OrganizationFieldsResult({
    required this.found,
    this.fields = const {},
    this.errorMessage,
  });
}

class _RpcActivationResult {
  final LicenseContext? context;
  final String? error;
  final bool requiresTerminalRegistration;
  final String spinTpn;
  final String spinAuthKey;
  final String cardReaderType;
  final String cardReaderHppAuthToken;
  final String defaultStaffId;
  final String defaultStaffName;

  const _RpcActivationResult({
    this.context,
    this.error,
    this.requiresTerminalRegistration = false,
    this.spinTpn = '',
    this.spinAuthKey = '',
    this.cardReaderType = '',
    this.cardReaderHppAuthToken = '',
    this.defaultStaffId = '',
    this.defaultStaffName = '',
  });
}

class LicenseService {
  static const _licenseStorageKey = 'app_license_key';
  static const _terminalStorageKey = 'app_terminal_number';
  static const _locationStorageKey = 'app_location_name';
  static const _deviceIdStorageKey = 'app_device_id';
  static const _deviceLabelStorageKey = 'app_device_label';
  static const _terminalTokenStorageKey = 'app_terminal_token';
  static const _spinTpnStorageKey = 'app_spin_tpn';
  static const _spinAuthKeyStorageKey = 'app_spin_auth_key';
  static LicenseContext? _activeContext;

  static const _licenseRecognizedButOrgHiddenMessage =
      'License key is recognized by the server, but organization lookup data is unavailable in this environment. Enter organization number and continue, or verify this install points to the correct Supabase project.';

  String _canonicalLicenseValue(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  List<String> _licenseCandidatesFromOrganization(
    Map<String, dynamic> organization,
  ) {
    return [
      organization['license_key']?.toString().trim() ?? '',
      organization['application_license_key']?.toString().trim() ?? '',
      organization['application_license_number']?.toString().trim() ?? '',
      organization['license_number']?.toString().trim() ?? '',
      organization['organization_number']?.toString().trim() ?? '',
    ].where((value) => value.isNotEmpty).toList();
  }

  bool _licenseValueMatchesInput(String input, String candidate) {
    final normalizedInput = input.trim();
    final normalizedCandidate = candidate.trim();
    if (normalizedInput.isEmpty || normalizedCandidate.isEmpty) return false;
    if (normalizedCandidate.toLowerCase() == normalizedInput.toLowerCase()) {
      return true;
    }
    return _canonicalLicenseValue(normalizedCandidate) ==
        _canonicalLicenseValue(normalizedInput);
  }

  String? _extractLikelyOrganizationNumber(String rawLicenseKey) {
    final canonical = _canonicalLicenseValue(rawLicenseKey);
    final match = RegExp(r'([0-9]{6})').firstMatch(canonical);
    return match?.group(1);
  }

  List<String> _backendLicenseProbeCandidates(String rawLicenseKey) {
    final normalized = rawLicenseKey.trim();
    if (normalized.isEmpty) return const [];

    final canonical = _canonicalLicenseValue(normalized);
    final inferredOrganizationNumber = _extractLikelyOrganizationNumber(
      normalized,
    );
    final candidates = <String>{
      normalized,
      normalized.toUpperCase(),
      normalized.toLowerCase(),
      canonical,
      ...?(inferredOrganizationNumber == null
          ? null
          : [inferredOrganizationNumber]),
      if (RegExp(r'^[0-9]{6}$').hasMatch(canonical)) canonical,
    };

    return candidates.where((value) => value.trim().isNotEmpty).toList();
  }

  Future<List<Map<String, dynamic>>> _fetchOrganizationsForLookup() async {
    try {
      final rpcRows = await SupabaseService.client.rpc(
        'list_organizations_from_app',
      );
      if (rpcRows is List) {
        return rpcRows
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
      }
    } catch (_) {}

    try {
      final rows = await SupabaseService.client
          .from('organizations')
          .select('*');
      return rows.map((row) => Map<String, dynamic>.from(row as Map)).toList();
    } catch (_) {}

    return const [];
  }

  Future<String?> _organizationLookupKeyById(String organizationId) async {
    final normalizedOrganizationId = organizationId.trim();
    if (normalizedOrganizationId.isEmpty) return null;

    final organizations = await _fetchOrganizationsForLookup();
    final match = organizations.firstWhere(
      (row) => (row['id']?.toString().trim() ?? '') == normalizedOrganizationId,
      orElse: () => const <String, dynamic>{},
    );
    if (match.isNotEmpty) {
      final licenseKey = match['license_key']?.toString().trim() ?? '';
      if (licenseKey.isNotEmpty) return licenseKey;

      final orgNumber = match['organization_number']?.toString().trim() ?? '';
      if (orgNumber.isNotEmpty) return orgNumber;
    }

    try {
      final rows = await SupabaseService.client
          .from('organizations')
          .select('license_key, organization_number')
          .eq('id', normalizedOrganizationId)
          .limit(1);
      if (rows.isNotEmpty) {
        final row = Map<String, dynamic>.from(rows.first as Map);
        final licenseKey = row['license_key']?.toString().trim() ?? '';
        if (licenseKey.isNotEmpty) return licenseKey;
        final orgNumber = row['organization_number']?.toString().trim() ?? '';
        if (orgNumber.isNotEmpty) return orgNumber;
      }
    } catch (_) {}

    return null;
  }

  Future<List<String>> _fetchLocationsViaLookupKey(String lookupKey) async {
    final normalizedLookupKey = lookupKey.trim();
    if (normalizedLookupKey.isEmpty) return const [];

    try {
      final response = await SupabaseService.client.rpc(
        'list_locations_for_license',
        params: {'p_license_key': normalizedLookupKey},
      );
      if (response is! List) return const [];

      final names =
          response
              .map(
                (row) =>
                    Map<String, dynamic>.from(
                      row as Map,
                    )['location_name']?.toString().trim() ??
                    '',
              )
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList()
            ..sort();

      return names;
    } catch (_) {
      return const [];
    }
  }

  bool _shouldAttemptLegacyActivationFallback(String? rpcError) {
    final text = (rpcError ?? '').toLowerCase();
    if (text.isEmpty) return true;
    return text.contains('p_allow_register') ||
        text.contains('does not exist') ||
        text.contains('not found') ||
        text.contains('pgrst202') ||
        text.contains('42883') ||
        text.contains('schema cache');
  }

  LicenseContext? get activeContext => _activeContext;

  Future<bool> isUpsertLocationRpcAvailable() async {
    try {
      await SupabaseService.client.rpc(
        'upsert_location_from_app',
        params: {
          'p_license_key': '__rpc_check__',
          'p_location_name': '__rpc_check__',
          'p_location_id': null,
        },
      );
      return true;
    } catch (error) {
      final text = error.toString().toLowerCase();
      if (text.contains('upsert_location_from_app') &&
          (text.contains('does not exist') ||
              text.contains('not found') ||
              text.contains('pgrst202') ||
              text.contains('42883'))) {
        return false;
      }
      return true;
    }
  }

  Future<String?> getStoredLicenseKey() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_licenseStorageKey)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> clearStoredLicenseKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_licenseStorageKey);
    await prefs.remove(_terminalStorageKey);
    await prefs.remove(_locationStorageKey);
    _activeContext = null;
  }

  /// Clears all locally stored activation state including credentials and
  /// device identity. Next startup will route through TerminalActivationScreen.
  Future<void> clearActivationState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_licenseStorageKey);
    await prefs.remove(_terminalStorageKey);
    await prefs.remove(_locationStorageKey);
    await prefs.remove(_spinTpnStorageKey);
    await prefs.remove(_spinAuthKeyStorageKey);
    await prefs.remove(_terminalTokenStorageKey);
    await prefs.remove(_deviceIdStorageKey);
    await prefs.remove(_deviceLabelStorageKey);
    _activeContext = null;
    TerminalConfig.clear();
  }

  Future<String?> releaseCurrentActivation({
    bool deactivateTerminal = true,
  }) async {
    final activeContext = _activeContext;
    final licenseKey = activeContext?.licenseKey.trim().isNotEmpty == true
        ? activeContext!.licenseKey.trim()
        : ((await getStoredLicenseKey()) ?? '').trim();
    final terminalNumber =
        activeContext?.terminalNumber.trim().isNotEmpty == true
        ? activeContext!.terminalNumber.trim()
        : ((await getStoredTerminalNumber()) ?? '').trim();
    final locationName = activeContext?.locationName.trim().isNotEmpty == true
        ? activeContext!.locationName.trim()
        : ((await getStoredLocationName()) ?? '').trim();
    final deviceId = ((await getStoredDeviceId()) ?? '').trim();

    if (licenseKey.isEmpty) {
      return 'No stored license context was available to release.';
    }

    try {
      await SupabaseService.client.rpc(
        'deactivate_install_license',
        params: {
          'p_license_key': licenseKey,
          if (terminalNumber.isNotEmpty) 'p_terminal_number': terminalNumber,
          if (locationName.isNotEmpty) 'p_location_name': locationName,
          if (deviceId.isNotEmpty) 'p_device_id': deviceId,
          'p_deactivate_terminal': deactivateTerminal,
        },
      );
      return null;
    } catch (error) {
      final text = error.toString().toLowerCase();
      if (text.contains('deactivate_install_license') &&
          (text.contains('does not exist') ||
              text.contains('not found') ||
              text.contains('pgrst202') ||
              text.contains('42883') ||
              text.contains('schema cache'))) {
        return 'Database release RPC is missing. Run the deactivate install migration, then retry.';
      }
      return 'Activation release failed: $error';
    }
  }

  Future<void> releaseAndClearActivationState({
    bool deactivateTerminal = true,
  }) async {
    final releaseError = await releaseCurrentActivation(
      deactivateTerminal: deactivateTerminal,
    );
    await clearActivationState();
    if (releaseError != null) {
      throw Exception(releaseError);
    }
  }

  Future<void> _storeLicenseKey(String licenseKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_licenseStorageKey, licenseKey);
  }

  Future<String?> getStoredTerminalNumber() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_terminalStorageKey)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<String?> getStoredLocationName() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_locationStorageKey)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<String?> getStoredDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_deviceIdStorageKey)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> _storeTerminalNumber(String terminalNumber) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_terminalStorageKey, terminalNumber);
  }

  Future<void> _storeLocationName(String locationName) async {
    final prefs = await SharedPreferences.getInstance();
    if (locationName.trim().isEmpty) {
      await prefs.remove(_locationStorageKey);
      return;
    }
    await prefs.setString(_locationStorageKey, locationName.trim());
  }

  Future<void> _storeSpinCredentials({
    required String spinTpn,
    required String spinAuthKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_spinTpnStorageKey, spinTpn.trim());
    await prefs.setString(_spinAuthKeyStorageKey, spinAuthKey.trim());
  }

  String _generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return [
      hex.substring(0, 8),
      hex.substring(8, 12),
      hex.substring(12, 16),
      hex.substring(16, 20),
      hex.substring(20, 32),
    ].join('-');
  }

  String _defaultDeviceLabel(String deviceId) {
    final suffix = deviceId.replaceAll('-', '');
    return 'Device ${suffix.substring(0, 8)}';
  }

  Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdStorageKey)?.trim();
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final deviceId = _generateDeviceId();
    await prefs.setString(_deviceIdStorageKey, deviceId);
    return deviceId;
  }

  Future<String> getOrCreateDeviceLabel() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceLabelStorageKey)?.trim();
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final deviceId = await getOrCreateDeviceId();
    final label = _defaultDeviceLabel(deviceId);
    await prefs.setString(_deviceLabelStorageKey, label);
    return label;
  }

  Future<void> _seedDeviceIdentityFromDefines() async {
    final defineDeviceId = SupabaseConfig.appDeviceId.trim();
    final defineDeviceLabel = SupabaseConfig.appDeviceLabel.trim();
    if (defineDeviceId.isEmpty && defineDeviceLabel.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();

    if (defineDeviceId.isNotEmpty) {
      await prefs.setString(_deviceIdStorageKey, defineDeviceId);
      if (defineDeviceLabel.isEmpty) {
        await prefs.setString(
          _deviceLabelStorageKey,
          _defaultDeviceLabel(defineDeviceId),
        );
      }
    }

    if (defineDeviceLabel.isNotEmpty) {
      await prefs.setString(_deviceLabelStorageKey, defineDeviceLabel);
    }
  }

  Future<List<Map<String, String>>> fetchLocationOptionsForLicense(
    String rawLicenseKey,
  ) async {
    final licenseKey = rawLicenseKey.trim();
    if (licenseKey.isEmpty) return const [];

    try {
      var response = await SupabaseService.client.rpc(
        'list_locations_for_license',
        params: {'p_license_key': licenseKey},
      );

      if (response is List && response.isEmpty) {
        await _ensureDefaultsForSelectors(licenseKey: licenseKey);
        response = await SupabaseService.client.rpc(
          'list_locations_for_license',
          params: {'p_license_key': licenseKey},
        );
      }

      if (response is! List) return const [];

      final options = <Map<String, String>>[];
      final seenIds = <String>{};
      for (final item in response) {
        final row = Map<String, dynamic>.from(item as Map);
        final id = row['location_id']?.toString().trim() ?? '';
        final name = row['location_name']?.toString().trim() ?? '';
        if (id.isEmpty || name.isEmpty) continue;
        if (seenIds.add(id)) {
          options.add({'id': id, 'name': name});
        }
      }

      options.sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
      return options;
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> fetchLocationsForLicense(String rawLicenseKey) async {
    final options = await fetchLocationOptionsForLicense(rawLicenseKey);
    return options
        .map((option) => option['name'] ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
  }

  Future<List<String>> fetchTerminalsForLicense({
    required String rawLicenseKey,
    String? locationName,
  }) async {
    final licenseKey = rawLicenseKey.trim();
    final normalizedLocation = (locationName ?? '').trim();
    if (licenseKey.isEmpty) return const [];

    try {
      var response = await SupabaseService.client.rpc(
        'list_terminals_for_license',
        params: {
          'p_license_key': licenseKey,
          if (normalizedLocation.isNotEmpty)
            'p_location_name': normalizedLocation,
        },
      );

      if (response is List && response.isEmpty) {
        await _ensureDefaultsForSelectors(
          licenseKey: licenseKey,
          locationName: normalizedLocation,
        );
        response = await SupabaseService.client.rpc(
          'list_terminals_for_license',
          params: {
            'p_license_key': licenseKey,
            if (normalizedLocation.isNotEmpty)
              'p_location_name': normalizedLocation,
          },
        );
      }

      if (response is! List) return const ['0001'];

      final numbers =
          response
              .map(
                (row) =>
                    Map<String, dynamic>.from(
                      row as Map,
                    )['terminal_number']?.toString().trim() ??
                    '',
              )
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList()
            ..sort();

      if (numbers.isEmpty) return const ['0001'];
      return numbers;
    } catch (_) {
      return const ['0001'];
    }
  }

  Future<List<String>> fetchLocationsForOrganization({
    required String organizationId,
  }) async {
    final normalizedOrganizationId = organizationId.trim();
    if (normalizedOrganizationId.isEmpty) return const [];

    try {
      final rows = await SupabaseService.client
          .from('locations')
          .select('name')
          .eq('organization_id', normalizedOrganizationId)
          .limit(500);

      final names =
          rows
              .map(
                (row) =>
                    Map<String, dynamic>.from(
                      row as Map,
                    )['name']?.toString().trim() ??
                    '',
              )
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList()
            ..sort();

      if (names.isNotEmpty) return names;
    } catch (_) {}

    final lookupKey = await _organizationLookupKeyById(
      normalizedOrganizationId,
    );
    if (lookupKey == null || lookupKey.isEmpty) return const [];
    return _fetchLocationsViaLookupKey(lookupKey);
  }

  Future<List<String>> fetchOrCreateLocationsForOrganization({
    required String organizationId,
  }) async {
    final normalizedOrganizationId = organizationId.trim();
    if (normalizedOrganizationId.isEmpty) return const [];

    final existing = await fetchLocationsForOrganization(
      organizationId: normalizedOrganizationId,
    );
    if (existing.isNotEmpty) return existing;

    try {
      await SupabaseService.client.from('locations').insert({
        'organization_id': normalizedOrganizationId,
        'name': 'Default Location',
      });
    } catch (_) {
      // Try the app-safe RPC when direct insert fails (for example due to RLS).
      final lookupKey = await _organizationLookupKeyById(
        normalizedOrganizationId,
      );
      if (lookupKey != null && lookupKey.isNotEmpty) {
        try {
          await SupabaseService.client.rpc(
            'upsert_location_from_app',
            params: {
              'p_license_key': lookupKey,
              'p_location_name': 'Default Location',
            },
          );
        } catch (_) {
          // Re-read below; caller surfaces final error if still empty.
        }
      }
    }

    return fetchLocationsForOrganization(
      organizationId: normalizedOrganizationId,
    );
  }

  Future<List<String>> fetchTerminalsForOrganization({
    required String organizationId,
    String? locationName,
  }) async {
    final normalizedOrganizationId = organizationId.trim();
    final normalizedLocationName = (locationName ?? '').trim();
    if (normalizedOrganizationId.isEmpty) return const ['0001'];

    try {
      String? locationId;
      if (normalizedLocationName.isNotEmpty) {
        final locationRows = await SupabaseService.client
            .from('locations')
            .select('id')
            .eq('organization_id', normalizedOrganizationId)
            .ilike('name', normalizedLocationName)
            .limit(1);

        if (locationRows.isNotEmpty) {
          locationId = Map<String, dynamic>.from(
            locationRows.first as Map,
          )['id']?.toString();
        }
      }

      var query = SupabaseService.client
          .from('terminals')
          .select('terminal_number')
          .eq('organization_id', normalizedOrganizationId);

      if (locationId != null && locationId.isNotEmpty) {
        query = query.eq('location_id', locationId);
      }

      final rows = await query.limit(500);
      final numbers =
          rows
              .map(
                (row) =>
                    Map<String, dynamic>.from(
                      row as Map,
                    )['terminal_number']?.toString().trim() ??
                    '',
              )
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList()
            ..sort();

      if (numbers.isEmpty) return const ['0001'];
      return numbers;
    } catch (_) {
      return const ['0001'];
    }
  }

  Future<bool> isTerminalNumberInUse({
    required String organizationId,
    required String terminalNumber,
    String? locationName,
  }) async {
    final normalizedTerminalNumber = terminalNumber.trim();
    if (normalizedTerminalNumber.isEmpty) return false;

    // Use list_terminals_from_app RPC — anon-callable, bypasses RLS.
    // We need the license key, which we can get from stored/define.
    final licenseKey =
        (await getStoredLicenseKey() ?? SupabaseConfig.appLicenseKey).trim();
    if (licenseKey.isEmpty) return false;

    try {
      final rows = await SupabaseService.client.rpc(
        'list_terminals_from_app',
        params: {
          'p_license_key': licenseKey,
          if ((locationName ?? '').trim().isNotEmpty)
            'p_location_name': locationName!.trim(),
        },
      );
      if (rows is! List) return false;
      return rows.any((row) {
        final num =
            Map<String, dynamic>.from(
              row as Map,
            )['terminal_number']?.toString().trim() ??
            '';
        return num == normalizedTerminalNumber;
      });
    } catch (_) {
      return false;
    }
  }

  Future<OrganizationLookupResult> findOrganizationByNumberAndLicense({
    required String organizationNumber,
    required String licenseKey,
  }) async {
    final normalizedOrganizationNumber = organizationNumber.trim();
    final normalizedLicenseKey = licenseKey.trim();

    if (normalizedOrganizationNumber.isEmpty || normalizedLicenseKey.isEmpty) {
      return const OrganizationLookupResult(
        found: false,
        errorMessage: 'Organization number and license key are required.',
      );
    }

    try {
      final allOrgs = await _fetchOrganizationsForLookup();
      final rows = allOrgs
          .where(
            (organization) =>
                (organization['organization_number']?.toString().trim() ??
                    '') ==
                normalizedOrganizationNumber,
          )
          .toList();

      if (rows.isEmpty) {
        return const OrganizationLookupResult(
          found: false,
          errorMessage: 'Organization number was not found.',
        );
      }

      final organization = Map<String, dynamic>.from(rows.first as Map);
      final candidates = _licenseCandidatesFromOrganization(organization);
      final matchesLicense = candidates.any(
        (value) => _licenseValueMatchesInput(normalizedLicenseKey, value),
      );

      if (!matchesLicense) {
        return const OrganizationLookupResult(
          found: false,
          errorMessage: 'License key does not match that organization number.',
        );
      }

      return OrganizationLookupResult(
        found: true,
        organizationId: organization['id']?.toString() ?? '',
        organizationNumber:
            organization['organization_number']?.toString() ?? '',
        organizationName: organization['name']?.toString() ?? '',
      );
    } catch (error) {
      return OrganizationLookupResult(
        found: false,
        errorMessage: 'Organization lookup failed: $error',
      );
    }
  }

  Future<OrganizationFieldsResult> findOrganizationByLicenseKey({
    required String licenseKey,
  }) async {
    final normalized = licenseKey.trim();
    if (normalized.isEmpty) {
      return const OrganizationFieldsResult(
        found: false,
        errorMessage: 'License key is required.',
      );
    }
    try {
      final rows = await _fetchOrganizationsForLookup();

      final match = rows.where((org) {
        final candidates = _licenseCandidatesFromOrganization(org);
        return candidates.any(
          (value) => _licenseValueMatchesInput(normalized, value),
        );
      }).firstOrNull;

      if (match == null) {
        final backendRecognized = await _isLicenseRecognizedByBackend(
          normalized,
        );
        if (backendRecognized) {
          final fields = <String, String>{};
          final inferredOrganizationNumber = _extractLikelyOrganizationNumber(
            normalized,
          );
          if (inferredOrganizationNumber != null) {
            fields['organization_number'] = inferredOrganizationNumber;
          }
          return OrganizationFieldsResult(
            found: fields.isNotEmpty,
            fields: fields,
            errorMessage: fields.isEmpty
                ? _licenseRecognizedButOrgHiddenMessage
                : null,
          );
        }
        return const OrganizationFieldsResult(
          found: false,
          errorMessage: 'No organization found with this license key.',
        );
      }

      final fields = <String, String>{};
      for (final entry in match.entries) {
        if (entry.value != null) {
          fields[entry.key] = entry.value.toString();
        }
      }
      return OrganizationFieldsResult(found: true, fields: fields);
    } catch (error) {
      return OrganizationFieldsResult(
        found: false,
        errorMessage: 'License lookup failed: $error',
      );
    }
  }

  Future<bool> _isLicenseRecognizedByBackend(String licenseKey) async {
    final normalized = licenseKey.trim();
    if (normalized.isEmpty) return false;

    final probeCandidates = _backendLicenseProbeCandidates(normalized);
    var sawInvalidLicenseResponse = false;

    for (final candidate in probeCandidates) {
      try {
        final response = await SupabaseService.client.rpc(
          'list_locations_for_license',
          params: {'p_license_key': candidate},
        );
        if (response is List && response.isNotEmpty) {
          return true;
        }
      } catch (_) {
        // Fall through to activation probe for older/missing lookup RPCs.
      }

      try {
        final response = await SupabaseService.client.rpc(
          'activate_install_license',
          params: {
            'p_license_key': candidate,
            'p_terminal_number': '0001',
            'p_location_name': '',
            'p_allow_register': false,
          },
        );
        if (response is List && response.isNotEmpty) {
          return true;
        }
      } catch (error) {
        final text = error.toString().toLowerCase();
        if (text.contains('no terminal is registered to this device') ||
            text.contains('terminal is not registered') ||
            text.contains('terminal 0001 is inactive') ||
            text.contains('is inactive')) {
          return true;
        }
        if (text.contains('invalid license key')) {
          sawInvalidLicenseResponse = true;
        }
      }
    }

    if (sawInvalidLicenseResponse) return false;
    return false;
  }

  Future<bool> isLicenseRecognizedByBackend(String licenseKey) {
    return _isLicenseRecognizedByBackend(licenseKey);
  }

  Future<String> _resolvePreferredLicenseKeyForRpc(String rawLicenseKey) async {
    final normalized = rawLicenseKey.trim();
    if (normalized.isEmpty) return normalized;

    try {
      final rows = await _fetchOrganizationsForLookup();
      final match = rows.where((org) {
        final candidates = _licenseCandidatesFromOrganization(org);
        return candidates.any(
          (value) => _licenseValueMatchesInput(normalized, value),
        );
      }).firstOrNull;

      if (match != null) {
        final preferred =
            (match['license_key']?.toString().trim() ?? '').isNotEmpty
            ? match['license_key']!.toString().trim()
            : (match['organization_number']?.toString().trim() ?? '');
        if (preferred.isNotEmpty) return preferred;
      }
    } catch (_) {
      // Continue to RPC probes below.
    }

    final probeCandidates = _backendLicenseProbeCandidates(normalized);
    for (final candidate in probeCandidates) {
      try {
        final response = await SupabaseService.client.rpc(
          'list_locations_for_license',
          params: {'p_license_key': candidate},
        );
        if (response is List && response.isNotEmpty) {
          return candidate;
        }
      } catch (_) {
        // Keep probing candidates; fallback to original input below.
      }
    }

    return normalized;
  }

  Future<void> _ensureDefaultsForSelectors({
    required String licenseKey,
    String locationName = '',
  }) async {
    try {
      await SupabaseService.client.rpc(
        'activate_install_license',
        params: {
          'p_license_key': licenseKey,
          'p_terminal_number': '0001',
          'p_location_name': locationName.trim(),
        },
      );
    } catch (_) {}
  }

  Future<LicenseActivationResult> initializeFromStoredOrDefine() async {
    // Seed persisted device identity from launcher defines before any restore calls.
    await _seedDeviceIdentityFromDefines();

    // If a terminal token was persisted from a previous ?tk= resolution,
    // use it to re-resolve - this guarantees full context including payment
    // credentials without requiring ?tk= in the URL on every visit.
    final storedToken = await getStoredTerminalToken();
    if (storedToken != null && storedToken.isNotEmpty) {
      final tokenResult = await resolveFromUrlToken(storedToken);
      if (tokenResult.success) return tokenResult;
      // Token expired or terminal deactivated — clear it and fall through
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_terminalTokenStorageKey);
      await prefs.remove(_spinTpnStorageKey);
      await prefs.remove(_spinAuthKeyStorageKey);
    }

    // Restore payment credentials that were persisted (non-token activation path)
    final credsPrefs = await SharedPreferences.getInstance();
    final storedSpinTpn =
        credsPrefs.getString(_spinTpnStorageKey)?.trim() ?? '';
    final storedSpinAuthKey =
        credsPrefs.getString(_spinAuthKeyStorageKey)?.trim() ?? '';
    if (storedSpinTpn.isNotEmpty || storedSpinAuthKey.isNotEmpty) {
      TerminalConfig.applyFromTerminalRecord(
        spinTpn: storedSpinTpn,
        spinAuthKey: storedSpinAuthKey,
      );
    }

    // Backend-first restore path: if this install/device was previously
    // registered, recover full startup context directly from Supabase.
    final backendDeviceResult = await _initializeFromRegisteredDevice();
    if (backendDeviceResult.success) {
      return backendDeviceResult;
    }

    final defineKey = SupabaseConfig.appLicenseKey.trim();
    final defineTerminal = SupabaseConfig.terminalNumber.trim();
    final defineLocation = SupabaseConfig.locationName.trim();
    final storedKey = await getStoredLicenseKey();
    final storedTerminal = await getStoredTerminalNumber();
    final storedLocation = await getStoredLocationName();
    final licenseKeyToUse = defineKey.isNotEmpty
        ? defineKey
        : (storedKey ?? '');
    final terminalNumberToUse = defineTerminal.isNotEmpty
        ? defineTerminal
        : (storedTerminal?.isNotEmpty == true ? storedTerminal! : '0001');
    final locationNameToUse = defineLocation.isNotEmpty
        ? defineLocation
        : (storedLocation ?? '');
    // Launcher-provided identity should be allowed to bind this machine on first run.
    final allowRegisterFromStartupDefines =
        defineKey.isNotEmpty ||
        defineTerminal.isNotEmpty ||
        defineLocation.isNotEmpty;

    if (licenseKeyToUse.isEmpty) {
      return LicenseActivationResult(
        success: false,
        requiresInput: true,
        errorMessage:
            'Enter your application license key to activate this install.',
        attemptedTerminalNumber: terminalNumberToUse,
      );
    }

    // Use activateLicense directly — it calls the RPC (which is anon-callable)
    // rather than direct table queries that RLS blocks for anon users.
    final result = await activateLicense(
      licenseKeyToUse,
      terminalNumber: terminalNumberToUse,
      locationName: locationNameToUse,
      allowTerminalRegistration: allowRegisterFromStartupDefines,
    );
    return LicenseActivationResult(
      success: result.success,
      requiresInput: !result.success,
      requiresTerminalRegistration: result.requiresTerminalRegistration,
      errorMessage: result.errorMessage,
      context: result.context,
      attemptedLicenseKey: licenseKeyToUse,
      attemptedTerminalNumber: terminalNumberToUse,
      attemptedLocationName: locationNameToUse,
    );
  }

  Future<LicenseActivationResult> _initializeFromRegisteredDevice() async {
    final deviceId = await getOrCreateDeviceId();
    final deviceLabel = await getOrCreateDeviceLabel();
    final rpcResult = await _resolveInstallFromDeviceRpc(
      deviceId: deviceId,
      deviceLabel: deviceLabel,
    );

    if (rpcResult.context == null) {
      return const LicenseActivationResult(
        success: false,
        requiresInput: false,
      );
    }

    final context = rpcResult.context!;
    await _storeLicenseKey(context.licenseKey);
    await _storeTerminalNumber(context.terminalNumber);
    await _storeLocationName(context.locationName);
    await _storeSpinCredentials(
      spinTpn: rpcResult.spinTpn,
      spinAuthKey: rpcResult.spinAuthKey,
    );
    TerminalConfig.applyFromTerminalRecord(
      spinTpn: rpcResult.spinTpn,
      spinAuthKey: rpcResult.spinAuthKey,
      cardReaderType: rpcResult.cardReaderType,
      cardReaderHppAuthToken: rpcResult.cardReaderHppAuthToken,
    );
    _activeContext = context;
    await TerminalConfig.loadForTerminalId(
      context.terminalId,
      terminalNumber: context.terminalNumber,
    );
    if (TerminalConfig.cardReaderHppAuthToken.trim().isEmpty) {
      await _hydrateCardReaderConfigFromLicenseRpc(context);
    }

    return LicenseActivationResult(
      success: true,
      context: context,
      attemptedLicenseKey: context.licenseKey,
      attemptedTerminalNumber: context.terminalNumber,
      attemptedLocationName: context.locationName,
      requiresTerminalRegistration: false,
    );
  }

  Future<LicenseActivationResult> activateLicense(
    String rawLicenseKey, {
    String? terminalNumber,
    String? terminalName,
    String? locationName,
    String? masterPin,
    bool allowTerminalRegistration = false,
  }) async {
    final licenseKey = rawLicenseKey.trim();
    final resolvedTerminalNumber =
        (terminalNumber ?? SupabaseConfig.terminalNumber).trim().isNotEmpty
        ? (terminalNumber ?? SupabaseConfig.terminalNumber).trim()
        : '0001';
    final resolvedLocationName = (locationName ?? '').trim();
    if (licenseKey.isEmpty) {
      return LicenseActivationResult(
        success: false,
        requiresInput: true,
        errorMessage: 'License key is required.',
        attemptedTerminalNumber: resolvedTerminalNumber,
        attemptedLocationName: resolvedLocationName,
      );
    }

    final rpcLicenseKey = await _resolvePreferredLicenseKeyForRpc(licenseKey);

    final deviceId = await getOrCreateDeviceId();
    final deviceLabel = await getOrCreateDeviceLabel();

    try {
      final rpcResult = await _activateViaRpc(
        licenseKey: rpcLicenseKey,
        terminalNumber: resolvedTerminalNumber,
        terminalName: (terminalName ?? '').trim(),
        locationName: resolvedLocationName,
        deviceId: deviceId,
        deviceLabel: deviceLabel,
        masterPin: (masterPin ?? '').trim(),
        allowTerminalRegistration: allowTerminalRegistration,
      );
      if (rpcResult.context != null) {
        await _storeLicenseKey(rpcLicenseKey);
        await _storeTerminalNumber(rpcResult.context!.terminalNumber);
        await _storeLocationName(rpcResult.context!.locationName);
        // Persist payment credentials so they survive page reloads
        await _storeSpinCredentials(
          spinTpn: rpcResult.spinTpn,
          spinAuthKey: rpcResult.spinAuthKey,
        );
        TerminalConfig.applyFromTerminalRecord(
          spinTpn: rpcResult.spinTpn,
          spinAuthKey: rpcResult.spinAuthKey,
          cardReaderType: rpcResult.cardReaderType,
          cardReaderHppAuthToken: rpcResult.cardReaderHppAuthToken,
        );
        _activeContext = rpcResult.context;
        await TerminalConfig.loadForTerminalId(
          rpcResult.context!.terminalId,
          terminalNumber: rpcResult.context!.terminalNumber,
        );
        if (TerminalConfig.cardReaderHppAuthToken.trim().isEmpty) {
          await _hydrateCardReaderConfigFromLicenseRpc(rpcResult.context!);
        }
        return LicenseActivationResult(
          success: true,
          context: _activeContext,
          attemptedLicenseKey: rpcLicenseKey,
          attemptedTerminalNumber: resolvedTerminalNumber,
          attemptedLocationName: resolvedLocationName,
          requiresTerminalRegistration: false,
          defaultStaffId: rpcResult.defaultStaffId,
          defaultStaffName: rpcResult.defaultStaffName,
        );
      }

      if (!_shouldAttemptLegacyActivationFallback(rpcResult.error)) {
        return LicenseActivationResult(
          success: false,
          requiresInput: true,
          attemptedLicenseKey: licenseKey,
          attemptedTerminalNumber: resolvedTerminalNumber,
          attemptedLocationName: resolvedLocationName,
          requiresTerminalRegistration: rpcResult.requiresTerminalRegistration,
          errorMessage: rpcResult.error != null
              ? 'License activation RPC failed: ${rpcResult.error}'
              : 'License activation failed.',
        );
      }

      LicenseActivationResult legacyResult;
      try {
        legacyResult = await _activateViaDirectTables(
          licenseKey: rpcLicenseKey,
          terminalNumber: resolvedTerminalNumber,
          locationName: resolvedLocationName,
          deviceId: deviceId,
          deviceLabel: deviceLabel,
        );
      } catch (error) {
        return LicenseActivationResult(
          success: false,
          requiresInput: true,
          attemptedLicenseKey: licenseKey,
          attemptedTerminalNumber: resolvedTerminalNumber,
          attemptedLocationName: resolvedLocationName,
          requiresTerminalRegistration: rpcResult.requiresTerminalRegistration,
          errorMessage: rpcResult.error != null
              ? 'License activation RPC failed: ${rpcResult.error}. Fallback read failed: $error'
              : 'License activation failed: $error',
        );
      }

      if (!legacyResult.success && rpcResult.error != null) {
        return LicenseActivationResult(
          success: false,
          requiresInput: true,
          attemptedLicenseKey: licenseKey,
          attemptedTerminalNumber: resolvedTerminalNumber,
          attemptedLocationName: resolvedLocationName,
          requiresTerminalRegistration: rpcResult.requiresTerminalRegistration,
          errorMessage:
              'License activation RPC failed: ${rpcResult.error}. ${legacyResult.errorMessage ?? ''}'
                  .trim(),
        );
      }

      if (legacyResult.success) {
        await _storeLicenseKey(rpcLicenseKey);
        await _storeTerminalNumber(
          legacyResult.context?.terminalNumber ?? resolvedTerminalNumber,
        );
        await _storeLocationName(
          legacyResult.context?.locationName ?? resolvedLocationName,
        );
      }
      return legacyResult;
    } catch (error) {
      return LicenseActivationResult(
        success: false,
        requiresInput: true,
        requiresTerminalRegistration: false,
        errorMessage: 'License validation failed: $error',
        attemptedLicenseKey: licenseKey,
        attemptedTerminalNumber: resolvedTerminalNumber,
        attemptedLocationName: resolvedLocationName,
      );
    }
  }

  Future<_RpcActivationResult> _activateViaRpc({
    required String licenseKey,
    required String terminalNumber,
    String terminalName = '',
    required String locationName,
    required String deviceId,
    required String deviceLabel,
    String masterPin = '',
    required bool allowTerminalRegistration,
  }) async {
    final client = SupabaseService.client;

    try {
      dynamic response;
      try {
        response = await client.rpc(
          'activate_install_license',
          params: {
            'p_license_key': licenseKey,
            'p_terminal_number': terminalNumber,
            'p_location_name': locationName,
            'p_device_id': deviceId,
            'p_device_label': deviceLabel,
            'p_allow_register': allowTerminalRegistration,
            if (terminalName.isNotEmpty) 'p_terminal_name': terminalName,
            if (masterPin.isNotEmpty) 'p_master_pin': masterPin,
          },
        );
      } catch (error) {
        final text = error.toString().toLowerCase();
        final isLegacySignature =
            text.contains('p_allow_register') ||
            text.contains('p_terminal_name') ||
            text.contains('p_master_pin') ||
            text.contains('does not exist') ||
            text.contains('not found') ||
            text.contains('pgrst202') ||
            text.contains('42883');
        if (!isLegacySignature) {
          rethrow;
        }

        response = await client.rpc(
          'activate_install_license',
          params: {
            'p_license_key': licenseKey,
            'p_terminal_number': terminalNumber,
            'p_location_name': locationName,
            'p_device_id': deviceId,
            'p_device_label': deviceLabel,
          },
        );
      }

      if (response is! List || response.isEmpty) {
        return const _RpcActivationResult(
          error:
              'RPC returned no rows. Run updated license_setup.sql and verify organization license key.',
        );
      }

      final row = Map<String, dynamic>.from(response.first as Map);
      final context = _contextFromRpcRow(
        row,
        fallbackLicenseKey: licenseKey,
        fallbackTerminalNumber: terminalNumber,
      );
      final spinTpn = row['spin_tpn']?.toString().trim() ?? '';
      final spinAuthKey = row['spin_auth_key']?.toString().trim() ?? '';
      final cardReaderType = row['card_reader_type']?.toString().trim() ?? '';
      final cardReaderHppAuthToken =
          row['card_reader_hpp_auth_token']?.toString().trim() ?? '';
      final defaultStaffId = row['default_staff_id']?.toString().trim() ?? '';
      final defaultStaffName =
          row['default_staff_name']?.toString().trim() ?? '';

      if (context == null) {
        return const _RpcActivationResult(
          error: 'RPC returned incomplete organization or terminal context.',
        );
      }

      return _RpcActivationResult(
        spinTpn: spinTpn,
        spinAuthKey: spinAuthKey,
        cardReaderType: cardReaderType,
        cardReaderHppAuthToken: cardReaderHppAuthToken,
        defaultStaffId: defaultStaffId,
        defaultStaffName: defaultStaffName,
        context: context,
      );
    } catch (error) {
      final text = error.toString();
      final normalized = text.toLowerCase();
      final needsTerminalRegistration =
          normalized.contains('no terminal is registered to this device') ||
          normalized.contains('terminal is not registered') ||
          normalized.contains('terminal 0001 is inactive') ||
          normalized.contains('is inactive');
      return _RpcActivationResult(
        error: text,
        requiresTerminalRegistration: needsTerminalRegistration,
      );
    }
  }

  Future<_RpcActivationResult> _resolveInstallFromDeviceRpc({
    required String deviceId,
    required String deviceLabel,
  }) async {
    try {
      final response = await SupabaseService.client.rpc(
        'resolve_install_from_device',
        params: {'p_device_id': deviceId, 'p_device_label': deviceLabel},
      );

      if (response is! List || response.isEmpty) {
        return const _RpcActivationResult(
          error: 'No terminal registered for this device.',
        );
      }

      final row = Map<String, dynamic>.from(response.first as Map);
      final context = _contextFromRpcRow(row);
      if (context == null) {
        return const _RpcActivationResult(
          error: 'RPC returned incomplete organization or terminal context.',
        );
      }

      return _RpcActivationResult(
        context: context,
        spinTpn: row['spin_tpn']?.toString().trim() ?? '',
        spinAuthKey: row['spin_auth_key']?.toString().trim() ?? '',
        cardReaderType: row['card_reader_type']?.toString().trim() ?? '',
        cardReaderHppAuthToken:
            row['card_reader_hpp_auth_token']?.toString().trim() ?? '',
      );
    } catch (_) {
      // RPC may not exist on older schema versions.
      return const _RpcActivationResult(
        error: 'Device bootstrap RPC unavailable.',
      );
    }
  }

  LicenseContext? _contextFromRpcRow(
    Map<String, dynamic> row, {
    String fallbackLicenseKey = '',
    String fallbackTerminalNumber = '0001',
  }) {
    final organizationId = row['organization_id']?.toString() ?? '';
    final organizationNumber = row['organization_number']?.toString() ?? '';
    final organizationName = row['organization_name']?.toString() ?? '';
    final locationId = row['location_id']?.toString() ?? '';
    final locationName = row['location_name']?.toString() ?? '';
    final name = row['name']?.toString() ?? locationName;
    final terminalId = row['terminal_id']?.toString() ?? '';
    final terminalNumber =
        row['terminal_number']?.toString() ?? fallbackTerminalNumber;
    final terminalName =
        row['terminal_name']?.toString() ?? 'Terminal $terminalNumber';
    final terminalLicenses =
        int.tryParse((row['terminal_licenses'] ?? '').toString()) ?? 0;
    final terminalsActive =
        int.tryParse((row['terminals_active'] ?? '').toString()) ?? 0;
    final licenseKey = (row['license_key']?.toString() ?? '').trim().isNotEmpty
        ? row['license_key']!.toString().trim()
        : fallbackLicenseKey;

    if (organizationId.isEmpty ||
        organizationNumber.isEmpty ||
        locationId.isEmpty ||
        terminalId.isEmpty) {
      return null;
    }

    return LicenseContext(
      organizationId: organizationId,
      organizationNumber: organizationNumber,
      organizationName: organizationName,
      locationId: locationId,
      locationName: locationName,
      name: name,
      terminalId: terminalId,
      terminalNumber: terminalNumber,
      terminalName: terminalName,
      licenseKey: licenseKey,
      terminalLicenses: terminalLicenses,
      terminalsActive: terminalsActive,
    );
  }

  Future<LicenseActivationResult> _activateViaDirectTables({
    required String licenseKey,
    required String terminalNumber,
    required String locationName,
    required String deviceId,
    required String deviceLabel,
  }) async {
    final client = SupabaseService.client;
    final organizationRows = await client
        .from('organizations')
        .select('*')
        .limit(500);

    final organization = _findOrganizationByLicense(
      List<Map<String, dynamic>>.from(organizationRows),
      licenseKey,
    );

    if (organization == null) {
      return const LicenseActivationResult(
        success: false,
        requiresInput: true,
        errorMessage: 'Invalid license key. Organization not found.',
      );
    }

    final organizationId = organization['id']?.toString() ?? '';
    final organizationNumber =
        organization['organization_number']?.toString() ?? '';
    if (organizationId.isEmpty || organizationNumber.isEmpty) {
      return const LicenseActivationResult(
        success: false,
        requiresInput: true,
        errorMessage:
            'Organization is missing required fields. Ensure organization has id and organization_number.',
      );
    }

    final terminal = await _findOrCreateTerminal(
      organizationId: organizationId,
      organizationNumber: organizationNumber,
      terminalNumber: terminalNumber,
      locationName: locationName,
    );

    if (terminal == null) {
      return const LicenseActivationResult(
        success: false,
        requiresInput: true,
        errorMessage:
            'Unable to resolve terminal for this install. Check terminals/location setup and terminal_number.',
      );
    }

    await _storeLicenseOnTerminal(
      terminalId: terminal['id']?.toString() ?? '',
      licenseKey: licenseKey,
    );

    final terminalName =
        terminal['terminal_name']?.toString() ??
        terminal['name']?.toString() ??
        terminal['code']?.toString() ??
        'Terminal $terminalNumber';

    String resolvedLocationName = locationName;
    final resolvedLocationId = terminal['location_id']?.toString() ?? '';
    if (resolvedLocationId.isNotEmpty) {
      try {
        final locationRows = await client
            .from('locations')
            .select('name')
            .eq('id', resolvedLocationId)
            .limit(1);
        if (locationRows.isNotEmpty) {
          final locationRow = Map<String, dynamic>.from(
            locationRows.first as Map,
          );
          resolvedLocationName =
              locationRow['name']?.toString() ?? resolvedLocationName;
        }
      } catch (_) {}
    }

    _activeContext = LicenseContext(
      organizationId: organizationId,
      organizationNumber: organizationNumber,
      organizationName: organization['name']?.toString() ?? '',
      locationId: resolvedLocationId,
      locationName: resolvedLocationName,
      name: resolvedLocationName,
      terminalId: terminal['id']?.toString() ?? '',
      terminalNumber: terminalNumber,
      terminalName: terminalName,
      licenseKey: licenseKey,
    );

    return LicenseActivationResult(
      success: true,
      context: _activeContext,
      attemptedLicenseKey: licenseKey,
      attemptedTerminalNumber: terminalNumber,
      attemptedLocationName: locationName,
    );
  }

  Map<String, dynamic>? _findOrganizationByLicense(
    List<Map<String, dynamic>> organizations,
    String licenseKey,
  ) {
    for (final row in organizations) {
      final candidates = [
        row['license_key']?.toString(),
        row['application_license_key']?.toString(),
        row['organization_number']?.toString(),
      ];

      final matched = candidates.any(
        (value) =>
            value != null &&
            value.trim().isNotEmpty &&
            value.trim() == licenseKey,
      );
      if (matched) return row;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _findOrCreateTerminal({
    required String organizationId,
    required String organizationNumber,
    required String terminalNumber,
    required String locationName,
  }) async {
    final client = SupabaseService.client;

    String? locationId;
    if (locationName.trim().isNotEmpty) {
      final filteredLocations = await client
          .from('locations')
          .select('id')
          .eq('organization_id', organizationId)
          .ilike('name', locationName.trim())
          .limit(1);
      if (filteredLocations.isEmpty) {
        return null;
      }
      locationId = Map<String, dynamic>.from(
        filteredLocations.first as Map,
      )['id']?.toString();
    }

    final existingQuery = client
        .from('terminals')
        .select('*')
        .eq('organization_id', organizationId)
        .eq('terminal_number', terminalNumber);

    final existing = locationId != null && locationId.isNotEmpty
        ? await existingQuery.eq('location_id', locationId).limit(1)
        : await existingQuery.limit(1);

    if (existing.isNotEmpty) {
      return Map<String, dynamic>.from(existing.first as Map);
    }

    final locations = locationId != null && locationId.isNotEmpty
        ? [
            {'id': locationId},
          ]
        : await client
              .from('locations')
              .select('id')
              .eq('organization_id', organizationId)
              .limit(1);

    List<dynamic> effectiveLocations = locations;
    if (effectiveLocations.isEmpty) {
      final insertedLocation = await client
          .from('locations')
          .insert({
            'organization_id': organizationId,
            'name': 'Primary Location',
          })
          .select('id')
          .limit(1);
      effectiveLocations = insertedLocation;
    }

    if (effectiveLocations.isEmpty) return null;

    final resolvedLocationId = Map<String, dynamic>.from(
      effectiveLocations.first as Map,
    )['id']?.toString();
    if (resolvedLocationId == null || resolvedLocationId.isEmpty) return null;

    final payload = <String, dynamic>{
      'organization_id': organizationId,
      'organization_number': organizationNumber,
      'location_id': resolvedLocationId,
      'terminal_number': terminalNumber,
      'name': 'Terminal $terminalNumber',
      'code': terminalNumber,
    };

    final inserted = await client
        .from('terminals')
        .insert(payload)
        .select('*')
        .limit(1);

    if (inserted.isEmpty) return null;
    return Map<String, dynamic>.from(inserted.first as Map);
  }

  /// Resolves terminal context from an opaque URL token (`?tk=<token>`).
  ///
  /// On success, caches the token in localStorage and sets [_activeContext].
  /// Returns null if the token is empty, invalid, or the terminal is inactive.
  Future<LicenseActivationResult> resolveFromUrlToken(String token) async {
    final t = token.trim();
    if (t.isEmpty) {
      return const LicenseActivationResult(
        success: false,
        requiresInput: true,
        errorMessage: 'No terminal token provided.',
      );
    }

    try {
      final response = await SupabaseService.client.rpc(
        'resolve_terminal_from_token',
        params: {'p_token': t},
      );

      if (response is! List || response.isEmpty) {
        return const LicenseActivationResult(
          success: false,
          requiresInput: true,
          errorMessage:
              'Terminal token not recognised. Check the URL and try again.',
        );
      }

      final row = Map<String, dynamic>.from(response.first as Map);
      final terminalId = row['terminal_id']?.toString() ?? '';
      final organizationId = row['organization_id']?.toString() ?? '';
      final locationId = row['location_id']?.toString() ?? '';

      if (terminalId.isEmpty || organizationId.isEmpty || locationId.isEmpty) {
        return const LicenseActivationResult(
          success: false,
          requiresInput: true,
          errorMessage: 'Terminal token resolved incomplete context.',
        );
      }

      final context = LicenseContext(
        organizationId: organizationId,
        organizationNumber: row['organization_number']?.toString() ?? '',
        organizationName: row['organization_name']?.toString() ?? '',
        locationId: locationId,
        locationName: row['location_name']?.toString() ?? '',
        name: row['location_name']?.toString() ?? '',
        terminalId: terminalId,
        terminalNumber: row['terminal_number']?.toString() ?? '',
        terminalName: row['terminal_name']?.toString() ?? '',
        licenseKey: row['license_key']?.toString() ?? '',
      );

      _activeContext = context;

      // Apply per-terminal payment credentials to runtime config
      TerminalConfig.applyFromTerminalRecord(
        spinTpn: row['spin_tpn']?.toString() ?? '',
        spinAuthKey: row['spin_auth_key']?.toString() ?? '',
        cardReaderType: row['card_reader_type']?.toString() ?? '',
        cardReaderHppAuthToken:
            row['card_reader_hpp_auth_token']?.toString() ?? '',
      );
      await TerminalConfig.loadForTerminalId(
        context.terminalId,
        terminalNumber: context.terminalNumber,
      );
      if (TerminalConfig.cardReaderHppAuthToken.trim().isEmpty) {
        await _hydrateCardReaderConfigFromLicenseRpc(context);
      }

      // Cache resolved values for fast subsequent loads
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_terminalTokenStorageKey, t);
      await prefs.setString(
        _spinTpnStorageKey,
        row['spin_tpn']?.toString().trim() ?? '',
      );
      await prefs.setString(
        _spinAuthKeyStorageKey,
        row['spin_auth_key']?.toString().trim() ?? '',
      );
      await _storeLicenseKey(context.licenseKey);
      await _storeTerminalNumber(context.terminalNumber);
      await _storeLocationName(context.locationName);

      return LicenseActivationResult(success: true, context: context);
    } catch (error) {
      return LicenseActivationResult(
        success: false,
        requiresInput: true,
        errorMessage: 'Token resolution failed: $error',
      );
    }
  }

  Future<String?> getStoredTerminalToken() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_terminalTokenStorageKey)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> _storeLicenseOnTerminal({
    required String terminalId,
    required String licenseKey,
  }) async {
    if (terminalId.isEmpty) return;

    final client = SupabaseService.client;
    final terminalRows = await client
        .from('terminals')
        .select('*')
        .eq('id', terminalId)
        .limit(1);

    if (terminalRows.isEmpty) return;

    final terminal = Map<String, dynamic>.from(terminalRows.first as Map);
    final preferredColumns = [
      'application_license_number',
      'license_number',
      'license_key',
    ];

    String? chosenColumn;
    for (final column in preferredColumns) {
      if (terminal.containsKey(column)) {
        chosenColumn = column;
        break;
      }
    }

    if (chosenColumn == null) {
      return;
    }

    await client
        .from('terminals')
        .update({chosenColumn: licenseKey})
        .eq('id', terminalId);
  }

  Future<void> _hydrateCardReaderConfigFromLicenseRpc(
    LicenseContext context,
  ) async {
    try {
      final rpcRows = await SupabaseService.client.rpc(
        'list_terminals_from_app',
        params: {
          'p_license_key': context.licenseKey.trim(),
          'p_location_name': context.locationName.trim().isEmpty
              ? null
              : context.locationName.trim(),
        },
      );

      if (rpcRows is! List || rpcRows.isEmpty) return;

      String pickId(Map<String, dynamic> row) {
        return (row['id'] ?? row['terminal_id'] ?? row['terminalId'] ?? '')
            .toString()
            .trim();
      }

      String pickTerminalNumber(Map<String, dynamic> row) {
        return (row['terminal_number'] ?? row['terminalNumber'] ?? '')
            .toString()
            .trim();
      }

      final normalizedTerminalId = context.terminalId.trim();
      final normalizedTerminalNumber = context.terminalNumber.trim();

      Map<String, dynamic>? matched;
      for (final raw in rpcRows) {
        final row = Map<String, dynamic>.from(raw as Map);
        final rowId = pickId(row);
        final rowNumber = pickTerminalNumber(row);
        if ((normalizedTerminalId.isNotEmpty &&
                rowId == normalizedTerminalId) ||
            (normalizedTerminalNumber.isNotEmpty &&
                rowNumber == normalizedTerminalNumber)) {
          matched = row;
          break;
        }
      }

      if (matched == null) return;

      final cardReaderType =
          (matched['card_reader_type'] ?? matched['cardReaderType'] ?? '')
              .toString();
      final cardReaderHppAuthToken =
          (matched['card_reader_hpp_auth_token'] ??
                  matched['cardReaderHppAuthToken'] ??
                  matched['hpp_auth_token'] ??
                  matched['hppAuthToken'] ??
                  '')
              .toString();

      if (cardReaderType.trim().isEmpty &&
          cardReaderHppAuthToken.trim().isEmpty) {
        return;
      }

      TerminalConfig.applyFromTerminalRecord(
        spinTpn: TerminalConfig.spinTpn,
        spinAuthKey: TerminalConfig.spinAuthKey,
        cardReaderType: cardReaderType,
        cardReaderHppAuthToken: cardReaderHppAuthToken,
      );
    } catch (_) {
      // Non-fatal fallback; keep defaults if RPC is unavailable.
    }
  }
}
