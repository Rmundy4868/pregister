import 'package:shared_preferences/shared_preferences.dart';

import 'integrity_check_store.dart';
import 'license_service.dart';
import 'settings_data_service.dart';
import 'supabase_service.dart';

enum CustomerFieldMode { required, optional, hidden }

extension CustomerFieldModeX on CustomerFieldMode {
  String get storageValue {
    switch (this) {
      case CustomerFieldMode.required:
        return 'required';
      case CustomerFieldMode.optional:
        return 'optional';
      case CustomerFieldMode.hidden:
        return 'hide';
    }
  }

  static CustomerFieldMode fromStorage(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'required':
        return CustomerFieldMode.required;
      case 'hide':
      case 'hidden':
        return CustomerFieldMode.hidden;
      default:
        return CustomerFieldMode.optional;
    }
  }
}

class TransactionFlowParameters {
  static const String staffTrackingKey = 'operating.transaction.staff_tracking';
  static const String customerTrackingKey =
      'operating.transaction.customer_tracking';
  static const String integrityChecksEnabledKey =
      IntegrityCheckStore.enabledKey;
    static const String enableProcessorSurchargeKey =
      'operating.transaction.enable_processor_surcharge';
  static const String fieldModePrefix =
      'operating.transaction.customer_field_mode.';
  static const String receiptPreviewPrefix = 'operating.receipts.';
  static const String receiptCopyCountPrefix = 'operating.receipts.';
  static const String receiptReplyToEmailKey =
      'operating.receipts.reply_to_email';

  static const List<String> receiptTypes = <String>['sale', 'void', 'return'];

  static const List<String> customerFieldKeys = <String>[
    'invoice_reference',
    'customer_id',
    'first_name',
    'last_name',
    'address1',
    'address2',
    'city',
    'state',
    'zip',
    'email',
  ];

  static Map<String, CustomerFieldMode> defaultCustomerFieldModes() {
    return <String, CustomerFieldMode>{
      for (final key in customerFieldKeys) key: CustomerFieldMode.optional,
    };
  }

  const TransactionFlowParameters({
    required this.staffTrackingEnabled,
    required this.customerTrackingEnabled,
    required this.integrityChecksEnabled,
    required this.enableProcessorSurcharge,
    required this.customerFieldModes,
    required this.receiptPreviewEnabled,
    required this.receiptCopyCount,
    required this.receiptReplyToEmail,
  });

  final bool staffTrackingEnabled;
  final bool customerTrackingEnabled;
  final bool integrityChecksEnabled;
  final bool enableProcessorSurcharge;
  final Map<String, CustomerFieldMode> customerFieldModes;
  final Map<String, bool> receiptPreviewEnabled;
  final Map<String, int> receiptCopyCount;
  final String receiptReplyToEmail;

  CustomerFieldMode modeFor(String fieldKey) {
    return customerFieldModes[fieldKey] ?? CustomerFieldMode.optional;
  }

  bool receiptPreviewFor(String receiptType) {
    return receiptPreviewEnabled[receiptType] ?? true;
  }

  int receiptCopyCountFor(String receiptType) {
    return (receiptCopyCount[receiptType] ?? 2).clamp(0, 10);
  }

  static Future<TransactionFlowParameters> load() async {
    final prefs = await SharedPreferences.getInstance();
    final modes = defaultCustomerFieldModes();
    final receiptPreview = <String, bool>{
      for (final type in receiptTypes)
        type:
            prefs.getBool('$receiptPreviewPrefix$type.preview_enabled') ?? true,
    };
    final receiptCopyCount = <String, int>{
      for (final type in receiptTypes)
        type: (prefs.getInt('$receiptCopyCountPrefix$type.copy_count') ?? 2)
            .clamp(0, 10),
    };
    final receiptReplyToEmail =
        prefs.getString(receiptReplyToEmailKey)?.trim() ?? '';

    Future<String> resolveLocationReplyToFallback(String locationId) async {
      final normalizedLocationId = locationId.trim();
      if (normalizedLocationId.isEmpty) return '';

      try {
        final locationDetails = await SettingsDataService()
            .getLocationDetailsById(normalizedLocationId);
        return locationDetails['receipt_reply_to_email']?.trim() ?? '';
      } catch (_) {
        return '';
      }
    }

    final activeContext = LicenseService().activeContext;
    final terminalId = activeContext?.terminalId.trim() ?? '';
    final licenseKey = activeContext?.licenseKey.trim() ?? '';

    if (terminalId.isNotEmpty && licenseKey.isNotEmpty) {
      try {
        final response = await SupabaseService.client.rpc(
          'get_terminal_transaction_parameters_from_app',
          params: {'p_license_key': licenseKey, 'p_terminal_id': terminalId},
        );

        if (response is Map) {
          final row = Map<String, dynamic>.from(response);
          final remoteModes = Map<String, CustomerFieldMode>.from(modes);
          final rawModes = row['customer_field_modes'];
          if (rawModes is Map) {
            for (final entry in rawModes.entries) {
              final key = entry.key.toString();
              if (!customerFieldKeys.contains(key)) continue;
              remoteModes[key] = CustomerFieldModeX.fromStorage(
                entry.value?.toString() ?? 'optional',
              );
            }
          }

          final resolvedReceiptReplyToEmail =
              row['receipt_reply_to_email']?.toString().trim().isNotEmpty ==
                  true
              ? row['receipt_reply_to_email'].toString().trim()
              : await resolveLocationReplyToFallback(
                  activeContext?.locationId ?? '',
                );

          final remote = TransactionFlowParameters(
            staffTrackingEnabled: row['staff_tracking_enabled'] == true,
            customerTrackingEnabled: row['customer_tracking_enabled'] == true,
            integrityChecksEnabled:
                prefs.getBool(integrityChecksEnabledKey) ?? false,
            enableProcessorSurcharge:
              row['enable_processor_surcharge'] == true,
            customerFieldModes: remoteModes,
            receiptPreviewEnabled: {
              for (final type in receiptTypes)
                type: row['${type}_receipt_preview_enabled'] == null
                    ? (receiptPreview[type] ?? true)
                    : row['${type}_receipt_preview_enabled'] == true,
            },
            receiptCopyCount: {
              for (final type in receiptTypes)
                type:
                    ((row['${type}_receipt_copy_count'] as num?)?.toInt() ??
                            (receiptCopyCount[type] ?? 2))
                        .clamp(0, 10),
            },
            receiptReplyToEmail: resolvedReceiptReplyToEmail.isNotEmpty
                ? resolvedReceiptReplyToEmail
                : receiptReplyToEmail,
          );

          await prefs.setBool(staffTrackingKey, remote.staffTrackingEnabled);
          await prefs.setBool(
            customerTrackingKey,
            remote.customerTrackingEnabled,
          );
          await prefs.setBool(
            enableProcessorSurchargeKey,
            remote.enableProcessorSurcharge,
          );
          for (final type in receiptTypes) {
            await prefs.setBool(
              '$receiptPreviewPrefix$type.preview_enabled',
              remote.receiptPreviewFor(type),
            );
            await prefs.setInt(
              '$receiptCopyCountPrefix$type.copy_count',
              remote.receiptCopyCountFor(type),
            );
          }
          await prefs.setString(
            receiptReplyToEmailKey,
            remote.receiptReplyToEmail,
          );
          for (final key in customerFieldKeys) {
            final mode =
                remote.customerFieldModes[key] ?? CustomerFieldMode.optional;
            await prefs.setString('$fieldModePrefix$key', mode.storageValue);
          }

          return remote;
        }
      } catch (_) {
        // Fall back to local cache when centralized lookup is unavailable.
      }
    }

    for (final key in customerFieldKeys) {
      final stored = prefs.getString('$fieldModePrefix$key') ?? 'optional';
      modes[key] = CustomerFieldModeX.fromStorage(stored);
    }

    final fallbackReceiptReplyToEmail = receiptReplyToEmail.isNotEmpty
        ? receiptReplyToEmail
        : await resolveLocationReplyToFallback(activeContext?.locationId ?? '');

    return TransactionFlowParameters(
      staffTrackingEnabled: prefs.getBool(staffTrackingKey) ?? false,
      customerTrackingEnabled: prefs.getBool(customerTrackingKey) ?? false,
      integrityChecksEnabled: prefs.getBool(integrityChecksEnabledKey) ?? false,
      enableProcessorSurcharge:
          prefs.getBool(enableProcessorSurchargeKey) ?? false,
      customerFieldModes: modes,
      receiptPreviewEnabled: receiptPreview,
      receiptCopyCount: receiptCopyCount,
      receiptReplyToEmail: fallbackReceiptReplyToEmail,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(staffTrackingKey, staffTrackingEnabled);
    await prefs.setBool(customerTrackingKey, customerTrackingEnabled);
    await prefs.setBool(integrityChecksEnabledKey, integrityChecksEnabled);
    await prefs.setBool(
      enableProcessorSurchargeKey,
      enableProcessorSurcharge,
    );
    for (final type in receiptTypes) {
      await prefs.setBool(
        '$receiptPreviewPrefix$type.preview_enabled',
        receiptPreviewFor(type),
      );
      await prefs.setInt(
        '$receiptCopyCountPrefix$type.copy_count',
        receiptCopyCountFor(type),
      );
    }
    await prefs.setString(receiptReplyToEmailKey, receiptReplyToEmail.trim());

    for (final key in customerFieldKeys) {
      final mode = customerFieldModes[key] ?? CustomerFieldMode.optional;
      await prefs.setString('$fieldModePrefix$key', mode.storageValue);
    }

    final activeContext = LicenseService().activeContext;
    final terminalId = activeContext?.terminalId.trim() ?? '';
    final licenseKey = activeContext?.licenseKey.trim() ?? '';
    if (terminalId.isEmpty || licenseKey.isEmpty) {
      return;
    }

    try {
      final commonParams = {
        'p_license_key': licenseKey,
        'p_terminal_id': terminalId,
        'p_staff_tracking_enabled': staffTrackingEnabled,
        'p_customer_tracking_enabled': customerTrackingEnabled,
        'p_sale_receipt_preview_enabled': receiptPreviewFor('sale'),
        'p_sale_receipt_copy_count': receiptCopyCountFor('sale'),
        'p_void_receipt_preview_enabled': receiptPreviewFor('void'),
        'p_void_receipt_copy_count': receiptCopyCountFor('void'),
        'p_return_receipt_preview_enabled': receiptPreviewFor('return'),
        'p_return_receipt_copy_count': receiptCopyCountFor('return'),
        'p_enable_processor_surcharge': enableProcessorSurcharge,
        'p_customer_field_modes': {
          for (final key in customerFieldKeys)
            key: (customerFieldModes[key] ?? CustomerFieldMode.optional)
                .storageValue,
        },
      };

      try {
        await SupabaseService.client.rpc(
          'set_terminal_transaction_parameters_from_app',
          params: {
            ...commonParams,
            'p_receipt_reply_to_email': receiptReplyToEmail.trim(),
          },
        );
      } catch (_) {
        try {
          // Backward compatibility for older RPC signatures not yet migrated.
          final fallbackParams = Map<String, dynamic>.from(commonParams)
            ..remove('p_enable_processor_surcharge');
          await SupabaseService.client.rpc(
            'set_terminal_transaction_parameters_from_app',
            params: fallbackParams,
          );
        } catch (_) {
          // Oldest fallback without receipt reply-to support.
          final legacyParams = Map<String, dynamic>.from(commonParams)
            ..remove('p_enable_processor_surcharge')
            ..remove('p_receipt_reply_to_email');
          await SupabaseService.client.rpc(
            'set_terminal_transaction_parameters_from_app',
            params: legacyParams,
          );
        }
      }
    } catch (_) {
      // Keep local settings as source-of-truth fallback when RPC is unavailable.
    }
  }
}
