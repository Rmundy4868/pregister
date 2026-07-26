import 'package:flutter/material.dart';

import '../services/transaction_sync_service.dart';

enum _ClosedBatchViewMode { headers, details, transaction }

class ClosedBatchBrowserScreen extends StatefulWidget {
  const ClosedBatchBrowserScreen({
    super.key,
    this.embedded = false,
    this.onClose,
    required this.tpn,
    required this.authKey,
    required this.terminalName,
    required this.locationName,
    required this.organizationName,
    required this.organizationNumber,
  });

  final bool embedded;
  final VoidCallback? onClose;
  final String tpn;
  final String authKey;
  final String terminalName;
  final String locationName;
  final String organizationName;
  final String organizationNumber;

  @override
  State<ClosedBatchBrowserScreen> createState() =>
      _ClosedBatchBrowserScreenState();
}

class _ClosedBatchBrowserScreenState extends State<ClosedBatchBrowserScreen> {
  final TransactionSyncService _service = TransactionSyncService();
  bool _backfilling = false;

  _ClosedBatchViewMode _mode = _ClosedBatchViewMode.headers;

  bool _loadingHeaders = true;
  String? _headersError;
  List<Map<String, dynamic>> _headers = const [];

  bool _loadingDetails = false;
  String? _detailsError;
  List<Map<String, dynamic>> _details = const [];

  bool _loadingTxn = false;
  String? _txnError;
  Map<String, dynamic>? _txnDetail;

  Map<String, dynamic>? _selectedHeader;
  Map<String, dynamic>? _selectedDetail;

  @override
  void initState() {
    super.initState();
    _loadHeaders();
  }

  Future<void> _loadHeaders() async {
    setState(() {
      _mode = _ClosedBatchViewMode.headers;
      _loadingHeaders = true;
      _headersError = null;
      _headers = const [];
      _selectedHeader = null;
      _details = const [];
      _selectedDetail = null;
      _txnDetail = null;
      _detailsError = null;
      _txnError = null;
    });

    try {
      final rows = await _service.getClosedBatchHeaders(limit: 300);
      if (!mounted) return;
      setState(() {
        _loadingHeaders = false;
        _headers = rows;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingHeaders = false;
        _headersError = error.toString();
      });
    }
  }

  Future<void> _openBatchDetails(Map<String, dynamic> header) async {
    final headerId = header['id']?.toString() ?? '';
    if (headerId.isEmpty) return;

    final reconciled = await _service.reconcileClosedBatchHeaderTotals(
      headerId,
    );
    final reconciledTotals = reconciled['totals'];
    final effectiveHeader = Map<String, dynamic>.from(header);
    if (reconciled['ok'] == true && reconciledTotals is Map) {
      final totalsMap = Map<String, dynamic>.from(reconciledTotals);
      effectiveHeader.addAll(totalsMap);
    }

    setState(() {
      _selectedHeader = effectiveHeader;
      _selectedDetail = null;
      _txnDetail = null;
      _mode = _ClosedBatchViewMode.details;
      _loadingDetails = true;
      _detailsError = null;
      _details = const [];
      _txnError = null;
    });

    try {
      final details = await _service.getClosedBatchDetails(headerId);
      if (!mounted) return;
      setState(() {
        _loadingDetails = false;
        _details = details;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingDetails = false;
        _detailsError = error.toString();
      });
    }
  }

  Future<void> _openTransactionDetail(Map<String, dynamic> detailRow) async {
    final detailId =
        detailRow['resolved_transaction_detail_id']?.toString() ??
        detailRow['transaction_detail_id']?.toString() ??
        '';
    final headerId = detailRow['transaction_header_id']?.toString() ?? '';
    final cardBatchHeaderId =
        detailRow['card_batch_header_id']?.toString() ?? '';
    final referenceId = detailRow['reference_id']?.toString() ?? '';
    final authCode = detailRow['auth_code']?.toString() ?? '';
    final cardLast4 = detailRow['card_last4']?.toString() ?? '';
    final cardType = detailRow['card_type']?.toString() ?? '';
    final amount = _asDouble(
      detailRow['display_amount'] ?? detailRow['amount'],
    );
    final createdAt = detailRow['created_at']?.toString() ?? '';

    setState(() {
      _selectedDetail = detailRow;
      _txnDetail = null;
      _mode = _ClosedBatchViewMode.transaction;
      _loadingTxn = true;
      _txnError = null;
    });

    try {
      final txn = await _service.getClosedBatchTransactionDrilldown(
        transactionDetailId: detailId,
        transactionHeaderId: headerId,
        cardBatchHeaderId: cardBatchHeaderId,
        referenceId: referenceId,
        authCode: authCode,
        cardLast4: cardLast4,
        cardType: cardType,
        amount: amount,
        createdAt: createdAt,
      );
      if (!mounted) return;
      setState(() {
        _loadingTxn = false;
        _txnDetail = txn;
        if (txn == null) {
          _txnError =
              'Transaction detail record was not found from detail/header lookup.';
        } else if ((txn['lookup_source']?.toString() ?? '') == 'error') {
          _txnError =
              'Drilldown lookup error: ${txn['lookup_error'] ?? 'unknown error'}';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingTxn = false;
        _txnError = error.toString();
      });
    }
  }

  void _goBack() {
    setState(() {
      if (_mode == _ClosedBatchViewMode.transaction) {
        _mode = _ClosedBatchViewMode.details;
        return;
      }
      if (_mode == _ClosedBatchViewMode.details) {
        _mode = _ClosedBatchViewMode.headers;
        return;
      }
    });
  }

  Future<void> _runOneTimeBackfill() async {
    if (_backfilling) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Run One-Time Backfill'),
          content: const Text(
            'Recompute closed batch header totals from stored detail rows for this location. This is intended as a one-time historical correction. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Run Backfill'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _backfilling = true;
    });

    final result = await _service.backfillClosedBatchHeaderTotals(
      limit: 5000,
      dryRun: false,
    );
    if (!mounted) return;

    setState(() {
      _backfilling = false;
    });

    final ok = result['ok'] == true;
    final examined = (result['examined'] as num?)?.toInt() ?? 0;
    final updated = (result['updated'] as num?)?.toInt() ?? 0;
    final unchanged = (result['unchanged'] as num?)?.toInt() ?? 0;
    final errors = (result['errors'] as num?)?.toInt() ?? 0;

    final message = ok
        ? 'Backfill complete. Examined: $examined, Updated: $updated, Unchanged: $unchanged, Errors: $errors'
        : 'Backfill failed: ${result['error'] ?? 'unknown error'}';

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));

    if (_mode == _ClosedBatchViewMode.headers) {
      await _loadHeaders();
    } else if (_selectedHeader != null) {
      await _openBatchDetails(_selectedHeader!);
    }
  }

  String _fmtDateTime(String raw) {
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return raw;
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final yyyy = dt.year.toString();
    final hh = (dt.hour % 12 == 0 ? 12 : dt.hour % 12).toString();
    final min = dt.minute.toString().padLeft(2, '0');
    final suffix = dt.hour >= 12 ? 'PM' : 'AM';
    return '$mm/$dd/$yyyy $hh:$min $suffix';
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? 0;
    return 0;
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  Widget _detailLine(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              '$label:',
              style: TextStyle(fontWeight: FontWeight.w700, color: cs.primary),
            ),
          ),
          Expanded(child: SelectableText(trimmed)),
        ],
      ),
    );
  }

  Widget _buildHeaderBar(BuildContext context, String title) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (_mode != _ClosedBatchViewMode.headers)
          IconButton(
            tooltip: 'Back',
            onPressed: _goBack,
            icon: const Icon(Icons.arrow_back),
          ),
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: cs.primary,
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Refresh',
          onPressed: () {
            if (_mode == _ClosedBatchViewMode.headers) {
              _loadHeaders();
              return;
            }
            if (_mode == _ClosedBatchViewMode.details &&
                _selectedHeader != null) {
              _openBatchDetails(_selectedHeader!);
              return;
            }
            if (_mode == _ClosedBatchViewMode.transaction &&
                _selectedDetail != null) {
              _openTransactionDetail(_selectedDetail!);
            }
          },
          icon: const Icon(Icons.refresh),
        ),
        if (_mode == _ClosedBatchViewMode.headers)
          IconButton(
            tooltip: _backfilling
                ? 'Backfill in progress'
                : 'Run one-time totals backfill',
            onPressed: _backfilling ? null : _runOneTimeBackfill,
            icon: _backfilling
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.build_circle_outlined),
          ),
        if (widget.embedded && widget.onClose != null)
          IconButton(
            tooltip: 'Close',
            onPressed: widget.onClose,
            icon: const Icon(Icons.close),
          ),
      ],
    );
  }

  Widget _buildHeadersList(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loadingHeaders) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_headersError != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('Failed to load closed batches: $_headersError'),
      );
    }
    if (_headers.isEmpty) {
      return const Align(
        alignment: Alignment.topLeft,
        child: Text('No closed batches found.'),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: ListView.separated(
        itemCount: _headers.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final row = _headers[index];
          final batchNumber = row['batch_number']?.toString() ?? '';
          final total = _asDouble(row['final_total']);
          final count = _asInt(row['transaction_count']);
          final closedAt = _fmtDateTime(row['closed_at']?.toString() ?? '');
          return ListTile(
            dense: true,
            title: Text(
              batchNumber.isEmpty ? 'Batch' : 'Batch #$batchNumber',
              style: TextStyle(fontWeight: FontWeight.w700, color: cs.primary),
            ),
            subtitle: Text(
              '$closedAt\n$count txns  •  \$${total.toStringAsFixed(2)}',
            ),
            trailing: IconButton(
              tooltip: 'View Details',
              onPressed: () => _openBatchDetails(row),
              icon: const Icon(Icons.open_in_new),
            ),
            isThreeLine: true,
          );
        },
      ),
    );
  }

  Widget _buildDetailsList(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final txnCount = _details.length;

    double originalTotal = 0;
    double surchargeTotal = 0;
    double tipTotal = 0;
    for (final row in _details) {
      final amount = _asDouble(row['display_amount'] ?? row['amount']);
      final fee = _asDouble(row['fee_amount']);
      final tip = _asDouble(row['tip_adjustment_total']);
      final sign = amount < 0 ? -1.0 : 1.0;

      originalTotal += (amount - tip);
      surchargeTotal += (fee < 0 ? fee : fee.abs() * sign);
      tipTotal += tip;
    }
    final calculatedTotal = originalTotal + surchargeTotal + tipTotal;

    if (_loadingDetails) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_detailsError != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('Failed to load batch details: $_detailsError'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              Text(
                'Calculated Total: \$${calculatedTotal.toStringAsFixed(2)}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: cs.primary,
                ),
              ),
              Text('Original Amount: \$${originalTotal.toStringAsFixed(2)}'),
              Text('Surcharge: \$${surchargeTotal.toStringAsFixed(2)}'),
              Text('Tip Adjustments: \$${tipTotal.toStringAsFixed(2)}'),
              Text(
                'Header Final: \$${_asDouble((_selectedHeader ?? const <String, dynamic>{})['final_total']).toStringAsFixed(2)}',
              ),
              Text('Txn: $txnCount'),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _details.isEmpty
              ? const Center(child: Text('No transactions in this batch.'))
              : Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: ListView.separated(
                    itemCount: _details.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final row = _details[index];
                      final displayAmount = _asDouble(
                        row['display_amount'] ?? row['amount'],
                      );
                      final tipAdjust = _asDouble(
                        row['tip_adjustment_total'],
                      ).abs();
                      final originalAmount = (displayAmount.abs() - tipAdjust)
                          .abs();
                      final surchargeAmount = _asDouble(
                        row['fee_amount'],
                      ).abs();
                      final surchargeSigned = _asDouble(row['fee_amount']) < 0
                          ? _asDouble(row['fee_amount'])
                          : _asDouble(row['fee_amount']).abs() *
                                (displayAmount < 0 ? -1.0 : 1.0);
                      final rolledAmount = (displayAmount + surchargeSigned)
                          .abs();
                      final status = row['status']?.toString() ?? '';
                      final last4 = row['card_last4']?.toString() ?? '';
                      final auth = row['auth_code']?.toString() ?? '';
                      final createdAt = _fmtDateTime(
                        row['created_at']?.toString() ?? '',
                      );

                      return ListTile(
                        dense: true,
                        title: Text(
                          '\$${rolledAmount.toStringAsFixed(2)}  ${last4.isEmpty ? '' : '****$last4'}',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: cs.primary,
                          ),
                        ),
                        subtitle: Text(
                          'Status: $status${auth.isNotEmpty ? '  •  Auth: $auth' : ''}'
                          '\nOriginal Amt - \$${originalAmount.toStringAsFixed(2)}'
                          '\nSurcharge - \$${surchargeAmount.toStringAsFixed(2)}'
                          '\nTip Adj - \$${tipAdjust.toStringAsFixed(2)}'
                          '\n$createdAt',
                        ),
                        trailing: IconButton(
                          tooltip: 'View Transaction Detail',
                          onPressed: () => _openTransactionDetail(row),
                          icon: const Icon(Icons.chevron_right),
                        ),
                        isThreeLine: false,
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildTransactionDetail(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loadingTxn) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_txnError != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('Failed to load transaction detail: $_txnError'),
      );
    }
    final txn = _txnDetail;
    if (txn == null) {
      return const Align(
        alignment: Alignment.topLeft,
        child: Text('Transaction detail was not found.'),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _detailLine(
            context,
            'Lookup Source',
            txn['lookup_source']?.toString() ?? '',
          ),
          _detailLine(context, 'Detail ID', txn['id']?.toString() ?? ''),
          _detailLine(
            context,
            'Header ID',
            txn['transaction_header_id']?.toString() ?? '',
          ),
          _detailLine(context, 'Subtype', txn['subtype']?.toString() ?? ''),
          _detailLine(context, 'Status', txn['status']?.toString() ?? ''),
          _detailLine(
            context,
            'Original Amount',
            '\$${_asDouble(txn['amount']).toStringAsFixed(2)}',
          ),
          _detailLine(
            context,
            'Tip Adjust',
            '\$${_asDouble(txn['tip_adjustment_total']).toStringAsFixed(2)}',
          ),
          _detailLine(
            context,
            'Display Amount',
            '\$${_asDouble(txn['display_amount']).toStringAsFixed(2)}',
          ),
          _detailLine(
            context,
            'Surcharge',
            '\$${_asDouble(txn['fee_amount']).toStringAsFixed(2)}',
          ),
          _detailLine(
            context,
            'Reference',
            txn['reference_id']?.toString() ?? '',
          ),
          _detailLine(context, 'Auth', txn['auth_code']?.toString() ?? ''),
          _detailLine(
            context,
            'Card',
            '${txn['card_type'] ?? ''} ${txn['card_last4'] ?? ''}'.trim(),
          ),
          _detailLine(
            context,
            'Created',
            _fmtDateTime(txn['created_at']?.toString() ?? ''),
          ),
        ],
      ),
    );
  }

  String _screenTitle() {
    if (_mode == _ClosedBatchViewMode.headers) {
      return 'Closed Batches';
    }
    if (_mode == _ClosedBatchViewMode.details) {
      final batch = _selectedHeader?['batch_number']?.toString() ?? '';
      return batch.isEmpty ? 'Batch Details' : 'Batch #$batch Details';
    }
    final ref = _selectedDetail?['reference_id']?.toString() ?? '';
    return ref.isEmpty ? 'Transaction Detail' : 'Transaction Detail • $ref';
  }

  Widget _buildBody(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeaderBar(context, _screenTitle()),
          const SizedBox(height: 8),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final fade = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOut,
                  reverseCurve: Curves.easeIn,
                );
                final scale = Tween<double>(begin: 0.985, end: 1.0).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                    reverseCurve: Curves.easeInCubic,
                  ),
                );
                return FadeTransition(
                  opacity: fade,
                  child: ScaleTransition(scale: scale, child: child),
                );
              },
              child: _mode == _ClosedBatchViewMode.headers
                  ? KeyedSubtree(
                      key: const ValueKey<String>('headers-screen'),
                      child: _buildHeadersList(context),
                    )
                  : _mode == _ClosedBatchViewMode.details
                  ? KeyedSubtree(
                      key: const ValueKey<String>('details-screen'),
                      child: _buildDetailsList(context),
                    )
                  : KeyedSubtree(
                      key: const ValueKey<String>('txn-screen'),
                      child: _buildTransactionDetail(context),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return _buildBody(context);
    }

    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_screenTitle()), backgroundColor: cs.surface),
      body: _buildBody(context),
    );
  }
}
