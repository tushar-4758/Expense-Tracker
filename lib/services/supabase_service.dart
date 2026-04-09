import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/sms_model.dart';
import '../config/supabase_config.dart';

/// Supabase Service with REAL-TIME Storage for Spend IQ
///
/// Features:
/// - Real-time PostgreSQL listeners
/// - Instant SMS upload
/// - Live sync status
/// - Cross-device sync
class SupabaseService {
  final SupabaseClient _supabase = Supabase.instance.client;

  // Use lowerCamelCase for constants
  static const String tableName = 'sms_logs';
  static const int batchSize = 500;

  // Real-time subscription channels
  RealtimeChannel? _smsChannel;
  RealtimeChannel? _transactionChannel;
  RealtimeChannel? _statsChannel;

  /// Initialize Supabase
  Future<void> initialize() async {
    debugPrint('🟢 Supabase initialized');
    debugPrint('🔗 URL: ${SupabaseConfig.supabaseUrl}');
  }

  // ==================== REAL-TIME STREAMS ====================

  /// Real-time stream of ALL synced SMS messages
  Stream<List<SmsModel>> getRealtimeSmsStream(String deviceId) {
    final controller = StreamController<List<SmsModel>>.broadcast();

    // Initial fetch
    _fetchAllSms(deviceId).then((data) {
      if (!controller.isClosed) {
        controller.add(data);
      }
    });

    // Subscribe to real-time changes
    _smsChannel = _supabase
        .channel('sms_realtime_$deviceId')
        .onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: tableName,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'device_id',
        value: deviceId,
      ),
      callback: (payload) {
        debugPrint('🔴 REAL-TIME CHANGE: ${payload.eventType}');
        // Refetch all data on any change
        _fetchAllSms(deviceId).then((data) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        });
      },
    )
        .subscribe();

    controller.onCancel = () {
      _smsChannel?.unsubscribe();
    };

    return controller.stream;
  }

  /// Fetch all SMS for a device
  Future<List<SmsModel>> _fetchAllSms(String deviceId) async {
    try {
      final response = await _supabase
          .from(tableName)
          .select()
          .eq('device_id', deviceId)
          .order('timestamp', ascending: false)
          .limit(100);

      debugPrint('📱 Fetched ${response.length} messages');
      return (response as List<dynamic>)
          .map((row) => SmsModel.fromSupabase(row as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('❌ Error fetching SMS: $e');
      return [];
    }
  }

  /// Real-time stream of ONLY transaction SMS
  Stream<List<SmsModel>> getRealtimeTransactionsStream(String deviceId) {
    final controller = StreamController<List<SmsModel>>.broadcast();

    // Initial fetch
    _fetchTransactions(deviceId).then((data) {
      if (!controller.isClosed) {
        controller.add(data);
      }
    });

    // Subscribe to real-time changes
    _transactionChannel = _supabase
        .channel('transactions_realtime_$deviceId')
        .onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: tableName,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'device_id',
        value: deviceId,
      ),
      callback: (payload) {
        debugPrint('💰 REAL-TIME TRANSACTION CHANGE: ${payload.eventType}');
        _fetchTransactions(deviceId).then((data) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        });
      },
    )
        .subscribe();

    controller.onCancel = () {
      _transactionChannel?.unsubscribe();
    };

    return controller.stream;
  }

  /// Fetch transactions for a device
  Future<List<SmsModel>> _fetchTransactions(String deviceId) async {
    try {
      final response = await _supabase
          .from(tableName)
          .select()
          .eq('device_id', deviceId)
          .eq('is_transaction', true)
          .order('timestamp', ascending: false)
          .limit(50);

      debugPrint('💰 Fetched ${response.length} transactions');
      return (response as List<dynamic>)
          .map((row) => SmsModel.fromSupabase(row as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('❌ Error fetching transactions: $e');
      return [];
    }
  }

  /// Real-time stream of sync statistics
  Stream<SyncStats> getRealtimeStatsStream(String deviceId) {
    final controller = StreamController<SyncStats>.broadcast();

    // Initial fetch
    _fetchStats(deviceId).then((stats) {
      if (!controller.isClosed) {
        controller.add(stats);
      }
    });

    // Subscribe to real-time changes
    _statsChannel = _supabase
        .channel('stats_realtime_$deviceId')
        .onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: tableName,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'device_id',
        value: deviceId,
      ),
      callback: (payload) {
        debugPrint('📊 REAL-TIME STATS UPDATE');
        _fetchStats(deviceId).then((stats) {
          if (!controller.isClosed) {
            controller.add(stats);
          }
        });
      },
    )
        .subscribe();

    controller.onCancel = () {
      _statsChannel?.unsubscribe();
    };

    return controller.stream;
  }

  /// Fetch stats for a device
  Future<SyncStats> _fetchStats(String deviceId) async {
    try {
      // Get all data and count locally
      final response = await _supabase
          .from(tableName)
          .select('id, is_transaction, synced_at')
          .eq('device_id', deviceId);

      final data = response as List<dynamic>;
      final total = data.length;
      final transactions = data.where((row) => row['is_transaction'] == true).length;

      DateTime? lastSync;
      if (data.isNotEmpty && data.first['synced_at'] != null) {
        lastSync = DateTime.parse(data.first['synced_at']);
      }

      return SyncStats(
        totalSynced: total,
        transactionCount: transactions,
        lastSyncTime: lastSync,
      );
    } catch (e) {
      debugPrint('❌ Error fetching stats: $e');
      return SyncStats.empty();
    }
  }

  // ==================== INSTANT UPLOAD ====================

  /// Upload a single SMS INSTANTLY (for real-time incoming SMS)
  Future<bool> uploadSingleSmsInstant(SmsModel sms) async {
    try {
      // Use upsert to prevent duplicates (based on hash unique constraint)
      await _supabase.from(tableName).upsert(
        sms.toSupabase(),
        onConflict: 'hash',
      );

      debugPrint('⚡ INSTANT UPLOAD: ${sms.sender}');
      if (sms.isTransactionSms) {
        debugPrint('💰 Transaction uploaded instantly!');
      }

      return true;
    } catch (e) {
      debugPrint('❌ Instant upload error: $e');
      return false;
    }
  }

  // ==================== BULK UPLOAD ====================

  /// Upload SMS messages with streaming progress
  Future<UploadResult> uploadSmsStream({
    required Stream<SmsBatch> smsStream,
    void Function(double progress, int uploaded, int total)? onProgress,
    void Function(String error)? onError,
  }) async {
    final stopwatch = Stopwatch()..start();
    int totalUploaded = 0;
    int totalFailed = 0;
    int totalSkipped = 0;
    int totalTransactions = 0;
    final uploadedHashes = <String>{};

    await for (final batch in smsStream) {
      try {
        final result = await _uploadBatch(batch.messages, uploadedHashes);

        totalUploaded += result.uploaded;
        totalFailed += result.failed;
        totalSkipped += result.skipped;
        totalTransactions += result.transactionCount;
        uploadedHashes.addAll(result.uploadedHashes);

        onProgress?.call(
          batch.progress,
          totalUploaded,
          totalUploaded + totalFailed + totalSkipped,
        );

        debugPrint('📤 Batch ${batch.batchIndex + 1}/${batch.totalBatches}: '
            '${result.uploaded} uploaded, ${result.skipped} skipped');
      } catch (e) {
        totalFailed += batch.size;
        onError?.call('Batch upload failed: $e');
        debugPrint('❌ Batch error: $e');
      }
    }

    stopwatch.stop();
    debugPrint(
        '✅ Bulk upload complete: $totalUploaded in ${stopwatch.elapsedMilliseconds}ms');

    return UploadResult(
      totalUploaded: totalUploaded,
      totalFailed: totalFailed,
      totalSkipped: totalSkipped,
      totalTransactions: totalTransactions,
      duration: stopwatch.elapsed,
    );
  }

  Future<_BatchResult> _uploadBatch(
      List<SmsModel> messages,
      Set<String> existingHashes,
      ) async {
    int uploaded = 0;
    int skipped = 0;
    int failed = 0;
    int transactionCount = 0;
    final newHashes = <String>{};

    final newMessages =
    messages.where((msg) => !existingHashes.contains(msg.hash)).toList();

    skipped = messages.length - newMessages.length;

    if (newMessages.isEmpty) {
      return _BatchResult(
        uploaded: 0,
        skipped: skipped,
        failed: 0,
        transactionCount: 0,
        uploadedHashes: {},
      );
    }

    transactionCount = newMessages.where((m) => m.isTransactionSms).length;

    // Split into smaller batches
    for (int i = 0; i < newMessages.length; i += batchSize) {
      final end = (i + batchSize).clamp(0, newMessages.length);
      final batchMessages = newMessages.sublist(i, end);

      try {
        final data = batchMessages.map((msg) => msg.toSupabase()).toList();

        // Bulk upsert
        await _supabase.from(tableName).upsert(
          data,
          onConflict: 'hash',
        );

        uploaded += batchMessages.length;
        newHashes.addAll(batchMessages.map((m) => m.hash));
      } catch (e) {
        debugPrint('❌ Batch upload error: $e');
        failed += batchMessages.length;
      }
    }

    return _BatchResult(
      uploaded: uploaded,
      skipped: skipped,
      failed: failed,
      transactionCount: transactionCount,
      uploadedHashes: newHashes,
    );
  }

  // ==================== QUERY METHODS ====================

  /// Get all synced message hashes for duplicate detection
  Future<Set<String>> getSyncedHashes(String deviceId) async {
    final hashes = <String>{};

    try {
      int offset = 0;
      const limit = 1000;

      while (true) {
        final response = await _supabase
            .from(tableName)
            .select('hash')
            .eq('device_id', deviceId)
            .range(offset, offset + limit - 1);

        final data = response as List<dynamic>;

        for (final row in data) {
          hashes.add(row['hash'] as String);
        }

        if (data.length < limit) break;
        offset += limit;
      }

      debugPrint('📊 Found ${hashes.length} existing hashes');
    } catch (e) {
      debugPrint('⚠️ Error fetching hashes: $e');
    }

    return hashes;
  }

  /// Get sync statistics (non-realtime)
  Future<SyncStats> getSyncStats(String deviceId) async {
    try {
      // Fetch all records and count locally
      final response = await _supabase
          .from(tableName)
          .select('id, is_transaction')
          .eq('device_id', deviceId);

      final data = response as List<dynamic>;
      final total = data.length;
      final transactions =
          data.where((row) => row['is_transaction'] == true).length;

      return SyncStats(
        totalSynced: total,
        transactionCount: transactions,
      );
    } catch (e) {
      debugPrint('❌ Error getting stats: $e');
      return SyncStats.empty();
    }
  }

  /// Get sync statistics using count (more efficient for large datasets)
  Future<SyncStats> getSyncStatsEfficient(String deviceId) async {
    try {
      // Get total count
      final totalResponse = await _supabase
          .from(tableName)
          .select()
          .eq('device_id', deviceId)
          .count(CountOption.exact);

      final total = totalResponse.count;

      // Get transaction count
      final transactionResponse = await _supabase
          .from(tableName)
          .select()
          .eq('device_id', deviceId)
          .eq('is_transaction', true)
          .count(CountOption.exact);

      final transactions = transactionResponse.count;

      return SyncStats(
        totalSynced: total,
        transactionCount: transactions,
      );
    } catch (e) {
      debugPrint('❌ Error getting stats: $e');
      return SyncStats.empty();
    }
  }

  /// Delete all synced messages for a device
  Future<int> deleteAllForDevice(String deviceId) async {
    try {
      await _supabase.from(tableName).delete().eq('device_id', deviceId);

      debugPrint('🗑️ Deleted all messages for device: $deviceId');
      return 1;
    } catch (e) {
      debugPrint('❌ Delete error: $e');
      return 0;
    }
  }

  /// Dispose all realtime subscriptions
  void dispose() {
    _smsChannel?.unsubscribe();
    _transactionChannel?.unsubscribe();
    _statsChannel?.unsubscribe();
  }
}

class _BatchResult {
  final int uploaded;
  final int skipped;
  final int failed;
  final int transactionCount;
  final Set<String> uploadedHashes;

  _BatchResult({
    required this.uploaded,
    required this.skipped,
    required this.failed,
    required this.transactionCount,
    required this.uploadedHashes,
  });
}

class UploadResult {
  final int totalUploaded;
  final int totalFailed;
  final int totalSkipped;
  final int totalTransactions;
  final Duration duration;

  UploadResult({
    required this.totalUploaded,
    required this.totalFailed,
    required this.totalSkipped,
    required this.totalTransactions,
    required this.duration,
  });

  double get messagesPerSecond => duration.inMilliseconds > 0
      ? totalUploaded / (duration.inMilliseconds / 1000)
      : 0;

  @override
  String toString() {
    return 'UploadResult(uploaded: $totalUploaded, transactions: $totalTransactions, '
        'duration: ${duration.inMilliseconds}ms)';
  }
}