import 'package:permission_handler/permission_handler.dart';
import 'package:telephony/telephony.dart';

/// Permission Service for Spend IQ
class PermissionService {
  final Telephony _telephony = Telephony.instance;

  /// Request all required permissions
  Future<PermissionResult> requestAllPermissions() async {
    final results = <String, bool>{};

    // Request SMS permission
    final smsPermission = await _telephony.requestSmsPermissions;
    results['sms'] = smsPermission ?? false;

    // Request phone state permission
    final phoneState = await Permission.phone.request();
    results['phone'] = phoneState.isGranted;

    final criticalGranted = results['sms'] == true;

    return PermissionResult(
      allGranted: results.values.every((v) => v),
      criticalGranted: criticalGranted,
      details: results,
    );
  }

  /// Check current permission status
  Future<Map<String, bool>> checkPermissions() async {
    return {
      'sms': await Permission.sms.isGranted,
      'phone': await Permission.phone.isGranted,
    };
  }

  /// Open app settings
  Future<bool> openSettings() async {
    return await openAppSettings();
  }
}

class PermissionResult {
  final bool allGranted;
  final bool criticalGranted;
  final Map<String, bool> details;

  PermissionResult({
    required this.allGranted,
    required this.criticalGranted,
    required this.details,
  });
}