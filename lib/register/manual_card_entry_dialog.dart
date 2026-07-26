import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ManualCardEntryResult {
  const ManualCardEntryResult({
    required this.cardNumber,
    required this.expirationDate,
    required this.cvv,
    required this.streetAddress,
    required this.zipCode,
  });

  final String cardNumber;
  final String expirationDate;
  final String cvv;
  final String streetAddress;
  final String zipCode;
}

Future<ManualCardEntryResult?> showManualCardEntryDialog({
  required BuildContext context,
  required double amount,
}) {
  return showDialog<ManualCardEntryResult>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withOpacity(0.5),
    builder: (dialogContext) => _ManualCardEntryDialog(amount: amount),
  );
}

class _ManualCardEntryDialog extends StatefulWidget {
  const _ManualCardEntryDialog({required this.amount});

  final double amount;

  @override
  State<_ManualCardEntryDialog> createState() => _ManualCardEntryDialogState();
}

class _ManualCardEntryDialogState extends State<_ManualCardEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  final _cardNumberController = TextEditingController();
  final _expirationController = TextEditingController();
  final _cvvController = TextEditingController();
  final _streetAddressController = TextEditingController();
  final _zipController = TextEditingController();

  @override
  void dispose() {
    _cardNumberController.dispose();
    _expirationController.dispose();
    _cvvController.dispose();
    _streetAddressController.dispose();
    _zipController.dispose();
    super.dispose();
  }

  String _digitsOnly(String value) => value.replaceAll(RegExp(r'[^0-9]'), '');

  bool _passesLuhn(String value) {
    final digits = _digitsOnly(value);
    if (digits.length < 12 || digits.length > 19) return false;

    var sum = 0;
    var shouldDouble = false;
    for (var index = digits.length - 1; index >= 0; index--) {
      var digit = int.parse(digits[index]);
      if (shouldDouble) {
        digit *= 2;
        if (digit > 9) digit -= 9;
      }
      sum += digit;
      shouldDouble = !shouldDouble;
    }
    return sum % 10 == 0;
  }

  String? _validateCardNumber(String? value) {
    final digits = _digitsOnly(value ?? '');
    if (digits.isEmpty) return 'Enter the card number';
    if (!_passesLuhn(digits)) return 'Enter a valid card number';
    return null;
  }

  String? _validateExpiration(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return 'Enter expiration date';
    final match = RegExp(r'^(\d{2})/(\d{2})$').firstMatch(raw);
    if (match == null) return 'Use MM/YY';

    final month = int.tryParse(match.group(1)!);
    final year = int.tryParse(match.group(2)!);
    if (month == null || year == null || month < 1 || month > 12) {
      return 'Enter a valid expiration date';
    }

    final now = DateTime.now();
    final fullYear = 2000 + year;
    final expiry = DateTime(fullYear, month + 1, 0);
    final currentMonth = DateTime(now.year, now.month + 1, 0);
    if (expiry.isBefore(currentMonth)) return 'Card is expired';
    return null;
  }

  String? _validateCvv(String? value) {
    final digits = _digitsOnly(value ?? '');
    if (digits.isEmpty) return 'Enter CVV';
    if (digits.length < 3 || digits.length > 4)
      return 'CVV must be 3 or 4 digits';
    return null;
  }

  String? _validateStreetAddress(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return null;
    if (text.length < 4) return 'Street address looks too short';
    return null;
  }

  String? _validateZip(String? value) {
    final digits = _digitsOnly(value ?? '');
    if (digits.isEmpty) return null;
    if (digits.length != 5 && digits.length != 9) {
      return 'ZIP must be 5 or 9 digits';
    }
    return null;
  }

  InputDecoration _fieldDecoration({
    required String label,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 18),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFD8E0EA)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFF2A5CAA), width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }

  Future<void> _handleContinue() async {
    if (!_formKey.currentState!.validate()) return;
    if (!mounted) return;
    Navigator.of(context).pop(
      ManualCardEntryResult(
        cardNumber: _digitsOnly(_cardNumberController.text),
        expirationDate: _expirationController.text.trim(),
        cvv: _digitsOnly(_cvvController.text),
        streetAddress: _streetAddressController.text.trim(),
        zipCode: _digitsOnly(_zipController.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      backgroundColor: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: const Color(0xFFF6F8FB),
          borderRadius: BorderRadius.circular(28),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 28,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(22, 20, 18, 18),
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                gradient: LinearGradient(
                  colors: [Color(0xFF163B66), Color(0xFF2B5EA7)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.credit_card,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Manual Card Entry',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Key in the card details for a terminal with no reader configured.',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.84),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF1FB),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFCFDCEE)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.receipt_long, color: cs.primary, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Charge Amount',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '\$${widget.amount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: Color(0xFF163B66),
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 22),
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _cardNumberController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                          LengthLimitingTextInputFormatter(23),
                        ],
                        decoration: _fieldDecoration(
                          label: 'Card Number',
                          icon: Icons.credit_card_outlined,
                        ),
                        validator: _validateCardNumber,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _expirationController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9/]'),
                                ),
                                LengthLimitingTextInputFormatter(5),
                                _ExpiryDateInputFormatter(),
                              ],
                              decoration: _fieldDecoration(
                                label: 'Expiration MM/YY',
                                icon: Icons.event,
                              ),
                              validator: _validateExpiration,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _cvvController,
                              keyboardType: TextInputType.number,
                              obscureText: true,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(4),
                              ],
                              decoration: _fieldDecoration(
                                label: 'CVV Code',
                                icon: Icons.shield_outlined,
                              ),
                              validator: _validateCvv,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _streetAddressController,
                        textCapitalization: TextCapitalization.words,
                        decoration: _fieldDecoration(
                          label: 'Street Address (Optional)',
                          icon: Icons.home_outlined,
                        ),
                        validator: _validateStreetAddress,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _zipController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(9),
                        ],
                        decoration: _fieldDecoration(
                          label: 'ZIP Code (Optional)',
                          icon: Icons.markunread_mailbox_outlined,
                        ),
                        validator: _validateZip,
                      ),
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7EA),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFF1D8A8)),
                        ),
                        child: const Text(
                          'Card data is validated in-memory only. Nothing from this form should be logged or stored until the processor submission path is completed.',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF6C5310),
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _handleContinue,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF163B66),
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      icon: const Icon(Icons.arrow_forward_rounded),
                      label: const Text('Continue'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpiryDateInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length <= 2) {
      return TextEditingValue(
        text: digits,
        selection: TextSelection.collapsed(offset: digits.length),
      );
    }

    final formatted =
        '${digits.substring(0, 2)}/${digits.substring(2, digits.length.clamp(2, 4))}';
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
