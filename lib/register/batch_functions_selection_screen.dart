import 'package:flutter/material.dart';

class BatchFunctionsSelectionScreen extends StatelessWidget {
  const BatchFunctionsSelectionScreen({
    super.key,
    this.embedded = false,
    this.onSelectFunction,
    this.onClose,
  });

  static const String openBatchReportFunctionId = 'open_batch_report';
  static const String openBatchFunctionId = 'open_batch';
  static const String closedBatchFunctionId = 'closed_batch';
  static const String closeBatchFunctionId = 'close_batch';

  final bool embedded;
  final ValueChanged<String>? onSelectFunction;
  final VoidCallback? onClose;

  void _handleSelect(BuildContext context, String functionId) {
    if (onSelectFunction != null) {
      onSelectFunction!(functionId);
      return;
    }
    Navigator.of(context).pop(functionId);
  }

  Widget _buildBody(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final quickButtons = <({String label, IconData icon, String functionId})>[
      (
        label: 'View Open Batch',
        icon: Icons.view_list_rounded,
        functionId: openBatchFunctionId,
      ),
      (
        label: 'Closed Batches',
        icon: Icons.inventory_2_outlined,
        functionId: closedBatchFunctionId,
      ),
      (
        label: 'Open Batch Report',
        icon: Icons.receipt_long_outlined,
        functionId: openBatchReportFunctionId,
      ),
      (
        label: 'Close Batch',
        icon: Icons.lock_clock_outlined,
        functionId: closeBatchFunctionId,
      ),
    ];

    Color tileBackgroundForLabel(String label) {
      switch (label) {
        case 'View Open Batch':
          return const Color(0xFFE0F2F1);
        case 'Closed Batches':
          return const Color(0xFFE8EAF6);
        case 'Open Batch Report':
          return const Color(0xFFF3E5F5);
        case 'Close Batch':
          return const Color(0xFFE8F5E9);
        default:
          return const Color(0xFFF5F7FA);
      }
    }

    Color tileIconColorForLabel(String label) {
      switch (label) {
        case 'View Open Batch':
          return const Color(0xFF00695C);
        case 'Closed Batches':
          return const Color(0xFF283593);
        case 'Open Batch Report':
          return const Color(0xFF6A1B9A);
        case 'Close Batch':
          return const Color(0xFF2E7D32);
        default:
          return const Color(0xFF37474F);
      }
    }

    double tileFontSizeForLabel(String label) {
      switch (label) {
        case 'Open Batch Report':
          return 10.0;
        default:
          return 11.0;
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Batch Functions',
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
          GridView.builder(
            itemCount: quickButtons.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 0,
              crossAxisSpacing: 0,
              mainAxisExtent: 84,
            ),
            itemBuilder: (context, index) {
              final button = quickButtons[index];
              final backgroundColor = tileBackgroundForLabel(button.label);
              final iconColor = tileIconColorForLabel(button.label);

              return Padding(
                padding: const EdgeInsets.all(3),
                child: Material(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _handleSelect(context, button.functionId),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: backgroundColor,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: cs.outlineVariant, width: 1),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: backgroundColor,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Icon(button.icon, size: 15.5, color: iconColor),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            button.label,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: tileFontSizeForLabel(button.label),
                              fontWeight: FontWeight.w700,
                              height: 1.1,
                              color: cs.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
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
        title: const Text('Batch Functions'),
        backgroundColor: cs.surface,
      ),
      body: _buildBody(context),
    );
  }
}