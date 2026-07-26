import 'package:flutter/material.dart';

class CredentialLoginFields extends StatefulWidget {
  const CredentialLoginFields({
    required this.userIdController,
    required this.passwordController,
    this.userIdLabel = 'User ID',
    this.passwordLabel = 'Password',
    this.enabled = true,
    this.onSubmitted,
    super.key,
  });

  final TextEditingController userIdController;
  final TextEditingController passwordController;
  final String userIdLabel;
  final String passwordLabel;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  State<CredentialLoginFields> createState() => _CredentialLoginFieldsState();
}

class _CredentialLoginFieldsState extends State<CredentialLoginFields> {
  bool _obscurePassword = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: widget.userIdController,
          enabled: widget.enabled,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.username],
          decoration: InputDecoration(
            labelText: widget.userIdLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: widget.passwordController,
          enabled: widget.enabled,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.password],
          onFieldSubmitted: (_) => widget.onSubmitted?.call(),
          decoration: InputDecoration(
            labelText: widget.passwordLabel,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _obscurePassword ? 'Show password' : 'Hide password',
              onPressed: widget.enabled
                  ? () => setState(() {
                      _obscurePassword = !_obscurePassword;
                    })
                  : null,
              icon: Icon(
                _obscurePassword ? Icons.visibility : Icons.visibility_off,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
