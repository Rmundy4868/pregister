import 'package:flutter/material.dart';

import '../services/supabase_service.dart';
import 'organization_admin_panel.dart';
import '../widgets/credential_login_fields.dart';
import '../widgets/register_sale_logo.dart';
import '../widgets/standard_action_button.dart';
import '../widgets/terminal_ambient_background.dart';

class MasterConsoleLoginScreen extends StatefulWidget {
  const MasterConsoleLoginScreen({super.key});

  @override
  State<MasterConsoleLoginScreen> createState() =>
      _MasterConsoleLoginScreenState();
}

class _MasterConsoleLoginScreenState extends State<MasterConsoleLoginScreen> {
  final TextEditingController _userIdController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _authenticating = false;
  bool _authenticated = false;
  String? _statusMessage;
  String? _principalType;
  String? _currentUserId;

  @override
  void dispose() {
    _userIdController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _onLogin() async {
    final username = _userIdController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      setState(() {
        _statusMessage = 'User ID and password are required.';
      });
      return;
    }

    setState(() {
      _authenticating = true;
      _statusMessage = null;
    });

    try {
      final dynamic result = await SupabaseService.client.rpc(
        'console_login',
        params: {'p_username': username, 'p_password': password},
      );

      final rows = _extractRows(result);
      final auth = _MasterConsoleAuthResult.fromRow(
        rows.isNotEmpty ? rows.first : null,
      );

      if (!mounted) return;

      if (!auth.authenticated) {
        setState(() {
          _authenticated = false;
          _principalType = null;
          _currentUserId = null;
          _statusMessage = auth.message.isEmpty
              ? 'Login failed. Please try again.'
              : auth.message;
        });
        return;
      }

      if (auth.principalType != 'master') {
        setState(() {
          _authenticated = false;
          _principalType = auth.principalType;
          _currentUserId = auth.userId;
          _statusMessage =
              'Access denied: this console is restricted to owner/master users.';
        });
        return;
      }

      setState(() {
        _authenticated = true;
        _principalType = auth.principalType;
        _currentUserId = auth.userId;
        _statusMessage = 'Master console login successful.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _authenticated = false;
        _statusMessage = 'Unable to sign in: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _authenticating = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> _extractRows(dynamic result) {
    if (result is List) {
      return result
          .whereType<Map>()
          .map(
            (entry) =>
                entry.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList();
    }

    if (result is Map) {
      return [result.map((key, value) => MapEntry(key.toString(), value))];
    }

    return const <Map<String, dynamic>>[];
  }

  void _signOut() {
    setState(() {
      _authenticated = false;
      _principalType = null;
      _currentUserId = null;
      _statusMessage = 'Signed out.';
      _passwordController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: TerminalAmbientBackground(
        style: AmbientBackgroundStyle.cinematic,
        child: SafeArea(
          child: _authenticated
              ? _buildAuthenticatedShell(theme)
              : _buildLoginShell(theme),
        ),
      ),
    );
  }

  Widget _buildLoginShell(ThemeData theme) {
    return LayoutBuilder(
      key: const ValueKey<String>('master-console-login-shell'),
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 980;

        return Stack(
          children: [
            _buildLoginBackdrop(constraints),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: TweenAnimationBuilder<double>(
                    duration: const Duration(milliseconds: 460),
                    curve: Curves.easeOutCubic,
                    tween: Tween<double>(begin: 0.0, end: 1.0),
                    builder: (context, value, child) {
                      return Opacity(
                        opacity: value,
                        child: Transform.translate(
                          offset: Offset(0, 28 * (1 - value)),
                          child: child,
                        ),
                      );
                    },
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(flex: 6, child: _buildLoginHero(theme)),
                              const SizedBox(width: 18),
                              Expanded(flex: 4, child: _buildLoginCard(theme)),
                            ],
                          )
                        : Column(
                            children: [
                              _buildLoginHero(theme, compact: true),
                              const SizedBox(height: 16),
                              _buildLoginCard(theme),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLoginBackdrop(BoxConstraints constraints) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: -120,
            top: -80,
            child: Container(
              width: constraints.maxWidth * 0.42,
              height: constraints.maxWidth * 0.42,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x8038BDF8), Color(0x0038BDF8)],
                ),
              ),
            ),
          ),
          Positioned(
            right: -140,
            bottom: -120,
            child: Container(
              width: constraints.maxWidth * 0.48,
              height: constraints.maxWidth * 0.48,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x66F59E0B), Color(0x00F59E0B)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginHero(ThemeData theme, {bool compact = false}) {
    final cs = theme.colorScheme;

    return Container(
      padding: EdgeInsets.all(compact ? 22 : 28),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF8FCFF), Color(0xFFEAF7FF), Color(0xFFF2FBFF)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 12,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: compact
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Align(
            alignment: compact ? Alignment.center : Alignment.centerLeft,
            child: const RegisterSaleLogo(height: 82, widthFactor: 0.5),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: compact ? Alignment.center : Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFDFF2FE),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.admin_panel_settings_rounded,
                    size: 16,
                    color: Color(0xFF0C4A6E),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Owner Workspace',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: const Color(0xFF0C4A6E),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Master Console',
            textAlign: compact ? TextAlign.center : TextAlign.left,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: const Color(0xFF0F172A),
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Sign in with your owner credentials, then manage organizations, locations, partner accounts, device trust, and activation policy from a dedicated console workspace.',
            textAlign: compact ? TextAlign.center : TextAlign.left,
            style: theme.textTheme.titleMedium?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: const [
              _HeroBadge(
                label: 'Organization Control',
                icon: Icons.apartment_rounded,
              ),
              _HeroBadge(
                label: 'Location Setup',
                icon: Icons.storefront_rounded,
              ),
              _HeroBadge(
                label: 'Activation Workflow',
                icon: Icons.vpn_key_rounded,
              ),
              _HeroBadge(
                label: 'Trusted Devices',
                icon: Icons.verified_user_rounded,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFE0F2FE),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFBAE6FD)),
            ),
            child: Row(
              children: [
                const Icon(Icons.insights_rounded, color: Color(0xFF0369A1)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Owner workspace status: organizations and license activation controls are live.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF0C4A6E),
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginCard(ThemeData theme) {
    final cs = theme.colorScheme;

    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFCFEFF), Color(0xFFF1F8FF)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 12,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: _buildLoginPanel(theme),
    );
  }

  Widget _buildLoginPanel(ThemeData theme) {
    final cs = theme.colorScheme;

    return Column(
      key: const ValueKey<String>('master-login-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFE0F2FE),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFBAE6FD)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.lock_person_rounded,
                size: 18,
                color: Color(0xFF0C4A6E),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Secure owner sign-in',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: const Color(0xFF0C4A6E),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Owner Authentication',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: const Color(0xFF0F172A),
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Enter your master credentials to open the console workspace.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFDBEAFE),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFBFDBFE)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.verified_rounded,
                size: 18,
                color: Color(0xFF1D4ED8),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Access level: Owner Master',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: const Color(0xFF1E3A8A),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        CredentialLoginFields(
          userIdController: _userIdController,
          passwordController: _passwordController,
          userIdLabel: 'Master User ID',
          passwordLabel: 'Master Password',
          enabled: !_authenticating,
          onSubmitted: _onLogin,
        ),
        if (_statusMessage != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _authenticated ? cs.primaryContainer : cs.errorContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _statusMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _authenticated
                    ? cs.onPrimaryContainer
                    : cs.onErrorContainer,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _authenticating ? null : _onLogin,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF0369A1),
            foregroundColor: Colors.white,
            elevation: 1,
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: _authenticating
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.onPrimary,
                  ),
                )
              : const Icon(Icons.login_rounded),
          label: _authenticating
              ? const Text('Signing In...')
              : const Text('Login to Master Console'),
        ),
      ],
    );
  }

  Widget _buildAuthenticatedShell(ThemeData theme) {
    final cs = theme.colorScheme;
    final compactTheme = theme.copyWith(
      visualDensity: VisualDensity.compact,
      iconTheme: theme.iconTheme.copyWith(size: 18),
      textTheme: theme.textTheme.apply(fontSizeFactor: 0.88),
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(isDense: true),
      listTileTheme: theme.listTileTheme.copyWith(
        dense: true,
        visualDensity: const VisualDensity(vertical: -3),
      ),
    );

    return LayoutBuilder(
      key: const ValueKey<String>('master-console-dashboard-shell'),
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 960;

        return Theme(
          data: compactTheme,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.outlineVariant, width: 1),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              children: [
                _buildConsoleHeader(compactTheme),
                Expanded(
                  child: compact
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: _buildDashboard(compactTheme),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(
                            10,
                            10,
                            10,
                            10,
                          ),
                          child: _buildDashboard(compactTheme),
                        ),
                ),
              ],
            ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildConsoleHeader(ThemeData theme) {
    final cs = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 1)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 165,
            child: RegisterSaleLogo(height: 42, widthFactor: 1),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Master Console',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0F1720),
                  ),
                ),
                Text(
                  'Global administration workspace',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _signOut,
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _buildConsoleSidebar(ThemeData theme, {bool compact = false}) {
    final cs = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StandardPanel(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Session',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              _SidebarMetaRow(
                label: 'Principal',
                value: _principalType ?? 'master',
              ),
              _SidebarMetaRow(label: 'User', value: _currentUserId ?? ''),
              _SidebarMetaRow(label: 'Status', value: 'Active'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        StandardPanel(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Navigation',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _SidebarChip(label: 'Overview', selected: true),
                  _SidebarChip(label: 'Organizations'),
                  _SidebarChip(label: 'Locations'),
                  _SidebarChip(label: 'Partners'),
                  _SidebarChip(label: 'Users'),
                  _SidebarChip(label: 'Devices'),
                ],
              ),
            ],
          ),
        ),
        if (!compact) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              'This pass establishes the authenticated shell. Each button in the workspace will become a dedicated admin screen in the next pass.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDashboard(ThemeData theme) {
    return Column(
      key: const ValueKey<String>('master-dashboard'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Organization Workspace',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        const OrganizationAdminPanel(),
      ],
    );
  }
}

class _HeroBadge extends StatelessWidget {
  const _HeroBadge({
    required this.label,
    required this.icon,
  });

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 18,
            color: const Color(0xFF0E7490),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: const Color(0xFF0F172A),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarMetaRow extends StatelessWidget {
  const _SidebarMetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarChip extends StatelessWidget {
  const _SidebarChip({required this.label, this.selected = false});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? cs.primaryContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: selected ? cs.onPrimaryContainer : cs.onSurface,
        ),
      ),
    );
  }
}

class _MasterConsoleAuthResult {
  const _MasterConsoleAuthResult({
    required this.authenticated,
    required this.principalType,
    required this.userId,
    required this.message,
  });

  final bool authenticated;
  final String principalType;
  final String userId;
  final String message;

  factory _MasterConsoleAuthResult.fromRow(Map<String, dynamic>? row) {
    if (row == null) {
      return const _MasterConsoleAuthResult(
        authenticated: false,
        principalType: 'none',
        userId: '',
        message: 'No authentication response returned.',
      );
    }

    final authenticated = row['authenticated'] == true;
    final principalType = (row['principal_type'] ?? 'none').toString();
    final userId = (row['user_id'] ?? '').toString();
    final message = (row['message'] ?? '').toString();

    return _MasterConsoleAuthResult(
      authenticated: authenticated,
      principalType: principalType,
      userId: userId,
      message: message,
    );
  }
}
