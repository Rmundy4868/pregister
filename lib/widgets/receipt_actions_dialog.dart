import 'dart:ui';

import 'package:flutter/material.dart';

typedef ReceiptEmailValidator = bool Function(String value);

bool defaultReceiptEmailValidator(String value) {
  final email = value.trim();
  if (email.isEmpty) return false;
  return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email);
}

Future<void> showReceiptActionsDialog({
  required BuildContext context,
  required String title,
  required double amount,
  required String cardType,
  required String cardLast4,
  required String authCode,
  required String initialEmail,
  required Future<void> Function() onPrintCustomer,
  required Future<void> Function(String recipientEmail) onEmailReceipt,
  ReceiptEmailValidator? emailValidator,
  Widget? previewSection,
  String printButtonLabel = 'Print Customer',
  String emailButtonLabel = 'Email Receipt',
  String actionsLabel = 'Receipt Actions',
  String doneButtonLabel = 'Done',
  String emailLabelText = 'Email Receipt To',
  String emailHintText = 'name@domain.com',
  String invalidEmailMessage = 'Enter a valid email address to continue.',
  bool barrierDismissible = false,
}) async {
  final validator = emailValidator ?? defaultReceiptEmailValidator;
  final emailController = TextEditingController(text: initialEmail);
  String? emailError;
  String? emailSentMessage;
  var isWorking = false;

  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: Colors.black.withOpacity(0.3),
      useRootNavigator: true,
      builder: (dialogContext) {
        final screenSize = MediaQuery.of(dialogContext).size;
        final maxWidth = (screenSize.width * 0.6).clamp(300.0, 360.0);
        final maxHeight = (screenSize.height * 0.75).clamp(400.0, 520.0);

        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
          child: StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              Future<void> runAction(Future<void> Function() action) async {
                setDialogState(() {
                  isWorking = true;
                });
                try {
                  await action();
                } finally {
                  if (dialogContext.mounted) {
                    setDialogState(() {
                      isWorking = false;
                    });
                  }
                }
              }

              final trimmedCardType = cardType.trim();
              final trimmedCardLast4 = cardLast4.trim();
              final trimmedAuthCode = authCode.trim();
              final maskedCard = trimmedCardLast4.isNotEmpty
                  ? ' ****$trimmedCardLast4'
                  : '';

              return AlertDialog(
                title: Text(title),
                content: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: maxWidth,
                    maxHeight: maxHeight,
                  ),
                  child: SizedBox(
                    width: maxWidth,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Amount: \$${amount.toStringAsFixed(2)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Card: ${trimmedCardType.isEmpty ? 'Card' : trimmedCardType}$maskedCard',
                          ),
                          if (trimmedAuthCode.isNotEmpty)
                            Text('Auth: $trimmedAuthCode'),
                          if (previewSection != null) ...[
                            const SizedBox(height: 14),
                            previewSection,
                          ],
                          const SizedBox(height: 14),
                          Text(
                            actionsLabel,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: isWorking
                                    ? null
                                    : () => runAction(onPrintCustomer),
                                icon: const Icon(Icons.receipt_long_outlined),
                                label: Text(printButtonLabel),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              labelText: emailLabelText,
                              hintText: emailHintText,
                              errorText: emailError,
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (_) {
                              if (emailError != null ||
                                  emailSentMessage != null) {
                                setDialogState(() {
                                  emailError = null;
                                  emailSentMessage = null;
                                });
                              }
                            },
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: isWorking
                                ? null
                                : () async {
                                    final email = emailController.text.trim();
                                    if (email.isEmpty || !validator(email)) {
                                      setDialogState(() {
                                        emailError = invalidEmailMessage;
                                      });
                                      return;
                                    }

                                    await runAction(() async {
                                      try {
                                        await onEmailReceipt(email);
                                        if (dialogContext.mounted) {
                                          setDialogState(() {
                                            emailError = null;
                                            emailSentMessage =
                                                'Receipt email sent to $email.';
                                          });
                                        }
                                      } catch (error) {
                                        final message = error
                                            .toString()
                                            .replaceFirst('Exception: ', '')
                                            .trim();
                                        if (dialogContext.mounted) {
                                          setDialogState(() {
                                            emailSentMessage = null;
                                            emailError = message.isNotEmpty
                                                ? message
                                                : 'Unable to send receipt email right now.';
                                          });
                                        }
                                      }
                                    });
                                  },
                            icon: const Icon(Icons.email_outlined),
                            label: Text(emailButtonLabel),
                          ),
                          if (emailSentMessage != null) ...[
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFD1FADF),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                emailSentMessage!,
                                style: const TextStyle(
                                  color: Color(0xFF065F46),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                actions: [
                  FilledButton(
                    onPressed: isWorking
                        ? null
                        : () => Navigator.of(dialogContext).pop(),
                    child: Text(doneButtonLabel),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  } finally {
    emailController.dispose();
  }
}
