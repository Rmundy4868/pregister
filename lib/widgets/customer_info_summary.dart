import 'package:flutter/material.dart';

typedef CustomerInfoFormatter = String Function(String label, String value);

String _defaultCustomerInfoFormatter(String label, String value) =>
    '$label: $value';

class CustomerInfoSummary extends StatelessWidget {
  const CustomerInfoSummary({
    super.key,
    required this.customerData,
    this.formatter,
    this.maxLines = 4,
    this.compact = false,
  });

  final Map<String, dynamic> customerData;
  final CustomerInfoFormatter? formatter;
  final int maxLines;
  final bool compact;

  String _preferredValue(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final text = candidate?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final format = formatter ?? _defaultCustomerInfoFormatter;

    final fullName = _preferredValue([
      customerData['first_name'],
      customerData['firstName'],
      customerData['name'],
      customerData['customer_name'],
    ]);

    final phone = _preferredValue([
      customerData['phone'],
      customerData['phone_number'],
      customerData['phoneNumber'],
    ]);

    final email = _preferredValue([
      customerData['email'],
      customerData['email_address'],
    ]);

    final customerId = _preferredValue([
      customerData['customer_number'],
      customerData['customer_id'],
      customerData['customerId'],
    ]);

    final lines = <String>[
      if (fullName.isNotEmpty) format('Name', fullName),
      if (customerId.isNotEmpty) format('Customer ID', customerId),
      if (phone.isNotEmpty) format('Phone', phone),
      if (email.isNotEmpty) format('Email', email),
    ];

    if (lines.isEmpty) {
      return const SizedBox.shrink();
    }

    final displayLines = lines.length > maxLines
        ? lines.sublist(0, maxLines)
        : lines;
    final showMore = lines.length > maxLines;

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Customer Info',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
          const SizedBox(height: 6),
          ...displayLines.map(
            (line) => Text(
              line,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (showMore)
            const Text(
              '... and more',
              style: TextStyle(fontSize: 10, fontStyle: FontStyle.italic),
            ),
        ],
      );
    }

    return Tooltip(
      message: lines.join('\n'),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFE0E0E0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Original Customer Info',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
            ),
            const SizedBox(height: 8),
            ...displayLines.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  line,
                  style: const TextStyle(fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (showMore)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '... and more',
                  style: TextStyle(fontSize: 10, fontStyle: FontStyle.italic),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
