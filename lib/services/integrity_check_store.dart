import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class IntegrityCheckStore {
  static const String enabledKey = 'operating.integrity_checks.enabled';
  static const String latestTransactionSnapshotKey =
      'debug.integrity.latest_transaction_snapshot';

  static Future<void> saveLatestTransactionSnapshot(
    Map<String, dynamic> snapshot,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(latestTransactionSnapshotKey, jsonEncode(snapshot));
  }

  static Future<Map<String, dynamic>?> loadLatestTransactionSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(latestTransactionSnapshotKey);
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      return null;
    }

    return null;
  }
}
