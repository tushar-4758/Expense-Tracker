import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:telephony/telephony.dart' hide SmsType;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/sms_model.dart';

/// SMS Service with Real-Time support
class SmsService {
  final Telephony _telephony = Telephony.instance;
  String? _deviceId;

  static const int batchSize = 500;

  /// Stream controller for real-time incoming SMS
  final _incomingSmsController = StreamController<SmsModel>.broadcast();
  Stream<SmsModel> get incomingSmsStream => _incomingSmsController.stream;

  /// Initialize SMS service
  Future<void> initialize() async {
    _deviceId = await _getDeviceId();
    _setupIncomingSmsListener();
    debugPrint('📱 Spend IQ: SMS Service initialized');
    debugPrint('📱 Device ID: $_deviceId');
  }

  /// Get unique device identifier
  Future<String> _getDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    return androidInfo.id;
  }

  String get deviceId => _deviceId ?? 'unknown';

  /// Setup real-time SMS listener
  void _setupIncomingSmsListener() {
    _telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) {
        debugPrint('📩 NEW SMS RECEIVED: ${message.address}');

        final smsModel = SmsModel(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          sender: message.address ?? 'Unknown',
          message: message.body ?? '',
          timestamp: DateTime.now(),
          type: SmsType.incoming,
          deviceId: _deviceId ?? 'unknown',
        );

        // Emit to stream for real-time upload
        _incomingSmsController.add(smsModel);

        if (smsModel.isTransactionSms) {
          debugPrint('💰 TRANSACTION DETECTED: ${smsModel.sender}');
        }
      },
      onBackgroundMessage: _backgroundMessageHandler,
      listenInBackground: true,
    );

    debugPrint('✅ Real-time SMS listener activated');
  }

  /// Background message handler
  @pragma('vm:entry-point')
  static void _backgroundMessageHandler(SmsMessage message) async {
    debugPrint('🔔 Background SMS: ${message.address}');
  }

  /// Read all SMS with batch processing
  Stream<SmsBatch> readAllSmsInBatches({
    Set<String>? existingHashes,
  }) async* {
    debugPrint('📱 Starting bulk SMS read...');
    final stopwatch = Stopwatch()..start();

    // Read inbox messages
    final inboxMessages = await _telephony.getInboxSms(
      columns: [
        SmsColumn.ID,
        SmsColumn.ADDRESS,
        SmsColumn.BODY,
        SmsColumn.DATE,
        SmsColumn.TYPE,
      ],
    );

    // Read sent messages
    final sentMessages = await _telephony.getSentSms(
      columns: [
        SmsColumn.ID,
        SmsColumn.ADDRESS,
        SmsColumn.BODY,
        SmsColumn.DATE,
        SmsColumn.TYPE,
      ],
    );

    final allMessages = [...inboxMessages, ...sentMessages];
    final totalMessages = allMessages.length;

    debugPrint('📊 Total SMS found: $totalMessages');

    if (totalMessages == 0) return;

    final totalBatches = (totalMessages / batchSize).ceil();

    for (int batchIndex = 0; batchIndex < totalBatches; batchIndex++) {
      final startIndex = batchIndex * batchSize;
      final endIndex = (startIndex + batchSize).clamp(0, totalMessages);
      final batchMessages = allMessages.sublist(startIndex, endIndex);

      final rawDataList = batchMessages.map((msg) => {
        'id': msg.id,
        'address': msg.address,
        'body': msg.body,
        'date': msg.date,
        'type': msg.type,
      }).toList();

      // Process batch in isolate
      final processedBatch = await compute(
        _processSmsBatchInIsolate,
        _IsolatePayload(
          rawMessages: rawDataList,
          deviceId: _deviceId ?? 'unknown',
          existingHashes: existingHashes ?? {},
        ),
      );

      if (processedBatch.isNotEmpty) {
        yield SmsBatch(
          messages: processedBatch,
          batchIndex: batchIndex,
          totalBatches: totalBatches,
        );
      }

      await Future.delayed(const Duration(milliseconds: 10));
    }

    stopwatch.stop();
    debugPrint('✅ SMS read complete in ${stopwatch.elapsedMilliseconds}ms');
  }

  /// Get last sync timestamp
  Future<DateTime?> getLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt('last_sms_sync');
    return timestamp != null
        ? DateTime.fromMillisecondsSinceEpoch(timestamp)
        : null;
  }

  /// Save last sync timestamp
  Future<void> saveLastSyncTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('last_sms_sync', time.millisecondsSinceEpoch);
  }

  void dispose() {
    _incomingSmsController.close();
  }
}

class _IsolatePayload {
  final List<Map<String, dynamic>> rawMessages;
  final String deviceId;
  final Set<String> existingHashes;

  _IsolatePayload({
    required this.rawMessages,
    required this.deviceId,
    required this.existingHashes,
  });
}

List<SmsModel> _processSmsBatchInIsolate(_IsolatePayload payload) {
  final results = <SmsModel>[];

  for (final rawData in payload.rawMessages) {
    try {
      final smsModel = SmsModel.fromRawData(rawData, payload.deviceId);

      if (!payload.existingHashes.contains(smsModel.hash)) {
        results.add(smsModel);
      }
    } catch (e) {
      continue;
    }
  }

  return results;
}