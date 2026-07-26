import 'package:flutter/material.dart';

enum AmbientBackgroundStyle { subtle, cinematic }

class TerminalAmbientBackground extends StatelessWidget {
  const TerminalAmbientBackground({
    super.key,
    required this.child,
    this.style = AmbientBackgroundStyle.subtle,
  });

  final Widget child;
  final AmbientBackgroundStyle style;

  @override
  Widget build(BuildContext context) {
    final isCinematic = style == AmbientBackgroundStyle.cinematic;

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isCinematic
                  ? const [
                      Color(0xFF1E1E1E),
                      Color(0xFF252526),
                      Color(0xFF1B1B1C),
                    ]
                  : const [
                      Color(0xFFF9FBFF),
                      Color(0xFFEFF5FD),
                      Color(0xFFF7FAFF),
                    ],
            ),
          ),
        ),
        Positioned(
          left: isCinematic ? -150 : -120,
          top: isCinematic ? -110 : -80,
          child: _AmbientBlob(
            width: isCinematic ? 380 : 320,
            height: isCinematic ? 260 : 220,
            color: isCinematic
                ? const Color(0x4A3FBCF3)
                : const Color(0x2D3FBCF3),
          ),
        ),
        Positioned(
          right: isCinematic ? -130 : -90,
          top: isCinematic ? 90 : 120,
          child: _AmbientBlob(
            width: isCinematic ? 320 : 260,
            height: isCinematic ? 220 : 180,
            color: isCinematic
                ? const Color(0x384CBB17)
                : const Color(0x244CBB17),
          ),
        ),
        Positioned(
          left: isCinematic ? 10 : 30,
          bottom: isCinematic ? -130 : -110,
          child: _AmbientBlob(
            width: isCinematic ? 360 : 300,
            height: isCinematic ? 250 : 210,
            color: isCinematic
                ? const Color(0x363FBCF3)
                : const Color(0x1F3FBCF3),
          ),
        ),
        Positioned(
          right: isCinematic ? 12 : 24,
          bottom: isCinematic ? 26 : 40,
          child: Transform.rotate(
            angle: isCinematic ? 0.24 : 0.18,
            child: Container(
              width: isCinematic ? 220 : 160,
              height: isCinematic ? 130 : 96,
              decoration: BoxDecoration(
                color: isCinematic
                    ? const Color(0x203FBCF3)
                    : const Color(0x123FBCF3),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isCinematic
                      ? const Color(0x343FBCF3)
                      : const Color(0x1F3FBCF3),
                  width: 1.1,
                ),
              ),
            ),
          ),
        ),
        if (isCinematic)
          const Positioned(
            left: -70,
            bottom: -40,
            child: _AmbientBlob(
              width: 260,
              height: 180,
              color: Color(0x1A2A2F35),
            ),
          ),
        if (isCinematic)
          const Positioned(
            right: -80,
            top: -30,
            child: _AmbientBlob(
              width: 280,
              height: 190,
              color: Color(0x1421262C),
            ),
          ),
        if (isCinematic)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 0.92,
                    colors: const [
                      Color(0x00000000),
                      Color(0x1E1A2230),
                    ],
                    stops: const [0.62, 1.0],
                  ),
                ),
              ),
            ),
          ),
        if (isCinematic)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: const [
                      Color(0x0D1E2228),
                      Color(0x00000000),
                      Color(0x121A1F25),
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
          ),
        child,
      ],
    );
  }
}

class _AmbientBlob extends StatelessWidget {
  const _AmbientBlob({
    required this.width,
    required this.height,
    required this.color,
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(width),
          boxShadow: [
            BoxShadow(
              color: color,
              blurRadius: 70,
              spreadRadius: 24,
            ),
          ],
        ),
      ),
    );
  }
}