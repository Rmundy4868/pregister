import 'dart:convert';
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../services/transaction_sync_service.dart';
import '../utils/text_file_save.dart';
import '../utils/receipt_id_format.dart';
import '../widgets/receipt_preview_section.dart';
import '../widgets/customer_info_summary.dart';
import '../widgets/standard_action_button.dart';

enum _PrintExportType { summary, details }

class ViewTransactionsReportScreen extends StatefulWidget {
  const ViewTransactionsReportScreen({
    super.key,
    this.embedded = false,
    this.onClose,
  });

  final bool embedded;
  final VoidCallback? onClose;

  @override
  State<ViewTransactionsReportScreen> createState() =>
      _ViewTransactionsReportScreenState();
}

class _ViewTransactionsReportScreenState
    extends State<ViewTransactionsReportScreen> {
  final TransactionSyncService _service = TransactionSyncService();
  final TextEditingController _customFromController = TextEditingController();
  final TextEditingController _customToController = TextEditingController();
  final TextEditingController _minAmountController = TextEditingController();
  final TextEditingController _maxAmountController = TextEditingController();
  final TextEditingController _cardFilterController = TextEditingController();
  final TextEditingController _authFilterController = TextEditingController();
  final TextEditingController _receiptIdFilterController =
      TextEditingController();

  String _datePreset = 'all';
  String _statusFilter = 'all';
  String _tenderFilter = 'all';
  bool _showFiltersModal = false;
  bool _showPrintExportModal = false;
  _PrintExportType _printExportSelection = _PrintExportType.summary;
  bool _printExportInProgress = false;
  bool _showInlineCalendar = false;
  bool _inlineCalendarForFromDate = true;
  DateTime? _customFromDate;
  DateTime? _customToDate;
  double? _minAmountFilter;
  double? _maxAmountFilter;
  String _cardFilter = '';
  String _authFilter = '';
  String _receiptIdFilter = '';
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _headers = const [];
  Map<String, String> _headerTenderKinds = const <String, String>{};
  Map<String, Map<String, String>> _headerCardAuthSummary =
      const <String, Map<String, String>>{};

  bool _detailsLoading = false;
  Map<String, dynamic>? _selectedHeader;
  List<Map<String, dynamic>> _selectedDetails = const [];

  // Inline detail expansion state (kept for legacy cache; modal is now primary)
  String? _expandedHeaderId;
  final Map<String, List<Map<String, dynamic>>> _inlineDetailCache = {};
  final Map<String, bool> _inlineDetailLoading = {};

  // Detail modal state
  bool _showDetailModal = false;
  Map<String, dynamic>? _modalHeader;
  List<Map<String, dynamic>> _modalDetails = const [];
  bool _modalLoading = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _customFromDate = DateTime(now.year, now.month, now.day);
    _customToDate = DateTime(now.year, now.month, now.day);
    _syncCustomDateText();
    _loadHeaders();
  }

  @override
  void dispose() {
    _customFromController.dispose();
    _customToController.dispose();
    _minAmountController.dispose();
    _maxAmountController.dispose();
    _cardFilterController.dispose();
    _authFilterController.dispose();
    _receiptIdFilterController.dispose();
    super.dispose();
  }

  void _openFiltersModal() {
    setState(() {
      _showFiltersModal = true;
      _showInlineCalendar = false;
    });
  }

  void _closeFiltersModal() {
    setState(() {
      _showFiltersModal = false;
      _showInlineCalendar = false;
    });
  }

  Future<void> _loadHeaders() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Pull event history broadly, then apply UI date presets locally on
      // flattened event rows so refunds/voids tied to older headers are not dropped.
      final range = _resolveRange('all');
      final rows = await _service.getTransactionHeadersReport(
        from: range.$1,
        to: range.$2,
        status: 'all',
      );

      final headerIds = rows
          .map((row) => row['id']?.toString().trim() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList(growable: false);
      Map<String, String> tenderKinds = const <String, String>{};
      Map<String, Map<String, String>> cardAuthSummary =
          const <String, Map<String, String>>{};
      if (headerIds.isNotEmpty) {
        tenderKinds = await _service.getTransactionHeaderTenderKinds(headerIds);
        cardAuthSummary = await _service.getTransactionHeaderCardAuthSummary(
          headerIds,
        );
      }

      // Flatten ledger headers into event rows so voids/refunds are visible
      // in the transactions list without opening each header detail modal.
      bool isTipAdjustmentRow(Map<String, dynamic> row) {
        final subtype = (row['subtype']?.toString().toLowerCase() ?? '').trim();
        if (subtype != 'a') return false;
        final originalId = row['original_detail_id']?.toString().trim() ?? '';
        return originalId.isNotEmpty;
      }

      double parseMoney(dynamic value) {
        if (value == null) return 0.0;
        if (value is num) return value.toDouble();
        final parsed = double.tryParse(value.toString().trim());
        return parsed ?? 0.0;
      }

      final detailsByHeader = await _loadDetailsByHeaderId(rows);
      final flattenedRows = <Map<String, dynamic>>[];
      for (final header in rows) {
        final headerId = header['id']?.toString().trim() ?? '';
        final details =
            detailsByHeader[headerId] ?? const <Map<String, dynamic>>[];

        if (details.isEmpty) {
          flattenedRows.add(Map<String, dynamic>.from(header));
          continue;
        }

        final tipAdjustByOriginalId = <String, double>{};
        final tipAdjustAtByOriginalId = <String, DateTime>{};
        final voidedSaleIds = <String>{};
        var hasUnlinkedVoid = false;
        final saleDetailIds = <String>[];
        for (final detail in details) {
          final isApproved =
              (detail['status']?.toString().toLowerCase() ?? '') == 'approved';
          if (!isApproved || !isTipAdjustmentRow(detail)) {
            continue;
          }
          final originalId =
              detail['original_detail_id']?.toString().trim() ?? '';
          if (originalId.isEmpty) continue;
          final amount = parseMoney(detail['amount']);
          final createdAt = DateTime.tryParse(
            detail['created_at']?.toString() ?? '',
          );
          final existingAt = tipAdjustAtByOriginalId[originalId];
          if (existingAt == null ||
              (createdAt != null && createdAt.isAfter(existingAt))) {
            tipAdjustByOriginalId[originalId] = amount;
            if (createdAt != null) {
              tipAdjustAtByOriginalId[originalId] = createdAt;
            }
          }
        }

        for (final detail in details) {
          final subtype = (detail['subtype']?.toString().toLowerCase() ?? '')
              .trim();
          final status = (detail['status']?.toString().toLowerCase() ?? '')
              .trim();

          if (subtype == 's' && (status == 'approved' || status == 'voided')) {
            final saleId = detail['id']?.toString().trim() ?? '';
            if (saleId.isNotEmpty) {
              saleDetailIds.add(saleId);
            }
          }

          if (subtype != 'v') continue;
          if (status != 'approved' && status != 'voided') continue;

          final originalId =
              detail['original_detail_id']?.toString().trim() ?? '';
          if (originalId.isNotEmpty) {
            voidedSaleIds.add(originalId);
          } else {
            hasUnlinkedVoid = true;
          }
        }

        if (hasUnlinkedVoid &&
            voidedSaleIds.isEmpty &&
            saleDetailIds.length == 1) {
          voidedSaleIds.add(saleDetailIds.first);
        }

        for (final detail in details) {
          if (isTipAdjustmentRow(detail)) {
            continue;
          }

          final subtype = (detail['subtype']?.toString().toLowerCase() ?? '')
              .trim();
          final detailStatus =
              (detail['status']?.toString().toLowerCase() ?? '').trim();
          if ((subtype != 's' && subtype != 'r') ||
              (detailStatus != 'approved' && detailStatus != 'voided')) {
            continue;
          }

          final detailId = detail['id']?.toString().trim() ?? '';
          final effectiveStatus =
              (subtype == 's' &&
                  detailStatus != 'voided' &&
                  detailId.isNotEmpty &&
                  voidedSaleIds.contains(detailId))
              ? 'voided'
              : detailStatus;

          if ((subtype != 's' && subtype != 'r') ||
              (effectiveStatus != 'approved' && effectiveStatus != 'voided')) {
            continue;
          }

          final status = effectiveStatus;

          final merged = {
            ...Map<String, dynamic>.from(header),
            ...Map<String, dynamic>.from(detail),
            'id': detail['id']?.toString() ?? header['id']?.toString(),
            'transaction_header_id': headerId,
            'header_id': headerId,
            'header_status': header['status'],
            'header_total': header['total'],
            'header_created_at': header['created_at'],
            'header_receipt_id': _headerReceiptIdDisplay(header),
            'created_at': detail['created_at'] ?? header['created_at'],
            'status': status,
            'total': parseMoney(detail['amount']).abs(),
          };
          if (subtype == 's') {
            final baseAmount = parseMoney(detail['amount']);
            final surchargeAmount = parseMoney(detail['fee_amount']).abs();
            final tipAdjustmentTotal = tipAdjustByOriginalId[detailId] ?? 0.0;
            final displayAmount =
                baseAmount + surchargeAmount + tipAdjustmentTotal;

            merged['original_amount'] = baseAmount;
            merged['surcharge_amount'] = surchargeAmount;
            merged['tip_adjustment_total'] = tipAdjustmentTotal;
            merged['display_amount'] = displayAmount;
            merged['total'] = displayAmount;
          } else if (subtype == 'r') {
            final baseAmount = parseMoney(detail['amount']).abs();
            merged['original_amount'] = baseAmount;
            merged['surcharge_amount'] = 0.0;
            merged['tip_adjustment_total'] = 0.0;
            merged['display_amount'] = baseAmount;
            merged['total'] = baseAmount;
          }

          flattenedRows.add(merged);
        }
      }

      if (!mounted) return;
      setState(() {
        _headers = flattenedRows;
        _headerTenderKinds = tenderKinds;
        _headerCardAuthSummary = cardAuthSummary;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  // ignore: unused_element
  Future<void> _openHeaderDetails(Map<String, dynamic> header) async {
    final headerId = _effectiveHeaderId(header);
    if (headerId.isEmpty) return;

    setState(() {
      _detailsLoading = true;
      _selectedHeader = header;
      _selectedDetails = const [];
    });

    try {
      final details = await _service.getTransactionDetailsForHeader(headerId);
      if (!mounted) return;
      setState(() {
        _selectedDetails = details;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load detail rows: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _detailsLoading = false;
        });
      }
    }
  }

  void _closeHeaderDetails() {
    setState(() {
      _selectedHeader = null;
      _selectedDetails = const [];
      _detailsLoading = false;
    });
  }

  Future<void> _openDetailModal(Map<String, dynamic> header) async {
    final headerId = _effectiveHeaderId(header);
    if (headerId.isEmpty) return;
    setState(() {
      _showDetailModal = true;
      _modalHeader = header;
      _modalDetails = const [];
      _modalLoading = true;
    });
    try {
      final details = await _service.getTransactionDetailsForHeader(headerId);
      if (!mounted) return;
      setState(() {
        _modalDetails = details;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _modalDetails = const [];
      });
    } finally {
      if (mounted) {
        setState(() => _modalLoading = false);
      }
    }
  }

  void _closeDetailModal() {
    setState(() {
      _showDetailModal = false;
      _modalHeader = null;
      _modalDetails = const [];
      _modalLoading = false;
    });
  }

  // ignore: unused_element
  Future<void> _toggleInlineDetail(Map<String, dynamic> header) async {
    final headerId = _effectiveHeaderId(header);
    if (headerId.isEmpty) return;

    if (_expandedHeaderId == headerId) {
      setState(() => _expandedHeaderId = null);
      return;
    }

    setState(() => _expandedHeaderId = headerId);

    if (!_inlineDetailCache.containsKey(headerId)) {
      setState(() => _inlineDetailLoading[headerId] = true);
      try {
        final details = await _service.getTransactionDetailsForHeader(headerId);
        if (!mounted) return;
        setState(() {
          _inlineDetailCache[headerId] = details;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _inlineDetailCache[headerId] = const [];
        });
      } finally {
        if (mounted) {
          setState(() => _inlineDetailLoading.remove(headerId));
        }
      }
    }
  }

  (DateTime, DateTime) _resolveRange(String preset) {
    final now = DateTime.now();
    final end = now;

    if (preset == 'all') {
      return (DateTime(2020, 1, 1), end);
    }
    if (preset == 'today') {
      final start = DateTime(now.year, now.month, now.day);
      return (start, end);
    }
    if (preset == 'last7') {
      return (now.subtract(const Duration(days: 7)), end);
    }
    if (preset == 'custom') {
      final from = _customFromDate ?? DateTime(now.year, now.month, now.day);
      final to = _customToDate ?? from;
      final start = DateTime(from.year, from.month, from.day);
      final endOfDay = DateTime(to.year, to.month, to.day, 23, 59, 59, 999);
      return (start, endOfDay);
    }
    return (now.subtract(const Duration(days: 30)), end);
  }

  String _formatDateOnly(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    final yyyy = date.year.toString();
    return '$mm/$dd/$yyyy';
  }

  void _syncCustomDateText() {
    if (_customFromDate != null) {
      _customFromController.text = _formatDateOnly(_customFromDate!);
    }
    if (_customToDate != null) {
      _customToController.text = _formatDateOnly(_customToDate!);
    }
  }

  DateTime? _parseDateInput(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final direct = DateTime.tryParse(text);
    if (direct != null) {
      return DateTime(direct.year, direct.month, direct.day);
    }

    final parts = text.split('/');
    if (parts.length == 3) {
      final month = int.tryParse(parts[0]);
      final day = int.tryParse(parts[1]);
      final year = int.tryParse(parts[2]);
      if (month == null || day == null || year == null) return null;
      if (month < 1 || month > 12 || day < 1 || day > 31) return null;
      return DateTime(year, month, day);
    }

    return null;
  }

  void _toggleInlineCalendar({required bool fromDate}) {
    setState(() {
      if (_showInlineCalendar && _inlineCalendarForFromDate == fromDate) {
        _showInlineCalendar = false;
      } else {
        _showInlineCalendar = true;
        _inlineCalendarForFromDate = fromDate;
      }
    });
  }

  void _applyInlineCalendarDate(DateTime picked) {
    setState(() {
      final selected = DateTime(picked.year, picked.month, picked.day);
      if (_inlineCalendarForFromDate) {
        _customFromDate = selected;
        if (_customToDate != null &&
            _customToDate!.isBefore(_customFromDate!)) {
          _customToDate = _customFromDate;
        }
      } else {
        _customToDate = selected;
        if (_customFromDate != null &&
            _customToDate!.isBefore(_customFromDate!)) {
          _customFromDate = _customToDate;
        }
      }
      _showInlineCalendar = false;
      _syncCustomDateText();
    });
  }

  void _setCustomDate({required bool fromDate, required DateTime picked}) {
    setState(() {
      if (fromDate) {
        _customFromDate = DateTime(picked.year, picked.month, picked.day);
        if (_customToDate != null &&
            _customToDate!.isBefore(_customFromDate!)) {
          _customToDate = _customFromDate;
        }
      } else {
        _customToDate = DateTime(picked.year, picked.month, picked.day);
        if (_customFromDate != null &&
            _customToDate!.isBefore(_customFromDate!)) {
          _customFromDate = _customToDate;
        }
      }
      _syncCustomDateText();
    });
  }

  void _updateCustomDateFromText({
    required bool fromDate,
    required String raw,
  }) {
    final parsed = _parseDateInput(raw);
    if (parsed == null) return;
    _setCustomDate(fromDate: fromDate, picked: parsed);
  }

  String _formatDateTime(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '-';
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
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  double _effectiveDisplayTotal(Map<String, dynamic> row) {
    return _asDouble(
      row['display_amount'] ?? row['total'] ?? row['header_total'],
    );
  }

  double _summaryContribution(Map<String, dynamic> row) {
    final status = (row['status']?.toString().toLowerCase() ?? '').trim();
    if (status == 'voided') {
      return 0.0;
    }
    final subtype = (row['subtype']?.toString().toLowerCase() ?? '').trim();
    final amount = _effectiveDisplayTotal(row).abs();
    if (subtype == 'r') {
      return -amount;
    }
    return amount;
  }

  double _summarySurchargeContribution(Map<String, dynamic> row) {
    final status = (row['status']?.toString().toLowerCase() ?? '').trim();
    if (status == 'voided') {
      return 0.0;
    }
    final subtype = (row['subtype']?.toString().toLowerCase() ?? '').trim();
    if (subtype != 's') {
      return 0.0;
    }
    return _headerSurchargeAmount(row);
  }

  double _summaryTipAdjustmentContribution(Map<String, dynamic> row) {
    final status = (row['status']?.toString().toLowerCase() ?? '').trim();
    if (status == 'voided') {
      return 0.0;
    }
    final subtype = (row['subtype']?.toString().toLowerCase() ?? '').trim();
    if (subtype != 's') {
      return 0.0;
    }
    return _headerTipAdjustmentAmount(row);
  }

  double _headerSurchargeAmount(Map<String, dynamic> row) {
    return _asDouble(row['surcharge_amount'] ?? row['fee_amount']);
  }

  double _detailSurchargeAmount(Map<String, dynamic> detail) {
    return _asDouble(detail['surcharge_amount'] ?? detail['fee_amount']);
  }

  double _headerTipAdjustmentAmount(Map<String, dynamic> row) {
    return _asDouble(row['tip_adjustment_total']);
  }

  double _detailTipAdjustmentAmount(Map<String, dynamic> detail) {
    final subtype = (detail['subtype']?.toString().toLowerCase() ?? '').trim();
    final originalId = detail['original_detail_id']?.toString().trim() ?? '';
    if (subtype == 'a' && originalId.isNotEmpty) {
      return _asDouble(detail['amount']);
    }
    return 0;
  }

  double? _parseAmountInput(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final normalized = text.replaceAll(',', '').replaceAll('\$', '');
    final parsed = double.tryParse(normalized);
    if (parsed == null) return null;
    if (parsed < 0) return 0;
    return parsed;
  }

  void _syncAmountFiltersFromText() {
    _minAmountFilter = _parseAmountInput(_minAmountController.text);
    _maxAmountFilter = _parseAmountInput(_maxAmountController.text);
    if (_minAmountFilter != null &&
        _maxAmountFilter != null &&
        _maxAmountFilter! < _minAmountFilter!) {
      final swap = _minAmountFilter;
      _minAmountFilter = _maxAmountFilter;
      _maxAmountFilter = swap;
      _minAmountController.text = _minAmountFilter!.toStringAsFixed(2);
      _maxAmountController.text = _maxAmountFilter!.toStringAsFixed(2);
    }
  }

  void _syncCardAuthFiltersFromText() {
    _cardFilter = _cardFilterController.text.trim().toLowerCase();
    _authFilter = _authFilterController.text.trim().toLowerCase();
    _receiptIdFilter = _receiptIdFilterController.text.trim().toLowerCase();
  }

  String _headerReceiptIdDisplay(Map<String, dynamic> row) {
    final hydrated = row['header_receipt_id']?.toString().trim() ?? '';
    if (hydrated.isNotEmpty) {
      return formatReceiptIdForDisplay(hydrated);
    }

    final raw = row['receipt_id']?.toString().trim() ?? '';
    if (raw.isNotEmpty) {
      return formatReceiptIdForDisplay(raw);
    }

    return formatReceiptIdFromParts(
      batchNumber: row['batch_number'],
      terminalNumber: row['terminal_number'],
      txnSeq: row['txn_seq'],
    );
  }

  bool _matchesReceiptIdFilter(Map<String, dynamic> row) {
    final query = _receiptIdFilter.trim();
    if (query.isEmpty) return true;

    final display = _headerReceiptIdDisplay(row).toLowerCase();
    final raw = (row['receipt_id']?.toString() ?? '').trim().toLowerCase();
    if (display.contains(query) || raw.contains(query)) return true;

    final queryKey = receiptIdSearchKey(query);
    if (queryKey.isEmpty) return false;
    return receiptIdSearchKey(display).contains(queryKey) ||
        receiptIdSearchKey(raw).contains(queryKey);
  }

  String _statusLabel(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 'unknown';
    return trimmed;
  }

  String _effectiveHeaderId(Map<String, dynamic> row) {
    return (row['transaction_header_id'] ?? row['header_id'] ?? row['id'])
            ?.toString()
            .trim() ??
        '';
  }

  bool _matchesStatusFilter(Map<String, dynamic> row) {
    if (_statusFilter == 'all') return true;

    if (_statusFilter == 'voided') {
      final subtype = row['subtype']?.toString().trim().toLowerCase() ?? '';
      final status = row['status']?.toString().trim().toLowerCase() ?? '';
      return subtype == 'v' || status == 'voided';
    }

    if (_statusFilter == 'closed') {
      return _headerBatchStatus(row) == 'c';
    }

    if (_statusFilter == 'open') {
      return _headerBatchStatus(row) != 'c';
    }

    return true;
  }

  String _paymentTypeLabel(String raw) {
    final value = raw.trim().toLowerCase();
    switch (value) {
      case 'c':
      case 'cash':
        return 'cash';
      case 'd':
      case 'card':
        return 'card';
      default:
        return value.isEmpty ? 'unknown' : value;
    }
  }

  String _eventTypeLabel(Map<String, dynamic> row) {
    final subtype = row['subtype']?.toString().trim().toLowerCase() ?? '';
    final status = row['status']?.toString().trim().toLowerCase() ?? '';
    if (subtype == 's' && status == 'voided') {
      return 'VOIDED';
    }
    switch (subtype) {
      case 's':
        return 'SALE';
      case 'r':
        return 'REFUND';
      case 'v':
        return 'VOID';
      case 'a':
        return 'ADJUST';
      default:
        final payment = _paymentTypeLabel(
          row['payment_type']?.toString() ?? '',
        );
        if (payment == 'cash') return 'CASH';
        if (payment == 'card') return 'CARD';
        return 'TXN';
    }
  }

  String _headerTenderKind(Map<String, dynamic> header) {
    final paymentType =
        header['payment_type']?.toString().trim().toLowerCase() ?? '';
    if (paymentType == 'd' || paymentType == 'card') return 'card';
    if (paymentType == 'c' || paymentType == 'cash') return 'cash';

    final headerId =
        (header['transaction_header_id'] ?? header['header_id'] ?? header['id'])
            ?.toString()
            .trim() ??
        '';
    if (headerId.isEmpty) return 'unknown';
    return _headerTenderKinds[headerId] ?? 'unknown';
  }

  List<Map<String, dynamic>> _visibleHeaders() {
    return _headers.where((row) {
      final createdAt = DateTime.tryParse(
        row['created_at']?.toString() ?? '',
      )?.toLocal();
      final range = _resolveRange(_datePreset);
      if (_datePreset != 'all') {
        if (createdAt == null) {
          return false;
        }
        final from = range.$1.toLocal();
        final to = range.$2.toLocal();
        if (createdAt.isBefore(from) || createdAt.isAfter(to)) {
          return false;
        }
      }

      if (!_matchesStatusFilter(row)) {
        return false;
      }

      if (_tenderFilter != 'all' && _headerTenderKind(row) != _tenderFilter) {
        return false;
      }
      final total = _effectiveDisplayTotal(row);
      if (_minAmountFilter != null && total < _minAmountFilter!) {
        return false;
      }
      if (_maxAmountFilter != null && total > _maxAmountFilter!) {
        return false;
      }

      if (_cardFilter.isNotEmpty) {
        final card = _headerCardLast4Raw(row).toLowerCase();
        final cardDigits = _cardFilter.replaceAll(RegExp(r'[^0-9]'), '');

        final matches = cardDigits.length == 4
            ? card == cardDigits
            : card.contains(_cardFilter);

        if (!matches) {
          return false;
        }
      }

      if (_authFilter.isNotEmpty) {
        final auth = _headerAuthCodeRaw(row).toLowerCase();
        if (!auth.contains(_authFilter)) {
          return false;
        }
      }

      if (!_matchesReceiptIdFilter(row)) {
        return false;
      }

      return true;
    }).toList();
  }

  Color _tenderColor(String tender) {
    switch (tender) {
      case 'cash':
        return const Color(0xFF2E7D32);
      case 'card':
        return const Color(0xFF1565C0);
      case 'mixed':
        return const Color(0xFF6A1B9A);
      default:
        return const Color(0xFF616161);
    }
  }

  Color _tenderBackgroundColor(String tender) {
    switch (tender) {
      case 'cash':
        return const Color(0xFFE8F5E9);
      case 'card':
        return const Color(0xFFE3F2FD);
      case 'mixed':
        return const Color(0xFFF3E5F5);
      default:
        return const Color(0xFFF5F5F5);
    }
  }

  IconData _tenderIcon(String tender) {
    switch (tender) {
      case 'cash':
        return Icons.payments_outlined;
      case 'card':
        return Icons.credit_card;
      case 'mixed':
        return Icons.account_balance_wallet_outlined;
      default:
        return Icons.help_outline;
    }
  }

  String _headerCardLast4Raw(Map<String, dynamic> row) {
    final detailLast4 = row['card_last4']?.toString().trim() ?? '';
    if (detailLast4.isNotEmpty) {
      final digitsOnly = detailLast4.replaceAll(RegExp(r'[^0-9]'), '');
      if (digitsOnly.length >= 4) {
        return digitsOnly.substring(digitsOnly.length - 4);
      }
      return detailLast4;
    }

    final headerId =
        (row['transaction_header_id'] ?? row['header_id'] ?? row['id'])
            ?.toString()
            .trim() ??
        '';
    if (headerId.isNotEmpty) {
      final summary = _headerCardAuthSummary[headerId];
      final summaryLast4 = summary?['cardLast4']?.trim() ?? '';
      if (summaryLast4.isNotEmpty) return summaryLast4;
    }

    final candidates = [
      row['card_last4'],
      row['last4'],
      row['pan_last4'],
      row['masked_pan_last4'],
    ];
    for (final value in candidates) {
      final text = (value ?? '').toString().trim();
      if (text.isNotEmpty) {
        final digitsOnly = text.replaceAll(RegExp(r'[^0-9]'), '');
        if (digitsOnly.length >= 4) {
          return digitsOnly.substring(digitsOnly.length - 4);
        }
        return text;
      }
    }
    return '';
  }

  String _headerCardLast4(Map<String, dynamic> row) {
    final raw = _headerCardLast4Raw(row);
    if (raw.isNotEmpty) return raw;
    return '----';
  }

  String _headerAuthCodeRaw(Map<String, dynamic> row) {
    final detailAuth = row['auth_code']?.toString().trim() ?? '';
    if (detailAuth.isNotEmpty) return detailAuth;

    final headerId =
        (row['transaction_header_id'] ?? row['header_id'] ?? row['id'])
            ?.toString()
            .trim() ??
        '';
    if (headerId.isNotEmpty) {
      final summary = _headerCardAuthSummary[headerId];
      final summaryAuth = summary?['authCode']?.trim() ?? '';
      if (summaryAuth.isNotEmpty) return summaryAuth;
    }

    final candidates = [
      row['auth_code'],
      row['authorization_code'],
      row['auth'],
      row['approval_code'],
    ];
    for (final value in candidates) {
      final text = (value ?? '').toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _headerAuthCode(Map<String, dynamic> row) {
    final raw = _headerAuthCodeRaw(row);
    if (raw.isNotEmpty) return raw;
    return '------';
  }

  /// Returns 'c' (settled) or 'o' (open) for the batch status of this header's
  /// payment detail rows. Defaults to 'o' when no summary is available.
  String _headerBatchStatus(Map<String, dynamic> row) {
    final detailBatch =
        row['batch_status']?.toString().trim().toLowerCase() ?? '';
    if (detailBatch == 'c' || detailBatch == 'o') return detailBatch;

    final headerId =
        (row['transaction_header_id'] ?? row['header_id'] ?? row['id'])
            ?.toString()
            .trim() ??
        '';
    if (headerId.isEmpty) return 'o';
    return _headerCardAuthSummary[headerId]?['batchStatus'] ?? 'o';
  }

  String _csvEscape(dynamic value) {
    final raw = (value ?? '').toString();
    final escaped = raw.replaceAll('"', '""');
    return '"$escaped"';
  }

  String _buildHeaderReportText({required bool includeAllRows}) {
    final visibleHeaders = _visibleHeaders();
    final totalAmount = visibleHeaders.fold<double>(
      0,
      (sum, row) => sum + _summaryContribution(row),
    );
    final totalSurcharge = visibleHeaders.fold<double>(
      0,
      (sum, row) => sum + _summarySurchargeContribution(row),
    );
    final totalTipAdjustments = visibleHeaders.fold<double>(
      0,
      (sum, row) => sum + _summaryTipAdjustmentContribution(row),
    );
    final rows = includeAllRows
        ? visibleHeaders
        : visibleHeaders
              .take(visibleHeaders.length > 50 ? 50 : visibleHeaders.length)
              .toList();

    final lines = <String>[
      'VIEW TRANSACTIONS (EVENTS)',
      'Generated: ${DateTime.now().toLocal()}',
      'Range: $_datePreset',
      'Status: $_statusFilter',
      'Tender: $_tenderFilter',
      'Rows: ${visibleHeaders.length}',
      'Total Amount: \$${totalAmount.toStringAsFixed(2)}',
      'Total Surcharge: \$${totalSurcharge.toStringAsFixed(2)}',
      'Total Tip Adjustments: \$${totalTipAdjustments.toStringAsFixed(2)}',
      '',
    ];

    for (final row in rows) {
      final tender = _headerTenderKind(row);
      lines.add(
        '${_formatDateTime(row['created_at']?.toString())} | '
        '\$${_effectiveDisplayTotal(row).toStringAsFixed(2)} | '
        'Surcharge=\$${_headerSurchargeAmount(row).toStringAsFixed(2)} | '
        'TipAdj=\$${_headerTipAdjustmentAmount(row).toStringAsFixed(2)} | '
        '${_eventTypeLabel(row)} | '
        '${tender.toUpperCase()} | '
        '${_statusLabel(row['status']?.toString() ?? '')} | '
        'receipt_id=${_headerReceiptIdDisplay(row)} | '
        'header_id=${_effectiveHeaderId(row)} detail_id=${row['id']?.toString() ?? ''}',
      );
    }

    return lines.join('\n');
  }

  // ignore: unused_element
  Future<void> _copyReport({required bool fullReport}) async {
    final text = _buildHeaderReportText(includeAllRows: fullReport);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(fullReport ? 'Full report copied.' : 'Snapshot copied.'),
      ),
    );
  }

  String _buildHeadersCsv({required bool includeAllRows}) {
    final visibleHeaders = _visibleHeaders();
    final rows = includeAllRows
        ? visibleHeaders
        : visibleHeaders
              .take(visibleHeaders.length > 50 ? 50 : visibleHeaders.length)
              .toList();

    final lines = <String>[
      [
        'header_id',
        'detail_id',
        'event_type',
        'created_at',
        'tender',
        'status',
        'subtotal',
        'tax',
        'surcharge',
        'tip_adjustments',
        'total',
        'amount_paid',
        'amount_due',
        'staff_name',
        'terminal_name',
        'invoice_reference',
        'receipt_id',
      ].map(_csvEscape).join(','),
    ];

    for (final row in rows) {
      final record = [
        _effectiveHeaderId(row),
        row['id']?.toString() ?? '',
        _eventTypeLabel(row),
        row['created_at']?.toString() ?? '',
        _headerTenderKind(row),
        row['status']?.toString() ?? '',
        _asDouble(row['subtotal']).toStringAsFixed(2),
        _asDouble(row['tax']).toStringAsFixed(2),
        _headerSurchargeAmount(row).toStringAsFixed(2),
        _headerTipAdjustmentAmount(row).toStringAsFixed(2),
        _effectiveDisplayTotal(row).toStringAsFixed(2),
        _asDouble(row['amount_paid']).toStringAsFixed(2),
        _asDouble(row['amount_due']).toStringAsFixed(2),
        row['staff_name']?.toString() ?? '',
        row['terminal_name']?.toString() ?? '',
        row['invoice_reference']?.toString() ?? '',
        _headerReceiptIdDisplay(row),
      ];
      lines.add(record.map(_csvEscape).join(','));
    }

    return lines.join('\n');
  }

  // ignore: unused_element
  Future<void> _copyCsv({required bool fullReport}) async {
    await Clipboard.setData(
      ClipboardData(text: _buildHeadersCsv(includeAllRows: fullReport)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(fullReport ? 'Full CSV copied.' : 'Snapshot CSV copied.'),
      ),
    );
  }

  String _todayStamp() {
    final now = DateTime.now();
    final yyyy = now.year.toString();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd';
  }

  String _reportBaseName(_PrintExportType type) {
    final date = _todayStamp();
    if (type == _PrintExportType.summary) {
      return 'Transaction Summary ($date)';
    }
    return 'Transaction Details ($date)';
  }

  Future<String?> _downloadTextFile({
    required String content,
    required String fileName,
    required String mimeType,
  }) async {
    return saveTextFile(
      content: content,
      fileName: fileName,
      mimeType: mimeType,
      saveToDownloads: true,
    ).timeout(const Duration(seconds: 60));
  }

  Future<Map<String, List<Map<String, dynamic>>>> _loadDetailsByHeaderId(
    List<Map<String, dynamic>> headers,
  ) async {
    final result = <String, List<Map<String, dynamic>>>{};
    final headerIds = headers
        .map(_effectiveHeaderId)
        .where((id) => id.isNotEmpty)
        .toSet();
    const batchSize = 6;
    final ids = headerIds.toList(growable: false);
    for (var i = 0; i < ids.length; i += batchSize) {
      final end = (i + batchSize > ids.length) ? ids.length : i + batchSize;
      final batch = ids.sublist(i, end);

      final fetched = await Future.wait(
        batch.map((headerId) async {
          try {
            final details = await _service
                .getTransactionDetailsForHeader(headerId)
                .timeout(const Duration(seconds: 12));
            return MapEntry(headerId, details);
          } catch (_) {
            return MapEntry(headerId, const <Map<String, dynamic>>[]);
          }
        }),
      );

      for (final entry in fetched) {
        result[entry.key] = entry.value;
      }

      // Yield periodically so large exports don't starve the UI isolate.
      await Future<void>.delayed(Duration.zero);
    }
    return result;
  }

  String _buildSummaryCsvFromRows(List<Map<String, dynamic>> rows) {
    final lines = <String>[
      [
        'header_id',
        'detail_id',
        'event_type',
        'created_at',
        'tender',
        'status',
        'subtotal',
        'tax',
        'surcharge',
        'tip_adjustments',
        'total',
        'amount_paid',
        'amount_due',
        'staff_name',
        'terminal_name',
        'invoice_reference',
        'receipt_id',
      ].map(_csvEscape).join(','),
    ];

    for (final row in rows) {
      lines.add(
        [
          _effectiveHeaderId(row),
          row['id']?.toString() ?? '',
          _eventTypeLabel(row),
          row['created_at']?.toString() ?? '',
          _headerTenderKind(row),
          row['status']?.toString() ?? '',
          _asDouble(row['subtotal']).toStringAsFixed(2),
          _asDouble(row['tax']).toStringAsFixed(2),
          _headerSurchargeAmount(row).toStringAsFixed(2),
          _headerTipAdjustmentAmount(row).toStringAsFixed(2),
          _effectiveDisplayTotal(row).toStringAsFixed(2),
          _asDouble(row['amount_paid']).toStringAsFixed(2),
          _asDouble(row['amount_due']).toStringAsFixed(2),
          row['staff_name']?.toString() ?? '',
          row['terminal_name']?.toString() ?? '',
          row['invoice_reference']?.toString() ?? '',
          _headerReceiptIdDisplay(row),
        ].map(_csvEscape).join(','),
      );
    }

    return lines.join('\n');
  }

  Future<String> _buildDetailsCsvFromRows(
    List<Map<String, dynamic>> rows,
  ) async {
    final detailsByHeader = await _loadDetailsByHeaderId(rows);
    final lines = <String>[
      [
        'header_id',
        'header_created_at',
        'header_tender',
        'header_status',
        'header_total',
        'header_surcharge',
        'header_tip_adjustments',
        'staff_name',
        'terminal_name',
        'invoice_reference',
        'header_receipt_id',
        'detail_id',
        'detail_created_at',
        'payment_type',
        'status',
        'subtype',
        'amount',
        'detail_surcharge',
        'detail_tip_adjustments',
        'reference_id',
        'auth_code',
        'card_last4',
        'card_type',
        'detail_receipt_id',
      ].map(_csvEscape).join(','),
    ];

    for (final row in rows) {
      final headerId = _effectiveHeaderId(row);
      final details =
          detailsByHeader[headerId] ?? const <Map<String, dynamic>>[];
      if (details.isEmpty) {
        lines.add(
          [
            headerId,
            row['header_created_at']?.toString() ??
                row['created_at']?.toString() ??
                '',
            _headerTenderKind(row),
            row['header_status']?.toString() ?? row['status']?.toString() ?? '',
            _effectiveDisplayTotal(row).toStringAsFixed(2),
            _headerSurchargeAmount(row).toStringAsFixed(2),
            _headerTipAdjustmentAmount(row).toStringAsFixed(2),
            row['staff_name']?.toString() ?? '',
            row['terminal_name']?.toString() ?? '',
            row['invoice_reference']?.toString() ?? '',
            _headerReceiptIdDisplay(row),
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
          ].map(_csvEscape).join(','),
        );
        if (lines.length % 40 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        continue;
      }

      for (final detail in details) {
        lines.add(
          [
            headerId,
            row['created_at']?.toString() ?? '',
            _headerTenderKind(row),
            row['status']?.toString() ?? '',
            _effectiveDisplayTotal(row).toStringAsFixed(2),
            _headerSurchargeAmount(row).toStringAsFixed(2),
            _headerTipAdjustmentAmount(row).toStringAsFixed(2),
            row['staff_name']?.toString() ?? '',
            row['terminal_name']?.toString() ?? '',
            row['invoice_reference']?.toString() ?? '',
            _headerReceiptIdDisplay(row),
            detail['id']?.toString() ?? '',
            detail['created_at']?.toString() ?? '',
            detail['payment_type']?.toString() ?? '',
            detail['status']?.toString() ?? '',
            detail['subtype']?.toString() ?? '',
            _asDouble(detail['amount']).toStringAsFixed(2),
            _detailSurchargeAmount(detail).toStringAsFixed(2),
            _detailTipAdjustmentAmount(detail).toStringAsFixed(2),
            detail['reference_id']?.toString() ?? '',
            detail['auth_code']?.toString() ?? '',
            detail['card_last4']?.toString() ?? '',
            detail['card_type']?.toString() ?? '',
            formatReceiptIdForDisplay(detail['receipt_id']?.toString() ?? ''),
          ].map(_csvEscape).join(','),
        );
        if (lines.length % 40 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    }

    return lines.join('\n');
  }

  void _showPrintExportDialog() {
    if (_printExportInProgress) return;
    setState(() {
      _showPrintExportModal = true;
      _printExportSelection = _PrintExportType.summary;
    });
  }

  void _closePrintExportDialog() {
    if (_printExportInProgress) return;
    setState(() {
      _showPrintExportModal = false;
    });
  }

  Future<void> _runPrintExportAction({required bool export}) async {
    if (_printExportInProgress) return;
    final selected = _printExportSelection;
    setState(() {
      _printExportInProgress = true;
      _showPrintExportModal = false;
    });
    try {
      if (export) {
        await _exportCsvFile(selected);
        return;
      }
      await _printReport(selected);
    } finally {
      if (mounted) {
        setState(() {
          _printExportInProgress = false;
        });
      }
    }
  }

  Future<void> _exportCsvFile(_PrintExportType type) async {
    final rows = _visibleHeaders();
    if (rows.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No transactions available to export.')),
      );
      return;
    }

    final fileBase = _reportBaseName(type);
    try {
      final csv = type == _PrintExportType.summary
          ? _buildSummaryCsvFromRows(rows)
          : await _buildDetailsCsvFromRows(rows);

      final savedPath = await _downloadTextFile(
        content: csv,
        fileName: '$fileBase.csv',
        mimeType: 'text/csv;charset=utf-8',
      );

      if (!mounted) return;
      if (savedPath == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('CSV export cancelled.')));
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('CSV exported: $fileBase.csv')));
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'CSV export timed out. Please retry with a smaller date range.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('CSV export failed: $e')));
    }
  }

  Future<void> _printReport(_PrintExportType type) async {
    final rows = _visibleHeaders();
    if (rows.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No transactions available to print.')),
      );
      return;
    }

    final fileBase = _reportBaseName(type);
    try {
      await Printing.layoutPdf(
        name: fileBase,
        format: PdfPageFormat.letter,
        onLayout: (_) async {
          final doc = pw.Document(title: fileBase);

          if (type == _PrintExportType.summary) {
            // Look up location names for all unique location_ids in the rows.
            final locationIds = rows
                .map((r) => r['location_id']?.toString().trim() ?? '')
                .where((id) => id.isNotEmpty)
                .toSet()
                .toList();
            final locationNames = await _service.getLocationNamesByIds(
              locationIds,
            );

            doc.addPage(
              pw.MultiPage(
                pageFormat: PdfPageFormat.letter,
                margin: const pw.EdgeInsets.all(24),
                build: (context) {
                  final totalAmount = rows.fold<double>(
                    0,
                    (sum, row) => sum + _summaryContribution(row),
                  );
                  final totalSurcharge = rows.fold<double>(
                    0,
                    (sum, row) => sum + _summarySurchargeContribution(row),
                  );
                  final totalTipAdjustments = rows.fold<double>(
                    0,
                    (sum, row) => sum + _summaryTipAdjustmentContribution(row),
                  );
                  return [
                    pw.Text(
                      fileBase,
                      style: pw.TextStyle(
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      'Generated: ${DateTime.now().toLocal()}',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                    pw.Text(
                      'Rows: ${rows.length}',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                    pw.Text(
                      'Total Amount: \$${totalAmount.toStringAsFixed(2)}',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                    pw.Text(
                      'Total Surcharge: \$${totalSurcharge.toStringAsFixed(2)}',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                    pw.Text(
                      'Total Tip Adjustments: \$${totalTipAdjustments.toStringAsFixed(2)}',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                    pw.SizedBox(height: 8),
                    pw.TableHelper.fromTextArray(
                      border: null,
                      headerStyle: pw.TextStyle(
                        fontSize: 8,
                        fontWeight: pw.FontWeight.bold,
                      ),
                      cellStyle: const pw.TextStyle(fontSize: 8),
                      headers: const [
                        'Date/Time',
                        'Receipt ID',
                        'Name',
                        'Terminal',
                        'Status',
                        'Tender',
                        'Surcharge',
                        'Tip Adj',
                        'Total',
                      ],
                      data: rows.map((row) {
                        final locId =
                            row['location_id']?.toString().trim() ?? '';
                        final locName = locId.isNotEmpty
                            ? (locationNames[locId] ?? locId)
                            : '';
                        return [
                          _formatDateTime(row['created_at']?.toString()),
                          _headerReceiptIdDisplay(row),
                          locName,
                          row['terminal_name']?.toString() ?? '',
                          _statusLabel(row['status']?.toString() ?? ''),
                          _headerTenderKind(row).toUpperCase(),
                          _headerSurchargeAmount(row).toStringAsFixed(2),
                          _headerTipAdjustmentAmount(row).toStringAsFixed(2),
                          _effectiveDisplayTotal(row).toStringAsFixed(2),
                        ];
                      }).toList(),
                    ),
                  ];
                },
              ),
            );
          } else {
            final detailsByHeader = await _loadDetailsByHeaderId(rows);
            doc.addPage(
              pw.MultiPage(
                pageFormat: PdfPageFormat.letter,
                margin: const pw.EdgeInsets.all(24),
                build: (context) {
                  final widgets = <pw.Widget>[
                    pw.Text(
                      fileBase,
                      style: pw.TextStyle(
                        fontSize: 16,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 6),
                    pw.Text('Generated: ${DateTime.now().toLocal()}'),
                    pw.Text('Headers: ${rows.length}'),
                    pw.SizedBox(height: 10),
                  ];

                  for (final header in rows) {
                    final headerId = _effectiveHeaderId(header);
                    final details =
                        detailsByHeader[headerId] ??
                        const <Map<String, dynamic>>[];
                    widgets.add(
                      pw.Container(
                        padding: const pw.EdgeInsets.all(8),
                        decoration: pw.BoxDecoration(
                          border: pw.Border.all(width: 0.5),
                        ),
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text(
                              'Header $headerId  ${_formatDateTime(header['created_at']?.toString())}',
                              style: pw.TextStyle(
                                fontSize: 11,
                                fontWeight: pw.FontWeight.bold,
                              ),
                            ),
                            pw.Text(
                              'Receipt ID: ${_headerReceiptIdDisplay(header)}',
                              style: const pw.TextStyle(fontSize: 10),
                            ),
                            pw.SizedBox(height: 2),
                            pw.Text(
                              'Status: ${_statusLabel(header['status']?.toString() ?? '')}  Tender: ${_headerTenderKind(header).toUpperCase()}  Surcharge: \$${_headerSurchargeAmount(header).toStringAsFixed(2)}  Tip Adj: \$${_headerTipAdjustmentAmount(header).toStringAsFixed(2)}  Total: \$${_effectiveDisplayTotal(header).toStringAsFixed(2)}',
                              style: const pw.TextStyle(fontSize: 10),
                            ),
                            pw.Text(
                              'Staff: ${header['staff_name'] ?? ''}  Terminal: ${header['terminal_name'] ?? ''}  Ref: ${header['invoice_reference'] ?? ''}',
                              style: const pw.TextStyle(fontSize: 10),
                            ),
                            pw.SizedBox(height: 6),
                            if (details.isEmpty)
                              pw.Text(
                                'No detail rows.',
                                style: const pw.TextStyle(fontSize: 10),
                              )
                            else
                              pw.TableHelper.fromTextArray(
                                headers: const [
                                  '#',
                                  'Type',
                                  'Status',
                                  'Subtype',
                                  'Amount',
                                  'Surcharge',
                                  'Tip Adj',
                                  'Ref/Auth',
                                ],
                                data: List.generate(details.length, (index) {
                                  final d = details[index];
                                  final ref =
                                      d['reference_id']?.toString() ?? '';
                                  final auth = d['auth_code']?.toString() ?? '';
                                  final refAuth = [ref, auth]
                                      .where((v) => v.trim().isNotEmpty)
                                      .join(' / ');
                                  return [
                                    '${index + 1}',
                                    _paymentTypeLabel(
                                      d['payment_type']?.toString() ?? '',
                                    ).toUpperCase(),
                                    d['status']?.toString() ?? '',
                                    d['subtype']?.toString() ?? '',
                                    _asDouble(d['amount']).toStringAsFixed(2),
                                    _detailSurchargeAmount(
                                      d,
                                    ).toStringAsFixed(2),
                                    _detailTipAdjustmentAmount(
                                      d,
                                    ).toStringAsFixed(2),
                                    refAuth,
                                  ];
                                }),
                              ),
                          ],
                        ),
                      ),
                    );
                    widgets.add(pw.SizedBox(height: 8));
                  }
                  return widgets;
                },
              ),
            );
          }

          return doc.save();
        },
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Printer dialog opened. Select printer and paper size there.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open printer dialog: $e')),
      );
    }
  }

  Future<Uint8List> _buildReprintReceiptPdfBytes({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> details,
    PdfPageFormat? format,
  }) async {
    final pdf = pw.Document();
    final resolvedFormat =
        format ??
        const PdfPageFormat(
          3.25 * PdfPageFormat.inch,
          11 * PdfPageFormat.inch,
          marginLeft: 0,
          marginRight: 0,
          marginTop: 0,
          marginBottom: 0,
        );
    final created = DateTime.tryParse(
      header['created_at']?.toString() ?? '',
    )?.toLocal();
    final receiptId = _headerReceiptIdDisplay(header);
    final eventType = _eventTypeLabel(header);
    final tender = _headerTenderKind(header).toUpperCase();
    final status = _statusLabel(
      header['status']?.toString() ?? '',
    ).toUpperCase();
    final customerData = _extractReprintCustomerTrackingData(
      header: header,
      details: details,
    );
    final surchargeAmount = (() {
      final headerValue = _asDouble(
        header['surcharge_amount'] ?? header['fee_amount'],
      ).abs();
      if (headerValue > 0.000001) return headerValue;

      for (final detail in details) {
        final subtype = (detail['subtype']?.toString().toLowerCase() ?? '')
            .trim();
        if (subtype != 's') continue;
        final amount = _asDouble(
          detail['surcharge_amount'] ?? detail['fee_amount'],
        ).abs();
        if (amount > 0.000001) return amount;
      }
      return 0.0;
    })();
    final tipAdjustmentAmount = (() {
      final headerValue = _asDouble(header['tip_adjustment_total']);
      if (headerValue.abs() > 0.000001) return headerValue;

      var sum = 0.0;
      for (final detail in details) {
        final subtype = (detail['subtype']?.toString().toLowerCase() ?? '')
            .trim();
        final status = (detail['status']?.toString().toLowerCase() ?? '')
            .trim();
        final originalId =
            detail['original_detail_id']?.toString().trim() ?? '';
        if (subtype == 'a' && status == 'approved' && originalId.isNotEmpty) {
          sum += _asDouble(detail['amount']);
        }
      }
      return sum;
    })();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: resolvedFormat,
        margin: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 72),
        build: (_) {
          final widgets = <pw.Widget>[
            pw.Center(
              child: pw.Text(
                'TRANSACTION REPRINT',
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Receipt ID: $receiptId',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            if (created != null)
              pw.Text(
                'Date: ${_formatDateTime(header['created_at']?.toString())}',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            pw.Text(
              'Event: $eventType  Status: $status',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            pw.Text(
              'Tender: $tender',
              style: const pw.TextStyle(fontSize: 8.5),
            ),
            if ((header['terminal_name']?.toString() ?? '').trim().isNotEmpty)
              pw.Text(
                'Terminal: ${header['terminal_name']}',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            if ((header['staff_name']?.toString() ?? '').trim().isNotEmpty)
              pw.Text(
                'Staff: ${header['staff_name']}',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            if ((header['invoice_reference']?.toString() ?? '')
                .trim()
                .isNotEmpty)
              pw.Text(
                'Invoice/Reference: ${header['invoice_reference']}',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            ..._buildReprintCustomerTrackingWidgets(customerData),
            pw.SizedBox(height: 4),
            pw.Divider(thickness: 0.6),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('Subtotal', style: const pw.TextStyle(fontSize: 8.5)),
                pw.Text(
                  '\$${_asDouble(header['subtotal']).toStringAsFixed(2)}',
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
              ],
            ),
            if (surchargeAmount > 0.000001)
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Surcharge',
                    style: const pw.TextStyle(fontSize: 8.5),
                  ),
                  pw.Text(
                    '+\$${surchargeAmount.toStringAsFixed(2)}',
                    style: const pw.TextStyle(fontSize: 8.5),
                  ),
                ],
              ),
            if (tipAdjustmentAmount.abs() > 0.000001)
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Tip Adjustment',
                    style: const pw.TextStyle(fontSize: 8.5),
                  ),
                  pw.Text(
                    '${tipAdjustmentAmount >= 0 ? '+' : '-'}\$${tipAdjustmentAmount.abs().toStringAsFixed(2)}',
                    style: const pw.TextStyle(fontSize: 8.5),
                  ),
                ],
              ),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('Tax', style: const pw.TextStyle(fontSize: 8.5)),
                pw.Text(
                  '\$${_asDouble(header['tax']).toStringAsFixed(2)}',
                  style: const pw.TextStyle(fontSize: 8.5),
                ),
              ],
            ),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Total',
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  '\$${_effectiveDisplayTotal(header).toStringAsFixed(2)}',
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 4),
            pw.Divider(thickness: 0.6),
            pw.Text(
              'Detail Lines',
              style: pw.TextStyle(
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ];

          if (details.isEmpty) {
            widgets.add(
              pw.Text(
                'No detail rows.',
                style: const pw.TextStyle(fontSize: 8.5),
              ),
            );
          } else {
            for (final d in details) {
              final type = _paymentTypeLabel(
                d['payment_type']?.toString() ?? '',
              ).toUpperCase();
              final subtype = d['subtype']?.toString() ?? '';
              final amount = _asDouble(d['amount']);
              final ref = d['reference_id']?.toString() ?? '';
              final auth = d['auth_code']?.toString() ?? '';

              widgets.add(
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Expanded(
                      child: pw.Text(
                        [type, if (subtype.isNotEmpty) '($subtype)'].join(' '),
                        style: const pw.TextStyle(fontSize: 8.5),
                      ),
                    ),
                    pw.Text(
                      '\$${amount.toStringAsFixed(2)}',
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                  ],
                ),
              );

              if (ref.trim().isNotEmpty || auth.trim().isNotEmpty) {
                widgets.add(
                  pw.Text(
                    [
                      if (ref.trim().isNotEmpty) 'Ref: $ref',
                      if (auth.trim().isNotEmpty) 'Auth: $auth',
                    ].join('  '),
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                );
              }
              widgets.add(pw.SizedBox(height: 2));
            }
          }

          widgets.addAll([
            pw.SizedBox(height: 6),
            pw.Divider(thickness: 0.6),
            pw.SizedBox(height: 6),
            pw.Center(
              child: pw.Text(
                '*** REPRINT ***',
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
          ]);

          return widgets;
        },
      ),
    );

    return pdf.save();
  }

  String _preferredReprintValue(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final text = candidate?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _formatReprintPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 10) {
      return '(${digits.substring(0, 3)}) ${digits.substring(3, 6)}-${digits.substring(6)}';
    }
    if (digits.length == 11 && digits.startsWith('1')) {
      return '+1 (${digits.substring(1, 4)}) ${digits.substring(4, 7)}-${digits.substring(7)}';
    }
    return raw.trim();
  }

  String _formatReprintCustomerCityStateZip({
    required String city,
    required String state,
    required String zip,
  }) {
    final trimmedCity = city.trim();
    final trimmedState = state.trim();
    final trimmedZip = zip.trim();

    final cityState = trimmedCity.isNotEmpty && trimmedState.isNotEmpty
        ? '$trimmedCity, $trimmedState'
        : trimmedCity.isNotEmpty
        ? trimmedCity
        : trimmedState;

    if (trimmedZip.isEmpty) return cityState;
    if (cityState.isEmpty) return trimmedZip;
    return '$cityState $trimmedZip';
  }

  Map<String, dynamic> _extractReprintCustomerTrackingData({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> details,
  }) {
    dynamic snapshotRaw = header['customer_snapshot'];
    if (snapshotRaw == null) {
      for (final detail in details) {
        final nested = detail['transaction_headers'];
        if (nested is Map && nested['customer_snapshot'] != null) {
          snapshotRaw = nested['customer_snapshot'];
          break;
        }
      }
    }

    final merged = <String, dynamic>{};
    if (snapshotRaw is Map) {
      merged.addAll(Map<String, dynamic>.from(snapshotRaw));
    } else if (snapshotRaw is String) {
      try {
        final decoded = jsonDecode(snapshotRaw);
        if (decoded is Map) {
          merged.addAll(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // Ignore malformed snapshot payloads.
      }
    }

    for (final entry in header.entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }

    final invoiceReference = _preferredReprintValue([
      merged['invoice_reference'],
      header['invoice_reference'],
    ]);
    if (invoiceReference.isNotEmpty) {
      merged['invoice_reference'] = invoiceReference;
    }

    return merged;
  }

  List<pw.Widget> _buildReprintCustomerTrackingWidgets(
    Map<String, dynamic> data,
  ) {
    final firstName = _preferredReprintValue([
      data['first_name'],
      data['firstName'],
    ]);
    final lastName = _preferredReprintValue([
      data['last_name'],
      data['lastName'],
    ]);
    final fullName = _preferredReprintValue([
      '$firstName $lastName',
      data['name'],
      data['customer_name'],
      data['customerName'],
    ]);
    final address1 = _preferredReprintValue([
      data['address_1'],
      data['address1'],
      data['street'],
    ]);
    final address2 = _preferredReprintValue([
      data['address_2'],
      data['address2'],
    ]);
    final city = _preferredReprintValue([data['city']]);
    final state = _preferredReprintValue([data['state']]);
    final zip = _preferredReprintValue([
      data['zip'],
      data['postal_code'],
      data['postalCode'],
    ]);
    final cityStateZip = _formatReprintCustomerCityStateZip(
      city: city,
      state: state,
      zip: zip,
    );
    final customerId = _preferredReprintValue([
      data['customer_number'],
      data['customer_id'],
      data['customerId'],
    ]);
    final phone = _preferredReprintValue([
      data['phone'],
      data['phone_number'],
      data['phoneNumber'],
    ]);
    final email = _preferredReprintValue([data['email']]);
    final invoiceReference = _preferredReprintValue([
      data['invoice_reference'],
      data['invoiceReference'],
    ]);

    final otherLines = <String>[
      if (customerId.isNotEmpty) 'Customer ID: $customerId',
      if (phone.isNotEmpty) 'Phone: ${_formatReprintPhone(phone)}',
      if (email.isNotEmpty) 'Email: $email',
      if (invoiceReference.isNotEmpty) 'Invoice/Reference: $invoiceReference',
    ];

    final hasTrackingData =
        fullName.isNotEmpty ||
        address1.isNotEmpty ||
        address2.isNotEmpty ||
        cityStateZip.isNotEmpty ||
        otherLines.isNotEmpty;
    if (!hasTrackingData) return const <pw.Widget>[];

    final widgets = <pw.Widget>[
      pw.SizedBox(height: 2),
      pw.Text(
        'Customer / Tracking info',
        style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
      ),
      if (fullName.isNotEmpty)
        pw.Text(fullName, style: const pw.TextStyle(fontSize: 8.5)),
      if (address1.isNotEmpty)
        pw.Text(address1, style: const pw.TextStyle(fontSize: 8.5)),
      if (address2.isNotEmpty)
        pw.Text(address2, style: const pw.TextStyle(fontSize: 8.5)),
      if (cityStateZip.isNotEmpty)
        pw.Text(cityStateZip, style: const pw.TextStyle(fontSize: 8.5)),
      ...otherLines.map(
        (line) => pw.Text(line, style: const pw.TextStyle(fontSize: 8.5)),
      ),
      pw.SizedBox(height: 4),
    ];

    return widgets;
  }

  Future<void> _emailReprintReceiptPdf({
    required String recipientEmail,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> details,
  }) async {
    final bytes = await _buildReprintReceiptPdfBytes(
      header: header,
      details: details,
    );

    final filename =
        'pregister-reprint-${DateTime.now().millisecondsSinceEpoch}.pdf';
    final amount = _effectiveDisplayTotal(header);
    final locationText =
        (header['location_name']?.toString().trim().isNotEmpty ?? false)
        ? header['location_name'].toString().trim()
        : ((header['location_id']?.toString().trim().isNotEmpty ?? false)
              ? header['location_id'].toString().trim()
              : 'your location');

    await _service.emailReceiptPdf(
      recipientEmail: recipientEmail,
      pdfBytes: bytes,
      filename: filename,
      subject: 'Your Receipt Reprint',
      textBody:
          'Location Name: $locationText\n'
          'Your receipt reprint for '
          '\$${amount.toStringAsFixed(2)} is attached.',
    );
  }

  bool _isValidReprintEmailFormat(String value) {
    final email = value.trim();
    if (email.isEmpty) return false;
    final match = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email);
    return match;
  }

  // ignore: unused_element
  Future<void> _printReprintCustomerCopy({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> details,
  }) async {
    final bytes = await _buildReprintReceiptPdfBytes(
      header: header,
      details: details,
    );
    final receiptId = _headerReceiptIdDisplay(header);
    await Printing.layoutPdf(
      name: 'Reprint Receipt - $receiptId',
      format: const PdfPageFormat(
        3.25 * PdfPageFormat.inch,
        11 * PdfPageFormat.inch,
        marginLeft: 0,
        marginRight: 0,
        marginTop: 0,
        marginBottom: 0,
      ),
      onLayout: (_) async => bytes,
    );
  }

  Map<String, String> _extractReprintCardMeta({
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> details,
  }) {
    for (final detail in details) {
      final cardType = detail['card_type']?.toString().trim() ?? '';
      final cardLast4 = detail['card_last4']?.toString().trim() ?? '';
      final authCode = detail['auth_code']?.toString().trim() ?? '';
      final paymentType = _paymentTypeLabel(
        detail['payment_type']?.toString() ?? '',
      ).trim();
      if (cardType.isNotEmpty || cardLast4.isNotEmpty || authCode.isNotEmpty) {
        return {
          'cardType': cardType.isNotEmpty ? cardType : paymentType,
          'cardLast4': cardLast4,
          'authCode': authCode,
        };
      }
    }

    return {
      'cardType': _headerTenderKind(header).toUpperCase(),
      'cardLast4': '',
      'authCode': '',
    };
  }

  Future<void> _reprintReceiptForRow(Map<String, dynamic> row) async {
    final headerId = _effectiveHeaderId(row);
    if (headerId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to reprint: missing header id.')),
      );
      return;
    }

    try {
      final details = await _service.getTransactionDetailsForHeader(headerId);
      if (!mounted) return;

      final customerData = _extractReprintCustomerTrackingData(
        header: row,
        details: details,
      );
      final cardMeta = _extractReprintCardMeta(header: row, details: details);

      // Capture methods as closures so they survive after this widget closes.
      Future<Uint8List> buildPdf(PdfPageFormat fmt) {
        return _buildReprintReceiptPdfBytes(
          header: row,
          details: details,
          format: fmt,
        );
      }

      Future<void> emailPdf(String email) {
        return _emailReprintReceiptPdf(
          recipientEmail: email,
          header: row,
          details: details,
        );
      }

      final isValidEmail = _isValidReprintEmailFormat;

      // Insert the reprint overlay entry ABOVE the transaction list overlay,
      // then immediately close the transaction list.
      final rootOverlay = Overlay.of(context, rootOverlay: true);
      late OverlayEntry reprintEntry;
      reprintEntry = OverlayEntry(
        builder: (_) => _ReprintOverlayWidget(
          header: row,
          customerData: customerData,
          cardMeta: cardMeta,
          buildReceiptPdfBytes: buildPdf,
          emailReceiptPdf: emailPdf,
          isValidEmail: isValidEmail,
          onClose: () => reprintEntry.remove(),
        ),
      );

      rootOverlay.insert(reprintEntry);
      widget.onClose?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to reprint receipt: $e')));
    }
  }

  // ignore: unused_element
  Future<void> _applyCashActivityPreset() async {
    setState(() {
      _statusFilter = 'closed';
      _tenderFilter = 'cash';
    });
    await _loadHeaders();
  }

  Future<void> _resetFilters() async {
    final now = DateTime.now();
    setState(() {
      _datePreset = 'all';
      _statusFilter = 'all';
      _tenderFilter = 'all';
      _customFromDate = DateTime(now.year, now.month, now.day);
      _customToDate = DateTime(now.year, now.month, now.day);
      _minAmountFilter = null;
      _maxAmountFilter = null;
      _cardFilter = '';
      _authFilter = '';
      _minAmountController.clear();
      _maxAmountController.clear();
      _cardFilterController.clear();
      _authFilterController.clear();
      _syncCustomDateText();
    });
    await _loadHeaders();
  }

  String _currentRangeLabel() {
    if (_datePreset == 'all') {
      return 'Date: All';
    }
    final range = _resolveRange(_datePreset);
    final from = _formatDateOnly(range.$1);
    final to = _formatDateOnly(range.$2);
    if (from == to) {
      return 'Date: $from';
    }
    return 'Date Range: $from - $to';
  }

  // Move all helper widget methods above build()
  Widget _buildMainContent(
    ColorScheme cs,
    List<Map<String, dynamic>> visibleHeaders,
  ) {
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
              child: Row(
                children: [
                  if (widget.embedded && widget.onClose != null) ...[
                    IconButton(
                      onPressed: widget.onClose,
                      icon: Icon(
                        Icons.arrow_back,
                        size: 20,
                        color: cs.onSurface,
                      ),
                      visualDensity: VisualDensity.compact,
                      splashRadius: 18,
                      tooltip: 'Back',
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      'Transactions List',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Expanded(
                    child: StandardActionButton(
                      label: 'Print/Export',
                      icon: Icons.print,
                      iconColor: const Color(0xFF1565C0),
                      iconBackgroundColor: const Color(0xFFE3F2FD),
                      small: true,
                      labelFontScale: 0.95,
                      onTap: _showPrintExportDialog,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: StandardActionButton(
                      label: 'Filters',
                      icon: Icons.filter_alt_outlined,
                      iconColor: const Color(0xFF2E7D32),
                      iconBackgroundColor: const Color(0xFFE8F5E9),
                      small: true,
                      labelFontScale: 0.95,
                      onTap: _openFiltersModal,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _currentRangeLabel(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 6),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: SelectableText(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : visibleHeaders.isEmpty
                  ? const Center(child: Text('No transactions found.'))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      itemCount: visibleHeaders.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final row = visibleHeaders[index];
                        final amount = _effectiveDisplayTotal(row);
                        final eventType = _eventTypeLabel(row);
                        final tender = _headerTenderKind(row);
                        final batchStatus = _headerBatchStatus(row);
                        final rowStatus =
                            (row['status']?.toString().toLowerCase() ?? '')
                                .trim();
                        final status = rowStatus == 'voided'
                            ? 'VOIDED'
                            : (batchStatus == 'c' ? 'SETTLED' : 'OPEN');
                        final created = _formatDateTime(
                          row['created_at']?.toString(),
                        );
                        final receiptId = _headerReceiptIdDisplay(row);

                        final cardLast4 = _headerCardLast4(row);
                        final authCode = _headerAuthCode(row);

                        return Material(
                          color: cs.surface,
                          borderRadius: BorderRadius.circular(10),
                          elevation: 0.6,
                          shadowColor: Colors.black26,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: cs.outlineVariant.withValues(
                                  alpha: 0.55,
                                ),
                                width: 1,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    6,
                                    4,
                                    6,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              created,
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                                color: cs.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: Center(
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    'Receipt ID: ',
                                                    style: TextStyle(
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color:
                                                          cs.onSurfaceVariant,
                                                    ),
                                                  ),
                                                  Text(
                                                    receiptId,
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: cs.onSurface,
                                                      letterSpacing: 0.25,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          Text(
                                            status,
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: batchStatus == 'c'
                                                  ? Colors.green.shade700
                                                  : const Color(0xFFB71C1C),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      Row(
                                        children: [
                                          Container(
                                            width: 20,
                                            height: 20,
                                            decoration: BoxDecoration(
                                              color: _tenderBackgroundColor(
                                                tender,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(7),
                                            ),
                                            child: Icon(
                                              _tenderIcon(tender),
                                              size: 12,
                                              color: _tenderColor(tender),
                                            ),
                                          ),
                                          const SizedBox(width: 5),
                                          Text(
                                            '\$${amount.toStringAsFixed(2)}',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w700,
                                              color: cs.onSurface,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color:
                                                  (eventType == 'VOID' ||
                                                      eventType == 'VOIDED')
                                                  ? const Color(0xFFFFEBEE)
                                                  : eventType == 'REFUND'
                                                  ? const Color(0xFFFFF3E0)
                                                  : const Color(0xFFE3F2FD),
                                              borderRadius:
                                                  BorderRadius.circular(7),
                                            ),
                                            child: Text(
                                              eventType,
                                              style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.w700,
                                                color:
                                                    (eventType == 'VOID' ||
                                                        eventType == 'VOIDED')
                                                    ? const Color(0xFFC62828)
                                                    : eventType == 'REFUND'
                                                    ? const Color(0xFFEF6C00)
                                                    : const Color(0xFF1565C0),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'Card: $cardLast4    Auth: $authCode',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: cs.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 1),
                                          IconButton(
                                            onPressed: () =>
                                                _reprintReceiptForRow(row),
                                            icon: const Icon(
                                              Icons.print,
                                              size: 16,
                                              color: Color(0xFF2E7D32),
                                            ),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(
                                              minWidth: 28,
                                              minHeight: 28,
                                            ),
                                            splashRadius: 14,
                                            tooltip: 'Reprint receipt',
                                          ),
                                          IconButton(
                                            onPressed: () =>
                                                _openDetailModal(row),
                                            icon: const Icon(
                                              Icons.receipt_long,
                                              size: 16,
                                              color: Color(0xFF1565C0),
                                            ),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(
                                              minWidth: 28,
                                              minHeight: 28,
                                            ),
                                            splashRadius: 14,
                                            tooltip: 'View details',
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
        if (_showFiltersModal)
          Positioned.fill(
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _closeFiltersModal,
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.28),
                      ),
                    ),
                  ),
                ),
                Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.98,
                    heightFactor: 0.92,
                    child: Material(
                      elevation: 16,
                      borderRadius: BorderRadius.circular(22),
                      color: cs.surface,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 960,
                            maxHeight: 900,
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      'Filters',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Date, status, and amount',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      icon: const Icon(Icons.close),
                                      onPressed: _closeFiltersModal,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                _buildChoiceRow(
                                  cs: cs,
                                  label: 'Range',
                                  icon: Icons.calendar_today_outlined,
                                  iconColor: const Color(0xFF1565C0),
                                  iconBackgroundColor: const Color(0xFFE3F2FD),
                                  selectedValue: _datePreset,
                                  options: const [
                                    MapEntry('all', 'All Dates'),
                                    MapEntry('today', 'Today'),
                                    MapEntry('last7', 'Last 7 Days'),
                                    MapEntry('last30', 'Last 30 Days'),
                                    MapEntry('custom', 'Custom'),
                                  ],
                                  onSelected: (value) =>
                                      setState(() => _datePreset = value),
                                ),
                                const SizedBox(height: 6),
                                _buildChoiceRow(
                                  cs: cs,
                                  label: 'Status',
                                  icon: Icons.tune,
                                  iconColor: const Color(0xFFEF6C00),
                                  iconBackgroundColor: const Color(0xFFFFF3E0),
                                  selectedValue: _statusFilter,
                                  options: const [
                                    MapEntry('all', 'All'),
                                    MapEntry('open', 'Open'),
                                    MapEntry('closed', 'Closed'),
                                    MapEntry('voided', 'Voided'),
                                  ],
                                  onSelected: (value) =>
                                      setState(() => _statusFilter = value),
                                ),
                                const SizedBox(height: 6),
                                _buildChoiceRow(
                                  cs: cs,
                                  label: 'Tender',
                                  icon: Icons.account_balance_wallet_outlined,
                                  iconColor: const Color(0xFF6A1B9A),
                                  iconBackgroundColor: const Color(0xFFF3E5F5),
                                  selectedValue: _tenderFilter,
                                  options: const [
                                    MapEntry('all', 'All'),
                                    MapEntry('cash', 'Cash'),
                                    MapEntry('card', 'Card'),
                                    MapEntry('mixed', 'Mixed'),
                                  ],
                                  onSelected: (value) =>
                                      setState(() => _tenderFilter = value),
                                ),
                                const SizedBox(height: 8),
                                _buildAmountFilterCard(cs),
                                const SizedBox(height: 6),
                                _buildCardAuthFilterCard(cs),
                                if (_datePreset == 'custom') ...[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _buildCustomDateInput(
                                        label: 'From',
                                        controller: _customFromController,
                                        onCalendarTap: () =>
                                            _toggleInlineCalendar(
                                              fromDate: true,
                                            ),
                                        onSubmitted: (value) =>
                                            _updateCustomDateFromText(
                                              fromDate: true,
                                              raw: value,
                                            ),
                                      ),
                                      _buildCustomDateInput(
                                        label: 'To',
                                        controller: _customToController,
                                        onCalendarTap: () =>
                                            _toggleInlineCalendar(
                                              fromDate: false,
                                            ),
                                        onSubmitted: (value) =>
                                            _updateCustomDateFromText(
                                              fromDate: false,
                                              raw: value,
                                            ),
                                      ),
                                    ],
                                  ),
                                  if (_showInlineCalendar) ...[
                                    const SizedBox(height: 8),
                                    StandardPanel(
                                      padding: const EdgeInsets.all(10),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: cs.surfaceContainerLow,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        padding: const EdgeInsets.all(8),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Text(
                                                  _inlineCalendarForFromDate
                                                      ? 'Select From Date'
                                                      : 'Select To Date',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                    color: cs.onSurface,
                                                  ),
                                                ),
                                                const Spacer(),
                                                IconButton(
                                                  icon: const Icon(
                                                    Icons.close,
                                                    size: 16,
                                                  ),
                                                  onPressed: () => setState(
                                                    () => _showInlineCalendar =
                                                        false,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            Container(
                                              decoration: BoxDecoration(
                                                color:
                                                    cs.surfaceContainerHighest,
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: cs.outlineVariant,
                                                ),
                                              ),
                                              padding: const EdgeInsets.all(6),
                                              child: SizedBox(
                                                height: 225,
                                                child: Theme(
                                                  data: Theme.of(context).copyWith(
                                                    textTheme: Theme.of(context)
                                                        .textTheme
                                                        .copyWith(
                                                          bodySmall:
                                                              const TextStyle(
                                                                fontSize: 12,
                                                              ), // day number
                                                        ),
                                                  ),
                                                  child: CalendarDatePicker(
                                                    initialDate:
                                                        _inlineCalendarForFromDate
                                                        ? (_customFromDate ??
                                                              DateTime.now())
                                                        : (_customToDate ??
                                                              _customFromDate ??
                                                              DateTime.now()),
                                                    firstDate: DateTime(
                                                      2020,
                                                      1,
                                                      1,
                                                    ),
                                                    lastDate: DateTime(
                                                      2100,
                                                      12,
                                                      31,
                                                    ),
                                                    onDateChanged:
                                                        _applyInlineCalendarDate,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                                const SizedBox(height: 12),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    final compact = constraints.maxWidth < 380;
                                    final applyButton = StandardActionButton(
                                      label: 'Apply Filters',
                                      icon: Icons.check,
                                      iconColor: const Color(0xFF2E7D32),
                                      iconBackgroundColor: const Color(
                                        0xFFE8F5E9,
                                      ),
                                      onTap: _loading
                                          ? null
                                          : () {
                                              setState(() {
                                                _syncAmountFiltersFromText();
                                                _syncCardAuthFiltersFromText();
                                              });
                                              _closeFiltersModal();
                                              _loadHeaders();
                                            },
                                    );
                                    final resetButton = StandardActionButton(
                                      label: 'Reset Filters',
                                      icon: Icons.restart_alt,
                                      iconColor: const Color(0xFFEF6C00),
                                      iconBackgroundColor: const Color(
                                        0xFFFFF3E0,
                                      ),
                                      onTap: _loading
                                          ? null
                                          : () {
                                              _resetFilters();
                                              _closeFiltersModal();
                                            },
                                    );

                                    if (compact) {
                                      return Column(
                                        children: [
                                          SizedBox(
                                            width: double.infinity,
                                            child: applyButton,
                                          ),
                                          const SizedBox(height: 8),
                                          SizedBox(
                                            width: double.infinity,
                                            child: resetButton,
                                          ),
                                        ],
                                      );
                                    }

                                    return Row(
                                      children: [
                                        Expanded(child: applyButton),
                                        const SizedBox(width: 10),
                                        Expanded(child: resetButton),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_showPrintExportModal)
          Positioned.fill(
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _closePrintExportDialog,
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.26),
                      ),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Material(
                      elevation: 18,
                      borderRadius: BorderRadius.circular(16),
                      color: cs.surface,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Print / Export Transactions',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: cs.onSurface,
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: _printExportInProgress
                                      ? null
                                      : _closePrintExportDialog,
                                ),
                              ],
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: SegmentedButton<_PrintExportType>(
                                segments: const [
                                  ButtonSegment<_PrintExportType>(
                                    value: _PrintExportType.summary,
                                    label: Text('Transaction Summary'),
                                  ),
                                  ButtonSegment<_PrintExportType>(
                                    value: _PrintExportType.details,
                                    label: Text('Transaction Details'),
                                  ),
                                ],
                                selected: {_printExportSelection},
                                onSelectionChanged: _printExportInProgress
                                    ? null
                                    : (selection) {
                                        if (selection.isEmpty) return;
                                        setState(
                                          () => _printExportSelection =
                                              selection.first,
                                        );
                                      },
                                showSelectedIcon: false,
                                multiSelectionEnabled: false,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: StandardActionButton(
                                    label: 'Print',
                                    icon: Icons.print,
                                    iconColor: const Color(0xFF1565C0),
                                    iconBackgroundColor: const Color(
                                      0xFFE3F2FD,
                                    ),
                                    onTap: _printExportInProgress
                                        ? null
                                        : () => _runPrintExportAction(
                                            export: false,
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: StandardActionButton(
                                    label: 'Export CSV',
                                    icon: Icons.download,
                                    iconColor: const Color(0xFF2E7D32),
                                    iconBackgroundColor: const Color(
                                      0xFFE8F5E9,
                                    ),
                                    onTap: _printExportInProgress
                                        ? null
                                        : () => _runPrintExportAction(
                                            export: true,
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_showDetailModal && _modalHeader != null)
          _buildDetailModalOverlay(cs),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_selectedHeader != null) {
      return _buildHeaderDetailScreen(cs);
    }

    final visibleHeaders = _visibleHeaders();
    return _buildMainContent(cs, visibleHeaders);
  }

  // ─── Transaction detail modal overlay ──────────────────────────────────────

  Widget _buildDetailModalOverlay(ColorScheme cs) {
    final header = _modalHeader!;
    final rawReceiptId = header['receipt_id']?.toString().trim() ?? '';
    final receiptId = rawReceiptId.isNotEmpty
        ? formatReceiptIdForDisplay(rawReceiptId)
        : '—';
    final created = _formatDateTime(header['created_at']?.toString());
    final isBatchSettled = _modalDetails.any(
      (d) => (d['batch_status']?.toString() ?? 'o') == 'c',
    );
    final status = isBatchSettled ? 'settled' : 'open';
    final salesDetails = _extractSalesDetails(_modalDetails);
    final paymentDetails = _extractPaymentDetails(_modalDetails);

    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeDetailModal,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(color: Colors.black.withValues(alpha: 0.34)),
              ),
            ),
          ),
          Center(
            child: FractionallySizedBox(
              widthFactor: 0.94,
              heightFactor: 0.94,
              child: Material(
                elevation: 18,
                borderRadius: BorderRadius.circular(14),
                color: cs.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Title bar ───────────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
                      child: Row(
                        children: [
                          Icon(
                            Icons.receipt_long,
                            size: 18,
                            color: const Color(0xFF1565C0),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Transaction Details',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _closeDetailModal,
                            icon: Icon(Icons.close, color: cs.onSurfaceVariant),
                            splashRadius: 18,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // ── Header info ─────────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Date + Status
                          Row(
                            children: [
                              Icon(
                                Icons.schedule,
                                size: 12,
                                color: cs.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                created,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _statusBadgeColor(status),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  status.toUpperCase(),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          // Meta chips: Batch | Terminal | Staff
                          Wrap(
                            spacing: 10,
                            runSpacing: 4,
                            children: [
                              _metaChip(cs, 'Receipt ID', receiptId),
                              if ((header['batch_number']?.toString() ?? '')
                                  .isNotEmpty)
                                _metaChip(
                                  cs,
                                  'Batch',
                                  header['batch_number'].toString(),
                                ),
                              if ((header['terminal_name']?.toString() ?? '')
                                  .isNotEmpty)
                                _metaChip(
                                  cs,
                                  'Terminal',
                                  header['terminal_name'].toString(),
                                ),
                              if ((header['staff_name']?.toString() ?? '')
                                  .isNotEmpty)
                                _metaChip(
                                  cs,
                                  'Staff',
                                  header['staff_name'].toString(),
                                ),
                            ],
                          ),
                          if ((header['invoice_reference']?.toString() ?? '')
                              .isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Ref: ${header['invoice_reference']}',
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          // Financial summary
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest.withValues(
                                alpha: 0.55,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _amountColumn(
                                  'Subtotal',
                                  _asDouble(header['subtotal']),
                                ),
                                _dividerV(cs),
                                _amountColumn('Tax', _asDouble(header['tax'])),
                                _dividerV(cs),
                                _amountColumn(
                                  'Total',
                                  _effectiveDisplayTotal(header),
                                  bold: true,
                                ),
                                _dividerV(cs),
                                _amountColumn(
                                  'Paid',
                                  _asDouble(header['amount_paid']),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Divider(
                      height: 1,
                      color: cs.outlineVariant.withValues(alpha: 0.5),
                    ),
                    // ── Detail sections ─────────────────────────────────────
                    Expanded(
                      child: _modalLoading
                          ? const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                10,
                                12,
                                16,
                              ),
                              children: [
                                if (salesDetails.isNotEmpty) ...[
                                  _sectionHeader(
                                    cs,
                                    Icons.shopping_bag_outlined,
                                    'Sales Items',
                                  ),
                                  const SizedBox(height: 8),
                                  ...salesDetails.asMap().entries.map(
                                    (e) => _buildDetailRow(cs, e.key, e.value),
                                  ),
                                  const SizedBox(height: 14),
                                  Divider(
                                    height: 1,
                                    color: cs.outlineVariant.withValues(
                                      alpha: 0.4,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                // Payment Details
                                _sectionHeader(
                                  cs,
                                  Icons.credit_card_outlined,
                                  'Payment Details',
                                ),
                                const SizedBox(height: 8),
                                if (paymentDetails.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 4,
                                    ),
                                    child: Text(
                                      'No payment detail rows found.',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  )
                                else
                                  ...paymentDetails.asMap().entries.map(
                                    (e) => _buildDetailRow(cs, e.key, e.value),
                                  ),
                              ],
                            ),
                    ),
                    // ── Close button ─────────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: SizedBox(
                        height: 40,
                        child: ElevatedButton.icon(
                          onPressed: _closeDetailModal,
                          icon: const Icon(Icons.close, size: 16),
                          label: const Text('Close'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: cs.surfaceContainerHighest,
                            foregroundColor: cs.onSurface,
                            elevation: 0,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaChip(ColorScheme cs, String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: cs.onSurfaceVariant,
          ),
        ),
        Text(value, style: TextStyle(fontSize: 11, color: cs.onSurface)),
      ],
    );
  }

  Widget _dividerV(ColorScheme cs) {
    return Container(
      width: 1,
      height: 28,
      color: cs.outlineVariant.withValues(alpha: 0.5),
    );
  }

  Widget _amountColumn(String label, double amount, {bool bold = false}) {
    return Column(
      children: [
        Text(
          '\$${amount.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: bold ? 14 : 12,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _sectionHeader(ColorScheme cs, IconData icon, String title) {
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 13, color: cs.primary),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
      ],
    );
  }

  List<Map<String, dynamic>> _extractSalesDetails(
    List<Map<String, dynamic>> details,
  ) {
    if (details.isEmpty) return const [];
    return details
        .where((row) {
          final paymentType =
              row['payment_type']?.toString().toLowerCase() ?? '';
          final subtype = row['subtype']?.toString().toLowerCase() ?? '';
          return paymentType == 'sale' ||
              paymentType == 'item' ||
              paymentType == 'service' ||
              paymentType == 'product' ||
              subtype.contains('sale') ||
              subtype.contains('item') ||
              subtype.contains('service');
        })
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _extractPaymentDetails(
    List<Map<String, dynamic>> details,
  ) {
    if (details.isEmpty) return const [];
    final salesIds = _extractSalesDetails(
      details,
    ).map((row) => row['id']?.toString() ?? '').toSet();
    if (salesIds.isEmpty) return List<Map<String, dynamic>>.from(details);

    return details
        .where((row) {
          final id = row['id']?.toString() ?? '';
          return !salesIds.contains(id);
        })
        .toList(growable: false);
  }

  Color _statusBadgeColor(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
      case 'settled':
        return Colors.green.shade700;
      case 'voided':
      case 'declined':
      case 'failed':
        return Colors.red.shade700;
      case 'pending':
        return Colors.orange.shade700;
      case 'open':
        return const Color(0xFFB71C1C);
      default:
        return Colors.blueGrey.shade600;
    }
  }

  Widget _buildDetailRow(ColorScheme cs, int index, Map<String, dynamic> d) {
    final amt = _asDouble(d['amount']);
    final type = _paymentTypeLabel(
      d['payment_type']?.toString() ?? '',
    ).toUpperCase();
    final dStatus = d['status']?.toString() ?? '';
    final subtype = d['subtype']?.toString() ?? '';
    final ref = d['reference_id']?.toString() ?? '';
    final auth = d['auth_code']?.toString() ?? '';
    final last4 = d['card_last4']?.toString() ?? '';
    final cardType = d['card_type']?.toString() ?? '';
    final time = _formatDateTime(d['created_at']?.toString());

    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${index + 1}. $type',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '\$${amt.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            if (dStatus.isNotEmpty || subtype.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                [
                  if (dStatus.isNotEmpty) 'Status: $dStatus',
                  if (subtype.isNotEmpty) 'Type: $subtype',
                ].join('   '),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
            if (auth.isNotEmpty || last4.isNotEmpty || cardType.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                [
                  if (auth.isNotEmpty) 'Auth: $auth',
                  if (last4.isNotEmpty) '••••$last4',
                  if (cardType.isNotEmpty) cardType,
                ].join('   '),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
            if (ref.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                'Ref: $ref',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 3),
            Text(
              time,
              style: TextStyle(
                fontSize: 10,
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderDetailScreen(ColorScheme cs) {
    final header = _selectedHeader ?? const <String, dynamic>{};
    final createdAt = _formatDateTime(header['created_at']?.toString());
    final tender = _headerTenderKind(header);

    final content = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Row(
            children: [
              StandardActionButton(
                label: 'Back',
                icon: Icons.arrow_back,
                compact: true,
                small: true,
                onTap: _closeHeaderDetails,
              ),
              const SizedBox(width: 8),
              Text(
                'Transaction Details',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              if (widget.embedded && widget.onClose != null)
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: StandardPanel(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailRow('Header ID', header['id']?.toString() ?? ''),
                _detailRow('Date', createdAt),
                _detailRow('Tender', tender.toUpperCase()),
                _detailRow('Status', header['status']?.toString() ?? ''),
                _detailRow(
                  'Amount',
                  '\$${_effectiveDisplayTotal(header).toStringAsFixed(2)}',
                ),
                _detailRow(
                  'Subtotal',
                  '\$${_asDouble(header['subtotal']).toStringAsFixed(2)}',
                ),
                _detailRow(
                  'Tax',
                  '\$${_asDouble(header['tax']).toStringAsFixed(2)}',
                ),
                _detailRow(
                  'Amount Paid',
                  '\$${_asDouble(header['amount_paid']).toStringAsFixed(2)}',
                ),
                _detailRow(
                  'Amount Due',
                  '\$${_asDouble(header['amount_due']).toStringAsFixed(2)}',
                ),
                _detailRow('Staff', header['staff_name']?.toString() ?? ''),
                _detailRow(
                  'Terminal',
                  header['terminal_name']?.toString() ?? '',
                ),
                _detailRow(
                  'Invoice/Ref',
                  header['invoice_reference']?.toString() ?? '',
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _detailsLoading
              ? const Center(child: CircularProgressIndicator())
              : _selectedDetails.isEmpty
              ? const Center(
                  child: Text('No detail rows for this transaction.'),
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: StandardPanel(
                    padding: const EdgeInsets.all(8),
                    child: ListView.separated(
                      itemCount: _selectedDetails.length,
                      separatorBuilder: (_, _) => const Divider(height: 10),
                      itemBuilder: (context, index) {
                        final row = _selectedDetails[index];
                        final amount = _asDouble(row['amount']);
                        final type = _paymentTypeLabel(
                          row['payment_type']?.toString() ?? '',
                        );
                        final status = row['status']?.toString() ?? '';
                        final subtype = row['subtype']?.toString() ?? '';
                        final created = _formatDateTime(
                          row['created_at']?.toString(),
                        );
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${index + 1}. ${type.toUpperCase()}  \$${amount.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'status=$status  subtype=$subtype  time=$created',
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            if ((row['reference_id']?.toString() ?? '')
                                .isNotEmpty)
                              Text(
                                'reference: ${row['reference_id']}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            if ((row['auth_code']?.toString() ?? '').isNotEmpty)
                              Text(
                                'auth: ${row['auth_code']}  last4: ${row['card_last4'] ?? ''}  card: ${row['card_type'] ?? ''}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );

    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(title: const Text('Transaction Details')),
      body: content,
    );
  }

  Widget _buildChoiceRow({
    required ColorScheme cs,
    required String label,
    required IconData icon,
    Color iconColor = const Color(0xFF1565C0),
    Color iconBackgroundColor = const Color(0xFFE3F2FD),
    required String selectedValue,
    required List<MapEntry<String, String>> options,
    required ValueChanged<String> onSelected,
  }) {
    return StandardPanel(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: iconBackgroundColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 11, color: iconColor),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 58,
            child: Text(
              '$label:',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: options
                  .map(
                    (option) => ChoiceChip(
                      label: Text(
                        option.value,
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: selectedValue == option.key,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => onSelected(option.key),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmountFilterCard(ColorScheme cs) {
    return StandardPanel(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(
              Icons.attach_money,
              size: 11,
              color: Color(0xFF2E7D32),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 58,
            child: Text(
              'Amount:',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _buildAmountField(
                    hint: 'Min',
                    controller: _minAmountController,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildAmountField(
                    hint: 'Max',
                    controller: _maxAmountController,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmountField({
    required String hint,
    required TextEditingController controller,
  }) {
    return SizedBox(
      height: 30,
      child: TextField(
        controller: controller,
        style: const TextStyle(fontSize: 11),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 7,
          ),
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => setState(_syncAmountFiltersFromText),
        onEditingComplete: () {
          setState(_syncAmountFiltersFromText);
          FocusScope.of(context).unfocus();
        },
      ),
    );
  }

  Widget _buildCardAuthFilterCard(ColorScheme cs) {
    return StandardPanel(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 420;
          final fieldRow = compact
              ? Column(
                  children: [
                    _buildTextFilterField(
                      hint: 'Card #',
                      controller: _cardFilterController,
                      onSubmit: _syncCardAuthFiltersFromText,
                    ),
                    const SizedBox(height: 8),
                    _buildTextFilterField(
                      hint: 'Auth',
                      controller: _authFilterController,
                      onSubmit: _syncCardAuthFiltersFromText,
                    ),
                    const SizedBox(height: 8),
                    _buildTextFilterField(
                      hint: 'Receipt ID',
                      controller: _receiptIdFilterController,
                      onSubmit: _syncCardAuthFiltersFromText,
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: _buildTextFilterField(
                        hint: 'Card #',
                        controller: _cardFilterController,
                        onSubmit: _syncCardAuthFiltersFromText,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildTextFilterField(
                        hint: 'Auth',
                        controller: _authFilterController,
                        onSubmit: _syncCardAuthFiltersFromText,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildTextFilterField(
                        hint: 'Receipt ID',
                        controller: _receiptIdFilterController,
                        onSubmit: _syncCardAuthFiltersFromText,
                      ),
                    ),
                  ],
                );

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 18,
                height: 18,
                margin: const EdgeInsets.only(top: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFE3F2FD),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(
                  Icons.credit_card,
                  size: 11,
                  color: Color(0xFF1565C0),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 58,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Card/Auth:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              Expanded(child: fieldRow),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTextFilterField({
    required String hint,
    required TextEditingController controller,
    required VoidCallback onSubmit,
  }) {
    return SizedBox(
      height: 30,
      child: TextField(
        controller: controller,
        style: const TextStyle(fontSize: 11),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 7,
          ),
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => setState(onSubmit),
        onEditingComplete: () {
          setState(onSubmit);
          FocusScope.of(context).unfocus();
        },
      ),
    );
  }

  Widget _buildCustomDateInput({
    required String label,
    required TextEditingController controller,
    required VoidCallback onCalendarTap,
    required ValueChanged<String> onSubmitted,
  }) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 246,
      child: StandardPanel(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              child: Text(
                '$label:',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: SizedBox(
                height: 28,
                child: TextField(
                  controller: controller,
                  style: const TextStyle(fontSize: 10.5),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 7,
                    ),
                    hintText: 'MM/DD/YYYY',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.datetime,
                  textInputAction: TextInputAction.done,
                  onSubmitted: onSubmitted,
                  onEditingComplete: () {
                    onSubmitted(controller.text);
                    FocusScope.of(context).unfocus();
                  },
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: onCalendarTap,
              icon: const Icon(Icons.calendar_month_outlined, size: 14),
              visualDensity: VisualDensity.compact,
              splashRadius: 14,
              tooltip: 'Pick date',
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    final cs = Theme.of(context).colorScheme;
    final safeValue = value.trim().isEmpty ? '-' : value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        text: TextSpan(
          style: TextStyle(color: cs.onSurface, fontSize: 13),
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
            TextSpan(text: safeValue),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reprint overlay — inserted directly into the root Overlay so it always
// renders above the transaction-list overlay entry.
// ---------------------------------------------------------------------------

class _ReprintOverlayWidget extends StatefulWidget {
  const _ReprintOverlayWidget({
    required this.header,
    required this.customerData,
    required this.cardMeta,
    required this.buildReceiptPdfBytes,
    required this.emailReceiptPdf,
    required this.isValidEmail,
    required this.onClose,
  });

  final Map<String, dynamic> header;
  final Map<String, dynamic> customerData;
  final Map<String, String> cardMeta;
  final Future<Uint8List> Function(PdfPageFormat format) buildReceiptPdfBytes;
  final Future<void> Function(String email) emailReceiptPdf;
  final bool Function(String) isValidEmail;
  final VoidCallback onClose;

  @override
  State<_ReprintOverlayWidget> createState() => _ReprintOverlayWidgetState();
}

class _ReprintOverlayWidgetState extends State<_ReprintOverlayWidget> {
  final _emailController = TextEditingController();
  String? _emailError;
  String? _emailSentMessage;
  bool _isWorking = false;

  static const _receiptFormat = PdfPageFormat(
    3.25 * PdfPageFormat.inch,
    11 * PdfPageFormat.inch,
    marginLeft: 0,
    marginRight: 0,
    marginTop: 0,
    marginBottom: 0,
  );

  @override
  void initState() {
    super.initState();
    _emailController.text =
        widget.customerData['email']?.toString().trim() ?? '';
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _runAction(Future<void> Function() action) async {
    setState(() => _isWorking = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cardType = widget.cardMeta['cardType']?.trim() ?? '';
    final cardLast4 = widget.cardMeta['cardLast4']?.trim() ?? '';
    final authCode = widget.cardMeta['authCode']?.trim() ?? '';
    final maskedCard = cardLast4.isNotEmpty ? ' ****$cardLast4' : '';
    final amount =
        double.tryParse(
          (widget.header['display_amount'] ??
                  widget.header['total'] ??
                  widget.header['header_total'] ??
                  '0')
              .toString(),
        ) ??
        0.0;

    return Material(
      color: Colors.black54,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400, maxHeight: 700),
            child: Card(
              margin: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header bar
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(12),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '*** REPRINT ***',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimaryContainer,
                                ),
                              ),
                              Text(
                                'Amount: \$${amount.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimaryContainer,
                                ),
                              ),
                              if (cardType.isNotEmpty)
                                Text(
                                  'Card: $cardType$maskedCard',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              if (authCode.isNotEmpty)
                                Text(
                                  'Auth: $authCode',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimaryContainer,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: _isWorking ? null : widget.onClose,
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                      ],
                    ),
                  ),

                  // Scrollable body
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Customer info
                          if (widget.customerData.isNotEmpty)
                            CustomerInfoSummary(
                              customerData: widget.customerData,
                              compact: true,
                            ),

                          const SizedBox(height: 12),

                          // PDF preview
                          ReceiptPreviewSection(
                            title: 'Print Preview',
                            pdfBuilder: widget.buildReceiptPdfBytes,
                            receiptFormat: _receiptFormat,
                            previewHeight: 260,
                            previewWidth: double.infinity,
                          ),

                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 8),

                          // Print button
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _isWorking
                                  ? null
                                  : () => _runAction(() async {
                                      await Printing.layoutPdf(
                                        name: 'Reprint Receipt',
                                        format: _receiptFormat,
                                        onLayout: widget.buildReceiptPdfBytes,
                                      );
                                    }),
                              icon: const Icon(Icons.print_outlined),
                              label: const Text('Print Reprint'),
                            ),
                          ),

                          const SizedBox(height: 12),

                          // Email field
                          TextField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              labelText: 'Email Receipt To',
                              hintText: 'name@domain.com',
                              errorText: _emailError,
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (_) {
                              if (_emailError != null ||
                                  _emailSentMessage != null) {
                                setState(() {
                                  _emailError = null;
                                  _emailSentMessage = null;
                                });
                              }
                            },
                          ),

                          const SizedBox(height: 8),

                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _isWorking
                                  ? null
                                  : () async {
                                      final email = _emailController.text
                                          .trim();
                                      if (!widget.isValidEmail(email)) {
                                        setState(() {
                                          _emailError =
                                              'Enter a valid email address.';
                                        });
                                        return;
                                      }
                                      await _runAction(() async {
                                        try {
                                          await widget.emailReceiptPdf(email);
                                          if (mounted) {
                                            setState(() {
                                              _emailError = null;
                                              _emailSentMessage =
                                                  'Receipt emailed to $email.';
                                            });
                                          }
                                        } catch (e) {
                                          if (mounted) {
                                            setState(() {
                                              _emailSentMessage = null;
                                              _emailError = e
                                                  .toString()
                                                  .replaceFirst(
                                                    'Exception: ',
                                                    '',
                                                  )
                                                  .trim();
                                            });
                                          }
                                        }
                                      });
                                    },
                              icon: const Icon(Icons.email_outlined),
                              label: const Text('Email Receipt'),
                            ),
                          ),

                          // Email sent confirmation banner
                          if (_emailSentMessage != null) ...[
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFD1FADF),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _emailSentMessage!,
                                style: const TextStyle(
                                  color: Color(0xFF065F46),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],

                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),

                  // Done button
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _isWorking ? null : widget.onClose,
                        child: const Text('Done'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
