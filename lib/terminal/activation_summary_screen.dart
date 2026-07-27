// ignore_for_file: deprecated_member_use

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../login/login_screen.dart';
import '../services/license_service.dart';
import '../terminal_config.dart';
import '../utils/text_file_save.dart';
import 'terminal_activation_screen.dart';

/// Post-activation validation screen that displays every resolved operating
/// parameter so the installer can verify the terminal is configured correctly
/// before handing it over.
class ActivationSummaryScreen extends StatelessWidget {
  final LicenseActivationResult result;
  final String deviceId;
  final String deviceLabel;

  const ActivationSummaryScreen({
    super.key,
    required this.result,
    required this.deviceId,
    required this.deviceLabel,
  });

  @override
  Widget build(BuildContext context) {
    final ctx = result.context;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: -140,
              right: -120,
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF1D4ED8).withOpacity(0.10),
                ),
              ),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 28,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeaderCard(),
                      const SizedBox(height: 16),
                      _section('Identity', [
                        _row('Device ID', _val(deviceId)),
                        _row('Device Label', _val(deviceLabel)),
                      ]),
                      const SizedBox(height: 12),
                      _section('Organization', [
                        _row('Organization Name', _val(ctx?.organizationName)),
                        _row(
                          'Organization Number',
                          _val(ctx?.organizationNumber),
                        ),
                        _row(
                          'Organization ID',
                          _val(ctx?.organizationId.toString()),
                        ),
                        _row('License Key', _val(ctx?.licenseKey)),
                      ]),
                      const SizedBox(height: 12),
                      _section('Location', [
                        _row('Location Name', _val(ctx?.locationName)),
                        _row('Location ID', _val(ctx?.locationId.toString())),
                      ]),
                      const SizedBox(height: 12),
                      _section('Terminal', [
                        _row('Terminal Name', _val(ctx?.terminalName)),
                        _row('Terminal Number', _val(ctx?.terminalNumber)),
                        _row('Terminal ID', _val(ctx?.terminalId.toString())),
                        _row(
                          'Terminal Licenses',
                          _val(ctx?.terminalLicenses.toString()),
                        ),
                        _row(
                          'Terminals Active',
                          _val(ctx?.terminalsActive.toString()),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      _section('Payment Configuration', [
                        _row(
                          'Card Reader Type',
                          _val(TerminalConfig.cardReaderType),
                        ),
                        _row('SPIn TPN', _val(TerminalConfig.spinTpn)),
                        _row(
                          'SPIn Auth Key',
                          _masked(TerminalConfig.spinAuthKey),
                        ),
                        _row(
                          'HPP Auth Token',
                          _masked(TerminalConfig.cardReaderHppAuthToken),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      _section('Default Staff (Owner)', [
                        _row(
                          'Name',
                          _val(
                            result.defaultStaffName.isNotEmpty
                                ? result.defaultStaffName
                                : null,
                          ),
                        ),
                        _row(
                          'Staff ID',
                          _val(
                            result.defaultStaffId.isNotEmpty
                                ? result.defaultStaffId
                                : null,
                          ),
                        ),
                        _row('Role', 'owner'),
                        _row(
                          'PIN',
                          result.defaultStaffName.isNotEmpty ? '● ● ● ●' : '—',
                        ),
                      ]),
                      const SizedBox(height: 16),
                      _buildActionCard(context),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Navigation ──────────────────────────────────────────────────────────

  void _goToLogin(BuildContext context) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
    );
  }

  Future<void> _confirmWipe(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wipe Activation?'),
        content: const Text(
          'This will release this install activation, clear local credentials, '
          'and return to the activation screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Wipe'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await LicenseService().releaseAndClearActivationState();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const TerminalActivationScreen()),
    );
  }

  void _downloadShortcut(BuildContext context) {
    if (!kIsWeb) return;
    final ctx = result.context;
    final licenseKey = ctx?.licenseKey ?? '';
    final terminalNumber = ctx?.terminalNumber ?? '';
    final locationName = ctx?.locationName ?? '';

    final baseUrl = Uri.base.origin;
    final params = Uri(
      queryParameters: {
        'lk': licenseKey,
        'tn': terminalNumber,
        if (locationName.isNotEmpty) 'loc': locationName,
      },
    ).query;
    final shortcutUrl = '$baseUrl/?$params';
    final urlFileContent =
        '[InternetShortcut]\r\nURL=$shortcutUrl\r\n'
        'IconFile=$baseUrl/icons/Icon-192.png\r\nIconIndex=0\r\n';
    final fileName = 'PaaayIT-Terminal-$terminalNumber.url';

    try {
      Clipboard.setData(ClipboardData(text: shortcutUrl));
    } catch (_) {}

    saveTextFile(
      content: urlFileContent,
      fileName: fileName,
      mimeType: 'application/internet-shortcut',
    );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Terminal shortcut downloaded (.url)')),
    );
  }

  // ── Widget builders ─────────────────────────────────────────────────────

  Widget _buildHeaderCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          colors: [Color(0xFF1D4ED8), Color(0xFF2563EB)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1D4ED8).withOpacity(0.24),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Image.asset(
              'assets/icons/Blue transparent-logo.png',
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Terminal Activated',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Review this setup before continuing to login.',
                  style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.16),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white24),
            ),
            child: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 16),
                SizedBox(width: 6),
                Text(
                  'Ready',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          FilledButton.icon(
            onPressed: () => _goToLogin(context),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Continue to Login'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: const Color(0xFF1D4ED8),
              foregroundColor: Colors.white,
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (kIsWeb) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _downloadShortcut(context),
              icon: const Icon(Icons.download),
              label: const Text('Download Terminal Shortcut'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                side: const BorderSide(color: Color(0xFF94A3B8)),
              ),
            ),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _confirmWipe(context),
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text('Wipe & Re-Activate'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              foregroundColor: const Color(0xFFB91C1C),
              side: const BorderSide(color: Color(0xFFFCA5A5)),
            ),
          ),
          const SizedBox(height: 8),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Testing helper: Wipe clears local activation state on this device only.',
              style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> rows) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFC),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: Color(0xFF334155),
                letterSpacing: 0.3,
              ),
            ),
          ),
          ...rows,
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 184,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1E293B),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _val(String? v) {
    if (v == null || v.isEmpty) return '—';
    return v;
  }

  /// Shows first 4 characters + *** for sensitive values.
  String _masked(String v) {
    if (v.isEmpty) return '—';
    final prefix = v.length > 4 ? v.substring(0, 4) : v;
    return '$prefix *** (masked)';
  }
}
