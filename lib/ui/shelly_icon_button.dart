import 'package:flutter/material.dart';

import '../app/app_theme.dart';

class ShellyIconButton extends StatelessWidget {
  const ShellyIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
    this.size = 21,
    this.dimension = 44,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;
  final double size;
  final double dimension;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: dimension,
        child: Material(
          color: active ? colors.surface3 : Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Icon(icon, size: size, color: colors.onSurface),
          ),
        ),
      ),
    );
  }
}
