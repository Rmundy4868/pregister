import 'dart:convert';

class TransactionResult {
  final bool success;
  final String message;
  final Map<String, dynamic> rawResponse;
  final String transactionId;
  final String authCode;
  final String accountNumber;
  final String accountType;

  TransactionResult({
    required this.success,
    required this.message,
    this.rawResponse = const <String, dynamic>{},
    this.transactionId = '',
    this.authCode = '',
    this.accountNumber = '',
    this.accountType = '',
  });

  String get prettyRawResponse =>
      const JsonEncoder.withIndent('  ').convert(rawResponse);
}
