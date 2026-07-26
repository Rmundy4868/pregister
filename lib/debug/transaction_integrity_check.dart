// ============================================================
// DEV TOOL — Transaction Integrity Check
// Fetches the last transaction_headers row + its detail rows
// from Supabase, displays labeled fields, and runs a set of
// pass/fail assertions.
//
// NOTE: This file is for development / QA purposes.
//       Remove the button that invokes it before release.
// ============================================================

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ---------------------------------------------------------------------------
// Public entry-point: call from a button onPressed
// ---------------------------------------------------------------------------
Future<void> showTransactionIntegrityCheck(BuildContext context) async {
  // Show loading indicator immediately
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      title: Text('Transaction Integrity Check'),
      content: SizedBox(
        height: 80,
        child: Center(child: CircularProgressIndicator()),
      ),
    ),
  );

  final result = await _fetchAndCheck();

  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop(); // close loading

  await showDialog<void>(
    context: context,
    builder: (ctx) => _IntegrityResultDialog(result: result),
  );
}

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------
class _CheckResult {
  final Map<String, dynamic>? header;
  final List<Map<String, dynamic>> details;
  final List<_Assertion> assertions;
  final String? fetchError;

  const _CheckResult({
    required this.header,
    required this.details,
    required this.assertions,
    this.fetchError,
  });

  bool get passed => assertions.every((a) => a.passed);
}

class _Assertion {
  final String label;
  final bool passed;
  final String detail;
  const _Assertion(this.label, this.passed, this.detail);
}

// ---------------------------------------------------------------------------
// Fetch + assertions
// ---------------------------------------------------------------------------
Future<_CheckResult> _fetchAndCheck() async {
  try {
    final client = Supabase.instance.client;

    // Fetch last header (most recent created_at)
    final headerResp = await client
        .from('transaction_headers')
        .select()
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (headerResp == null) {
      // Try to get a count to distinguish "empty table" from "RLS blocks read"
      String diagDetail = 'No transaction_headers rows found.';
      try {
        final user = Supabase.instance.client.auth.currentUser;
        final authState = user == null
            ? 'NOT authenticated (anon)'
            : 'authenticated uid=${user.id}';
        diagDetail = 'No rows returned.\n'
            'Auth: $authState\n'
            'Possible causes:\n'
            '  • createTransactionHeader() returned null (insert failed — check debug logs)\n'
            '  • RLS insert policy blocked the write\n'
            '  • RLS select policy blocking this read\n';
      } catch (_) {}
      return _CheckResult(
        header: null,
        details: [],
        assertions: [],
        fetchError: diagDetail,
      );
    }

    final header = Map<String, dynamic>.from(headerResp);

    // Fetch detail rows for this header
    final detailResp = await client
        .from('transaction_details')
        .select()
        .eq('transaction_header_id', header['id'] as String)
        .order('created_at', ascending: true);

    final details = (detailResp as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();

    // ---- Run assertions ----
    final assertions = <_Assertion>[];

    // 1. Header has a UUID id
    final headerId = header['id'] as String? ?? '';
    assertions.add(_Assertion(
      'Header: id is a UUID',
      RegExp(r'^[0-9a-f\-]{36}$').hasMatch(headerId),
      headerId.isEmpty ? 'MISSING' : headerId,
    ));

    // 2. organization_id present
    final orgId = header['organization_id'] as String? ?? '';
    assertions.add(_Assertion(
      'Header: organization_id present',
      orgId.isNotEmpty,
      orgId.isEmpty ? 'MISSING' : orgId,
    ));

    // 3. location_id present
    final locId = header['location_id'] as String? ?? '';
    assertions.add(_Assertion(
      'Header: location_id present',
      locId.isNotEmpty,
      locId.isEmpty ? 'MISSING' : locId,
    ));

    // 4. total > 0
    final total = _toNum(header['total']);
    assertions.add(_Assertion(
      'Header: total > 0',
      total > 0,
      '\$${total.toStringAsFixed(2)}',
    ));

    // 5. amount_paid matches sum of approved details
    final approvedSum = details
        .where((d) => d['status'] == 'approved')
        .fold<double>(0, (s, d) => s + _toNum(d['amount']));
    final amountPaid = _toNum(header['amount_paid']);
    final paidDiff = (approvedSum - amountPaid).abs();
    assertions.add(_Assertion(
      'Header: amount_paid matches approved detail sum',
      paidDiff < 0.01,
      'header.amount_paid=\$${amountPaid.toStringAsFixed(2)}  '
          'detail sum=\$${approvedSum.toStringAsFixed(2)}  '
          'diff=\$${paidDiff.toStringAsFixed(4)}',
    ));

    // 6. amount_due = total - amount_paid
    final amountDue = _toNum(header['amount_due']);
    final expectedDue = (total - amountPaid).clamp(0.0, double.infinity);
    final dueDiff = (amountDue - expectedDue).abs();
    assertions.add(_Assertion(
      'Header: amount_due = total − amount_paid',
      dueDiff < 0.01,
      'amount_due=\$${amountDue.toStringAsFixed(2)}  '
          'expected=\$${expectedDue.toStringAsFixed(2)}',
    ));

    // 7. status is valid
    final status = header['status'] as String? ?? '';
    assertions.add(_Assertion(
      'Header: status is open/closed/voided',
      ['open', 'closed', 'voided'].contains(status),
      status.isEmpty ? 'MISSING' : status,
    ));

    // 8. If status=closed, amount_due should be ~0
    if (status == 'closed') {
      assertions.add(_Assertion(
        'Header: if closed then amount_due ≈ 0',
        amountDue < 0.01,
        'amount_due=\$${amountDue.toStringAsFixed(2)}',
      ));
    }

    // 9. At least one detail row exists
    assertions.add(_Assertion(
      'Details: at least one row exists',
      details.isNotEmpty,
      '${details.length} row(s)',
    ));

    // 10. Each detail has valid payment_type
    final validTypes = {'c', 'd', 'g', 'k', 'e', 'x'};
    final allTypesValid =
        details.every((d) => validTypes.contains(d['payment_type'] as String? ?? ''));
    final types = details.map((d) => d['payment_type']).join(', ');
    assertions.add(_Assertion(
      'Details: all payment_type values valid (c/d/g/k/e/x)',
      allTypesValid,
      'types found: [$types]',
    ));

    // 11. Each detail has valid subtype
    final validSubtypes = {'s', 'r', 'v', 'a'};
    final allSubtypesValid =
        details.every((d) => validSubtypes.contains(d['subtype'] as String? ?? ''));
    final subtypes = details.map((d) => d['subtype']).join(', ');
    assertions.add(_Assertion(
      'Details: all subtype values valid (s/r/v/a)',
      allSubtypesValid,
      'subtypes found: [$subtypes]',
    ));

    // 12. Card detail has gateway_token if approved
    final approvedCardDetails = details.where(
      (d) => d['payment_type'] == 'd' && d['status'] == 'approved',
    );
    for (final d in approvedCardDetails) {
      final token = d['gateway_token'] as String? ?? '';
      assertions.add(_Assertion(
        'Detail(card): gateway_token present',
        token.isNotEmpty,
        token.isEmpty ? 'MISSING' : token.substring(0, token.length.clamp(0, 20)),
      ));
    }

    // 13. No orphan details (all reference this header)
    final allLinked = details.every(
      (d) => d['transaction_header_id'] == headerId,
    );
    assertions.add(_Assertion(
      'Details: all rows link to this header',
      allLinked,
      allLinked ? 'OK' : 'ORPHAN ROWS DETECTED',
    ));

    return _CheckResult(
      header: header,
      details: details,
      assertions: assertions,
    );
  } catch (e) {
    return _CheckResult(
      header: null,
      details: [],
      assertions: [],
      fetchError: e.toString(),
    );
  }
}

double _toNum(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}

// ---------------------------------------------------------------------------
// Dialog widget
// ---------------------------------------------------------------------------
class _IntegrityResultDialog extends StatelessWidget {
  final _CheckResult result;
  const _IntegrityResultDialog({required this.result});

  @override
  Widget build(BuildContext context) {
    final overallPass = result.fetchError == null && result.passed;
    final passColor = Colors.green.shade700;
    final failColor = Colors.red.shade700;
    final headerColor = overallPass ? passColor : failColor;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 740, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- Banner ----
            Container(
              color: headerColor,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    overallPass ? Icons.check_circle_outline : Icons.error_outline,
                    color: Colors.white,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      overallPass
                          ? 'PASS — All integrity checks passed'
                          : 'FAIL — One or more checks failed',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Text(
                    'DEV TOOL',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
            // ---- Body ----
            Flexible(
              child: SelectionArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (result.fetchError != null) ...[
                      _sectionTitle('Fetch Error'),
                      Text(
                        result.fetchError!,
                        style: TextStyle(color: failColor),
                      ),
                    ] else ...[
                      // Header fields
                      _sectionTitle('transaction_headers (last row)'),
                      _FieldTable(rows: _headerRows(result.header!)),
                      const SizedBox(height: 16),
                      // Detail rows
                      _sectionTitle(
                        'transaction_details (${result.details.length} row${result.details.length == 1 ? '' : 's'})',
                      ),
                      if (result.details.isEmpty)
                        const Text('No detail rows found.',
                            style: TextStyle(color: Colors.orange))
                      else
                        ...result.details.asMap().entries.map(
                              (e) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Row ${e.key + 1}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12),
                                    ),
                                    _FieldTable(rows: _detailRows(e.value)),
                                  ],
                                ),
                              ),
                            ),
                      const SizedBox(height: 16),
                      // Assertions
                      _sectionTitle('Integrity Assertions (${result.assertions.length})'),
                      ...result.assertions.map((a) => _AssertionRow(a: a)),
                    ],
                  ],
                ),
              ),
            ), // end SelectionArea
            ), // end Flexible
            // ---- Footer ----
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
          ),
        ),
      );

  List<(String, String)> _headerRows(Map<String, dynamic> h) => [
        ('id', _s(h['id'])),
        ('organization_id', _s(h['organization_id'])),
        ('location_id', _s(h['location_id'])),
        ('staff_id', _s(h['staff_id'])),
        ('staff_name', _s(h['staff_name'])),
        ('terminal_name', _s(h['terminal_name'])),
        ('subtotal', '\$${_toNum(h['subtotal']).toStringAsFixed(2)}'),
        ('tax', '\$${_toNum(h['tax']).toStringAsFixed(2)}'),
        ('total', '\$${_toNum(h['total']).toStringAsFixed(2)}'),
        ('amount_paid', '\$${_toNum(h['amount_paid']).toStringAsFixed(2)}'),
        ('amount_due', '\$${_toNum(h['amount_due']).toStringAsFixed(2)}'),
        ('status', _s(h['status'])),
        ('created_at', _s(h['created_at'])),
        ('closed_at', _s(h['closed_at'])),
      ];

  List<(String, String)> _detailRows(Map<String, dynamic> d) => [
        ('id', _s(d['id'])),
        ('payment_type', _s(d['payment_type'])),
        ('subtype', _s(d['subtype'])),
        ('amount', '\$${_toNum(d['amount']).toStringAsFixed(2)}'),
        ('status', _s(d['status'])),
        ('reference_id', _s(d['reference_id'])),
        ('gateway_provider', _s(d['gateway_provider'])),
        ('gateway_token', _s(d['gateway_token'])),
        ('auth_code', _s(d['auth_code'])),
        ('card_last4', _s(d['card_last4'])),
        ('card_type', _s(d['card_type'])),
        ('cash_tendered', _s(d['cash_tendered'])),
        ('cash_change', _s(d['cash_change'])),
        ('created_at', _s(d['created_at'])),
      ];

  String _s(dynamic v) => v?.toString() ?? '—';
}

// ---------------------------------------------------------------------------
// Helper widgets
// ---------------------------------------------------------------------------
class _FieldTable extends StatelessWidget {
  final List<(String, String)> rows;
  const _FieldTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Table(
      columnWidths: const {
        0: IntrinsicColumnWidth(),
        1: FlexColumnWidth(),
      },
      border: TableBorder.all(color: Colors.black12),
      children: rows.map((r) {
        return TableRow(
          decoration: const BoxDecoration(color: Colors.white),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Text(
                r.$1,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Text(
                r.$2,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ],
        );
      }).toList(),
    );
  }
}

class _AssertionRow extends StatelessWidget {
  final _Assertion a;
  const _AssertionRow({required this.a});

  @override
  Widget build(BuildContext context) {
    final color = a.passed ? Colors.green.shade700 : Colors.red.shade700;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            a.passed ? Icons.check_circle : Icons.cancel,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 12, color: Colors.black87),
                children: [
                  TextSpan(
                    text: '${a.label}  ',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text: a.detail,
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
