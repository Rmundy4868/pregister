import 'package:flutter/material.dart';

class StandardActionButton extends StatelessWidget {
  const StandardActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.iconColor = const Color(0xFF37474F),
    this.iconBackgroundColor = const Color(0xFFF5F7FA),
    this.compact = false,
    this.small = false,
    this.xsmall = false,
    this.labelFontScale = 1.0,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final Color iconColor;
  final Color iconBackgroundColor;
  final bool compact;
  final bool small;
  final bool xsmall;
  final double labelFontScale;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dense = compact || small || xsmall;
    final horizontalPadding = xsmall ? 4.0 : (small ? 6.0 : (dense ? 8.0 : 10.0));
    final verticalPadding = xsmall ? 3.0 : (small ? 6.0 : (dense ? 7.0 : 9.0));
    final iconSize = xsmall ? 10.0 : (small ? 12.0 : (dense ? 14.0 : 16.0));
    final iconBoxSize = xsmall ? 16.0 : (small ? 20.0 : (dense ? 24.0 : 28.0));
    final gap = xsmall ? 3.0 : (small ? 5.0 : (dense ? 6.0 : 8.0));
    final baseLabelFontSize =
      xsmall ? 10.5 : (small ? 12.0 : (dense ? 13.0 : 14.0));
    final labelFontSize = baseLabelFontSize * labelFontScale;
    final cornerRadius = xsmall ? 8.0 : (small ? 10.0 : 12.0);

    return Opacity(
      opacity: onTap == null ? 0.6 : 1,
      child: Material(
        color: cs.surface,
        borderRadius: BorderRadius.circular(cornerRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(cornerRadius),
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(cornerRadius),
              border: Border.all(color: cs.outlineVariant, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: iconBoxSize,
                  height: iconBoxSize,
                  decoration: BoxDecoration(
                    color: iconBackgroundColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: iconSize, color: iconColor),
                ),
                SizedBox(width: gap),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: labelFontSize,
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
  }
}

class StandardPanel extends StatelessWidget {
  const StandardPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant, width: 1),
      ),
      child: child,
    );
  }
}

class StandardMetricTile extends StatelessWidget {
  const StandardMetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.iconColor = const Color(0xFF37474F),
    this.iconBackgroundColor = const Color(0xFFF5F7FA),
    this.compact = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;
  final Color iconBackgroundColor;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final panelPadding = compact
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 6)
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 8);
    final iconBoxSize = compact ? 20.0 : 24.0;
    final iconSize = compact ? 12.0 : 14.0;
    final valueFont = compact ? 12.0 : 13.0;
    final labelFont = compact ? 10.0 : 10.5;
    return StandardPanel(
      padding: panelPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: iconBoxSize,
            height: iconBoxSize,
            decoration: BoxDecoration(
              color: iconBackgroundColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: iconSize, color: iconColor),
          ),
          SizedBox(height: compact ? 3 : 4),
          Text(
            value,
            style: TextStyle(fontSize: valueFont, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            style: TextStyle(
              fontSize: labelFont,
              fontWeight: FontWeight.w500,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
