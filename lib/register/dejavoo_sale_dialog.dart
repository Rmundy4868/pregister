import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../services/dejavoo_service.dart';

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------
// Uses an Overlay entry instead of Navigator.push / showDialog so that the
// underlying RegisterScreen is never removed from the render tree.
// On Flutter web (CanvasKit) any navigator-level transition can leave the
// canvas layer dirty after dismissal — the Overlay approach avoids this.
// ---------------------------------------------------------------------------

Future<DejavooSaleResult?> showDejavooSaleDialog({
  required BuildContext context,
  required double amount,
  required String tpn,
  required String authKey,
  bool requestProcessorSurcharge = false,
  bool sandbox = false,
  GlobalKey? viewportAnchorKey,
  double viewportCornerRadius = 26,
  EdgeInsets viewportInset = const EdgeInsets.symmetric(vertical: 8),
}) {
  final completer = Completer<DejavooSaleResult?>();
  late OverlayEntry entry;
  var didClose = false;

  void finish(DejavooSaleResult? result) {
    if (didClose) return;
    didClose = true;
    if (entry.mounted) {
      entry.remove();
    }
    if (!completer.isCompleted) {
      completer.complete(result);
    }
  }

  Rect? anchorRect;
  final overlayState = Overlay.of(context, rootOverlay: true);
  final anchorContext = viewportAnchorKey?.currentContext;
  if (anchorContext != null) {
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    final anchorBox = anchorContext.findRenderObject() as RenderBox?;
    if (overlayBox != null && anchorBox != null && anchorBox.hasSize) {
      final topLeft = anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox);
      anchorRect = topLeft & anchorBox.size;
    }
  }

  entry = OverlayEntry(
    builder: (_) {
      final dialog = _DejavooSaleDialog(
        amount: amount,
        tpn: tpn,
        authKey: authKey,
        requestProcessorSurcharge: requestProcessorSurcharge,
        sandbox: sandbox,
        onDone: finish,
      );

      if (anchorRect == null) {
        return dialog;
      }

      return Stack(
        children: [
          Positioned(
            left: anchorRect.left + viewportInset.left,
            top: anchorRect.top + viewportInset.top,
            width: anchorRect.width - viewportInset.left - viewportInset.right,
            height:
                anchorRect.height - viewportInset.top - viewportInset.bottom,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(viewportCornerRadius),
              child: dialog,
            ),
          ),
        ],
      );
    },
  );

  overlayState.insert(entry);
  return completer.future;
}

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------

enum _SaleState { waiting, processing, approved, declined, error }

// ---------------------------------------------------------------------------
// Dialog widget
// ---------------------------------------------------------------------------

class _DejavooSaleDialog extends StatefulWidget {
  const _DejavooSaleDialog({
    required this.amount,
    required this.tpn,
    required this.authKey,
    required this.requestProcessorSurcharge,
    required this.sandbox,
    required this.onDone,
  });

  final double amount;
  final String tpn;
  final String authKey;
  final bool requestProcessorSurcharge;
  final bool sandbox;
  final void Function(DejavooSaleResult?) onDone;

  @override
  State<_DejavooSaleDialog> createState() => _DejavooSaleDialogState();
}

class _DejavooSaleDialogState extends State<_DejavooSaleDialog>
    with TickerProviderStateMixin {
  // -- State ----------------------------------------------------------------
  _SaleState _saleState = _SaleState.waiting;
  DejavooSaleResult? _result;
  String _statusMessage = 'Follow prompts on the terminal';

  // -- Animations -----------------------------------------------------------
  // NFC pulse rings
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  // Card icon bobbing
  late final AnimationController _bobCtrl;
  late final Animation<double> _bobAnim;

  // Result (scale + fade in)
  late final AnimationController _resultCtrl;
  late final Animation<double> _resultScale;
  late final Animation<double> _resultOpacity;

  // -- Service --------------------------------------------------------------
  late final DejavooService _service;

  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();

    _service = DejavooService(
      tpn: widget.tpn,
      authKey: widget.authKey,
      sandbox: widget.sandbox,
      requestProcessorSurcharge: widget.requestProcessorSurcharge,
    );

    // NFC pulse – repeating expand-from-centre
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _pulseAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeOut),
    );

    // Card icon gentle bob
    _bobCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _bobAnim = Tween<double>(begin: -6.0, end: 6.0).animate(
      CurvedAnimation(parent: _bobCtrl, curve: Curves.easeInOut),
    );

    // Result pop-in
    _resultCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _resultScale = CurvedAnimation(parent: _resultCtrl, curve: Curves.elasticOut)
        as Animation<double>;
    _resultOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _resultCtrl,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );

    _startSale();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _bobCtrl.dispose();
    _resultCtrl.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Core flow
  // -------------------------------------------------------------------------

  Future<void> _startSale() async {
    setState(() {
      _saleState = _SaleState.waiting;
      _statusMessage = 'Follow prompts on the terminal';
    });

    final transId =
        DateTime.now().millisecondsSinceEpoch.toString();

    // Brief pause so the dialog is visible before request fires
    await Future.delayed(const Duration(milliseconds: 300));

    setState(() {
      _saleState = _SaleState.processing;
      _statusMessage = 'Communicating with terminal…';
    });

    final result = await _service.sale(
      amount: widget.amount,
      referenceId: transId,
    );

    if (!mounted) return;

    _pulseCtrl.stop();
    _bobCtrl.stop();

    setState(() {
      _result = result;
      switch (result.status) {
        case DejavooSaleStatus.approved:
          _saleState = _SaleState.approved;
          _statusMessage = 'Payment Approved';
          break;
        case DejavooSaleStatus.declined:
          _saleState = _SaleState.declined;
          _statusMessage = result.message;
          break;
        case DejavooSaleStatus.cancelled:
          // Dismiss immediately without staying on screen
          widget.onDone(result);
          return;
        case DejavooSaleStatus.error:
          _saleState = _SaleState.error;
          _statusMessage = result.message;
          break;
      }
    });

    _resultCtrl.forward(from: 0.0);

    // Auto-close after success
    if (result.isApproved) {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) widget.onDone(result);
    }
  }

  void _cancel() {
    _service.cancel();
    widget.onDone(DejavooSaleResult.cancelled());
  }

  void _retry() {
    _pulseCtrl.repeat();
    _bobCtrl.repeat(reverse: true);
    _resultCtrl.reset();
    _startSale();
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;

  @override
  Widget build(BuildContext context) {
    final cs = _cs;
    return Material(
      color: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 3.5, sigmaY: 3.5),
            child: Container(color: cs.surface.withAlpha(185)),
          ),
          Center(
            child: Container(
              width: 380,
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: cs.outlineVariant, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: cs.shadow.withAlpha(60),
                    blurRadius: 32,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(),
                  _buildAmountBadge(),
                  _buildBody(),
                  _buildActions(),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -- Header ---------------------------------------------------------------

  Widget _buildHeader() {
    final cs = _cs;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant, width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.point_of_sale_rounded, color: cs.primary, size: 20),
          const SizedBox(width: 10),
          Text(
            'Card Payment',
            style: _tt.titleMedium?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const Spacer(),
          _buildStateChip(),
        ],
      ),
    );
  }

  Widget _buildStateChip() {
    final cs = _cs;
    Color chipBg;
    String label;
    switch (_saleState) {
      case _SaleState.waiting:
      case _SaleState.processing:
        chipBg = cs.primaryContainer;
        label = 'In Progress';
        break;
      case _SaleState.approved:
        chipBg = cs.secondaryContainer;
        label = 'Approved';
        break;
      case _SaleState.declined:
        chipBg = cs.errorContainer;
        label = 'Declined';
        break;
      case _SaleState.error:
        chipBg = cs.errorContainer;
        label = 'Error';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: _stateColor(),
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  // -- Amount badge ---------------------------------------------------------

  Widget _buildAmountBadge() {
    final cs = _cs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Row(
        children: [
          Text(
            'AMOUNT',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const Spacer(),
          Text(
            '\$${widget.amount.toStringAsFixed(2)}',
            style: _tt.headlineMedium?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }

  // -- Body -----------------------------------------------------------------

  Widget _buildBody() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: _isActive
            ? _buildWaitingBody()
            : _buildResultBody(),
      ),
    );
  }

  bool get _isActive =>
      _saleState == _SaleState.waiting ||
      _saleState == _SaleState.processing;

  // -- Waiting / processing body --------------------------------------------

  Widget _buildWaitingBody() {
    final primary = _cs.primary;
    final primaryContainer = _cs.primaryContainer;
    final onSurface = _cs.onSurface;
    final onSurfaceVariant = _cs.onSurfaceVariant;
    return Column(
      key: const ValueKey('waiting'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 140,
          height: 140,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // NFC pulse rings
              ...List.generate(3, (i) {
                return AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, _) {
                    final offset = i / 3.0;
                    final t = (_pulseAnim.value + offset) % 1.0;
                    final radius = 44.0 + t * 46.0;
                    final opacity = (1.0 - t).clamp(0.0, 1.0) * 0.45;
                    return Container(
                      width: radius * 2,
                      height: radius * 2,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: primary.withAlpha(
                            (opacity * 255).round(),
                          ),
                          width: 1.5,
                        ),
                      ),
                    );
                  },
                );
              }),
              // Card icon
              AnimatedBuilder(
                animation: _bobAnim,
                builder: (_, child) => Transform.translate(
                  offset: Offset(0, _bobAnim.value),
                  child: child,
                ),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: primaryContainer,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: primary.withAlpha(60),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.contactless_rounded,
                    color: primary,
                    size: 36,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text(
          _saleState == _SaleState.processing
              ? 'Processing…'
              : 'Ready',
          style: TextStyle(
            color: primary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _statusMessage,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: onSurface,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Tap, insert, or swipe card on terminal',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        if (_saleState == _SaleState.processing) ...[
          const SizedBox(height: 20),
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: primary,
            ),
          ),
        ],
      ],
    );
  }

  // -- Result body ----------------------------------------------------------

  Widget _buildResultBody() {
    final cs = _cs;
    final isApproved = _saleState == _SaleState.approved;
    final isDeclined = _saleState == _SaleState.declined;

    return AnimatedBuilder(
      animation: _resultCtrl,
      builder: (_, child) => Opacity(
        opacity: _resultOpacity.value,
        child: Transform.scale(
          scale: 0.7 + 0.3 * _resultScale.value.clamp(0.0, 1.0),
          child: child,
        ),
      ),
      child: Column(
        key: const ValueKey('result'),
        mainAxisSize: MainAxisSize.min,
        children: [
          // Icon circle
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: _stateColor().withAlpha(20),
              shape: BoxShape.circle,
              border: Border.all(color: _stateColor().withAlpha(80), width: 2),
            ),
            child: Icon(
              isApproved
                  ? Icons.check_circle_outline_rounded
                  : isDeclined
                      ? Icons.cancel_outlined
                      : Icons.wifi_off_rounded,
              color: _stateColor(),
              size: 44,
            ),
          ),
          const SizedBox(height: 20),
          SelectableText(
            _statusMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _stateColor(),
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (isApproved && _result != null) ...[
            const SizedBox(height: 16),
            _buildApprovedDetails(),
          ] else if (!isApproved) ...[
            const SizedBox(height: 10),
            if (_result?.message.isNotEmpty == true &&
                _result!.message != _statusMessage)
              SelectableText(
                _result!.message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildApprovedDetails() {
    final cs = _cs;
    final r = _result!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.secondary.withAlpha(80)),
      ),
      child: Column(
        children: [
          if (r.cardType != null)
            _detailRow(Icons.credit_card_rounded, r.cardType!),
          if (r.last4 != null)
            _detailRow(Icons.lock_outline_rounded, '•••• ${r.last4}'),
          if (r.authCode != null)
            _detailRow(Icons.verified_outlined, 'Auth: ${r.authCode}'),
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String text) {
    final cs = _cs;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 15, color: cs.secondary),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: cs.onSecondaryContainer,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // -- Actions --------------------------------------------------------------

  Widget _buildActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: _buildActionButtons(),
      ),
    );
  }

  Widget _buildActionButtons() {
    final cs = _cs;
    switch (_saleState) {
      case _SaleState.waiting:
      case _SaleState.processing:
        return _actionButton(
          key: const ValueKey('cancel'),
          label: 'Cancel',
          icon: Icons.close_rounded,
          color: cs.surfaceContainerHighest,
          textColor: cs.onSurfaceVariant,
          onTap: _cancel,
        );

      case _SaleState.approved:
        return _actionButton(
          key: const ValueKey('done'),
          label: 'Done',
          icon: Icons.check_rounded,
          color: cs.secondaryContainer,
          textColor: cs.secondary,
          onTap: () => widget.onDone(_result),
        );

      case _SaleState.declined:
        return Row(
          key: const ValueKey('declined-actions'),
          children: [
            Expanded(
              child: _actionButton(
                label: 'Close',
                icon: Icons.close_rounded,
                color: cs.surfaceContainerHighest,
                textColor: cs.onSurfaceVariant,
                onTap: () => widget.onDone(_result),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _actionButton(
                label: 'Try Again',
                icon: Icons.refresh_rounded,
                color: cs.primaryContainer,
                textColor: cs.primary,
                onTap: _retry,
              ),
            ),
          ],
        );

      case _SaleState.error:
        return Row(
          key: const ValueKey('error-actions'),
          children: [
            Expanded(
              child: _actionButton(
                label: 'Close',
                icon: Icons.close_rounded,
                color: cs.surfaceContainerHighest,
                textColor: cs.onSurfaceVariant,
                onTap: () => widget.onDone(_result),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _actionButton(
                label: 'Retry',
                icon: Icons.refresh_rounded,
                color: cs.errorContainer,
                textColor: cs.error,
                onTap: _retry,
              ),
            ),
          ],
        );
    }
  }

  Widget _actionButton({
    Key? key,
    required String label,
    required IconData icon,
    required Color color,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: textColor, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -- Helpers --------------------------------------------------------------

  Color _stateColor() {
    final cs = _cs;
    switch (_saleState) {
      case _SaleState.waiting:
      case _SaleState.processing:
        return cs.primary;
      case _SaleState.approved:
        return cs.secondary;
      case _SaleState.declined:
        return cs.error;
      case _SaleState.error:
        return cs.tertiary;
    }
  }
}
