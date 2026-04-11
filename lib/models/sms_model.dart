import 'dart:convert';
import 'package:crypto/crypto.dart';

/// SMS Model for Spend IQ with Supabase Support
class SmsModel {
  final String id;
  final String sender;
  final String message;
  final DateTime timestamp;
  final SmsType type;
  final String deviceId;
  final String hash;
  final DateTime? syncedAt;
  final bool isTransaction;

  SmsModel({
    required this.id,
    required this.sender,
    required this.message,
    required this.timestamp,
    required this.type,
    required this.deviceId,
    String? hash,
    this.syncedAt,
    bool? isTransaction,
  })  : hash = hash ?? _generateHash(sender, message, timestamp),
        isTransaction = isTransaction ?? _detectTransaction(message);

  /// Generate unique hash for duplicate detection
  static String _generateHash(String sender, String message, DateTime timestamp) {
    final content = '$sender|$message|${timestamp.millisecondsSinceEpoch}';
    return md5.convert(utf8.encode(content)).toString();
  }

  /// Detect if SMS contains transaction keywords
  static bool _detectTransaction(String message) {
    final lowerMessage = message.toLowerCase();
    final transactionKeywords = [
      'debited', 'credited', 'paid', 'received', 'transferred',
      'withdrawn', 'deposited', 'spent', 'purchase', 'payment',
      'transaction', 'balance', 'upi', 'atm', 'pos', 'imps', 'neft',
      'rupees', 'rs.', 'inr', '₹', 'amt', 'amount', 'a/c', 'account',
      'bank', 'hdfc', 'icici', 'sbi', 'axis', 'kotak', 'paytm', 'phonepe', 'gpay'
    ];

    return transactionKeywords.any((keyword) => lowerMessage.contains(keyword));
  }

  bool get isTransactionSms => isTransaction;

  /// Convert to Supabase JSON format
  Map<String, dynamic> toSupabase() {
    return {
      'hash': hash,
      'sender': sender,
      'message': message,
      'timestamp': timestamp.toIso8601String(),
      'type': type == SmsType.incoming ? 'incoming' : 'outgoing',
      'device_id': deviceId,
      'is_transaction': isTransaction,
      'synced_at': DateTime.now().toIso8601String(),
    };
  }

  /// Create from Supabase row
  factory SmsModel.fromSupabase(Map<String, dynamic> json) {
    DateTime timestamp;
    if (json['timestamp'] is String) {
      timestamp = DateTime.parse(json['timestamp']);
    } else {
      timestamp = DateTime.now();
    }

    DateTime? syncedAt;
    if (json['synced_at'] != null && json['synced_at'] is String) {
      syncedAt = DateTime.parse(json['synced_at']);
    }

    return SmsModel(
      id: json['id']?.toString() ?? '',
      sender: json['sender']?.toString() ?? 'Unknown',
      message: json['message']?.toString() ?? '',
      timestamp: timestamp,
      type: json['type'] == 'outgoing' ? SmsType.outgoing : SmsType.incoming,
      deviceId: json['device_id']?.toString() ?? 'unknown',
      hash: json['hash']?.toString() ?? '',
      syncedAt: syncedAt,
      isTransaction: json['is_transaction'] ?? false,
    );
  }

  /// Create from raw SMS data (from Android)
  factory SmsModel.fromRawData(Map<String, dynamic> data, String deviceId) {
    final timestamp = data['date'] is int
        ? DateTime.fromMillisecondsSinceEpoch(data['date'] as int)
        : DateTime.now();

    final message = data['body']?.toString() ?? '';

    return SmsModel(
      id: data['_id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      sender: data['address']?.toString() ?? 'Unknown',
      message: message,
      timestamp: timestamp,
      type: _parseType(data['type']),
      deviceId: deviceId,
      isTransaction: _detectTransaction(message),
    );
  }

  static SmsType _parseType(dynamic type) {
    if (type == null) return SmsType.incoming;
    final typeInt = type is int ? type : int.tryParse(type.toString()) ?? 1;
    return typeInt == 2 ? SmsType.outgoing : SmsType.incoming;
  }

  /// Convert to Map for Isolate transfer
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'sender': sender,
      'message': message,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'type': type.index,
      'deviceId': deviceId,
      'hash': hash,
      'isTransaction': isTransaction,
    };
  }

  /// Create from Map (after Isolate transfer)
  factory SmsModel.fromMap(Map<String, dynamic> map) {
    return SmsModel(
      id: map['id'],
      sender: map['sender'],
      message: map['message'],
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp']),
      type: SmsType.values[map['type']],
      deviceId: map['deviceId'],
      hash: map['hash'],
      isTransaction: map['isTransaction'] ?? false,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SmsModel && other.hash == hash;
  }

  @override
  int get hashCode => hash.hashCode;

  @override
  String toString() {
    return 'SmsModel(sender: $sender, timestamp: $timestamp, isTransaction: $isTransaction)';
  }
}

enum SmsType { incoming, outgoing }

/// Batch of SMS messages
class SmsBatch {
  final List<SmsModel> messages;
  final int batchIndex;
  final int totalBatches;

  SmsBatch({
    required this.messages,
    required this.batchIndex,
    required this.totalBatches,
  });

  int get size => messages.length;
  bool get isLast => batchIndex == totalBatches - 1;
  double get progress => (batchIndex + 1) / totalBatches;
  int get transactionCount => messages.where((m) => m.isTransactionSms).length;
}

/// Real-time sync stats
class SyncStats {
  final int totalSynced;
  final int transactionCount;
  final DateTime? lastSyncTime;

  SyncStats({
    required this.totalSynced,
    required this.transactionCount,
    this.lastSyncTime,
  });

  factory SyncStats.empty() {
    return SyncStats(totalSynced: 0, transactionCount: 0);
  }
}