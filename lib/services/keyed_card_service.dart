import 'package:http/http.dart' as http;
import 'dart:convert';

import 'supabase_service.dart';

/// Response from a keyed card charge attempt
class KeyedCardChargeResult {
  const KeyedCardChargeResult({
    required this.success,
    required this.approved,
    required this.transactionId,
    required this.authCode,
    required this.amount,
    this.errorMessage,
    this.responseCode,
    this.responseReasonCode,
  });

  final bool success;
  final bool approved;
  final String transactionId;
  final String authCode;
  final double amount;
  final String? errorMessage;
  final String? responseCode;
  final String? responseReasonCode;
}

class KeyedCardService {
  static const String _backendBaseUrl = 'http://localhost:3000';

  /// Processes a keyed card entry charge through the backend.
  /// Returns the transaction result with approval/decline status.
  static Future<KeyedCardChargeResult> chargeKeyedCard({
    required double amount,
    required String cardNumber,
    required String expirationDate, // MM/YY format
    required String cvv,
    required String streetAddress,
    required String zipCode,
    String? invoiceNumber,
    String? purchaseOrderNumber,
  }) async {
    try {
      // Format card expiration from MM/YY to MMYY for backend processor payloads.
      final expParts = expirationDate.split('/');
      final formattedExp =
          '${expParts[0]}${expParts.length > 1 ? expParts[1] : ''}';

      final requestBody = {
        'amount': amount,
        'card': {'number': cardNumber, 'exp': formattedExp, 'cvv': cvv},
        'billTo': {'address': streetAddress, 'zip': zipCode},
        if (invoiceNumber?.isNotEmpty ?? false)
          'order': {
            'invoiceNumber': invoiceNumber,
            if (purchaseOrderNumber?.isNotEmpty ?? false)
              'purchaseOrderNumber': purchaseOrderNumber,
          },
      };

      final response = await http
          .post(
            Uri.parse('$_backendBaseUrl/api/charge'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(requestBody),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        return KeyedCardChargeResult(
          success: false,
          approved: false,
          transactionId: '',
          authCode: '',
          amount: amount,
          errorMessage:
              'Backend error: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // Check for backend processor errors.
      if (data['error'] != null) {
        return KeyedCardChargeResult(
          success: false,
          approved: false,
          transactionId: '',
          authCode: '',
          amount: amount,
          errorMessage: data['error'].toString(),
        );
      }

      // Parse normalized or passthrough processor response structure.
      final processorResponse =
          (data['transactionResponse'] ?? data['createTransactionResponse'])
              as Map<String, dynamic>?;
      if (processorResponse == null) {
        return KeyedCardChargeResult(
          success: false,
          approved: false,
          transactionId: '',
          authCode: '',
          amount: amount,
          errorMessage: 'Invalid response from payment processor',
        );
      }

      // Check for transaction response code (success indicator)
      final responseCode = processorResponse['responseCode']?.toString() ?? '';
      final messages = processorResponse['messages'] as Map<String, dynamic>?;

      // responseCode: '1' = Approved, '2' = Declined, '3' = Error, '4' = Held for review
      if (responseCode == '1') {
        final transId = processorResponse['transId']?.toString() ?? 'unknown';
        final authCode = processorResponse['authCode']?.toString() ?? 'N/A';

        return KeyedCardChargeResult(
          success: true,
          approved: true,
          transactionId: transId,
          authCode: authCode,
          amount: amount,
          responseCode: responseCode,
        );
      }

      // Declined or error
      final messageData = messages?['message'] is List
          ? messages!['message'][0]
          : null;
      final errorMessage =
          messageData?['text']?.toString() ??
          'Transaction declined or error occurred';

      return KeyedCardChargeResult(
        success: true,
        approved: false,
        transactionId: '',
        authCode: '',
        amount: amount,
        errorMessage: errorMessage,
        responseCode: responseCode,
        responseReasonCode: messageData?['code']?.toString(),
      );
    } catch (error) {
      return KeyedCardChargeResult(
        success: false,
        approved: false,
        transactionId: '',
        authCode: '',
        amount: amount,
        errorMessage: 'Network error: ${error.toString()}',
      );
    }
  }

  /// Creates a transaction record in Supabase after successful charge.
  static Future<Map<String, dynamic>?> createTransactionRecord({
    required double amount,
    required String transactionId,
    required String authCode,
    String? invoiceNumber,
  }) async {
    try {
      final insertResult = await SupabaseService.client
          .from('transaction_headers')
          .insert({
            'organization_id': SupabaseService.client.auth.currentUser?.id,
            'amount': amount,
            'total': amount,
            'amount_paid': amount,
            'status': 'closed',
            'payment_method': 'card_keyed',
            'reference_id': invoiceNumber ?? transactionId,
          })
          .select()
          .single();

      return insertResult;
    } catch (error) {
      // Transaction record creation failed, but charge succeeded
      // Log this for reconciliation
      return null;
    }
  }
}
