import 'dart:convert';
import 'package:http/http.dart' as http;

class PaaayitRequestResult {
  final bool success;
  final String message;
  final String requestId;
  final String requestNumber;
  final String hppTransactionReferenceId;
  final String paymentUrl;
  final DateTime? expiresAt;
  final String status;

  const PaaayitRequestResult({
    required this.success,
    required this.message,
    this.requestId = '',
    this.requestNumber = '',
    this.hppTransactionReferenceId = '',
    this.paymentUrl = '',
    this.expiresAt,
    this.status = '',
  });
}

class PaaayitRequestActivityItem {
  final String id;
  final String hppTransactionReferenceId;
  final String requestNumber;
  final String requestTitle;
  final bool isManualOverride;
  final String status;
  final double amount;
  final String currency;
  final String customerName;
  final String customerEmail;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final DateTime? sentAt;
  final String paymentUrl;
  final String cancelReason;
  final DateTime? cancelledAt;

  const PaaayitRequestActivityItem({
    required this.id,
    required this.hppTransactionReferenceId,
    required this.requestNumber,
    required this.requestTitle,
    required this.isManualOverride,
    required this.status,
    required this.amount,
    required this.currency,
    required this.customerName,
    required this.customerEmail,
    this.createdAt,
    this.expiresAt,
    this.sentAt,
    required this.paymentUrl,
    this.cancelReason = '',
    this.cancelledAt,
  });
}

class PaaayitRequestService {
  String get _backendBase {
    const raw = String.fromEnvironment(
      'PAYMENT_API_BASE_URL',
      defaultValue: 'http://127.0.0.1:3000',
    );
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  String _composeTempSyncErrorMessage({
    required int statusCode,
    required String responseBody,
  }) {
    String message = 'Temp sync failed (HTTP $statusCode).';

    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, dynamic>) {
        return message;
      }

      final errorText = decoded['error']?.toString().trim() ?? '';
      final verification = decoded['verification'];

      final details = <String>[];
      if (verification is Map) {
        final verificationMap = Map<String, dynamic>.from(verification);
        final reason = verificationMap['reason']?.toString().trim() ?? '';
        final endpoint = verificationMap['endpoint']?.toString().trim() ?? '';
        final upstreamStatus =
            verificationMap['status']?.toString().trim() ?? '';

        if (reason.isNotEmpty) {
          details.add('reason=$reason');
        }
        if (endpoint.isNotEmpty) {
          details.add('endpoint=$endpoint');
        }
        if (upstreamStatus.isNotEmpty) {
          details.add('upstreamStatus=$upstreamStatus');
        }
      }

      if (errorText.isNotEmpty && details.isNotEmpty) {
        return '$errorText | ${details.join(' | ')}';
      }
      if (errorText.isNotEmpty) {
        return errorText;
      }
      if (details.isNotEmpty) {
        return details.join(' | ');
      }
    } catch (_) {
      // Keep generic message when response body is not valid JSON.
    }

    return message;
  }

  Future<PaaayitRequestResult> createRequest({
    required String organizationId,
    required String locationId,
    required String terminalId,
    required String merchantId,
    String? transactionReferenceId,
    required String customerEmail,
    required String customerName,
    required double amount,
    required String hppAuthToken,
    bool calculateFee = false,
    bool? sendPaymentLink,
    bool? requestCardToken,
    String? requestTitle,
    String? customerMobile,
    String? paymentReference,
    String? pdfAttachmentFileName,
    String? pdfAttachmentBase64,
  }) async {
    final url = Uri.parse('$_backendBase/api/paaayit-requests/create');

    try {
      final response = await http.post(
        url,
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'organizationId': organizationId,
          'locationId': locationId,
          'terminalId': terminalId,
          'merchantId': merchantId,
          if (transactionReferenceId != null &&
              transactionReferenceId.trim().isNotEmpty)
            'transactionReferenceId': transactionReferenceId.trim(),
          'customerEmail': customerEmail,
          'customerName': customerName,
          if (customerMobile != null && customerMobile.trim().isNotEmpty)
            'customerMobile': customerMobile.trim(),
          if (requestTitle != null && requestTitle.trim().isNotEmpty)
            'requestTitle': requestTitle.trim(),
          'amount': amount,
          'calculateFee': calculateFee,
          if (sendPaymentLink != null) 'sendPaymentLink': sendPaymentLink,
          if (requestCardToken != null) 'requestCardToken': requestCardToken,
          'hppAuthToken': hppAuthToken,
          if (paymentReference != null && paymentReference.trim().isNotEmpty)
            'paymentReference': paymentReference.trim(),
          if (paymentReference != null && paymentReference.trim().isNotEmpty)
            'txReferenceTag1': paymentReference.trim(),
          if (pdfAttachmentFileName != null &&
              pdfAttachmentFileName.trim().isNotEmpty)
            'attachmentPdfFileName': pdfAttachmentFileName.trim(),
          if (pdfAttachmentBase64 != null &&
              pdfAttachmentBase64.trim().isNotEmpty)
            'attachmentPdfBase64': pdfAttachmentBase64.trim(),
          if (pdfAttachmentBase64 != null &&
              pdfAttachmentBase64.trim().isNotEmpty)
            'attachmentPdfMimeType': 'application/pdf',
        }),
      );

      if (response.statusCode != 200) {
        String message = 'HTTP ${response.statusCode}';
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) {
            final baseError = decoded['error']?.toString().trim();
            final upstreamStatus = decoded['upstreamStatus']?.toString().trim();
            final upstreamCode = decoded['upstreamCode']?.toString().trim();
            final details = decoded['details']?.toString().trim();
            final upstreamData = decoded['upstreamData'];
            final merchantIdCandidates = decoded['merchantIdCandidates'];
            final tokenMerchantId = decoded['tokenMerchantId']
                ?.toString()
                .trim();
            final tokenTpn = decoded['tokenTpn']?.toString().trim();
            String? upstreamMessage;
            if (upstreamData is Map<String, dynamic>) {
              final errors = upstreamData['errors'];
              if (errors is List && errors.isNotEmpty && errors.first is Map) {
                final first = Map<String, dynamic>.from(errors.first as Map);
                final field = first['field']?.toString().trim() ?? '';
                final msg = first['message']?.toString().trim() ?? '';
                if (msg.isNotEmpty) {
                  upstreamMessage = field.isNotEmpty ? '$field: $msg' : msg;
                }
              }

              upstreamMessage =
                  upstreamMessage ??
                  (upstreamData['message']?.toString().trim().isNotEmpty == true
                      ? upstreamData['message'].toString().trim()
                      : (upstreamData['error']?.toString().trim().isNotEmpty ==
                                true
                            ? upstreamData['error'].toString().trim()
                            : null));
            } else if (upstreamData != null) {
              final text = upstreamData.toString().trim();
              if (text.isNotEmpty) {
                upstreamMessage = text;
              }
            }

            final parts = <String>[];
            if (baseError != null && baseError.isNotEmpty) {
              parts.add(baseError);
            }
            if (upstreamStatus != null && upstreamStatus.isNotEmpty) {
              parts.add('upstreamStatus=$upstreamStatus');
            }
            if (upstreamCode != null && upstreamCode.isNotEmpty) {
              parts.add('upstreamCode=$upstreamCode');
            }
            if (upstreamMessage != null && upstreamMessage.isNotEmpty) {
              parts.add(upstreamMessage);
            }
            if (details != null &&
                details.isNotEmpty &&
                details != upstreamMessage) {
              parts.add(details);
            }
            if (merchantIdCandidates is List &&
                merchantIdCandidates.isNotEmpty) {
              final candidates = merchantIdCandidates
                  .map((value) => value?.toString().trim() ?? '')
                  .where((value) => value.isNotEmpty)
                  .join(', ');
              if (candidates.isNotEmpty) {
                parts.add('merchantIds=$candidates');
              }
            }
            if (tokenMerchantId != null && tokenMerchantId.isNotEmpty) {
              parts.add('tokenMerchantId=$tokenMerchantId');
            }
            if (tokenTpn != null && tokenTpn.isNotEmpty) {
              parts.add('tokenTpn=$tokenTpn');
            }

            if (parts.isNotEmpty) {
              message = parts.join(' | ');
            }
          }
        } catch (_) {}
        return PaaayitRequestResult(success: false, message: message);
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const PaaayitRequestResult(
          success: false,
          message: 'Unexpected response while creating PaaayIT request.',
        );
      }

      final requestId = decoded['requestId']?.toString().trim() ?? '';
      final requestNumber = decoded['requestNumber']?.toString().trim() ?? '';
      final hppTransactionReferenceId =
          decoded['hppTransactionReferenceId']?.toString().trim() ?? '';
      final paymentUrl = decoded['paymentUrl']?.toString().trim() ?? '';
      final status = decoded['status']?.toString().trim() ?? 'pending';

      DateTime? expiresAt;
      if (decoded['expiresAt'] != null) {
        try {
          expiresAt = DateTime.parse(decoded['expiresAt'].toString());
        } catch (_) {}
      }

      if (paymentUrl.isEmpty) {
        return const PaaayitRequestResult(
          success: false,
          message: 'Payment URL is missing from response.',
        );
      }

      return PaaayitRequestResult(
        success: true,
        message: 'PaaayIT request created successfully.',
        requestId: requestId,
        requestNumber: requestNumber,
        hppTransactionReferenceId: hppTransactionReferenceId,
        paymentUrl: paymentUrl,
        expiresAt: expiresAt,
        status: status,
      );
    } catch (e) {
      return PaaayitRequestResult(success: false, message: 'Network error: $e');
    }
  }

  Future<List<PaaayitRequestActivityItem>> listRequests({
    required String organizationId,
    required String terminalId,
    String? locationId,
    String? status,
    DateTime? fromDate,
    DateTime? toDate,
    int limit = 100,
  }) async {
    final query = <String, String>{
      'organizationId': organizationId.trim(),
      'terminalId': terminalId.trim(),
      'limit': limit.toString(),
    };
    if (locationId != null && locationId.trim().isNotEmpty) {
      query['locationId'] = locationId.trim();
    }
    if (status != null && status.trim().isNotEmpty) {
      query['status'] = status.trim().toLowerCase();
    }
    if (fromDate != null) {
      query['fromDate'] = fromDate.toUtc().toIso8601String();
    }
    if (toDate != null) {
      query['toDate'] = toDate.toUtc().toIso8601String();
    }

    final url = Uri.parse(
      '$_backendBase/api/paaayit-requests',
    ).replace(queryParameters: query);
    final response = await http.get(
      url,
      headers: const {'Accept': 'application/json'},
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to load activity (HTTP ${response.statusCode}).');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      return const [];
    }

    final itemsRaw = decoded['items'];
    if (itemsRaw is! List) {
      return const [];
    }

    DateTime? tryParseDate(dynamic value) {
      if (value == null) return null;
      try {
        return DateTime.parse(value.toString());
      } catch (_) {
        return null;
      }
    }

    return itemsRaw
        .whereType<Map>()
        .map((row) {
          final map = Map<String, dynamic>.from(row);
          final amountRaw = map['amount'];
          final amount = amountRaw is num
              ? amountRaw.toDouble()
              : double.tryParse(amountRaw?.toString() ?? '') ?? 0;
          final providerPayloadRaw = map['provider_response_payload'];
          final providerPayload = providerPayloadRaw is Map
              ? Map<String, dynamic>.from(providerPayloadRaw)
              : const <String, dynamic>{};
          final isManualOverride =
              providerPayload['manualOverride'] == true ||
              providerPayload['tempSyncSource']?.toString() ==
                      'temp-sync-paid' &&
                  providerPayload['manualOverride']?.toString().toLowerCase() ==
                      'true';
          final cancelReason =
              providerPayload['cancelReason']?.toString().trim() ?? '';
          final cancelledAt =
              tryParseDate(providerPayload['cancelledAt']) ??
              tryParseDate(map['cancelled_at']);
          return PaaayitRequestActivityItem(
            id: map['id']?.toString() ?? '',
            hppTransactionReferenceId:
                map['hpp_transaction_reference_id']?.toString() ?? '',
            requestNumber: map['request_number']?.toString() ?? '',
            requestTitle: map['request_title']?.toString() ?? '',
            isManualOverride: isManualOverride,
            status: map['status']?.toString() ?? '',
            amount: amount,
            currency: map['currency']?.toString() ?? 'USD',
            customerName: map['customer_name']?.toString() ?? '',
            customerEmail: map['customer_email']?.toString() ?? '',
            createdAt: tryParseDate(map['created_at']),
            expiresAt: tryParseDate(map['expires_at']),
            sentAt: tryParseDate(map['sent_at']),
            paymentUrl: map['hpp_payment_url']?.toString() ?? '',
            cancelReason: cancelReason,
            cancelledAt: cancelledAt,
          );
        })
        .toList(growable: false);
  }

  Future<void> tempSyncPaid({
    required String hppTransactionReferenceId,
    String? expectedRequestNumber,
    double? expectedAmount,
    bool manualOverride = false,
    String? manualOverrideReason,
    double? manualOverrideFeeAmount,
  }) async {
    final ref = hppTransactionReferenceId.trim();
    if (ref.isEmpty) {
      throw Exception('Missing transaction reference for sync.');
    }

    final url = Uri.parse('$_backendBase/api/paaayit-requests/temp-sync-paid');
    final response = await http.post(
      url,
      headers: const {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'transactionReferenceId': ref,
        if (expectedRequestNumber != null &&
            expectedRequestNumber.trim().isNotEmpty)
          'expectedRequestNumber': expectedRequestNumber.trim(),
        if (expectedAmount != null) 'expectedAmount': expectedAmount,
        if (manualOverride) 'manualOverride': true,
        if (manualOverride &&
            manualOverrideReason != null &&
            manualOverrideReason.trim().isNotEmpty)
          'manualOverrideReason': manualOverrideReason.trim(),
        if (manualOverride && manualOverrideFeeAmount != null)
          'manualOverrideFeeAmount': manualOverrideFeeAmount,
      }),
    );

    if (response.statusCode == 200) {
      return;
    }

    final message = _composeTempSyncErrorMessage(
      statusCode: response.statusCode,
      responseBody: response.body,
    );
    throw Exception(message);
  }

  Future<void> cancelRequest({
    required String requestId,
    String? hppTransactionReferenceId,
    String? cancelReason,
  }) async {
    final trimmedId = requestId.trim();
    final trimmedRef = hppTransactionReferenceId?.trim() ?? '';
    if (trimmedId.isEmpty && trimmedRef.isEmpty) {
      throw Exception('Missing request identifier for cancel.');
    }

    final url = Uri.parse('$_backendBase/api/paaayit-requests/cancel');
    final response = await http.post(
      url,
      headers: const {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        if (trimmedId.isNotEmpty) 'requestId': trimmedId,
        if (trimmedRef.isNotEmpty) 'transactionReferenceId': trimmedRef,
        if (cancelReason != null && cancelReason.trim().isNotEmpty)
          'cancelReason': cancelReason.trim(),
      }),
    );

    if (response.statusCode == 200) {
      return;
    }

    String message = 'Cancel failed (HTTP ${response.statusCode}).';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error']?.toString().trim() ?? '';
        final providerCancelRaw = decoded['providerCancel'];
        String providerDetail = '';
        if (providerCancelRaw is Map) {
          final providerCancel = Map<String, dynamic>.from(providerCancelRaw);
          final reason = providerCancel['reason']?.toString().trim() ?? '';
          final status = providerCancel['status']?.toString().trim() ?? '';
          final endpoint = providerCancel['endpoint']?.toString().trim() ?? '';
          final parts = <String>[];
          if (reason.isNotEmpty) parts.add('reason=$reason');
          if (status.isNotEmpty) parts.add('upstreamStatus=$status');
          if (endpoint.isNotEmpty) parts.add('endpoint=$endpoint');
          if (parts.isNotEmpty) {
            providerDetail = parts.join(' | ');
          }
        }
        if (error.isNotEmpty) {
          message = providerDetail.isNotEmpty
              ? '$error | $providerDetail'
              : error;
        } else if (providerDetail.isNotEmpty) {
          message = providerDetail;
        }
      }
    } catch (_) {}
    throw Exception(message);
  }
}
