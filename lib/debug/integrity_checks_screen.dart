import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/license_service.dart';
import '../startup_screen.dart';
import '../services/transaction_sync_service.dart';


Future<void> showIntegrityChecksWorkbench(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _IntegrityChecksDialog(),
  );
}

class _IntegrityChecksDialog extends StatefulWidget {
  const _IntegrityChecksDialog();

  @override
  State<_IntegrityChecksDialog> createState() => _IntegrityChecksDialogState();
}

class _IntegrityChecksDialogState extends State<_IntegrityChecksDialog> {
  bool _running = false;
  bool _loadingBatchHeaders = false;
  _IntegrityRunResult? _result;
  List<_BatchHeaderOption> _batchHeaders = const [];
  String? _selectedBatchHeaderId;
  final TextEditingController _loginPinController = TextEditingController();
  final TransactionSyncService _transactionSyncService = TransactionSyncService();
  final LicenseService _licenseService = LicenseService();

  @override
  void dispose() {
    _loginPinController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadRecentBatchHeaders();
  }

  Future<void> _loadRecentBatchHeaders() async {
    setState(() {
      _loadingBatchHeaders = true;
    });

    try {
      final client = Supabase.instance.client;
      final rows = await client
          .from('card_batch_headers')
          .select(
            'id,batch_number,accepted,processor_status,total_amount,closed_at,created_at',
          )
          .order('created_at', ascending: false)
          .limit(30);

      final options = (rows as List)
          .map((row) => _BatchHeaderOption.fromRow(Map<String, dynamic>.from(row as Map)))
          .toList();

      if (!mounted) return;
      setState(() {
        _batchHeaders = options;
        if (_selectedBatchHeaderId != null &&
            !_batchHeaders.any((b) => b.id == _selectedBatchHeaderId)) {
          _selectedBatchHeaderId = null;
        }
        _loadingBatchHeaders = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _batchHeaders = const [];
        _loadingBatchHeaders = false;
      });
    }
  }

  Future<void> _runBatchCloseCheck() async {
    setState(() {
      _running = true;
      _result = null;
    });

    final result = await _performBatchCloseCheck(
      selectedBatchHeaderId: _selectedBatchHeaderId,
    );

    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
    });
  }

  Future<void> _runLoginIntegrityCheck() async {
    setState(() {
      _running = true;
      _result = null;
    });

    final result = await _performLoginIntegrityCheck(
      _transactionSyncService,
      _licenseService,
      testPin: _loginPinController.text.trim(),
    );

    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
    });
  }

  Future<void> _blowoutLoginProcess() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Blowout Login Process'),
        content: const Text(
          'This clears stored terminal/license context and restarts startup resolution. '
          'Use this to validate login controls from a clean state.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Blowout + Restart Startup'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await _licenseService.clearStoredLicenseKey();
    _transactionSyncService.clearTenantScopeCache();
    if (!mounted) return;

    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const StartupScreen()),
      (route) => false,
    );
  }

  Future<void> _copySnapshot() async {
    final result = _result;
    if (result == null) return;
    final payload = const JsonEncoder.withIndent('  ').convert(result.snapshot ?? {});
    await Clipboard.setData(ClipboardData(text: payload));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Integrity snapshot copied.')),
    );
  }

  Future<void> _copyFullReport() async {
    final result = _result;
    if (result == null) return;
    final payload = _buildCopyReport(result);
    await Clipboard.setData(ClipboardData(text: payload));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Integrity report copied.')),
    );
  }

  String _buildCopyReport(_IntegrityRunResult result) {
    final buffer = StringBuffer();
    buffer.writeln(result.title);
    buffer.writeln(result.passed ? 'STATUS: PASS' : 'STATUS: FAIL');
    if ((result.error ?? '').trim().isNotEmpty) {
      buffer.writeln('ERROR: ${result.error}');
    }
    buffer.writeln('');
    buffer.writeln('SNAPSHOT:');
    buffer.writeln(const JsonEncoder.withIndent('  ').convert(result.snapshot ?? {}));
    buffer.writeln('');
    buffer.writeln('RECORD CHECKS:');
    for (final check in result.recordChecks) {
      buffer.writeln(
        '- [${check.passed ? 'PASS' : 'FAIL'}] ${check.label} | expected=${check.expected ?? '-'} | actual=${check.actual ?? '-'}',
      );
    }
    buffer.writeln('');
    buffer.writeln('FIELD CHECKS:');
    for (final check in result.fieldChecks) {
      buffer.writeln(
        '- [${check.passed ? 'PASS' : 'FAIL'}] ${check.label} | expected=${check.expected ?? '-'} | actual=${check.actual ?? '-'}',
      );
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Integrity Checks',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      OutlinedButton.icon(
                        onPressed: _running ? null : _runBatchCloseCheck,
                        icon: _running
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.fact_check_outlined),
                        label: const Text('Run Batch Close Check'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _running ? null : _runLoginIntegrityCheck,
                        icon: _running
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.login),
                        label: const Text('Run Login Integrity Check'),
                      ),
                      FilledButton.icon(
                        onPressed: _running ? null : _blowoutLoginProcess,
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('Blowout Login Process'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Test PIN:'),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 130,
                        child: TextField(
                          controller: _loginPinController,
                          maxLength: 6,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            isDense: true,
                            counterText: '',
                            border: OutlineInputBorder(),
                            hintText: 'Optional',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Used by Login Integrity Check to validate DB retrieval and mapped startup variables.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  if (_result != null) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _copySnapshot,
                          icon: const Icon(Icons.content_copy),
                          label: const Text('Copy Snapshot'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _copyFullReport,
                          icon: const Icon(Icons.assignment_outlined),
                          label: const Text('Copy Full Report'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Batch:'),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _selectedBatchHeaderId,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            hintText: 'Latest (auto)',
                          ),
                          items: _batchHeaders
                              .map(
                                (b) => DropdownMenuItem<String>(
                                  value: b.id,
                                  child: Text(b.label),
                                ),
                              )
                              .toList(),
                          onChanged: _running || _loadingBatchHeaders
                              ? null
                              : (value) {
                                  setState(() {
                                    _selectedBatchHeaderId = value;
                                  });
                                },
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _running || _loadingBatchHeaders
                            ? null
                            : _loadRecentBatchHeaders,
                        icon: _loadingBatchHeaders
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh),
                        label: const Text('Refresh'),
                      ),
                    ],
                  ),
                  if (_selectedBatchHeaderId != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _running
                            ? null
                            : () {
                                setState(() {
                                  _selectedBatchHeaderId = null;
                                });
                              },
                        child: const Text('Use Latest Instead'),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _result == null
                  ? const Center(
                      child: Text(
                        'Run Batch Close Check to validate batch integrity.',
                      ),
                    )
                  : _IntegrityCheckView(result: _result!),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: TextButton(
                  onPressed: _running ? null : () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IntegrityRunResult {
  const _IntegrityRunResult({
    required this.title,
    required this.snapshot,
    required this.recordChecks,
    required this.fieldChecks,
    this.error,
  });

  final String title;
  final Map<String, dynamic>? snapshot;
  final List<_IntegrityCheckLine> recordChecks;
  final List<_IntegrityCheckLine> fieldChecks;
  final String? error;

  bool get passed =>
      error == null &&
      recordChecks.every((c) => c.passed) &&
      fieldChecks.every((c) => c.passed);
}

class _IntegrityCheckLine {
  const _IntegrityCheckLine({
    required this.label,
    required this.passed,
    this.expected,
    this.actual,
  });

  final String label;
  final bool passed;
  final String? expected;
  final String? actual;
}

Future<_IntegrityRunResult> _performBatchCloseCheck({
  String? selectedBatchHeaderId,
}) async {
  try {
    final client = Supabase.instance.client;

    Map<String, dynamic>? header;
    if ((selectedBatchHeaderId ?? '').trim().isNotEmpty) {
      final row = await client
          .from('card_batch_headers')
          .select()
          .eq('id', selectedBatchHeaderId!.trim())
          .maybeSingle();
      if (row != null) {
        header = Map<String, dynamic>.from(row);
      }
    } else {
      final headerRow = await client
          .from('card_batch_headers')
          .select()
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      if (headerRow != null) {
        header = Map<String, dynamic>.from(headerRow);
      }
    }

    if (header == null) {
      return const _IntegrityRunResult(
        title: 'Batch Close Check',
        snapshot: null,
        recordChecks: [],
        fieldChecks: [],
        error: 'No card_batch_headers row found yet. Close a batch first.',
      );
    }

    final batchHeaderId = header['id']?.toString() ?? '';

    final detailRows = await client
        .from('card_batch_details')
        .select()
        .eq('card_batch_header_id', batchHeaderId)
        .order('created_at', ascending: true);
    final details = (detailRows as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();

    final detailIds = details
        .map((d) => d['transaction_detail_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();

    final referencedTxDetailRows = detailIds.isEmpty
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await client
                .from('transaction_details')
                .select('id')
                .inFilter('id', detailIds),
          );
    final referencedTxDetailIds = referencedTxDetailRows
        .map((r) => r['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    final expectedCount = _toInt(header['transaction_count']);
    final expectedApproved = _toInt(header['approved_count']);
    final expectedVoided = _toInt(header['voided_count']);
    final expectedTotal = _toDouble(header['total_amount']);

    final actualCount = details.length;
    final actualApproved = details
        .where((d) => (d['status']?.toString().toLowerCase() ?? '') == 'approved')
        .length;
    final actualVoided = details
        .where((d) => (d['status']?.toString().toLowerCase() ?? '') == 'voided')
        .length;
    final actualTotalRaw = details.fold<double>(
      0,
      (sum, d) => sum + _toDouble(d['amount']),
    );
    final actualTotalAbs = details.fold<double>(
      0,
      (sum, d) => sum + _toDouble(d['amount']).abs(),
    );

    final snapshot = <String, dynamic>{
      'batchHeaderId': batchHeaderId,
      'batchNumber': header['batch_number'],
      'processorStatus': header['processor_status'],
      'integrityStatus': header['integrity_status'],
      'expectedTransactionCount': expectedCount,
      'actualTransactionCount': actualCount,
      'expectedApprovedCount': expectedApproved,
      'actualApprovedCount': actualApproved,
      'expectedVoidedCount': expectedVoided,
      'actualVoidedCount': actualVoided,
      'expectedTotalAmount': expectedTotal,
      'actualTotalRaw': actualTotalRaw,
      'actualTotalAbs': actualTotalAbs,
      'detailRowsSample': details.take(3).toList(),
    };

    final recordChecks = <_IntegrityCheckLine>[
      _IntegrityCheckLine(
        label: 'card_batch_headers record exists',
        passed: batchHeaderId.isNotEmpty,
        expected: 'latest header id',
        actual: batchHeaderId.isEmpty ? '(missing)' : batchHeaderId,
      ),
      _IntegrityCheckLine(
        label: 'card_batch_details rows exist',
        passed: details.isNotEmpty,
        expected: '> 0 rows',
        actual: '$actualCount row(s)',
      ),
      _IntegrityCheckLine(
        label: 'all batch details reference existing transaction_details',
        passed: detailIds.length == referencedTxDetailIds.length,
        expected: '${detailIds.length} linked row(s)',
        actual: '${referencedTxDetailIds.length} linked row(s)',
      ),
      _IntegrityCheckLine(
        label: 'all batch detail rows belong to selected batch header',
        passed: details.every(
          (d) => d['card_batch_header_id']?.toString() == batchHeaderId,
        ),
        expected: batchHeaderId,
        actual: details.any(
              (d) => d['card_batch_header_id']?.toString() != batchHeaderId,
            )
            ? 'one or more mismatched header ids'
            : 'all rows match',
      ),
    ];

    final fieldChecks = <_IntegrityCheckLine>[
      _expectNonEmpty(
        label: 'batch_header.batch_number',
        actual: header['batch_number']?.toString() ?? '',
      ),
      _expectNonEmpty(
        label: 'batch_header.processor_status',
        actual: header['processor_status']?.toString() ?? '',
      ),
      _cmpInt(
        label: 'batch_header.transaction_count',
        expected: expectedCount,
        actual: actualCount,
      ),
      _cmpInt(
        label: 'batch_header.approved_count',
        expected: expectedApproved,
        actual: actualApproved,
      ),
      _cmpInt(
        label: 'batch_header.voided_count',
        expected: expectedVoided,
        actual: actualVoided,
      ),
      _IntegrityCheckLine(
        label: 'batch_header.total_amount matches detail sum',
        passed:
            (expectedTotal - actualTotalRaw).abs() < 0.01 ||
            (expectedTotal - actualTotalAbs).abs() < 0.01,
        expected: expectedTotal.toStringAsFixed(2),
        actual:
            'raw=${actualTotalRaw.toStringAsFixed(2)} | abs=${actualTotalAbs.toStringAsFixed(2)}',
      ),
    ];

    return _IntegrityRunResult(
      title: 'Batch Close Check',
      snapshot: snapshot,
      recordChecks: recordChecks,
      fieldChecks: fieldChecks,
    );
  } catch (error) {
    return _IntegrityRunResult(
      title: 'Batch Close Check',
      snapshot: const {},
      recordChecks: const [],
      fieldChecks: const [],
      error: error.toString(),
    );
  }
}

Future<_IntegrityRunResult> _performLoginIntegrityCheck(
  TransactionSyncService transactionSyncService,
  LicenseService licenseService, {
  required String testPin,
}) async {
  try {
    final rpcProbe = await _probeResolveInstallRpc();
    final activeContext = licenseService.activeContext;
    final canResolveTenantScope = await transactionSyncService
        .canResolveTenantScope();
    final startup = await transactionSyncService.getStartupContext();

    Map<String, String>? startupFromPin;
    String? pinDiagnostics;
    if (testPin.trim().isNotEmpty) {
      startupFromPin =
          await transactionSyncService.getStartupContextForStaffPin(testPin);
      pinDiagnostics = await transactionSyncService.diagnoseStaffPinLogin(
        testPin,
      );
    }

    final snapshot = <String, dynamic>{
      'testPinProvided': testPin.trim().isNotEmpty,
      'resolveInstallFromDeviceRpc': {
        'available': rpcProbe.available,
        'message': rpcProbe.message,
      },
      'canResolveTenantScope': canResolveTenantScope,
      'activeLicenseContext': {
        'organizationId': activeContext?.organizationId ?? '',
        'organizationNumber': activeContext?.organizationNumber ?? '',
        'licenseKey': activeContext?.licenseKey ?? '',
        'locationId': activeContext?.locationId ?? '',
        'locationName': activeContext?.locationName ?? '',
        'terminalId': activeContext?.terminalId ?? '',
        'terminalNumber': activeContext?.terminalNumber ?? '',
      },
      'startupContext': startup,
      'startupAllowTipAdjustments':
          startup['allow_tip_adjustments'] ?? startup['allowTipAdjustments'],
      'startupContextFromPin': startupFromPin,
      'pinDiagnostics': pinDiagnostics ?? 'No test PIN provided.',
    };

    final recordChecks = <_IntegrityCheckLine>[
      _IntegrityCheckLine(
        label: 'resolve_install_from_device RPC is available',
        passed: rpcProbe.available,
        expected: 'function exists and can execute',
        actual: rpcProbe.message,
      ),
      _IntegrityCheckLine(
        label: 'active license context is loaded',
        passed: activeContext != null,
        expected: 'non-null',
        actual: activeContext == null ? '(null)' : 'loaded',
      ),
      _IntegrityCheckLine(
        label: 'tenant scope can be resolved',
        passed: canResolveTenantScope,
        expected: 'true',
        actual: '$canResolveTenantScope',
      ),
      _IntegrityCheckLine(
        label: 'startup context contains terminalName',
        passed: (startup['terminalName'] ?? '').trim().isNotEmpty,
        expected: 'non-empty',
        actual: startup['terminalName'] ?? '(missing)',
      ),
      _IntegrityCheckLine(
        label: 'startup context contains staffName',
        passed: (startup['staffName'] ?? '').trim().isNotEmpty,
        expected: 'non-empty',
        actual: startup['staffName'] ?? '(missing)',
      ),
      _IntegrityCheckLine(
        label: 'startup context contains locationName',
        passed: (startup['locationName'] ?? '').trim().isNotEmpty,
        expected: 'non-empty',
        actual: startup['locationName'] ?? '(missing)',
      ),
      _IntegrityCheckLine(
        label: 'startup context contains allow_tip_adjustments',
        passed:
            (startup['allow_tip_adjustments'] ??
                    startup['allowTipAdjustments'] ??
                    '')
                .trim()
                .isNotEmpty,
        expected: 'true/false string',
        actual:
            startup['allow_tip_adjustments'] ??
            startup['allowTipAdjustments'] ??
            '(missing)',
      ),
      if (testPin.trim().isNotEmpty)
        _IntegrityCheckLine(
          label: 'test PIN resolves startup context',
          passed: startupFromPin != null,
          expected: 'non-null result',
          actual: startupFromPin == null ? '(null)' : 'resolved',
        ),
      if (testPin.trim().isNotEmpty)
        _IntegrityCheckLine(
          label: 'test PIN maps staffId',
          passed: (startupFromPin?['staffId'] ?? '').trim().isNotEmpty,
          expected: 'non-empty',
          actual: startupFromPin?['staffId'] ?? '(missing)',
        ),
      if (testPin.trim().isNotEmpty)
        _IntegrityCheckLine(
          label: 'test PIN maps staffName',
          passed: (startupFromPin?['staffName'] ?? '').trim().isNotEmpty,
          expected: 'non-empty',
          actual: startupFromPin?['staffName'] ?? '(missing)',
        ),
    ];

    final fieldChecks = <_IntegrityCheckLine>[
      _expectNonEmpty(
        label: 'license.organization_id',
        actual: activeContext?.organizationId ?? '',
      ),
      _expectNonEmpty(
        label: 'license.license_key',
        actual: activeContext?.licenseKey ?? '',
      ),
      _expectNonEmpty(
        label: 'license.location_id',
        actual: activeContext?.locationId ?? '',
      ),
      _expectNonEmpty(
        label: 'license.terminal_id',
        actual: activeContext?.terminalId ?? '',
      ),
      _expectNonEmpty(
        label: 'license.terminal_number',
        actual: activeContext?.terminalNumber ?? '',
      ),
      _expectNonEmpty(
        label: 'startup.terminalName',
        actual: startup['terminalName'] ?? '',
      ),
      _expectNonEmpty(
        label: 'startup.staffName',
        actual: startup['staffName'] ?? '',
      ),
      _expectNonEmpty(
        label: 'startup.locationName',
        actual: startup['locationName'] ?? '',
      ),
      _expectNonEmpty(
        label: 'startup.allow_tip_adjustments',
        actual:
            startup['allow_tip_adjustments'] ??
            startup['allowTipAdjustments'] ??
            '',
      ),
    ];

    return _IntegrityRunResult(
      title: 'Login Integrity Check',
      snapshot: snapshot,
      recordChecks: recordChecks,
      fieldChecks: fieldChecks,
    );
  } catch (error) {
    return _IntegrityRunResult(
      title: 'Login Integrity Check',
      snapshot: const {},
      recordChecks: const [],
      fieldChecks: const [],
      error: error.toString(),
    );
  }
}

class _RpcProbeResult {
  const _RpcProbeResult({required this.available, required this.message});

  final bool available;
  final String message;
}

Future<_RpcProbeResult> _probeResolveInstallRpc() async {
  final client = Supabase.instance.client;
  try {
    await client.rpc(
      'resolve_install_from_device',
      params: {
        'p_device_id': '__integrity_probe__',
        'p_device_label': '__integrity_probe__',
      },
    );
    return const _RpcProbeResult(
      available: true,
      message: 'RPC call succeeded (migration present).',
    );
  } on PostgrestException catch (e) {
    final code = (e.code ?? '').trim();
    final message = e.message.trim();
    final details = (e.details ?? '').toString().trim();
    final hint = (e.hint ?? '').trim();
    final normalized = '$message $details $hint'.toLowerCase();
    final missingFunction = code == '42883' ||
        normalized.contains('resolve_install_from_device') &&
            normalized.contains('does not exist');
    if (missingFunction) {
      return const _RpcProbeResult(
        available: false,
        message:
            'RPC missing. Apply supabase/2026-05-13_resolve_install_from_device.sql in this environment.',
      );
    }
    final summary = [if (code.isNotEmpty) 'code=$code', if (message.isNotEmpty) message]
        .join(' | ');
    return _RpcProbeResult(
      available: false,
      message: summary.isEmpty ? 'RPC probe failed for unknown reason.' : summary,
    );
  } catch (e) {
    return _RpcProbeResult(
      available: false,
      message: 'RPC probe failed: $e',
    );
  }
}

_IntegrityCheckLine _cmpInt({
  required String label,
  required int expected,
  required int actual,
}) {
  return _IntegrityCheckLine(
    label: label,
    passed: expected == actual,
    expected: '$expected',
    actual: '$actual',
  );
}

_IntegrityCheckLine _expectNonEmpty({
  required String label,
  required String actual,
}) {
  final value = actual.trim();
  return _IntegrityCheckLine(
    label: label,
    passed: value.isNotEmpty,
    expected: 'non-empty',
    actual: value.isEmpty ? '(empty)' : value,
  );
}

class _IntegrityCheckView extends StatelessWidget {
  const _IntegrityCheckView({required this.result});

  final _IntegrityRunResult result;

  @override
  Widget build(BuildContext context) {
    final passColor = Colors.green.shade700;
    final failColor = Colors.red.shade700;
    final bannerColor = result.passed ? passColor : failColor;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: bannerColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            result.error != null
                ? '${result.title}: FAIL - ${result.error}'
                : (result.passed
                      ? '${result.title}: PASS'
                      : 'FAIL - One or more integrity checks failed'),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Variables Snapshot', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(result.snapshot ?? {}),
            style: const TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Record-Level Checks', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        ...result.recordChecks.map(_checkRow),
        const SizedBox(height: 12),
        const Text('Field-Level Checks', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        ...result.fieldChecks.map(_checkRow),
      ],
    );
  }

  Widget _checkRow(_IntegrityCheckLine check) {
    final color = check.passed ? Colors.green.shade700 : Colors.red.shade700;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: Icon(
          check.passed ? Icons.check_circle_outline : Icons.error_outline,
          color: color,
        ),
        title: Text(check.label),
        subtitle: Text(
          'Expected: ${check.expected ?? '-'}\nActual: ${check.actual ?? '-'}',
        ),
      ),
    );
  }
}

double _toDouble(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0;
}

class _BatchHeaderOption {
  const _BatchHeaderOption({
    required this.id,
    required this.label,
  });

  final String id;
  final String label;

  static _BatchHeaderOption fromRow(Map<String, dynamic> row) {
    final id = row['id']?.toString() ?? '';
    final batch = row['batch_number']?.toString() ?? '';
    final accepted = row['accepted'] == true;
    final processorStatus = row['processor_status']?.toString().trim() ?? '';
    final totalAmount = _toDouble(row['total_amount']);
    final whenRaw = row['closed_at']?.toString() ?? row['created_at']?.toString() ?? '';
    final when = DateTime.tryParse(whenRaw)?.toLocal();
    final ts = when == null
        ? whenRaw
        : '${when.month.toString().padLeft(2, '0')}/${when.day.toString().padLeft(2, '0')}/${when.year} ${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';

    final acceptanceText = accepted ? 'Accepted' : 'Not Accepted';
    final processorText = processorStatus.isEmpty ? 'n/a' : processorStatus;
    final label =
        'Batch ${batch.isEmpty ? '(n/a)' : batch} | $acceptanceText | $processorText | \$${totalAmount.toStringAsFixed(2)} | ${ts.isEmpty ? 'no timestamp' : ts}';
    return _BatchHeaderOption(id: id, label: label);
  }
}

int _toInt(dynamic value) {
  if (value == null) return 0;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? 0;
}
