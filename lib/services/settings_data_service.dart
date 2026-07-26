import 'package:supabase_flutter/supabase_flutter.dart';

import 'license_service.dart';
import '../supabase_config.dart';
import 'supabase_service.dart';

class SettingsDataService {
  bool _isTruthy(dynamic value) {
    if (value is bool) return value;
    final normalized = value?.toString().trim().toLowerCase();
    return normalized == 'true' ||
        normalized == 't' ||
        normalized == '1' ||
        normalized == 'yes';
  }

  String _normalizeSqlTimeString(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return '';
    final match = RegExp(r'^(\d{1,2}:\d{2}(?::\d{2})?)').firstMatch(raw);
    if (match == null) return raw;
    return match.group(1) ?? raw;
  }

  bool _isValidUuid(String value) {
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);
  }

  bool _isValidOrganizationNumber(String value) {
    return RegExp(r'^\d{6}$').hasMatch(value);
  }

  bool _isValidTerminalNumber(String value) {
    return RegExp(r'^\d{4}$').hasMatch(value);
  }

  String _normalizePhoneDigits(String value) {
    return value.replaceAll(RegExp(r'\D'), '');
  }

  bool? _parseOptionalBool(dynamic value) {
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

  Future<void> _ensureLocationTipAdjustmentsPersisted({
    required String locationId,
    required String locationName,
    required bool allowTipAdjustments,
  }) async {
    final normalizedLocationId = locationId.trim();
    if (normalizedLocationId.isEmpty || !_isValidUuid(normalizedLocationId)) {
      throw Exception(
        'Cannot verify allow_tip_adjustments without a valid location id.',
      );
    }

    Object? directUpdateError;
    try {
      await SupabaseService.client
          .from('locations')
          .update({'allow_tip_adjustments': allowTipAdjustments})
          .eq('id', normalizedLocationId)
          .select('id')
          .limit(1);
    } catch (error) {
      directUpdateError = error;
    }

    // If direct update succeeded, we're done. Readback may return null
    // when RLS SELECT policy does not expose allow_tip_adjustments, so we
    // trust the write rather than failing on a null readback.
    if (directUpdateError == null) {
      return;
    }

    // Direct update failed — try the RPC fallback.
    try {
      final licenseKey = await _resolveLicenseKeyForLocationFallback();
      await SupabaseService.client.rpc(
        'update_location_tip_adjustments_from_app',
        params: {
          'p_license_key': licenseKey,
          'p_location_id': normalizedLocationId,
          'p_location_name': locationName.trim().isEmpty
              ? null
              : locationName.trim(),
          'p_allow_tip_adjustments': allowTipAdjustments,
        },
      );
    } catch (rpcError) {
      throw Exception(
        'allow_tip_adjustments could not be saved for location $normalizedLocationId. '
        'direct_update_error=$directUpdateError; rpc_error=$rpcError',
      );
    }
  }

  Future<void> _ensureLocationReceiptSettingsPersisted({
    required String locationId,
    required String locationName,
    required bool printTipSuggestions,
    required String tipSuggestion1Pct,
    required String tipSuggestion2Pct,
    required String tipSuggestion3Pct,
    required String tipSuggestionBase,
    required String receiptCardSignatureMessage,
    required String receiptMiscMessage,
    required String receiptReplyToEmail,
  }) async {
    final normalizedLocationId = locationId.trim();
    if (normalizedLocationId.isEmpty || !_isValidUuid(normalizedLocationId)) {
      throw Exception(
        'Cannot verify receipt settings without a valid location id.',
      );
    }

    final normalizedTipSuggestionBase =
        tipSuggestionBase.trim().toLowerCase() == 'total'
        ? 'total'
        : 'subtotal';
    final normalizedTipSuggestion1 =
        double.tryParse(tipSuggestion1Pct.trim()) ?? 18;
    final normalizedTipSuggestion2 =
        double.tryParse(tipSuggestion2Pct.trim()) ?? 20;
    final normalizedTipSuggestion3 =
        double.tryParse(tipSuggestion3Pct.trim()) ?? 25;

    Object? directUpdateError;
    try {
      final PostgrestList updated = await SupabaseService.client
          .from('locations')
          .update({
            'print_tip_suggestions': printTipSuggestions,
            'tip_suggestion_1_pct': normalizedTipSuggestion1,
            'tip_suggestion_2_pct': normalizedTipSuggestion2,
            'tip_suggestion_3_pct': normalizedTipSuggestion3,
            'tip_suggestion_base': normalizedTipSuggestionBase,
            'receipt_card_signature_message': receiptCardSignatureMessage
                .trim(),
            'receipt_misc_message': receiptMiscMessage.trim(),
            'receipt_reply_to_email': receiptReplyToEmail.trim(),
          })
          .eq('id', normalizedLocationId)
          .select('id')
          .limit(1);
      if (updated.isNotEmpty) {
        return;
      }
      directUpdateError = Exception('No matching location row was updated.');
    } catch (error) {
      directUpdateError = error;
    }

    try {
      final licenseKey = await _resolveLicenseKeyForLocationFallback();
      await _syncLocationReceiptSettingsViaRpc(
        licenseKey: licenseKey,
        locationId: normalizedLocationId,
        locationName: locationName,
        printTipSuggestions: printTipSuggestions,
        tipSuggestion1Pct: tipSuggestion1Pct,
        tipSuggestion2Pct: tipSuggestion2Pct,
        tipSuggestion3Pct: tipSuggestion3Pct,
        tipSuggestionBase: normalizedTipSuggestionBase,
        receiptCardSignatureMessage: receiptCardSignatureMessage,
        receiptMiscMessage: receiptMiscMessage,
        receiptReplyToEmail: receiptReplyToEmail,
      );
    } catch (rpcError) {
      throw Exception(
        'Receipt settings could not be saved for location '
        '$normalizedLocationId ($locationName). '
        'direct_update_error=$directUpdateError; rpc_error=$rpcError',
      );
    }
  }

  String _normalizeStaffRole(String value) {
    switch (value.trim().toLowerCase()) {
      case 'administrator':
      case 'admin':
        return 'admin';
      case 'manager':
        return 'manager';
      case 'cashier':
        return 'cashier';
      default:
        return value.trim().toLowerCase();
    }
  }

  String _buildStaffFullName(String firstName, String lastName) {
    return [
      firstName.trim(),
      lastName.trim(),
    ].where((part) => part.isNotEmpty).join(' ');
  }

  bool _isValidStaffPin(String value) {
    return RegExp(r'^\d{1,6}$').hasMatch(value);
  }

  Future<void> _assertUniqueStaffPinInScope({
    required String organizationId,
    required String locationId,
    required String pin,
    String? excludeStaffId,
  }) async {
    final orgId = organizationId.trim();
    final locId = locationId.trim();
    final normalizedPin = pin.trim();
    final excluded = (excludeStaffId ?? '').trim();

    if (orgId.isEmpty || locId.isEmpty || normalizedPin.isEmpty) {
      return;
    }

    try {
      var query = SupabaseService.client
          .from('staff')
          .select('id')
          .eq('organization_id', orgId)
          .eq('location_id', locId)
          .eq('pin', normalizedPin);

      if (excluded.isNotEmpty) {
        query = query.neq('id', excluded);
      }

      final PostgrestList matches = await query.limit(1);
      if (matches.isNotEmpty) {
        throw Exception(
          'PIN already exists for another staff member in this location. Choose a unique PIN.',
        );
      }
    } catch (error) {
      if (error is Exception &&
          error.toString().contains('PIN already exists for another staff')) {
        rethrow;
      }
      if (_isRlsOrPermissionError(error) || _isPostgrestError(error)) {
        return;
      }
      throw Exception('Unable to validate unique staff PIN: $error');
    }
  }

  bool _isMissingLicenseColumnError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('license_key') &&
        (text.contains('column') ||
            text.contains('schema cache') ||
            text.contains('pgrst204'));
  }

  bool _isRlsOrPermissionError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('row-level security') ||
        text.contains('permission denied') ||
        text.contains('42501') ||
        text.contains('not allowed') ||
        text.contains('requires authentication') ||
        text.contains('jwt');
  }

  bool _isPostgrestError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('postgrestexception') || text.contains('pgrst');
  }

  bool _isUniqueViolation(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('23505') || text.contains('unique constraint');
  }

  bool _isStaffPinUniqueViolation(Object error) {
    final text = error.toString().toLowerCase();
    return _isUniqueViolation(error) &&
        (text.contains('pin') ||
            text.contains('idx_staff_org_location_pin_unique'));
  }

  bool _isNoMatchingLocationUpdateError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('no matching location row was updated');
  }

  bool _isNoMatchingStaffUpdateError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('no matching staff row was updated');
  }

  Exception _buildDatabaseException(String context, Object error) {
    return Exception('$context: $error');
  }

  Future<String> _resolveLicenseKeyForLocationFallback() async {
    final licenseService = LicenseService();
    var activeContext = licenseService.activeContext;

    String pickToken() {
      final activeLicenseKey = (activeContext?.licenseKey ?? '').trim();
      if (activeLicenseKey.isNotEmpty) return activeLicenseKey;

      final activeOrganizationNumber = (activeContext?.organizationNumber ?? '')
          .trim();
      if (activeOrganizationNumber.isNotEmpty) return activeOrganizationNumber;

      final defineLicenseKey = SupabaseConfig.appLicenseKey.trim();
      if (defineLicenseKey.isNotEmpty) return defineLicenseKey;

      final defineOrganizationNumber = SupabaseConfig.organizationNumber.trim();
      if (defineOrganizationNumber.isNotEmpty) return defineOrganizationNumber;

      return '';
    }

    final storedKey = ((await licenseService.getStoredLicenseKey()) ?? '')
        .trim();
    var token = pickToken();
    if (token.isEmpty && storedKey.isNotEmpty) {
      token = storedKey;
    }

    if (token.isEmpty) {
      final activationResult = await licenseService
          .initializeFromStoredOrDefine();
      if (activationResult.success) {
        activeContext = licenseService.activeContext;
        token = pickToken();
      }
    }

    if (token.isEmpty) {
      throw Exception(
        'No active or stored license context available for location operation fallback.',
      );
    }

    return token;
  }

  Future<String?> _upsertLocationViaLicenseRpcFallback({
    String? locationId,
    required String locationName,
    required String address,
    required String address2,
    required String city,
    required String state,
    required String zip,
    required String phone,
    int? terminalLicenses,
    int? terminalsActive,
    String processorProvider = '',
    String processorEnvironment = '',
    String processorMode = '',
    String epnApiLoginId = '',
    String epnUserId = '',
    String epnPassword = '',
    String epnRestrictKey = '',
    bool allowTipAdjustments = false,
    String receiptReplyToEmail = '',
  }) async {
    final licenseKey = await _resolveLicenseKeyForLocationFallback();
    final normalizedLocationId = (locationId ?? '').trim();

    final baseParams = {
      'p_license_key': licenseKey,
      'p_location_id':
          normalizedLocationId.isNotEmpty && _isValidUuid(normalizedLocationId)
          ? normalizedLocationId
          : null,
      'p_location_name': locationName.trim(),
      'p_address': address.trim(),
      'p_address_2': address2.trim(),
      'p_city': city.trim(),
      'p_state': state.trim(),
      'p_zip': zip.trim(),
      'p_phone': _normalizePhoneDigits(phone.trim()),
      'p_terminal_licenses': terminalLicenses,
      'p_terminals_active': terminalsActive,
      'p_allow_tip_adjustments': allowTipAdjustments,
      'p_receipt_reply_to_email': receiptReplyToEmail.trim().isEmpty
          ? null
          : receiptReplyToEmail.trim(),
    };

    try {
      final dynamic rpcLocationId = await SupabaseService.client.rpc(
        'upsert_location_from_app',
        params: {
          ...baseParams,
          'p_processor_provider': processorProvider.trim(),
          'p_processor_environment': processorEnvironment.trim(),
          'p_processor_mode': processorMode.trim(),
          'p_epn_api_login_id': epnApiLoginId.trim(),
          'p_epn_user_id': epnUserId.trim(),
          'p_epn_password': epnPassword.trim(),
          'p_epn_restrict_key': epnRestrictKey.trim(),
        },
      );
      final resolvedLocationId =
          (rpcLocationId?.toString().trim().isNotEmpty == true)
          ? rpcLocationId.toString().trim()
          : normalizedLocationId;
      await _syncLocationTerminalLimitsViaRpc(
        licenseKey: licenseKey,
        locationId: resolvedLocationId,
        locationName: locationName,
        terminalLicenses: terminalLicenses,
        terminalsActive: terminalsActive,
      );
      await _syncLocationTipAdjustmentsViaRpc(
        licenseKey: licenseKey,
        locationId: resolvedLocationId,
        locationName: locationName,
        allowTipAdjustments: allowTipAdjustments,
      );
      return resolvedLocationId;
    } catch (error) {
      final text = error.toString().toLowerCase();
      final signatureMismatch =
          text.contains('upsert_location_from_app') &&
          (text.contains('function') ||
              text.contains('pgrst') ||
              text.contains('schema cache'));
      if (!signatureMismatch) rethrow;
    }

    final legacyParams = Map<String, dynamic>.from(baseParams)
      ..remove('p_terminal_licenses')
      ..remove('p_terminals_active')
      ..remove('p_allow_tip_adjustments');

    final dynamic legacyLocationId = await SupabaseService.client.rpc(
      'upsert_location_from_app',
      params: legacyParams,
    );

    final resolvedLegacyLocationId =
        (legacyLocationId?.toString().trim().isNotEmpty == true)
        ? legacyLocationId.toString().trim()
        : normalizedLocationId;

    await _syncLocationTerminalLimitsViaRpc(
      licenseKey: licenseKey,
      locationId: resolvedLegacyLocationId,
      locationName: locationName,
      terminalLicenses: terminalLicenses,
      terminalsActive: terminalsActive,
    );
    await _syncLocationTipAdjustmentsViaRpc(
      licenseKey: licenseKey,
      locationId: resolvedLegacyLocationId,
      locationName: locationName,
      allowTipAdjustments: allowTipAdjustments,
    );
    return resolvedLegacyLocationId;
  }

  Future<void> _syncLocationTerminalLimitsViaRpc({
    required String licenseKey,
    required String locationId,
    required String locationName,
    int? terminalLicenses,
    int? terminalsActive,
  }) async {
    if (terminalLicenses == null && terminalsActive == null) {
      return;
    }

    try {
      await SupabaseService.client.rpc(
        'update_location_terminal_limits_from_app',
        params: {
          'p_license_key': licenseKey,
          'p_location_id': locationId.trim().isEmpty ? null : locationId.trim(),
          'p_location_name': locationName.trim().isEmpty
              ? null
              : locationName.trim(),
          'p_terminal_licenses': terminalLicenses,
          'p_terminals_active': terminalsActive,
        },
      );
    } catch (_) {
      // Older schema may not have this RPC yet.
    }
  }

  Future<void> _syncLocationReceiptSettingsViaRpc({
    required String licenseKey,
    required String locationId,
    required String locationName,
    required bool printTipSuggestions,
    required String tipSuggestion1Pct,
    required String tipSuggestion2Pct,
    required String tipSuggestion3Pct,
    required String tipSuggestionBase,
    required String receiptCardSignatureMessage,
    required String receiptMiscMessage,
    required String receiptReplyToEmail,
  }) async {
    final normalizedLocationId = locationId.trim();
    final normalizedTipSuggestionBase =
        tipSuggestionBase.trim().toLowerCase() == 'total'
        ? 'total'
        : 'subtotal';
    final normalizedTipSuggestion1 =
        double.tryParse(tipSuggestion1Pct.trim()) ?? 18;
    final normalizedTipSuggestion2 =
        double.tryParse(tipSuggestion2Pct.trim()) ?? 20;
    final normalizedTipSuggestion3 =
        double.tryParse(tipSuggestion3Pct.trim()) ?? 25;

    if (normalizedLocationId.isNotEmpty) {
      try {
        final PostgrestList updated = await SupabaseService.client
            .from('locations')
            .update({
              'print_tip_suggestions': printTipSuggestions,
              'tip_suggestion_1_pct': normalizedTipSuggestion1,
              'tip_suggestion_2_pct': normalizedTipSuggestion2,
              'tip_suggestion_3_pct': normalizedTipSuggestion3,
              'tip_suggestion_base': normalizedTipSuggestionBase,
              'receipt_card_signature_message': receiptCardSignatureMessage
                  .trim(),
              'receipt_misc_message': receiptMiscMessage.trim(),
              'receipt_reply_to_email': receiptReplyToEmail.trim(),
            })
            .eq('id', normalizedLocationId)
            .select('id')
            .limit(1);
        if (updated.isNotEmpty) {
          return;
        }
      } catch (_) {
        // Fall through to RPC fallback.
      }
    }

    await SupabaseService.client.rpc(
      'update_location_receipt_settings_from_app',
      params: {
        'p_license_key': licenseKey,
        'p_location_id': normalizedLocationId.isEmpty
            ? null
            : normalizedLocationId,
        'p_location_name': locationName.trim().isEmpty
            ? null
            : locationName.trim(),
        'p_print_tip_suggestions': printTipSuggestions,
        'p_tip_suggestion_1_pct': normalizedTipSuggestion1,
        'p_tip_suggestion_2_pct': normalizedTipSuggestion2,
        'p_tip_suggestion_3_pct': normalizedTipSuggestion3,
        'p_tip_suggestion_base': normalizedTipSuggestionBase,
        'p_receipt_card_signature_message':
            receiptCardSignatureMessage.trim().isEmpty
            ? null
            : receiptCardSignatureMessage.trim(),
        'p_receipt_misc_message': receiptMiscMessage.trim().isEmpty
            ? null
            : receiptMiscMessage.trim(),
        'p_receipt_reply_to_email': receiptReplyToEmail.trim().isEmpty
            ? null
            : receiptReplyToEmail.trim(),
      },
    );
  }

  Future<void> _syncLocationTipAdjustmentsViaRpc({
    required String licenseKey,
    required String locationId,
    required String locationName,
    required bool allowTipAdjustments,
  }) async {
    final normalizedLocationId = locationId.trim();

    // Prefer direct update first; many environments allow this path even when
    // custom RPCs are not yet deployed.
    if (normalizedLocationId.isNotEmpty) {
      try {
        final PostgrestList updated = await SupabaseService.client
            .from('locations')
            .update({'allow_tip_adjustments': allowTipAdjustments})
            .eq('id', normalizedLocationId)
            .select('id')
            .limit(1);
        if (updated.isNotEmpty) {
          return;
        }
      } catch (_) {
        // Fall through to RPC fallback.
      }
    }

    try {
      await SupabaseService.client.rpc(
        'update_location_tip_adjustments_from_app',
        params: {
          'p_license_key': licenseKey,
          'p_location_id': normalizedLocationId.isEmpty
              ? null
              : normalizedLocationId,
          'p_location_name': locationName.trim().isEmpty
              ? null
              : locationName.trim(),
          'p_allow_tip_adjustments': allowTipAdjustments,
        },
      );
    } catch (_) {
      // Older schema may not have this RPC yet.
    }
  }

  Future<void> _upsertStaffViaLicenseRpcFallback({
    String? staffId,
    required String locationId,
    required String firstName,
    required String pin,
    String lastName = '',
    String email = '',
    String phone = '',
    String role = 'cashier',
    bool isActive = true,
  }) async {
    final licenseKey = await _resolveLicenseKeyForLocationFallback();
    final normalizedStaffId = (staffId ?? '').trim();

    await SupabaseService.client.rpc(
      'upsert_staff_from_app',
      params: {
        'p_license_key': licenseKey,
        'p_location_id': locationId.trim(),
        'p_staff_id':
            normalizedStaffId.isNotEmpty && _isValidUuid(normalizedStaffId)
            ? normalizedStaffId
            : null,
        'p_first_name': firstName.trim(),
        'p_last_name': lastName.trim(),
        'p_email': null,
        'p_phone': phone.trim().isEmpty ? null : _normalizePhoneDigits(phone),
        'p_role': _normalizeStaffRole(role),
        'p_is_active': isActive,
        'p_pin': pin.trim(),
      },
    );
  }

  Future<List<Map<String, dynamic>>> _listTerminalsViaLicenseRpc() async {
    final licenseKey = await _resolveLicenseKeyForLocationFallback();
    final locationName = (await LicenseService().getStoredLocationName()) ?? '';

    final PostgrestList rpcRows = await SupabaseService.client.rpc(
      'list_terminals_from_app',
      params: {
        'p_license_key': licenseKey,
        'p_location_name': locationName.trim().isEmpty
            ? null
            : locationName.trim(),
      },
    );

    String _pickTerminalId(Map<String, dynamic> row) {
      return (row['id'] ?? row['terminal_id'] ?? row['terminalId'] ?? '')
          .toString()
          .trim();
    }

    String _pickTerminalName(Map<String, dynamic> row) {
      return (row['terminal_name'] ?? row['name'] ?? '').toString();
    }

    final rows = rpcRows.map((raw) {
      final row = Map<String, dynamic>.from(raw as Map);

      // Normalize keys so UI/editor code has a stable shape regardless
      // of which migration version produced the RPC row.
      row['id'] = _pickTerminalId(row);
      row['terminal_name'] = _pickTerminalName(row);
      row['terminal_number'] =
          (row['terminal_number'] ?? row['terminalNumber'] ?? '').toString();
      row['auto_close_batch_enabled'] = _isTruthy(
        row['auto_close_batch_enabled'] ??
            row['autoCloseBatchEnabled'] ??
            row['auto_close_enabled'] ??
            row['autoCloseEnabled'],
      );
      row['auto_close_batch_time'] = _normalizeSqlTimeString(
        row['auto_close_batch_time'] ??
            row['autoCloseBatchTime'] ??
            row['auto_close_time'] ??
            row['autoCloseTime'],
      );

      return row;
    }).toList();

    // Some RPC versions don't return new terminal fields; enrich from table when available.
    try {
      final ids = rows
          .map((r) => _pickTerminalId(r))
          .where((v) => v.isNotEmpty)
          .toList();

      if (ids.isNotEmpty) {
        final PostgrestList extraRows = await SupabaseService.client
            .from('terminals')
            .select(
              'id, terminal_token, spin_tpn, spin_auth_key, card_reader_type, card_reader_hpp_auth_token, receipt_printer_name, auto_close_batch_enabled, auto_close_batch_time',
            )
            .inFilter('id', ids)
            .limit(ids.length);

        final extraById = <String, Map<String, dynamic>>{};
        for (final raw in extraRows) {
          final row = Map<String, dynamic>.from(raw as Map);
          final id = row['id']?.toString().trim() ?? '';
          if (id.isNotEmpty) extraById[id] = row;
        }

        for (final row in rows) {
          final id = _pickTerminalId(row);
          final extra = extraById[id];
          if (extra == null) continue;

          row['card_reader_type'] =
              (extra['card_reader_type']?.toString().trim().toLowerCase() ??
              'dejavoo_p12');
          row['terminal_token'] = extra['terminal_token']?.toString() ?? '';
          row['card_reader_hpp_auth_token'] =
              extra['card_reader_hpp_auth_token']?.toString() ?? '';
          row['spin_tpn'] = extra['spin_tpn']?.toString() ?? '';
          row['spin_auth_key'] = extra['spin_auth_key']?.toString() ?? '';
          row['receipt_printer_name'] =
              extra['receipt_printer_name']?.toString() ?? '';
          row['auto_close_batch_enabled'] = _isTruthy(
            extra['auto_close_batch_enabled'],
          );
          row['auto_close_batch_time'] = _normalizeSqlTimeString(
            extra['auto_close_batch_time'],
          );
        }
      }
    } catch (_) {
      // Keep base RPC rows when extra columns are unavailable.
    }

    return rows;
  }

  Future<String?> _upsertTerminalViaLicenseRpcFallback({
    String? terminalId,
    required String locationId,
    required String terminalNumber,
    required String name,
    String code = '',
    String spinTpn = '',
    String spinAuthKey = '',
    String cardReaderType = 'dejavoo_p12',
    String cardReaderHppAuthToken = '',
    bool isActive = true,
    String receiptPrinterName = '',
    bool? autoCloseBatchEnabled,
    String? autoCloseBatchTime,
  }) async {
    final licenseKey = await _resolveLicenseKeyForLocationFallback();
    final normalizedTerminalId = (terminalId ?? '').trim();
    final normalizedReaderType = cardReaderType.trim().toLowerCase() == 'none'
        ? 'none'
        : 'dejavoo_p12';
    final normalizedSpinTpn = spinTpn.trim();
    final normalizedSpinAuthKey = spinAuthKey.trim();
    final normalizedHppToken = cardReaderHppAuthToken.trim();
    final normalizedAutoCloseTime = autoCloseBatchTime?.trim() ?? '';
    var usedLegacyRpcFallback = false;

    dynamic rpcTerminalId;
    try {
      rpcTerminalId = await SupabaseService.client.rpc(
        'upsert_terminal_from_app',
        params: {
          'p_license_key': licenseKey,
          'p_location_id': locationId.trim(),
          'p_terminal_id':
              normalizedTerminalId.isNotEmpty &&
                  _isValidUuid(normalizedTerminalId)
              ? normalizedTerminalId
              : null,
          'p_terminal_number': terminalNumber.trim(),
          'p_name': name.trim(),
          'p_code': code.trim().isEmpty ? null : code.trim(),
          'p_spin_tpn': normalizedSpinTpn.isEmpty ? null : normalizedSpinTpn,
          'p_spin_auth_key': normalizedSpinAuthKey.isEmpty
              ? null
              : normalizedSpinAuthKey,
          'p_card_reader_type': normalizedReaderType,
          'p_card_reader_hpp_auth_token': normalizedHppToken.isEmpty
              ? null
              : normalizedHppToken,
          'p_is_active': isActive,
          'p_receipt_printer_name': receiptPrinterName.trim().isEmpty
              ? null
              : receiptPrinterName.trim(),
          'p_auto_close_batch_enabled': autoCloseBatchEnabled,
          'p_auto_close_batch_time': autoCloseBatchTime == null
              ? null
              : normalizedAutoCloseTime.isEmpty
              ? null
              : normalizedAutoCloseTime,
        },
      );
    } catch (error) {
      final text = error.toString().toLowerCase();
      final missingSpinParams =
          text.contains('p_spin_tpn') || text.contains('p_spin_auth_key');
      final missingAutoCloseParams =
          text.contains('p_auto_close_batch_enabled') ||
          text.contains('p_auto_close_batch_time');
      if (!missingSpinParams && !missingAutoCloseParams) {
        rethrow;
      }

      usedLegacyRpcFallback = true;

      // Legacy fallback for databases that still have older RPC signatures.
      rpcTerminalId = await SupabaseService.client.rpc(
        'upsert_terminal_from_app',
        params: {
          'p_license_key': licenseKey,
          'p_location_id': locationId.trim(),
          'p_terminal_id':
              normalizedTerminalId.isNotEmpty &&
                  _isValidUuid(normalizedTerminalId)
              ? normalizedTerminalId
              : null,
          'p_terminal_number': terminalNumber.trim(),
          'p_name': name.trim(),
          'p_code': code.trim().isEmpty ? null : code.trim(),
          'p_card_reader_type': normalizedReaderType,
          'p_card_reader_hpp_auth_token': normalizedHppToken.isEmpty
              ? null
              : normalizedHppToken,
          'p_is_active': isActive,
          'p_receipt_printer_name': receiptPrinterName.trim().isEmpty
              ? null
              : receiptPrinterName.trim(),
        },
      );
    }

    final resolvedTerminalId = rpcTerminalId?.toString().trim() ?? '';
    if (resolvedTerminalId.isNotEmpty) {
      try {
        final terminalUpdate = <String, dynamic>{
          'spin_tpn': normalizedSpinTpn,
          'spin_auth_key': normalizedSpinAuthKey,
        };
        if (autoCloseBatchEnabled != null) {
          terminalUpdate['auto_close_batch_enabled'] = autoCloseBatchEnabled;
        }
        if (autoCloseBatchTime != null) {
          terminalUpdate['auto_close_batch_time'] = normalizedAutoCloseTime.isEmpty
              ? null
              : normalizedAutoCloseTime;
        }

        await SupabaseService.client
            .from('terminals')
            .update(terminalUpdate)
            .eq('id', resolvedTerminalId);
      } catch (error) {
        final text = error.toString().toLowerCase();
        final requestedAutoCloseUpdate =
            autoCloseBatchEnabled != null || autoCloseBatchTime != null;
        final missingAutoCloseColumns =
            text.contains('auto_close_batch_enabled') ||
            text.contains('auto_close_batch_time');

        if (requestedAutoCloseUpdate && usedLegacyRpcFallback) {
          if (missingAutoCloseColumns) {
            throw Exception(
              'Terminal auto-close fields are missing in this database. Run supabase/2026-06-13_terminal_auto_close_batch_settings.sql, then retry.',
            );
          }
          throw Exception(
            'Terminal auto-close settings could not be saved. The database is using a legacy terminal upsert RPC and direct terminals table update failed: $error',
          );
        }

        if (requestedAutoCloseUpdate && missingAutoCloseColumns) {
          throw Exception(
            'Terminal auto-close fields are missing in this database. Run supabase/2026-06-13_terminal_auto_close_batch_settings.sql, then retry.',
          );
        }
        // Non-fatal; some deployments may only allow updates via RPC.
      }
    }
    return resolvedTerminalId.isEmpty ? null : resolvedTerminalId;
  }

  Future<String?> _findTerminalIdByLocationAndNumber({
    required String locationId,
    required String terminalNumber,
  }) async {
    final locId = locationId.trim();
    final number = terminalNumber.trim();
    if (locId.isEmpty || number.isEmpty) return null;

    try {
      final rows = await SupabaseService.client
          .from('terminals')
          .select('id')
          .eq('location_id', locId)
          .eq('terminal_number', number)
          .limit(1);
      if (rows.isNotEmpty) {
        return rows.first['id']?.toString().trim();
      }
    } catch (_) {
      // Ignore and return null for fallback resolution.
    }

    return null;
  }

  String? _extractMissingColumnName(Object error) {
    final text = error.toString();
    final singleQuoted = RegExp(r"'([a-zA-Z0-9_]+)'").firstMatch(text);
    if (singleQuoted != null) {
      return singleQuoted.group(1)?.toLowerCase();
    }

    final doubleQuoted = RegExp(r'"([a-zA-Z0-9_]+)"').firstMatch(text);
    if (doubleQuoted != null) {
      return doubleQuoted.group(1)?.toLowerCase();
    }

    return null;
  }

  Future<void> _insertLocationsWithFallback(
    Map<String, dynamic> payload,
  ) async {
    final mutable = Map<String, dynamic>.from(payload);

    while (true) {
      try {
        await SupabaseService.client.from('locations').insert(mutable);
        return;
      } catch (error) {
        final missingColumn = _extractMissingColumnName(error);
        if (missingColumn != null && mutable.containsKey(missingColumn)) {
          mutable.remove(missingColumn);
          continue;
        }
        if (mutable.containsKey('organization_number')) {
          mutable.remove('organization_number');
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _updateLocationsWithFallback({
    required dynamic id,
    required Map<String, dynamic> payload,
  }) async {
    final mutable = Map<String, dynamic>.from(payload);

    while (true) {
      try {
        final PostgrestList updated = await SupabaseService.client
            .from('locations')
            .update(mutable)
            .eq('id', id)
            .select('id')
            .limit(1);

        if (updated.isEmpty) {
          throw Exception('No matching location row was updated.');
        }

        return;
      } catch (error) {
        final missingColumn = _extractMissingColumnName(error);
        if (missingColumn != null && mutable.containsKey(missingColumn)) {
          mutable.remove(missingColumn);
          continue;
        }
        if (mutable.containsKey('organization_number')) {
          mutable.remove('organization_number');
          continue;
        }
        rethrow;
      }
    }
  }

  Future<List<Map<String, dynamic>>> fetchTableRows({
    required String tableName,
    int limit = 100,
  }) async {
    if (tableName == 'terminals') {
      try {
        return await _listTerminalsViaLicenseRpc();
      } catch (_) {}
    }

    if (tableName == 'organizations') {
      try {
        final PostgrestList rpcRows = await SupabaseService.client.rpc(
          'list_organizations_from_app',
        );
        final rows = rpcRows
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();

        // Enrich RPC rows with newer org-level fields when available.
        try {
          final ids = rows
              .map((r) => (r['id'] ?? '').toString().trim())
              .where((v) => v.isNotEmpty)
              .toList();
          if (ids.isNotEmpty) {
            final PostgrestList extraRows = await SupabaseService.client
                .from('organizations')
                .select('id, auto_close_batch_enabled, auto_close_batch_time')
                .inFilter('id', ids)
                .limit(ids.length);
            final extraById = <String, Map<String, dynamic>>{};
            for (final raw in extraRows) {
              final row = Map<String, dynamic>.from(raw as Map);
              final id = row['id']?.toString().trim() ?? '';
              if (id.isNotEmpty) extraById[id] = row;
            }

            for (final row in rows) {
              final id = row['id']?.toString().trim() ?? '';
              final extra = extraById[id];
              if (extra != null) {
                row['auto_close_batch_enabled'] = _isTruthy(
                  extra['auto_close_batch_enabled'],
                );
                row['auto_close_batch_time'] = _normalizeSqlTimeString(
                  extra['auto_close_batch_time'],
                );
              } else {
                // Keep any values already returned by RPC rows, but normalize type/format.
                row['auto_close_batch_enabled'] = _isTruthy(
                  row['auto_close_batch_enabled'],
                );
                row['auto_close_batch_time'] = _normalizeSqlTimeString(
                  row['auto_close_batch_time'],
                );
              }
            }
          }
        } catch (_) {}

        return rows;
      } catch (_) {}
    }

    if (tableName == 'locations') {
      try {
        final PostgrestList response = await SupabaseService.client
            .from('locations')
            .select(
              'id, organization_id, name, address, address_1, address_2, city, state, zip, phone, terminal_licenses, terminals_active, allow_tip_adjustments, print_tip_suggestions, tip_suggestion_1_pct, tip_suggestion_2_pct, tip_suggestion_3_pct, tip_suggestion_base, receipt_card_signature_message, receipt_misc_message, receipt_reply_to_email, invoice_reply_to_email',
            )
            .limit(limit);

        return response
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
      } catch (_) {
        // Fall back to generic select for compatibility with older schemas.
      }
    }

    final PostgrestList response = await SupabaseService.client
        .from(tableName)
        .select()
        .limit(limit);

    return response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<void> insertRow({
    required String tableName,
    required Map<String, dynamic> row,
  }) async {
    await SupabaseService.client.from(tableName).insert(row);
  }

  Future<void> updateRow({
    required String tableName,
    required dynamic id,
    required Map<String, dynamic> row,
  }) async {
    await SupabaseService.client.from(tableName).update(row).eq('id', id);
  }

  Future<void> deleteRow({
    required String tableName,
    required dynamic id,
  }) async {
    await SupabaseService.client.from(tableName).delete().eq('id', id);
  }

  Future<void> deleteLocationForm({
    required dynamic id,
    required String name,
  }) async {
    final locationId = id.toString().trim();
    final locationName = name.trim();

    if (locationId.isEmpty) {
      throw Exception('Location id is required to delete location.');
    }

    try {
      final PostgrestList deleted = await SupabaseService.client
          .from('locations')
          .delete()
          .eq('id', locationId)
          .select('id')
          .limit(1);

      if (deleted.isEmpty) {
        throw Exception('No matching location row was deleted.');
      }

      return;
    } catch (error) {
      if (!_isRlsOrPermissionError(error) && !_isPostgrestError(error)) {
        final message = error.toString().toLowerCase();
        final isNoRows = message.contains(
          'no matching location row was deleted',
        );
        if (!isNoRows) {
          throw _buildDatabaseException('Failed to delete location', error);
        }
      }
    }

    try {
      final licenseKey = await _resolveLicenseKeyForLocationFallback();
      await SupabaseService.client.rpc(
        'delete_location_from_app',
        params: {
          'p_license_key': licenseKey,
          'p_location_id': locationId,
          'p_location_name': locationName,
        },
      );
      return;
    } catch (rpcError) {
      throw _buildDatabaseException(
        'Failed to delete location (RPC fallback failed). Run updated supabase/license_setup.sql and verify role/permissions',
        rpcError,
      );
    }
  }

  Future<void> setOrganizationLicenseKey({
    required String organizationNumber,
    required String licenseKey,
  }) async {
    final orgNumber = organizationNumber.trim();
    final key = licenseKey.trim();
    if (orgNumber.isEmpty || key.isEmpty) {
      throw Exception('Organization number and license key are required.');
    }

    final updated = await SupabaseService.client
        .from('organizations')
        .update({'license_key': key})
        .eq('organization_number', orgNumber)
        .select('id')
        .limit(1);

    if (updated.isEmpty) {
      throw Exception(
        'Organization not found for organization_number $orgNumber.',
      );
    }
  }

  Future<String?> getOrganizationIdByNumber(String organizationNumber) async {
    final orgNumber = organizationNumber.trim();
    if (orgNumber.isEmpty) return null;

    final rows = await SupabaseService.client
        .from('organizations')
        .select('id')
        .eq('organization_number', orgNumber)
        .limit(1);

    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first as Map)['id']?.toString();
  }

  Future<String?> getOrganizationNumberById(String organizationId) async {
    final id = organizationId.trim();
    if (id.isEmpty) return null;

    final rows = await SupabaseService.client
        .from('organizations')
        .select('organization_number')
        .eq('id', id)
        .limit(1);

    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(
      rows.first as Map,
    )['organization_number']?.toString();
  }

  Future<String?> getDefaultOrganizationNumber() async {
    final rows = await SupabaseService.client
        .from('organizations')
        .select('organization_number')
        .limit(1);

    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(
      rows.first as Map,
    )['organization_number']?.toString();
  }

  Future<Map<String, String?>> getOrganizationDetailsByNumber(
    String organizationNumber,
  ) async {
    final orgNumber = organizationNumber.trim();
    if (orgNumber.isEmpty) {
      return {'id': null, 'organization_number': null, 'name': null};
    }

    try {
      final rows = await SupabaseService.client
          .from('organizations')
          .select('id, organization_number, name')
          .eq('organization_number', orgNumber)
          .limit(1);

      if (rows.isNotEmpty) {
        final row = Map<String, dynamic>.from(rows.first as Map);
        return {
          'id': row['id']?.toString(),
          'organization_number': row['organization_number']?.toString(),
          'name': row['name']?.toString(),
        };
      }
    } catch (_) {}

    try {
      final PostgrestList rpcRows = await SupabaseService.client.rpc(
        'list_organizations_from_app',
      );
      for (final rpcRow in rpcRows) {
        final row = Map<String, dynamic>.from(rpcRow as Map);
        final rowOrgNumber =
            row['organization_number']?.toString().trim() ?? '';
        if (rowOrgNumber == orgNumber) {
          return {
            'id': row['id']?.toString(),
            'organization_number': row['organization_number']?.toString(),
            'name': row['name']?.toString(),
          };
        }
      }
    } catch (_) {}

    return {'id': null, 'organization_number': null, 'name': null};
  }

  Future<Map<String, String?>> getOrganizationDetailsById(
    String organizationId,
  ) async {
    final id = organizationId.trim();
    if (id.isEmpty) {
      return {'id': null, 'organization_number': null, 'name': null};
    }

    try {
      final rows = await SupabaseService.client
          .from('organizations')
          .select('id, organization_number, name')
          .eq('id', id)
          .limit(1);

      if (rows.isNotEmpty) {
        final row = Map<String, dynamic>.from(rows.first as Map);
        return {
          'id': row['id']?.toString(),
          'organization_number': row['organization_number']?.toString(),
          'name': row['name']?.toString(),
        };
      }
    } catch (_) {}

    try {
      final PostgrestList rpcRows = await SupabaseService.client.rpc(
        'list_organizations_from_app',
      );
      for (final rpcRow in rpcRows) {
        final row = Map<String, dynamic>.from(rpcRow as Map);
        final rowId = row['id']?.toString().trim() ?? '';
        if (rowId == id) {
          return {
            'id': row['id']?.toString(),
            'organization_number': row['organization_number']?.toString(),
            'name': row['name']?.toString(),
          };
        }
      }
    } catch (_) {}

    return {'id': null, 'organization_number': null, 'name': null};
  }

  Future<Map<String, String?>> getLocationDetailsById(String locationId) async {
    final id = locationId.trim();
    if (id.isEmpty) {
      return {
        'id': null,
        'organization_id': null,
        'name': null,
        'address': null,
        'address_1': null,
        'address_2': null,
        'city': null,
        'state': null,
        'zip': null,
        'phone': null,
        'allow_tip_adjustments': null,
        'print_tip_suggestions': null,
        'tip_suggestion_1_pct': null,
        'tip_suggestion_2_pct': null,
        'tip_suggestion_3_pct': null,
        'tip_suggestion_base': null,
        'receipt_card_signature_message': null,
        'receipt_misc_message': null,
        'receipt_reply_to_email': null,
        'invoice_reply_to_email': null,
      };
    }

    try {
      final rows = await SupabaseService.client
          .from('locations')
          .select(
            'id, organization_id, name, address, address_1, address_2, city, state, zip, phone, allow_tip_adjustments, print_tip_suggestions, tip_suggestion_1_pct, tip_suggestion_2_pct, tip_suggestion_3_pct, tip_suggestion_base, receipt_card_signature_message, receipt_misc_message, receipt_reply_to_email, invoice_reply_to_email',
          )
          .eq('id', id)
          .limit(1);

      if (rows.isNotEmpty) {
        final row = Map<String, dynamic>.from(rows.first as Map);
        return {
          'id': row['id']?.toString(),
          'organization_id': row['organization_id']?.toString(),
          'name': row['name']?.toString(),
          'address': row['address']?.toString(),
          'address_1': row['address_1']?.toString(),
          'address_2': row['address_2']?.toString(),
          'city': row['city']?.toString(),
          'state': row['state']?.toString(),
          'zip': row['zip']?.toString(),
          'phone': row['phone']?.toString(),
          'allow_tip_adjustments': row['allow_tip_adjustments']?.toString(),
          'print_tip_suggestions': row['print_tip_suggestions']?.toString(),
          'tip_suggestion_1_pct': row['tip_suggestion_1_pct']?.toString(),
          'tip_suggestion_2_pct': row['tip_suggestion_2_pct']?.toString(),
          'tip_suggestion_3_pct': row['tip_suggestion_3_pct']?.toString(),
          'tip_suggestion_base': row['tip_suggestion_base']?.toString(),
          'receipt_card_signature_message':
              row['receipt_card_signature_message']?.toString(),
          'receipt_misc_message': row['receipt_misc_message']?.toString(),
          'receipt_reply_to_email': row['receipt_reply_to_email']?.toString(),
          'invoice_reply_to_email': row['invoice_reply_to_email']?.toString(),
        };
      }
    } catch (_) {}

    try {
      final licenseKey = await _resolveLicenseKeyForLocationFallback();
      final rpcRows = await SupabaseService.client.rpc(
        'get_location_profile_for_license',
        params: {
          'p_license_key': licenseKey,
          'p_location_id': id,
          'p_location_name': null,
        },
      );

      if (rpcRows is List && rpcRows.isNotEmpty) {
        final row = Map<String, dynamic>.from(rpcRows.first as Map);
        final allowTip = _parseOptionalBool(row['allow_tip_adjustments']);
        return {
          'id': row['location_id']?.toString() ?? id,
          'organization_id': null,
          'name': row['location_name']?.toString(),
          'address': row['address_1']?.toString(),
          'address_1': row['address_1']?.toString(),
          'address_2': row['address_2']?.toString(),
          'city': row['city']?.toString(),
          'state': row['state']?.toString(),
          'zip': row['zip']?.toString(),
          'phone': row['phone']?.toString(),
          'allow_tip_adjustments': allowTip == null
              ? null
              : (allowTip ? 'true' : 'false'),
          'print_tip_suggestions': row['print_tip_suggestions']?.toString(),
          'tip_suggestion_1_pct': row['tip_suggestion_1_pct']?.toString(),
          'tip_suggestion_2_pct': row['tip_suggestion_2_pct']?.toString(),
          'tip_suggestion_3_pct': row['tip_suggestion_3_pct']?.toString(),
          'tip_suggestion_base': row['tip_suggestion_base']?.toString(),
          'receipt_card_signature_message':
              row['receipt_card_signature_message']?.toString(),
          'receipt_misc_message': row['receipt_misc_message']?.toString(),
          'receipt_reply_to_email': row['receipt_reply_to_email']?.toString(),
          'invoice_reply_to_email': row['invoice_reply_to_email']?.toString(),
        };
      }
    } catch (_) {}

    return {
      'id': null,
      'organization_id': null,
      'name': null,
      'address': null,
      'address_1': null,
      'address_2': null,
      'city': null,
      'state': null,
      'zip': null,
      'phone': null,
      'allow_tip_adjustments': null,
      'print_tip_suggestions': null,
      'tip_suggestion_1_pct': null,
      'tip_suggestion_2_pct': null,
      'tip_suggestion_3_pct': null,
      'tip_suggestion_base': null,
      'receipt_card_signature_message': null,
      'receipt_misc_message': null,
      'receipt_reply_to_email': null,
      'invoice_reply_to_email': null,
    };
  }

  Future<bool?> getLocationAllowTipAdjustmentsByLicenseContext({
    required String locationId,
    String locationName = '',
  }) async {
    final id = locationId.trim();
    if (id.isEmpty || !_isValidUuid(id)) {
      return null;
    }

    try {
      final licenseKey = await _resolveLicenseKeyForLocationFallback();
      final rpcRows = await SupabaseService.client.rpc(
        'get_location_profile_for_license',
        params: {
          'p_license_key': licenseKey,
          'p_location_id': id,
          'p_location_name': locationName.trim().isEmpty
              ? null
              : locationName.trim(),
        },
      );

      if (rpcRows is List && rpcRows.isNotEmpty) {
        final row = Map<String, dynamic>.from(rpcRows.first as Map);
        return _parseOptionalBool(row['allow_tip_adjustments']);
      }
    } catch (_) {}

    return null;
  }

  Future<Map<String, dynamic>?> getTerminalDetailsById(
    String terminalId,
  ) async {
    final id = terminalId.trim();
    if (id.isEmpty) return null;

    try {
      final rows = await SupabaseService.client
          .from('terminals')
          .select(
            'id, organization_id, location_id, terminal_number, name, code, is_active, '
            'registered_device_id, registered_device_label, terminal_token, spin_tpn, spin_auth_key, card_reader_type, card_reader_hpp_auth_token, receipt_printer_name, auto_close_batch_enabled, auto_close_batch_time',
          )
          .eq('id', id)
          .limit(1);

      if (rows.isNotEmpty) {
        final row = Map<String, dynamic>.from(rows.first as Map);
        row['auto_close_batch_enabled'] = _isTruthy(
          row['auto_close_batch_enabled'],
        );
        row['auto_close_batch_time'] = _normalizeSqlTimeString(
          row['auto_close_batch_time'],
        );
        return row;
      }
    } catch (_) {
      // Non-fatal; fall back to license-scoped RPC below.
    }

    // Fallback for environments where direct terminals table reads are blocked by
    // RLS/policies but list_terminals_from_app is available to anon/authenticated.
    try {
      final licenseKey = await _resolveLicenseKeyForLocationFallback();
      final locationName = (await LicenseService().getStoredLocationName()) ?? '';
      final rpcRows = await SupabaseService.client.rpc(
        'list_terminals_from_app',
        params: {
          'p_license_key': licenseKey,
          'p_location_name': locationName.trim().isEmpty
              ? null
              : locationName.trim(),
        },
      );

      if (rpcRows is List) {
        for (final raw in rpcRows) {
          final row = Map<String, dynamic>.from(raw as Map);
          final rowId =
              (row['id'] ?? row['terminal_id'] ?? row['terminalId'] ?? '')
                  .toString()
                  .trim();
          if (rowId != id) continue;

          row['id'] = rowId;
          row['terminal_number'] =
              (row['terminal_number'] ?? row['terminalNumber'] ?? '')
                  .toString();
          row['name'] =
              (row['terminal_name'] ?? row['name'] ?? '').toString();
          row['auto_close_batch_enabled'] = _isTruthy(
            row['auto_close_batch_enabled'] ??
                row['autoCloseBatchEnabled'] ??
                row['auto_close_enabled'] ??
                row['autoCloseEnabled'],
          );
          row['auto_close_batch_time'] = _normalizeSqlTimeString(
            row['auto_close_batch_time'] ??
                row['autoCloseBatchTime'] ??
                row['auto_close_time'] ??
                row['autoCloseTime'],
          );
          return row;
        }
      }
    } catch (_) {
      // Keep null when RPC detail fallback is unavailable.
    }

    return null;
  }

  Future<bool> locationHasDependencies(String locationId) async {
    final id = locationId.trim();
    if (id.isEmpty) return false;

    final terminals = await SupabaseService.client
        .from('terminals')
        .select('id')
        .eq('location_id', id)
        .limit(1);
    if (terminals.isNotEmpty) return true;

    final staff = await SupabaseService.client
        .from('staff')
        .select('id')
        .eq('location_id', id)
        .limit(1);
    return staff.isNotEmpty;
  }

  Future<void> insertLocationForm({
    String organizationId = '',
    required String organizationNumber,
    required String name,
    required String address,
    String address2 = '',
    String city = '',
    String state = '',
    String zip = '',
    String phone = '',
    int? terminalLicenses,
    int? terminalsActive,
    String processorProvider = '',
    String processorEnvironment = '',
    String processorMode = '',
    String epnApiLoginId = '',
    String epnUserId = '',
    String epnPassword = '',
    String epnRestrictKey = '',
    bool allowTipAdjustments = false,
    bool printTipSuggestions = true,
    String tipSuggestion1Pct = '18',
    String tipSuggestion2Pct = '20',
    String tipSuggestion3Pct = '25',
    String tipSuggestionBase = 'subtotal',
    String receiptCardSignatureMessage = '',
    String receiptMiscMessage = '',
    String receiptReplyToEmail = '',
  }) async {
    final orgIdInput = organizationId.trim();
    final orgNumber = organizationNumber.trim();
    final locationName = name.trim();
    final locationAddress = address.trim();
    final normalizedTipSuggestionBase =
        tipSuggestionBase.trim().toLowerCase() == 'total'
        ? 'total'
        : 'subtotal';

    if (locationName.isEmpty) {
      throw Exception('Location name is required.');
    }

    if (orgNumber.isEmpty) {
      try {
        final fallbackLocationId = await _upsertLocationViaLicenseRpcFallback(
          locationName: locationName,
          address: locationAddress,
          address2: address2,
          city: city,
          state: state,
          zip: zip,
          phone: phone,
          terminalLicenses: terminalLicenses,
          terminalsActive: terminalsActive,
          processorProvider: processorProvider,
          processorEnvironment: processorEnvironment,
          processorMode: processorMode,
          epnApiLoginId: epnApiLoginId,
          epnUserId: epnUserId,
          epnPassword: epnPassword,
          epnRestrictKey: epnRestrictKey,
          allowTipAdjustments: allowTipAdjustments,
          receiptReplyToEmail: receiptReplyToEmail,
        );
        if ((fallbackLocationId ?? '').trim().isNotEmpty) {
          await _ensureLocationReceiptSettingsPersisted(
            locationId: fallbackLocationId!,
            locationName: locationName,
            printTipSuggestions: printTipSuggestions,
            tipSuggestion1Pct: tipSuggestion1Pct,
            tipSuggestion2Pct: tipSuggestion2Pct,
            tipSuggestion3Pct: tipSuggestion3Pct,
            tipSuggestionBase: normalizedTipSuggestionBase,
            receiptCardSignatureMessage: receiptCardSignatureMessage,
            receiptMiscMessage: receiptMiscMessage,
            receiptReplyToEmail: receiptReplyToEmail,
          );
        }
        return;
      } catch (rpcError) {
        throw _buildDatabaseException(
          'Failed to add location (organization number missing and RPC fallback failed). Run updated supabase/license_setup.sql and ensure an active/stored license key is available',
          rpcError,
        );
      }
    }

    Map<String, String?> organizationDetails = {
      'id': null,
      'organization_number': null,
      'name': null,
    };

    if (orgIdInput.isNotEmpty && _isValidUuid(orgIdInput)) {
      organizationDetails = await getOrganizationDetailsById(orgIdInput);
    }

    if ((organizationDetails['id'] ?? '').trim().isEmpty) {
      organizationDetails = await getOrganizationDetailsByNumber(orgNumber);
    }

    final effectiveOrganizationId =
        (organizationDetails['id'] ?? '').trim().isNotEmpty
        ? (organizationDetails['id'] ?? '').trim()
        : orgIdInput;
    if (effectiveOrganizationId.isEmpty) {
      try {
        final fallbackLocationId = await _upsertLocationViaLicenseRpcFallback(
          locationName: locationName,
          address: locationAddress,
          address2: address2,
          city: city,
          state: state,
          zip: zip,
          phone: phone,
          terminalLicenses: terminalLicenses,
          terminalsActive: terminalsActive,
          processorProvider: processorProvider,
          processorEnvironment: processorEnvironment,
          processorMode: processorMode,
          epnApiLoginId: epnApiLoginId,
          epnUserId: epnUserId,
          epnPassword: epnPassword,
          epnRestrictKey: epnRestrictKey,
          allowTipAdjustments: allowTipAdjustments,
        );
        if ((fallbackLocationId ?? '').trim().isNotEmpty) {
          await _ensureLocationReceiptSettingsPersisted(
            locationId: fallbackLocationId!,
            locationName: locationName,
            printTipSuggestions: printTipSuggestions,
            tipSuggestion1Pct: tipSuggestion1Pct,
            tipSuggestion2Pct: tipSuggestion2Pct,
            tipSuggestion3Pct: tipSuggestion3Pct,
            tipSuggestionBase: normalizedTipSuggestionBase,
            receiptCardSignatureMessage: receiptCardSignatureMessage,
            receiptMiscMessage: receiptMiscMessage,
            receiptReplyToEmail: receiptReplyToEmail,
          );
        }
        return;
      } catch (rpcError) {
        throw _buildDatabaseException(
          'Failed to add location (organization context unresolved and RPC fallback failed). Re-run supabase/license_setup.sql and ensure an active license is set',
          rpcError,
        );
      }
    }

    final effectiveOrganizationNumber =
        (organizationDetails['organization_number'] ?? '').trim().isNotEmpty
        ? (organizationDetails['organization_number'] ?? '').trim()
        : orgNumber;

    final payload = <String, dynamic>{
      'organization_id': effectiveOrganizationId,
      'organization_number': effectiveOrganizationNumber,
      'name': locationName,
      'address': locationAddress,
      'address_2': address2.trim(),
      'city': city.trim(),
      'state': state.trim(),
      'zip': zip.trim(),
      'phone': _normalizePhoneDigits(phone.trim()),
      'terminal_licenses': terminalLicenses,
      'terminals_active': terminalsActive,
      'processor_provider': processorProvider.trim(),
      'processor_environment': processorEnvironment.trim(),
      'processor_mode': processorMode.trim(),
      'epn_api_login_id': epnApiLoginId.trim(),
      'epn_user_id': epnUserId.trim(),
      'epn_password': epnPassword.trim(),
      'epn_restrict_key': epnRestrictKey.trim(),
      'allow_tip_adjustments': allowTipAdjustments,
      'print_tip_suggestions': printTipSuggestions,
      'tip_suggestion_1_pct': double.tryParse(tipSuggestion1Pct.trim()) ?? 18,
      'tip_suggestion_2_pct': double.tryParse(tipSuggestion2Pct.trim()) ?? 20,
      'tip_suggestion_3_pct': double.tryParse(tipSuggestion3Pct.trim()) ?? 25,
      'tip_suggestion_base': normalizedTipSuggestionBase,
      'receipt_card_signature_message': receiptCardSignatureMessage.trim(),
      'receipt_misc_message': receiptMiscMessage.trim(),
      'receipt_reply_to_email': receiptReplyToEmail.trim(),
    };

    try {
      await _insertLocationsWithFallback(payload);
    } catch (error) {
      if (_isRlsOrPermissionError(error)) {
        try {
          final fallbackLocationId = await _upsertLocationViaLicenseRpcFallback(
            locationName: locationName,
            address: locationAddress,
            address2: address2,
            city: city,
            state: state,
            zip: zip,
            phone: phone,
            terminalLicenses: terminalLicenses,
            terminalsActive: terminalsActive,
            processorProvider: processorProvider,
            processorEnvironment: processorEnvironment,
            processorMode: processorMode,
            epnApiLoginId: epnApiLoginId,
            epnUserId: epnUserId,
            epnPassword: epnPassword,
            epnRestrictKey: epnRestrictKey,
            allowTipAdjustments: allowTipAdjustments,
          );
          if ((fallbackLocationId ?? '').trim().isNotEmpty) {
            await _ensureLocationReceiptSettingsPersisted(
              locationId: fallbackLocationId!,
              locationName: locationName,
              printTipSuggestions: printTipSuggestions,
              tipSuggestion1Pct: tipSuggestion1Pct,
              tipSuggestion2Pct: tipSuggestion2Pct,
              tipSuggestion3Pct: tipSuggestion3Pct,
              tipSuggestionBase: normalizedTipSuggestionBase,
              receiptCardSignatureMessage: receiptCardSignatureMessage,
              receiptMiscMessage: receiptMiscMessage,
              receiptReplyToEmail: receiptReplyToEmail,
            );
          }
          return;
        } catch (rpcError) {
          throw _buildDatabaseException(
            'Failed to add location (permission/RLS). RPC fallback via upsert_location_from_app failed. Re-run supabase/license_setup.sql and supabase/settings_tables_policies.sql',
            rpcError,
          );
        }
      }
      if (_isPostgrestError(error)) {
        throw _buildDatabaseException(
          'Failed to add location (PostgREST)',
          error,
        );
      }
      throw _buildDatabaseException('Failed to add location', error);
    }
  }

  Future<void> updateLocationForm({
    required dynamic id,
    String organizationId = '',
    required String organizationNumber,
    required String name,
    required String address,
    String address2 = '',
    String city = '',
    String state = '',
    String zip = '',
    String phone = '',
    int? terminalLicenses,
    int? terminalsActive,
    String processorProvider = '',
    String processorEnvironment = '',
    String processorMode = '',
    String epnApiLoginId = '',
    String epnUserId = '',
    String epnPassword = '',
    String epnRestrictKey = '',
    bool allowTipAdjustments = false,
    bool printTipSuggestions = true,
    String tipSuggestion1Pct = '18',
    String tipSuggestion2Pct = '20',
    String tipSuggestion3Pct = '25',
    String tipSuggestionBase = 'subtotal',
    String receiptCardSignatureMessage = '',
    String receiptMiscMessage = '',
    String receiptReplyToEmail = '',
  }) async {
    final locationId = id.toString().trim();
    final orgIdInput = organizationId.trim();
    final orgNumber = organizationNumber.trim();
    final locationName = name.trim();
    final locationAddress = address.trim();
    final normalizedTipSuggestionBase =
        tipSuggestionBase.trim().toLowerCase() == 'total'
        ? 'total'
        : 'subtotal';

    if (locationName.isEmpty) {
      throw Exception('Location name is required.');
    }

    if (orgNumber.isEmpty) {
      try {
        final fallbackLocationId = await _upsertLocationViaLicenseRpcFallback(
          locationId: locationId,
          locationName: locationName,
          address: locationAddress,
          address2: address2,
          city: city,
          state: state,
          zip: zip,
          phone: phone,
          terminalLicenses: terminalLicenses,
          terminalsActive: terminalsActive,
          processorProvider: processorProvider,
          processorEnvironment: processorEnvironment,
          processorMode: processorMode,
          epnApiLoginId: epnApiLoginId,
          epnUserId: epnUserId,
          epnPassword: epnPassword,
          epnRestrictKey: epnRestrictKey,
          allowTipAdjustments: allowTipAdjustments,
          receiptReplyToEmail: receiptReplyToEmail,
        );
        await _ensureLocationTipAdjustmentsPersisted(
          locationId: (fallbackLocationId ?? '').trim().isNotEmpty
              ? fallbackLocationId!
              : locationId,
          locationName: locationName,
          allowTipAdjustments: allowTipAdjustments,
        );
        await _ensureLocationReceiptSettingsPersisted(
          locationId: (fallbackLocationId ?? '').trim().isNotEmpty
              ? fallbackLocationId!
              : locationId,
          locationName: locationName,
          printTipSuggestions: printTipSuggestions,
          tipSuggestion1Pct: tipSuggestion1Pct,
          tipSuggestion2Pct: tipSuggestion2Pct,
          tipSuggestion3Pct: tipSuggestion3Pct,
          tipSuggestionBase: normalizedTipSuggestionBase,
          receiptCardSignatureMessage: receiptCardSignatureMessage,
          receiptMiscMessage: receiptMiscMessage,
          receiptReplyToEmail: receiptReplyToEmail,
        );
        return;
      } catch (rpcError) {
        throw _buildDatabaseException(
          'Failed to update location (organization number missing and RPC fallback failed). Run updated supabase/license_setup.sql and ensure an active/stored license key is available',
          rpcError,
        );
      }
    }

    Map<String, String?> organizationDetails = {
      'id': null,
      'organization_number': null,
      'name': null,
    };

    if (orgIdInput.isNotEmpty && _isValidUuid(orgIdInput)) {
      organizationDetails = await getOrganizationDetailsById(orgIdInput);
    }

    if ((organizationDetails['id'] ?? '').trim().isEmpty) {
      organizationDetails = await getOrganizationDetailsByNumber(orgNumber);
    }

    final effectiveOrganizationId =
        (organizationDetails['id'] ?? '').trim().isNotEmpty
        ? (organizationDetails['id'] ?? '').trim()
        : orgIdInput;
    if (effectiveOrganizationId.isEmpty) {
      try {
        final fallbackLocationId = await _upsertLocationViaLicenseRpcFallback(
          locationId: locationId,
          locationName: locationName,
          address: locationAddress,
          address2: address2,
          city: city,
          state: state,
          zip: zip,
          phone: phone,
          terminalLicenses: terminalLicenses,
          terminalsActive: terminalsActive,
          processorProvider: processorProvider,
          processorEnvironment: processorEnvironment,
          processorMode: processorMode,
          epnApiLoginId: epnApiLoginId,
          epnUserId: epnUserId,
          epnPassword: epnPassword,
          epnRestrictKey: epnRestrictKey,
          allowTipAdjustments: allowTipAdjustments,
          receiptReplyToEmail: receiptReplyToEmail,
        );
        await _ensureLocationTipAdjustmentsPersisted(
          locationId: (fallbackLocationId ?? '').trim().isNotEmpty
              ? fallbackLocationId!
              : locationId,
          locationName: locationName,
          allowTipAdjustments: allowTipAdjustments,
        );
        await _ensureLocationReceiptSettingsPersisted(
          locationId: (fallbackLocationId ?? '').trim().isNotEmpty
              ? fallbackLocationId!
              : locationId,
          locationName: locationName,
          printTipSuggestions: printTipSuggestions,
          tipSuggestion1Pct: tipSuggestion1Pct,
          tipSuggestion2Pct: tipSuggestion2Pct,
          tipSuggestion3Pct: tipSuggestion3Pct,
          tipSuggestionBase: normalizedTipSuggestionBase,
          receiptCardSignatureMessage: receiptCardSignatureMessage,
          receiptMiscMessage: receiptMiscMessage,
          receiptReplyToEmail: receiptReplyToEmail,
        );
        return;
      } catch (rpcError) {
        throw _buildDatabaseException(
          'Failed to update location (organization context unresolved and RPC fallback failed). Re-run supabase/license_setup.sql and ensure an active license is set',
          rpcError,
        );
      }
    }

    final effectiveOrganizationNumber =
        (organizationDetails['organization_number'] ?? '').trim().isNotEmpty
        ? (organizationDetails['organization_number'] ?? '').trim()
        : orgNumber;

    final payload = <String, dynamic>{
      'organization_id': effectiveOrganizationId,
      'organization_number': effectiveOrganizationNumber,
      'name': locationName,
      'address': locationAddress,
      'address_2': address2.trim(),
      'city': city.trim(),
      'state': state.trim(),
      'zip': zip.trim(),
      'phone': _normalizePhoneDigits(phone.trim()),
      'terminal_licenses': terminalLicenses,
      'terminals_active': terminalsActive,
      'processor_provider': processorProvider.trim(),
      'processor_environment': processorEnvironment.trim(),
      'processor_mode': processorMode.trim(),
      'epn_api_login_id': epnApiLoginId.trim(),
      'epn_user_id': epnUserId.trim(),
      'epn_password': epnPassword.trim(),
      'epn_restrict_key': epnRestrictKey.trim(),
      'allow_tip_adjustments': allowTipAdjustments,
      'print_tip_suggestions': printTipSuggestions,
      'tip_suggestion_1_pct': double.tryParse(tipSuggestion1Pct.trim()) ?? 18,
      'tip_suggestion_2_pct': double.tryParse(tipSuggestion2Pct.trim()) ?? 20,
      'tip_suggestion_3_pct': double.tryParse(tipSuggestion3Pct.trim()) ?? 25,
      'tip_suggestion_base': normalizedTipSuggestionBase,
      'receipt_card_signature_message': receiptCardSignatureMessage.trim(),
      'receipt_misc_message': receiptMiscMessage.trim(),
      'receipt_reply_to_email': receiptReplyToEmail.trim(),
    };

    try {
      await _updateLocationsWithFallback(id: id, payload: payload);
    } catch (error) {
      if (_isRlsOrPermissionError(error) ||
          _isPostgrestError(error) ||
          _isNoMatchingLocationUpdateError(error)) {
        try {
          final fallbackLocationId = await _upsertLocationViaLicenseRpcFallback(
            locationId: locationId,
            locationName: locationName,
            address: locationAddress,
            address2: address2,
            city: city,
            state: state,
            zip: zip,
            phone: phone,
            terminalLicenses: terminalLicenses,
            terminalsActive: terminalsActive,
            processorProvider: processorProvider,
            processorEnvironment: processorEnvironment,
            processorMode: processorMode,
            epnApiLoginId: epnApiLoginId,
            epnUserId: epnUserId,
            epnPassword: epnPassword,
            epnRestrictKey: epnRestrictKey,
            allowTipAdjustments: allowTipAdjustments,
            receiptReplyToEmail: receiptReplyToEmail,
          );
          await _ensureLocationReceiptSettingsPersisted(
            locationId: (fallbackLocationId ?? '').trim().isNotEmpty
                ? fallbackLocationId!
                : locationId,
            locationName: locationName,
            printTipSuggestions: printTipSuggestions,
            tipSuggestion1Pct: tipSuggestion1Pct,
            tipSuggestion2Pct: tipSuggestion2Pct,
            tipSuggestion3Pct: tipSuggestion3Pct,
            tipSuggestionBase: normalizedTipSuggestionBase,
            receiptCardSignatureMessage: receiptCardSignatureMessage,
            receiptMiscMessage: receiptMiscMessage,
            receiptReplyToEmail: receiptReplyToEmail,
          );
        } catch (rpcError) {
          throw _buildDatabaseException(
            'Failed to update location (RPC fallback failed). Re-run supabase/license_setup.sql and supabase/settings_tables_policies.sql',
            rpcError,
          );
        }
      } else {
        throw _buildDatabaseException('Failed to update location', error);
      }
    }

    try {
      await _ensureLocationTipAdjustmentsPersisted(
        locationId: locationId,
        locationName: locationName,
        allowTipAdjustments: allowTipAdjustments,
      );
      await _ensureLocationReceiptSettingsPersisted(
        locationId: locationId,
        locationName: locationName,
        printTipSuggestions: printTipSuggestions,
        tipSuggestion1Pct: tipSuggestion1Pct,
        tipSuggestion2Pct: tipSuggestion2Pct,
        tipSuggestion3Pct: tipSuggestion3Pct,
        tipSuggestionBase: normalizedTipSuggestionBase,
        receiptCardSignatureMessage: receiptCardSignatureMessage,
        receiptMiscMessage: receiptMiscMessage,
        receiptReplyToEmail: receiptReplyToEmail,
      );
    } catch (error) {
      throw _buildDatabaseException(
        'Location updated, but receipt settings verification failed',
        error,
      );
    }
  }

  Future<void> insertStaffForm({
    required String organizationId,
    required String locationId,
    required String firstName,
    required String pin,
    String lastName = '',
    String email = '',
    String phone = '',
    String role = 'cashier',
    bool isActive = true,
  }) async {
    final orgId = organizationId.trim();
    final locId = locationId.trim();
    final first = firstName.trim();
    final last = lastName.trim();
    final normalizedPin = pin.trim();
    final normalizedRole = _normalizeStaffRole(role);

    if (orgId.isEmpty || locId.isEmpty) {
      throw Exception('Organization ID and Location ID are required.');
    }
    if (!_isValidUuid(orgId) || !_isValidUuid(locId)) {
      throw Exception(
        'Organization ID and Location ID must be valid UUID values.',
      );
    }
    if (first.isEmpty) {
      throw Exception('First Name is required.');
    }
    if (!_isValidStaffPin(normalizedPin)) {
      throw Exception('PIN must be numeric and no more than 6 digits.');
    }
    await _assertUniqueStaffPinInScope(
      organizationId: orgId,
      locationId: locId,
      pin: normalizedPin,
    );

    final payload = <String, dynamic>{
      'organization_id': orgId,
      'location_id': locId,
      'first_name': first,
      'last_name': last,
      'email': null,
      'phone': phone.trim().isEmpty ? null : _normalizePhoneDigits(phone),
      'role': normalizedRole,
      'is_active': isActive,
      'full_name': _buildStaffFullName(first, last),
      'pin': normalizedPin,
    };

    try {
      await SupabaseService.client
          .from('staff')
          .insert(payload)
          .select('id')
          .limit(1);
    } catch (error) {
      if (_isStaffPinUniqueViolation(error)) {
        throw Exception(
          'PIN already exists for another staff member in this location. Choose a unique PIN.',
        );
      }
      if (_isRlsOrPermissionError(error) || _isPostgrestError(error)) {
        try {
          await _upsertStaffViaLicenseRpcFallback(
            locationId: locId,
            firstName: first,
            lastName: last,
            email: email,
            phone: phone,
            pin: normalizedPin,
            role: normalizedRole,
            isActive: isActive,
          );
          return;
        } catch (rpcError) {
          if (_isStaffPinUniqueViolation(rpcError)) {
            throw Exception(
              'PIN already exists for another staff member in this location. Choose a unique PIN.',
            );
          }
          throw _buildDatabaseException(
            'Failed to add staff (permission/RLS). RPC fallback via upsert_staff_from_app failed. Run updated supabase/license_setup.sql or supabase/2026-03-14_add_staff_pin.sql',
            rpcError,
          );
        }
      }
      throw _buildDatabaseException('Failed to add staff', error);
    }
  }

  Future<void> updateStaffForm({
    required dynamic id,
    required String organizationId,
    required String locationId,
    required String firstName,
    required String pin,
    String lastName = '',
    String email = '',
    String phone = '',
    String role = 'cashier',
    bool isActive = true,
  }) async {
    final staffId = id.toString().trim();
    final orgId = organizationId.trim();
    final locId = locationId.trim();
    final first = firstName.trim();
    final last = lastName.trim();
    final normalizedPin = pin.trim();
    final normalizedRole = _normalizeStaffRole(role);

    if (staffId.isEmpty) {
      throw Exception('Staff id is required to update a staff record.');
    }
    if (orgId.isEmpty || locId.isEmpty) {
      throw Exception('Organization ID and Location ID are required.');
    }
    if (!_isValidUuid(orgId) || !_isValidUuid(locId)) {
      throw Exception(
        'Organization ID and Location ID must be valid UUID values.',
      );
    }
    if (first.isEmpty) {
      throw Exception('First Name is required.');
    }
    if (!_isValidStaffPin(normalizedPin)) {
      throw Exception('PIN must be numeric and no more than 6 digits.');
    }
    await _assertUniqueStaffPinInScope(
      organizationId: orgId,
      locationId: locId,
      pin: normalizedPin,
      excludeStaffId: staffId,
    );

    final payload = <String, dynamic>{
      'organization_id': orgId,
      'location_id': locId,
      'first_name': first,
      'last_name': last,
      'email': null,
      'phone': phone.trim().isEmpty ? null : _normalizePhoneDigits(phone),
      'role': normalizedRole,
      'is_active': isActive,
      'full_name': _buildStaffFullName(first, last),
      'pin': normalizedPin,
    };

    try {
      final PostgrestList updated = await SupabaseService.client
          .from('staff')
          .update(payload)
          .eq('id', staffId)
          .select('id')
          .limit(1);

      if (updated.isEmpty) {
        throw Exception('No matching staff row was updated.');
      }
    } catch (error) {
      if (_isStaffPinUniqueViolation(error)) {
        throw Exception(
          'PIN already exists for another staff member in this location. Choose a unique PIN.',
        );
      }
      if (_isRlsOrPermissionError(error) ||
          _isPostgrestError(error) ||
          _isNoMatchingStaffUpdateError(error)) {
        try {
          await _upsertStaffViaLicenseRpcFallback(
            staffId: staffId,
            locationId: locId,
            firstName: first,
            lastName: last,
            email: email,
            phone: phone,
            pin: normalizedPin,
            role: normalizedRole,
            isActive: isActive,
          );
          return;
        } catch (rpcError) {
          if (_isStaffPinUniqueViolation(rpcError)) {
            throw Exception(
              'PIN already exists for another staff member in this location. Choose a unique PIN.',
            );
          }
          throw _buildDatabaseException(
            'Failed to update staff (permission/RLS). RPC fallback via upsert_staff_from_app failed. Run updated supabase/license_setup.sql or supabase/2026-03-14_add_staff_pin.sql',
            rpcError,
          );
        }
      }
      throw _buildDatabaseException('Failed to update staff', error);
    }
  }

  Future<void> insertTerminalForm({
    required String locationId,
    required String terminalNumber,
    required String name,
    String code = '',
    String spinTpn = '',
    String spinAuthKey = '',
    String cardReaderType = 'dejavoo_p12',
    String cardReaderHppAuthToken = '',
    bool isActive = true,
    String receiptPrinterName = '',
    bool? autoCloseBatchEnabled,
    String? autoCloseBatchTime,
  }) async {
    final locId = locationId.trim();
    final number = terminalNumber.trim();
    final terminalName = name.trim();

    if (locId.isEmpty || !_isValidUuid(locId)) {
      throw Exception('Location ID is required and must be a valid UUID.');
    }
    if (!_isValidTerminalNumber(number)) {
      throw Exception('Terminal Number must be exactly 4 digits.');
    }
    if (terminalName.isEmpty) {
      throw Exception('Terminal Name is required.');
    }

    try {
      await _upsertTerminalViaLicenseRpcFallback(
        locationId: locId,
        terminalNumber: number,
        name: terminalName,
        code: code,
        spinTpn: spinTpn,
        spinAuthKey: spinAuthKey,
        cardReaderType: cardReaderType,
        cardReaderHppAuthToken: cardReaderHppAuthToken,
        isActive: isActive,
        receiptPrinterName: receiptPrinterName,
        autoCloseBatchEnabled: autoCloseBatchEnabled,
        autoCloseBatchTime: autoCloseBatchTime,
      );
    } catch (error) {
      throw _buildDatabaseException(
        'Failed to add terminal. Run migrations supabase/2026-05-17_terminal_card_reader_type.sql, supabase/2026-05-18_terminal_card_reader_hpp_auth_token.sql, and supabase/2026-05-29_terminal_spin_upsert_rpc.sql (and updated supabase/license_setup.sql if needed).',
        error,
      );
    }
  }

  Future<void> updateTerminalForm({
    required dynamic id,
    required String locationId,
    required String terminalNumber,
    required String name,
    String code = '',
    String spinTpn = '',
    String spinAuthKey = '',
    String cardReaderType = 'dejavoo_p12',
    String cardReaderHppAuthToken = '',
    bool isActive = true,
    String receiptPrinterName = '',
    bool? autoCloseBatchEnabled,
    String? autoCloseBatchTime,
  }) async {
    final terminalId = id.toString().trim();
    final locId = locationId.trim();
    final number = terminalNumber.trim();
    final terminalName = name.trim();

    if (terminalId.isEmpty) {
      throw Exception('Terminal id is required to update a terminal.');
    }
    if (locId.isEmpty || !_isValidUuid(locId)) {
      throw Exception('Location ID is required and must be a valid UUID.');
    }
    if (!_isValidTerminalNumber(number)) {
      throw Exception('Terminal Number must be exactly 4 digits.');
    }
    if (terminalName.isEmpty) {
      throw Exception('Terminal Name is required.');
    }

    try {
      await _upsertTerminalViaLicenseRpcFallback(
        terminalId: terminalId,
        locationId: locId,
        terminalNumber: number,
        name: terminalName,
        code: code,
        spinTpn: spinTpn,
        spinAuthKey: spinAuthKey,
        cardReaderType: cardReaderType,
        cardReaderHppAuthToken: cardReaderHppAuthToken,
        isActive: isActive,
        receiptPrinterName: receiptPrinterName,
        autoCloseBatchEnabled: autoCloseBatchEnabled,
        autoCloseBatchTime: autoCloseBatchTime,
      );
    } catch (error) {
      throw _buildDatabaseException(
        'Failed to update terminal. Run migrations supabase/2026-05-17_terminal_card_reader_type.sql, supabase/2026-05-18_terminal_card_reader_hpp_auth_token.sql, and supabase/2026-05-29_terminal_spin_upsert_rpc.sql (and updated supabase/license_setup.sql if needed).',
        error,
      );
    }
  }

  Future<void> insertOrganizationForm({
    required String organizationNumber,
    required String name,
    required String licenseKey,
    bool autoCloseBatchEnabled = false,
    String autoCloseBatchTime = '',
  }) async {
    final orgNumber = organizationNumber.trim();
    final orgName = name.trim();
    final orgLicenseKey = licenseKey.trim();

    if (orgNumber.isEmpty || orgName.isEmpty) {
      throw Exception('Organization number and name are required.');
    }
    if (!_isValidOrganizationNumber(orgNumber)) {
      throw Exception('Organization number must be exactly 6 digits.');
    }

    final existing = await SupabaseService.client
        .from('organizations')
        .select('id')
        .eq('organization_number', orgNumber)
        .limit(1);
    if (existing.isNotEmpty) {
      throw Exception('Organization number $orgNumber already exists.');
    }

    final payload = <String, dynamic>{
      'organization_number': orgNumber,
      'name': orgName,
      'license_key': orgLicenseKey,
      'auto_close_batch_enabled': autoCloseBatchEnabled,
      'auto_close_batch_time': autoCloseBatchTime.trim().isEmpty
          ? null
          : autoCloseBatchTime.trim(),
    };

    Future<void> applyAutoCloseSettings() async {
      try {
        final autoPayload = <String, dynamic>{
          'auto_close_batch_enabled': autoCloseBatchEnabled,
          'auto_close_batch_time': autoCloseBatchTime.trim().isEmpty
              ? null
              : autoCloseBatchTime.trim(),
        };

        final PostgrestList byOrgNumber = await SupabaseService.client
            .from('organizations')
            .update(autoPayload)
            .eq('organization_number', orgNumber)
            .select('id')
            .limit(1);
        if (byOrgNumber.isNotEmpty) return;
      } catch (_) {}

      // Fallback to RPC path when direct table update is not allowed.
      await SupabaseService.client.rpc(
        'set_organization_auto_close_from_app',
        params: {
          'p_organization_number': orgNumber,
          'p_auto_close_batch_enabled': autoCloseBatchEnabled,
          'p_auto_close_batch_time': autoCloseBatchTime.trim().isEmpty
              ? null
              : autoCloseBatchTime.trim(),
        },
      );
    }

    try {
      await SupabaseService.client.from('organizations').insert(payload);
      await applyAutoCloseSettings();
      return;
    } catch (error) {
      if (_isMissingLicenseColumnError(error)) {
        try {
          payload.remove('license_key');
          payload.remove('auto_close_batch_enabled');
          payload.remove('auto_close_batch_time');
          await SupabaseService.client.from('organizations').insert(payload);
          await applyAutoCloseSettings();
          return;
        } catch (retryError) {
          throw _buildDatabaseException(
            'Failed to add organization (retry without license_key failed)',
            retryError,
          );
        }
      }

      if (_isRlsOrPermissionError(error)) {
        try {
          await SupabaseService.client.rpc(
            'upsert_organization_from_app',
            params: {
              'p_organization_number': orgNumber,
              'p_name': orgName,
              'p_license_key': orgLicenseKey,
            },
          );
          await applyAutoCloseSettings();
          return;
        } catch (rpcError) {
          throw _buildDatabaseException(
            'Failed to add organization (RPC fallback failed). Run updated supabase/license_setup.sql',
            rpcError,
          );
        }
      }

      throw _buildDatabaseException('Failed to add organization', error);
    }
  }

  Future<void> updateOrganizationForm({
    required dynamic id,
    required String organizationNumber,
    required String name,
    required String licenseKey,
    bool autoCloseBatchEnabled = false,
    String autoCloseBatchTime = '',
  }) async {
    final orgNumber = organizationNumber.trim();
    final orgName = name.trim();
    final orgLicenseKey = licenseKey.trim();
    final existingRows = await SupabaseService.client
        .from('organizations')
        .select('license_key')
        .eq('id', id)
        .limit(1);
    final existingLicenseKey = existingRows.isNotEmpty
        ? Map<String, dynamic>.from(
                existingRows.first as Map,
              )['license_key']?.toString().trim() ??
              ''
        : '';
    final effectiveLicenseKey = existingLicenseKey.isNotEmpty
        ? existingLicenseKey
        : orgLicenseKey;
    final persistedOrgNumber = await getOrganizationNumberById(id.toString());
    final effectiveOrgNumber = (persistedOrgNumber ?? '').trim().isNotEmpty
        ? persistedOrgNumber!.trim()
        : orgNumber;

    if (effectiveOrgNumber.isEmpty || orgName.isEmpty) {
      throw Exception('Organization number and name are required.');
    }
    if (!_isValidOrganizationNumber(effectiveOrgNumber)) {
      throw Exception('Organization number must be exactly 6 digits.');
    }

    final payload = <String, dynamic>{
      'name': orgName,
      'license_key': effectiveLicenseKey,
      'auto_close_batch_enabled': autoCloseBatchEnabled,
      'auto_close_batch_time': autoCloseBatchTime.trim().isEmpty
          ? null
          : autoCloseBatchTime.trim(),
    };

    Future<void> applyAutoCloseSettings() async {
      final autoPayload = <String, dynamic>{
        'auto_close_batch_enabled': autoCloseBatchEnabled,
        'auto_close_batch_time': autoCloseBatchTime.trim().isEmpty
            ? null
            : autoCloseBatchTime.trim(),
      };

      try {
        final PostgrestList updatedById = await SupabaseService.client
            .from('organizations')
            .update(autoPayload)
            .eq('id', id)
            .select('id')
            .limit(1);
        if (updatedById.isNotEmpty) return;
      } catch (_) {}

      try {
        final PostgrestList updatedByOrganizationNumber = await SupabaseService
            .client
            .from('organizations')
            .update(autoPayload)
            .eq('organization_number', effectiveOrgNumber)
            .select('id')
            .limit(1);
        if (updatedByOrganizationNumber.isNotEmpty) return;
      } catch (_) {}

      await SupabaseService.client.rpc(
        'set_organization_auto_close_from_app',
        params: {
          'p_organization_number': effectiveOrgNumber,
          'p_auto_close_batch_enabled': autoCloseBatchEnabled,
          'p_auto_close_batch_time': autoCloseBatchTime.trim().isEmpty
              ? null
              : autoCloseBatchTime.trim(),
        },
      );
    }

    try {
      final PostgrestList updatedById = await SupabaseService.client
          .from('organizations')
          .update(payload)
          .eq('id', id)
          .select('id')
          .limit(1);

      if (updatedById.isNotEmpty) {
        await applyAutoCloseSettings();
        return;
      }

      final PostgrestList updatedByOrganizationNumber = await SupabaseService
          .client
          .from('organizations')
          .update(payload)
          .eq('organization_number', effectiveOrgNumber)
          .select('id')
          .limit(1);

      if (updatedByOrganizationNumber.isNotEmpty) {
        await applyAutoCloseSettings();
        return;
      }

      await SupabaseService.client.rpc(
        'upsert_organization_from_app',
        params: {
          'p_id': id,
          'p_organization_number': effectiveOrgNumber,
          'p_name': orgName,
          'p_license_key': effectiveLicenseKey,
        },
      );
      await applyAutoCloseSettings();
      return;
    } catch (error) {
      if (_isMissingLicenseColumnError(error)) {
        try {
          payload.remove('license_key');
          payload.remove('auto_close_batch_enabled');
          payload.remove('auto_close_batch_time');
          final PostgrestList updatedById = await SupabaseService.client
              .from('organizations')
              .update(payload)
              .eq('id', id)
              .select('id')
              .limit(1);

          if (updatedById.isNotEmpty) {
            await applyAutoCloseSettings();
            return;
          }

          final PostgrestList updatedByOrganizationNumber =
              await SupabaseService.client
                  .from('organizations')
                  .update(payload)
                  .eq('organization_number', effectiveOrgNumber)
                  .select('id')
                  .limit(1);

          if (updatedByOrganizationNumber.isNotEmpty) {
            await applyAutoCloseSettings();
            return;
          }

          await SupabaseService.client.rpc(
            'upsert_organization_from_app',
            params: {
              'p_id': id,
              'p_organization_number': effectiveOrgNumber,
              'p_name': orgName,
              'p_license_key': effectiveLicenseKey,
            },
          );
          await applyAutoCloseSettings();
          return;
        } catch (retryError) {
          throw _buildDatabaseException(
            'Failed to update organization (retry without license_key failed)',
            retryError,
          );
        }
      }

      if (_isRlsOrPermissionError(error)) {
        try {
          await SupabaseService.client.rpc(
            'upsert_organization_from_app',
            params: {
              'p_id': id,
              'p_organization_number': effectiveOrgNumber,
              'p_name': orgName,
              'p_license_key': effectiveLicenseKey,
            },
          );
          await applyAutoCloseSettings();
          return;
        } catch (rpcError) {
          throw _buildDatabaseException(
            'Failed to update organization (RPC fallback failed). Run updated supabase/license_setup.sql',
            rpcError,
          );
        }
      }

      throw _buildDatabaseException('Failed to update organization', error);
    }
  }
}
