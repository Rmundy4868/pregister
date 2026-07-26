import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class RegisterSaleLogo extends StatelessWidget {
  const RegisterSaleLogo({
    super.key,
    this.height = 66.9,
    this.widthFactor = 0.78,
  });

  final double height;
  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    const baseAspectRatio = 3.2;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final logo = SvgPicture.asset(
              'assets/icons/Blue transparent-logo.svg',
              fit: BoxFit.contain,
            );

            if (constraints.hasBoundedWidth && constraints.maxWidth.isFinite) {
              return Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: constraints.maxWidth * widthFactor,
                  child: logo,
                ),
              );
            }

            final resolvedAspect = (baseAspectRatio * widthFactor).clamp(
              1.0,
              6.0,
            );

            return Align(
              alignment: Alignment.centerLeft,
              child: AspectRatio(aspectRatio: resolvedAspect, child: logo),
            );
          },
        ),
      ),
    );
  }
}
