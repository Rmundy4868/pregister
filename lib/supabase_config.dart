class SupabaseConfig {
  static const String url = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const String anonKey =
    String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
  static const String appLicenseKey =
    String.fromEnvironment('APP_LICENSE_KEY', defaultValue: '');
  static const String transactionsTable = 'transactions';
  static const String screenReceiptsTable = 'screen_receipts';
  static const String organizationNumber =
    String.fromEnvironment('ORGANIZATION_NUMBER', defaultValue: '');
  static const String terminalNumber =
    String.fromEnvironment('TERMINAL_NUMBER', defaultValue: '');
  static const String locationName =
    String.fromEnvironment('LOCATION_NAME', defaultValue: '');
  static const String appDeviceId =
    String.fromEnvironment('APP_DEVICE_ID', defaultValue: '');
  static const String appDeviceLabel =
    String.fromEnvironment('APP_DEVICE_LABEL', defaultValue: '');

  // Dejavoo SPIn credentials (from iPOSpays portal -> S.T.E.A.M -> TPN -> Integrations -> SPIn Cloud)
  static const String spinTpn =
    String.fromEnvironment('SPIN_TPN', defaultValue: '');
  static const String spinAuthKey =
    String.fromEnvironment('SPIN_AUTH_KEY', defaultValue: '');
  /// Set SPIN_SANDBOX=true to route to test.spinpos.net instead of production.
  static const bool spinSandbox =
    bool.fromEnvironment('SPIN_SANDBOX', defaultValue: false);

  /// Set DEBUG_MODE=true to show the startup context verification popup after PIN login.
  static const bool debugMode =
    bool.fromEnvironment('DEBUG_MODE', defaultValue: false);

  static bool get hasPlaceholderValues {
    return url.contains('YOUR_PROJECT') ||
        anonKey.contains('YOUR_ANON_KEY') ||
        appLicenseKey.contains('YOUR_LICENSE_KEY');
  }

  static bool get hasValidUrl {
    final parsed = Uri.tryParse(url);
    return parsed != null &&
        (parsed.scheme == 'https' || parsed.scheme == 'http') &&
        parsed.host.isNotEmpty;
  }
}
