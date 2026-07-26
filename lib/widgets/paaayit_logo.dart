import 'package:flutter/material.dart';

class PaaayitLogo extends StatelessWidget {
  const PaaayitLogo({
    super.key,
    this.size = 28,
  });

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icons/Blue transparent-logo.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}
