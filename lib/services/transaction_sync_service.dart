import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../terminal_config.dart';
import '../supabase_config.dart';
import 'license_service.dart';
import 'settings_data_service.dart';
import 'supabase_service.dart';
import 'transaction_flow_parameters.dart';
import '../utils/receipt_id_format.dart';

class _TenantScope {
  final String organizationId;
  final String locationId;
  final String? terminalId;
  final String? organizationNumber;
  final String? terminalNumber;

  const _TenantScope({
    required this.organizationId,
    required this.locationId,
    this.terminalId,
    this.organizationNumber,
    this.terminalNumber,
  });
}

class RefundVerificationCheck {
  final String label;
  final bool passed;
  final String detail;

  const RefundVerificationCheck({
    required this.label,
    required this.passed,
    required this.detail,
  });
}

class RefundVerificationResult {
  final String? fetchError;
  final Map<String, dynamic>? refundRow;
  final Map<String, dynamic>? originalRow;
  final Map<String, dynamic>? headerRow;
  final List<RefundVerificationCheck> checks;

  const RefundVerificationResult({
    this.fetchError,
    this.refundRow,
    this.originalRow,
    this.headerRow,
    this.checks = const [],
  });

  bool get passed =>
      fetchError == null && checks.every((check) => check.passed);
}

class TransactionSyncService {
  _TenantScope? _cachedScope;
  final SettingsDataService _settingsDataService = SettingsDataService();
  static const String _cardBatchHeadersTable = 'card_batch_headers';
  static const String _cardBatchDetailsTable = 'card_batch_details';

  List<String> _buildPinCandidates(String pin) {
    final normalizedPin = pin.trim();
    if (normalizedPin.isEmpty) return const [];

    final candidates = <String>{normalizedPin};
    if (normalizedPin.length < 4) {
      candidates.add(normalizedPin.padLeft(4, '0'));
    }
    if (normalizedPin.length < 6) {
      candidates.add(normalizedPin.padLeft(6, '0'));
    }
    return candidates.toList();
  }

  String get _backendBase {
    const raw = String.fromEnvironment(
      'PAYMENT_API_BASE_URL',
      defaultValue: 'http://localhost:3000',
    );
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  double _asDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  int _asInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }

  String _deriveTerminalNumber({
    required _TenantScope scope,
    required String terminalName,
  }) {
    final scopeTerminal = scope.terminalNumber?.trim() ?? '';
    if (scopeTerminal.isNotEmpty) return scopeTerminal;

    final digits = terminalName.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isNotEmpty) {
      return digits.length <= 3 ? digits.padLeft(3, '0') : digits;
    }

    return '';
  }

  Future<int> _resolveHeaderBatchNumber({
    required _TenantScope scope,
    required String terminalNumber,
    int? requestedBatchNumber,
  }) async {
    if (requestedBatchNumber != null && requestedBatchNumber > 0) {
      return requestedBatchNumber;
    }

    try {
      final row = terminalNumber.trim().isNotEmpty
          ? await SupabaseService.client
                .from('transaction_headers')
                .select('batch_number')
                .eq('organization_id', scope.organizationId)
                .eq('location_id', scope.locationId)
                .eq('terminal_number', terminalNumber.trim())
                .not('batch_number', 'is', null)
                .order('created_at', ascending: false)
                .limit(1)
                .maybeSingle()
          : await SupabaseService.client
                .from('transaction_headers')
                .select('batch_number')
                .eq('organization_id', scope.organizationId)
                .eq('location_id', scope.locationId)
                .not('batch_number', 'is', null)
                .order('created_at', ascending: false)
                .limit(1)
                .maybeSingle();

      if (row != null) {
        final parsed = _asInt(row['batch_number']);
        if (parsed > 0) return parsed;
      }
    } catch (error) {
      debugPrint('resolve header batch number failed, defaulting to 1: $error');
    }

    return 1;
  }

  Future<int> resolveActiveHeaderBatchNumber() async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) return 1;

      final openRow =
          await ((scope.terminalId != null && scope.terminalId!.isNotEmpty)
              ? SupabaseService.client
                    .from('transaction_details')
                    .select(
                      'created_at,transaction_headers!inner(batch_number,terminal_id,terminal_number)',
                    )
                    .eq('organization_id', scope.organizationId)
                    .eq('location_id', scope.locationId)
                    .eq('payment_type', 'd')
                    .eq('batch_status', 'o')
                    .eq('transaction_headers.terminal_id', scope.terminalId!)
                    .order('created_at', ascending: false)
                    .limit(1)
                    .maybeSingle()
              : SupabaseService.client
                    .from('transaction_details')
                    .select(
                      'created_at,transaction_headers!inner(batch_number,terminal_id,terminal_number)',
                    )
                    .eq('organization_id', scope.organizationId)
                    .eq('location_id', scope.locationId)
                    .eq('payment_type', 'd')
                    .eq('batch_status', 'o')
                    .order('created_at', ascending: false)
                    .limit(1)
                    .maybeSingle());

      if (openRow != null) {
        final header = openRow['transaction_headers'];
        if (header is Map) {
          final openBatch = _asInt(header['batch_number']);
          if (openBatch > 0) {
            return openBatch;
          }
        }
      }

      final latestClosed =
          await ((scope.terminalId != null && scope.terminalId!.isNotEmpty)
              ? SupabaseService.client
                    .from(_cardBatchHeadersTable)
                    .select('batch_number')
                    .eq('organization_id', scope.organizationId)
                    .eq('location_id', scope.locationId)
                    .eq('terminal_id', scope.terminalId!)
                    .order('created_at', ascending: false)
                    .limit(1)
                    .maybeSingle()
              : SupabaseService.client
                    .from(_cardBatchHeadersTable)
                    .select('batch_number')
                    .eq('organization_id', scope.organizationId)
                    .eq('location_id', scope.locationId)
                    .order('created_at', ascending: false)
                    .limit(1)
                    .maybeSingle());

      final latestClosedBatch = _asInt(latestClosed?['batch_number']);
      if (latestClosedBatch > 0) {
        return latestClosedBatch + 1;
      }

      final latestHeader =
          await ((scope.terminalId != null && scope.terminalId!.isNotEmpty)
              ? SupabaseService.client
                    .from('transaction_headers')
                    .select('batch_number')
                    .eq('organization_id', scope.organizationId)
                    .eq('location_id', scope.locationId)
                    .eq('terminal_id', scope.terminalId!)
                    .not('batch_number', 'is', null)
                    .order('created_at', ascending: false)
                    .limit(1)
                    .maybeSingle()
              : SupabaseService.client
                    .from('transaction_headers')
                    .select('batch_number')
                    .eq('organization_id', scope.organizationId)
                    .eq('location_id', scope.locationId)
                    .not('batch_number', 'is', null)
                    .order('created_at', ascending: false)
                    .limit(1)
                    .maybeSingle());

      final latestHeaderBatch = _asInt(latestHeader?['batch_number']);
      if (latestHeaderBatch > 0) {
        return latestHeaderBatch;
      }

      return 1;
    } catch (error) {
      debugPrint('resolveActiveHeaderBatchNumber failed: $error');
      return 1;
    }
  }

  String _firstNonEmpty(Map<String, dynamic> row, List<String> keys) {
    for (final key in keys) {
      final value = row[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _buildStaffDisplayName(Map<String, dynamic> staff) {
    final firstName = staff['first_name']?.toString().trim() ?? '';
    final lastName = staff['last_name']?.toString().trim() ?? '';
    final combinedName = '$firstName $lastName'.trim();
    if (combinedName.isNotEmpty) return combinedName;

    final fullName = staff['full_name']?.toString().trim() ?? '';
    if (fullName.isNotEmpty) return fullName;

    final name = staff['name']?.toString().trim() ?? '';
    if (name.isNotEmpty) return name;

    final email = staff['email']?.toString().trim() ?? '';
    if (email.isNotEmpty) return email;

    return 'STAFF';
  }

  String _licenseLookupKey() {
    final active = LicenseService().activeContext;
    final licenseKey = active?.licenseKey.trim() ?? '';
    if (licenseKey.isNotEmpty) return licenseKey;

    final orgNumber = active?.organizationNumber.trim() ?? '';
    if (orgNumber.isNotEmpty) return orgNumber;

    if (SupabaseConfig.organizationNumber.trim().isNotEmpty) {
      return SupabaseConfig.organizationNumber.trim();
    }
    return '';
  }

  Future<String> diagnoseStaffPinLogin(String pin) async {
    final normalizedPin = pin.trim();
    final out = StringBuffer();

    out.writeln('PIN Diagnostics');
    out.writeln('pin="$normalizedPin"');

    if (normalizedPin.isEmpty ||
        !RegExp(r'^\d{1,6}$').hasMatch(normalizedPin)) {
      out.writeln('result=invalid_pin_format');
      return out.toString();
    }

    final scope = await _resolveTenantScope();
    out.writeln('scope.organization_id=${scope?.organizationId ?? '(null)'}');
    out.writeln('scope.location_id=${scope?.locationId ?? '(null)'}');

    try {
      final directRows = await SupabaseService.client
          .from('staff')
          .select('id, organization_id, location_id, pin, is_active')
          .eq('pin', normalizedPin)
          .limit(20);

      out.writeln('direct_query.count=${directRows.length}');
      for (final raw in directRows.take(5)) {
        final row = Map<String, dynamic>.from(raw as Map);
        out.writeln(
          'direct_row: id=${row['id']} org=${row['organization_id']} '
          'loc=${row['location_id']} active=${row['is_active']}',
        );
      }
    } catch (error) {
      out.writeln('direct_query.error=$error');
    }

    final lookupKey = _licenseLookupKey();
    out.writeln(
      'license_lookup_key=${lookupKey.isEmpty ? '(empty)' : lookupKey}',
    );

    if (lookupKey.isNotEmpty) {
      try {
        final rpcRows = await SupabaseService.client.rpc(
          'resolve_staff_pin_from_license',
          params: {
            'p_license_key': lookupKey,
            'p_pin': normalizedPin,
            'p_location_id': scope?.locationId.isNotEmpty == true
                ? scope!.locationId
                : null,
          },
        );

        if (rpcRows is List) {
          out.writeln('rpc_query.count=${rpcRows.length}');
          for (final raw in rpcRows.take(5)) {
            final row = Map<String, dynamic>.from(raw as Map);
            out.writeln(
              'rpc_row: id=${row['id']} org=${row['organization_id']} '
              'loc=${row['location_id']} active=${row['is_active']}',
            );
          }
        } else {
          out.writeln('rpc_query.type=${rpcRows.runtimeType}');
        }
      } catch (error) {
        out.writeln('rpc_query.error=$error');
      }
    }

    return out.toString();
  }

  Future<_TenantScope?> _resolveTenantScope() async {
    if (_cachedScope != null) return _cachedScope;

    final activeLicenseContext = LicenseService().activeContext;
    if (activeLicenseContext != null &&
        activeLicenseContext.organizationId.isNotEmpty &&
        activeLicenseContext.locationId.isNotEmpty) {
      _cachedScope = _TenantScope(
        organizationId: activeLicenseContext.organizationId,
        locationId: activeLicenseContext.locationId,
        terminalId: activeLicenseContext.terminalId,
        organizationNumber: activeLicenseContext.organizationNumber,
        terminalNumber: activeLicenseContext.terminalNumber,
      );
      return _cachedScope;
    }

    final client = SupabaseService.client;

    try {
      final user = client.auth.currentUser;
      if (user != null) {
        final membershipRows = await client
            .from('user_memberships')
            .select('organization_id, location_id')
            .eq('user_id', user.id)
            .limit(50);

        for (final rawRow in membershipRows) {
          final row = Map<String, dynamic>.from(rawRow as Map);
          final orgId = row['organization_id']?.toString();
          final locId = row['location_id']?.toString();
          if (orgId != null &&
              orgId.isNotEmpty &&
              locId != null &&
              locId.isNotEmpty) {
            final terminalRows = await client
                .from('terminals')
                .select('terminal_number, organization_number')
                .eq('organization_id', orgId)
                .eq('location_id', locId)
                .limit(1);

            String? terminalNumber;
            String? organizationNumber;
            if (terminalRows.isNotEmpty) {
              final terminal = Map<String, dynamic>.from(
                terminalRows.first as Map,
              );
              terminalNumber = terminal['terminal_number']?.toString();
              organizationNumber = terminal['organization_number']?.toString();
            }

            _cachedScope = _TenantScope(
              organizationId: orgId,
              locationId: locId,
            );
            _cachedScope = _TenantScope(
              organizationId: orgId,
              locationId: locId,
              organizationNumber: organizationNumber,
              terminalNumber: terminalNumber,
            );
            return _cachedScope;
          }
        }

        if (membershipRows.isNotEmpty) {
          final firstMembership = Map<String, dynamic>.from(
            membershipRows.first as Map,
          );
          final orgId = firstMembership['organization_id']?.toString();
          if (orgId != null && orgId.isNotEmpty) {
            final locationRows = await client
                .from('locations')
                .select('id')
                .eq('organization_id', orgId)
                .limit(1);

            if (locationRows.isNotEmpty) {
              final locationId = Map<String, dynamic>.from(
                locationRows.first as Map,
              )['id']?.toString();
              if (locationId != null && locationId.isNotEmpty) {
                final terminalRows = await client
                    .from('terminals')
                    .select('terminal_number, organization_number')
                    .eq('organization_id', orgId)
                    .eq('location_id', locationId)
                    .limit(1);

                String? terminalNumber;
                String? organizationNumber;
                if (terminalRows.isNotEmpty) {
                  final terminal = Map<String, dynamic>.from(
                    terminalRows.first as Map,
                  );
                  terminalNumber = terminal['terminal_number']?.toString();
                  organizationNumber = terminal['organization_number']
                      ?.toString();
                }

                _cachedScope = _TenantScope(
                  organizationId: orgId,
                  locationId: locationId,
                  organizationNumber: organizationNumber,
                  terminalNumber: terminalNumber,
                );
                return _cachedScope;
              }
            }
          }
        }
      }
    } catch (_) {
      // Fall through to anonymous terminal fallback.
    }

    try {
      final terminalRows = await client
          .from('terminals')
          .select(
            'organization_id, location_id, terminal_number, organization_number',
          )
          .limit(1);

      if (terminalRows.isNotEmpty) {
        final row = Map<String, dynamic>.from(terminalRows.first as Map);
        final orgId = row['organization_id']?.toString();
        final locId = row['location_id']?.toString();
        final terminalNumber = row['terminal_number']?.toString();
        final organizationNumber = row['organization_number']?.toString();
        if (orgId != null &&
            orgId.isNotEmpty &&
            locId != null &&
            locId.isNotEmpty) {
          _cachedScope = _TenantScope(
            organizationId: orgId,
            locationId: locId,
            organizationNumber: organizationNumber,
            terminalNumber: terminalNumber,
          );
          return _cachedScope;
        }
      }
    } catch (_) {
      // No fallback scope available.
    }

    return null;
  }

  Future<bool> canResolveTenantScope() async {
    final scope = await _resolveTenantScope();
    return scope != null;
  }

  void clearTenantScopeCache() {
    _cachedScope = null;
  }

  Future<Map<String, String>> getStartupContext() async {
    var terminalName = 'TEST_TERMINAL';
    var staffName = 'TEST_STAFF';
    var locationName = '';
    var locationAddress1 = '';
    var locationAddress2 = '';
    var locationCity = '';
    var locationState = '';
    var locationZip = '';
    var locationPhone = '';
    var processorProvider = '';
    var processorEnvironment = '';
    var processorMode = '';
    var epnApiLoginId = '';
    var epnUserId = '';
    var epnPassword = '';
    var epnRestrictKey = '';
    var allowTipAdjustments = 'false';
    var printTipSuggestions = 'true';
    var tipSuggestion1Pct = '18';
    var tipSuggestion2Pct = '20';
    var tipSuggestion3Pct = '25';
    var tipSuggestionBase = 'subtotal';
    var receiptCardSignatureMessage = '';
    var receiptMiscMessage = '';
    var defaultReceiptPrinter = TerminalConfig.defaultReceiptPrinter;
    var saleReceiptPreviewEnabled = 'true';
    var saleReceiptCopyCount = '2';
    var voidReceiptPreviewEnabled = 'true';
    var voidReceiptCopyCount = '2';
    var returnReceiptPreviewEnabled = 'true';
    var returnReceiptCopyCount = '2';
    var receiptReplyToEmail = '';

    try {
      final txFlowParams = await TransactionFlowParameters.load();
      saleReceiptPreviewEnabled = txFlowParams
          .receiptPreviewFor('sale')
          .toString();
      saleReceiptCopyCount = txFlowParams
          .receiptCopyCountFor('sale')
          .toString();
      voidReceiptPreviewEnabled = txFlowParams
          .receiptPreviewFor('void')
          .toString();
      voidReceiptCopyCount = txFlowParams
          .receiptCopyCountFor('void')
          .toString();
      returnReceiptPreviewEnabled = txFlowParams
          .receiptPreviewFor('return')
          .toString();
      returnReceiptCopyCount = txFlowParams
          .receiptCopyCountFor('return')
          .toString();
      receiptReplyToEmail = txFlowParams.receiptReplyToEmail;
    } catch (_) {
      // Keep default receipt output settings if transaction parameters fail.
    }

    try {
      final activeLicenseContext = LicenseService().activeContext;
      final fallbackLocationName =
          (await LicenseService().getStoredLocationName())?.trim() ?? '';
      if (activeLicenseContext != null &&
          activeLicenseContext.terminalName.isNotEmpty) {
        terminalName = activeLicenseContext.terminalName;
        locationName = activeLicenseContext.locationName;
      }

      final scope = await _resolveTenantScope();
      if (scope == null) {
        return {
          'terminalName': terminalName,
          'staffName': staffName,
          'locationName': locationName,
          'locationAddress1': locationAddress1,
          'locationAddress2': locationAddress2,
          'locationCity': locationCity,
          'locationState': locationState,
          'locationZip': locationZip,
          'locationPhone': locationPhone,
          'processorProvider': processorProvider,
          'processorEnvironment': processorEnvironment,
          'processorMode': processorMode,
          'epnApiLoginId': epnApiLoginId,
          'epnUserId': epnUserId,
          'epnPassword': epnPassword,
          'epnRestrictKey': epnRestrictKey,
          'allowTipAdjustments': allowTipAdjustments,
          'allow_tip_adjustments': allowTipAdjustments,
          'printTipSuggestions': printTipSuggestions,
          'tipSuggestion1Pct': tipSuggestion1Pct,
          'tipSuggestion2Pct': tipSuggestion2Pct,
          'tipSuggestion3Pct': tipSuggestion3Pct,
          'tipSuggestionBase': tipSuggestionBase,
          'receiptCardSignatureMessage': receiptCardSignatureMessage,
          'receiptMiscMessage': receiptMiscMessage,
          'defaultReceiptPrinter': defaultReceiptPrinter,
          'saleReceiptPreviewEnabled': saleReceiptPreviewEnabled,
          'saleReceiptCopyCount': saleReceiptCopyCount,
          'voidReceiptPreviewEnabled': voidReceiptPreviewEnabled,
          'voidReceiptCopyCount': voidReceiptCopyCount,
          'returnReceiptPreviewEnabled': returnReceiptPreviewEnabled,
          'returnReceiptCopyCount': returnReceiptCopyCount,
          'receiptReplyToEmail': receiptReplyToEmail,
        };
      }

      try {
        Map<String, dynamic>? location;

        final locationRows = await SupabaseService.client
            .from('locations')
            .select('*')
            .eq('organization_id', scope.organizationId)
            .eq('id', scope.locationId)
            .limit(1);

        if (locationRows.isNotEmpty) {
          location = Map<String, dynamic>.from(locationRows.first as Map);
        }

        if (location == null) {
          final lookupName = locationName.isNotEmpty
              ? locationName
              : fallbackLocationName;
          if (lookupName.isNotEmpty) {
            final fallbackRows = await SupabaseService.client
                .from('locations')
                .select('*')
                .eq('organization_id', scope.organizationId)
                .or(
                  'name.ilike.${lookupName.replaceAll(',', r'\,')},location_name.ilike.${lookupName.replaceAll(',', r'\,')}',
                )
                .limit(1);

            if (fallbackRows.isNotEmpty) {
              location = Map<String, dynamic>.from(fallbackRows.first as Map);
            }
          }
        }

        if (location != null) {
          final resolvedLocation = location;

          String readFirstNonEmpty(List<String> keys) {
            for (final key in keys) {
              final value = resolvedLocation[key]?.toString().trim() ?? '';
              if (value.isNotEmpty) return value;
            }
            return '';
          }

          final resolvedLocationName = readFirstNonEmpty([
            'location_name',
            'name',
            'location',
          ]);
          if (resolvedLocationName.isNotEmpty) {
            locationName = resolvedLocationName;
          }
          locationAddress1 = readFirstNonEmpty([
            'address_1',
            'address1',
            'address',
            'street',
          ]);
          locationAddress2 = readFirstNonEmpty([
            'address_2',
            'address2',
            'suite',
            'unit',
          ]);
          locationCity = readFirstNonEmpty(['city', 'location_city']);
          locationState = readFirstNonEmpty(['state', 'province']);
          locationZip = readFirstNonEmpty(['zip', 'postal_code', 'postcode']);
          locationPhone = readFirstNonEmpty([
            'phone',
            'telephone',
            'phone_number',
          ]);
          processorProvider = _firstNonEmpty(resolvedLocation, [
            'processor_provider',
            'processor',
            'payment_processor',
          ]);
          processorEnvironment = _firstNonEmpty(resolvedLocation, [
            'processor_environment',
            'processing_environment',
            'gateway_environment',
          ]);
          processorMode = _firstNonEmpty(resolvedLocation, [
            'processor_mode',
            'processing_mode',
          ]);
          epnApiLoginId = _firstNonEmpty(resolvedLocation, [
            'epn_api_login_id',
            'epn_login_id',
          ]);
          epnUserId = _firstNonEmpty(resolvedLocation, [
            'epn_user_id',
            'epn_userid',
          ]);
          epnPassword = _firstNonEmpty(resolvedLocation, [
            'epn_password',
            'epn_pass',
          ]);
          epnRestrictKey = _firstNonEmpty(resolvedLocation, [
            'epn_restrict_key',
            'epn_restriction_key',
          ]);
          final rawAllowTipAdjustments =
              resolvedLocation['allow_tip_adjustments'] ??
              resolvedLocation['allowTipAdjustments'];
          if (rawAllowTipAdjustments != null) {
            final normalized = rawAllowTipAdjustments
                .toString()
                .trim()
                .toLowerCase();
            allowTipAdjustments =
                normalized == 'true' ||
                    normalized == '1' ||
                    normalized == 'yes' ||
                    normalized == 'y'
                ? 'true'
                : 'false';
          }
          final rawPrintTipSuggestions =
              resolvedLocation['print_tip_suggestions'] ??
              resolvedLocation['printTipSuggestions'];
          if (rawPrintTipSuggestions != null) {
            final normalized = rawPrintTipSuggestions
                .toString()
                .trim()
                .toLowerCase();
            printTipSuggestions =
                normalized == 'false' ||
                    normalized == '0' ||
                    normalized == 'no' ||
                    normalized == 'n'
                ? 'false'
                : 'true';
          }
          tipSuggestion1Pct = _firstNonEmpty(resolvedLocation, [
            'tip_suggestion_1_pct',
            'tipSuggestion1Pct',
          ]);
          if (tipSuggestion1Pct.isEmpty) tipSuggestion1Pct = '18';
          tipSuggestion2Pct = _firstNonEmpty(resolvedLocation, [
            'tip_suggestion_2_pct',
            'tipSuggestion2Pct',
          ]);
          if (tipSuggestion2Pct.isEmpty) tipSuggestion2Pct = '20';
          tipSuggestion3Pct = _firstNonEmpty(resolvedLocation, [
            'tip_suggestion_3_pct',
            'tipSuggestion3Pct',
          ]);
          if (tipSuggestion3Pct.isEmpty) tipSuggestion3Pct = '25';
          tipSuggestionBase = _firstNonEmpty(resolvedLocation, [
            'tip_suggestion_base',
            'tipSuggestionBase',
          ]);
          if (tipSuggestionBase.isEmpty) tipSuggestionBase = 'subtotal';
          receiptCardSignatureMessage = _firstNonEmpty(resolvedLocation, [
            'receipt_card_signature_message',
            'receiptCardSignatureMessage',
          ]);
          receiptMiscMessage = _firstNonEmpty(resolvedLocation, [
            'receipt_misc_message',
            'receiptMiscMessage',
          ]);

          debugPrint(
            'StartupContext location fields: '
            'name="$locationName", '
            'address1="$locationAddress1", '
            'address2="$locationAddress2", '
            'city="$locationCity", '
            'state="$locationState", '
            'zip="$locationZip", '
            'phone="$locationPhone"',
          );
        } else {
          debugPrint(
            'StartupContext location fields: no location row found for '
            'organization_id=${scope.organizationId}, location_id=${scope.locationId}',
          );
        }
      } catch (_) {
        // Older schemas may not have all processor fields yet.
      }

      if (locationAddress1.isEmpty && scope.locationId.trim().isNotEmpty) {
        try {
          final locationDetails = await _settingsDataService
              .getLocationDetailsById(scope.locationId);
          locationName =
              locationDetails['name']?.toString().trim().isNotEmpty == true
              ? locationDetails['name']!.toString().trim()
              : locationName;
          locationAddress1 =
              locationDetails['address_1']?.toString().trim().isNotEmpty == true
              ? locationDetails['address_1']!.toString().trim()
              : (locationDetails['address']?.toString().trim() ??
                    locationAddress1);
          locationAddress2 =
              locationDetails['address_2']?.toString().trim() ??
              locationAddress2;
          locationCity =
              locationDetails['city']?.toString().trim() ?? locationCity;
          locationState =
              locationDetails['state']?.toString().trim() ?? locationState;
          locationZip =
              locationDetails['zip']?.toString().trim() ?? locationZip;
          locationPhone =
              locationDetails['phone']?.toString().trim() ?? locationPhone;
        } catch (_) {
          // Keep existing values if settings-data fallback also fails.
        }
      }

      try {
        final activeLicenseContext = LicenseService().activeContext;
        final rpcLicenseKey =
            (activeLicenseContext?.licenseKey ?? '').trim().isNotEmpty
            ? activeLicenseContext!.licenseKey.trim()
            : (activeLicenseContext?.organizationNumber ?? '').trim();
        final rpcLocationName = locationName.isNotEmpty
            ? locationName
            : fallbackLocationName;

        if (rpcLicenseKey.isNotEmpty) {
          final rpcRows = await SupabaseService.client.rpc(
            'get_location_profile_for_license',
            params: {
              'p_license_key': rpcLicenseKey,
              'p_location_id': scope.locationId.trim().isNotEmpty
                  ? scope.locationId.trim()
                  : null,
              'p_location_name': rpcLocationName.isNotEmpty
                  ? rpcLocationName
                  : null,
            },
          );

          if (rpcRows is List && rpcRows.isNotEmpty) {
            final row = Map<String, dynamic>.from(rpcRows.first as Map);
            locationName =
                row['location_name']?.toString().trim().isNotEmpty == true
                ? row['location_name'].toString().trim()
                : locationName;
            locationAddress1 =
                row['address_1']?.toString().trim().isNotEmpty == true
                ? row['address_1'].toString().trim()
                : locationAddress1;
            locationAddress2 =
                row['address_2']?.toString().trim().isNotEmpty == true
                ? row['address_2'].toString().trim()
                : locationAddress2;
            locationCity = row['city']?.toString().trim().isNotEmpty == true
                ? row['city'].toString().trim()
                : locationCity;
            locationState = row['state']?.toString().trim().isNotEmpty == true
                ? row['state'].toString().trim()
                : locationState;
            locationZip = row['zip']?.toString().trim().isNotEmpty == true
                ? row['zip'].toString().trim()
                : locationZip;
            locationPhone = row['phone']?.toString().trim().isNotEmpty == true
                ? row['phone'].toString().trim()
                : locationPhone;

            final rpcAllowTip =
                row['allow_tip_adjustments']?.toString().trim().toLowerCase() ??
                '';
            if (rpcAllowTip.isNotEmpty) {
              allowTipAdjustments =
                  (rpcAllowTip == 'true' ||
                      rpcAllowTip == '1' ||
                      rpcAllowTip == 'yes' ||
                      rpcAllowTip == 'y')
                  ? 'true'
                  : 'false';
            }

            final rpcPrintTipSuggestions =
                row['print_tip_suggestions']?.toString().trim().toLowerCase() ??
                '';
            if (rpcPrintTipSuggestions.isNotEmpty) {
              printTipSuggestions =
                  (rpcPrintTipSuggestions == 'false' ||
                      rpcPrintTipSuggestions == '0' ||
                      rpcPrintTipSuggestions == 'no' ||
                      rpcPrintTipSuggestions == 'n')
                  ? 'false'
                  : 'true';
            }

            tipSuggestion1Pct =
                row['tip_suggestion_1_pct']?.toString().trim().isNotEmpty ==
                    true
                ? row['tip_suggestion_1_pct'].toString().trim()
                : tipSuggestion1Pct;
            tipSuggestion2Pct =
                row['tip_suggestion_2_pct']?.toString().trim().isNotEmpty ==
                    true
                ? row['tip_suggestion_2_pct'].toString().trim()
                : tipSuggestion2Pct;
            tipSuggestion3Pct =
                row['tip_suggestion_3_pct']?.toString().trim().isNotEmpty ==
                    true
                ? row['tip_suggestion_3_pct'].toString().trim()
                : tipSuggestion3Pct;
            tipSuggestionBase =
                row['tip_suggestion_base']?.toString().trim().isNotEmpty == true
                ? row['tip_suggestion_base'].toString().trim()
                : tipSuggestionBase;
            receiptCardSignatureMessage =
                row['receipt_card_signature_message']
                        ?.toString()
                        .trim()
                        .isNotEmpty ==
                    true
                ? row['receipt_card_signature_message'].toString().trim()
                : receiptCardSignatureMessage;
            receiptMiscMessage =
                row['receipt_misc_message']?.toString().trim().isNotEmpty ==
                    true
                ? row['receipt_misc_message'].toString().trim()
                : receiptMiscMessage;
          }
        }
      } catch (_) {
        // Keep existing values if RPC fallback is not installed yet.
      }

      String pickTerminalId(Map<String, dynamic> row) {
        return (row['id'] ?? row['terminal_id'] ?? row['terminalId'] ?? '')
            .toString()
            .trim();
      }

      String pickTerminalNumber(Map<String, dynamic> row) {
        return (row['terminal_number'] ?? row['terminalNumber'] ?? '')
            .toString()
            .trim();
      }

      String pickTerminalName(Map<String, dynamic> row) {
        return (row['terminal_name'] ?? row['name'] ?? row['code'] ?? '')
            .toString()
            .trim();
      }

      String pickReceiptPrinter(Map<String, dynamic> row) {
        return (row['receipt_printer_name'] ??
                row['receiptPrinterName'] ??
                row['default_receipt_printer'] ??
                row['defaultReceiptPrinter'] ??
                '')
            .toString()
            .trim();
      }

      final rpcLicenseKey =
          (activeLicenseContext?.licenseKey ?? '').trim().isNotEmpty
          ? activeLicenseContext!.licenseKey.trim()
          : (activeLicenseContext?.organizationNumber ?? '').trim();
      final rpcLocationName = locationName.isNotEmpty
          ? locationName
          : fallbackLocationName;

      if (rpcLicenseKey.isNotEmpty) {
        try {
          final rpcRows = await SupabaseService.client.rpc(
            'list_terminals_from_app',
            params: {
              'p_license_key': rpcLicenseKey,
              'p_location_name': rpcLocationName.isNotEmpty
                  ? rpcLocationName
                  : null,
            },
          );

          if (rpcRows is List && rpcRows.isNotEmpty) {
            final normalizedTerminalId = (scope.terminalId ?? '').trim();
            final normalizedTerminalNumber = (scope.terminalNumber ?? '')
                .trim();

            Map<String, dynamic>? matched;
            for (final raw in rpcRows) {
              final row = Map<String, dynamic>.from(raw as Map);
              final rowId = pickTerminalId(row);
              final rowNumber = pickTerminalNumber(row);
              if ((normalizedTerminalId.isNotEmpty &&
                      rowId == normalizedTerminalId) ||
                  (normalizedTerminalNumber.isNotEmpty &&
                      rowNumber == normalizedTerminalNumber)) {
                matched = row;
                break;
              }
            }

            matched ??= Map<String, dynamic>.from(rpcRows.first as Map);

            final rpcTerminalName = pickTerminalName(matched);
            if (rpcTerminalName.isNotEmpty) {
              terminalName = rpcTerminalName;
            }

            final rpcPrinter = pickReceiptPrinter(matched);
            if (rpcPrinter.isNotEmpty) {
              defaultReceiptPrinter = rpcPrinter;
            }
          }
        } catch (_) {
          // Fall back to direct table query below when RPC is unavailable.
        }
      }

      if (terminalName.isEmpty || defaultReceiptPrinter.isEmpty) {
        var terminalQuery = SupabaseService.client
            .from('terminals')
            .select('terminal_name, name, code, receipt_printer_name')
            .eq('organization_id', scope.organizationId)
            .eq('location_id', scope.locationId);

        if ((scope.terminalNumber ?? '').isNotEmpty) {
          terminalQuery = terminalQuery.eq(
            'terminal_number',
            scope.terminalNumber!,
          );
        }

        final terminalRows = await terminalQuery.limit(1);

        if (terminalRows.isNotEmpty) {
          final terminal = Map<String, dynamic>.from(terminalRows.first as Map);
          terminalName =
              terminal['terminal_name']?.toString() ??
              terminal['name']?.toString() ??
              terminal['code']?.toString() ??
              terminalName;
          final rawPrinter =
              terminal['receipt_printer_name']?.toString().trim() ?? '';
          if (rawPrinter.isNotEmpty) {
            defaultReceiptPrinter = rawPrinter;
          }
        }
      }

      final staffRows = await SupabaseService.client
          .from('staff')
          .select('first_name, last_name, full_name, name, email')
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId)
          .limit(1);

      if (staffRows.isNotEmpty) {
        final staff = Map<String, dynamic>.from(staffRows.first as Map);
        final firstName = staff['first_name']?.toString() ?? '';
        final lastName = staff['last_name']?.toString() ?? '';
        final combinedName = '$firstName $lastName'.trim();

        staffName = combinedName.isNotEmpty
            ? combinedName
            : staff['full_name']?.toString() ??
                  staff['name']?.toString() ??
                  staff['email']?.toString() ??
                  staffName;
      }
    } catch (_) {
      // Keep default test values.
    }

    debugPrint(
      'StartupContext resolved: location="$locationName", '
      'allow_tip_adjustments=$allowTipAdjustments, '
      'default_receipt_printer="$defaultReceiptPrinter", '
      'sale_receipt_preview_enabled=$saleReceiptPreviewEnabled, '
      'sale_receipt_copy_count=$saleReceiptCopyCount, '
      'receipt_reply_to_email="$receiptReplyToEmail"',
    );

    return {
      'terminalName': terminalName,
      'staffName': staffName,
      'locationName': locationName,
      'locationAddress1': locationAddress1,
      'locationAddress2': locationAddress2,
      'locationCity': locationCity,
      'locationState': locationState,
      'locationZip': locationZip,
      'locationPhone': locationPhone,
      'processorProvider': processorProvider,
      'processorEnvironment': processorEnvironment,
      'processorMode': processorMode,
      'epnApiLoginId': epnApiLoginId,
      'epnUserId': epnUserId,
      'epnPassword': epnPassword,
      'epnRestrictKey': epnRestrictKey,
      'allowTipAdjustments': allowTipAdjustments,
      'allow_tip_adjustments': allowTipAdjustments,
      'tipAdjustEnabled': allowTipAdjustments,
      'allowGratuityAdjustments': allowTipAdjustments,
      'printTipSuggestions': printTipSuggestions,
      'tipSuggestion1Pct': tipSuggestion1Pct,
      'tipSuggestion2Pct': tipSuggestion2Pct,
      'tipSuggestion3Pct': tipSuggestion3Pct,
      'tipSuggestionBase': tipSuggestionBase,
      'receiptCardSignatureMessage': receiptCardSignatureMessage,
      'receiptMiscMessage': receiptMiscMessage,
      'defaultReceiptPrinter': defaultReceiptPrinter,
      'saleReceiptPreviewEnabled': saleReceiptPreviewEnabled,
      'saleReceiptCopyCount': saleReceiptCopyCount,
      'voidReceiptPreviewEnabled': voidReceiptPreviewEnabled,
      'voidReceiptCopyCount': voidReceiptCopyCount,
      'returnReceiptPreviewEnabled': returnReceiptPreviewEnabled,
      'returnReceiptCopyCount': returnReceiptCopyCount,
      'receiptReplyToEmail': receiptReplyToEmail,
    };
  }

  Future<Map<String, String>?> getStartupContextForStaffPin(String pin) async {
    final normalizedPin = pin.trim();
    if (normalizedPin.isEmpty ||
        !RegExp(r'^\d{1,6}$').hasMatch(normalizedPin)) {
      debugPrint('PIN login rejected: invalid pin format "$normalizedPin"');
      return null;
    }

    final pinCandidates = _buildPinCandidates(normalizedPin);

    final scope = await _resolveTenantScope();
    debugPrint(
      'PIN login start: pin="$normalizedPin", '
      'scopeOrg="${scope?.organizationId ?? ''}", '
      'scopeLoc="${scope?.locationId ?? ''}"',
    );
    debugPrint('PIN login candidates: ${pinCandidates.join(', ')}');

    try {
      List<dynamic> staffRows = const [];
      for (final candidatePin in pinCandidates) {
        staffRows = await SupabaseService.client
            .from('staff')
            .select(
              'id, organization_id, location_id, first_name, last_name, full_name, email, role, pin, is_active',
            )
            .eq('pin', candidatePin)
            .eq('is_active', true)
            .limit(50);
        if (staffRows.isNotEmpty) {
          debugPrint(
            'PIN login: direct query matched ${staffRows.length} row(s) using candidate "$candidatePin".',
          );
          break;
        }
      }

      if (staffRows.isEmpty) {
        final lookupKey = _licenseLookupKey();
        if (lookupKey.isNotEmpty) {
          for (final candidatePin in pinCandidates) {
            try {
              final rpcRows = await SupabaseService.client.rpc(
                'resolve_staff_pin_from_license',
                params: {
                  'p_license_key': lookupKey,
                  'p_pin': candidatePin,
                  'p_location_id': scope?.locationId.isNotEmpty == true
                      ? scope!.locationId
                      : null,
                },
              );
              if (rpcRows is List && rpcRows.isNotEmpty) {
                staffRows = rpcRows;
                debugPrint(
                  'PIN login: direct staff query returned 0, RPC fallback matched '
                  '${staffRows.length} row(s) using candidate "$candidatePin".',
                );
                break;
              }
            } catch (_) {
              // RPC may not be installed yet.
            }
          }
        }
      }

      if (staffRows.isEmpty) {
        debugPrint('PIN login: no active staff found for entered PIN.');
        return null;
      }

      debugPrint(
        'PIN login: matched ${staffRows.length} active staff row(s) for entered PIN.',
      );

      Map<String, dynamic>? selectedStaff;
      if (scope != null) {
        for (final rawRow in staffRows) {
          final row = Map<String, dynamic>.from(rawRow as Map);
          final staffOrgId = row['organization_id']?.toString().trim() ?? '';
          final staffLocationId = row['location_id']?.toString().trim() ?? '';
          if (staffOrgId == scope.organizationId &&
              staffLocationId == scope.locationId) {
            selectedStaff = row;
            break;
          }
        }
      }

      selectedStaff ??= Map<String, dynamic>.from(staffRows.first as Map);
      final staff = selectedStaff;

      final staffOrgId = staff['organization_id']?.toString().trim() ?? '';
      final staffLocationId = staff['location_id']?.toString().trim() ?? '';
      if (staffOrgId.isEmpty || staffLocationId.isEmpty) {
        debugPrint(
          'PIN login rejected: matched staff row missing org/location. '
          'staffId="${staff['id']?.toString() ?? ''}", '
          'org="$staffOrgId", loc="$staffLocationId"',
        );
        return null;
      }

      debugPrint(
        'PIN login selected staff: '
        'staffId="${staff['id']?.toString() ?? ''}", '
        'org="$staffOrgId", '
        'loc="$staffLocationId", '
        'name="${_buildStaffDisplayName(staff)}"',
      );

      // PIN determines the acting staff member first, then we load startup
      // context for that staff member's assigned location.
      _cachedScope = _TenantScope(
        organizationId: staffOrgId,
        locationId: staffLocationId,
        organizationNumber: scope?.organizationNumber,
        terminalNumber: scope?.terminalNumber,
      );

      final startup = await getStartupContext();
      startup['staffName'] = _buildStaffDisplayName(staff);
      startup['staffId'] = staff['id']?.toString().trim() ?? '';
      startup['staffRole'] = staff['role']?.toString().trim() ?? '';
      debugPrint(
        'PIN login success: startup context resolved for '
        'staffId="${startup['staffId'] ?? ''}", '
        'staffName="${startup['staffName'] ?? ''}", '
        'locationName="${startup['locationName'] ?? ''}"',
      );
      return startup;
    } catch (error, stackTrace) {
      debugPrint('PIN login exception: $error');
      debugPrint('$stackTrace');
      return null;
    }
  }

  /// Creates a transaction_headers row and returns the new header UUID.
  /// Pass [subtotal], [tax], [total] from the screen totals.
  /// Returns null on failure (error is logged).
  Future<String?> createTransactionHeader({
    required double subtotal,
    required double tax,
    required double total,
    double feeAmount = 0,

    /// Staff-entered employee/server identifier (PIN or short ID).
    /// Written to the server_id text column for tip tracking & reporting.
    /// NOT the same as staff_id (uuid FK), which is reserved for future
    /// login-gated authenticated flows.
    String serverId = '',
    String staffName = '',
    String terminalName = '',
    int? batchNumber,
    String invoiceReference = '',
    Map<String, dynamic>? customerSnapshot,
  }) async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) {
        debugPrint(
          'createTransactionHeader: no tenant scope — header not saved',
        );
        return null;
      }

      final resolvedTerminalNumber = _deriveTerminalNumber(
        scope: scope,
        terminalName: terminalName,
      );
      final resolvedBatchNumber = await _resolveHeaderBatchNumber(
        scope: scope,
        terminalNumber: resolvedTerminalNumber,
        requestedBatchNumber: batchNumber,
      );

      final payload = <String, dynamic>{
        'organization_id': scope.organizationId,
        'location_id': scope.locationId,
        'batch_number': resolvedBatchNumber,
        'subtotal': subtotal,
        'tax': tax,
        'total': total,
        'fee_amount': feeAmount,
        'amount_paid': 0,
        'amount_due': total,
        'status': 'open',
        'staff_name': staffName,
        'terminal_name': terminalName,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };

      if (scope.terminalId != null && scope.terminalId!.isNotEmpty) {
        payload['terminal_id'] = scope.terminalId;
      }
      if (resolvedTerminalNumber.isNotEmpty) {
        payload['terminal_number'] = resolvedTerminalNumber;
      }

      // server_id: staff-entered employee/server identifier (PIN, short ID).
      // staff_id (uuid FK) is left null until a future login-gated flow can
      // resolve the PIN to a staff UUID.
      if (serverId.trim().isNotEmpty) {
        payload['server_id'] = serverId.trim();
      }
      if (invoiceReference.trim().isNotEmpty) {
        payload['invoice_reference'] = invoiceReference.trim();
      }
      if (customerSnapshot != null && customerSnapshot.isNotEmpty) {
        payload['customer_snapshot'] = customerSnapshot;
      }

      final response = await SupabaseService.client
          .from('transaction_headers')
          .insert(payload)
          .select('id')
          .single();

      final headerId = response['id']?.toString();
      debugPrint(
        'createTransactionHeader: headerId=$headerId batch=$resolvedBatchNumber terminalNumber=$resolvedTerminalNumber',
      );
      return headerId;
    } catch (error, stackTrace) {
      debugPrint('createTransactionHeader failed: $error');
      debugPrint('$stackTrace');
      return null;
    }
  }

  /// Appends a payment detail row to the ledger and returns the detail row UUID.
  /// The DB trigger recalculates header totals automatically after this insert.
  Future<String?> saveTransactionDetail({
    required String transactionHeaderId,
    required String paymentType, // 'c' | 'd' | 'g' | 'k' | 'e' | 'x'
    required String subtype, // 's' | 'r' | 'v' | 'a'
    required double amount,
    double feeAmount = 0,
    required String status, // 'approved' | 'declined' | 'pending' | 'voided'
    String referenceId = '',
    String gatewayProvider = '',
    String gatewayToken = '',
    String authCode = '',
    String cardLast4 = '',
    String cardType = '',
    double? cashTendered,
    double? cashChange,
    String? originalDetailId,
    Map<String, dynamic>? gatewayRaw,
  }) async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) {
        debugPrint('saveTransactionDetail: no tenant scope — detail not saved');
        return null;
      }

      final payload = <String, dynamic>{
        'transaction_header_id': transactionHeaderId,
        'organization_id': scope.organizationId,
        'location_id': scope.locationId,
        'payment_type': paymentType,
        'subtype': subtype,
        'amount': amount,
        'fee_amount': feeAmount,
        'status': status,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };

      // Card transactions participate in open/closed batch workflows.
      if (paymentType == 'd') {
        payload['batch_status'] = 'o';
      }

      if (referenceId.isNotEmpty) payload['reference_id'] = referenceId;
      if (gatewayProvider.isNotEmpty) {
        payload['gateway_provider'] = gatewayProvider;
      }
      if (gatewayToken.isNotEmpty) payload['gateway_token'] = gatewayToken;
      if (authCode.isNotEmpty) payload['auth_code'] = authCode;
      if (cardLast4.isNotEmpty) payload['card_last4'] = cardLast4;
      if (cardType.isNotEmpty) payload['card_type'] = cardType;
      if (cashTendered != null) payload['cash_tendered'] = cashTendered;
      if (cashChange != null) payload['cash_change'] = cashChange;
      if (originalDetailId != null && originalDetailId.isNotEmpty) {
        payload['original_detail_id'] = originalDetailId;
      }
      if (gatewayRaw != null && gatewayRaw.isNotEmpty) {
        payload['gateway_raw'] = gatewayRaw;
      }

      final response = await SupabaseService.client
          .from('transaction_details')
          .insert(payload)
          .select('id')
          .single();

      final detailId = response['id']?.toString();
      debugPrint(
        'saveTransactionDetail: detailId=$detailId type=$paymentType subtype=$subtype status=$status',
      );
      return detailId;
    } catch (error, stackTrace) {
      debugPrint('saveTransactionDetail failed: $error');
      debugPrint('$stackTrace');
      return null;
    }
  }

  /// Legacy shim — still writes to the old `transactions` table so existing
  /// reporting queries keep working. New code should call
  /// createTransactionHeader + saveTransactionDetail directly.
  Future<void> saveTransaction({
    required String paymentType,
    required double amount,
    required bool success,
    required String message,
    String? transactionHeaderId,
  }) async {
    try {
      final scope = await _resolveTenantScope();

      final payload = <String, dynamic>{
        'payment_type': paymentType,
        'amount': amount,
        'success': success,
        'message': message,
        'created_at': DateTime.now().toIso8601String(),
      };

      if (transactionHeaderId != null && transactionHeaderId.isNotEmpty) {
        payload['transaction_header_id'] = transactionHeaderId;
      }

      if (scope != null) {
        payload['organization_id'] = scope.organizationId;
        payload['location_id'] = scope.locationId;
        if (scope.organizationNumber != null &&
            scope.organizationNumber!.isNotEmpty) {
          payload['organization_number'] = scope.organizationNumber;
        }
        if (scope.terminalNumber != null && scope.terminalNumber!.isNotEmpty) {
          payload['terminal_number'] = scope.terminalNumber;
        }
      } else {
        if (SupabaseConfig.organizationNumber.isNotEmpty) {
          payload['organization_number'] = SupabaseConfig.organizationNumber;
        }
        if (SupabaseConfig.terminalNumber.isNotEmpty) {
          payload['terminal_number'] = SupabaseConfig.terminalNumber;
        }
      }

      await SupabaseService.client
          .from(SupabaseConfig.transactionsTable)
          .insert(payload);
    } catch (error, stackTrace) {
      debugPrint('Supabase transaction sync failed: $error');
      debugPrint('$stackTrace');
    }
  }

  Future<void> saveScreenReceipts({
    required List<Map<String, dynamic>> receiptRows,
    String? transactionHeaderId,
  }) async {
    if (receiptRows.isEmpty) return;

    try {
      final scope = await _resolveTenantScope();
      final now = DateTime.now().toIso8601String();

      final payloads = receiptRows.map((row) {
        final payload = Map<String, dynamic>.from(row);
        payload['created_at'] ??= now;

        if (scope != null) {
          payload['organization_id'] = scope.organizationId;
          payload['location_id'] = scope.locationId;
        }

        if (transactionHeaderId != null && transactionHeaderId.isNotEmpty) {
          payload['transaction_header_id'] = transactionHeaderId;
        }

        return payload;
      }).toList();

      await SupabaseService.client
          .from(SupabaseConfig.screenReceiptsTable)
          .insert(payloads);
    } catch (error, stackTrace) {
      debugPrint('Supabase screen_receipts sync failed: $error');
      debugPrint('$stackTrace');
    }
  }

  /// Reads terminal-level auto-close configuration.
  /// `time24h` is expected as HH:mm or HH:mm:ss in 24-hour format.
  Future<({bool enabled, String time24h})?>
  getTerminalAutoCloseBatchSettings() async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null ||
          scope.terminalId == null ||
          scope.terminalId!.isEmpty) {
        return null;
      }

      final rows = await SupabaseService.client
          .from('terminals')
          .select('auto_close_batch_enabled, auto_close_batch_time')
          .eq('id', scope.terminalId!)
          .limit(1);

      if (rows.isEmpty) return null;
      final row = Map<String, dynamic>.from(rows.first as Map);
      final enabled = row['auto_close_batch_enabled'] == true;
      final time24h = row['auto_close_batch_time']?.toString().trim() ?? '';
      return (enabled: enabled, time24h: time24h);
    } catch (e) {
      debugPrint('getTerminalAutoCloseBatchSettings failed: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getRecentTransactions({
    int limit = 5,
  }) async {
    final response = await SupabaseService.client
        .from(SupabaseConfig.transactionsTable)
        .select('payment_type, amount, success, message, created_at')
        .order('created_at', ascending: false)
        .limit(limit);

    return List<Map<String, dynamic>>.from(response);
  }

  Future<List<Map<String, dynamic>>> getTransactionsReport({
    required DateTime from,
    required DateTime to,
    String paymentType = 'all',
    int limit = 500,
  }) async {
    final scope = await _resolveTenantScope();

    var query = SupabaseService.client
        .from(SupabaseConfig.transactionsTable)
        .select(
          'id, payment_type, amount, success, message, created_at, transaction_header_id, organization_id, location_id',
        )
        .gte('created_at', from.toUtc().toIso8601String())
        .lte('created_at', to.toUtc().toIso8601String());

    if (scope != null) {
      query = query
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId);
    }

    final normalizedType = paymentType.trim().toLowerCase();
    if (normalizedType.isNotEmpty && normalizedType != 'all') {
      query = query.eq('payment_type', normalizedType);
    }

    final response = await query
        .order('created_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(response);
  }

  Future<List<Map<String, dynamic>>> getTransactionHeadersReport({
    required DateTime from,
    required DateTime to,
    String status = 'all',
    int limit = 500,
  }) async {
    final scope = await _resolveTenantScope();
    final normalizedStatus = status.trim().toLowerCase();
    final fromIso = from.toUtc().toIso8601String();
    final toIso = to.toUtc().toIso8601String();

    Future<List<Map<String, dynamic>>> runAttempt({
      required String selectColumns,
      required bool withScope,
      required bool withStatus,
    }) async {
      var query = SupabaseService.client
          .from('transaction_headers')
          .select(selectColumns)
          .gte('created_at', fromIso)
          .lte('created_at', toIso);

      if (withScope && scope != null) {
        query = query
            .eq('organization_id', scope.organizationId)
            .eq('location_id', scope.locationId);
      }

      if (withStatus &&
          normalizedStatus.isNotEmpty &&
          normalizedStatus != 'all') {
        query = query.eq('status', normalizedStatus);
      }

      final response = await query
          .order('created_at', ascending: false)
          .limit(limit);
      var rows = List<Map<String, dynamic>>.from(response);

      if (!withStatus &&
          normalizedStatus.isNotEmpty &&
          normalizedStatus != 'all') {
        rows = rows.where((row) {
          final value = row['status']?.toString().trim().toLowerCase() ?? '';
          return value == normalizedStatus;
        }).toList();
      }

      return rows;
    }

    final attempts = <({String selectColumns, bool withScope, bool withStatus})>[
      (
        selectColumns:
            'id, created_at, updated_at, subtotal, tax, total, fee_amount, amount_paid, amount_due, status, staff_name, terminal_name, invoice_reference, customer_snapshot, organization_id, location_id, batch_number, terminal_number, txn_seq, receipt_id',
        withScope: true,
        withStatus: true,
      ),
      (
        selectColumns:
            'id, created_at, updated_at, subtotal, tax, total, fee_amount, amount_paid, amount_due, status, staff_name, terminal_name, customer_snapshot, organization_id, location_id, batch_number, terminal_number, txn_seq, receipt_id',
        withScope: true,
        withStatus: true,
      ),
      (selectColumns: '*', withScope: true, withStatus: true),
      (selectColumns: '*', withScope: true, withStatus: false),
      (selectColumns: '*', withScope: false, withStatus: false),
    ];

    Object? lastError;
    for (final attempt in attempts) {
      try {
        return await runAttempt(
          selectColumns: attempt.selectColumns,
          withScope: attempt.withScope,
          withStatus: attempt.withStatus,
        );
      } catch (e) {
        lastError = e;
      }
    }

    throw Exception(
      'Unable to query transaction_headers. '
      'Check DB migrations/RLS for transaction ledger tables. '
      'Last error: $lastError',
    );
  }

  Future<List<Map<String, dynamic>>> getTransactionDetailsForHeader(
    String transactionHeaderId,
  ) async {
    final trimmed = transactionHeaderId.trim();
    if (trimmed.isEmpty) return const [];

    final response = await SupabaseService.client
        .from('transaction_details')
        .select(
          'id, transaction_header_id, payment_type, subtype, amount, fee_amount, status, reference_id, auth_code, card_last4, card_type, gateway_provider, original_detail_id, batch_status, receipt_id, created_at',
        )
        .eq('transaction_header_id', trimmed)
        .order('created_at', ascending: true);
    return List<Map<String, dynamic>>.from(response);
  }

  Future<String> getReceiptIdDisplayForHeader(
    String transactionHeaderId,
  ) async {
    final trimmed = transactionHeaderId.trim();
    if (trimmed.isEmpty) return '';

    try {
      final row = await SupabaseService.client
          .from('transaction_headers')
          .select('receipt_id,batch_number,terminal_number,txn_seq')
          .eq('id', trimmed)
          .maybeSingle();
      final map = row == null ? null : Map<String, dynamic>.from(row);
      if (map == null) return '';

      final raw = map['receipt_id']?.toString().trim() ?? '';
      if (raw.isNotEmpty) {
        return formatReceiptIdForDisplay(raw);
      }

      return formatReceiptIdFromParts(
        batchNumber: map['batch_number'],
        terminalNumber: map['terminal_number'],
        txnSeq: map['txn_seq'],
      );
    } catch (_) {
      return '';
    }
  }

  Future<Map<String, String>> getTransactionHeaderTenderKinds(
    List<String> transactionHeaderIds,
  ) async {
    final normalizedIds = transactionHeaderIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalizedIds.isEmpty) return const <String, String>{};

    List<Map<String, dynamic>> rows;
    try {
      final response = await SupabaseService.client
          .from('transaction_details')
          .select('transaction_header_id, payment_type')
          .inFilter('transaction_header_id', normalizedIds);
      rows = List<Map<String, dynamic>>.from(response);
    } catch (_) {
      return {for (final headerId in normalizedIds) headerId: 'unknown'};
    }
    final kindsByHeader = <String, Set<String>>{};

    String normalizeType(String value) {
      final raw = value.trim().toLowerCase();
      if (raw == 'c' || raw == 'cash') return 'cash';
      if (raw == 'd' || raw == 'card') return 'card';
      return 'unknown';
    }

    for (final row in rows) {
      final headerId = row['transaction_header_id']?.toString().trim() ?? '';
      if (headerId.isEmpty) continue;
      final normalizedType = normalizeType(
        row['payment_type']?.toString() ?? '',
      );
      final bucket = kindsByHeader.putIfAbsent(headerId, () => <String>{});
      bucket.add(normalizedType);
    }

    final result = <String, String>{};
    for (final headerId in normalizedIds) {
      final set = kindsByHeader[headerId] ?? const <String>{};
      if (set.isEmpty) {
        result[headerId] = 'unknown';
      } else if (set.length == 1) {
        result[headerId] = set.first;
      } else if (set.contains('cash') && set.contains('card')) {
        result[headerId] = 'mixed';
      } else {
        result[headerId] = 'unknown';
      }
    }

    return result;
  }

  Future<Map<String, Map<String, String>>> getTransactionHeaderCardAuthSummary(
    List<String> transactionHeaderIds,
  ) async {
    final normalizedIds = transactionHeaderIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalizedIds.isEmpty) return const <String, Map<String, String>>{};

    List<Map<String, dynamic>> rows;
    try {
      final response = await SupabaseService.client
          .from('transaction_details')
          .select(
            'transaction_header_id, payment_type, auth_code, card_last4, batch_status, created_at',
          )
          .inFilter('transaction_header_id', normalizedIds)
          .order('created_at', ascending: false);
      rows = List<Map<String, dynamic>>.from(response);
    } catch (_) {
      return {
        for (final headerId in normalizedIds)
          headerId: const <String, String>{'cardLast4': '', 'authCode': ''},
      };
    }

    String normalizeType(String value) {
      final raw = value.trim().toLowerCase();
      if (raw == 'c' || raw == 'cash') return 'cash';
      if (raw == 'd' || raw == 'card') return 'card';
      return 'unknown';
    }

    String normalizeLast4(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return '';
      final digitsOnly = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
      if (digitsOnly.length >= 4) {
        return digitsOnly.substring(digitsOnly.length - 4);
      }
      return trimmed;
    }

    final result = {
      for (final headerId in normalizedIds)
        headerId: <String, String>{
          'cardLast4': '',
          'authCode': '',
          'batchStatus': 'o',
        },
    };

    for (final row in rows) {
      final headerId = row['transaction_header_id']?.toString().trim() ?? '';
      if (headerId.isEmpty || !result.containsKey(headerId)) continue;

      final paymentType = normalizeType(row['payment_type']?.toString() ?? '');
      final authCode = (row['auth_code']?.toString() ?? '').trim();
      final cardLast4 = normalizeLast4(row['card_last4']?.toString() ?? '');
      final batchStatus = (row['batch_status']?.toString() ?? 'o').trim();

      final current = result[headerId]!;
      final hasCard = current['cardLast4']!.trim().isNotEmpty;
      final hasAuth = current['authCode']!.trim().isNotEmpty;

      // Prefer card rows for display values, but keep first non-empty fallback.
      final shouldPrefer = paymentType == 'card';
      if ((!hasCard && cardLast4.isNotEmpty) ||
          (shouldPrefer && cardLast4.isNotEmpty)) {
        current['cardLast4'] = cardLast4;
      }
      if ((!hasAuth && authCode.isNotEmpty) ||
          (shouldPrefer && authCode.isNotEmpty)) {
        current['authCode'] = authCode;
      }
      // Mark batch settled if any payment detail is settled.
      if (batchStatus == 'c') {
        current['batchStatus'] = 'c';
      }
    }

    return result;
  }

  /// Returns a map of location_id -> location_name for the given location IDs.
  /// Falls back to location_id string if name cannot be resolved.
  Future<Map<String, String>> getLocationNamesByIds(
    List<String> locationIds,
  ) async {
    final uniqueIds = locationIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (uniqueIds.isEmpty) return const {};

    // Seed result with ID as fallback in case lookup fails.
    final result = <String, String>{for (final id in uniqueIds) id: id};

    // Try the SECURITY DEFINER RPC first — works with the anon key
    // because terminal sessions are not authenticated via Supabase Auth
    // and the locations table RLS is scoped to authenticated users only.
    try {
      final uuidList = uniqueIds.map((id) => id).toList();
      final rpcRows = await SupabaseService.client.rpc(
        'get_location_names_by_ids',
        params: {'p_location_ids': uuidList},
      );
      for (final row in List<Map<String, dynamic>>.from(rpcRows as List)) {
        final id = row['id']?.toString().trim() ?? '';
        final name = row['name']?.toString().trim() ?? '';
        if (id.isNotEmpty && name.isNotEmpty && name != id) {
          result[id] = name;
        }
      }
      // If all IDs resolved, we're done.
      if (result.values.every((v) => !uniqueIds.contains(v) || v.length < 36)) {
        return result;
      }
    } catch (_) {
      // Fall through to direct query attempt.
    }

    // Fallback: direct table query (works when authenticated).
    try {
      final rows = await SupabaseService.client
          .from('locations')
          .select('id, name')
          .inFilter('id', uniqueIds);
      for (final row in List<Map<String, dynamic>>.from(rows)) {
        final id = row['id']?.toString().trim() ?? '';
        if (id.isEmpty) continue;
        final name = row['name']?.toString().trim() ?? '';
        if (name.isNotEmpty) result[id] = name;
      }
    } catch (_) {
      // Return whatever we have — non-fatal.
    }
    return result;
  }

  Future<int?> saveBatchCloseReport({
    required bool accepted,
    required String processorStatus,
    required String processorMessage,
    required String terminalName,
    required String locationName,
    required String organizationName,
    required String organizationNumber,
    required DateTime closedAt,
    required List<Map<String, dynamic>> batchRows,
    Map<String, dynamic>? reportOverride,
    String? processorCloseResponseRaw,
  }) async {
    final payload =
        reportOverride ??
        _buildBatchCloseReportPayload(
          accepted: accepted,
          processorStatus: processorStatus,
          processorMessage: processorMessage,
          terminalName: terminalName,
          locationName: locationName,
          organizationName: organizationName,
          organizationNumber: organizationNumber,
          closedAt: closedAt,
          batchRows: batchRows,
        );

    final closedBatchNumber = await _saveCardBatchReportToLedger(
      report: payload,
      processorCloseResponseRaw: processorCloseResponseRaw,
    );

    await saveTransaction(
      paymentType: 'card',
      amount: _asDouble(
        Map<String, dynamic>.from(
          payload['header'] as Map<String, dynamic>? ??
              const <String, dynamic>{},
        )['totalAmount'],
      ),
      success:
          Map<String, dynamic>.from(
            payload['header'] as Map<String, dynamic>? ??
                const <String, dynamic>{},
          )['accepted'] ==
          true,
      message: jsonEncode(payload),
    );

    return closedBatchNumber;
  }

  Map<String, dynamic> _buildBatchCloseReportPayload({
    required bool accepted,
    required String processorStatus,
    required String processorMessage,
    required String terminalName,
    required String locationName,
    required String organizationName,
    required String organizationNumber,
    required DateTime closedAt,
    required List<Map<String, dynamic>> batchRows,
  }) {
    final totals = _buildLedgerIntegrityTotals(batchRows);
    final approvedCount = _asInt(totals['approvedCount']);
    final voidedCount = _asInt(totals['voidedCount']);
    final saleAmount = _asDouble(totals['saleAmount']);
    final tipAdjustAmount = _asDouble(totals['tipAdjustAmount']);
    final refundCount = _asInt(totals['refundCount']);
    final voidCount = _asInt(totals['voidCount']);
    final salesWithTipAmount = _asDouble(totals['salesWithTipAmount']);
    final salesWithTipCount = _asInt(totals['salesWithTipCount']);
    final refundSignedAmount = _asDouble(totals['refundSignedAmount']);
    final voidSignedAmount = _asDouble(totals['voidSignedAmount']);
    final netAmount = _asDouble(totals['netAmount']);

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
        'terminalName': terminalName,
        'locationName': locationName,
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
        'totalAmount': netAmount,
      },
      'transactions': transactions,
    };
  }

  Map<String, dynamic> _buildLedgerIntegrityTotals(
    List<Map<String, dynamic>> rows,
  ) {
    String statusOf(Map<String, dynamic> row) {
      return (row['status']?.toString().toLowerCase() ?? '').trim();
    }

    String subtypeOf(Map<String, dynamic> row) {
      return (row['subtype']?.toString().toLowerCase() ?? '').trim();
    }

    double amountOf(Map<String, dynamic> row) {
      return ((row['amount'] is num) ? (row['amount'] as num).toDouble() : 0.0)
          .abs();
    }

    double surchargeOf(Map<String, dynamic> row) {
      final explicit = _asDouble(row['surcharge_amount']).abs();
      if (explicit > 0) return explicit;
      return _asDouble(row['fee_amount']).abs();
    }

    double embeddedTipAdjustOf(Map<String, dynamic> row) {
      return _asDouble(row['tip_adjustment_total']).abs();
    }

    String operationOf(Map<String, dynamic> row) {
      final raw = row['gateway_raw'];
      if (raw is Map) {
        final rawMap = Map<String, dynamic>.from(raw);
        return (rawMap['operation']?.toString().toLowerCase() ?? '').trim();
      }
      if (raw is String && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            final rawMap = Map<String, dynamic>.from(decoded);
            return (rawMap['operation']?.toString().toLowerCase() ?? '').trim();
          }
        } catch (_) {}
      }
      return '';
    }

    final approvedSaleIds = rows
        .where((row) => statusOf(row) == 'approved' && subtypeOf(row) == 's')
        .map((row) => row['id']?.toString().trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    var approvedCount = 0;
    var voidedCount = 0;
    var saleCount = 0;
    var refundCount = 0;
    var voidCount = 0;
    var tipAdjustCount = 0;
    var saleAmount = 0.0;
    var surchargeAmount = 0.0;
    var refundAmount = 0.0;
    var voidAmount = 0.0;
    var tipAdjustAmount = 0.0;

    for (final row in rows) {
      final status = statusOf(row);
      final subtype = subtypeOf(row);
      final amount = amountOf(row);

      if (status == 'approved') {
        approvedCount += 1;
      } else if (status == 'voided') {
        voidedCount += 1;
      }

      if (status != 'approved' && status != 'voided') {
        continue;
      }

      if (subtype == 's') {
        saleCount += 1;
        saleAmount += amount;
        surchargeAmount += surchargeOf(row);
        tipAdjustAmount += embeddedTipAdjustOf(row);
        continue;
      }

      if (subtype == 'a' && operationOf(row) == 'tip_adjust') {
        final originalId = row['original_detail_id']?.toString().trim() ?? '';
        if (originalId.isEmpty || !approvedSaleIds.contains(originalId)) {
          continue;
        }
        tipAdjustCount += 1;
        tipAdjustAmount += amount;
        continue;
      }

      if (subtype == 'r') {
        refundCount += 1;
        refundAmount += amount;
        continue;
      }

      if (subtype == 'v') {
        voidCount += 1;
        voidAmount += amount;
      }
    }

    final salesWithTipAmount =
        saleAmount + surchargeAmount + tipAdjustAmount + voidAmount;
    final salesWithTipCount = saleCount + tipAdjustCount + voidCount;
    final refundSignedAmount = -refundAmount;
    final voidSignedAmount = -voidAmount;
    final netAmount =
        salesWithTipAmount + refundSignedAmount + voidSignedAmount;

    return {
      'approvedCount': approvedCount,
      'voidedCount': voidedCount,
      'saleCount': saleCount,
      'refundCount': refundCount,
      'voidCount': voidCount,
      'tipAdjustCount': tipAdjustCount,
      'salesWithTipCount': salesWithTipCount,
      'saleAmount': double.parse(saleAmount.toStringAsFixed(2)),
      'surchargeAmount': double.parse(surchargeAmount.toStringAsFixed(2)),
      'refundAmount': double.parse(refundAmount.toStringAsFixed(2)),
      'voidAmount': double.parse(voidAmount.toStringAsFixed(2)),
      'tipAdjustAmount': double.parse(tipAdjustAmount.toStringAsFixed(2)),
      'salesWithTipAmount': double.parse(salesWithTipAmount.toStringAsFixed(2)),
      'refundSignedAmount': double.parse(refundSignedAmount.toStringAsFixed(2)),
      'voidSignedAmount': double.parse(voidSignedAmount.toStringAsFixed(2)),
      'netAmount': double.parse(netAmount.toStringAsFixed(2)),
    };
  }

  Map<String, dynamic> buildOpenBatchIntegritySnapshot(
    List<Map<String, dynamic>> rows,
  ) {
    String statusOf(Map<String, dynamic> row) {
      return (row['status']?.toString().toLowerCase() ?? '').trim();
    }

    String subtypeOf(Map<String, dynamic> row) {
      return (row['subtype']?.toString().toLowerCase() ?? '').trim();
    }

    double amountOf(Map<String, dynamic> row) {
      return ((row['amount'] is num) ? (row['amount'] as num).toDouble() : 0.0)
          .abs();
    }

    String operationOf(Map<String, dynamic> row) {
      final raw = row['gateway_raw'];
      if (raw is Map) {
        final rawMap = Map<String, dynamic>.from(raw);
        return (rawMap['operation']?.toString().toLowerCase() ?? '').trim();
      }
      if (raw is String && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            final rawMap = Map<String, dynamic>.from(decoded);
            return (rawMap['operation']?.toString().toLowerCase() ?? '').trim();
          }
        } catch (_) {}
      }
      return '';
    }

    bool isTipAdjustmentRow(Map<String, dynamic> row) {
      if (subtypeOf(row) != 'a') return false;
      final originalId = row['original_detail_id']?.toString().trim() ?? '';
      if (originalId.isEmpty) return false;
      final op = operationOf(row);
      return op.isEmpty || op == 'tip_adjust' || op == 'tip_adjust_probe';
    }

    final approvedSaleIds = rows
        .where((row) => statusOf(row) == 'approved' && subtypeOf(row) == 's')
        .map((row) => row['id']?.toString().trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    final tipAdjustByOriginalId = <String, double>{};
    final tipAdjustAtByOriginalId = <String, DateTime>{};
    for (final row in rows) {
      if (statusOf(row) != 'approved' || !isTipAdjustmentRow(row)) {
        continue;
      }
      final originalId = row['original_detail_id']?.toString().trim() ?? '';
      if (originalId.isEmpty || !approvedSaleIds.contains(originalId)) {
        continue;
      }
      final amount = amountOf(row);
      final createdAt = DateTime.tryParse(row['created_at']?.toString() ?? '');
      final existingAt = tipAdjustAtByOriginalId[originalId];
      if (existingAt == null ||
          (createdAt != null && createdAt.isAfter(existingAt))) {
        tipAdjustByOriginalId[originalId] = amount;
        if (createdAt != null) {
          tipAdjustAtByOriginalId[originalId] = createdAt;
        }
      }
    }

    final reportRows = <Map<String, dynamic>>[];
    for (final row in rows) {
      final subtype = subtypeOf(row);
      if (isTipAdjustmentRow(row)) {
        continue;
      }
      if (subtype == 'v') {
        continue;
      }

      final mutable = Map<String, dynamic>.from(row);
      final id = mutable['id']?.toString().trim() ?? '';
      if (subtype == 's') {
        final tipAdd = tipAdjustByOriginalId[id] ?? 0.0;
        final baseAmount = amountOf(mutable);
        final surchargeAmount = _asDouble(mutable['fee_amount']).abs();
        mutable['display_amount'] = baseAmount + surchargeAmount + tipAdd;
        mutable['surcharge_amount'] = surchargeAmount;
        mutable['tip_adjustment_total'] = tipAdd;
      }
      reportRows.add(mutable);
    }

    final totals = _buildLedgerIntegrityTotals(rows);
    return {
      'rows': reportRows,
      'totals': totals,
      'tipAdjustByOriginalId': tipAdjustByOriginalId,
    };
  }

  Future<void> saveBatchCloseReportSnapshot({
    required Map<String, dynamic> report,
  }) async {
    final header = Map<String, dynamic>.from(
      report['header'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    );

    await saveTransaction(
      paymentType: 'card',
      amount: _asDouble(header['totalAmount']),
      success: header['accepted'] == true,
      message: jsonEncode(report),
    );
  }

  Future<List<Map<String, dynamic>>> getBatchCloseReports({
    required DateTime beginDate,
    required DateTime endDate,
    int limit = 500,
  }) async {
    final cardBatchRows = await _getBatchCloseReportsFromCardBatchTables(
      beginDate: beginDate,
      endDate: endDate,
      limit: limit,
    );
    if (cardBatchRows.isNotEmpty) {
      return cardBatchRows;
    }

    final start = DateTime(
      beginDate.year,
      beginDate.month,
      beginDate.day,
    ).toUtc();
    final endExclusive = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
    ).add(const Duration(days: 1)).toUtc();

    try {
      final response = await SupabaseService.client
          .from(SupabaseConfig.transactionsTable)
          .select(
            'id, payment_type, amount, success, message, created_at, organization_number, terminal_number',
          )
          .ilike('message', '%"reportType":"batch_close"%')
          .gte('created_at', start.toIso8601String())
          .lt('created_at', endExclusive.toIso8601String())
          .order('created_at', ascending: false)
          .limit(limit);

      return List<Map<String, dynamic>>.from(response).map((row) {
        final parsed = _parseBatchClosePayload(
          row['message']?.toString() ?? '',
        );
        if (parsed != null) {
          return {...row, 'report': parsed};
        }

        return {
          ...row,
          'report': {
            'version': 1,
            'reportType': 'batch_close',
            'header': {
              'accepted': row['success'] == true,
              'processorStatus': row['success'] == true
                  ? 'Accepted'
                  : 'Not Accepted',
              'processorMessage': row['message']?.toString() ?? '',
              'terminalName': row['terminal_number']?.toString() ?? '',
              'locationName': '',
              'organizationName': '',
              'organizationNumber':
                  row['organization_number']?.toString() ?? '',
              'closedAt': row['created_at']?.toString() ?? '',
              'approvedCount': 0,
              'voidedCount': 0,
              'transactionCount': 0,
              'totalAmount': _asDouble(row['amount']),
            },
            'transactions': const <Map<String, dynamic>>[],
          },
        };
      }).toList();
    } catch (e) {
      debugPrint('getBatchCloseReports failed: $e');
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> getBatchCloseReportsProcessorFirst({
    required DateTime beginDate,
    required DateTime endDate,
    required String tpn,
    required String authKey,
    required bool sandbox,
    required String terminalName,
    required String locationName,
    required String organizationName,
    required String organizationNumber,
    int limit = 500,
  }) async {
    final localReports = await getBatchCloseReports(
      beginDate: beginDate,
      endDate: endDate,
      limit: limit,
    );
    return localReports;
  }

  Future<Map<String, dynamic>> buildPreCloseBatchAudit({
    required List<Map<String, dynamic>> localRows,
    required String tpn,
    required String authKey,
    required bool sandbox,
  }) async {
    Map<String, dynamic> buildLocalTotals() {
      final totals = _buildLedgerIntegrityTotals(localRows);
      return {'transactionCount': localRows.length, ...totals};
    }

    final localTotals = buildLocalTotals();
    if (tpn.trim().isEmpty || authKey.trim().isEmpty) {
      return {
        'status': 'unavailable',
        'summary': 'Processor credentials are missing for this terminal.',
        'local': localTotals,
        'processor': null,
        'mismatches': const <String>[],
        'warnings': const <String>[],
        'referenceDiff': {
          'enabled': false,
          'missingInLocal': const <String>[],
          'missingInProcessor': const <String>[],
        },
      };
    }

    try {
      final response = await http.post(
        Uri.parse('$_backendBase/api/spin/report/daily'),
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'sandbox': sandbox, 'tpn': tpn, 'authKey': authKey}),
      );

      if (response.statusCode != 200) {
        return {
          'status': 'unavailable',
          'summary':
              'Processor report unavailable (HTTP ${response.statusCode}).',
          'local': localTotals,
          'processor': null,
          'mismatches': const <String>[],
          'warnings': const <String>[],
          'referenceDiff': {
            'enabled': false,
            'missingInLocal': const <String>[],
            'missingInProcessor': const <String>[],
          },
        };
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return {
          'status': 'failed',
          'summary': 'Processor report payload was not valid JSON.',
          'local': localTotals,
          'processor': null,
          'mismatches': const <String>[],
          'warnings': const <String>[],
          'referenceDiff': {
            'enabled': false,
            'missingInLocal': const <String>[],
            'missingInProcessor': const <String>[],
          },
        };
      }

      final general = Map<String, dynamic>.from(
        decoded['GeneralResponse'] as Map<String, dynamic>? ??
            const <String, dynamic>{},
      );
      final resultCode = general['ResultCode']?.toString() ?? '';
      if (resultCode.isNotEmpty && resultCode != '0') {
        final message =
            general['DetailedMessage']?.toString().trim().isNotEmpty == true
            ? general['DetailedMessage'].toString()
            : (general['Message']?.toString() ??
                  'Processor report unavailable.');
        return {
          'status': 'unavailable',
          'summary': message,
          'local': localTotals,
          'processor': null,
          'mismatches': const <String>[],
          'warnings': const <String>[],
          'referenceDiff': {
            'enabled': false,
            'missingInLocal': const <String>[],
            'missingInProcessor': const <String>[],
          },
        };
      }

      final processorTransactions = <Map<String, dynamic>>[];
      final dailyDetails = (decoded['DailyDetails'] as List? ?? const [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      for (final daily in dailyDetails) {
        final rows =
            (daily['TransactionsDailyReports'] as List? ?? const <dynamic>[])
                .whereType<Map>()
                .map((row) => Map<String, dynamic>.from(row));
        processorTransactions.addAll(rows);
      }

      var pSaleCount = 0;
      var pRefundCount = 0;
      var pVoidCount = 0;
      var pTipAdjustCount = 0;
      var pSaleAmount = 0.0;
      var pRefundAmount = 0.0;
      var pVoidAmount = 0.0;
      var pTipAdjustAmount = 0.0;

      final processorReferences = <String>{};
      for (final row in processorTransactions) {
        final amount = _extractProcessorAmount(row).abs();
        final typeText =
            (row['TransactionType']?.toString().toLowerCase() ??
                    row['Type']?.toString().toLowerCase() ??
                    '')
                .trim();
        final ref = _extractProcessorReferenceId(row);
        if (ref.isNotEmpty) {
          processorReferences.add(ref);
        }

        if (typeText.contains('void')) {
          pVoidCount += 1;
          pVoidAmount += amount;
          continue;
        }
        if (typeText.contains('refund') || typeText.contains('return')) {
          pRefundCount += 1;
          pRefundAmount += amount;
          continue;
        }
        if (typeText.contains('tip')) {
          pTipAdjustCount += 1;
          pTipAdjustAmount += amount;
          continue;
        }

        pSaleCount += 1;
        pSaleAmount += amount;
      }

      final pSalesWithTipAmount = pSaleAmount + pTipAdjustAmount;
      final pSalesWithTipCount = pSaleCount + pTipAdjustCount;
      final pRefundSignedAmount = -pRefundAmount;
      final pVoidSignedAmount = -pVoidAmount;
      final pNetAmount =
          pSalesWithTipAmount + pRefundSignedAmount + pVoidSignedAmount;

      final processorTotals = {
        'transactionCount': processorTransactions.length,
        'saleCount': pSaleCount,
        'refundCount': pRefundCount,
        'voidCount': pVoidCount,
        'tipAdjustCount': pTipAdjustCount,
        'salesWithTipCount': pSalesWithTipCount,
        'saleAmount': double.parse(pSaleAmount.toStringAsFixed(2)),
        'surchargeAmount': 0.0,
        'refundAmount': double.parse(pRefundAmount.toStringAsFixed(2)),
        'voidAmount': double.parse(pVoidAmount.toStringAsFixed(2)),
        'tipAdjustAmount': double.parse(pTipAdjustAmount.toStringAsFixed(2)),
        'salesWithTipAmount': double.parse(
          pSalesWithTipAmount.toStringAsFixed(2),
        ),
        'refundSignedAmount': double.parse(
          pRefundSignedAmount.toStringAsFixed(2),
        ),
        'voidSignedAmount': double.parse(pVoidSignedAmount.toStringAsFixed(2)),
        'netAmount': double.parse(pNetAmount.toStringAsFixed(2)),
      };

      final blockingMismatches = <String>[];
      final nonBlockingWarnings = <String>[];
      bool amountDiff(String key, {double tolerance = 0.01}) {
        return (_asDouble(localTotals[key]) - _asDouble(processorTotals[key]))
                .abs() >
            tolerance;
      }

      bool countDiff(String key) {
        return _asInt(localTotals[key]) != _asInt(processorTotals[key]);
      }

      if (amountDiff('salesWithTipAmount')) {
        blockingMismatches.add(
          'Sales + Surcharge + Tip Adjustments amount difference: local=\$${_asDouble(localTotals['salesWithTipAmount']).toStringAsFixed(2)} processor=\$${_asDouble(processorTotals['salesWithTipAmount']).toStringAsFixed(2)}',
        );
      }
      if (amountDiff('refundSignedAmount')) {
        blockingMismatches.add(
          'Refund amount difference: local=${_asDouble(localTotals['refundSignedAmount']).toStringAsFixed(2)} processor=${_asDouble(processorTotals['refundSignedAmount']).toStringAsFixed(2)}',
        );
      }
      if (amountDiff('voidSignedAmount')) {
        blockingMismatches.add(
          'Void amount difference: local=${_asDouble(localTotals['voidSignedAmount']).toStringAsFixed(2)} processor=${_asDouble(processorTotals['voidSignedAmount']).toStringAsFixed(2)}',
        );
      }
      if (amountDiff('netAmount')) {
        blockingMismatches.add(
          'Net amount difference: local=\$${_asDouble(localTotals['netAmount']).toStringAsFixed(2)} processor=\$${_asDouble(processorTotals['netAmount']).toStringAsFixed(2)}',
        );
      }
      if (countDiff('salesWithTipCount')) {
        nonBlockingWarnings.add(
          'Sales + Surcharge + Tip Adjustments count difference: local=${_asInt(localTotals['salesWithTipCount'])} processor=${_asInt(processorTotals['salesWithTipCount'])}',
        );
      }
      if (countDiff('refundCount')) {
        nonBlockingWarnings.add(
          'Refund count difference: local=${_asInt(localTotals['refundCount'])} processor=${_asInt(processorTotals['refundCount'])}',
        );
      }
      if (countDiff('voidCount')) {
        nonBlockingWarnings.add(
          'Void count difference: local=${_asInt(localTotals['voidCount'])} processor=${_asInt(processorTotals['voidCount'])}',
        );
      }

      final localReferences = localRows
          .map((row) => (row['reference_id']?.toString() ?? '').trim())
          .where((ref) => ref.isNotEmpty)
          .toSet();
      final referenceDiffEnabled =
          localReferences.isNotEmpty && processorReferences.isNotEmpty;
      final missingInLocal = referenceDiffEnabled
          ? processorReferences
                .where((ref) => !localReferences.contains(ref))
                .take(20)
                .toList()
          : <String>[];
      final missingInProcessor = referenceDiffEnabled
          ? localReferences
                .where((ref) => !processorReferences.contains(ref))
                .take(20)
                .toList()
          : <String>[];

      final hasReferenceDiff =
          missingInLocal.isNotEmpty || missingInProcessor.isNotEmpty;

      final balanced = blockingMismatches.isEmpty;
      return {
        'status': balanced ? 'balanced' : 'blocked',
        'summary': balanced
            ? (hasReferenceDiff
                  ? 'Local and processor batch totals are aligned. Reference differences detected (informational).'
                  : 'Local and processor batch totals are aligned.')
            : 'Close batch blocked: critical totals do not align.',
        'local': localTotals,
        'processor': processorTotals,
        'mismatches': blockingMismatches,
        'warnings': nonBlockingWarnings,
        'referenceDiff': {
          'enabled': referenceDiffEnabled,
          'missingInLocal': missingInLocal,
          'missingInProcessor': missingInProcessor,
        },
      };
    } catch (error) {
      return {
        'status': 'failed',
        'summary': 'Pre-close audit failed: $error',
        'local': localTotals,
        'processor': null,
        'mismatches': const <String>[],
        'warnings': const <String>[],
        'referenceDiff': {
          'enabled': false,
          'missingInLocal': const <String>[],
          'missingInProcessor': const <String>[],
        },
      };
    }
  }

  Future<Map<String, dynamic>> verifyBatchReportIntegrity({
    required Map<String, dynamic> report,
    required String tpn,
    required String authKey,
    required bool sandbox,
  }) async {
    final header = Map<String, dynamic>.from(
      report['header'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    );
    final localTransactions = (report['transactions'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();

    if (tpn.trim().isEmpty || authKey.trim().isEmpty) {
      return _buildIntegrityResult(
        report: report,
        status: 'unavailable',
        summary: 'Processor credentials are not configured for this terminal.',
        items: const [],
      );
    }

    final closedAt = DateTime.tryParse(header['closedAt']?.toString() ?? '');
    if (closedAt == null) {
      return _buildIntegrityResult(
        report: report,
        status: 'unavailable',
        summary:
            'Batch close time is missing, so processor integrity cannot be checked.',
        items: const [],
      );
    }

    final now = DateTime.now();
    final localClosedAt = closedAt.toLocal();
    final isToday =
        localClosedAt.year == now.year &&
        localClosedAt.month == now.month &&
        localClosedAt.day == now.day;
    if (!isToday) {
      return _buildIntegrityResult(
        report: report,
        status: 'unavailable',
        summary:
            'Processor integrity is only available for today\'s batch because SPIn does not expose historical date-range reports.',
        items: const [],
      );
    }

    try {
      final response = await http.post(
        Uri.parse('$_backendBase/api/spin/report/daily'),
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'sandbox': sandbox, 'tpn': tpn, 'authKey': authKey}),
      );

      if (response.statusCode != 200) {
        String message =
            'Processor integrity check failed with HTTP ${response.statusCode}.';
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) {
            final general = Map<String, dynamic>.from(
              decoded['GeneralResponse'] as Map<String, dynamic>? ??
                  const <String, dynamic>{},
            );
            final detailed =
                general['DetailedMessage']?.toString().trim() ?? '';
            final basic = general['Message']?.toString().trim() ?? '';
            final fallback = decoded['error']?.toString().trim() ?? '';
            message = detailed.isNotEmpty
                ? detailed
                : (basic.isNotEmpty
                      ? basic
                      : (fallback.isNotEmpty ? fallback : message));
          }
        } catch (_) {}

        if (_isTransientOrPostCloseIntegrityMessage(message)) {
          return _buildIntegrityResult(
            report: report,
            status: 'unavailable',
            summary: 'Processor integrity currently unavailable: $message',
            items: const [],
          );
        }

        return _buildIntegrityResult(
          report: report,
          status: 'failed',
          summary: message,
          items: const [],
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return _buildIntegrityResult(
          report: report,
          status: 'failed',
          summary: 'Processor daily report returned an unexpected payload.',
          items: const [],
        );
      }

      final general = Map<String, dynamic>.from(
        decoded['GeneralResponse'] as Map<String, dynamic>? ??
            const <String, dynamic>{},
      );
      final resultCode = general['ResultCode']?.toString() ?? '';
      if (resultCode.isNotEmpty && resultCode != '0') {
        final message =
            general['DetailedMessage']?.toString().trim().isNotEmpty == true
            ? general['DetailedMessage'].toString()
            : (general['Message']?.toString() ??
                  'Processor daily report rejected the integrity request.');

        if (_isTransientOrPostCloseIntegrityMessage(message)) {
          return _buildIntegrityResult(
            report: report,
            status: 'unavailable',
            summary: 'Processor integrity currently unavailable: $message',
            items: const [],
          );
        }

        return _buildIntegrityResult(
          report: report,
          status: 'failed',
          summary: message,
          items: const [],
        );
      }

      final processorTransactions = <Map<String, dynamic>>[];
      final dailyDetails = (decoded['DailyDetails'] as List? ?? const [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      for (final daily in dailyDetails) {
        final rows =
            (daily['TransactionsDailyReports'] as List? ?? const <dynamic>[])
                .whereType<Map>()
                .map((row) => Map<String, dynamic>.from(row));
        processorTransactions.addAll(rows);
      }

      final usedProcessorIndexes = <int>{};
      final integrityItems = <Map<String, dynamic>>[];
      var verifiedCount = 0;
      var mismatchCount = 0;
      var missingCount = 0;

      for (final localRow in localTransactions) {
        final matchedIndex = _findMatchingProcessorTransactionIndex(
          localRow: localRow,
          processorTransactions: processorTransactions,
          usedIndexes: usedProcessorIndexes,
        );

        if (matchedIndex < 0) {
          missingCount += 1;
          integrityItems.add({
            'id': localRow['id']?.toString() ?? '',
            'status': 'missing',
            'summary':
                'No matching processor transaction found in today\'s daily report.',
          });
          continue;
        }

        usedProcessorIndexes.add(matchedIndex);
        final processorRow = processorTransactions[matchedIndex];
        final localAmount = _asDouble(localRow['amount']).abs();
        final processorAmount = _extractProcessorAmount(processorRow).abs();
        final localLast4 = (localRow['cardLast4']?.toString() ?? '').trim();
        final processorLast4 = _extractProcessorLast4(processorRow);
        final localRef = (localRow['referenceId']?.toString() ?? '').trim();
        final processorRef = _extractProcessorReferenceId(processorRow);

        final issues = <String>[];
        if ((localAmount - processorAmount).abs() > 0.01) {
          issues.add(
            'Amount mismatch local=\$${localAmount.toStringAsFixed(2)} processor=\$${processorAmount.toStringAsFixed(2)}',
          );
        }
        if (localLast4.isNotEmpty &&
            processorLast4.isNotEmpty &&
            localLast4 != processorLast4) {
          issues.add(
            'Last4 mismatch local=$localLast4 processor=$processorLast4',
          );
        }
        if (localRef.isNotEmpty &&
            processorRef.isNotEmpty &&
            localRef != processorRef) {
          issues.add(
            'Reference mismatch local=$localRef processor=$processorRef',
          );
        }

        if (issues.isEmpty) {
          verifiedCount += 1;
          integrityItems.add({
            'id': localRow['id']?.toString() ?? '',
            'status': 'verified',
            'summary': 'Matched processor daily report.',
            'processorReferenceId': processorRef,
            'processorTransactionType':
                processorRow['TransactionType']?.toString() ?? '',
          });
        } else {
          mismatchCount += 1;
          integrityItems.add({
            'id': localRow['id']?.toString() ?? '',
            'status': 'mismatch',
            'summary': issues.join(' | '),
            'processorReferenceId': processorRef,
            'processorTransactionType':
                processorRow['TransactionType']?.toString() ?? '',
          });
        }
      }

      final status = missingCount == 0 && mismatchCount == 0
          ? 'verified'
          : verifiedCount > 0
          ? 'partial'
          : 'failed';
      final summary =
          'Verified $verifiedCount of ${localTransactions.length} transactions'
          '${mismatchCount > 0 ? ', mismatched $mismatchCount' : ''}'
          '${missingCount > 0 ? ', missing $missingCount' : ''}.';

      return _buildIntegrityResult(
        report: report,
        status: status,
        summary: summary,
        items: integrityItems,
      );
    } catch (error) {
      return _buildIntegrityResult(
        report: report,
        status: 'failed',
        summary: 'Processor integrity check failed: $error',
        items: const [],
      );
    }
  }

  bool _isTransientOrPostCloseIntegrityMessage(String message) {
    final m = message.toLowerCase();
    return m.contains('service busy') ||
        m.contains('temporarily unavailable') ||
        m.contains('timeout') ||
        m.contains('try again') ||
        m.contains('no transaction in the batch') ||
        m.contains('no transaction in batch');
  }

  Map<String, dynamic> _buildIntegrityResult({
    required Map<String, dynamic> report,
    required String status,
    required String summary,
    required List<Map<String, dynamic>> items,
  }) {
    final header = Map<String, dynamic>.from(
      report['header'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    );
    final transactions = (report['transactions'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final existingStatus = (header['integrityStatus']?.toString() ?? '')
        .toLowerCase();

    var effectiveStatus = status;
    var effectiveSummary = summary;
    if (existingStatus == 'verified' && status == 'unavailable') {
      effectiveStatus = 'verified';
      effectiveSummary =
          'Previously verified. Latest processor check unavailable: $summary';
    }

    final itemById = {
      for (final item in items)
        if ((item['id']?.toString() ?? '').isNotEmpty)
          item['id'].toString(): item,
    };

    final nextTransactions = transactions.map((row) {
      final rowId = row['id']?.toString() ?? '';
      final integrity = itemById[rowId];
      if (integrity == null) return row;
      return {
        ...row,
        'integrityStatus': integrity['status'],
        'integritySummary': integrity['summary'],
      };
    }).toList();

    return {
      'version': report['version'],
      'reportType': report['reportType'],
      if (report.containsKey('source')) 'source': report['source'],
      'header': {
        ...header,
        'integrityStatus': effectiveStatus,
        'integritySummary': effectiveSummary,
        'integrityCheckedAt': DateTime.now().toUtc().toIso8601String(),
      },
      'transactions': nextTransactions,
    };
  }

  int _findMatchingProcessorTransactionIndex({
    required Map<String, dynamic> localRow,
    required List<Map<String, dynamic>> processorTransactions,
    required Set<int> usedIndexes,
  }) {
    final localReferenceId = (localRow['referenceId']?.toString() ?? '').trim();
    if (localReferenceId.isNotEmpty) {
      for (var index = 0; index < processorTransactions.length; index++) {
        if (usedIndexes.contains(index)) continue;
        if (_extractProcessorReferenceId(processorTransactions[index]) ==
            localReferenceId) {
          return index;
        }
      }
    }

    final localAmount = _asDouble(localRow['amount']).abs();
    final localLast4 = (localRow['cardLast4']?.toString() ?? '').trim();
    for (var index = 0; index < processorTransactions.length; index++) {
      if (usedIndexes.contains(index)) continue;
      final processorRow = processorTransactions[index];
      final processorAmount = _extractProcessorAmount(processorRow).abs();
      final processorLast4 = _extractProcessorLast4(processorRow);
      if ((processorAmount - localAmount).abs() > 0.01) continue;
      if (localLast4.isNotEmpty &&
          processorLast4.isNotEmpty &&
          localLast4 != processorLast4) {
        continue;
      }
      return index;
    }

    return -1;
  }

  double _extractProcessorAmount(Map<String, dynamic> processorRow) {
    return _asDouble(
      processorRow['Amount'] ??
          processorRow['TotalAmount'] ??
          processorRow['AuthorizedAmount'],
    );
  }

  String _extractProcessorReferenceId(Map<String, dynamic> processorRow) {
    return (processorRow['ReferenceId']?.toString() ??
            processorRow['RefNum']?.toString() ??
            processorRow['Number']?.toString() ??
            '')
        .trim();
  }

  String _extractProcessorLast4(Map<String, dynamic> processorRow) {
    return (processorRow['Last4']?.toString() ??
            processorRow['CardLast4']?.toString() ??
            '')
        .trim();
  }

  Future<int?> _saveCardBatchReportToLedger({
    required Map<String, dynamic> report,
    String? processorCloseResponseRaw,
  }) async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) {
        return null;
      }

      final header = Map<String, dynamic>.from(
        report['header'] as Map<String, dynamic>? ?? const <String, dynamic>{},
      );
      final batchRows = (report['transactions'] as List? ?? const [])
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList();
      final accepted = header['accepted'] == true;
      final normalizedRows = batchRows
          .map(_normalizeBatchReportRowForTotals)
          .toList(growable: false);
      final recomputedTotals = _buildLedgerIntegrityTotals(normalizedRows);

      if ((processorCloseResponseRaw ?? '').trim().isNotEmpty) {
        try {
          jsonDecode(processorCloseResponseRaw!);
        } catch (_) {}
      }

      final insertedHeader = await SupabaseService.client
          .from(_cardBatchHeadersTable)
          .insert({
            'organization_id': scope.organizationId,
            'location_id': scope.locationId,
            if (scope.terminalId != null && scope.terminalId!.isNotEmpty)
              'terminal_id': scope.terminalId,
            'accepted': accepted,
            'processor_status': header['processorStatus']?.toString() ?? '',
            'processor_message': header['processorMessage']?.toString() ?? '',
            'terminal_name': header['terminalName']?.toString() ?? '',
            'location_name': header['locationName']?.toString() ?? '',
            'organization_name': header['organizationName']?.toString() ?? '',
            'organization_number':
                header['organizationNumber']?.toString() ?? '',
            'closed_at':
                header['closedAt']?.toString() ??
                DateTime.now().toUtc().toIso8601String(),
            'transaction_count': batchRows.length,
            'approved_count': _asInt(recomputedTotals['approvedCount']),
            'voided_count': _asInt(recomputedTotals['voidedCount']),
            'original_total': _asDouble(recomputedTotals['saleAmount']),
            'tip_total': _asDouble(recomputedTotals['tipAdjustAmount']),
            'final_total': _asDouble(recomputedTotals['netAmount']),
            'total_amount': _asDouble(recomputedTotals['netAmount']),
            'integrity_status': header['integrityStatus']?.toString() ?? '',
            'integrity_summary': header['integritySummary']?.toString() ?? '',
            'processor_close_raw': processorCloseResponseRaw,
          })
          .select('id,batch_number')
          .single();

      final batchHeaderId = insertedHeader['id']?.toString() ?? '';
      if (batchHeaderId.isEmpty) {
        return null;
      }

      if (batchRows.isNotEmpty) {
        final detailPayloads = batchRows.map((row) {
          final amount = ((row['amount'] is num)
              ? (row['amount'] as num).toDouble()
              : 0);
          return {
            'card_batch_header_id': batchHeaderId,
            'organization_id': scope.organizationId,
            'location_id': scope.locationId,
            'transaction_detail_id': row['id']?.toString(),
            'transaction_header_id':
                row['transaction_header_id']?.toString() ??
                row['transactionHeaderId']?.toString(),
            'reference_id':
                row['reference_id']?.toString() ??
                row['referenceId']?.toString() ??
                '',
            'amount': amount,
            'fee_amount': _asDouble(row['feeAmount'] ?? row['fee_amount']),
            'card_type':
                row['cardType']?.toString() ??
                row['card_type']?.toString() ??
                '',
            'card_last4':
                row['cardLast4']?.toString() ??
                row['card_last4']?.toString() ??
                '',
            'auth_code':
                row['authCode']?.toString() ??
                row['auth_code']?.toString() ??
                '',
            'status': row['status']?.toString() ?? '',
            'close_status': accepted ? 'Accepted' : 'Not Accepted',
            'integrity_status': row['integrityStatus']?.toString() ?? '',
            'integrity_summary': row['integritySummary']?.toString() ?? '',
            'processor_reference_id':
                row['processorReferenceId']?.toString() ?? '',
            'processor_transaction_type':
                row['processorTransactionType']?.toString() ?? '',
            'created_at':
                row['createdAt']?.toString() ??
                DateTime.now().toUtc().toIso8601String(),
          };
        }).toList();

        await SupabaseService.client
            .from(_cardBatchDetailsTable)
            .insert(detailPayloads);
      }

      final closedBatchNumber = _asInt(insertedHeader['batch_number']);
      return closedBatchNumber > 0 ? closedBatchNumber : null;
    } catch (error) {
      debugPrint('save card_batch header/detail failed: $error');
      return null;
    }
  }

  Map<String, dynamic> _normalizeBatchReportRowForTotals(
    Map<String, dynamic> row,
  ) {
    return {
      'id': row['id']?.toString() ?? '',
      'amount': _asDouble(row['amount']),
      'fee_amount': _asDouble(row['fee_amount'] ?? row['feeAmount']),
      'surcharge_amount': _asDouble(
        row['surcharge_amount'] ?? row['surchargeAmount'],
      ),
      'tip_adjustment_total': _asDouble(
        row['tip_adjustment_total'] ?? row['tipAdjustmentTotal'],
      ),
      'status': row['status']?.toString() ?? '',
      'subtype': row['subtype']?.toString() ?? '',
      'original_detail_id':
          row['original_detail_id']?.toString() ??
          row['originalDetailId']?.toString() ??
          '',
      'gateway_raw': row['gateway_raw'] ?? row['gatewayRaw'],
    };
  }

  Future<List<Map<String, dynamic>>> getClosedBatchHeaders({
    int limit = 200,
  }) async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) return const [];

      final rows = await SupabaseService.client
          .from(_cardBatchHeadersTable)
          .select(
            'id,batch_number,accepted,processor_status,processor_message,terminal_name,location_name,organization_name,organization_number,closed_at,transaction_count,approved_count,voided_count,original_total,tip_total,final_total,total_amount,integrity_status,integrity_summary,created_at',
          )
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId)
          .order('closed_at', ascending: false)
          .limit(limit);

      return List<Map<String, dynamic>>.from(rows);
    } catch (error) {
      debugPrint('getClosedBatchHeaders failed: $error');
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> getClosedBatchDetails(
    String cardBatchHeaderId,
  ) async {
    final trimmed = cardBatchHeaderId.trim();
    if (trimmed.isEmpty) return const [];

    try {
      final scope = await _resolveTenantScope();
      if (scope == null) return const [];

      final rows = await SupabaseService.client
          .from(_cardBatchDetailsTable)
          .select(
            'id,card_batch_header_id,transaction_detail_id,transaction_header_id,reference_id,amount,fee_amount,card_type,card_last4,auth_code,status,close_status,integrity_status,integrity_summary,processor_reference_id,processor_transaction_type,created_at',
          )
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId)
          .eq('card_batch_header_id', trimmed)
          .order('created_at', ascending: false)
          .limit(1000);

      final baseRows = List<Map<String, dynamic>>.from(rows);
      if (baseRows.isEmpty) return const [];

      final detailIds = baseRows
          .map((row) => row['transaction_detail_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      final txnById = <String, Map<String, dynamic>>{};
      if (detailIds.isNotEmpty) {
        final txnRows = await SupabaseService.client
            .from('transaction_details')
            .select(
              'id,transaction_header_id,payment_type,subtype,amount,fee_amount,status,reference_id,auth_code,card_last4,card_type,gateway_raw,original_detail_id,created_at',
            )
            .eq('organization_id', scope.organizationId)
            .eq('location_id', scope.locationId)
            .inFilter('id', detailIds);

        for (final raw in List<Map<String, dynamic>>.from(txnRows)) {
          final id = raw['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          txnById[id] = raw;
        }
      }

      final enriched = baseRows.map((row) {
        final merged = Map<String, dynamic>.from(row);
        final detailId = merged['transaction_detail_id']?.toString() ?? '';
        final txn = txnById[detailId];
        if (txn != null) {
          merged['subtype'] = txn['subtype']?.toString() ?? '';
          merged['original_detail_id'] =
              txn['original_detail_id']?.toString() ?? '';
          merged['resolved_transaction_detail_id'] =
              txn['id']?.toString() ?? detailId;
        } else {
          merged['subtype'] = merged['subtype']?.toString() ?? '';
          merged['original_detail_id'] =
              merged['original_detail_id']?.toString() ?? '';
          merged['resolved_transaction_detail_id'] = detailId;
        }
        merged['display_amount'] = _asDouble(merged['amount']);
        merged['tip_adjustment_total'] = 0.0;
        merged['original_amount_with_tip'] = _asDouble(merged['amount']);
        return merged;
      }).toList();

      final byResolvedId = <String, Map<String, dynamic>>{};
      for (final row in enriched) {
        final id = row['resolved_transaction_detail_id']?.toString() ?? '';
        if (id.isNotEmpty) byResolvedId[id] = row;
      }

      final tipRows = <Map<String, dynamic>>[];
      final visible = <Map<String, dynamic>>[];
      for (final row in enriched) {
        final subtype = row['subtype']?.toString().toLowerCase() ?? '';
        if (subtype == 'a') {
          tipRows.add(row);
          continue;
        }
        visible.add(row);
      }

      for (final tip in tipRows) {
        final originalId = tip['original_detail_id']?.toString() ?? '';
        final host = byResolvedId[originalId];
        if (host == null) {
          visible.add(tip);
          continue;
        }
        final tipAmount = _asDouble(tip['amount']).abs();
        host['tip_adjustment_total'] =
            _asDouble(host['tip_adjustment_total']) + tipAmount;
        host['original_amount_with_tip'] =
            _asDouble(host['original_amount_with_tip']) + tipAmount;
        host['display_amount'] = _asDouble(host['display_amount']) + tipAmount;

        final refs = (host['tip_adjustment_refs'] as List?) ?? <String>[];
        refs.add(tip['resolved_transaction_detail_id']?.toString() ?? '');
        host['tip_adjustment_refs'] = refs;
      }

      visible.sort((a, b) {
        final aRaw = a['created_at']?.toString() ?? '';
        final bRaw = b['created_at']?.toString() ?? '';
        return bRaw.compareTo(aRaw);
      });

      return visible;
    } catch (error) {
      debugPrint('getClosedBatchDetails failed: $error');
      return const [];
    }
  }

  Future<Map<String, dynamic>?> getTransactionDetailById(
    String detailId,
  ) async {
    final trimmed = detailId.trim();
    if (trimmed.isEmpty) return null;

    try {
      final scope = await _resolveTenantScope();
      if (scope == null) return null;

      final row = await SupabaseService.client
          .from('transaction_details')
          .select(
            'id,transaction_header_id,payment_type,subtype,amount,fee_amount,status,batch_status,reference_id,auth_code,card_last4,card_type,gateway_provider,gateway_token,gateway_raw,original_detail_id,receipt_id,created_at',
          )
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId)
          .eq('id', trimmed)
          .maybeSingle();

      if (row == null) return null;
      return _attachHeaderToDetail(Map<String, dynamic>.from(row), scope);
    } catch (error) {
      debugPrint('getTransactionDetailById failed: $error');
      return null;
    }
  }

  Future<Map<String, dynamic>> _attachHeaderToDetail(
    Map<String, dynamic> detail,
    _TenantScope scope,
  ) async {
    final result = Map<String, dynamic>.from(detail);
    final headerId = result['transaction_header_id']?.toString().trim() ?? '';
    if (headerId.isEmpty) return result;

    try {
      final header = await SupabaseService.client
          .from('transaction_headers')
          .select(
            'id,batch_number,terminal_number,txn_seq,terminal_name,staff_name,invoice_reference,subtotal,tax,total,fee_amount,amount_paid,amount_due,status,created_at,updated_at',
          )
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId)
          .eq('id', headerId)
          .maybeSingle();

      if (header != null) {
        result['transaction_headers'] = Map<String, dynamic>.from(header);
      }
    } catch (_) {
      // Keep detail payload even when header cannot be attached.
    }

    return result;
  }

  Future<Map<String, dynamic>?> getClosedBatchTransactionDrilldown({
    String? transactionDetailId,
    String? transactionHeaderId,
    String? cardBatchHeaderId,
    String? referenceId,
    String? authCode,
    String? cardLast4,
    String? cardType,
    double? amount,
    String? createdAt,
  }) async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) return null;

      Map<String, dynamic>? resolved;
      var lookupSource = 'none';

      final detailId = transactionDetailId?.trim() ?? '';
      if (detailId.isNotEmpty) {
        resolved = await getTransactionDetailById(detailId);
        if (resolved != null && resolved.isNotEmpty) {
          lookupSource = 'transaction_detail_id';
        }

        if (resolved == null) {
          final receiptMatch = await SupabaseService.client
              .from('transaction_details')
              .select(
                'id,transaction_header_id,payment_type,subtype,amount,fee_amount,status,batch_status,reference_id,auth_code,card_last4,card_type,gateway_provider,gateway_token,gateway_raw,original_detail_id,receipt_id,created_at',
              )
              .eq('organization_id', scope.organizationId)
              .eq('location_id', scope.locationId)
              .eq('receipt_id', detailId)
              .order('created_at', ascending: false)
              .limit(1)
              .maybeSingle();
          if (receiptMatch != null) {
            resolved = Map<String, dynamic>.from(receiptMatch);
            lookupSource = 'receipt_id_fallback';
          }
        }

        if (resolved == null) {
          final referenceMatch = await SupabaseService.client
              .from('transaction_details')
              .select(
                'id,transaction_header_id,payment_type,subtype,amount,fee_amount,status,batch_status,reference_id,auth_code,card_last4,card_type,gateway_provider,gateway_token,gateway_raw,original_detail_id,receipt_id,created_at',
              )
              .eq('organization_id', scope.organizationId)
              .eq('location_id', scope.locationId)
              .eq('reference_id', detailId)
              .order('created_at', ascending: false)
              .limit(1)
              .maybeSingle();
          if (referenceMatch != null) {
            resolved = Map<String, dynamic>.from(referenceMatch);
            lookupSource = 'reference_id_fallback';
          }
        }
      }

      if (resolved == null) {
        final headerId = transactionHeaderId?.trim() ?? '';
        if (headerId.isNotEmpty) {
          final rows = List<Map<String, dynamic>>.from(
            await SupabaseService.client
                .from('transaction_details')
                .select(
                  'id,transaction_header_id,payment_type,subtype,amount,fee_amount,status,batch_status,reference_id,auth_code,card_last4,card_type,gateway_provider,gateway_token,gateway_raw,original_detail_id,receipt_id,created_at',
                )
                .eq('organization_id', scope.organizationId)
                .eq('location_id', scope.locationId)
                .eq('transaction_header_id', headerId)
                .order('created_at', ascending: false)
                .limit(200),
          );

          final refNeedle = referenceId?.trim().toLowerCase() ?? '';
          final authNeedle = authCode?.trim().toLowerCase() ?? '';
          final amountNeedle = (amount ?? 0).abs();

          bool isTipAdjust(Map<String, dynamic> row) {
            final subtype = row['subtype']?.toString().toLowerCase() ?? '';
            if (subtype == 'a') return true;
            final raw = row['gateway_raw'];
            if (raw is Map) {
              final op = (raw['operation']?.toString().toLowerCase() ?? '')
                  .trim();
              if (op == 'tip_adjust' || op == 'tip_adjust_probe') return true;
            }
            return false;
          }

          final nonTipRows = rows.where((row) => !isTipAdjust(row)).toList();
          final candidates = nonTipRows.isNotEmpty ? nonTipRows : rows;

          if (candidates.isNotEmpty) {
            Map<String, dynamic>? pickByReference;
            if (refNeedle.isNotEmpty) {
              pickByReference = candidates.firstWhere(
                (row) =>
                    (row['reference_id']?.toString().toLowerCase() ?? '') ==
                    refNeedle,
                orElse: () => <String, dynamic>{},
              );
              if (pickByReference.isEmpty) pickByReference = null;
            }

            Map<String, dynamic>? pickByAuth;
            if (pickByReference == null && authNeedle.isNotEmpty) {
              pickByAuth = candidates.firstWhere(
                (row) =>
                    (row['auth_code']?.toString().toLowerCase() ?? '') ==
                    authNeedle,
                orElse: () => <String, dynamic>{},
              );
              if (pickByAuth.isEmpty) pickByAuth = null;
            }

            Map<String, dynamic>? pickByAmount;
            if (pickByReference == null &&
                pickByAuth == null &&
                amountNeedle > 0.009) {
              pickByAmount = candidates.firstWhere(
                (row) =>
                    (_asDouble(row['amount']).abs() - amountNeedle).abs() <=
                    0.01,
                orElse: () => <String, dynamic>{},
              );
              if (pickByAmount.isEmpty) pickByAmount = null;
            }

            resolved =
                pickByReference ??
                pickByAuth ??
                pickByAmount ??
                Map<String, dynamic>.from(candidates.first);
            if (resolved.isNotEmpty) {
              resolved = Map<String, dynamic>.from(resolved);
              lookupSource = 'header_fallback';
            }
          }
        }
      }

      if (resolved == null) {
        final batchHeaderId = cardBatchHeaderId?.trim() ?? '';
        if (batchHeaderId.isNotEmpty) {
          final batchHeader = await SupabaseService.client
              .from(_cardBatchHeadersTable)
              .select('batch_number,closed_at,terminal_name')
              .eq('organization_id', scope.organizationId)
              .eq('location_id', scope.locationId)
              .eq('id', batchHeaderId)
              .maybeSingle();

          final batchNumber = _asInt(batchHeader?['batch_number']);
          if (batchNumber > 0) {
            final headerRows = List<Map<String, dynamic>>.from(
              await SupabaseService.client
                  .from('transaction_headers')
                  .select('id,batch_number,terminal_name,created_at')
                  .eq('organization_id', scope.organizationId)
                  .eq('location_id', scope.locationId)
                  .eq('batch_number', batchNumber)
                  .order('created_at', ascending: false)
                  .limit(300),
            );

            final headerIds = headerRows
                .map((row) => row['id']?.toString() ?? '')
                .where((id) => id.isNotEmpty)
                .toList(growable: false);

            if (headerIds.isNotEmpty) {
              final rows = List<Map<String, dynamic>>.from(
                await SupabaseService.client
                    .from('transaction_details')
                    .select(
                      'id,transaction_header_id,payment_type,subtype,amount,fee_amount,status,batch_status,reference_id,auth_code,card_last4,card_type,gateway_provider,gateway_token,gateway_raw,original_detail_id,receipt_id,created_at',
                    )
                    .eq('organization_id', scope.organizationId)
                    .eq('location_id', scope.locationId)
                    .inFilter('transaction_header_id', headerIds)
                    .order('created_at', ascending: false)
                    .limit(1000),
              );

              if (rows.isNotEmpty) {
                final refNeedle = referenceId?.trim().toLowerCase() ?? '';
                final authNeedle = authCode?.trim().toLowerCase() ?? '';
                final cardNeedle = cardLast4?.trim() ?? '';
                final typeNeedle = cardType?.trim().toLowerCase() ?? '';
                final amountNeedle = (amount ?? 0).abs();
                final createdNeedle = DateTime.tryParse(
                  createdAt?.trim() ?? '',
                )?.toUtc();

                int scoreRow(Map<String, dynamic> row) {
                  var score = 0;

                  final subtype =
                      row['subtype']?.toString().toLowerCase() ?? '';
                  if (subtype == 's' || subtype == 'r' || subtype == 'v') {
                    score += 2;
                  }

                  final rowRef =
                      row['reference_id']?.toString().toLowerCase() ?? '';
                  if (refNeedle.isNotEmpty && rowRef == refNeedle) {
                    score += 70;
                  }

                  final rowAuth =
                      row['auth_code']?.toString().toLowerCase() ?? '';
                  if (authNeedle.isNotEmpty && rowAuth == authNeedle) {
                    score += 50;
                  }

                  final rowCard = row['card_last4']?.toString() ?? '';
                  if (cardNeedle.isNotEmpty && rowCard == cardNeedle) {
                    score += 25;
                  }

                  final rowType =
                      row['card_type']?.toString().toLowerCase() ?? '';
                  if (typeNeedle.isNotEmpty && rowType == typeNeedle) {
                    score += 10;
                  }

                  if (amountNeedle > 0.009) {
                    final rowAmount = _asDouble(row['amount']).abs();
                    if ((rowAmount - amountNeedle).abs() <= 0.01) {
                      score += 25;
                    }
                  }

                  final rowCreated = DateTime.tryParse(
                    row['created_at']?.toString() ?? '',
                  )?.toUtc();
                  if (createdNeedle != null && rowCreated != null) {
                    final deltaMinutes = rowCreated
                        .difference(createdNeedle)
                        .inMinutes
                        .abs();
                    if (deltaMinutes <= 2) {
                      score += 20;
                    } else if (deltaMinutes <= 10) {
                      score += 12;
                    } else if (deltaMinutes <= 60) {
                      score += 6;
                    }
                  }

                  return score;
                }

                Map<String, dynamic>? best;
                var bestScore = -1;
                for (final row in rows) {
                  final rowScore = scoreRow(row);
                  if (rowScore > bestScore) {
                    bestScore = rowScore;
                    best = row;
                  }
                }

                if (best != null) {
                  resolved = Map<String, dynamic>.from(best);
                  lookupSource = 'batch_header_lookup';
                }
              }
            }
          }
        }
      }

      if (resolved == null) {
        final refNeedle = referenceId?.trim().toLowerCase() ?? '';
        final authNeedle = authCode?.trim().toLowerCase() ?? '';
        final cardNeedle = cardLast4?.trim() ?? '';
        final typeNeedle = cardType?.trim().toLowerCase() ?? '';
        final amountNeedle = (amount ?? 0).abs();
        final createdNeedle = DateTime.tryParse(
          createdAt?.trim() ?? '',
        )?.toUtc();

        final lowerBound = createdNeedle?.subtract(const Duration(days: 2));
        final upperBound = createdNeedle?.add(const Duration(days: 2));

        var query = SupabaseService.client
            .from('transaction_details')
            .select(
              'id,transaction_header_id,payment_type,subtype,amount,fee_amount,status,batch_status,reference_id,auth_code,card_last4,card_type,gateway_provider,gateway_token,gateway_raw,original_detail_id,receipt_id,created_at',
            )
            .eq('organization_id', scope.organizationId)
            .eq('location_id', scope.locationId);

        if (lowerBound != null && upperBound != null) {
          query = query
              .gte('created_at', lowerBound.toIso8601String())
              .lte('created_at', upperBound.toIso8601String());
        }

        final rows = List<Map<String, dynamic>>.from(
          await query.order('created_at', ascending: false).limit(500),
        );
        if (rows.isNotEmpty) {
          int scoreRow(Map<String, dynamic> row) {
            var score = 0;

            final rowRef = row['reference_id']?.toString().toLowerCase() ?? '';
            if (refNeedle.isNotEmpty && rowRef == refNeedle) {
              score += 60;
            }

            final rowAuth = row['auth_code']?.toString().toLowerCase() ?? '';
            if (authNeedle.isNotEmpty && rowAuth == authNeedle) {
              score += 45;
            }

            final rowCard = row['card_last4']?.toString() ?? '';
            if (cardNeedle.isNotEmpty && rowCard == cardNeedle) {
              score += 25;
            }

            final rowType = row['card_type']?.toString().toLowerCase() ?? '';
            if (typeNeedle.isNotEmpty && rowType == typeNeedle) {
              score += 10;
            }

            if (amountNeedle > 0.009) {
              final rowAmount = _asDouble(row['amount']).abs();
              if ((rowAmount - amountNeedle).abs() <= 0.01) {
                score += 25;
              }
            }

            final rowCreated = DateTime.tryParse(
              row['created_at']?.toString() ?? '',
            )?.toUtc();
            if (createdNeedle != null && rowCreated != null) {
              final deltaMinutes = rowCreated
                  .difference(createdNeedle)
                  .inMinutes
                  .abs();
              if (deltaMinutes <= 2) {
                score += 20;
              } else if (deltaMinutes <= 10) {
                score += 12;
              } else if (deltaMinutes <= 60) {
                score += 6;
              }
            }

            return score;
          }

          Map<String, dynamic>? best;
          var bestScore = -1;
          for (final row in rows) {
            final rowScore = scoreRow(row);
            if (rowScore > bestScore) {
              bestScore = rowScore;
              best = row;
            }
          }

          if (best != null) {
            resolved = Map<String, dynamic>.from(best);
            lookupSource = 'scored_lookup';
          }
        }
      }

      if (resolved == null) {
        final refNeedle = referenceId?.trim().toLowerCase() ?? '';
        final authNeedle = authCode?.trim().toLowerCase() ?? '';
        final cardNeedle = cardLast4?.trim() ?? '';
        final typeNeedle = cardType?.trim().toLowerCase() ?? '';
        final amountNeedle = (amount ?? 0).abs();
        final createdNeedle = DateTime.tryParse(
          createdAt?.trim() ?? '',
        )?.toUtc();

        final rows = List<Map<String, dynamic>>.from(
          await SupabaseService.client
              .from('transaction_details')
              .select(
                'id,transaction_header_id,payment_type,subtype,amount,fee_amount,status,batch_status,reference_id,auth_code,card_last4,card_type,gateway_provider,gateway_token,gateway_raw,original_detail_id,receipt_id,created_at',
              )
              .order('created_at', ascending: false)
              .limit(1500),
        );

        if (rows.isNotEmpty) {
          int scoreRow(Map<String, dynamic> row) {
            var score = 0;

            final rowRef = row['reference_id']?.toString().toLowerCase() ?? '';
            if (refNeedle.isNotEmpty && rowRef == refNeedle) {
              score += 70;
            }

            final rowAuth = row['auth_code']?.toString().toLowerCase() ?? '';
            if (authNeedle.isNotEmpty && rowAuth == authNeedle) {
              score += 50;
            }

            final rowCard = row['card_last4']?.toString() ?? '';
            if (cardNeedle.isNotEmpty && rowCard == cardNeedle) {
              score += 25;
            }

            final rowType = row['card_type']?.toString().toLowerCase() ?? '';
            if (typeNeedle.isNotEmpty && rowType == typeNeedle) {
              score += 10;
            }

            if (amountNeedle > 0.009) {
              final rowAmount = _asDouble(row['amount']).abs();
              if ((rowAmount - amountNeedle).abs() <= 0.01) {
                score += 25;
              }
            }

            final rowCreated = DateTime.tryParse(
              row['created_at']?.toString() ?? '',
            )?.toUtc();
            if (createdNeedle != null && rowCreated != null) {
              final deltaMinutes = rowCreated
                  .difference(createdNeedle)
                  .inMinutes
                  .abs();
              if (deltaMinutes <= 2) {
                score += 20;
              } else if (deltaMinutes <= 10) {
                score += 12;
              } else if (deltaMinutes <= 60) {
                score += 6;
              }
            }

            return score;
          }

          Map<String, dynamic>? best;
          var bestScore = -1;
          for (final row in rows) {
            final rowScore = scoreRow(row);
            if (rowScore > bestScore) {
              bestScore = rowScore;
              best = row;
            }
          }

          if (best != null) {
            resolved = Map<String, dynamic>.from(best);
            lookupSource = 'legacy_unscoped_lookup';
          }
        }
      }

      if (resolved == null || resolved.isEmpty) return null;
      resolved = await _attachHeaderToDetail(resolved, scope);

      final resolvedId = resolved['id']?.toString() ?? '';
      double tipAdjustmentTotal = 0;
      List<Map<String, dynamic>> tipAdjustments = const [];

      if (resolvedId.isNotEmpty) {
        final tipRows = List<Map<String, dynamic>>.from(
          await SupabaseService.client
              .from('transaction_details')
              .select(
                'id,amount,status,subtype,reference_id,auth_code,created_at,gateway_raw',
              )
              .eq('organization_id', scope.organizationId)
              .eq('location_id', scope.locationId)
              .eq('original_detail_id', resolvedId)
              .eq('subtype', 'a')
              .inFilter('status', ['approved', 'voided'])
              .order('created_at', ascending: true),
        );

        tipAdjustments = tipRows;
        tipAdjustmentTotal = tipRows.fold<double>(
          0,
          (sum, row) => sum + _asDouble(row['amount']).abs(),
        );
      }

      final result = Map<String, dynamic>.from(resolved);
      result['tip_adjustments'] = tipAdjustments;
      result['tip_adjustment_total'] = tipAdjustmentTotal;
      result['display_amount'] =
          _asDouble(result['amount']) + tipAdjustmentTotal;
      result['lookup_source'] = lookupSource;
      result['lookup_context'] = {
        'transactionDetailId': detailId,
        'transactionHeaderId': transactionHeaderId,
        'cardBatchHeaderId': cardBatchHeaderId,
        'referenceId': referenceId,
        'authCode': authCode,
        'cardLast4': cardLast4,
        'cardType': cardType,
        'amount': amount,
        'createdAt': createdAt,
      };

      return result;
    } catch (error) {
      debugPrint('getClosedBatchTransactionDrilldown failed: $error');
      return {'lookup_source': 'error', 'lookup_error': error.toString()};
    }
  }

  Future<Map<String, dynamic>> backfillClosedBatchHeaderTotals({
    int limit = 2000,
    bool dryRun = false,
  }) async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) {
        return {
          'ok': false,
          'error': 'Tenant scope could not be resolved.',
          'examined': 0,
          'updated': 0,
          'unchanged': 0,
          'errors': 0,
          'dryRun': dryRun,
        };
      }

      final headerRows = List<Map<String, dynamic>>.from(
        await SupabaseService.client
            .from(_cardBatchHeadersTable)
            .select(
              'id,transaction_count,approved_count,voided_count,original_total,tip_total,final_total,total_amount',
            )
            .eq('organization_id', scope.organizationId)
            .eq('location_id', scope.locationId)
            .order('closed_at', ascending: false)
            .limit(limit),
      );

      int examined = 0;
      int updated = 0;
      int unchanged = 0;
      int errors = 0;

      for (final header in headerRows) {
        examined += 1;
        try {
          final headerId = header['id']?.toString() ?? '';
          if (headerId.isEmpty) {
            unchanged += 1;
            continue;
          }

          final batchDetailRows = List<Map<String, dynamic>>.from(
            await SupabaseService.client
                .from(_cardBatchDetailsTable)
                .select('id,transaction_detail_id,amount,fee_amount,status')
                .eq('organization_id', scope.organizationId)
                .eq('location_id', scope.locationId)
                .eq('card_batch_header_id', headerId)
                .order('created_at', ascending: false)
                .limit(2000),
          );

          if (batchDetailRows.isEmpty) {
            unchanged += 1;
            continue;
          }

          final baseDetailIds = batchDetailRows
              .map((row) => row['transaction_detail_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList();

          final txnById = <String, Map<String, dynamic>>{};
          if (baseDetailIds.isNotEmpty) {
            final txnRows = List<Map<String, dynamic>>.from(
              await SupabaseService.client
                  .from('transaction_details')
                  .select(
                    'id,amount,fee_amount,status,subtype,original_detail_id,gateway_raw',
                  )
                  .eq('organization_id', scope.organizationId)
                  .eq('location_id', scope.locationId)
                  .inFilter('id', baseDetailIds),
            );

            for (final row in txnRows) {
              final id = row['id']?.toString() ?? '';
              if (id.isEmpty) continue;
              txnById[id] = row;
            }
          }

          final tipByOriginalId = <String, double>{};
          if (baseDetailIds.isNotEmpty) {
            final tipRows = List<Map<String, dynamic>>.from(
              await SupabaseService.client
                  .from('transaction_details')
                  .select(
                    'original_detail_id,amount,status,subtype,gateway_raw',
                  )
                  .eq('organization_id', scope.organizationId)
                  .eq('location_id', scope.locationId)
                  .eq('subtype', 'a')
                  .inFilter('original_detail_id', baseDetailIds),
            );

            for (final tip in tipRows) {
              final originalId = tip['original_detail_id']?.toString() ?? '';
              if (originalId.isEmpty) continue;
              final status =
                  tip['status']?.toString().toLowerCase().trim() ?? '';
              if (status != 'approved') continue;
              final amount = _asDouble(tip['amount']).abs();
              if (amount <= 0.0001) continue;
              tipByOriginalId.update(
                originalId,
                (value) => value + amount,
                ifAbsent: () => amount,
              );
            }
          }

          final normalizedRows = batchDetailRows
              .map((row) {
                final detailId = row['transaction_detail_id']?.toString() ?? '';
                final txn = txnById[detailId];
                return {
                  'id': detailId.isNotEmpty
                      ? detailId
                      : (row['id']?.toString() ?? ''),
                  'amount': _asDouble(txn?['amount'] ?? row['amount']),
                  'fee_amount': _asDouble(
                    txn?['fee_amount'] ?? row['fee_amount'],
                  ),
                  'tip_adjustment_total': tipByOriginalId[detailId] ?? 0.0,
                  'status':
                      (txn?['status']?.toString() ??
                              row['status']?.toString() ??
                              '')
                          .trim(),
                  'subtype': (txn?['subtype']?.toString() ?? '').trim(),
                  'original_detail_id':
                      (txn?['original_detail_id']?.toString() ?? '').trim(),
                  'gateway_raw': txn?['gateway_raw'],
                };
              })
              .toList(growable: false);

          final totals = _buildLedgerIntegrityTotals(normalizedRows);

          final nextTransactionCount = normalizedRows.length;
          final nextApprovedCount = _asInt(totals['approvedCount']);
          final nextVoidedCount = _asInt(totals['voidedCount']);
          final nextOriginalTotal = _asDouble(totals['saleAmount']);
          final nextTipTotal = _asDouble(totals['tipAdjustAmount']);
          final nextFinalTotal = _asDouble(totals['netAmount']);
          final nextTotalAmount = nextFinalTotal;

          final currentTransactionCount = _asInt(header['transaction_count']);
          final currentApprovedCount = _asInt(header['approved_count']);
          final currentVoidedCount = _asInt(header['voided_count']);
          final currentOriginalTotal = _asDouble(header['original_total']);
          final currentTipTotal = _asDouble(header['tip_total']);
          final currentFinalTotal = _asDouble(header['final_total']);
          final currentTotalAmount = _asDouble(header['total_amount']);

          bool changed = false;
          changed = changed || currentTransactionCount != nextTransactionCount;
          changed = changed || currentApprovedCount != nextApprovedCount;
          changed = changed || currentVoidedCount != nextVoidedCount;
          changed =
              changed ||
              (currentOriginalTotal - nextOriginalTotal).abs() > 0.009;
          changed = changed || (currentTipTotal - nextTipTotal).abs() > 0.009;
          changed =
              changed || (currentFinalTotal - nextFinalTotal).abs() > 0.009;
          changed =
              changed || (currentTotalAmount - nextTotalAmount).abs() > 0.009;

          if (!changed) {
            unchanged += 1;
            continue;
          }

          if (!dryRun) {
            await SupabaseService.client
                .from(_cardBatchHeadersTable)
                .update({
                  'transaction_count': nextTransactionCount,
                  'approved_count': nextApprovedCount,
                  'voided_count': nextVoidedCount,
                  'original_total': nextOriginalTotal,
                  'tip_total': nextTipTotal,
                  'final_total': nextFinalTotal,
                  'total_amount': nextTotalAmount,
                })
                .eq('organization_id', scope.organizationId)
                .eq('location_id', scope.locationId)
                .eq('id', headerId);
          }

          updated += 1;
        } catch (error) {
          errors += 1;
          debugPrint('backfillClosedBatchHeaderTotals row failed: $error');
        }
      }

      return {
        'ok': true,
        'examined': examined,
        'updated': updated,
        'unchanged': unchanged,
        'errors': errors,
        'dryRun': dryRun,
      };
    } catch (error) {
      debugPrint('backfillClosedBatchHeaderTotals failed: $error');
      return {
        'ok': false,
        'error': error.toString(),
        'examined': 0,
        'updated': 0,
        'unchanged': 0,
        'errors': 1,
        'dryRun': dryRun,
      };
    }
  }

  Future<Map<String, dynamic>> reconcileClosedBatchHeaderTotals(
    String headerId, {
    bool dryRun = false,
  }) async {
    final trimmed = headerId.trim();
    if (trimmed.isEmpty) {
      return {'ok': false, 'error': 'Missing header id.', 'changed': false};
    }

    try {
      final scope = await _resolveTenantScope();
      if (scope == null) {
        return {
          'ok': false,
          'error': 'Tenant scope could not be resolved.',
          'changed': false,
        };
      }

      final header = await SupabaseService.client
          .from(_cardBatchHeadersTable)
          .select(
            'id,transaction_count,approved_count,voided_count,original_total,tip_total,final_total,total_amount',
          )
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId)
          .eq('id', trimmed)
          .maybeSingle();

      if (header == null) {
        return {'ok': false, 'error': 'Header not found.', 'changed': false};
      }

      final headerRow = Map<String, dynamic>.from(header);
      final batchDetailRows = List<Map<String, dynamic>>.from(
        await SupabaseService.client
            .from(_cardBatchDetailsTable)
            .select('id,transaction_detail_id,amount,fee_amount,status')
            .eq('organization_id', scope.organizationId)
            .eq('location_id', scope.locationId)
            .eq('card_batch_header_id', trimmed)
            .order('created_at', ascending: false)
            .limit(2000),
      );

      if (batchDetailRows.isEmpty) {
        return {
          'ok': true,
          'changed': false,
          'reason': 'No detail rows found for header.',
        };
      }

      final baseDetailIds = batchDetailRows
          .map((row) => row['transaction_detail_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      final txnById = <String, Map<String, dynamic>>{};
      if (baseDetailIds.isNotEmpty) {
        final txnRows = List<Map<String, dynamic>>.from(
          await SupabaseService.client
              .from('transaction_details')
              .select(
                'id,amount,fee_amount,status,subtype,original_detail_id,gateway_raw',
              )
              .eq('organization_id', scope.organizationId)
              .eq('location_id', scope.locationId)
              .inFilter('id', baseDetailIds),
        );

        for (final row in txnRows) {
          final id = row['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          txnById[id] = row;
        }
      }

      final tipByOriginalId = <String, double>{};
      if (baseDetailIds.isNotEmpty) {
        final tipRows = List<Map<String, dynamic>>.from(
          await SupabaseService.client
              .from('transaction_details')
              .select('original_detail_id,amount,status,subtype,gateway_raw')
              .eq('organization_id', scope.organizationId)
              .eq('location_id', scope.locationId)
              .eq('subtype', 'a')
              .inFilter('original_detail_id', baseDetailIds),
        );

        for (final tip in tipRows) {
          final originalId = tip['original_detail_id']?.toString() ?? '';
          if (originalId.isEmpty) continue;
          final status = tip['status']?.toString().toLowerCase().trim() ?? '';
          if (status != 'approved') continue;
          final amount = _asDouble(tip['amount']).abs();
          if (amount <= 0.0001) continue;
          tipByOriginalId.update(
            originalId,
            (value) => value + amount,
            ifAbsent: () => amount,
          );
        }
      }

      final normalizedRows = batchDetailRows
          .map((row) {
            final detailId = row['transaction_detail_id']?.toString() ?? '';
            final txn = txnById[detailId];
            return {
              'id': detailId.isNotEmpty
                  ? detailId
                  : (row['id']?.toString() ?? ''),
              'amount': _asDouble(txn?['amount'] ?? row['amount']),
              'fee_amount': _asDouble(txn?['fee_amount'] ?? row['fee_amount']),
              'tip_adjustment_total': tipByOriginalId[detailId] ?? 0.0,
              'status':
                  (txn?['status']?.toString() ??
                          row['status']?.toString() ??
                          '')
                      .trim(),
              'subtype': (txn?['subtype']?.toString() ?? '').trim(),
              'original_detail_id':
                  (txn?['original_detail_id']?.toString() ?? '').trim(),
              'gateway_raw': txn?['gateway_raw'],
            };
          })
          .toList(growable: false);

      final totals = _buildLedgerIntegrityTotals(normalizedRows);

      final nextTransactionCount = normalizedRows.length;
      final nextApprovedCount = _asInt(totals['approvedCount']);
      final nextVoidedCount = _asInt(totals['voidedCount']);
      final nextOriginalTotal = _asDouble(totals['saleAmount']);
      final nextTipTotal = _asDouble(totals['tipAdjustAmount']);
      final nextFinalTotal = _asDouble(totals['netAmount']);
      final nextTotalAmount = nextFinalTotal;

      final currentTransactionCount = _asInt(headerRow['transaction_count']);
      final currentApprovedCount = _asInt(headerRow['approved_count']);
      final currentVoidedCount = _asInt(headerRow['voided_count']);
      final currentOriginalTotal = _asDouble(headerRow['original_total']);
      final currentTipTotal = _asDouble(headerRow['tip_total']);
      final currentFinalTotal = _asDouble(headerRow['final_total']);
      final currentTotalAmount = _asDouble(headerRow['total_amount']);

      bool changed = false;
      changed = changed || currentTransactionCount != nextTransactionCount;
      changed = changed || currentApprovedCount != nextApprovedCount;
      changed = changed || currentVoidedCount != nextVoidedCount;
      changed =
          changed || (currentOriginalTotal - nextOriginalTotal).abs() > 0.009;
      changed = changed || (currentTipTotal - nextTipTotal).abs() > 0.009;
      changed = changed || (currentFinalTotal - nextFinalTotal).abs() > 0.009;
      changed = changed || (currentTotalAmount - nextTotalAmount).abs() > 0.009;

      if (changed && !dryRun) {
        await SupabaseService.client
            .from(_cardBatchHeadersTable)
            .update({
              'transaction_count': nextTransactionCount,
              'approved_count': nextApprovedCount,
              'voided_count': nextVoidedCount,
              'original_total': nextOriginalTotal,
              'tip_total': nextTipTotal,
              'final_total': nextFinalTotal,
              'total_amount': nextTotalAmount,
            })
            .eq('organization_id', scope.organizationId)
            .eq('location_id', scope.locationId)
            .eq('id', trimmed);
      }

      return {
        'ok': true,
        'changed': changed,
        'dryRun': dryRun,
        'totals': {
          'transaction_count': nextTransactionCount,
          'approved_count': nextApprovedCount,
          'voided_count': nextVoidedCount,
          'original_total': nextOriginalTotal,
          'tip_total': nextTipTotal,
          'final_total': nextFinalTotal,
          'total_amount': nextTotalAmount,
        },
      };
    } catch (error) {
      debugPrint('reconcileClosedBatchHeaderTotals failed: $error');
      return {'ok': false, 'error': error.toString(), 'changed': false};
    }
  }

  Future<List<Map<String, dynamic>>> _getBatchCloseReportsFromCardBatchTables({
    required DateTime beginDate,
    required DateTime endDate,
    required int limit,
  }) async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) return const [];

      final start = DateTime(
        beginDate.year,
        beginDate.month,
        beginDate.day,
      ).toUtc();
      final endExclusive = DateTime(
        endDate.year,
        endDate.month,
        endDate.day,
      ).add(const Duration(days: 1)).toUtc();

      final headerRows = await SupabaseService.client
          .from(_cardBatchHeadersTable)
          .select(
            'id,batch_number,accepted,processor_status,processor_message,terminal_name,location_name,organization_name,organization_number,closed_at,transaction_count,approved_count,voided_count,original_total,tip_total,final_total,total_amount,integrity_status,integrity_summary,created_at',
          )
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId)
          .gte('closed_at', start.toIso8601String())
          .lt('closed_at', endExclusive.toIso8601String())
          .order('closed_at', ascending: false)
          .limit(limit);

      final headers = List<Map<String, dynamic>>.from(headerRows);
      if (headers.isEmpty) return const [];

      final headerIds = headers
          .map((row) => row['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList();

      final detailsByHeader = <String, List<Map<String, dynamic>>>{};
      if (headerIds.isNotEmpty) {
        final detailRows = await SupabaseService.client
            .from(_cardBatchDetailsTable)
            .select(
              'card_batch_header_id,transaction_detail_id,transaction_header_id,reference_id,amount,fee_amount,card_type,card_last4,auth_code,status,close_status,integrity_status,integrity_summary,processor_reference_id,processor_transaction_type,created_at',
            )
            .inFilter('card_batch_header_id', headerIds)
            .order('created_at', ascending: true)
            .limit(limit * 200);

        for (final raw in List<Map<String, dynamic>>.from(detailRows)) {
          final key = raw['card_batch_header_id']?.toString() ?? '';
          if (key.isEmpty) continue;
          detailsByHeader.putIfAbsent(key, () => <Map<String, dynamic>>[]);
          detailsByHeader[key]!.add(raw);
        }
      }

      return headers.map((headerRow) {
        final headerId = headerRow['id']?.toString() ?? '';
        final details = detailsByHeader[headerId] ?? const [];

        final report = {
          'version': 2,
          'reportType': 'batch_close',
          'source': 'card_batch_tables',
          'header': {
            'accepted': headerRow['accepted'] == true,
            'processorStatus': headerRow['processor_status']?.toString() ?? '',
            'processorMessage':
                headerRow['processor_message']?.toString() ?? '',
            'terminalName': headerRow['terminal_name']?.toString() ?? '',
            'locationName': headerRow['location_name']?.toString() ?? '',
            'organizationName':
                headerRow['organization_name']?.toString() ?? '',
            'organizationNumber':
                headerRow['organization_number']?.toString() ?? '',
            'closedAt': headerRow['closed_at']?.toString() ?? '',
            'approvedCount': headerRow['approved_count'] ?? 0,
            'voidedCount': headerRow['voided_count'] ?? 0,
            'transactionCount': headerRow['transaction_count'] ?? 0,
            'originalTotal': _asDouble(headerRow['original_total']),
            'tipTotal': _asDouble(headerRow['tip_total']),
            'finalTotal': _asDouble(
              headerRow['final_total'] ?? headerRow['total_amount'],
            ),
            'totalAmount': _asDouble(
              headerRow['final_total'] ?? headerRow['total_amount'],
            ),
            'batchNumber': headerRow['batch_number'],
            'integrityStatus': headerRow['integrity_status']?.toString() ?? '',
            'integritySummary':
                headerRow['integrity_summary']?.toString() ?? '',
          },
          'transactions': details.map((row) {
            return {
              'id': row['transaction_detail_id']?.toString() ?? '',
              'transactionHeaderId':
                  row['transaction_header_id']?.toString() ?? '',
              'amount': _asDouble(row['amount']),
              'feeAmount': _asDouble(row['fee_amount']),
              'cardType': row['card_type']?.toString() ?? '',
              'cardLast4': row['card_last4']?.toString() ?? '',
              'authCode': row['auth_code']?.toString() ?? '',
              'referenceId': row['reference_id']?.toString() ?? '',
              'status': row['status']?.toString() ?? '',
              'createdAt': row['created_at']?.toString() ?? '',
              'transactionDate': row['created_at']?.toString() ?? '',
              'closeStatus': row['close_status']?.toString() ?? '',
              'integrityStatus': row['integrity_status']?.toString() ?? '',
              'integritySummary': row['integrity_summary']?.toString() ?? '',
              'processorReferenceId':
                  row['processor_reference_id']?.toString() ?? '',
              'processorTransactionType':
                  row['processor_transaction_type']?.toString() ?? '',
            };
          }).toList(),
        };

        return {
          'id': headerId,
          'payment_type': 'card',
          'amount': _asDouble(headerRow['total_amount']),
          'success': headerRow['accepted'] == true,
          'created_at':
              headerRow['closed_at']?.toString() ??
              headerRow['created_at']?.toString() ??
              '',
          'report': report,
        };
      }).toList();
    } catch (error) {
      debugPrint('card_batch report fetch failed: $error');
      return const [];
    }
  }

  Map<String, dynamic>? _parseBatchClosePayload(String rawMessage) {
    if (rawMessage.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is! Map<String, dynamic>) return null;
      final reportType = decoded['reportType']?.toString() ?? '';
      if (reportType != 'batch_close') return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getCurrentBatchTransactions({
    int limit = 500,
    bool ascending = false,
  }) async {
    final response = await SupabaseService.client
        .from(SupabaseConfig.transactionsTable)
        .select('*')
        .order('created_at', ascending: ascending)
        .limit(limit);

    return List<Map<String, dynamic>>.from(response);
  }

  /// Returns all approved, open-batch card detail rows for this terminal's
  /// location, ordered newest-first.  Each row includes header-level
  /// created_at so the UI can display a timestamp.
  Future<List<Map<String, dynamic>>> getOpenBatchCardDetails() async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) return [];

      final base = SupabaseService.client
          .from('transaction_details')
          .select(
            'id, transaction_header_id, amount, fee_amount, auth_code, card_last4, card_type, gateway_provider, gateway_token, gateway_raw, reference_id, status, subtype, original_detail_id, batch_status, created_at, transaction_headers!inner(terminal_id,customer_snapshot,invoice_reference,txn_seq)',
          )
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId)
          .eq('payment_type', 'd')
          .eq('batch_status', 'o')
          .inFilter('status', ['approved', 'voided']);

      final response =
          await ((scope.terminalId != null && scope.terminalId!.isNotEmpty)
                  ? base.eq(
                      'transaction_headers.terminal_id',
                      scope.terminalId!,
                    )
                  : base)
              .order('created_at', ascending: false)
              .limit(200);

      final rows = List<Map<String, dynamic>>.from(response);

      for (final row in rows) {
        final gatewayToken = row['gateway_token']?.toString().trim() ?? '';
        if (gatewayToken.isEmpty) {
          final raw = row['gateway_raw'];
          if (raw is Map) {
            final rawMap = Map<String, dynamic>.from(raw);
            final fallbackToken =
                rawMap['TransactionId']?.toString().trim() ??
                rawMap['RefNum']?.toString().trim() ??
                '';
            if (fallbackToken.isNotEmpty) {
              row['gateway_token'] = fallbackToken;
            }
          }
        }

        final cardholderName = _extractCardholderNameFromDetail(row);
        if (cardholderName.isNotEmpty) {
          row['cardholder_name'] = cardholderName;
        }

        final header = row['transaction_headers'];
        if (header is Map) {
          final headerMap = Map<String, dynamic>.from(header);
          final customerName = _extractCustomerNameFromHeader(headerMap);
          if (customerName.isNotEmpty) {
            row['customer_name'] = customerName;
          }

          final invoiceReference =
              headerMap['invoice_reference']?.toString().trim() ?? '';
          if (invoiceReference.isNotEmpty) {
            row['invoice_reference'] = invoiceReference;
          }

          final txnSeq = headerMap['txn_seq'];
          if (txnSeq != null && txnSeq.toString().trim().isNotEmpty) {
            row['txn_seq'] = txnSeq;
          }
        }
      }

      final byId = <String, Map<String, dynamic>>{};
      final voidedOriginalIds = <String>{};
      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        if (id.isNotEmpty) byId[id] = row;

        final subtype = (row['subtype']?.toString().toLowerCase() ?? '').trim();
        if (subtype == 'v') {
          final originalId = row['original_detail_id']?.toString() ?? '';
          if (originalId.isNotEmpty) voidedOriginalIds.add(originalId);
        }
      }

      final visibleRows = <Map<String, dynamic>>[];
      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        final subtype = (row['subtype']?.toString().toLowerCase() ?? '').trim();

        // Once a sale is voided, hide the original sale row and keep only
        // the explicit void row so users see one canonical entry.
        if (subtype == 's' && id.isNotEmpty && voidedOriginalIds.contains(id)) {
          continue;
        }

        if (subtype == 'v') {
          final originalId = row['original_detail_id']?.toString() ?? '';
          final original = byId[originalId];
          if (original != null) {
            row['voided_reference_id'] =
                original['reference_id']?.toString() ?? '';
            row['voided_card_type'] = original['card_type']?.toString() ?? '';
            row['voided_card_last4'] = original['card_last4']?.toString() ?? '';
            row['voided_auth_code'] = original['auth_code']?.toString() ?? '';
            row['voided_cardholder_name'] =
                original['cardholder_name']?.toString() ?? '';

            final customerName =
                original['customer_name']?.toString().trim() ?? '';
            if (customerName.isNotEmpty) {
              row['customer_name'] = customerName;
            }
          }
        }

        visibleRows.add(row);
      }

      return visibleRows;
    } catch (e) {
      debugPrint('getOpenBatchCardDetails failed: $e');
      return [];
    }
  }

  String _extractCustomerNameFromHeader(Map<String, dynamic> header) {
    final snapshot = header['customer_snapshot'];
    if (snapshot is! Map) return '';

    final snap = Map<String, dynamic>.from(snapshot);
    final candidateKeys = [
      'name',
      'full_name',
      'customer_name',
      'display_name',
    ];
    for (final key in candidateKeys) {
      final value = snap[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }

    final first =
        snap['first_name']?.toString().trim() ??
        snap['firstName']?.toString().trim() ??
        '';
    final last =
        snap['last_name']?.toString().trim() ??
        snap['lastName']?.toString().trim() ??
        '';
    final combined = '$first $last'.trim();
    if (combined.isNotEmpty) return combined;

    final customerNumber = snap['customer_number']?.toString().trim() ?? '';
    if (customerNumber.isNotEmpty) return 'Customer #$customerNumber';

    return '';
  }

  String _extractCardholderNameFromDetail(Map<String, dynamic> row) {
    final direct = row['cardholder_name']?.toString().trim() ?? '';
    if (direct.isNotEmpty) return direct;

    final raw = row['gateway_raw'];
    if (raw is! Map) return '';

    final rawMap = Map<String, dynamic>.from(raw);
    final cardData = rawMap['CardData'];
    if (cardData is Map) {
      final cardMap = Map<String, dynamic>.from(cardData);
      for (final key in [
        'CardHolderName',
        'CardholderName',
        'NameOnCard',
        'Name',
      ]) {
        final value = cardMap[key]?.toString().trim() ?? '';
        if (value.isNotEmpty) return value;
      }
    }

    for (final key in ['CardHolderName', 'CardholderName', 'NameOnCard']) {
      final value = rawMap[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }

    return '';
  }

  /// Returns settled, approved card sale rows for this terminal that do not
  /// already have their full approved amount refunded.
  Future<List<Map<String, dynamic>>> getRefundableClosedCardDetails() async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) return [];

      final base = SupabaseService.client
          .from('transaction_details')
          .select(
            'id, transaction_header_id, amount, fee_amount, receipt_id, auth_code, card_last4, card_type, gateway_token, reference_id, status, batch_status, created_at, transaction_headers!inner(terminal_id,customer_snapshot,invoice_reference)',
          )
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId)
          .eq('payment_type', 'd')
          .eq('subtype', 's')
          .eq('status', 'approved')
          .eq('batch_status', 'c');

      final closedSales = List<Map<String, dynamic>>.from(
        await ((scope.terminalId != null && scope.terminalId!.isNotEmpty)
                ? base.eq('transaction_headers.terminal_id', scope.terminalId!)
                : base)
            .order('created_at', ascending: false)
            .limit(200),
      );

      if (closedSales.isEmpty) return const [];

      final saleIds = closedSales
          .map((row) => row['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList();
      if (saleIds.isEmpty) return const [];

      String operationOf(Map<String, dynamic> row) {
        final raw = row['gateway_raw'];
        if (raw is Map) {
          final rawMap = Map<String, dynamic>.from(raw);
          return (rawMap['operation']?.toString().toLowerCase() ?? '').trim();
        }
        if (raw is String && raw.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map) {
              final rawMap = Map<String, dynamic>.from(decoded);
              return (rawMap['operation']?.toString().toLowerCase() ?? '')
                  .trim();
            }
          } catch (_) {}
        }
        return '';
      }

      bool isTipAdjustmentRow(Map<String, dynamic> row) {
        final op = operationOf(row);
        return op.isEmpty || op == 'tip_adjust' || op == 'tip_adjust_probe';
      }

      final tipAdjustRows = List<Map<String, dynamic>>.from(
        await SupabaseService.client
            .from('transaction_details')
            .select(
              'original_detail_id, amount, status, subtype, gateway_raw, created_at',
            )
            .eq('organization_id', scope.organizationId)
            .eq('location_id', scope.locationId)
            .eq('payment_type', 'd')
            .eq('subtype', 'a')
            .eq('status', 'approved')
            .inFilter('original_detail_id', saleIds),
      );

      final tipAdjustTotalsByOriginalId = <String, double>{};
      final tipAdjustAtByOriginalId = <String, DateTime>{};
      for (final row in tipAdjustRows) {
        if (!isTipAdjustmentRow(row)) continue;
        final originalId = row['original_detail_id']?.toString().trim() ?? '';
        if (originalId.isEmpty) continue;

        final tipAmount = (row['amount'] as num?)?.toDouble().abs() ?? 0;
        final createdAt = DateTime.tryParse(
          row['created_at']?.toString() ?? '',
        );
        final existingAt = tipAdjustAtByOriginalId[originalId];
        if (existingAt == null ||
            (createdAt != null && createdAt.isAfter(existingAt))) {
          tipAdjustTotalsByOriginalId[originalId] = tipAmount;
          if (createdAt != null) {
            tipAdjustAtByOriginalId[originalId] = createdAt;
          }
        }
      }

      final refundRows = List<Map<String, dynamic>>.from(
        await SupabaseService.client
            .from('transaction_details')
            .select('original_detail_id, amount, status')
            .eq('organization_id', scope.organizationId)
            .eq('location_id', scope.locationId)
            .eq('payment_type', 'd')
            .eq('subtype', 'r')
            .eq('status', 'approved')
            .inFilter('original_detail_id', saleIds),
      );

      final refundedTotalsByOriginalId = <String, double>{};
      for (final row in refundRows) {
        final originalId = row['original_detail_id']?.toString() ?? '';
        if (originalId.isEmpty) continue;
        final amount = (row['amount'] as num?)?.toDouble().abs() ?? 0;
        refundedTotalsByOriginalId.update(
          originalId,
          (existing) => existing + amount,
          ifAbsent: () => amount,
        );
      }

      final rows = closedSales.where((row) {
        final saleId = row['id']?.toString() ?? '';
        final saleAmount = (row['amount'] as num?)?.toDouble().abs() ?? 0;
        final surchargeAmount =
            (row['fee_amount'] as num?)?.toDouble().abs() ?? 0;
        final tipAdjustmentTotal = tipAdjustTotalsByOriginalId[saleId] ?? 0;
        final grossAmount = saleAmount + surchargeAmount + tipAdjustmentTotal;
        final refundedAmount = refundedTotalsByOriginalId[saleId] ?? 0;
        final remainingAmount = grossAmount - refundedAmount;
        if (remainingAmount <= 0.009) {
          return false;
        }

        row['original_amount'] = saleAmount;
        row['surcharge_amount'] = surchargeAmount;
        row['tip_adjustment_total'] = tipAdjustmentTotal;
        row['display_amount'] = grossAmount;
        row['refunded_amount'] = refundedAmount;
        row['refundable_amount'] = remainingAmount;
        return true;
      }).toList();

      for (final row in rows) {
        final header = row['transaction_headers'];
        if (header is! Map) continue;
        final headerMap = Map<String, dynamic>.from(header);

        final customerName = _extractCustomerNameFromHeader(headerMap);
        if (customerName.isNotEmpty) {
          row['customer_name'] = customerName;
        }

        final invoiceReference =
            headerMap['invoice_reference']?.toString().trim() ?? '';
        if (invoiceReference.isNotEmpty) {
          row['invoice_reference'] = invoiceReference;
        }
      }

      return rows;
    } catch (e) {
      debugPrint('getRefundableClosedCardDetails failed: $e');
      return [];
    }
  }

  Future<int> _countOpenBatchByIds(List<String> detailIds) async {
    if (detailIds.isEmpty) return 0;
    final scope = await _resolveTenantScope();
    if (scope == null) return detailIds.length;

    final response = await SupabaseService.client
        .from('transaction_details')
        .select('id')
        .eq('organization_id', scope.organizationId)
        .eq('location_id', scope.locationId)
        .eq('payment_type', 'd')
        .eq('batch_status', 'o')
        .inFilter('id', detailIds)
        .limit(detailIds.length);

    return List<Map<String, dynamic>>.from(response).length;
  }

  Future<bool> _markBatchClosedViaBackend(List<String> detailIds) async {
    if (detailIds.isEmpty) return true;
    final url = Uri.parse('$_backendBase/api/batch/mark-closed');
    final response = await http
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({'detailIds': detailIds}),
        )
        .timeout(const Duration(seconds: 20));
    return response.statusCode == 200;
  }

  Future<void> emailReceiptPdf({
    required String recipientEmail,
    required List<int> pdfBytes,
    required String filename,
    String? subject,
    String? textBody,
    String? replyTo,
  }) async {
    final trimmedRecipient = recipientEmail.trim();
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    if (trimmedRecipient.isEmpty) {
      throw Exception('Recipient email is required.');
    }
    if (!emailRegex.hasMatch(trimmedRecipient)) {
      throw Exception('Recipient email format is invalid.');
    }
    final trimmedReplyTo = (replyTo ?? '').trim();
    if (trimmedReplyTo.isNotEmpty && !emailRegex.hasMatch(trimmedReplyTo)) {
      throw Exception('Reply-to email format is invalid.');
    }
    if (pdfBytes.isEmpty) {
      throw Exception('Receipt PDF is empty and cannot be emailed.');
    }

    final url = Uri.parse('$_backendBase/api/receipts/email');
    final response = await http
        .post(
          url,
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            'recipientEmail': trimmedRecipient,
            'pdfBase64': base64Encode(pdfBytes),
            'filename': filename,
            if ((subject ?? '').trim().isNotEmpty) 'subject': subject!.trim(),
            if ((textBody ?? '').trim().isNotEmpty)
              'textBody': textBody!.trim(),
            if (trimmedReplyTo.isNotEmpty) 'replyTo': trimmedReplyTo,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      return;
    }

    String message = 'Receipt email failed with HTTP ${response.statusCode}.';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final err = (decoded['error'] ?? '').toString().trim();
        if (err.isNotEmpty) {
          message = err;
        }
      }
    } catch (_) {
      // Keep HTTP fallback message when response body is not JSON.
    }
    throw Exception(message);
  }

  /// Mark a list of detail row IDs as batch_status = 'c' (settled).
  /// Returns true when the rows are confirmed closed after local or backend
  /// fallback update.
  Future<bool> markBatchClosed(List<String> detailIds) async {
    if (detailIds.isEmpty) return true;
    try {
      await SupabaseService.client
          .from('transaction_details')
          .update({'batch_status': 'c'})
          .inFilter('id', detailIds);

      var stillOpen = await _countOpenBatchByIds(detailIds);
      if (stillOpen == 0) return true;

      final backendOk = await _markBatchClosedViaBackend(detailIds);
      if (!backendOk) return false;

      stillOpen = await _countOpenBatchByIds(detailIds);
      return stillOpen == 0;
    } catch (e) {
      debugPrint('markBatchClosed failed: $e');

      try {
        final backendOk = await _markBatchClosedViaBackend(detailIds);
        if (!backendOk) return false;
        final stillOpen = await _countOpenBatchByIds(detailIds);
        return stillOpen == 0;
      } catch (inner) {
        debugPrint('markBatchClosed backend fallback failed: $inner');
        return false;
      }
    }
  }

  /// Insert a void detail row and mark the original as voided.
  Future<void> recordVoid({
    required String transactionHeaderId,
    required String originalDetailId,
    required double amount,
    String referenceId = '',
    String authCode = '',
    String cardLast4 = '',
    String cardType = '',
  }) async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) return;

      // Insert void detail row (negative amount so trigger reduces amount_paid)
      await SupabaseService.client.from('transaction_details').insert({
        'transaction_header_id': transactionHeaderId,
        'organization_id': scope.organizationId,
        'location_id': scope.locationId,
        'payment_type': 'd',
        'subtype': 'v',
        'amount': -amount,
        'status': 'voided',
        'original_detail_id': originalDetailId,
        'reference_id': referenceId,
        'auth_code': authCode,
        'card_last4': cardLast4,
        'card_type': cardType,
        'gateway_provider': 'dejavoo',
        'batch_status': 'o',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });

      // Mark original as voided
      await SupabaseService.client
          .from('transaction_details')
          .update({'status': 'voided'})
          .eq('id', originalDetailId);
    } catch (e) {
      debugPrint('recordVoid failed: $e');
    }
  }

  Future<String?> recordRefund({
    required String transactionHeaderId,
    String? originalDetailId,
    required double amount,
    String referenceId = '',
    String authCode = '',
    String cardLast4 = '',
    String cardType = '',
    Map<String, dynamic>? gatewayRaw,
  }) async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) return null;

      final response = await SupabaseService.client
          .from('transaction_details')
          .insert({
            'transaction_header_id': transactionHeaderId,
            'organization_id': scope.organizationId,
            'location_id': scope.locationId,
            'payment_type': 'd',
            'subtype': 'r',
            'amount': -amount,
            'status': 'approved',
            'reference_id': referenceId,
            'auth_code': authCode,
            'card_last4': cardLast4,
            'card_type': cardType,
            'original_detail_id': originalDetailId,
            'gateway_provider': 'dejavoo',
            'batch_status': 'o',
            'created_at': DateTime.now().toUtc().toIso8601String(),
            if (gatewayRaw != null && gatewayRaw.isNotEmpty)
              'gateway_raw': gatewayRaw,
          })
          .select('id')
          .single();
      return response['id']?.toString();
    } catch (e) {
      debugPrint('recordRefund failed: $e');
      return null;
    }
  }

  Future<RefundVerificationResult> verifyRefundPersistence({
    required String refundDetailId,
    required String originalDetailId,
    required String transactionHeaderId,
  }) async {
    try {
      final scope = await _resolveTenantScope();
      if (scope == null) {
        return const RefundVerificationResult(
          fetchError:
              'Tenant scope could not be resolved for refund verification.',
        );
      }

      final refundRowResponse = await SupabaseService.client
          .from('transaction_details')
          .select(
            'id, transaction_header_id, original_detail_id, subtype, amount, status, batch_status, created_at',
          )
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId)
          .eq('id', refundDetailId)
          .limit(1);

      final originalRowResponse = await SupabaseService.client
          .from('transaction_details')
          .select(
            'id, transaction_header_id, amount, subtype, status, batch_status',
          )
          .eq('organization_id', scope.organizationId)
          .eq('location_id', scope.locationId)
          .eq('id', originalDetailId)
          .limit(1);

      final headerResponse = await SupabaseService.client
          .from('transaction_headers')
          .select(
            'id, total, amount_paid, amount_due, status, closed_at, voided_at',
          )
          .eq('id', transactionHeaderId)
          .limit(1);

      final approvedDetails = List<Map<String, dynamic>>.from(
        await SupabaseService.client
            .from('transaction_details')
            .select('id, amount, subtype, status')
            .eq('organization_id', scope.organizationId)
            .eq('location_id', scope.locationId)
            .eq('transaction_header_id', transactionHeaderId)
            .eq('status', 'approved'),
      );

      final refundRow = refundRowResponse.isNotEmpty
          ? Map<String, dynamic>.from(refundRowResponse.first as Map)
          : null;
      final originalRow = originalRowResponse.isNotEmpty
          ? Map<String, dynamic>.from(originalRowResponse.first as Map)
          : null;
      final headerRow = headerResponse.isNotEmpty
          ? Map<String, dynamic>.from(headerResponse.first as Map)
          : null;

      final approvedSum = approvedDetails.fold<double>(
        0,
        (sum, row) => sum + _asDouble(row['amount']),
      );
      final headerTotal = _asDouble(headerRow?['total']);
      final headerPaid = _asDouble(headerRow?['amount_paid']);
      final headerDue = _asDouble(headerRow?['amount_due']);
      final expectedDue = (headerTotal - approvedSum) > 0
          ? (headerTotal - approvedSum)
          : 0;
      final hasApprovedVoid = approvedDetails.any(
        (row) => row['subtype']?.toString() == 'v',
      );
      final expectedStatus = hasApprovedVoid
          ? 'voided'
          : expectedDue <= 0.001
          ? 'closed'
          : 'open';

      final checks = <RefundVerificationCheck>[
        RefundVerificationCheck(
          label: 'Refund row exists',
          passed: refundRow != null,
          detail: refundRow != null
              ? 'refund_detail_id=${refundRow['id']}'
              : 'No transaction_details row found for refund_detail_id=$refundDetailId',
        ),
        RefundVerificationCheck(
          label: 'subtype = r',
          passed: refundRow?['subtype']?.toString() == 'r',
          detail: 'actual=${refundRow?['subtype'] ?? '(missing)'}',
        ),
        RefundVerificationCheck(
          label: 'Refund amount is negative',
          passed: _asDouble(refundRow?['amount']) < 0,
          detail:
              'actual=${_asDouble(refundRow?['amount']).toStringAsFixed(2)}',
        ),
        RefundVerificationCheck(
          label: 'batch_status = o',
          passed: refundRow?['batch_status']?.toString() == 'o',
          detail: 'actual=${refundRow?['batch_status'] ?? '(missing)'}',
        ),
        RefundVerificationCheck(
          label: 'original_detail_id matches sale',
          passed:
              refundRow?['original_detail_id']?.toString() == originalDetailId,
          detail:
              'actual=${refundRow?['original_detail_id'] ?? '(missing)'} expected=$originalDetailId',
        ),
        RefundVerificationCheck(
          label: 'Original sale row exists',
          passed: originalRow != null,
          detail: originalRow != null
              ? 'original_amount=${_asDouble(originalRow['amount']).toStringAsFixed(2)} status=${originalRow['status']}'
              : 'No original sale row found for id=$originalDetailId',
        ),
        RefundVerificationCheck(
          label: 'Header amount_paid matches approved detail sum',
          passed: (headerPaid - approvedSum).abs() <= 0.01,
          detail:
              'header=${headerPaid.toStringAsFixed(2)} computed=${approvedSum.toStringAsFixed(2)}',
        ),
        RefundVerificationCheck(
          label: 'Header amount_due recalculated correctly',
          passed: (headerDue - expectedDue).abs() <= 0.01,
          detail:
              'header=${headerDue.toStringAsFixed(2)} expected=${expectedDue.toStringAsFixed(2)}',
        ),
        RefundVerificationCheck(
          label: 'Header status matches recalculated totals',
          passed: headerRow?['status']?.toString() == expectedStatus,
          detail:
              'actual=${headerRow?['status'] ?? '(missing)'} expected=$expectedStatus',
        ),
      ];

      return RefundVerificationResult(
        refundRow: refundRow,
        originalRow: originalRow,
        headerRow: headerRow,
        checks: checks,
      );
    } catch (e) {
      return RefundVerificationResult(fetchError: e.toString());
    }
  }
}
