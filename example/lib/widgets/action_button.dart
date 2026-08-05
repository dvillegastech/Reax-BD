import 'package:flutter/material.dart';

/// A labelled button used by the demo screens.
///
/// Passing a null [onPressed] disables the button, which the demos use while
/// an operation is running.
class ActionButton extends StatelessWidget {
  /// Creates an action button.
  const ActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.tonal = false,
  });

  /// Text shown on the button.
  final String label;

  /// Leading icon.
  final IconData icon;

  /// Called when the button is tapped, or null to disable it.
  final VoidCallback? onPressed;

  /// Whether to render the lower-emphasis tonal style.
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    final Widget iconWidget = Icon(icon, size: 18);
    final Widget labelWidget = Text(label);
    if (tonal) {
      return FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: iconWidget,
        label: labelWidget,
      );
    }
    return FilledButton.icon(
      onPressed: onPressed,
      icon: iconWidget,
      label: labelWidget,
    );
  }
}
