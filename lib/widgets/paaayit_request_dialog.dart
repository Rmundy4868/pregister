import 'dart:convert';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/paaayit_request_service.dart';

class PaaayitRequestDialog extends StatefulWidget {
  final String organizationId;
  final String locationId;
  final String terminalId;
  final String merchantId;
  final String hppAuthToken;
  final bool enableProcessorSurcharge;
  final VoidCallback? onClose;

  const PaaayitRequestDialog({
    super.key,
    required this.organizationId,
    required this.locationId,
    required this.terminalId,
    required this.merchantId,
    required this.hppAuthToken,
    required this.enableProcessorSurcharge,
    this.onClose,
  });

  @override
  State<PaaayitRequestDialog> createState() => _PaaayitRequestDialogState();
}

class _PaaayitRequestDialogState extends State<PaaayitRequestDialog> {
  final _service = PaaayitRequestService();
  final _paymentReferenceController = TextEditingController();
  final _customerEmailController = TextEditingController();
  final _customerNameController = TextEditingController();
  final _amountController = TextEditingController();
  final RegExp _emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  static const int _maxAttachmentBytes = 2 * 1024 * 1024;

  static const _brandBlue = Color(0xFF0A4FAF);
  static const _brandSky = Color(0xFF2E9BFF);
  static const _brandMint = Color(0xFF4FD2C2);
  static const _heroDark = Color(0xFF05224D);

  bool _isLoading = false;
  String? _errorMessage;
  PaaayitRequestResult? _result;
  String? _pdfAttachmentFileName;
  String? _pdfAttachmentBase64;
  int? _pdfAttachmentSizeBytes;

  @override
  void dispose() {
    _paymentReferenceController.dispose();
    _customerEmailController.dispose();
    _customerNameController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _validateAndSubmit() async {
    final paymentReference = _paymentReferenceController.text.trim();
    final email = _customerEmailController.text.trim();
    final name = _customerNameController.text.trim();
    final amountText = _amountController.text.trim();

    if (paymentReference.isEmpty) {
      setState(() => _errorMessage = 'Payment reference is required.');
      return;
    }

    if (email.isEmpty) {
      setState(() => _errorMessage = 'Customer email is required.');
      return;
    }

    if (!_emailRegex.hasMatch(email)) {
      setState(() => _errorMessage = 'Please enter a valid email address.');
      return;
    }

    if (name.isEmpty) {
      setState(() => _errorMessage = 'Customer name is required.');
      return;
    }

    double? amount;
    try {
      amount = double.parse(amountText);
      if (amount <= 0) {
        setState(() => _errorMessage = 'Amount must be greater than zero.');
        return;
      }
    } catch (_) {
      setState(() => _errorMessage = 'Please enter a valid amount.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await _service.createRequest(
      organizationId: widget.organizationId,
      locationId: widget.locationId,
      terminalId: widget.terminalId,
      merchantId: widget.merchantId,
      customerEmail: email,
      customerName: name,
      amount: amount,
      hppAuthToken: widget.hppAuthToken,
      calculateFee: widget.enableProcessorSurcharge,
      paymentReference: paymentReference,
      pdfAttachmentFileName: _pdfAttachmentFileName,
      pdfAttachmentBase64: _pdfAttachmentBase64,
    );

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (result.success) {
        _result = result;
      } else {
        _errorMessage = result.message;
      }
    });
  }

  Future<void> _pickPdfAttachment() async {
    try {
      final pdfGroup = XTypeGroup(label: 'PDF', extensions: ['pdf']);
      final file = await openFile(acceptedTypeGroups: [pdfGroup]);

      if (file == null) {
        return;
      }

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        if (!mounted) return;
        setState(() {
          _errorMessage =
              'Could not read PDF bytes. Please choose a local PDF file.';
        });
        return;
      }

      if (bytes.length > _maxAttachmentBytes) {
        if (!mounted) return;
        setState(() {
          _errorMessage = 'PDF must be 2 MB or smaller.';
        });
        return;
      }

      if (!mounted) return;
      setState(() {
        _pdfAttachmentFileName = file.name;
        _pdfAttachmentBase64 = base64Encode(bytes);
        _pdfAttachmentSizeBytes = bytes.length;
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to open PDF picker: $e';
      });
    }
  }

  void _removePdfAttachment() {
    setState(() {
      _pdfAttachmentFileName = null;
      _pdfAttachmentBase64 = null;
      _pdfAttachmentSizeBytes = null;
    });
  }

  void _openPaymentLink() async {
    if (_result?.paymentUrl.isEmpty ?? true) return;

    final uri = Uri.parse(_result!.paymentUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open URL: ${_result!.paymentUrl}')),
        );
      }
    }
  }

  void _copyPaymentLink() async {
    if (_result?.paymentUrl.isEmpty ?? true) return;

    await Clipboard.setData(ClipboardData(text: _result!.paymentUrl));
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Payment link copied to clipboard.')),
    );
  }

  Future<void> _openActivityScreen() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return _PaaayitRequestActivityDialog(
          service: _service,
          organizationId: widget.organizationId,
          locationId: widget.locationId,
          terminalId: widget.terminalId,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _result == null
        ? 'Create PaaayIT Request'
        : 'Request Created';
    final maxDialogHeight = MediaQuery.of(context).size.height * 0.92;

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 620,
            minHeight: 760,
            maxHeight: maxDialogHeight,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Material(
              color: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHero(context, title),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                        child: _result == null
                            ? _buildFormState(context)
                            : _buildSuccessState(context),
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

  Widget _buildHero(BuildContext context, String title) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [_heroDark, _brandBlue, _brandSky],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(230),
              borderRadius: BorderRadius.circular(14),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset(
                'assets/icons/Blue arrows-icon.png',
                fit: BoxFit.contain,
                alignment: Alignment.centerLeft,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _result == null
                      ? 'Send a payment request.'
                      : 'Payment link is ready to send.',
                  style: TextStyle(
                    color: Colors.white.withAlpha(220),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          _buildFlyingPlaneBadge(),
        ],
      ),
    );
  }

  Widget _buildFlyingPlaneBadge() {
    return Container(
      width: 74,
      height: 52,
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(35),
        border: Border.all(color: Colors.white.withAlpha(60)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 14,
            top: 16,
            child: Container(
              width: 18,
              height: 2,
              color: Colors.white.withAlpha(120),
            ),
          ),
          Positioned(
            left: 10,
            top: 24,
            child: Container(
              width: 24,
              height: 2,
              color: Colors.white.withAlpha(90),
            ),
          ),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: -2, end: 2),
            duration: const Duration(milliseconds: 1400),
            curve: Curves.easeInOut,
            builder: (context, value, child) {
              return Transform.translate(
                offset: Offset(value, -value),
                child: child,
              );
            },
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: EdgeInsets.only(right: 10),
                child: Transform.rotate(
                  angle: -0.35,
                  child: Icon(
                    Icons.send_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormState(BuildContext context) {
    final fieldError = _errorMessage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _paymentReferenceController,
          enabled: !_isLoading,
          decoration: InputDecoration(
            labelText: 'Payment Reference *',
            hintText: 'INV-10027',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.tag_outlined),
            errorText: fieldError?.contains('Payment reference') ?? false
                ? fieldError
                : null,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _customerEmailController,
          enabled: !_isLoading,
          decoration: InputDecoration(
            labelText: 'Customer Email *',
            hintText: 'customer@example.com',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.email_outlined),
            errorText: fieldError?.contains('email') ?? false
                ? fieldError
                : null,
          ),
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _customerNameController,
          enabled: !_isLoading,
          decoration: InputDecoration(
            labelText: 'Customer Name *',
            hintText: 'John Doe',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.person_outline),
            errorText: fieldError?.contains('name') ?? false
                ? fieldError
                : null,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _amountController,
          enabled: !_isLoading,
          decoration: InputDecoration(
            labelText: 'Amount (USD) *',
            hintText: '0.00',
            prefixText: '\$ ',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.attach_money),
            errorText: fieldError?.contains('Amount') ?? false
                ? fieldError
                : null,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF6F8FC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFD5DEEF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.picture_as_pdf_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Attach PDF (optional)',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _isLoading ? null : _pickPdfAttachment,
                    icon: const Icon(Icons.attach_file),
                    label: const Text('Select PDF'),
                  ),
                ],
              ),
              if (_pdfAttachmentFileName != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _pdfAttachmentSizeBytes == null
                            ? _pdfAttachmentFileName!
                            : '${_pdfAttachmentFileName!} (${(_pdfAttachmentSizeBytes! / 1024).toStringAsFixed(1)} KB)',
                        style: const TextStyle(fontSize: 12.5),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _isLoading ? null : _removePdfAttachment,
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('Remove'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (_isLoading) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [_brandBlue.withAlpha(24), _brandMint.withAlpha(24)],
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _brandBlue.withAlpha(80)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Sending PaaayIT request...',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                LinearProgressIndicator(minHeight: 5),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (_errorMessage != null &&
            !_errorMessage!.contains('email') &&
            !_errorMessage!.contains('name') &&
            !_errorMessage!.contains('Amount'))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withAlpha(20),
                border: Border.all(color: Colors.red.withAlpha(170)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _isLoading ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _validateAndSubmit,
              style: ElevatedButton.styleFrom(
                backgroundColor: _brandBlue,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.send_rounded),
              label: const Text('Create Request'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF6F8FC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFD5DEEF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'PaaayIT Request Activity',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                'Review created requests, status, and timeline activity.',
                style: TextStyle(fontSize: 12, color: Color(0xFF4A5568)),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _isLoading ? null : _openActivityScreen,
                  icon: const Icon(Icons.history),
                  label: const Text('Open Activity'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: _isLoading ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close),
            label: const Text('Close'),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessState(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.green.withAlpha(24), _brandMint.withAlpha(24)],
            ),
            border: Border.all(color: Colors.green.withAlpha(130)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _result!.message,
                      style: const TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text('Request Number: ${_result!.requestNumber}'),
              const SizedBox(height: 4),
              Text(
                'Expires: ${_result!.expiresAt?.toString().split('.').first ?? 'N/A'}',
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Payment Link',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF6F8FC),
            border: Border.all(color: const Color(0xFFD5DEEF)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            _result!.paymentUrl,
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              wordSpacing: 0,
            ),
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _openPaymentLink,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Link'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _copyPaymentLink,
                icon: const Icon(Icons.content_copy),
                label: const Text('Copy Link'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _brandBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              widget.onClose?.call();
              Navigator.pop(context);
            },
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}

class _PaaayitRequestActivityDialog extends StatefulWidget {
  final PaaayitRequestService service;
  final String organizationId;
  final String locationId;
  final String terminalId;

  const _PaaayitRequestActivityDialog({
    required this.service,
    required this.organizationId,
    required this.locationId,
    required this.terminalId,
  });

  @override
  State<_PaaayitRequestActivityDialog> createState() =>
      _PaaayitRequestActivityDialogState();
}

class _PaaayitRequestActivityDialogState
    extends State<_PaaayitRequestActivityDialog> {
  static const _bluePrimary = Color(0xFF0A4FAF);
  static const _blueDark = Color(0xFF05224D);
  static const _blueSurface = Color(0xFFF4F8FF);
  static const _blueBorder = Color(0xFFD5DEEF);
  static const _blueMuted = Color(0xFF4A607B);

  String _statusFilter = 'all';
  String _dateFilter = 'all';
  bool _isLoading = true;
  final Set<String> _syncingRefs = <String>{};
  final Set<String> _cancellingIds = <String>{};
  String? _error;
  List<PaaayitRequestActivityItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime? _fromDateForFilter(String value) {
    final now = DateTime.now();
    if (value == 'today') {
      return DateTime(now.year, now.month, now.day);
    }
    if (value == 'last7') {
      return now.subtract(const Duration(days: 7));
    }
    if (value == 'last30') {
      return now.subtract(const Duration(days: 30));
    }
    return null;
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final items = await widget.service.listRequests(
        organizationId: widget.organizationId,
        terminalId: widget.terminalId,
        locationId: widget.locationId,
        status: _statusFilter == 'all' ? null : _statusFilter,
        fromDate: _fromDateForFilter(_dateFilter),
        toDate: DateTime.now(),
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _items = items;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _tempSyncPaid(PaaayitRequestActivityItem item) async {
    final ref = item.hppTransactionReferenceId.trim();
    if (ref.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot sync: missing transaction reference.'),
        ),
      );
      return;
    }

    setState(() {
      _syncingRefs.add(ref);
    });

    try {
      await widget.service.tempSyncPaid(
        hppTransactionReferenceId: ref,
        expectedRequestNumber: item.requestNumber,
        expectedAmount: item.amount,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Temp sync complete.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      final raw = e.toString().trim();
      final display = raw.startsWith('Exception: ')
          ? raw.substring('Exception: '.length).trim()
          : raw;

      final canManualOverride =
          display.contains('reason=verification_call_failed') ||
          display.contains('reason=missing_hpp_auth_token');

      if (canManualOverride) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Manual Paid Override?'),
              content: Text(
                'Provider verification is unavailable.\n\n'
                'Selected request: ${item.requestNumber.isEmpty ? 'N/A' : item.requestNumber}\n'
                'Amount: \$${item.amount.toStringAsFixed(2)}\n'
                'Reference: ${item.hppTransactionReferenceId}\n\n'
                'If this exact transaction is confirmed paid in iPOS portal, you can force Temp Sync.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(
                    'Force Sync Paid - \$${item.amount.toStringAsFixed(2)}',
                  ),
                ),
              ],
            );
          },
        );

        if (confirmed == true) {
          try {
            await widget.service.tempSyncPaid(
              hppTransactionReferenceId: ref,
              expectedRequestNumber: item.requestNumber,
              expectedAmount: item.amount,
              manualOverride: true,
              manualOverrideReason:
                  'Operator confirmed payment in iPOS portal during test flow.',
            );
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Manual Temp Sync complete (override applied).'),
              ),
            );
            await _load();
            return;
          } catch (overrideError) {
            if (!mounted) return;
            final overrideRaw = overrideError.toString().trim();
            final overrideDisplay = overrideRaw.startsWith('Exception: ')
                ? overrideRaw.substring('Exception: '.length).trim()
                : overrideRaw;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Manual temp sync failed: $overrideDisplay'),
              ),
            );
            return;
          }
        }
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Temp sync failed: $display')));
    } finally {
      if (!mounted) return;
      setState(() {
        _syncingRefs.remove(ref);
      });
    }
  }

  Future<void> _cancelRequest(PaaayitRequestActivityItem item) async {
    final id = item.id.trim();
    final ref = item.hppTransactionReferenceId.trim();
    if (id.isEmpty && ref.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot cancel: missing request id/reference.'),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Payment Request?'),
        content: Text(
          'Request: ${item.requestNumber.isEmpty ? 'N/A' : item.requestNumber}\n'
          'Amount: \$${item.amount.toStringAsFixed(2)}\n\n'
          'This will block all future payment attempts for this request.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep Active'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel Request'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _cancellingIds.add(id.isNotEmpty ? id : ref);
    });

    try {
      await widget.service.cancelRequest(
        requestId: id,
        hppTransactionReferenceId: ref,
        cancelReason: 'Cancelled from register activity dialog by operator.',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Payment request cancelled. Any payment attempt will be declined.',
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      final raw = e.toString().trim();
      final display = raw.startsWith('Exception: ')
          ? raw.substring('Exception: '.length).trim()
          : raw;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Cancel failed: $display')));
    } finally {
      if (!mounted) return;
      setState(() {
        _cancellingIds.remove(id.isNotEmpty ? id : ref);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 30, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 920,
            maxHeight: MediaQuery.of(context).size.height * 0.9,
            minHeight: 620,
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'PaaayIT Request Activity',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: _blueDark,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: _blueMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    SizedBox(
                      width: 180,
                      child: DropdownButtonFormField<String>(
                        value: _statusFilter,
                        decoration: const InputDecoration(
                          labelText: 'Status',
                          border: OutlineInputBorder(),
                          isDense: true,
                          labelStyle: TextStyle(color: _blueMuted),
                          filled: true,
                          fillColor: _blueSurface,
                        ),
                        style: const TextStyle(color: _blueDark),
                        dropdownColor: Colors.white,
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('All')),
                          DropdownMenuItem(
                            value: 'pending',
                            child: Text('Pending'),
                          ),
                          DropdownMenuItem(value: 'sent', child: Text('Sent')),
                          DropdownMenuItem(value: 'paid', child: Text('Paid')),
                          DropdownMenuItem(
                            value: 'failed',
                            child: Text('Failed'),
                          ),
                          DropdownMenuItem(
                            value: 'expired',
                            child: Text('Expired'),
                          ),
                          DropdownMenuItem(
                            value: 'cancelled',
                            child: Text('Cancelled'),
                          ),
                        ],
                        onChanged: (value) {
                          setState(() => _statusFilter = value ?? 'all');
                          _load();
                        },
                      ),
                    ),
                    SizedBox(
                      width: 180,
                      child: DropdownButtonFormField<String>(
                        value: _dateFilter,
                        decoration: const InputDecoration(
                          labelText: 'Date',
                          border: OutlineInputBorder(),
                          isDense: true,
                          labelStyle: TextStyle(color: _blueMuted),
                          filled: true,
                          fillColor: _blueSurface,
                        ),
                        style: const TextStyle(color: _blueDark),
                        dropdownColor: Colors.white,
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('All Dates'),
                          ),
                          DropdownMenuItem(
                            value: 'today',
                            child: Text('Today'),
                          ),
                          DropdownMenuItem(
                            value: 'last7',
                            child: Text('Last 7 Days'),
                          ),
                          DropdownMenuItem(
                            value: 'last30',
                            child: Text('Last 30 Days'),
                          ),
                        ],
                        onChanged: (value) {
                          setState(() => _dateFilter = value ?? 'all');
                          _load();
                        },
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _isLoading ? null : _load,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _bluePrimary,
                        side: const BorderSide(color: _blueBorder),
                      ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: _blueSurface,
                      border: Border.all(color: _blueBorder),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : _error != null
                        ? Center(
                            child: Text(
                              _error!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          )
                        : _items.isEmpty
                        ? const Center(
                            child: Text('No PaaayIT requests found.'),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: _items.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 16),
                            itemBuilder: (context, index) {
                              final item = _items[index];
                              final normalizedStatus = item.status
                                  .toLowerCase()
                                  .trim();
                              final statusBackgroundColor =
                                  normalizedStatus == 'paid'
                                  ? const Color(0xFFE3F3EA)
                                  : (normalizedStatus == 'cancelled' ||
                                        normalizedStatus == 'canceled')
                                  ? const Color(0xFFFFF1E0)
                                  : normalizedStatus == 'expired'
                                  ? const Color(0xFFF9E6E6)
                                  : const Color(0xFFE8F1FF);
                              final statusTextColor = normalizedStatus == 'paid'
                                  ? const Color(0xFF2E6A4A)
                                  : (normalizedStatus == 'cancelled' ||
                                        normalizedStatus == 'canceled')
                                  ? const Color(0xFF8A4A00)
                                  : normalizedStatus == 'expired'
                                  ? const Color(0xFF8A3B3B)
                                  : _blueDark;
                              final canTempSync =
                                  item.status.toLowerCase() != 'cancelled' &&
                                  item.status.toLowerCase() != 'canceled' &&
                                  item.status.toLowerCase() != 'expired' &&
                                  item.status.toLowerCase() != 'paid' &&
                                  item.status.toLowerCase() != 'reconciled';
                              final canCancel =
                                  item.status.toLowerCase() != 'cancelled' &&
                                  item.status.toLowerCase() != 'canceled' &&
                                  item.status.toLowerCase() != 'expired' &&
                                  item.status.toLowerCase() != 'paid' &&
                                  item.status.toLowerCase() != 'reconciled';
                              final isSyncing =
                                  _syncingRefs.contains(
                                    item.hppTransactionReferenceId,
                                  ) ||
                                  _isLoading;
                              final cancelKey = item.id.trim().isNotEmpty
                                  ? item.id.trim()
                                  : item.hppTransactionReferenceId.trim();
                              final isCancelling =
                                  _cancellingIds.contains(cancelKey) ||
                                  _isLoading;
                              final createdText =
                                  item.createdAt
                                      ?.toLocal()
                                      .toString()
                                      .split('.')
                                      .first ??
                                  'N/A';
                              final cancelledText =
                                  item.cancelledAt
                                      ?.toLocal()
                                      .toString()
                                      .split('.')
                                      .first ??
                                  'N/A';
                              final showCancelledMeta =
                                  normalizedStatus == 'cancelled' ||
                                  normalizedStatus == 'canceled';
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.requestNumber.isEmpty
                                              ? '(No request number)'
                                              : item.requestNumber,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                            color: _blueDark,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${item.customerName} • ${item.customerEmail}',
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            color: _bluePrimary,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Created: $createdText',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: _blueMuted,
                                          ),
                                        ),
                                        if (showCancelledMeta) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            'Cancelled: $cancelledText',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFF8A4A00),
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          if (item.cancelReason
                                              .trim()
                                              .isNotEmpty)
                                            Text(
                                              'Reason: ${item.cancelReason.trim()}',
                                              style: const TextStyle(
                                                fontSize: 11.5,
                                                color: Color(0xFF8A4A00),
                                              ),
                                            ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: statusBackgroundColor,
                                          borderRadius: BorderRadius.circular(
                                            30,
                                          ),
                                        ),
                                        child: Text(
                                          item.status.isEmpty
                                              ? 'unknown'
                                              : item.status,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: statusTextColor,
                                          ),
                                        ),
                                      ),
                                      if (item.isManualOverride) ...[
                                        const SizedBox(height: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFFF2CC),
                                            borderRadius: BorderRadius.circular(
                                              30,
                                            ),
                                          ),
                                          child: const Text(
                                            'Manual Override',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF7A4A00),
                                            ),
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 8),
                                      Text(
                                        '\$${item.amount.toStringAsFixed(2)} ${item.currency}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: _blueDark,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      OutlinedButton(
                                        onPressed: canTempSync && !isSyncing
                                            ? () => _tempSyncPaid(item)
                                            : null,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: _bluePrimary,
                                          side: const BorderSide(
                                            color: _blueBorder,
                                          ),
                                          minimumSize: const Size(120, 34),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                        ),
                                        child: isSyncing
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Text('Temp Sync Paid'),
                                      ),
                                      const SizedBox(height: 6),
                                      OutlinedButton(
                                        onPressed: canCancel && !isCancelling
                                            ? () => _cancelRequest(item)
                                            : null,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: const Color(
                                            0xFF8A3B3B,
                                          ),
                                          side: const BorderSide(
                                            color: Color(0xFFF1C9C9),
                                          ),
                                          minimumSize: const Size(120, 34),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                        ),
                                        child: isCancelling
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Text('Cancel Request'),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
