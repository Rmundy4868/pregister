import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// Result model
// ---------------------------------------------------------------------------

enum DejavooSaleStatus { approved, declined, error, cancelled }

class DejavooSaleResult {
  final DejavooSaleStatus status;
  final String message;
  final double feeAmount;
  final String? authCode;
  final String? cardType;
  final String? cardholderName;
  final String? last4;
  final String? rawResponse;

  /// The gateway token returned by SPIn — use this for void/refund/tip-adjust.
  final String? gatewayToken;

  /// The reference ID that was sent with the request.
  final String? referenceId;

  const DejavooSaleResult({
    required this.status,
    required this.message,
    this.feeAmount = 0,
    this.authCode,
    this.cardType,
    this.cardholderName,
    this.last4,
    this.rawResponse,
    this.gatewayToken,
    this.referenceId,
  });

  bool get isApproved => status == DejavooSaleStatus.approved;
  bool get isCancelled => status == DejavooSaleStatus.cancelled;

  static DejavooSaleResult cancelled() => const DejavooSaleResult(
    status: DejavooSaleStatus.cancelled,
    message: 'Cancelled',
    feeAmount: 0,
  );
}

class DejavooVoidResult {
  final bool success;
  final String message;
  final String? resultCode;
  final String? statusCode;
  final String? detailedMessage;
  final String? rawResponse;

  const DejavooVoidResult({
    required this.success,
    required this.message,
    this.resultCode,
    this.statusCode,
    this.detailedMessage,
    this.rawResponse,
  });
}

class DejavooRefundResult {
  final bool success;
  final String message;
  final String? authCode;
  final String? cardType;
  final String? cardholderName;
  final String? last4;

  const DejavooRefundResult({
    required this.success,
    required this.message,
    this.authCode,
    this.cardType,
    this.cardholderName,
    this.last4,
  });
}

class DejavooTipAdjustResult {
  const DejavooTipAdjustResult({
    required this.success,
    required this.message,
    this.referenceId,
    this.authCode,
    this.gatewayToken,
    this.rawResponse,
  });

  final bool success;
  final String message;
  final String? referenceId;
  final String? authCode;
  final String? gatewayToken;
  final Map<String, dynamic>? rawResponse;
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------
// SPIn REST API (Dejavoo / iPOSpays)
// Docs: https://app.theneo.io/dejavoo/spin/spin-rest-api-methods
//
// Setup at iPOSpays portal (portal.ipospays.com):
//   S.T.E.A.M → Edit Parameters → select TPN → Integrations
//   → Type of Integrations: SPIn → Mode: Cloud
//   Copy the TPN and AuthKey shown.
//
// Usage:
//   final service = DejavooService(tpn: 'Z11NATASHA98', authKey: 'zbhRAW9N6x');
//   final result = await service.sale(amount: 12.50, referenceId: 'REF001');
// ---------------------------------------------------------------------------

class DejavooService {
  /// Terminal Profile Number (10–12 alphanumeric chars) from iPOSpays portal.
  final String tpn;

  /// Auth key (exactly 10 chars) from iPOSpays portal.
  final String authKey;

  /// Set true to hit the sandbox environment (test.spinpos.net).
  final bool sandbox;

  /// When true, sale requests ask processor to calculate surcharge eligibility.
  final bool requestProcessorSurcharge;

  /// Max wait time for a response. SPIn cloud default is 120 s.
  final Duration timeout;

  /// Backend base URL — all requests are proxied through server.js to avoid
  /// browser CORS restrictions on Flutter web.
  String get _backendBase {
    const raw = String.fromEnvironment(
      'PAYMENT_API_BASE_URL',
      defaultValue: 'http://127.0.0.1:3000',
    );
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  // Completer so an in-flight sale can be resolved from outside (cancel).
  Completer<DejavooSaleResult>? _activeCompleter;
  String? _activeReferenceId;

  DejavooService({
    required this.tpn,
    required this.authKey,
    this.sandbox = false,
    this.requestProcessorSurcharge = false,
    this.timeout = const Duration(seconds: 120),
  });

  // -------------------------------------------------------------------------
  // Sale
  // -------------------------------------------------------------------------
  Future<DejavooSaleResult> sale({
    required double amount,
    required String referenceId,
    String paymentType = 'Credit',
  }) async {
    _activeCompleter = Completer<DejavooSaleResult>();
    _activeReferenceId = referenceId;
    final url = Uri.parse('$_backendBase/api/spin/sale');
    final body = jsonEncode({
      'sandbox': sandbox,
      'tpn': tpn,
      'authKey': authKey,
      'amount': amount,
      'paymentType': paymentType,
      'calculateFee': requestProcessorSurcharge,
      'referenceId': referenceId,
    });

    developer.log('[SPIn] POST $url (via proxy)', name: 'DejavooService');

    http
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: body,
        )
        .timeout(timeout)
        .then((response) {
          developer.log(
            '[SPIn] HTTP ${response.statusCode} — ${response.body}',
            name: 'DejavooService',
          );
          if (!_activeCompleter!.isCompleted) {
            if (response.statusCode != 200) {
              _activeCompleter!.complete(
                DejavooSaleResult(
                  status: DejavooSaleStatus.error,
                  message:
                      'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
                  rawResponse: response.body,
                ),
              );
            } else {
              _activeCompleter!.complete(
                _parseResponse(response.body, referenceId: referenceId),
              );
            }
          }
        })
        .catchError((Object e) {
          developer.log('[SPIn] Error: $e', name: 'DejavooService');
          if (!_activeCompleter!.isCompleted) {
            final msg = e is TimeoutException
                ? 'Request timed out. Check terminal connection.'
                : 'Network error: ${e.toString()}';
            _activeCompleter!.complete(
              DejavooSaleResult(status: DejavooSaleStatus.error, message: msg),
            );
          }
        });

    return _activeCompleter!.future;
  }

  Future<DejavooSaleResult> keyedSale({
    required double amount,
    required String referenceId,
    required String cardNumber,
    required String expirationDate,
    required String cvv,
    String streetAddress = '',
    String zipCode = '',
    String paymentType = 'Credit',
  }) async {
    _activeCompleter = Completer<DejavooSaleResult>();
    _activeReferenceId = referenceId;
    final url = Uri.parse('$_backendBase/api/spin/sale-keyed');
    final body = jsonEncode({
      'sandbox': sandbox,
      'tpn': tpn,
      'authKey': authKey,
      'amount': amount,
      'paymentType': paymentType,
      'calculateFee': requestProcessorSurcharge,
      'referenceId': referenceId,
      'cardNumber': cardNumber,
      'expirationDate': expirationDate,
      'cvv': cvv,
      'streetAddress': streetAddress,
      'zipCode': zipCode,
    });

    developer.log('[SPIn] POST $url (via proxy)', name: 'DejavooService');

    http
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: body,
        )
        .timeout(timeout)
        .then((response) {
          developer.log(
            '[SPIn] HTTP ${response.statusCode} — ${response.body}',
            name: 'DejavooService',
          );
          if (!_activeCompleter!.isCompleted) {
            if (response.statusCode != 200) {
              _activeCompleter!.complete(
                DejavooSaleResult(
                  status: DejavooSaleStatus.error,
                  message:
                      'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
                  rawResponse: response.body,
                ),
              );
            } else {
              _activeCompleter!.complete(
                _parseResponse(response.body, referenceId: referenceId),
              );
            }
          }
        })
        .catchError((Object e) {
          developer.log('[SPIn] Error: $e', name: 'DejavooService');
          if (!_activeCompleter!.isCompleted) {
            final msg = e is TimeoutException
                ? 'Request timed out. Check terminal connection.'
                : 'Network error: ${e.toString()}';
            _activeCompleter!.complete(
              DejavooSaleResult(status: DejavooSaleStatus.error, message: msg),
            );
          }
        });

    return _activeCompleter!.future;
  }

  // -------------------------------------------------------------------------
  // Void — cancels an unsettled (open-batch) card transaction at the gateway.
  // Only works while batch_status = 'o' (before batch close).
  // -------------------------------------------------------------------------
  Future<DejavooVoidResult> voidSale({
    required String referenceId,
    required String gatewayToken,
    required double amount,
    String paymentType = 'Credit',
  }) async {
    final url = Uri.parse('$_backendBase/api/spin/void');
    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'sandbox': sandbox,
              'tpn': tpn,
              'authKey': authKey,
              'referenceId': referenceId,
              'gatewayToken': gatewayToken,
              'amount': amount,
              'paymentType': paymentType,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        return DejavooVoidResult(
          success: false,
          message:
              'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
          rawResponse: response.body,
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final resultCode =
          (json['GeneralResponse'] as Map<String, dynamic>?)?['ResultCode']
              ?.toString() ??
          '';
      final message =
          (json['GeneralResponse'] as Map<String, dynamic>?)?['Message']
              ?.toString() ??
          '';
      final statusCode =
          (json['GeneralResponse'] as Map<String, dynamic>?)?['StatusCode']
              ?.toString() ??
          '';
      final detailedMessage =
          (json['GeneralResponse'] as Map<String, dynamic>?)?['DetailedMessage']
              ?.toString() ??
          '';
      final hostMessage =
          (json['GeneralResponse']
                  as Map<String, dynamic>?)?['HostResponseMessage']
              ?.toString() ??
          '';
      if (resultCode == '0') {
        return DejavooVoidResult(
          success: true,
          message: 'Voided',
          resultCode: resultCode,
          statusCode: statusCode,
          detailedMessage: detailedMessage,
          rawResponse: response.body,
        );
      }

      final extraParts = <String>[];
      if (statusCode.isNotEmpty) extraParts.add('status=$statusCode');
      if (detailedMessage.isNotEmpty) extraParts.add(detailedMessage);
      if (hostMessage.isNotEmpty) extraParts.add('host=$hostMessage');
      final extra = extraParts.isEmpty ? '' : ' [${extraParts.join(' | ')}]';

      return DejavooVoidResult(
        success: false,
        message: 'Void failed ($resultCode): $message$extra',
        resultCode: resultCode,
        statusCode: statusCode,
        detailedMessage: detailedMessage,
        rawResponse: response.body,
      );
    } on TimeoutException {
      return DejavooVoidResult(
        success: false,
        message: 'Void request timed out.',
      );
    } catch (e) {
      return DejavooVoidResult(success: false, message: 'Network error: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Close Batch — settles all open card transactions with the processor.
  // After success, mark all transaction_details batch_status = 'c'.
  // -------------------------------------------------------------------------
  Future<DejavooVoidResult> closeBatch() async {
    final url = Uri.parse('$_backendBase/api/spin/closebatch');
    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'sandbox': sandbox,
              'tpn': tpn,
              'authKey': authKey,
            }),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        return DejavooVoidResult(
          success: false,
          message:
              'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final resultCode =
          (json['GeneralResponse'] as Map<String, dynamic>?)?['ResultCode']
              ?.toString() ??
          '';
      final statusCode =
          (json['GeneralResponse'] as Map<String, dynamic>?)?['StatusCode']
              ?.toString() ??
          '';
      final message =
          (json['GeneralResponse'] as Map<String, dynamic>?)?['Message']
              ?.toString() ??
          '';
      final detailedMessage =
          (json['GeneralResponse'] as Map<String, dynamic>?)?['DetailedMessage']
              ?.toString() ??
          '';
      final hostMessage =
          (json['GeneralResponse']
                  as Map<String, dynamic>?)?['HostResponseMessage']
              ?.toString() ??
          '';
      if (resultCode == '0') {
        return DejavooVoidResult(
          success: true,
          message: 'Batch closed',
          resultCode: resultCode,
          statusCode: statusCode,
          detailedMessage: detailedMessage,
          rawResponse: response.body,
        );
      }

      final extraParts = <String>[];
      if (statusCode.isNotEmpty) extraParts.add('status=$statusCode');
      if (detailedMessage.isNotEmpty) extraParts.add(detailedMessage);
      if (hostMessage.isNotEmpty) extraParts.add('host=$hostMessage');
      final extra = extraParts.isEmpty ? '' : ' [${extraParts.join(' | ')}]';

      return DejavooVoidResult(
        success: false,
        message: 'Batch close failed ($resultCode): $message$extra',
        resultCode: resultCode,
        statusCode: statusCode,
        detailedMessage: detailedMessage,
        rawResponse: response.body,
      );
    } on TimeoutException {
      return DejavooVoidResult(
        success: false,
        message: 'Batch close request timed out.',
      );
    } catch (e) {
      return DejavooVoidResult(success: false, message: 'Network error: $e');
    }
  }

  Future<DejavooRefundResult> refundSale({
    required double amount,
    required String referenceId,
    String gatewayToken = '',
  }) async {
    final url = Uri.parse('$_backendBase/api/spin/refund');
    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'sandbox': sandbox,
              'tpn': tpn,
              'authKey': authKey,
              'amount': amount,
              'referenceId': referenceId,
              'gatewayToken': gatewayToken,
            }),
          )
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        return DejavooRefundResult(
          success: false,
          message:
              'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final resultCode =
          (json['GeneralResponse'] as Map<String, dynamic>?)?['ResultCode']
              ?.toString() ??
          '';
      final message =
          (json['GeneralResponse'] as Map<String, dynamic>?)?['Message']
              ?.toString() ??
          '';
      if (resultCode == '0') {
        final cardData = json['CardData'] as Map<String, dynamic>?;
        final cardholderName = _extractCardholderName(json);
        return DejavooRefundResult(
          success: true,
          message: 'Refund approved',
          authCode: json['AuthCode']?.toString(),
          cardType: cardData?['CardType']?.toString(),
          cardholderName: (cardholderName?.isNotEmpty == true)
              ? cardholderName
              : null,
          last4: cardData?['Last4']?.toString(),
        );
      }
      return DejavooRefundResult(
        success: false,
        message: 'Refund failed ($resultCode): $message',
      );
    } on TimeoutException {
      return const DejavooRefundResult(
        success: false,
        message: 'Refund request timed out.',
      );
    } catch (e) {
      return DejavooRefundResult(success: false, message: 'Network error: $e');
    }
  }

  Future<DejavooTipAdjustResult> tipAdjust({
    required double amount,
    required double tipAmount,
    required String referenceId,
    String paymentType = 'Credit',
    String? gatewayProvider,
  }) async {
    final url = Uri.parse('$_backendBase/api/spin/tip-adjust');
    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'sandbox': sandbox,
              'tpn': tpn,
              'authKey': authKey,
              'amount': amount,
              'tipAmount': tipAmount,
              'referenceId': referenceId,
              'paymentType': paymentType,
              if (gatewayProvider != null && gatewayProvider.trim().isNotEmpty)
                'gatewayProvider': gatewayProvider.trim(),
            }),
          )
          .timeout(const Duration(seconds: 60));

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        return DejavooTipAdjustResult(
          success: false,
          message:
              'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
          rawResponse: json,
        );
      }

      final generalResponse = json['GeneralResponse'] as Map<String, dynamic>?;
      final resultCode = generalResponse?['ResultCode']?.toString() ?? '';
      final message = generalResponse?['Message']?.toString() ?? '';
      final approved = resultCode == '0';

      return DejavooTipAdjustResult(
        success: approved,
        message: approved
            ? 'Tip adjustment approved'
            : 'Tip adjustment failed ($resultCode): $message',
        referenceId: json['ReferenceId']?.toString(),
        authCode: json['AuthCode']?.toString(),
        gatewayToken: json['TransactionId']?.toString(),
        rawResponse: json,
      );
    } on TimeoutException {
      return const DejavooTipAdjustResult(
        success: false,
        message: 'Tip adjust request timed out.',
      );
    } catch (e) {
      return DejavooTipAdjustResult(
        success: false,
        message: 'Network error: $e',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Terminal UX helpers (best-effort)
  // -------------------------------------------------------------------------
  Future<void> showDeviceMessage({required String message}) async {
    final url = Uri.parse('$_backendBase/api/spin/device-message');
    try {
      await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'sandbox': sandbox,
              'tpn': tpn,
              'authKey': authKey,
              'message': message,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Best-effort only; do not block transaction flow.
    }
  }

  Future<void> setDeviceReadyForNextTransaction() async {
    final url = Uri.parse('$_backendBase/api/spin/device-ready');
    try {
      await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'sandbox': sandbox,
              'tpn': tpn,
              'authKey': authKey,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Best-effort only; do not block transaction flow.
    }
  }

  // -------------------------------------------------------------------------
  // Cancel — sends AbortTransaction to the terminal (best-effort) and
  // resolves the pending sale() future as cancelled.
  // -------------------------------------------------------------------------
  Future<void> cancel() async {
    if (_activeReferenceId != null) {
      final url = Uri.parse('$_backendBase/api/spin/abort');
      http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'sandbox': sandbox,
              'tpn': tpn,
              'authKey': authKey,
              'referenceId': _activeReferenceId,
            }),
          )
          .ignore();
    }
    if (_activeCompleter != null && !_activeCompleter!.isCompleted) {
      _activeCompleter!.complete(DejavooSaleResult.cancelled());
    }
  }

  // -------------------------------------------------------------------------
  // JSON response parser
  // -------------------------------------------------------------------------

  // SPIn infrastructure/configuration error codes that are NOT card declines.
  static const _spinInfraErrors = {
    '2001': 'Terminal not connected to SPIn cloud.',
    '2002': 'Invalid Auth Key — check SPIN_AUTH_KEY in portal.',
    '2003': 'TPN or server mismatch — check SPIN_TPN and sandbox setting.',
    '1009': 'Auth Key mismatch on terminal — re-copy key from portal.',
    '2004': 'TPN not found.',
    '2005': 'SPIn cloud service unavailable.',
    '2006': 'Terminal offline.',
    '2007': 'Request already in progress.',
    '2008': 'Request timed out on cloud.',
    '2009': 'Transaction cancelled by terminal.',
    '2010': 'Terminal busy.',
    '2011': 'Invalid request parameters.',
  };

  DejavooSaleResult _parseResponse(String body, {String? referenceId}) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;

      final generalResponse = json['GeneralResponse'] as Map<String, dynamic>?;
      final resultCode = generalResponse?['ResultCode']?.toString() ?? '';
      final rawMsg = generalResponse?['Message']?.toString();
      final rawDetail = generalResponse?['DetailedMessage']?.toString();
      final apiMessage =
          (rawMsg?.isNotEmpty == true ? rawMsg : rawDetail) ?? '';

      final authCode = json['AuthCode']?.toString();
      final cardData = json['CardData'] as Map<String, dynamic>?;
      final cardType = cardData?['CardType']?.toString();
      final cardholderName = _extractCardholderName(json);
      final last4 = cardData?['Last4']?.toString();
      final feeAmount = _extractFeeAmount(json);
      // SPIn returns the token as 'TransactionId' or 'RefNum'.
      // Do not fall back to ReferenceId because that is a client-generated id,
      // not a processor token suitable for void/refund operations.
      final gatewayToken =
          json['TransactionId']?.toString() ?? json['RefNum']?.toString();

      if (resultCode == '0') {
        return DejavooSaleResult(
          status: DejavooSaleStatus.approved,
          message: 'Approved',
          feeAmount: feeAmount,
          authCode: (authCode?.isNotEmpty == true) ? authCode : null,
          cardType: (cardType != null && cardType != 'None') ? cardType : null,
          cardholderName: (cardholderName?.isNotEmpty == true)
              ? cardholderName
              : null,
          last4: (last4?.isNotEmpty == true) ? last4 : null,
          rawResponse: body,
          gatewayToken: (gatewayToken?.isNotEmpty == true)
              ? gatewayToken
              : null,
          referenceId: referenceId,
        );
      }

      // Check for known SPIn infrastructure/config errors.
      final infraDesc = _spinInfraErrors[resultCode];
      if (infraDesc != null) {
        final detail = apiMessage.isNotEmpty ? ' ($apiMessage)' : '';
        return DejavooSaleResult(
          status: DejavooSaleStatus.error,
          message: 'Error $resultCode: $infraDesc$detail',
          rawResponse: body,
          referenceId: referenceId,
        );
      }

      // Actual card decline (issuer or terminal business logic).
      final declineMsg = apiMessage.isNotEmpty
          ? 'Declined ($resultCode): $apiMessage'
          : 'Declined (code $resultCode)';
      return DejavooSaleResult(
        status: DejavooSaleStatus.declined,
        message: declineMsg,
        authCode: (authCode?.isNotEmpty == true) ? authCode : null,
        cardType: (cardType != null && cardType != 'None') ? cardType : null,
        cardholderName: (cardholderName?.isNotEmpty == true)
            ? cardholderName
            : null,
        last4: (last4?.isNotEmpty == true) ? last4 : null,
        rawResponse: body,
        referenceId: referenceId,
      );
    } catch (_) {
      return DejavooSaleResult(
        status: DejavooSaleStatus.error,
        message: 'Failed to parse terminal response.',
        rawResponse: body,
        referenceId: referenceId,
      );
    }
  }

  String? _extractCardholderName(Map<String, dynamic> json) {
    final cardData = json['CardData'];
    if (cardData is Map) {
      final map = Map<String, dynamic>.from(cardData);
      final keys = ['CardHolderName', 'CardholderName', 'NameOnCard', 'Name'];
      for (final key in keys) {
        final value = map[key]?.toString().trim() ?? '';
        if (value.isNotEmpty) return value;
      }
    }

    final topLevelKeys = ['CardHolderName', 'CardholderName', 'NameOnCard'];
    for (final key in topLevelKeys) {
      final value = json[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  double _extractFeeAmount(Map<String, dynamic> json) {
    double? parseMoney(dynamic value) {
      if (value == null) return null;
      if (value is num) return value.toDouble();
      final text = value.toString().trim();
      if (text.isEmpty) return null;
      final cleaned = text.replaceAll(RegExp(r'[^0-9.\-]'), '');
      if (cleaned.isEmpty || cleaned == '.' || cleaned == '-') return null;
      return double.tryParse(cleaned);
    }

    dynamic pickPath(dynamic root, List<String> path) {
      dynamic current = root;
      for (final key in path) {
        if (current is Map) {
          if (!current.containsKey(key)) {
            return null;
          }
          current = current[key];
          continue;
        }

        if (current is List) {
          final index = int.tryParse(key);
          if (index == null || index < 0 || index >= current.length) {
            return null;
          }
          current = current[index];
          continue;
        }

        return null;
      }
      return current;
    }

    double? findFeeLikeValue(dynamic node) {
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key.toString().toLowerCase();
          final value = entry.value;

          if (key.contains('fee') || key.contains('surcharge')) {
            final parsed = parseMoney(value);
            if (parsed != null && parsed > 0) {
              return parsed;
            }
          }

          final nested = findFeeLikeValue(value);
          if (nested != null && nested > 0) {
            return nested;
          }
        }
      } else if (node is List) {
        for (final item in node) {
          final nested = findFeeLikeValue(item);
          if (nested != null && nested > 0) {
            return nested;
          }
        }
      }

      return null;
    }

    const candidatePaths = <List<String>>[
      ['FeeAmount'],
      ['feeAmount'],
      ['SurchargeAmount'],
      ['surchargeAmount'],
      ['SurchargeFee'],
      ['surchargeFee'],
      ['GeneralResponse', 'FeeAmount'],
      ['GeneralResponse', 'feeAmount'],
      ['GeneralResponse', 'SurchargeAmount'],
      ['GeneralResponse', 'surchargeAmount'],
      ['GeneralResponse', 'SurchargeFee'],
      ['GeneralResponse', 'surchargeFee'],
      ['CardData', 'FeeAmount'],
      ['CardData', 'feeAmount'],
      ['CardData', 'SurchargeAmount'],
      ['CardData', 'surchargeAmount'],
      ['CardData', 'SurchargeFee'],
      ['CardData', 'surchargeFee'],
      ['ExtendedData', 'FeeAmount'],
      ['ExtendedData', 'feeAmount'],
      ['ExtendedData', 'SurchargeAmount'],
      ['ExtendedData', 'surchargeAmount'],
      ['ExtendedData', 'SurchargeFee'],
      ['ExtendedData', 'surchargeFee'],
      ['result', 'FeeAmount'],
      ['result', 'feeAmount'],
      ['result', 'SurchargeAmount'],
      ['result', 'surchargeAmount'],
      ['response', 'FeeAmount'],
      ['response', 'feeAmount'],
      ['response', 'SurchargeAmount'],
      ['response', 'surchargeAmount'],
      ['data', 'FeeAmount'],
      ['data', 'feeAmount'],
      ['data', 'SurchargeAmount'],
      ['data', 'surchargeAmount'],
      ['payment', 'FeeAmount'],
      ['payment', 'feeAmount'],
      ['payment', 'SurchargeAmount'],
      ['payment', 'surchargeAmount'],
    ];

    for (final path in candidatePaths) {
      final parsed = parseMoney(pickPath(json, path));
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }

    final recursiveFallback = findFeeLikeValue(json);
    if (recursiveFallback != null && recursiveFallback > 0) {
      return recursiveFallback;
    }

    return 0;
  }
}
