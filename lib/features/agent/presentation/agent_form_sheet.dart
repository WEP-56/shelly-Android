import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Bottom sheet for the agent forms.
///
/// The height tracks the keyboard so a focused field is never left underneath it.
Future<T?> showAgentFormSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double heightFactor = 0.9,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      final insets = MediaQuery.viewInsetsOf(context).bottom;
      final available = MediaQuery.sizeOf(context).height * heightFactor;
      return Padding(
        padding: EdgeInsets.only(bottom: insets),
        child: SizedBox(
          height: available - insets < 260 ? 260 : available - insets,
          child: builder(context),
        ),
      );
    },
  );
}

/// Labelled form field shared by the agent setting forms.
class AgentFormField extends StatelessWidget {
  const AgentFormField({
    required this.controller,
    required this.label,
    this.hint,
    this.helper,
    this.keyboardType,
    this.inputFormatters,
    this.obscureText = false,
    this.suffix,
    this.maxLines = 1,
    this.maxLength,
    this.enabled = true,
    this.validator,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final bool obscureText;
  final Widget? suffix;
  final int maxLines;
  final int? maxLength;
  final bool enabled;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        obscureText: obscureText,
        enabled: enabled,
        maxLines: obscureText ? 1 : maxLines,
        minLines: 1,
        maxLength: maxLength,
        validator: validator,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 3,
          suffixIcon: suffix,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}
