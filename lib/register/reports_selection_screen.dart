import 'package:flutter/material.dart';

import '../widgets/standard_action_button.dart';

class ReportsSelectionScreen extends StatelessWidget {
  const ReportsSelectionScreen({
    super.key,
    this.embedded = false,
    this.tipsAllowed = false,
    this.onSelectReport,
    this.onClose,
  });

  static const String viewTransactionsReportId = 'view_transactions';
  static const String tipAdjustmentsReportId = 'tip_adjustments';

  final bool embedded;
  final bool tipsAllowed;
  final ValueChanged<String>? onSelectReport;
  final VoidCallback? onClose;

  void _handleSelect(BuildContext context, String reportId) {
    if (onSelectReport != null) {
      onSelectReport!(reportId);
      return;
    }
    Navigator.of(context).pop(reportId);
  }

  Widget _buildBody(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Reports & Functions',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              if (embedded && onClose != null)
                IconButton(
                  tooltip: 'Close',
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: StandardActionButton(
                  label: 'View Transactions',
                  icon: Icons.receipt_long_outlined,
                  iconColor: const Color(0xFF2E7D32),
                  iconBackgroundColor: const Color(0xFFE8F5E9),
                  labelFontScale: 0.85,
                  onTap: () => _handleSelect(context, viewTransactionsReportId),
                ),
              ),
              if (tipsAllowed) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: StandardActionButton(
                    label: 'Open Transactions',
                    icon: Icons.tips_and_updates_outlined,
                    iconColor: const Color(0xFFEF6C00),
                    iconBackgroundColor: const Color(0xFFFFF3E0),
                    labelFontScale: 0.85,
                    onTap: () =>
                        _handleSelect(context, tipAdjustmentsReportId),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (embedded) return _buildBody(context);

    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports & Functions'),
        backgroundColor: cs.surface,
      ),
      body: _buildBody(context),
    );
  }
}
