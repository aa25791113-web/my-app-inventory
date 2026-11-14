import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class AppNotificationService {
  AppNotificationService._();
  static final AppNotificationService instance = AppNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const int _stockBaseId = 1100000;
  static const int _invoiceBaseId = 2200000;
  static const int _updateNotificationId = 3300000;
  static const int _testNotificationId = 3300001;

  int _stockId(int productId) => _stockBaseId + productId;
  int _invoiceId(int invoiceId) => _invoiceBaseId + invoiceId;

  Future<void> initialize() async {
    if (!Platform.isAndroid || _initialized) return;
    tzdata.initializeTimeZones();
    try {
      final local = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(local.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Africa/Cairo'));
    }
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {},
    );
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'inventory_alerts',
        'تنبيهات المخزون',
        description: 'تنبيهات انخفاض رصيد المنتجات عن الحد الأدنى',
        importance: Importance.max,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'invoice_reminders',
        'تذكيرات الفواتير',
        description: 'تذكيرات الفواتير التي لم يتم تحصيلها بالكامل',
        importance: Importance.high,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'app_updates',
        'تحديثات البرنامج',
        description: 'إشعارات توفر تحديثات جديدة للبرنامج',
        importance: Importance.high,
      ),
    );
    _initialized = true;
  }

  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return false;
    await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    return await android?.areNotificationsEnabled() ?? true;
  }

  Future<bool> hasPermission() async {
    if (!Platform.isAndroid) return false;
    await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? true;
  }

  NotificationDetails _details(String channelId, String channelName,
      String description, {Importance importance = Importance.high}) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: description,
        importance: importance,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        styleInformation: const BigTextStyleInformation(''),
        icon: '@mipmap/ic_launcher',
        playSound: true,
        enableVibration: true,
      ),
    );
  }

  Future<void> showTestNotification() async {
    if (!Platform.isAndroid || !await hasPermission()) return;
    await _plugin.show(
      _testNotificationId,
      'تم تفعيل إشعارات MY APP',
      'الإشعارات تعمل بشكل صحيح. ستصلك تنبيهات المخزون والفواتير والتحديثات حسب الإعدادات.',
      _details('app_updates', 'تحديثات البرنامج', 'إشعار تجريبي'),
    );
  }

  Future<void> showUpdateNotification({
    required String title,
    required String body,
  }) async {
    if (!Platform.isAndroid || !await hasPermission()) return;
    await _plugin.show(
      _updateNotificationId,
      title,
      body,
      _details('app_updates', 'تحديثات البرنامج', 'إشعارات تحديث البرنامج'),
      payload: 'app_update',
    );
  }

  Future<void> syncStockAlerts(List<Map<String, Object?>> products) async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    final enabled = (prefs.getBool('notifications_enabled') ?? false) &&
        (prefs.getBool('stock_alerts') ?? true);
    if (!enabled || !await hasPermission()) {
      final pending = await _plugin.pendingNotificationRequests();
      for (final item in pending) {
        if (item.id >= _stockBaseId && item.id < _invoiceBaseId) {
          await _plugin.cancel(item.id);
        }
      }
      return;
    }

    final notified = (prefs.getStringList('notified_low_stock_ids') ?? [])
        .toSet();
    for (final product in products) {
      final rawId = product['id'];
      if (rawId is! num) continue;
      final id = rawId.toInt();
      final qty = (product['qty'] as num?)?.toInt() ?? 0;
      final minimum = (product['min_qty'] as num?)?.toInt() ?? 0;
      final archived = (product['archived'] as num?)?.toInt() ?? 0;
      final key = id.toString();
      if (archived == 0 && minimum > 0 && qty <= minimum) {
        if (!notified.contains(key)) {
          await _plugin.show(
            _stockId(id),
            'تنبيه مخزون منخفض',
            '\${product['name'] ?? 'منتج'}: المتبقي $qty، وحد التنبيه $minimum.',
            _details(
              'inventory_alerts',
              'تنبيهات المخزون',
              'انخفاض رصيد المنتجات',
              importance: Importance.max,
            ),
            payload: 'stock:$id',
          );
          notified.add(key);
        }
      } else if (notified.contains(key)) {
        await _plugin.cancel(_stockId(id));
        notified.remove(key);
      }
    }
    await prefs.setStringList('notified_low_stock_ids', notified.toList());
  }

  Future<void> syncInvoiceReminders(
    List<Map<String, Object?>> invoices, {
    required int reminderDays,
    bool forceReschedule = false,
  }) async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    final enabled = (prefs.getBool('notifications_enabled') ?? false) &&
        (prefs.getBool('invoice_alerts') ?? true);
    final pending = await _plugin.pendingNotificationRequests();

    if (!enabled || !await hasPermission()) {
      for (final item in pending) {
        if (item.id >= _invoiceBaseId && item.id < _updateNotificationId) {
          await _plugin.cancel(item.id);
        }
      }
      return;
    }

    final liveIds = <int>{};
    final days = reminderDays.clamp(1, 365);
    final now = DateTime.now();

    for (final invoice in invoices) {
      final rawId = invoice['id'];
      if (rawId is! num) continue;
      final id = rawId.toInt();
      final total = (invoice['total'] as num?)?.toDouble() ?? 0;
      final paid = (invoice['paid'] as num?)?.toDouble() ?? 0;
      if (total <= paid + 0.0001) {
        await _plugin.cancel(_invoiceId(id));
        await prefs.remove('invoice_reminder_schedule_$id');
        continue;
      }

      liveIds.add(id);
      final createdRaw = (invoice['created_at'] ?? '').toString();
      DateTime createdAt;
      try {
        createdAt = DateTime.parse(createdRaw).toLocal();
      } catch (_) {
        continue;
      }
      final fingerprint = '$days:$createdRaw';
      final stored = prefs.getString('invoice_reminder_schedule_$id');
      if (!forceReschedule && stored == fingerprint) continue;

      await _plugin.cancel(_invoiceId(id));
      final dueAt = createdAt.add(Duration(days: days));
      final scheduleAt = dueAt.isAfter(now)
          ? dueAt
          : now.add(const Duration(seconds: 8));
      final remaining = total - paid;
      await _plugin.zonedSchedule(
        _invoiceId(id),
        'تذكير بفاتورة غير مسددة',
        'العميل \${invoice['customer_name'] ?? ''} • الفاتورة \${invoice['invoice_no'] ?? ''} • المتبقي \${remaining.toStringAsFixed(2)} ج.م',
        tz.TZDateTime.from(scheduleAt, tz.local),
        _details(
          'invoice_reminders',
          'تذكيرات الفواتير',
          'الفواتير غير المسددة',
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'invoice:$id',
      );
      await prefs.setString('invoice_reminder_schedule_$id', fingerprint);
    }

    for (final item in pending) {
      if (item.id >= _invoiceBaseId && item.id < _updateNotificationId) {
        final invoiceId = item.id - _invoiceBaseId;
        if (!liveIds.contains(invoiceId)) {
          await _plugin.cancel(item.id);
          await prefs.remove('invoice_reminder_schedule_$invoiceId');
        }
      }
    }
  }

  Future<void> cancelAllInvoiceReminders() async {
    if (!Platform.isAndroid) return;
    final pending = await _plugin.pendingNotificationRequests();
    final prefs = await SharedPreferences.getInstance();
    for (final item in pending) {
      if (item.id >= _invoiceBaseId && item.id < _updateNotificationId) {
        await _plugin.cancel(item.id);
      }
    }
    for (final key in prefs.getKeys()) {
      if (key.startsWith('invoice_reminder_schedule_')) {
        await prefs.remove(key);
      }
    }
  }
}
