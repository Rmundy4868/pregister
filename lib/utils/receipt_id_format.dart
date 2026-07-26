int _toIntOrZero(dynamic value) {
  if (value == null) return 0;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? 0;
}

String _normalizeSegment(String raw, {int minWidth = 3}) {
  final digitsOnly = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digitsOnly.isEmpty) return ''.padLeft(minWidth, '0');
  final parsed = int.tryParse(digitsOnly) ?? 0;
  final compact = parsed.toString();
  if (compact.length >= minWidth) return compact;
  return compact.padLeft(minWidth, '0');
}

String formatReceiptIdForDisplay(String raw, {int minWidth = 3}) {
  final value = raw.trim();
  if (value.isEmpty) return '';

  final match = RegExp(r'^(\d+)-(\d+)-(\d+)$').firstMatch(value);
  if (match == null) return value;

  final batch = _normalizeSegment(match.group(1) ?? '', minWidth: minWidth);
  final terminal = _normalizeSegment(
    match.group(2) ?? '',
    minWidth: minWidth,
  );
  final seq = _normalizeSegment(match.group(3) ?? '', minWidth: minWidth);
  return '$batch-$terminal-$seq';
}

String formatReceiptIdFromParts({
  required dynamic batchNumber,
  required dynamic terminalNumber,
  required dynamic txnSeq,
  int minWidth = 3,
}) {
  final batch = _toIntOrZero(batchNumber);
  final seq = _toIntOrZero(txnSeq);
  final terminalDigits =
      (terminalNumber?.toString() ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  final terminal = int.tryParse(terminalDigits) ?? 0;

  if (batch <= 0 || terminal <= 0 || seq <= 0) return '';

  final batchText = _normalizeSegment(batch.toString(), minWidth: minWidth);
  final terminalText = _normalizeSegment(
    terminal.toString(),
    minWidth: minWidth,
  );
  final seqText = _normalizeSegment(seq.toString(), minWidth: minWidth);
  return '$batchText-$terminalText-$seqText';
}

String receiptIdSearchKey(String value) {
  return value.replaceAll(RegExp(r'[^0-9]'), '');
}
