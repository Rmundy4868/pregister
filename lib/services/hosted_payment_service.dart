import 'dart:convert';

import 'package:http/http.dart' as http;

class HostedPaymentLinkResult {
  final bool success;
  final String message;
  final String paymentUrl;
  final String referenceId;

  const HostedPaymentLinkResult({
    required this.success,
    required this.message,
    this.paymentUrl = '',
    this.referenceId = '',
  });
}

class HostedPaymentService {
  String get _backendBase {
    const raw = String.fromEnvironment(
      'PAYMENT_API_BASE_URL',
      defaultValue: 'http://127.0.0.1:3000',
    );
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  Future<HostedPaymentLinkResult> createPaymentLink({
    required double amount,
    required String referenceId,
    required String hppAuthToken,
  }) async {
    final url = Uri.parse('$_backendBase/api/hpp/payment-link');

    try {
      final response = await http.post(
        url,
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'amount': amount,
          'referenceId': referenceId,
          'hppAuthToken': hppAuthToken,
        }),
      );

      if (response.statusCode != 200) {
        String message = 'HTTP ${response.statusCode}';
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) {
            message =
                decoded['error']?.toString().trim().isNotEmpty == true
                ? decoded['error'].toString().trim()
                : message;
          }
        } catch (_) {}
        return HostedPaymentLinkResult(success: false, message: message);
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const HostedPaymentLinkResult(
          success: false,
          message: 'Unexpected response while creating hosted payment link.',
        );
      }

      final paymentUrl = decoded['paymentUrl']?.toString().trim() ?? '';
      final resolvedReference =
          decoded['referenceId']?.toString().trim() ?? referenceId;
      if (paymentUrl.isEmpty) {
        return const HostedPaymentLinkResult(
          success: false,
          message: 'Hosted payment link is missing from response.',
        );
      }

      return HostedPaymentLinkResult(
        success: true,
        message: 'Hosted payment link created.',
        paymentUrl: paymentUrl,
        referenceId: resolvedReference,
      );
    } catch (e) {
      return HostedPaymentLinkResult(
        success: false,
        message: 'Network error: $e',
      );
    }
  }
}
