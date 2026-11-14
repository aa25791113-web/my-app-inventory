import 'dart:convert';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:csv/csv.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';
import 'premium_assistant.dart';
import 'scientific_calculator.dart';

String currencyLabel='ج.م';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences=await SharedPreferences.getInstance();currencyLabel=preferences.getString('currencyLabel')??'ج.م';
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  await StoreDb.instance.init();
  runApp(const MyApp());
}

class StoreDb {
  StoreDb._();
  static final instance = StoreDb._();
  Database? database;
  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    database = await openDatabase(p.join(dir.path, 'my_app.sqlite'), version: 14,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE products(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,category TEXT NOT NULL DEFAULT "",qty INTEGER NOT NULL DEFAULT 0,min_qty INTEGER NOT NULL DEFAULT 0,buy REAL NOT NULL DEFAULT 0,sell REAL NOT NULL DEFAULT 0,sku TEXT NOT NULL DEFAULT "",manufacturer TEXT NOT NULL DEFAULT "",part_no TEXT NOT NULL DEFAULT "",alt_part_no TEXT NOT NULL DEFAULT "",location TEXT NOT NULL DEFAULT "",description TEXT NOT NULL DEFAULT "",archived INTEGER NOT NULL DEFAULT 0,wholesale REAL NOT NULL DEFAULT 0,brand TEXT NOT NULL DEFAULT "",unit TEXT NOT NULL DEFAULT "قطعة",country TEXT NOT NULL DEFAULT "",alt_names TEXT NOT NULL DEFAULT "",specs TEXT NOT NULL DEFAULT "",image_path TEXT NOT NULL DEFAULT "",supplier_id INTEGER,compatibility TEXT NOT NULL DEFAULT "",dimensions TEXT NOT NULL DEFAULT "",weight TEXT NOT NULL DEFAULT "",package_size INTEGER NOT NULL DEFAULT 1)');
        await db.execute('CREATE TABLE operations(id INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,product_id INTEGER NOT NULL,product_name TEXT NOT NULL,qty INTEGER NOT NULL,unit_price REAL NOT NULL,total REAL NOT NULL,note TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL,cost_price REAL NOT NULL DEFAULT 0,party_id INTEGER,party_name TEXT NOT NULL DEFAULT "",warehouse_id INTEGER NOT NULL DEFAULT 1)');
        await _createExtendedTables(db);
        await _createProductHistory(db);
        await _backfillProductCodes(db);
        await _createSmartTables(db);
        await _createPartyLedger(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('CREATE TABLE IF NOT EXISTS operations(id INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,product_id INTEGER NOT NULL,product_name TEXT NOT NULL,qty INTEGER NOT NULL,unit_price REAL NOT NULL,total REAL NOT NULL,note TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL)');
        }
        if (oldVersion < 3) {
          final cols = await db.rawQuery('PRAGMA table_info(operations)');
          final names = cols.map((e)=>e['name']).toSet();
          if (!names.contains('cost_price')) await db.execute('ALTER TABLE operations ADD COLUMN cost_price REAL NOT NULL DEFAULT 0');
          if (!names.contains('party_id')) await db.execute('ALTER TABLE operations ADD COLUMN party_id INTEGER');
          if (!names.contains('party_name')) await db.execute('ALTER TABLE operations ADD COLUMN party_name TEXT NOT NULL DEFAULT ""');
          if (!names.contains('warehouse_id')) await db.execute('ALTER TABLE operations ADD COLUMN warehouse_id INTEGER NOT NULL DEFAULT 1');
          await _createExtendedTables(db);
          await db.execute('UPDATE operations SET cost_price=COALESCE((SELECT buy FROM products WHERE products.id=operations.product_id),0) WHERE cost_price=0');
        }
        if (oldVersion < 4) {
          final cols=await db.rawQuery('PRAGMA table_info(products)');
          final names=cols.map((e)=>e['name']).toSet();
          for(final e in <String,String>{'sku':'TEXT NOT NULL DEFAULT ""','manufacturer':'TEXT NOT NULL DEFAULT ""','part_no':'TEXT NOT NULL DEFAULT ""','alt_part_no':'TEXT NOT NULL DEFAULT ""','location':'TEXT NOT NULL DEFAULT ""','description':'TEXT NOT NULL DEFAULT ""','archived':'INTEGER NOT NULL DEFAULT 0'}.entries){
            if(!names.contains(e.key))await db.execute('ALTER TABLE products ADD COLUMN ${e.key} ${e.value}');
          }
          await _createProductHistory(db);
          await _backfillProductCodes(db);
        }
        if(oldVersion<8){await _upgradeProductColumns(db);await _createSmartTables(db);} if(oldVersion<9){await _createSmartTables(db);} if(oldVersion<10){await _createSmartTables(db);} if(oldVersion<11){await _createWarehouseStock(db);} if(oldVersion<12){await _createPartyLedger(db);} if(oldVersion<13){final cols=await db.rawQuery('PRAGMA table_info(invoices)');if(!cols.any((c)=>c['name']=='customer_phone'))await db.execute('ALTER TABLE invoices ADD COLUMN customer_phone TEXT NOT NULL DEFAULT ""');} if(oldVersion<14){final cols=await db.rawQuery('PRAGMA table_info(invoice_items)');final names=cols.map((c)=>c['name']).toSet();if(!names.contains('supplier_id'))await db.execute('ALTER TABLE invoice_items ADD COLUMN supplier_id INTEGER');if(!names.contains('supplier_name'))await db.execute('ALTER TABLE invoice_items ADD COLUMN supplier_name TEXT NOT NULL DEFAULT ""');if(!names.contains('added_at'))await db.execute('ALTER TABLE invoice_items ADD COLUMN added_at TEXT NOT NULL DEFAULT ""');await db.execute("UPDATE invoice_items SET added_at=COALESCE((SELECT created_at FROM invoices WHERE invoices.id=invoice_items.invoice_id),'') WHERE added_at='' ");}
      });
  }

  Future<void> _upgradeProductColumns(DatabaseExecutor db) async {
    final cols=await db.rawQuery('PRAGMA table_info(products)');
    final names=cols.map((e)=>e['name']).toSet();
    final definitions=<String,String>{
      'wholesale':'REAL NOT NULL DEFAULT 0','brand':'TEXT NOT NULL DEFAULT ""',
      'unit':'TEXT NOT NULL DEFAULT "قطعة"','country':'TEXT NOT NULL DEFAULT ""',
      'alt_names':'TEXT NOT NULL DEFAULT ""','specs':'TEXT NOT NULL DEFAULT ""',
      'image_path':'TEXT NOT NULL DEFAULT ""','supplier_id':'INTEGER','compatibility':'TEXT NOT NULL DEFAULT ""','dimensions':'TEXT NOT NULL DEFAULT ""','weight':'TEXT NOT NULL DEFAULT ""','package_size':'INTEGER NOT NULL DEFAULT 1'
    };
    for(final e in definitions.entries){if(!names.contains(e.key))await db.execute('ALTER TABLE products ADD COLUMN '+e.key+' '+e.value);}
  }
  Future<void> _createSmartTables(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS categories(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,parent_id INTEGER,color INTEGER NOT NULL DEFAULT 0,description TEXT NOT NULL DEFAULT "")');
    await db.execute('CREATE TABLE IF NOT EXISTS favorites(product_id INTEGER PRIMARY KEY,created_at TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS recent_searches(id INTEGER PRIMARY KEY AUTOINCREMENT,query TEXT NOT NULL,created_at TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS activity_log(id INTEGER PRIMARY KEY AUTOINCREMENT,action TEXT NOT NULL,details TEXT NOT NULL,created_at TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS tasks(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,done INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS product_notes(id INTEGER PRIMARY KEY AUTOINCREMENT,product_id INTEGER,title TEXT NOT NULL,body TEXT NOT NULL,created_at TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS product_images(id INTEGER PRIMARY KEY AUTOINCREMENT,product_id INTEGER NOT NULL,path TEXT NOT NULL,is_primary INTEGER NOT NULL DEFAULT 0)');
    await _upgradeProductColumns(db);
    await db.execute('CREATE TABLE IF NOT EXISTS invoices(id INTEGER PRIMARY KEY AUTOINCREMENT,invoice_no TEXT NOT NULL UNIQUE,customer_id INTEGER,customer_name TEXT NOT NULL DEFAULT "",subtotal REAL NOT NULL,discount_value REAL NOT NULL DEFAULT 0,discount_mode TEXT NOT NULL DEFAULT "amount",discount_amount REAL NOT NULL DEFAULT 0,total REAL NOT NULL,paid REAL NOT NULL DEFAULT 0,note TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL,customer_phone TEXT NOT NULL DEFAULT "")');
    await db.execute('CREATE TABLE IF NOT EXISTS invoice_items(id INTEGER PRIMARY KEY AUTOINCREMENT,invoice_id INTEGER NOT NULL,product_id INTEGER NOT NULL,product_name TEXT NOT NULL,qty INTEGER NOT NULL,unit_price REAL NOT NULL,total REAL NOT NULL,supplier_id INTEGER,supplier_name TEXT NOT NULL DEFAULT "",added_at TEXT NOT NULL DEFAULT "")');
    await db.execute('CREATE TABLE IF NOT EXISTS invoice_payments(id INTEGER PRIMARY KEY AUTOINCREMENT,invoice_id INTEGER NOT NULL,amount REAL NOT NULL,paid_at TEXT NOT NULL,note TEXT NOT NULL DEFAULT "")');
  }
  Future<void> log(String action,String details) async {
    await database!.insert('activity_log',{'action':action,'details':details,'created_at':DateTime.now().toIso8601String()});
  }
  Future<List<Map<String,Object?>>> categories([String query=''])=>database!.query('categories',where:query.trim().isEmpty?null:'name LIKE ?',whereArgs:query.trim().isEmpty?null:['%'+query.trim()+'%'],orderBy:'name');
  Future<void> saveCategory(Map<String,Object?> data,int? id) async {if(id==null){await database!.insert('categories',data);}else{await database!.update('categories',data,where:'id=?',whereArgs:[id]);}}
  Future<void> bulkAdjustSellingPrices(double value,bool percent,String reason) async {
    if(value<0)throw Exception('القيمة غير صحيحة.');
    await database!.transaction((txn) async {final rows=await txn.query('products',where:'archived=0');for(final row in rows){final old=(row['sell'] as num).toDouble();final next=percent?old*(1+value/100):old+value;if(next<0)continue;if(next!=old){await txn.insert('price_history',{'product_id':row['id'],'product_name':row['name'],'old_buy':row['buy'],'new_buy':row['buy'],'old_sell':old,'new_sell':next,'reason':reason,'created_at':DateTime.now().toIso8601String()});await txn.update('products',{'sell':next},where:'id=?',whereArgs:[row['id']]);}}await txn.insert('activity_log',{'action':'تعديل أسعار جماعي','details':(percent?'نسبة ':'قيمة ')+value.toString()+' | '+reason,'created_at':DateTime.now().toIso8601String()});});
  }
  Future<void> toggleFavorite(int id,bool value) async {
    if(value){await database!.insert('favorites',{'product_id':id,'created_at':DateTime.now().toIso8601String()},conflictAlgorithm:ConflictAlgorithm.replace);}
    else{await database!.delete('favorites',where:'product_id=?',whereArgs:[id]);}
  }
  Future<bool> isFavorite(int id) async => (await database!.query('favorites',where:'product_id=?',whereArgs:[id],limit:1)).isNotEmpty;
  Future<List<Map<String,Object?>>> favoriteProducts() async => database!.rawQuery('SELECT p.* FROM products p INNER JOIN favorites f ON f.product_id=p.id ORDER BY f.created_at DESC');
  Future<List<Map<String,Object?>>> archivedProducts()=>database!.query('products',where:'archived=1',orderBy:'name');
  Future<void> setArchived(int id,bool value) async {await database!.update('products',{'archived':value?1:0},where:'id=?',whereArgs:[id]);await log(value?'أرشفة منتج':'استعادة منتج','رقم المنتج '+id.toString());}
  Future<List<Map<String,Object?>>> productsWithoutImages()=>database!.query('products',where:'archived=0 AND (image_path IS NULL OR image_path="")');
  Future<List<Map<String,Object?>>> productsWithoutPrices()=>database!.query('products',where:'archived=0 AND sell<=0');
  Future<List<Map<String,Object?>>> possibleDuplicates()=>database!.rawQuery('SELECT name,COUNT(*) AS amount FROM products WHERE archived=0 GROUP BY lower(trim(name)) HAVING COUNT(*)>1');
  Future<void> saveSearch(String query) async {
    if(query.trim().isEmpty)return;
    await database!.insert('recent_searches',{'query':query.trim(),'created_at':DateTime.now().toIso8601String()});
    await database!.rawDelete('DELETE FROM recent_searches WHERE id NOT IN (SELECT id FROM recent_searches ORDER BY id DESC LIMIT 100)');
  }
  Future<List<Map<String,Object?>>> recentSearches()=>database!.query('recent_searches',orderBy:'id DESC',limit:100);
  Future<List<Map<String,Object?>>> activity()=>database!.query('activity_log',orderBy:'id DESC',limit:300);
  Future<void> saveProductNote(int productId,String title,String body) async {await database!.insert('product_notes',{'product_id':productId,'title':title,'body':body,'created_at':DateTime.now().toIso8601String()});await log('إضافة ملاحظة منتج',title);}
  Future<List<Map<String,Object?>>> productNotes(int productId)=>database!.query('product_notes',where:'product_id=?',whereArgs:[productId],orderBy:'id DESC');
  Future<void> deleteProductNote(int id) async {await database!.delete('product_notes',where:'id=?',whereArgs:[id]);}
  Future<void> saveTask(String title) async {if(title.trim().isNotEmpty)await database!.insert('tasks',{'title':title.trim(),'done':0,'created_at':DateTime.now().toIso8601String()});}
  Future<List<Map<String,Object?>>> tasks()=>database!.query('tasks',orderBy:'done, id DESC');
  Future<void> toggleTask(int id,bool done) async {await database!.update('tasks',{'done':done?1:0},where:'id=?',whereArgs:[id]);}
  Future<void> deleteTask(int id) async {await database!.delete('tasks',where:'id=?',whereArgs:[id]);}
  Future<void> deleteRecentSearch(int id) async {await database!.delete('recent_searches',where:'id=?',whereArgs:[id]);}
  Future<void> deleteActivity(int id) async {await database!.delete('activity_log',where:'id=?',whereArgs:[id]);}
  Future<void> deleteCategory(int id) async {await database!.delete('categories',where:'id=?',whereArgs:[id]);}
  Future<void> deleteExpense(int id) async {await database!.delete('expenses',where:'id=?',whereArgs:[id]);}
  Future<void> deleteWarehouse(int id) async {if(id==1)throw Exception('لا يمكن حذف المخزن الرئيسي لأنه مرتبط بالحركات الافتراضية.');final count=Sqflite.firstIntValue(await database!.rawQuery('SELECT COUNT(*) FROM warehouses'));if((count??0)<=1)throw Exception('يجب الاحتفاظ بمخزن واحد على الأقل.');await database!.delete('warehouses',where:'id=?',whereArgs:[id]);}
  Future<void> deleteMovement(int id) async {
    await database!.transaction((txn) async {
      final found=await txn.query('operations',where:'id=?',whereArgs:[id],limit:1);
      if(found.isEmpty)return;
      final op=found.first;final pid=op['product_id'] as int;final qty=op['qty'] as int;
      final products=await txn.query('products',where:'id=?',whereArgs:[pid],limit:1);
      if(products.isNotEmpty){final current=products.first['qty'] as int;final next=op['kind']=='sale'?current+qty:current-qty;if(next<0)throw Exception('لا يمكن حذف عملية الشراء لأن الكمية صُرفت بالفعل. سوِّ المخزون أولاً.');await txn.rawInsert('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) VALUES(?,1,?)',[pid,current]);final stockRows=await txn.query('warehouse_stock',where:'product_id=? AND warehouse_id=1',whereArgs:[pid],limit:1);final stockQty=stockRows.first['qty'] as int;final nextWarehouse=op['kind']=='sale'?stockQty+qty:stockQty-qty;if(nextWarehouse<0)throw Exception('لا يمكن عكس الحركة: الكمية لم تعد متاحة في المخزن الرئيسي.');await txn.update('warehouse_stock',{'qty':nextWarehouse},where:'product_id=? AND warehouse_id=1',whereArgs:[pid]);await txn.update('products',{'qty':next},where:'id=?',whereArgs:[pid]);}
      await txn.delete('party_ledger',where:'reference=?',whereArgs:['operation:'+id.toString()]);
      await txn.delete('operations',where:'id=?',whereArgs:[id]);
      await txn.insert('activity_log',{'action':'حذف حركة وعكس أثرها','details':op['product_name'].toString()+' | '+qty.toString(),'created_at':DateTime.now().toIso8601String()});
    });
  }
  Future<void> _createProductHistory(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS price_history(id INTEGER PRIMARY KEY AUTOINCREMENT,product_id INTEGER NOT NULL,product_name TEXT NOT NULL,old_buy REAL NOT NULL,new_buy REAL NOT NULL,old_sell REAL NOT NULL,new_sell REAL NOT NULL,reason TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL)');
  }
  String _newSku(){const chars='ABCDEFGHIJKLMNOPQRSTUVWXYZ';final r=math.Random.secure();return '${chars[r.nextInt(26)]}${List.generate(5,(_)=>r.nextInt(10)).join()}';}
  Future<String> generateUniqueSku() async {
    for(var i=0;i<10000;i++){final s=_newSku();final x=await database!.query('products',columns:['id'],where:'sku=?',whereArgs:[s],limit:1);if(x.isEmpty)return s;}
    throw Exception('تعذر إنشاء كود فريد.');
  }
  Future<void> _backfillProductCodes(DatabaseExecutor db) async {
    final rows=await db.query('products',where:'sku IS NULL OR sku=""');
    for(final row in rows){String s;do{s=_newSku();final x=await db.query('products',columns:['id'],where:'sku=?',whereArgs:[s],limit:1);if(x.isNotEmpty)s='';}while(s.isEmpty);await db.update('products',{'sku':s},where:'id=?',whereArgs:[row['id']]);}
    await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_products_sku ON products(sku)');
  }
  Future<void> _createExtendedTables(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS suppliers(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,phone TEXT NOT NULL DEFAULT "",email TEXT NOT NULL DEFAULT "",address TEXT NOT NULL DEFAULT "",notes TEXT NOT NULL DEFAULT "",balance REAL NOT NULL DEFAULT 0)');
    await db.execute('CREATE TABLE IF NOT EXISTS customers(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,phone TEXT NOT NULL DEFAULT "",email TEXT NOT NULL DEFAULT "",address TEXT NOT NULL DEFAULT "",notes TEXT NOT NULL DEFAULT "",balance REAL NOT NULL DEFAULT 0)');
    await db.execute('CREATE TABLE IF NOT EXISTS warehouses(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,location TEXT NOT NULL DEFAULT "",notes TEXT NOT NULL DEFAULT "")');
    await db.execute('CREATE TABLE IF NOT EXISTS expenses(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,category TEXT NOT NULL DEFAULT "عام",amount REAL NOT NULL,notes TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS stock_adjustments(id INTEGER PRIMARY KEY AUTOINCREMENT,product_id INTEGER NOT NULL,product_name TEXT NOT NULL,old_qty INTEGER NOT NULL,new_qty INTEGER NOT NULL,difference INTEGER NOT NULL,reason TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL)');
    final wh = await db.rawQuery('SELECT COUNT(*) AS c FROM warehouses');
    if ((wh.first['c'] as int? ?? 0) == 0) await db.insert('warehouses', {'name':'المخزن الرئيسي','location':'','notes':''});
    await _createWarehouseStock(db);
  }
  Future<void> _createWarehouseStock(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS warehouse_stock(id INTEGER PRIMARY KEY AUTOINCREMENT,product_id INTEGER NOT NULL,warehouse_id INTEGER NOT NULL,qty INTEGER NOT NULL DEFAULT 0,UNIQUE(product_id,warehouse_id))');
    await db.execute('CREATE TABLE IF NOT EXISTS warehouse_transfers(id INTEGER PRIMARY KEY AUTOINCREMENT,product_id INTEGER NOT NULL,product_name TEXT NOT NULL,from_warehouse_id INTEGER NOT NULL,to_warehouse_id INTEGER NOT NULL,qty INTEGER NOT NULL,note TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL)');
    await db.execute('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) SELECT id,1,qty FROM products');
  }
  Future<List<Map<String,Object?>>> warehouseStock(int warehouseId) async { await database!.rawInsert('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) SELECT id,1,qty FROM products'); return database!.rawQuery('SELECT p.id,p.name,p.sku,p.qty AS total_qty,COALESCE(ws.qty,0) AS warehouse_qty,p.buy,p.sell FROM products p LEFT JOIN warehouse_stock ws ON ws.product_id=p.id AND ws.warehouse_id=? WHERE p.archived=0 ORDER BY p.name',[warehouseId]); }
  Future<List<Map<String,Object?>>> warehouseTransfers() => database!.query('warehouse_transfers',orderBy:'id DESC',limit:200);
  Future<void> transferStock({required int productId,required int fromWarehouseId,required int toWarehouseId,required int qty,required String note}) async {
    if(fromWarehouseId==toWarehouseId) throw Exception('اختر مخزنين مختلفين.');
    if(qty<=0) throw Exception('أدخل كمية صحيحة.');
    await database!.transaction((txn) async {
      final productRows=await txn.query('products',where:'id=?',whereArgs:[productId],limit:1);
      if(productRows.isEmpty) throw Exception('المنتج غير موجود.');
      final product=productRows.first;
      await txn.rawInsert('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) VALUES(?,?,0)',[productId,fromWarehouseId]);
      await txn.rawInsert('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) VALUES(?,?,0)',[productId,toWarehouseId]);
      final fromRows=await txn.query('warehouse_stock',where:'product_id=? AND warehouse_id=?',whereArgs:[productId,fromWarehouseId],limit:1);
      final available=fromRows.first['qty'] as int;
      if(available<qty) throw Exception('الكمية المتاحة في المخزن المصدر غير كافية.');
      final toRows=await txn.query('warehouse_stock',where:'product_id=? AND warehouse_id=?',whereArgs:[productId,toWarehouseId],limit:1);
      await txn.update('warehouse_stock',{'qty':available-qty},where:'product_id=? AND warehouse_id=?',whereArgs:[productId,fromWarehouseId]);
      await txn.update('warehouse_stock',{'qty':(toRows.first['qty'] as int)+qty},where:'product_id=? AND warehouse_id=?',whereArgs:[productId,toWarehouseId]);
      await txn.insert('warehouse_transfers',{'product_id':productId,'product_name':product['name'],'from_warehouse_id':fromWarehouseId,'to_warehouse_id':toWarehouseId,'qty':qty,'note':note,'created_at':DateTime.now().toIso8601String()});
      await txn.insert('activity_log',{'action':'تحويل مخزون بين المخازن','details':'${product['name']} | ${qty} | ${fromWarehouseId} → ${toWarehouseId}','created_at':DateTime.now().toIso8601String()});
    });
  }
  Future<void> _createPartyLedger(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS party_ledger(id INTEGER PRIMARY KEY AUTOINCREMENT,party_type TEXT NOT NULL,party_id INTEGER NOT NULL,entry_type TEXT NOT NULL,amount REAL NOT NULL,note TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL,reference TEXT NOT NULL DEFAULT "")');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_party_ledger_party ON party_ledger(party_type,party_id,id)');
    await db.execute("INSERT INTO party_ledger(party_type,party_id,entry_type,amount,note,created_at,reference) SELECT CASE WHEN kind='sale' THEN 'customer' ELSE 'supplier' END,party_id,'debit',total,note,created_at,'operation:'||id FROM operations o WHERE party_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM party_ledger l WHERE l.reference='operation:'||o.id)");
    await db.execute("INSERT INTO party_ledger(party_type,party_id,entry_type,amount,note,created_at,reference) SELECT 'customer',customer_id,'debit',total,'فاتورة سابقة',created_at,'invoice:'||id||':debit' FROM invoices i WHERE customer_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM party_ledger l WHERE l.reference='invoice:'||i.id||':debit')");
    await db.execute("INSERT INTO party_ledger(party_type,party_id,entry_type,amount,note,created_at,reference) SELECT 'customer',customer_id,'credit',paid,'مدفوع عند إصدار فاتورة سابقة',created_at,'invoice:'||id||':credit' FROM invoices i WHERE customer_id IS NOT NULL AND paid>0 AND NOT EXISTS(SELECT 1 FROM party_ledger l WHERE l.reference='invoice:'||i.id||':credit')");
  }
  Future<List<Map<String,Object?>>> partyLedger(String type,int id) => database!.query('party_ledger',where:'party_type=? AND party_id=?',whereArgs:[type,id],orderBy:'id DESC');
  Future<double> partyBalance(String type,int id) async {
    final table=type=='customer'?'customers':'suppliers';
    final party=await database!.query(table,columns:['balance'],where:'id=?',whereArgs:[id],limit:1);
    final opening=party.isEmpty?0.0:(party.first['balance'] as num).toDouble();
    final rows=await database!.rawQuery("SELECT COALESCE(SUM(CASE WHEN entry_type='debit' THEN amount ELSE -amount END),0) AS balance FROM party_ledger WHERE party_type=? AND party_id=?",[type,id]);
    return opening+(rows.first['balance'] as num).toDouble();
  }
  Future<void> recordPartyPayment({required String type,required int partyId,required double amount,required String note}) async {
    if(amount<=0)throw Exception('أدخل مبلغاً أكبر من صفر.');
    await database!.transaction((txn) async {
      final table=type=='customer'?'customers':'suppliers';
      final partyRows=await txn.query(table,columns:['balance'],where:'id=?',whereArgs:[partyId],limit:1);
      if(partyRows.isEmpty)throw Exception('الحساب غير موجود.');
      final opening=(partyRows.first['balance'] as num).toDouble();
      final rows=await txn.rawQuery("SELECT COALESCE(SUM(CASE WHEN entry_type='debit' THEN amount ELSE -amount END),0) AS balance FROM party_ledger WHERE party_type=? AND party_id=?",[type,partyId]);
      final balance=opening+(rows.first['balance'] as num).toDouble();
      if(amount>balance)throw Exception('المبلغ أكبر من الرصيد المستحق.');
      await txn.insert('party_ledger',{'party_type':type,'party_id':partyId,'entry_type':'credit','amount':amount,'note':note,'created_at':DateTime.now().toIso8601String(),'reference':'دفعة يدوية'});
      await txn.insert('activity_log',{'action':type=='customer'?'تحصيل من عميل':'سداد لمورد','details':'رقم الطرف $partyId | $amount | $note','created_at':DateTime.now().toIso8601String()});
    });
  }
  Future<List<Map<String,Object?>>> parties(String table,[String query='']) => database!.query(table,where:query.trim().isEmpty?null:'name LIKE ?',whereArgs:query.trim().isEmpty?null:['%$query%'],orderBy:'name');
  Future<void> saveParty(String table,Map<String,Object?> data,int? id) async { if(id==null){await database!.insert(table,data);}else{await database!.update(table,data,where:'id=?',whereArgs:[id]);} await log('تعديل بيانات',table); }
  Future<void> deleteParty(String table,int id) async { final type=table=='customers'?'customer':table=='suppliers'?'supplier':'';if(type.isNotEmpty){final count=Sqflite.firstIntValue(await database!.rawQuery('SELECT COUNT(*) FROM party_ledger WHERE party_type=? AND party_id=?',[type,id]))??0;if(count>0)throw Exception('لا يمكن حذف حساب له كشف حركات مالية؛ احتفظ بالسجل أو عدّل بياناته.');}await database!.delete(table,where:'id=?',whereArgs:[id]); }
  Future<List<Map<String,Object?>>> expenses() => database!.query('expenses',orderBy:'id DESC');
  Future<void> addExpense(String title,String category,double amount,String notes) async {
    if(title.trim().isEmpty||amount<=0) throw Exception('أدخل بيان المصروف ومبلغاً أكبر من صفر.');
    await database!.insert('expenses',{'title':title.trim(),'category':category.trim(),'amount':amount,'notes':notes.trim(),'created_at':DateTime.now().toIso8601String()});
    await log('إضافة مصروف',title.trim()+' | '+amount.toString());
  }
  Future<void> adjustStock(Map<String,Object?> product,int newQty,String reason) async {
    if(newQty<0) throw Exception('الكمية لا يمكن أن تكون سالبة.');
    await database!.transaction((txn) async {
      final old=product['qty'] as int;
      final otherRows=await txn.rawQuery('SELECT COALESCE(SUM(qty),0) AS qty FROM warehouse_stock WHERE product_id=? AND warehouse_id<>1',[product['id']]);
      final otherQty=(otherRows.first['qty'] as num).toInt();
      if(newQty<otherQty) throw Exception('الكمية الجديدة أقل من الكميات الموجودة في المخازن الأخرى.');
      await txn.update('products',{'qty':newQty},where:'id=?',whereArgs:[product['id']]);
      await txn.rawInsert('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) VALUES(?,1,?)',[product['id'],newQty]);
      await txn.update('warehouse_stock',{'qty':newQty-otherQty},where:'product_id=? AND warehouse_id=1',whereArgs:[product['id']]);
      await txn.insert('stock_adjustments',{'product_id':product['id'],'product_name':product['name'],'old_qty':old,'new_qty':newQty,'difference':newQty-old,'reason':reason,'created_at':DateTime.now().toIso8601String()});
      await txn.insert('activity_log',{'action':'تسوية مخزون','details':product['name'].toString()+' | '+old.toString()+' ← '+newQty.toString()+' | '+reason,'created_at':DateTime.now().toIso8601String()});
    });
  }
  Future<List<Map<String,Object?>>> products([String query = '']) async {
    final q=query.trim();if(q.isEmpty)return database!.query('products',where:'archived=0',orderBy:'name');
    final tokens=q.split(RegExp(r'\s+')).where((v)=>v.isNotEmpty).toList();
    const fields=['name','category','sku','part_no','alt_part_no','brand','manufacturer','alt_names','location','specs'];
    final clauses=tokens.map((_)=>'('+fields.map((f)=>f+' LIKE ?').join(' OR ')+')').join(' AND ');
    final args=tokens.expand((token)=>fields.map((_)=>'%'+token+'%')).toList();
    return database!.query('products',where:'archived=0 AND '+clauses,whereArgs:args,orderBy:'name');
  }
  Future<List<Map<String,Object?>>> priceHistory([int? id])=>database!.query('price_history',where:id==null?null:'product_id=?',whereArgs:id==null?null:[id],orderBy:'id DESC');
  Future<List<Map<String,Object?>>> similarProducts(Uint8List queryBytes) async {
    final source=img.decodeImage(queryBytes);
    if(source==null)throw Exception('الصورة غير مدعومة أو تالفة.');
    List<bool> fingerprint(img.Image image){
      final tiny=img.grayscale(img.copyResize(image,width:9,height:8));
      final bits=<bool>[];
      for(var y=0;y<8;y++){for(var x=0;x<8;x++){bits.add(tiny.getPixel(x,y).r>tiny.getPixel(x+1,y).r);}}
      return bits;
    }
    List<List<bool>> fingerprints(img.Image image){
      final side=image.width<image.height?image.width:image.height;
      final center=img.copyCrop(image,x:(image.width-side)~/2,y:(image.height-side)~/2,width:side,height:side);
      return [fingerprint(image),fingerprint(center)];
    }
    final queryHashes=fingerprints(source);
    final rows=await database!.query('products',where:'image_path<>? AND archived=0',whereArgs:['']);
    final ranked=<Map<String,Object?>>[];
    for(final row in rows){
      try{
        final path=(row['image_path']??'').toString();
        final file=File(path);
        if(!await file.exists())continue;
        final decoded=img.decodeImage(await file.readAsBytes());
        if(decoded==null)continue;
        final productHashes=fingerprints(decoded);
        var similarity=0.0;
        for(final queryBits in queryHashes){for(final bits in productHashes){
          var distance=0;
          for(var i=0;i<64;i++){if(bits[i]!=queryBits[i])distance++;}
          similarity=math.max(similarity,(64-distance)/64).toDouble();
        }}
        if(similarity>=0.55)ranked.add({...row,'similarity':similarity});
      }catch(_){continue;}
    }
    ranked.sort((a,b)=>(b['similarity'] as double).compareTo(a['similarity'] as double));
    return ranked.take(8).toList();
  }

  Future<void> saveProduct(Map<String,Object?> data, int? id) async {
    final v=Map<String,Object?>.from(data);
    if(id==null){final requested=(v['sku']??'').toString().trim().toUpperCase();if(requested.isEmpty){v['sku']=await generateUniqueSku();}else{final exists=await database!.query('products',columns:['id'],where:'sku=?',whereArgs:[requested],limit:1);if(exists.isNotEmpty)throw Exception('هذا الكود مستخدم بالفعل.');v['sku']=requested;}final newId=await database!.insert('products',v);
      await database!.insert('warehouse_stock',{'product_id':newId,'warehouse_id':1,'qty':v['qty']??0},conflictAlgorithm:ConflictAlgorithm.replace);
      return;}
    final rows=await database!.query('products',where:'id=?',whereArgs:[id],limit:1);if(rows.isEmpty)throw Exception('المنتج غير موجود.');
    final old=rows.first;final requested=(v['sku']??'').toString().trim().toUpperCase();if(requested.isEmpty||requested==old['sku']){v['sku']=old['sku'];}else{final exists=await database!.query('products',columns:['id'],where:'sku=? AND id<>?',whereArgs:[requested,id],limit:1);if(exists.isNotEmpty)throw Exception('هذا الكود مستخدم بالفعل.');v['sku']=requested;}final ob=(old['buy'] as num).toDouble(),os=(old['sell'] as num).toDouble(),nb=(v['buy'] as num).toDouble(),ns=(v['sell'] as num).toDouble();
    if(ob!=nb||os!=ns)await database!.insert('price_history',{'product_id':id,'product_name':old['name'],'old_buy':ob,'new_buy':nb,'old_sell':os,'new_sell':ns,'reason':'تعديل السعر','created_at':DateTime.now().toIso8601String()});
    final otherRows=await database!.rawQuery('SELECT COALESCE(SUM(qty),0) AS qty FROM warehouse_stock WHERE product_id=? AND warehouse_id<>1',[id]);
     final otherQty=(otherRows.first['qty'] as num).toInt();
     final targetQty=(v['qty'] as num).toInt();
     if(targetQty<otherQty)throw Exception('الكمية الإجمالية لا يمكن أن تقل عن الموجود في المخازن الأخرى.');
     await database!.transaction((txn) async {
       await txn.update('products',v,where:'id=?',whereArgs:[id]);
       await txn.rawInsert('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) VALUES(?,1,0)',[id]);
       await txn.update('warehouse_stock',{'qty':targetQty-otherQty},where:'product_id=? AND warehouse_id=1',whereArgs:[id]);
     });
  }
  Future<void> removeProduct(int id) async {
    final count = Sqflite.firstIntValue(await database!.rawQuery('SELECT COUNT(*) FROM operations WHERE product_id=?',[id])) ?? 0;
    if (count > 0) throw Exception('لا يمكن حذف منتج مرتبط بحركات سابقة؛ استخدم الأرشفة حتى لا تضيع سجلات الحسابات.');
    final rows=await database!.query('products',columns:['image_path'],where:'id=?',whereArgs:[id],limit:1);
    if(rows.isEmpty)return;
    final imagePath=(rows.first['image_path']??'').toString();
    await database!.transaction((txn) async {
      await txn.delete('favorites',where:'product_id=?',whereArgs:[id]);
      await txn.delete('product_notes',where:'product_id=?',whereArgs:[id]);
      await txn.delete('product_images',where:'product_id=?',whereArgs:[id]);
      await txn.delete('products',where:'id=?',whereArgs:[id]);
    });
    if(imagePath.isNotEmpty){try{final file=File(imagePath);if(await file.exists())await file.delete();}catch(_){}}
  }
  Future<void> addMovement(String kind, Map<String,Object?> product, int qty, double price, String note, [Map<String,Object?>? party]) async {
    if (qty <= 0 || price < 0) throw Exception('تحقق من الكمية والسعر.');
    await database!.transaction((txn) async {
      final current = product['qty'] as int;
      if (kind == 'sale' && current < qty) throw Exception('الكمية المتاحة لا تكفي.');
      final next = kind == 'sale' ? current - qty : current + qty;
      await txn.rawInsert('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) VALUES(?,1,?)',[product['id'],current]);
      final whRows=await txn.query('warehouse_stock',where:'product_id=? AND warehouse_id=1',whereArgs:[product['id']],limit:1);
      final whQty=whRows.first['qty'] as int;
      if(kind=='sale' && whQty<qty) throw Exception('الكمية المتاحة في المخزن الرئيسي غير كافية.');
      await txn.update('warehouse_stock',{'qty':kind=='sale'?whQty-qty:whQty+qty},where:'product_id=? AND warehouse_id=1',whereArgs:[product['id']]);
      await txn.update('products', {'qty':next,if(kind=='purchase'&&party!=null)'supplier_id':party['id']},where:'id=?',whereArgs:[product['id']]);
      final operationId=await txn.insert('operations', {
        'kind':kind,'product_id':product['id'],'product_name':product['name'],
        'qty':qty,'unit_price':price,'total':qty*price,'note':note,
        'created_at':DateTime.now().toIso8601String(),
        'cost_price':(product['buy'] as num).toDouble(),
        'party_id':party?['id'],'party_name':party?['name'] ?? '','warehouse_id':1,
      });
      if(party!=null){await txn.insert('party_ledger',{'party_type':kind=='sale'?'customer':'supplier','party_id':party['id'],'entry_type':'debit','amount':qty*price,'note':note,'created_at':DateTime.now().toIso8601String(),'reference':'operation:'+operationId.toString()});}
      await txn.insert('activity_log',{'action':kind=='sale'?'تسجيل بيع':'تسجيل شراء','details':product['name'].toString()+' | كمية: '+qty.toString()+' | إجمالي: '+(qty*price).toString(),'created_at':DateTime.now().toIso8601String()});
    });
  }
  Future<List<Map<String,Object?>>> movements([String? kind]) => database!.query('operations',
    where:kind == null ? null : 'kind=?',whereArgs:kind == null ? null : [kind],orderBy:'id DESC');

  Future<List<Map<String,Object?>>> invoices({bool pendingOnly=false})=>database!.query('invoices',where:pendingOnly?'total>paid':null,orderBy:'id DESC');
  Future<List<Map<String,Object?>>> invoiceItems(int id)=>database!.query('invoice_items',where:'invoice_id=?',whereArgs:[id],orderBy:'id');
  Future<List<Map<String,Object?>>> shortageGroups() async => database!.rawQuery("SELECT p.id AS product_id,p.name AS product_name,p.sku,p.qty,p.min_qty,p.unit,p.supplier_id,COALESCE(s.name,'بدون مورد') AS supplier_name,COALESCE((SELECT SUM(o.qty) FROM operations o WHERE o.product_id=p.id AND o.kind='sale'),0) AS sold_qty FROM products p LEFT JOIN suppliers s ON s.id=p.supplier_id WHERE p.archived=0 AND p.qty<=p.min_qty AND COALESCE((SELECT SUM(o.qty) FROM operations o WHERE o.product_id=p.id AND o.kind='sale'),0)>0 ORDER BY supplier_name,p.name");
  Future<void> createInvoice({required String customerName,required String customerPhone,required int? customerId,required List<Map<String,Object?>> items,required double discountValue,required bool discountPercent,required double paid,required String note}) async {
    if(items.isEmpty)throw Exception('أضف صنفاً واحداً على الأقل.');
    if(customerName.trim().isEmpty)throw Exception('اكتب اسم العميل لإصدار الفاتورة.');
    await database!.transaction((txn) async {
      final now=DateTime.now().toIso8601String();double subtotal=0;
      int? resolvedCustomerId=customerId;
      if(resolvedCustomerId==null){
        final phone=customerPhone.trim();
        var matches=phone.isNotEmpty?await txn.query('customers',where:'phone=?',whereArgs:[phone],limit:1):<Map<String,Object?>>[];if(matches.isEmpty){matches=await txn.query('customers',where:'name=? COLLATE NOCASE',whereArgs:[customerName.trim()],limit:1);}
        if(matches.isNotEmpty){resolvedCustomerId=matches.first['id'] as int; if(phone.isNotEmpty)await txn.update('customers',{'phone':phone},where:'id=?',whereArgs:[resolvedCustomerId]);}
        else{resolvedCustomerId=await txn.insert('customers',{'name':customerName.trim(),'phone':phone,'email':'','address':'','notes':'أُضيف تلقائياً من فاتورة بيع','balance':0});}
      }
      for(final item in items){final q=item['qty'] as int;final price=(item['unit_price'] as num).toDouble();if(q<=0||price<0)throw Exception('راجع كمية وسعر الأصناف.');subtotal+=q*price;}
      final discount=discountPercent?subtotal*discountValue/100:discountValue;
      if(discount<0||discount>subtotal)throw Exception('قيمة الخصم غير صحيحة.');
      final total=subtotal-discount;if(paid<0||paid>total)throw Exception('المبلغ المدفوع يجب ألا يتجاوز إجمالي الفاتورة.');
      for(final item in items){final id=item['product_id'] as int;final q=item['qty'] as int;final found=await txn.query('products',where:'id=?',whereArgs:[id],limit:1);if(found.isEmpty)throw Exception('أحد المنتجات لم يعد موجوداً.');if((found.first['qty'] as int)<q)throw Exception('الكمية غير كافية للمنتج: ${item['product_name']}');}
      final count=Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM invoices'))??0;
      final invoiceNo='INV-${DateTime.now().year}-${(count+1).toString().padLeft(5,'0')}';
      final invoiceId=await txn.insert('invoices',{'invoice_no':invoiceNo,'customer_id':resolvedCustomerId,'customer_name':customerName.trim(),'customer_phone':customerPhone.trim(),'subtotal':subtotal,'discount_value':discountValue,'discount_mode':discountPercent?'percent':'amount','discount_amount':discount,'total':total,'paid':paid,'note':note,'created_at':now});
      if(total>0)await txn.insert('party_ledger',{'party_type':'customer','party_id':resolvedCustomerId,'entry_type':'debit','amount':total,'note':'فاتورة بيع $invoiceNo','created_at':now,'reference':invoiceNo});if(paid>0){await txn.insert('party_ledger',{'party_type':'customer','party_id':resolvedCustomerId,'entry_type':'credit','amount':paid,'note':'مدفوع عند إصدار الفاتورة','created_at':now,'reference':invoiceNo});await txn.insert('invoice_payments',{'invoice_id':invoiceId,'amount':paid,'paid_at':now,'note':'دفعة عند إصدار الفاتورة'});}
      for(final item in items){final id=item['product_id'] as int;final q=item['qty'] as int;final price=(item['unit_price'] as num).toDouble();final line=q*price;
        final current=(await txn.query('products',columns:['qty'],where:'id=?',whereArgs:[id])).first['qty'] as int;
        await txn.rawInsert('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) VALUES(?,1,?)',[id,current]);
        final warehouseRows=await txn.query('warehouse_stock',where:'product_id=? AND warehouse_id=1',whereArgs:[id],limit:1);
        final warehouseQty=warehouseRows.first['qty'] as int;
        if(warehouseQty<q) throw Exception('الكمية في المخزن الرئيسي لا تكفي لإصدار الفاتورة.');
        await txn.update('warehouse_stock',{'qty':warehouseQty-q},where:'product_id=? AND warehouse_id=1',whereArgs:[id]);
        await txn.update('products',{'qty':current-q},where:'id=?',whereArgs:[id]);
        final lineAddedAt=DateTime.now().toIso8601String();final lineSupplierId=item['supplier_id'] as int?;final lineSupplierName=(item['supplier_name']??'').toString();await txn.update('products',{'supplier_id':lineSupplierId},where:'id=?',whereArgs:[id]);await txn.insert('invoice_items',{'invoice_id':invoiceId,'product_id':id,'product_name':item['product_name'],'qty':q,'unit_price':price,'total':line,'supplier_id':lineSupplierId,'supplier_name':lineSupplierName,'added_at':lineAddedAt});
        await txn.insert('operations',{'kind':'sale','product_id':id,'product_name':item['product_name'],'qty':q,'unit_price':price,'total':line,'note':'فاتورة '+invoiceNo,'created_at':now,'cost_price':item['cost_price']??0,'party_id':resolvedCustomerId,'party_name':customerName.trim(),'warehouse_id':1});
      }
      await txn.insert('activity_log',{'action':'إصدار فاتورة','details':invoiceNo+' | '+customerName+' | '+total.toString(),'created_at':now});
    });
  }
  Future<void> appendInvoiceItems(int invoiceId,List<Map<String,Object?>> items) async {
    if(items.isEmpty)throw Exception('أضف صنفاً واحداً على الأقل.');
    await database!.transaction((txn) async {
      final found=await txn.query('invoices',where:'id=?',whereArgs:[invoiceId],limit:1);
      if(found.isEmpty)throw Exception('الفاتورة غير موجودة.');
      final invoice=found.first;double addedSubtotal=0;
      for(final item in items){
        final id=item['product_id'] as int;final q=item['qty'] as int;final price=(item['unit_price'] as num).toDouble();
        if(q<=0||price<0)throw Exception('راجع كمية وسعر الأصناف.');
        final productRows=await txn.query('products',where:'id=?',whereArgs:[id],limit:1);
        if(productRows.isEmpty)throw Exception('أحد المنتجات لم يعد موجوداً.');
        final product=productRows.first;final current=product['qty'] as int;
        if(current<q)throw Exception('الكمية غير كافية للمنتج: ${item['product_name']}');
        await txn.rawInsert('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) VALUES(?,1,?)',[id,current]);
        final wh=(await txn.query('warehouse_stock',where:'product_id=? AND warehouse_id=1',whereArgs:[id],limit:1)).first['qty'] as int;
        if(wh<q)throw Exception('الكمية في المخزن الرئيسي لا تكفي.');
        await txn.update('warehouse_stock',{'qty':wh-q},where:'product_id=? AND warehouse_id=1',whereArgs:[id]);
        await txn.update('products',{'qty':current-q,'supplier_id':item['supplier_id']},where:'id=?',whereArgs:[id]);
        final lineTotal=q*price;final addedAt=DateTime.now().toIso8601String();
        addedSubtotal+=lineTotal;
        await txn.insert('invoice_items',{'invoice_id':invoiceId,'product_id':id,'product_name':item['product_name'],'qty':q,'unit_price':price,'total':lineTotal,'supplier_id':item['supplier_id'],'supplier_name':item['supplier_name']??'','added_at':addedAt});
        await txn.insert('operations',{'kind':'sale','product_id':id,'product_name':item['product_name'],'qty':q,'unit_price':price,'total':lineTotal,'note':'فاتورة ${invoice['invoice_no']}','created_at':addedAt,'cost_price':item['cost_price']??product['buy']??0,'party_id':invoice['customer_id'],'party_name':invoice['customer_name'],'warehouse_id':1});
      }
      final oldSubtotal=(invoice['subtotal'] as num).toDouble(),newSubtotal=oldSubtotal+addedSubtotal;
      final discountValue=(invoice['discount_value'] as num).toDouble();final isPercent=invoice['discount_mode']=='percent';
      final discount=isPercent?newSubtotal*discountValue/100:discountValue;
      final newTotal=(newSubtotal-discount).clamp(0,double.infinity).toDouble();
      final oldTotal=(invoice['total'] as num).toDouble();final delta=newTotal-oldTotal;
      await txn.update('invoices',{'subtotal':newSubtotal,'discount_amount':discount,'total':newTotal},where:'id=?',whereArgs:[invoiceId]);
      if(delta>0)await txn.insert('party_ledger',{'party_type':'customer','party_id':invoice['customer_id'],'entry_type':'debit','amount':delta,'note':'إضافة أصناف إلى فاتورة ${invoice['invoice_no']}','created_at':DateTime.now().toIso8601String(),'reference':'${invoice['invoice_no']}-ADD-${DateTime.now().microsecondsSinceEpoch}'});
      await txn.insert('activity_log',{'action':'إضافة أصناف لفاتورة','details':'${invoice['invoice_no']} | ${items.length} صنف | ${addedSubtotal.toStringAsFixed(2)}','created_at':DateTime.now().toIso8601String()});
    });
  }

  Future<void> createInvoiceFromSales({required List<int> operationIds,required String customerName,required String customerPhone,required double paid}) async {
    if(operationIds.isEmpty)throw Exception('حدد عملية بيع واحدة على الأقل.');
    if(customerName.trim().isEmpty)throw Exception('اكتب اسم العميل.');
    await database!.transaction((txn) async {
      final marks=List.filled(operationIds.length,'?').join(',');
      final sales=await txn.rawQuery("SELECT * FROM operations WHERE kind='sale' AND id IN ($marks) ORDER BY id",operationIds);
      if(sales.length!=operationIds.toSet().length)throw Exception('بعض عمليات البيع المحددة غير موجودة.');
      if(sales.any((e)=>(e['note']??'').toString().startsWith('فاتورة ')))throw Exception('العمليات المرتبطة بفاتورة موجودة لا يمكن دمجها مرة أخرى.');
      final subtotal=sales.fold<double>(0,(sum,e)=>sum+(e['total'] as num).toDouble());
      if(paid<0||paid>subtotal)throw Exception('راجع المبلغ المدفوع.');
      final phone=customerPhone.trim();final name=customerName.trim();
      var matches=phone.isNotEmpty?await txn.query('customers',where:'phone=?',whereArgs:[phone],limit:1):<Map<String,Object?>>[];if(matches.isEmpty){matches=await txn.query('customers',where:'name=? COLLATE NOCASE',whereArgs:[name],limit:1);}
      int customerId;
      if(matches.isNotEmpty){customerId=matches.first['id'] as int;if(phone.isNotEmpty)await txn.update('customers',{'phone':phone},where:'id=?',whereArgs:[customerId]);}
      else{customerId=await txn.insert('customers',{'name':name,'phone':phone,'email':'','address':'','notes':'أُضيف تلقائياً من فاتورة مبيعات مجمعة','balance':0});}
      final count=Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM invoices'))??0;
      final invoiceNo='INV-${DateTime.now().year}-${(count+1).toString().padLeft(5,'0')}';
      final now=DateTime.now().toIso8601String();
      final invoiceId=await txn.insert('invoices',{'invoice_no':invoiceNo,'customer_id':customerId,'customer_name':name,'customer_phone':phone,'subtotal':subtotal,'discount_value':0,'discount_mode':'amount','discount_amount':0,'total':subtotal,'paid':paid,'note':'فاتورة مجمعة من صفحة المبيعات','created_at':now});
      await txn.insert('party_ledger',{'party_type':'customer','party_id':customerId,'entry_type':'debit','amount':subtotal,'note':'فاتورة بيع $invoiceNo','created_at':now,'reference':invoiceNo});
      if(paid>0){await txn.insert('party_ledger',{'party_type':'customer','party_id':customerId,'entry_type':'credit','amount':paid,'note':'مدفوع عند إصدار الفاتورة','created_at':now,'reference':invoiceNo});await txn.insert('invoice_payments',{'invoice_id':invoiceId,'amount':paid,'paid_at':now,'note':'دفعة عند إصدار الفاتورة'});}
      final grouped=<String,Map<String,Object?>>{};
      for(final sale in sales){final key='${sale['product_id']}|${sale['unit_price']}';final existing=grouped[key];if(existing==null){grouped[key]={'product_id':sale['product_id'],'product_name':sale['product_name'],'qty':sale['qty'],'unit_price':sale['unit_price'],'total':sale['total']};}else{existing['qty']=(existing['qty'] as int)+(sale['qty'] as int);existing['total']=(existing['total'] as num).toDouble()+(sale['total'] as num).toDouble();}}
      for(final sale in sales){
        final id=sale['id'] as int;
        await txn.delete('party_ledger',where:'reference=?',whereArgs:['operation:'+id.toString()]);
        await txn.update('operations',{'party_id':customerId,'party_name':name,'note':'فاتورة $invoiceNo • '+(sale['note']??'').toString()},where:'id=?',whereArgs:[id]);
      }
      for(final item in grouped.values){await txn.insert('invoice_items',{'invoice_id':invoiceId,...item});}
      await txn.insert('activity_log',{'action':'دمج مبيعات في فاتورة','details':'$invoiceNo | $name | عدد الأصناف: ${sales.length} | الإجمالي: $subtotal','created_at':now});
    });
  }
  Future<double> collectedSales() async {
    final direct=await database!.rawQuery("SELECT COALESCE(SUM(total),0) AS amount FROM operations WHERE kind='sale' AND party_id IS NULL AND note NOT LIKE 'فاتورة %'");
    final invoices=await database!.rawQuery("SELECT COALESCE(SUM(paid),0) AS amount FROM invoices");
    return (direct.first['amount'] as num).toDouble()+(invoices.first['amount'] as num).toDouble();
  }
  Future<List<Map<String,Object?>>> invoicePayments(int id)=>database!.query('invoice_payments',where:'invoice_id=?',whereArgs:[id],orderBy:'id DESC');
  Future<void> addInvoicePayment(int id,double amount) async {
    if(amount<=0)throw Exception('أدخل مبلغاً صحيحاً.');
    await database!.transaction((txn) async {final rows=await txn.query('invoices',where:'id=?',whereArgs:[id],limit:1);if(rows.isEmpty)throw Exception('الفاتورة غير موجودة.');final row=rows.first;final due=(row['total'] as num).toDouble()-(row['paid'] as num).toDouble();if(amount>due)throw Exception('المبلغ أكبر من المتبقي.');await txn.update('invoices',{'paid':(row['paid'] as num).toDouble()+amount},where:'id=?',whereArgs:[id]);await txn.insert('invoice_payments',{'invoice_id':id,'amount':amount,'paid_at':DateTime.now().toIso8601String(),'note':'دفعة نقدية'});if(row['customer_id']!=null){await txn.insert('party_ledger',{'party_type':'customer','party_id':row['customer_id'],'entry_type':'credit','amount':amount,'note':'تحصيل فاتورة '+row['invoice_no'].toString(),'created_at':DateTime.now().toIso8601String(),'reference':row['invoice_no'].toString()});}await txn.insert('activity_log',{'action':'تحصيل دفعة فاتورة','details':row['invoice_no'].toString()+' | '+amount.toString(),'created_at':DateTime.now().toIso8601String()});});
  }

  Future<Map<String,Object?>> summary() async {
    final products = await database!.query('products',where:'archived=0');
    final sales = await database!.rawQuery("SELECT COALESCE(SUM(total),0) AS total FROM operations WHERE kind='sale'");
    final buys = await database!.rawQuery("SELECT COALESCE(SUM(total),0) AS total FROM operations WHERE kind='purchase'");
    final expenses = await database!.rawQuery("SELECT COALESCE(SUM(amount),0) AS total FROM expenses");
    final profit = await database!.rawQuery("SELECT COALESCE(SUM((unit_price-cost_price)*qty),0) AS total FROM operations WHERE kind='sale'");
    return {
      'count':products.length,
      'qty':products.fold<int>(0,(sum,row)=>sum + (row['qty'] as int)),
      'low':products.where((row)=>(row['qty'] as int)>0&&(row['qty'] as int) <= (row['min_qty'] as int)).length,
      'out':products.where((row)=>(row['qty'] as int)==0).length,
      'categories':Sqflite.firstIntValue(await database!.rawQuery('SELECT COUNT(*) FROM categories'))??0,
      'manufacturers':products.map((row)=>(row['manufacturer']??'').toString()).where((v)=>v.isNotEmpty).toSet().length,
      'stock':products.fold<double>(0,(sum,row)=>sum + (row['qty'] as int) * (row['buy'] as num).toDouble()),
      'stock_sell':products.fold<double>(0,(sum,row)=>sum + (row['qty'] as int) * (row['sell'] as num).toDouble()),
      'sales':(sales.first['total'] as num).toDouble(),
      'buys':(buys.first['total'] as num).toDouble(),
      'expense_total':(expenses.first['total'] as num).toDouble(),
      'profit':(profit.first['total'] as num).toDouble(),
    };
  }

  Future<Map<String,Object?>> _backupData() async {
    final products=await database!.query('products');
    final blobs=<Map<String,Object?>>[];
    for(final product in products){final path=(product['image_path']??'').toString();if(path.isEmpty)continue;try{final file=File(path);if(await file.exists()){blobs.add({'product_id':product['id'],'name':p.basename(path),'data':base64Encode(await file.readAsBytes())});}}catch(_){}}
    return {'format':'MYAPP_BACKUP_3','products':products,'operations':await database!.query('operations'),'suppliers':await database!.query('suppliers'),'customers':await database!.query('customers'),'warehouses':await database!.query('warehouses'),'expenses':await database!.query('expenses'),'stock_adjustments':await database!.query('stock_adjustments'),'price_history':await database!.query('price_history'),'categories':await database!.query('categories'),'favorites':await database!.query('favorites'),'recent_searches':await database!.query('recent_searches'),'activity_log':await database!.query('activity_log'),'tasks':await database!.query('tasks'),'product_notes':await database!.query('product_notes'),'product_images':await database!.query('product_images'),'invoices':await database!.query('invoices'),'invoice_items':await database!.query('invoice_items'),'invoice_payments':await database!.query('invoice_payments'),'warehouse_stock':await database!.query('warehouse_stock'),'warehouse_transfers':await database!.query('warehouse_transfers'),'party_ledger':await database!.query('party_ledger'),'image_blobs':blobs};
  }
  Future<Map<int,String>> _restoreImageBlobs(Map<String,dynamic> data) async {
    final result=<int,String>{};final blobs=data['image_blobs'] as List? ?? [];if(blobs.isEmpty)return result;
    final dir=await getApplicationSupportDirectory();final imageDir=Directory(p.join(dir.path,'product_images'));await imageDir.create(recursive:true);
    for(final item in blobs){try{final row=Map<String,Object?>.from(item as Map);final id=row['product_id'] as int;final name=(row['name']??'product.jpg').toString();final ext=p.extension(name).isEmpty?'.jpg':p.extension(name);final file=File(p.join(imageDir.path,'product_'+id.toString()+'_'+DateTime.now().microsecondsSinceEpoch.toString()+ext));await file.writeAsBytes(base64Decode(row['data'] as String),flush:true);result[id]=file.path;}catch(_){}}
    return result;
  }
  Future<String> backup() async {
    final dir = await getApplicationDocumentsDirectory();
    final data = await _backupData();
    final file = File(p.join(dir.path,'my_app_backup.json'));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return file.path;
  }
  Future<String?> exportBackup() async {
    final data = await _backupData();
    final bytes=Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(data)));
    return FilePicker.platform.saveFile(dialogTitle:'حفظ النسخة الاحتياطية',fileName:'MYAPP_Backup.json',type:FileType.custom,allowedExtensions:['json'],bytes:bytes);
  }

  Future<int> importProductsCsv() async {
    final picked=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['csv'],withData:true);
    if(picked==null||picked.files.isEmpty||picked.files.first.bytes==null)return 0;
    final content=utf8.decode(picked.files.first.bytes!,allowMalformed:true).replaceFirst('\uFEFF','');
    final rows=const CsvToListConverter(shouldParseNumbers:false).convert(content);
    if(rows.length<2)throw Exception('ملف CSV لا يحتوي على أصناف.');
    final headers=rows.first.map((e)=>e.toString().trim().toLowerCase()).toList();
    int index(List<String> names)=>headers.indexWhere((h)=>names.contains(h));
    String val(List<dynamic> row,List<String> names){final i=index(names);return i<0||i>=row.length?'':row[i].toString().trim();}
    double number(List<dynamic> row,List<String> names)=>double.tryParse(val(row,names).replaceAll(',','.'))??0;
    int whole(List<dynamic> row,List<String> names)=>int.tryParse(val(row,names))??0;
    var added=0;
    await database!.transaction((txn) async {
      for(final row in rows.skip(1)){
        final name=val(row,['product','name','اسم المنتج','الاسم']);if(name.isEmpty)continue;
        var sku=val(row,['sku','code','الكود']).toUpperCase();
        if(sku.isNotEmpty){final exists=await txn.query('products',columns:['id'],where:'sku=?',whereArgs:[sku],limit:1);if(exists.isNotEmpty)sku='';}
        if(sku.isEmpty){do{sku=_newSku();final exists=await txn.query('products',columns:['id'],where:'sku=?',whereArgs:[sku],limit:1);if(exists.isNotEmpty)sku='';}while(sku.isEmpty);}
        await txn.insert('products',{'name':name,'category':val(row,['category','التصنيف']),'qty':whole(row,['quantity','qty','الكمية']),'min_qty':whole(row,['minimum','min_qty','حد التنبيه']),'buy':number(row,['purchase price','buy','سعر الشراء']),'sell':number(row,['selling price','sell','سعر البيع']),'sku':sku,'manufacturer':val(row,['manufacturer','الشركة المصنعة']),'part_no':val(row,['part_no','رقم القطعة']),'alt_part_no':val(row,['alt_part_no','رقم القطعة البديل']),'location':val(row,['location','الموقع','مكان التخزين']),'description':val(row,['description','الوصف']),'wholesale':number(row,['wholesale','سعر الجملة']),'brand':val(row,['brand','الماركة']),'unit':val(row,['unit','الوحدة']).isEmpty?'قطعة':val(row,['unit','الوحدة']),'country':val(row,['country','بلد المنشأ']),'alt_names':val(row,['alt_names','أسماء أخرى']),'specs':val(row,['specs','المواصفات']),'image_path':'','archived':0});
        added++;
      }
      await txn.insert('activity_log',{'action':'استيراد أصناف CSV','details':'تم استيراد '+added.toString()+' صنف','created_at':DateTime.now().toIso8601String()});
    });
    return added;
  }
  Future<String?> exportInventoryCsv() async {
    final rows=await database!.query('products',orderBy:'name');
    String cell(Object? v)=>'"'+(v??'').toString().replaceAll('"','""')+'"';
    final lines=<String>['ID,SKU,Product,Category,Quantity,Minimum,Purchase Price,Selling Price,Wholesale,Manufacturer,Brand,Part Number,Alternative Part Number,Unit,Country,Location,Alternative Names,Description,Specifications'];
    for(final r in rows){lines.add([r['id'],r['sku'],r['name'],r['category'],r['qty'],r['min_qty'],r['buy'],r['sell'],r['wholesale'],r['manufacturer'],r['brand'],r['part_no'],r['alt_part_no'],r['unit'],r['country'],r['location'],r['alt_names'],r['description'],r['specs']].map(cell).join(','));}
    final bytes=Uint8List.fromList(utf8.encode('\uFEFF'+lines.join('\r\n')));
    return FilePicker.platform.saveFile(dialogTitle:'تصدير جرد المنتجات CSV',fileName:'MYAPP_Inventory.csv',type:FileType.custom,allowedExtensions:['csv'],bytes:bytes);
  }
  Future<void> importBackup() async {
    final result=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['json'],withData:true);
    if(result==null||result.files.isEmpty||result.files.first.bytes==null)return;
    final data=jsonDecode(utf8.decode(result.files.first.bytes!)) as Map<String,dynamic>;
    if(data['format']!='MYAPP_BACKUP_1'&&data['format']!='MYAPP_BACKUP_2'&&data['format']!='MYAPP_BACKUP_3')throw Exception('ملف النسخة الاحتياطية غير صالح.');
    final restoredImages=await _restoreImageBlobs(data);
    await database!.transaction((txn) async {
      for(final t in ['party_ledger','warehouse_transfers','warehouse_stock','invoice_payments','invoice_items','invoices','product_images','product_notes','tasks','activity_log','recent_searches','favorites','categories','price_history','stock_adjustments','expenses','operations','products','suppliers','customers','warehouses']){await txn.delete(t);}
      for(final row in data['products'] as List){final product=Map<String,Object?>.from(row as Map);final id=product['id'] as int?;if(id!=null&&restoredImages.containsKey(id))product['image_path']=restoredImages[id];var sku=(product['sku']??'').toString();if(sku.isEmpty||(await txn.query('products',columns:['id'],where:'sku=?',whereArgs:[sku],limit:1)).isNotEmpty){do{sku=_newSku();}while((await txn.query('products',columns:['id'],where:'sku=?',whereArgs:[sku],limit:1)).isNotEmpty);product['sku']=sku;}await txn.insert('products',product);}
      for(final row in data['operations'] as List){final m=Map<String,Object?>.from(row as Map);m.putIfAbsent('cost_price',()=>0.0);m.putIfAbsent('party_id',()=>null);m.putIfAbsent('party_name',()=> '');m.putIfAbsent('warehouse_id',()=>1);await txn.insert('operations',m);}
      for(final table in ['party_ledger','warehouse_stock','warehouse_transfers','suppliers','customers','warehouses','expenses','stock_adjustments','price_history','categories','favorites','recent_searches','activity_log','tasks','product_notes','product_images','invoices','invoice_items','invoice_payments']){for(final row in (data[table] as List? ?? [])){await txn.insert(table,Map<String,Object?>.from(row as Map));}}
      final wh=await txn.rawQuery('SELECT COUNT(*) AS c FROM warehouses');if((wh.first['c'] as int? ?? 0)==0)await txn.insert('warehouses',{'name':'المخزن الرئيسي','location':'','notes':''});
       if(data['warehouse_stock']==null)await txn.execute('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) SELECT id,1,qty FROM products');
       if(data['party_ledger']==null)await _createPartyLedger(txn);
    });
  }
  Future<String> restore() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path,'my_app_backup.json'));
    if (!await file.exists()) throw Exception('لا توجد نسخة احتياطية على الجهاز.');
    final data = jsonDecode(await file.readAsString()) as Map<String,dynamic>;
    if (data['format'] != 'MYAPP_BACKUP_1' && data['format'] != 'MYAPP_BACKUP_2' && data['format'] != 'MYAPP_BACKUP_3') throw Exception('ملف النسخة الاحتياطية غير صالح.');
    final restoredImages=await _restoreImageBlobs(data);
    await database!.transaction((txn) async {
      for(final t in ['party_ledger','warehouse_transfers','warehouse_stock','invoice_payments','invoice_items','invoices','product_images','product_notes','tasks','activity_log','recent_searches','favorites','categories','price_history','stock_adjustments','expenses','operations','products','suppliers','customers','warehouses']) { await txn.delete(t); }
      for (final row in data['products'] as List) {
        final product=Map<String,Object?>.from(row as Map);final id=product['id'] as int?;if(id!=null&&restoredImages.containsKey(id))product['image_path']=restoredImages[id];var sku=(product['sku']??'').toString();if(sku.isEmpty||(await txn.query('products',columns:['id'],where:'sku=?',whereArgs:[sku],limit:1)).isNotEmpty){do{sku=_newSku();}while((await txn.query('products',columns:['id'],where:'sku=?',whereArgs:[sku],limit:1)).isNotEmpty);product['sku']=sku;}await txn.insert('products',product);
      }
      for (final row in data['operations'] as List) {
        final m=Map<String,Object?>.from(row as Map);
        m.putIfAbsent('cost_price',()=>0.0);m.putIfAbsent('party_id',()=>null);m.putIfAbsent('party_name',()=> '');m.putIfAbsent('warehouse_id',()=>1);
        await txn.insert('operations',m);
      }
      for(final table in ['suppliers','customers','warehouses','expenses','stock_adjustments','warehouse_stock','warehouse_transfers','party_ledger','price_history','categories','favorites','recent_searches','activity_log','tasks','product_notes','product_images','invoices','invoice_items','invoice_payments']) {
        for(final row in (data[table] as List? ?? [])) { await txn.insert(table,Map<String,Object?>.from(row as Map)); }
      }
      final wh=await txn.rawQuery('SELECT COUNT(*) AS c FROM warehouses');
      if((wh.first['c'] as int? ?? 0)==0) await txn.insert('warehouses',{'name':'المخزن الرئيسي','location':'','notes':''});
       if(data['warehouse_stock']==null) await txn.execute('INSERT OR IGNORE INTO warehouse_stock(product_id,warehouse_id,qty) SELECT id,1,qty FROM products');
       if(data['party_ledger']==null) await _createPartyLedger(txn);
    });
    return file.path;
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override State<MyApp> createState()=>_MyAppState();
}
class _MyAppState extends State<MyApp> {
  ThemeMode mode = ThemeMode.light;
  Color seedColor = const Color(0xFF087F68);
  String appName = 'MY APP';
  String? logoPath;
  String? backgroundPath;
  @override void initState(){super.initState();load();}
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() { mode = prefs.getBool('dark') == true ? ThemeMode.dark : ThemeMode.light; seedColor = Color(prefs.getInt('seedColor') ?? 0xFF087F68); appName=prefs.getString('appName') ?? 'MY APP'; logoPath=prefs.getString('logoPath'); backgroundPath=prefs.getString('backgroundPath'); });
  }
  Future<void> toggle() async {
    final dark = mode != ThemeMode.dark;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark',dark);
    if (mounted) setState(() => mode = dark ? ThemeMode.dark : ThemeMode.light);
  }
  Future<void> changeSeed(int value) async { final prefs=await SharedPreferences.getInstance(); await prefs.setInt('seedColor',value); if(mounted)setState(()=>seedColor=Color(value)); }
  Future<void> changeAppName(String value) async { final v=value.trim().isEmpty?'MY APP':value.trim(); final prefs=await SharedPreferences.getInstance(); await prefs.setString('appName',v); if(mounted)setState(()=>appName=v); }
  Future<void> changeLogo() async { final picked=await FilePicker.platform.pickFiles(type:FileType.image); if(picked==null||picked.files.isEmpty||picked.files.first.path==null)return; final source=File(picked.files.first.path!); final dir=await getApplicationSupportDirectory(); final ext=p.extension(source.path); final target=File(p.join(dir.path,'my_app_logo'+(ext.isEmpty?'.png':ext))); await source.copy(target.path); final prefs=await SharedPreferences.getInstance(); await prefs.setString('logoPath',target.path); if(mounted)setState(()=>logoPath=target.path); }
  Future<void> changeBackground() async { final picked=await FilePicker.platform.pickFiles(type:FileType.image); if(picked==null||picked.files.isEmpty||picked.files.first.path==null)return; final source=File(picked.files.first.path!); final dir=await getApplicationSupportDirectory(); final ext=p.extension(source.path); final target=File(p.join(dir.path,'my_app_background'+(ext.isEmpty?'.png':ext))); await source.copy(target.path); final prefs=await SharedPreferences.getInstance(); await prefs.setString('backgroundPath',target.path); if(mounted)setState(()=>backgroundPath=target.path); }
  Future<void> clearBackground() async { final prefs=await SharedPreferences.getInstance(); await prefs.remove('backgroundPath'); if(mounted)setState(()=>backgroundPath=null); }
  ThemeData makeTheme(Brightness b)=>ThemeData(
    useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:seedColor,brightness:b),
    scaffoldBackgroundColor:b==Brightness.dark?const Color(0xFF101820):const Color(0xFFF3F6F8),
    cardTheme:CardThemeData(color:b==Brightness.dark?const Color(0xFF192630):Colors.white,elevation:b==Brightness.dark?0:1,margin:const EdgeInsets.symmetric(horizontal:10,vertical:7),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(20),side:BorderSide(color:b==Brightness.dark?const Color(0xFF293A45):const Color(0xFFE8EDF1)))),
    appBarTheme:AppBarTheme(centerTitle:false,elevation:0,scrolledUnderElevation:0,backgroundColor:b==Brightness.dark?const Color(0xFF101820):const Color(0xFFF3F6F8),surfaceTintColor:Colors.transparent,titleTextStyle:TextStyle(fontSize:19,fontWeight:FontWeight.w900,color:b==Brightness.dark?Colors.white:const Color(0xFF17252D))),
    inputDecorationTheme:InputDecorationTheme(filled:true,isDense:true,contentPadding:const EdgeInsets.symmetric(horizontal:14,vertical:13),border:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:BorderSide.none),enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:BorderSide.none),focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:BorderSide(width:1.4,color:seedColor))),
    navigationBarTheme:NavigationBarThemeData(height:70,elevation:0,backgroundColor:b==Brightness.dark?const Color(0xFF17232C):Colors.white,indicatorColor:ColorScheme.fromSeed(seedColor:seedColor,brightness:b).primaryContainer,labelBehavior:NavigationDestinationLabelBehavior.onlyShowSelected),
    dialogTheme:DialogThemeData(shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(24)),elevation:12),
    snackBarTheme:SnackBarThemeData(behavior:SnackBarBehavior.floating,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14))),
    dividerTheme:DividerThemeData(color:b==Brightness.dark?const Color(0xFF293A45):const Color(0xFFE5EBEF)),
    filledButtonTheme:FilledButtonThemeData(style:FilledButton.styleFrom(shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14)),padding:const EdgeInsets.symmetric(horizontal:18,vertical:13))),
    outlinedButtonTheme:OutlinedButtonThemeData(style:OutlinedButton.styleFrom(shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14)),padding:const EdgeInsets.symmetric(horizontal:16,vertical:12)))
  );
  @override Widget build(BuildContext context)=>MaterialApp(debugShowCheckedModeBanner:false,title:appName,
    theme:makeTheme(Brightness.light),darkTheme:makeTheme(Brightness.dark),themeMode:mode,
    home:HomePage(dark:mode==ThemeMode.dark,toggle:toggle,seedColor:seedColor,changeSeed:changeSeed,appName:appName,changeAppName:changeAppName,logoPath:logoPath,changeLogo:changeLogo,backgroundPath:backgroundPath,changeBackground:changeBackground,clearBackground:clearBackground));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key,required this.dark,required this.toggle,required this.seedColor,required this.changeSeed,required this.appName,required this.changeAppName,required this.logoPath,required this.changeLogo,required this.backgroundPath,required this.changeBackground,required this.clearBackground});
  final bool dark; final VoidCallback toggle; final Color seedColor; final ValueChanged<int> changeSeed; final String appName; final ValueChanged<String> changeAppName; final String? logoPath; final VoidCallback changeLogo; final String? backgroundPath; final VoidCallback changeBackground,clearBackground;
  @override State<HomePage> createState()=>_HomePageState();
}
class _HomePageState extends State<HomePage> {
  int tab=10, refreshId=0;
  void refresh()=>setState(()=>refreshId++);
  @override Widget build(BuildContext context) {
    final pages=[
      Dashboard(key:ValueKey('d'+refreshId.toString()),go:(v)=>setState(()=>tab=v),appName:widget.appName),
      ProductsPage(key:ValueKey('p'+refreshId.toString()),changed:refresh),
      MovementPage(key:ValueKey('s'+refreshId.toString()),kind:'sale',changed:refresh),
      MovementPage(key:ValueKey('b'+refreshId.toString()),kind:'purchase',changed:refresh),
      PartyPage(key:ValueKey('sup'+refreshId.toString()),table:'suppliers',title:'الموردون',changed:refresh),
      PartyPage(key:ValueKey('cus'+refreshId.toString()),table:'customers',title:'العملاء',changed:refresh),
      WarehousePage(key:ValueKey('wh'+refreshId.toString()),changed:refresh),
      ExpensePage(key:ValueKey('ex'+refreshId.toString()),changed:refresh),
      ReportsPage(key:ValueKey('r'+refreshId.toString())),
      SettingsPage(dark:widget.dark,toggle:widget.toggle,seedColor:widget.seedColor,changeSeed:widget.changeSeed,appName:widget.appName,changeAppName:widget.changeAppName,logoPath:widget.logoPath,changeLogo:widget.changeLogo,backgroundPath:widget.backgroundPath,changeBackground:widget.changeBackground,clearBackground:widget.clearBackground),
      QuickSearchPage(key:ValueKey('q'+refreshId.toString())),
      CategoriesPage(key:ValueKey('cat'+refreshId.toString())),
      SmartToolsPage(key:ValueKey('tools'+refreshId.toString())),
      const PremiumAssistantPage(),
      InvoicePage(key:ValueKey('inv'+refreshId.toString()),changed:refresh),
      InvoicePage(key:ValueKey('due'+refreshId.toString()),changed:refresh,pendingOnly:true),
      const ScientificCalculatorPage(),
      WarehouseStockPage(key:ValueKey('whstock'+refreshId.toString()),changed:refresh),
      PartyLedgerPage(key:ValueKey('ledger'+refreshId.toString())),
      ShortagesPage(key:ValueKey('shortages'+refreshId.toString())),
    ];
    const labels=['الرئيسية','المنتجات','المبيعات','المشتريات','الموردون','العملاء','المخازن','المصروفات','التقارير','الإعدادات','بحث الأسعار','التصنيفات','الأدوات الذكية','المساعد الذكي','الفواتير','انتظار الدفع','الآلة العلمية','توزيع المخزون','حسابات العملاء والموردين','النواقص'];
    const icons=[Icons.dashboard_outlined,Icons.inventory_2_outlined,Icons.point_of_sale,Icons.shopping_cart_outlined,Icons.local_shipping_outlined,Icons.people_alt_outlined,Icons.warehouse_outlined,Icons.payments_outlined,Icons.analytics_outlined,Icons.settings_outlined,Icons.search,Icons.category_outlined,Icons.auto_awesome,Icons.auto_awesome,Icons.receipt_long,Icons.pending_actions,Icons.calculate_outlined,Icons.swap_horiz,Icons.account_balance_wallet_outlined,Icons.warning_amber_rounded];
    return Directionality(textDirection:TextDirection.rtl,child:Scaffold(
      drawer:Drawer(child:SafeArea(child:Column(children:[
        Container(width:double.infinity,padding:const EdgeInsets.all(22),color:Theme.of(context).colorScheme.primaryContainer,
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            if(widget.logoPath!=null&&File(widget.logoPath!).existsSync()) Padding(padding:const EdgeInsets.only(bottom:8),child:Image.file(File(widget.logoPath!),height:58,fit:BoxFit.contain,errorBuilder:(c,e,st)=>const Icon(Icons.store,size:42))),
            Text(widget.appName,style:const TextStyle(fontSize:25,fontWeight:FontWeight.w900)),
            const Text('نظام إدارة المخزون والمبيعات')
          ])),
        Expanded(child:ListView.builder(itemCount:labels.length,itemBuilder:(c,i)=>ListTile(selected:tab==i,leading:Icon(icons[i]),title:Text(labels[i]),
          onTap:(){Navigator.pop(context);setState(()=>tab=i);}))),
        const Padding(padding:EdgeInsets.all(12),child:Text('يعمل محلياً دون إنترنت',style:TextStyle(fontSize:12)))
      ]))),
      appBar:AppBar(leading:Builder(builder:(c)=>IconButton(icon:const Icon(Icons.menu),onPressed:()=>Scaffold.of(c).openDrawer())),
        title:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(widget.appName,style:const TextStyle(fontWeight:FontWeight.w900)),
        const Text('إدارة المخزون دون إنترنت',style:TextStyle(fontSize:11))]),
        actions:[IconButton(tooltip:'مساعد البرنامج',onPressed:()=>setState(()=>tab=13),icon:const Icon(Icons.support_agent)),const SizedBox(width:6)]),
      body:Stack(children:[
        if(widget.backgroundPath!=null&&File(widget.backgroundPath!).existsSync()) Positioned.fill(child:Image.file(File(widget.backgroundPath!),fit:BoxFit.cover,errorBuilder:(c,e,st)=>const SizedBox.shrink())),
        IndexedStack(index:tab,children:pages)
      ]),
      bottomNavigationBar:NavigationBar(selectedIndex:tab==10?0:tab==1?1:tab==0?2:tab==14?3:tab==8?4:tab==12?5:0,onDestinationSelected:(v)=>setState(()=>tab=[10,1,0,14,8,12][v]),
        destinations:const [
          NavigationDestination(icon:Icon(Icons.search),label:'بحث الأسعار'),
          NavigationDestination(icon:Icon(Icons.inventory_2_outlined),label:'المنتجات'),
          NavigationDestination(icon:Icon(Icons.dashboard_outlined),label:'الرئيسية'),
          NavigationDestination(icon:Icon(Icons.receipt_long_outlined),label:'الفواتير'),
          NavigationDestination(icon:Icon(Icons.analytics_outlined),label:'التقارير'),
          NavigationDestination(icon:Icon(Icons.auto_awesome),label:'الأدوات'),
        ]),
    ));
  }
}


class QuickSearchPage extends StatefulWidget {const QuickSearchPage({super.key});@override State<QuickSearchPage> createState()=>_QuickSearchPageState();}
class _QuickSearchPageState extends State<QuickSearchPage>{
  final controller=TextEditingController();final picker=ImagePicker();List<Map<String,Object?>> rows=[];bool searchingImage=false;
  @override void dispose(){controller.dispose();super.dispose();}
  Future<void> search(String value) async {
    final q=value.trim();
    if(q.isEmpty){if(mounted)setState(()=>rows=[]);return;}
    final r=await StoreDb.instance.products(q);
    if(mounted)setState(()=>rows=r);
  }
  Future<void> imageSearch(ImageSource source) async {
    if(searchingImage)return;
    try{
      setState(()=>searchingImage=true);
      final file=await picker.pickImage(source:source,imageQuality:90,maxWidth:1800,maxHeight:1800);
      if(file==null)return;
      final bytes=await File(file.path).readAsBytes();
      final matches=await StoreDb.instance.similarProducts(bytes);
      if(!mounted)return;
      setState(()=>rows=matches);
      if(matches.isEmpty)toast(context,'مفيش صورة قريبة كفاية في كتالوج منتجاتك. أضف صور واضحة للمنتجات الأول، أو ابحث بالكود/الاسم.');
      else toast(context,'لقيت '+matches.length.toString()+' منتجات محتملة. راجع نسبة التشابه قبل الاختيار.');
    }catch(e){
      if(mounted)toast(context,'تعذر البحث بالصورة: '+e.toString().replaceFirst('Exception: ',''));
    }finally{if(mounted)setState(()=>searchingImage=false);}
  }
  Future<void> _acceptScannedCode(String value) async {
    final code=value.trim();
    if(code.isEmpty)return;
    controller.text=code;
    await search(code);
    if(!mounted)return;
    if(rows.isEmpty)toast(context,'الكود اتقري بنجاح، لكن مفيش منتج مسجل بنفس الكود: '+code);
  }
  Future<void> scanImageCode() async {
    if(!Platform.isAndroid&&!Platform.isIOS){toast(context,'قراءة الأكواد من الصور متاحة على Android وiPhone فقط.');return;}
    try{
      final file=await picker.pickImage(source:ImageSource.gallery,imageQuality:100);
      if(file==null)return;
      final scanner=MobileScannerController(formats:const [BarcodeFormat.qrCode,BarcodeFormat.ean8,BarcodeFormat.ean13,BarcodeFormat.upcA,BarcodeFormat.upcE,BarcodeFormat.code128,BarcodeFormat.code39,BarcodeFormat.code93,BarcodeFormat.itf,BarcodeFormat.dataMatrix,BarcodeFormat.pdf417]);
      try{
        final capture=await scanner.analyzeImage(file.path);
        final value=capture?.barcodes.map((b)=>b.rawValue).firstWhere((v)=>v!=null&&v.trim().isNotEmpty,orElse:()=>null);
        if(value==null){if(mounted)toast(context,'الصورة دي مفيهاش QR أو باركود واضح. جرّب صورة أقرب وأوضح.');return;}
        await _acceptScannedCode(value);
      }finally{await scanner.dispose();}
    }catch(e){if(mounted)toast(context,'فشل قراءة الكود من الصورة: '+e.toString().replaceFirst('Exception: ',''));}
  }
  Future<void> scanCode() async {
    if(!Platform.isAndroid&&!Platform.isIOS){toast(context,'مسح الكاميرا المباشر متاح على Android وiPhone فقط. استخدم البحث بالكود على الكمبيوتر.');return;}
    final scanner=MobileScannerController(
      detectionSpeed:DetectionSpeed.noDuplicates,
      returnImage:false,
      formats:const [BarcodeFormat.qrCode,BarcodeFormat.ean8,BarcodeFormat.ean13,BarcodeFormat.upcA,BarcodeFormat.upcE,BarcodeFormat.code128,BarcodeFormat.code39,BarcodeFormat.code93,BarcodeFormat.itf,BarcodeFormat.dataMatrix,BarcodeFormat.pdf417],
    );
    var captured=false;
    try {
      await showDialog(context:context,builder:(ctx)=>Dialog(child:SizedBox(width:360,height:490,child:Column(children:[
        const Padding(padding:EdgeInsets.all(12),child:Text('وجّه الكاميرا ناحية QR أو الباركود وخليه داخل الإطار')),
        Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(14),child:MobileScanner(
          controller:scanner,
          onDetect:(capture) async {
            if(captured)return;
            final value=capture.barcodes.map((b)=>b.rawValue).firstWhere((v)=>v!=null&&v.trim().isNotEmpty,orElse:()=>null);
            if(value==null)return;
            captured=true;
            try{await scanner.stop();}catch(_){}
            if(ctx.mounted)Navigator.of(ctx).pop();
            if(mounted)await _acceptScannedCode(value);
          },
        ))),
        TextButton(onPressed:()=>Navigator.of(ctx).pop(),child:const Text('إغلاق'))
      ]))));
    }catch(e){if(mounted)toast(context,'مش قادر أشغل الكاميرا. راجع إذن الكاميرا واقفل أي تطبيق بيستخدمها. التفاصيل: '+e.toString());}
    finally{await scanner.dispose();}
  }
  Future<void> addProductNote(Map<String,Object?> p) async {final title=TextEditingController();final body=TextEditingController();final ok=await showDialog<bool>(context:context,builder:(ctx)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:const Text('ملاحظة للمنتج'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:title,decoration:const InputDecoration(labelText:'عنوان الملاحظة')),TextField(controller:body,maxLines:4,decoration:const InputDecoration(labelText:'التفاصيل'))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,title.text.trim().isNotEmpty||body.text.trim().isNotEmpty),child:const Text('حفظ'))])));if(ok==true){await StoreDb.instance.saveProductNote(p['id'] as int,title.text.trim(),body.text.trim());if(mounted)toast(context,'تم حفظ الملاحظة محليًا.');}title.dispose();body.dispose();}
  Future<void> viewProductNotes(Map<String,Object?> p) async {
    final rows=await StoreDb.instance.productNotes(p['id'] as int);if(!mounted)return;
    showDialog(context:context,builder:(ctx)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(
      title:Text('ملاحظات '+p['name'].toString()),
      content:SizedBox(width:380,height:300,child:rows.isEmpty?const Center(child:Text('لا توجد ملاحظات.')):ListView(children:rows.map((e)=>ListTile(
        title:Text(e['title'].toString()),subtitle:Text(e['body'].toString()+'\\n'+e['created_at'].toString()),
        trailing:IconButton(tooltip:'حذف الملاحظة',icon:const Icon(Icons.delete_outline),onPressed:()async{
          if(await ask(ctx,'حذف الملاحظة','هل تريد حذف هذه الملاحظة؟')==true){await StoreDb.instance.deleteProductNote(e['id'] as int);if(ctx.mounted)Navigator.pop(ctx);await viewProductNotes(p);}
        })
      )).toList())),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إغلاق'))]
    )));
  }
  void details(Map<String,Object?> p) {
    showModalBottomSheet(context:context,isScrollControlled:true,builder:(ctx)=>Directionality(textDirection:TextDirection.rtl,child:Padding(padding:const EdgeInsets.all(18),child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      if((p['image_path']??'').toString().isNotEmpty&&File(p['image_path'] as String).existsSync())ClipRRect(borderRadius:BorderRadius.circular(14),child:Image.file(File(p['image_path'] as String),height:170,fit:BoxFit.contain)),
      Text(p['name'].toString(),style:const TextStyle(fontSize:22,fontWeight:FontWeight.bold)),
      Text('الكود: '+p['sku'].toString()),
      const SizedBox(height:8),Text(money(p['sell']),style:TextStyle(fontSize:34,fontWeight:FontWeight.w900,color:Theme.of(ctx).colorScheme.primary)),
      Text('الشراء: '+money(p['buy'])+' • الجملة: '+money(p['wholesale'])),
      Text('المتاح: '+p['qty'].toString()+' '+p['unit'].toString()+' • '+p['category'].toString()),
      Text('الشركة: '+(p['manufacturer']??'').toString()+' • الماركة: '+(p['brand']??'').toString()),
      Text('رقم القطعة: '+(p['part_no']??'').toString()+' • البديل: '+(p['alt_part_no']??'').toString()),
      Text('الموقع: '+(p['location']??'').toString()),
      Wrap(spacing:8,children:[
        OutlinedButton.icon(onPressed:(){Clipboard.setData(ClipboardData(text:p['sku'].toString()));toast(ctx,'تم نسخ الكود');},icon:const Icon(Icons.copy),label:const Text('نسخ الكود')),
        FilledButton.icon(onPressed:(){Clipboard.setData(ClipboardData(text:money(p['sell'])));toast(ctx,'تم نسخ السعر');},icon:const Icon(Icons.price_check),label:const Text('نسخ السعر')),
        OutlinedButton.icon(onPressed:()=>showQr(ctx,p['sku'].toString(),p['name'].toString()),icon:const Icon(Icons.qr_code),label:const Text('QR')),
        OutlinedButton.icon(onPressed:()=>addProductNote(p),icon:const Icon(Icons.note_add),label:const Text('إضافة ملاحظة')),
        OutlinedButton.icon(onPressed:()=>viewProductNotes(p),icon:const Icon(Icons.notes),label:const Text('عرض الملاحظات'))
      ])
    ])))));
  }
  @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(14),children:[
    Card(color:Theme.of(context).colorScheme.primaryContainer,child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('بحث الأسعار السريع',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),
      const Text('ابحث بالاسم أو الكود أو رقم القطعة'),
      const SizedBox(height:12),
      TextField(controller:controller,onChanged:search,onSubmitted:(v)=>StoreDb.instance.saveSearch(v),autofocus:false,decoration:InputDecoration(filled:true,hintText:'اكتب اسم المنتج أو الكود...',prefixIcon:const Icon(Icons.search),suffixIcon:IconButton(onPressed:(){controller.clear();search('');},icon:const Icon(Icons.close)),border:OutlineInputBorder(borderRadius:BorderRadius.circular(16)))),
      const SizedBox(height:8),
      Wrap(spacing:8,children:[
        OutlinedButton.icon(onPressed:scanCode,icon:const Icon(Icons.qr_code_scanner),label:const Text('مسح بالكاميرا')),
        OutlinedButton.icon(onPressed:scanImageCode,icon:const Icon(Icons.document_scanner_outlined),label:const Text('قراءة كود من صورة')),
        OutlinedButton.icon(onPressed:()=>imageSearch(ImageSource.gallery),icon:const Icon(Icons.image_search),label:const Text('بحث بصورة')),
        OutlinedButton.icon(onPressed:()=>imageSearch(ImageSource.camera),icon:const Icon(Icons.camera_alt),label:const Text('تصوير')),
      ]),
      if(searchingImage)const LinearProgressIndicator(),
      const Padding(padding:EdgeInsets.only(top:6),child:Text('البحث بالصورة يقارن بصور المنتجات المحفوظة داخل جهازك، ولا يبحث تلقائياً في الإنترنت.',style:TextStyle(fontSize:11,color:Colors.grey)))
    ]))),
    if(rows.isEmpty)const Padding(padding:EdgeInsets.all(28),child:Center(child:Text('ابدأ بكتابة اسم المنتج أو كوده للعثور على سعره.')))
    else ...rows.map((p)=>Card(child:ListTile(onTap:()=>details(p),leading:(p['image_path']??'').toString().isNotEmpty&&File(p['image_path'] as String).existsSync()?ClipRRect(borderRadius:BorderRadius.circular(8),child:Image.file(File(p['image_path'] as String),width:54,height:54,fit:BoxFit.cover)):const CircleAvatar(child:Icon(Icons.inventory_2)),title:Text(p['name'].toString(),style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('الكود: '+p['sku'].toString()+' • المتاح: '+p['qty'].toString()),trailing:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.end,mainAxisAlignment:MainAxisAlignment.center,children:[Text(money(p['sell']),style:const TextStyle(fontWeight:FontWeight.w900,fontSize:16)),if(p['similarity']!=null)Text('تشابه '+(((p['similarity'] as num).toDouble()*100).round()).toString()+'%',style:const TextStyle(fontSize:10,color:Colors.grey))])))),
  ]);
}


Future<void> printProductLabel(BuildContext context,String code,String name) async {
  try {
    final recorder=ui.PictureRecorder();final canvas=ui.Canvas(recorder);
    canvas.drawRect(const ui.Rect.fromLTWH(0,0,900,180),ui.Paint()..color=const ui.Color(0xFFFFFFFF));
    final painter=TextPainter(text:TextSpan(text:name,style:const TextStyle(fontSize:54,fontWeight:FontWeight.bold,color:Color(0xFF111111))),textDirection:TextDirection.rtl,textAlign:TextAlign.center,maxLines:2);
    painter.layout(maxWidth:860);painter.paint(canvas,Offset((900-painter.width)/2,20));
    final image=await recorder.endRecording().toImage(900,180);final data=await image.toByteData(format:ui.ImageByteFormat.png);image.dispose();
    final doc=pw.Document();
    doc.addPage(pw.Page(pageFormat:const pdf.PdfPageFormat(80*pdf.PdfPageFormat.mm,60*pdf.PdfPageFormat.mm),margin:const pw.EdgeInsets.all(5),build:(_)=>pw.Column(mainAxisAlignment:pw.MainAxisAlignment.center,children:[
      if(data!=null)pw.Image(pw.MemoryImage(data.buffer.asUint8List()),height:22*pdf.PdfPageFormat.mm,fit:pw.BoxFit.contain),
      pw.BarcodeWidget(barcode:pw.Barcode.qrCode(),data:code,width:28*pdf.PdfPageFormat.mm,height:28*pdf.PdfPageFormat.mm),
      pw.Text(code,style:pw.TextStyle(fontSize:12,fontWeight:pw.FontWeight.bold))
    ])));
    await Printing.layoutPdf(name:'Product_Label_$code.pdf',onLayout:(_)=>doc.save());
  }catch(e){if(context.mounted)toast(context,'تعذرت طباعة الملصق: $e');}
}

void showQr(BuildContext context,String code,String name){
  showDialog(context:context,builder:(c)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:Text('رمز المنتج: '+name),content:SizedBox(width:230,height:260,child:Column(children:[QrImageView(data:code,size:190),Text(code,style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold))])),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إغلاق')),FilledButton.icon(onPressed:()=>printProductLabel(context,code,name),icon:const Icon(Icons.print),label:const Text('طباعة ملصق'))])));
}

class CategoriesPage extends StatefulWidget {const CategoriesPage({super.key});@override State<CategoriesPage> createState()=>_CategoriesPageState();}
class _CategoriesPageState extends State<CategoriesPage>{
 List<Map<String,Object?>> rows=[];@override void initState(){super.initState();load();}
 Future<void> load()async{final r=await StoreDb.instance.categories();if(mounted)setState(()=>rows=r);}
 Future<void> edit([Map<String,Object?>? e])async{final name=TextEditingController(text:e?['name'] as String? ?? '');final desc=TextEditingController(text:e?['description'] as String? ?? '');final ok=await showDialog<bool>(context:context,builder:(c)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:Text(e==null?'تصنيف جديد':'تعديل التصنيف'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:name,decoration:const InputDecoration(labelText:'اسم التصنيف')),TextField(controller:desc,decoration:const InputDecoration(labelText:'الوصف'))]),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(c,name.text.trim().isNotEmpty),child:const Text('حفظ'))])));if(ok==true){await StoreDb.instance.saveCategory({'name':name.text.trim(),'description':desc.text.trim(),'color':0,'parent_id':null},e?['id'] as int?);await load();}name.dispose();desc.dispose();}
 @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(12),children:[Row(children:[const Expanded(child:Text('تصنيفات الأصناف',style:TextStyle(fontSize:21,fontWeight:FontWeight.bold))),IconButton.filled(onPressed:()=>edit(),icon:const Icon(Icons.add))]),if(rows.isEmpty)const Text('لم تتم إضافة تصنيفات بعد.')else ...rows.map((e)=>Card(child:ListTile(leading:const Icon(Icons.category_outlined),title:Text(e['name'].toString()),subtitle:Text(e['description'].toString()),trailing:PopupMenuButton<String>(onSelected:(v)async{if(v=='edit'){await edit(e);}else if(await ask(context,'حذف التصنيف','حذف التصنيف؟')==true){await StoreDb.instance.deleteCategory(e['id'] as int);await load();}},itemBuilder:(_)=>const [PopupMenuItem(value:'edit',child:Text('تعديل')),PopupMenuItem(value:'delete',child:Text('حذف'))]))))]);}
 
class SimpleCalculator {
  static double evaluate(String expression){
    final parser=_ExpressionParser(expression.replaceAll('×','*').replaceAll('÷','/').replaceAll('−','-').replaceAll('٫','.'));
    final value=parser.parse();
    if(!value.isFinite)throw const FormatException('الناتج غير صالح.');
    return value;
  }
}
class _ExpressionParser {
  _ExpressionParser(this.source);
  final String source;int index=0;
  void spaces(){while(index<source.length&&source[index].trim().isEmpty)index++;}
  bool take(String c){spaces();if(index<source.length&&source[index]==c){index++;return true;}return false;}
  double parse(){final v=expression();spaces();if(index!=source.length)throw const FormatException('راجع صيغة العملية الحسابية.');return v;}
  double expression(){var v=term();while(true){if(take('+'))v+=term();else if(take('-'))v-=term();else return v;}}
  double term(){var v=factor();while(true){if(take('*'))v*=factor();else if(take('/')){final d=factor();if(d==0)throw const FormatException('مينفعش القسمة على صفر.');v/=d;}else if(take('%')){final d=factor();if(d==0)throw const FormatException('مينفعش باقي القسمة على صفر.');v%=d;}else return v;}}
  double factor(){spaces();if(take('+'))return factor();if(take('-'))return -factor();if(take('(')){final v=expression();if(!take(')'))throw const FormatException('في قوس ناقص.');return v;}final m=RegExp(r'^\d+(?:\.\d+)?|^\.\d+').firstMatch(source.substring(index));if(m==null)throw const FormatException('اكتب أرقام وعلامات حسابية صحيحة.');index+=m.group(0)!.length;return double.parse(m.group(0)!);}
}

class SmartToolsPage extends StatefulWidget {const SmartToolsPage({super.key});@override State<SmartToolsPage> createState()=>_SmartToolsPageState();}
class _SmartToolsPageState extends State<SmartToolsPage>{
 int section=0;List<Map<String,Object?>> rows=[];final task=TextEditingController();final bulkValue=TextEditingController();final calculator=TextEditingController();bool bulkPercent=true;String calculatorResult='الناتج هيظهر هنا';
 @override void initState(){super.initState();load();}@override void dispose(){task.dispose();bulkValue.dispose();calculator.dispose();super.dispose();}
 Future<void> load()async{List<Map<String,Object?>> r=[];if(section==0)r=await StoreDb.instance.favoriteProducts();if(section==1)r=await StoreDb.instance.tasks();if(section==2)r=await StoreDb.instance.activity();if(section==3)r=await StoreDb.instance.recentSearches();if(section==4)r=await StoreDb.instance.archivedProducts();if(section==5)r=await StoreDb.instance.productsWithoutImages();if(section==6)r=await StoreDb.instance.productsWithoutPrices();if(section==7)r=await StoreDb.instance.possibleDuplicates();if(mounted)setState(()=>rows=r);}
 @override Widget build(BuildContext context)=>Column(children:[
  Padding(padding:const EdgeInsets.all(10),child:Wrap(spacing:6,children:[ChoiceChip(label:const Text('المفضلة'),selected:section==0,onSelected:(_){setState(()=>section=0);load();}),ChoiceChip(label:const Text('المهام'),selected:section==1,onSelected:(_){setState(()=>section=1);load();}),ChoiceChip(label:const Text('النشاط'),selected:section==2,onSelected:(_){setState(()=>section=2);load();}),ChoiceChip(label:const Text('عمليات البحث'),selected:section==3,onSelected:(_){setState(()=>section=3);load();}),ChoiceChip(label:const Text('الأرشيف'),selected:section==4,onSelected:(_){setState(()=>section=4);load();}),ChoiceChip(label:const Text('بدون صور'),selected:section==5,onSelected:(_){setState(()=>section=5);load();}),ChoiceChip(label:const Text('بدون سعر'),selected:section==6,onSelected:(_){setState(()=>section=6);load();}),ChoiceChip(label:const Text('التكرارات'),selected:section==7,onSelected:(_){setState(()=>section=7);load();}),ChoiceChip(label:const Text('تعديل أسعار جماعي'),selected:section==8,onSelected:(_){setState(()=>section=8);load();}),ChoiceChip(label:const Text('آلة حاسبة'),selected:section==9,onSelected:(_){setState(()=>section=9);load();})])),
  if(section==1)Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Row(children:[Expanded(child:TextField(controller:task,decoration:const InputDecoration(hintText:'مهمة جديدة'))),IconButton.filled(onPressed:()async{await StoreDb.instance.saveTask(task.text);task.clear();await load();},icon:const Icon(Icons.add))])),
  Expanded(child:section==9?ListView(padding:const EdgeInsets.all(14),children:[const Text('آلة حاسبة سريعة',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),const Text('عمليات الجمع والطرح والضرب والقسمة وباقي القسمة والأقواس.'),TextField(controller:calculator,keyboardType:const TextInputType.numberWithOptions(decimal:true,signed:true),decoration:const InputDecoration(labelText:'اكتب العملية',hintText:'مثال: (125 * 3) + 40 / 2')),const SizedBox(height:10),FilledButton.icon(onPressed:(){try{final result=SimpleCalculator.evaluate(calculator.text);setState(()=>calculatorResult=result.toStringAsFixed(2));}catch(e){setState(()=>calculatorResult=e.toString().replaceFirst('FormatException: ',''));}},icon:const Icon(Icons.calculate_outlined),label:const Text('احسب')),Card(child:ListTile(title:const Text('النتيجة'),trailing:Text(calculatorResult,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:18)))),TextButton.icon(onPressed:(){calculator.clear();setState(()=>calculatorResult='الناتج هيظهر هنا');},icon:const Icon(Icons.backspace_outlined),label:const Text('مسح'))]):section==8?ListView(padding:const EdgeInsets.all(14),children:[const Text('تعديل سعر البيع لمجموعة المنتجات',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),const SizedBox(height:12),SegmentedButton<bool>(segments:const [ButtonSegment(value:true,label:Text('نسبة مئوية')),ButtonSegment(value:false,label:Text('مبلغ ثابت'))],selected:{bulkPercent},onSelectionChanged:(v)=>setState(()=>bulkPercent=v.first)),TextField(controller:bulkValue,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'قيمة الزيادة',hintText:'مثال: 5')),const SizedBox(height:12),FilledButton.icon(onPressed:()async{final v=double.tryParse(bulkValue.text);if(v==null||v<0){toast(context,'أدخل قيمة صحيحة.');return;}await StoreDb.instance.bulkAdjustSellingPrices(v,bulkPercent,'تعديل جماعي من الأدوات');bulkValue.clear();toast(context,'تم تحديث الأسعار وتسجيل السعر السابق لكل منتج.');await load();},icon:const Icon(Icons.price_change),label:const Text('تطبيق على جميع المنتجات'))]):rows.isEmpty?const Center(child:Text('لا توجد بيانات هنا بعد.')):ListView.builder(itemCount:rows.length,itemBuilder:(c,i){final e=rows[i];if(section==0)return Card(child:ListTile(title:Text(e['name'].toString()),subtitle:Text('الكود: '+e['sku'].toString()+' • '+money(e['sell'])),trailing:IconButton(tooltip:'إزالة من المفضلة',icon:const Icon(Icons.star_outline),onPressed:()async{await StoreDb.instance.toggleFavorite(e['id'] as int,false);await load();})));if(section==1)return Card(child:ListTile(leading:Checkbox(value:e['done']==1,onChanged:(v)async{await StoreDb.instance.toggleTask(e['id'] as int,v==true);await load();}),title:Text(e['title'].toString()),trailing:IconButton(tooltip:'حذف المهمة',icon:const Icon(Icons.delete_outline),onPressed:()async{if(await ask(context,'حذف المهمة','هل تريد حذف هذه المهمة؟')==true){await StoreDb.instance.deleteTask(e['id'] as int);await load();}})));if(section==2)return ListTile(leading:const Icon(Icons.history),title:Text(e['action'].toString()),subtitle:Text(e['details'].toString()),trailing:IconButton(tooltip:'حذف السجل',icon:const Icon(Icons.delete_outline),onPressed:()async{if(await ask(context,'حذف السجل','حذف هذا السجل؟')==true){await StoreDb.instance.deleteActivity(e['id'] as int);await load();}}));if(section==3)return ListTile(leading:const Icon(Icons.search),title:Text(e['query'].toString()),subtitle:Text((e['created_at']??'').toString()),trailing:IconButton(tooltip:'حذف البحث',icon:const Icon(Icons.delete_outline),onPressed:()async{await StoreDb.instance.deleteRecentSearch(e['id'] as int);await load();}));if(section==7)return ListTile(leading:const Icon(Icons.copy_all),title:Text(e['name'].toString()),trailing:Text('عدد النسخ: '+e['amount'].toString()));return ListTile(leading:Icon(section==4?Icons.archive:section==5?Icons.image_not_supported:Icons.price_change),title:Text(e['name'].toString()),subtitle:Text('الكود: '+(e['sku']??'').toString()+' • السعر: '+money(e['sell'])),trailing:section==4?IconButton(tooltip:'استعادة',icon:const Icon(Icons.unarchive),onPressed:()async{await StoreDb.instance.setArchived(e['id'] as int,false);await load();}):null);}))
 ]);
}

class AssistantPage extends StatefulWidget {
  const AssistantPage({super.key,required this.changed,required this.go});
  final VoidCallback changed;
  final ValueChanged<int> go;
  @override State<AssistantPage> createState()=>_AssistantPageState();
}
class _AssistantPageState extends State<AssistantPage> {
  final input=TextEditingController();
  List<Map<String,Object?>> results=[];
  bool busy=false;
  String reply='أنا مساعد MY APP. اسألني عن أي صفحة أو اطلب تنفيذ مهمة داخل البرنامج.';
  @override void dispose(){input.dispose();super.dispose();}
  String understand(String raw){
    var v=raw.trim().replaceAll(RegExp(r'[؟?!،,.]+$'),'').replaceAll(RegExp(r'\s+'),' ');
    final low=v.toLowerCase();
    if(RegExp(r'^(اهلا|أهلا|السلام عليكم|وعليكم السلام|صباح الخير|صباح النور|مساء الخير|مساء النور|هاي|هلو|ازيك|إزيك|عامل ايه|عامل إيه|عامل ايه يا|اخبارك|أخبارك|يا شات|يا شاتو)').hasMatch(low))return 'تحية';
    v=v.replaceFirst(RegExp(r'^(يا مساعد|يا شات|ممكن|لو سمحت|من فضلك|بعد اذنك|بعد إذنك)\s*'),'');
    v=v.replaceFirst(RegExp(r'^(عايز|عاوز|محتاج)\s+(افتح|أفتح|اشوف|أشوف|اعرض|وريني|تفتحلي|تفتح لي)'),'افتح');
    v=v.replaceFirst(RegExp(r'^(عايزك|عاوزك|ممكن)\s+(تشرحلي|تشرح|تفهمني)\s*'),'اشرح ');
    v=v.replaceFirst(RegExp(r'^(ضيفلي|زودلي|ضيف|اضيف|أضيف)\s+'),'ضيف ');
    v=v.replaceFirst(RegExp(r'^(سجللي|سجلي|اعمللي|اعملي)\s+'),'سجل ');
    v=v.replaceAll('الاصناف','المنتجات').replaceAll('الأصناف','المنتجات').replaceAll('الصنف','المنتج').replaceAll('البضاعة','المنتجات').replaceAll('الحاجات','المنتجات').replaceAll('الكام','الكمية').replaceAll('بكام','السعر كم').replaceAll('الفلوس','المبلغ').replaceAll('المخزنات','المخازن');
    return v.trim();
  }
  String clean(String value)=>value
    .replaceFirst(RegExp(r'^(يا مساعد|مساعد|ابحثلي عن|ابحث عن|ابحث|دور على|دورلي على|دور|هات|فين|عايز|عاوز|من فضلك)\s*'),'')
    .replaceFirst(RegExp(r'^(اسم مشابه|اسم شبيه|منتج مشابه|شبيه بـ|مشابه لـ|منتج اسمه|الصنف اسمه|منتج)\s*(?:لـ|ل)?'),'').trim();
  String textField(String command,String key) {
    final stop=r'(?:كمية|شراء|بيع|سعر|مبلغ|تصنيف|ماركة|شركة|رقم القطعة|البديل|مكان التخزين|وحدة|بلد المنشأ|أسماء بديلة|مواصفات|متوافق مع|الأبعاد|وزن|إلى|الى|سبب)';
    final pattern=RegExp(RegExp.escape(key)+r'\s*[:=]?\s*(.*?)(?=\s+'+stop+r'\s*|$)',caseSensitive:false);
    return pattern.firstMatch(command)?.group(1)?.trim()??'';
  }
  String numberField(String command,String key) {
    final pattern=RegExp(RegExp.escape(key)+r'\s*[:=]?\s*([0-9]+(?:[.,][0-9]+)?)',caseSensitive:false);
    return pattern.firstMatch(command)?.group(1)?.replaceAll(',','.')??'';
  }
  Future<bool> confirm(String title,String message) async => await ask(context,title,message)==true;
  Future<void> showProduct(Map<String,Object?> e) async {
    if(!mounted)return;
    await showDialog(context:context,builder:(ctx)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(
      title:Text((e['name']??'').toString()),
      content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('الكود: '+(e['sku']??'').toString()),Text('الكمية: '+(e['qty']??0).toString()+' '+(e['unit']??'').toString()),
        Text('سعر الشراء: '+money(e['buy'])),Text('سعر البيع: '+money(e['sell'])),
        Text('التصنيف: '+(e['category']??'').toString()),Text('الماركة: '+(e['brand']??'').toString()),
        Text('رقم القطعة: '+(e['part_no']??'').toString()),Text('الأسماء البديلة: '+(e['alt_names']??'').toString()),
        Text('المواصفات: '+(e['specs']??'').toString()),
      ])),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إغلاق')),
        FilledButton(onPressed:()async{Navigator.pop(ctx);final saved=await showDialog<bool>(context:context,builder:(_)=>ProductDialog(item:e));if(saved==true)widget.changed();},child:const Text('تعديل المنتج')),
      ]
    )));
  }
  String? chatAnswer(String q){
    final v=q.toLowerCase();
    if(q=='تحية')return 'أهلاً بيك يا صاحبي! عامل إيه؟ 😄 قولّي محتاج تعمل إيه في البرنامج وأنا أساعدك خطوة بخطوة.';
    if(RegExp(r'^(شكرا|شكراً|تسلم|حبيبي|كتر خيرك|تمام يا|جامد)').hasMatch(v))return 'تحت أمرك! لو في حاجة تانية في البرنامج قولّي عليها.';
    if(RegExp(r'^(مين انت|انت مين|من انت|عرفني بنفسك)').hasMatch(v))return 'أنا مساعد MY APP المحلي. أقدر أشرحلك البرنامج، أبحث في منتجاتك، أفتح الصفحات، وأساعدك في عمليات المخزون بعد ما أراجع التفاصيل وأخد موافقتك. شغلي الحالي بدون إنترنت، فمش نموذج ذكاء اصطناعي سحابي ولا عندي بحث مباشر في الويب.';
    if(RegExp(r'^(عامل ايه|عامل إيه|ازيك|إزيك)').hasMatch(v))return 'زي الفل وجاهز أساعدك 😄 إنت محتاج إيه النهارده؟';
    if(RegExp(r'^(احسب|احسبلي|حاسبة)\s*').hasMatch(v)){final expression=q.replaceFirst(RegExp(r'^(احسب|احسبلي|حاسبة)\s*'),'');try{return 'الناتج: '+SimpleCalculator.evaluate(expression).toStringAsFixed(2);}catch(e){return 'مش قادر أحسبها بالشكل ده. اكتب العملية بأرقام وعلامات زي: احسب (20*5)+10';}}
    return null;
  }
  String? helpAnswer(String q) {
    final v=q.toLowerCase();
    if(RegExp(r'(مساعدة|بتعمل ايه|تقدر تعمل|اوامر|أوامر|شرح البرنامج|اشرح البرنامج)').hasMatch(v))return 'أقدر أشرح صفحات البرنامج، أفتح لك الصفحة المطلوبة، أبحث عن المنتجات، أضيف منتجًا أو مهمة أو مصروفًا، أسجل بيعًا أو شراءً، أعدّل كمية أو سعرًا، وأؤرشف منتجًا. قبل أي إضافة أو حركة مالية أو تعديل مؤثر أعرض عليك التفاصيل وأطلب موافقتك. اكتب: أمثلة للأوامر.';
    if(v.contains('أمثلة')||v.contains('امثلة'))return 'جرّب: افتح التقارير • اشرح المخازن • ابحث عن فلتر تويوتا • ضيف مهمة مراجعة المخزون • ضيف مصروف نقل مبلغ 150 تصنيف تشغيل • سجل بيع فلتر زيت كمية 2 سعر 80 • عدل كمية فلتر الزيت إلى 10 • غير سعر بيع فلتر الزيت إلى 95.';
    if(v.contains('المنتج')||v.contains('الأصناف')||v.contains('الاصناف'))return 'صفحة المنتجات هي سجل الأصناف. تقدر تحفظ الاسم والتصنيف والكود والكمية وحد التنبيه وسعر الشراء والبيع والجملة والشركة والماركة وأرقام القطع والموقع والوحدة والمنشأ والأسماء البديلة والمواصفات والموديلات المتوافقة والأبعاد والوزن والمورد والصورة. الكود يتولد تلقائيًا لو تركته فارغًا.';
    if(v.contains('البيع')||v.contains('مبيعات'))return 'صفحة المبيعات تسجل خروج الكمية من المخزون. اختر المنتج والكمية وسعر الوحدة والعميل والملاحظات. البرنامج يمنع بيع كمية أكبر من المتاح، ويسجل الحركة في التقارير.';
    if(v.contains('الشراء')||v.contains('مشتريات'))return 'صفحة المشتريات تسجل دخول الكمية للمخزون. اختر المنتج والكمية وسعر الوحدة والمورد. الكمية تزيد وتُسجل الحركة في سجل المشتريات.';
    if(v.contains('المورد'))return 'صفحة الموردين تحفظ بيانات الموردين وتربط المورد بالمنتجات وبحركات الشراء. بيانات الطرف لا تعني وجود دفتر حسابات تفصيلي كامل.';
    if(v.contains('العميل'))return 'صفحة العملاء تحفظ بيانات العملاء وتتيح ربط العميل بحركات البيع.';
    if(v.contains('المخزن')||v.contains('المخازن'))return 'تقدر تدير أسماء المخازن، وتشوف رصيد كل منتج في المخزن المختار، وتحول الكميات بين المخازن من صفحة توزيع المخزون. تسجيل البيع والشراء الحالي مرتبط بالمخزن الرئيسي افتراضياً.';
    if(v.contains('المصروف'))return 'صفحة المصروفات تحفظ البيان والتصنيف والمبلغ والملاحظات، وتدخل المصروفات في ملخص صافي الربح والتدفق النقدي.';
    if(v.contains('التقرير')||v.contains('الأرباح')||v.contains('الربح'))return 'التقارير تعرض قيمة المخزون بسعر الشراء والبيع وإجمالي المبيعات والمشتريات والمصروفات والربح التقديري. الأرقام ملخصة وليست نظام محاسبة ضريبية أو دفتر أستاذ متكامل.';
    if(v.contains('النسخ')||v.contains('الاحتياطي')||v.contains('استعادة'))return 'من الإعدادات يمكنك إنشاء نسخة احتياطية JSON واستعادة البيانات. الاستعادة تستبدل البيانات الحالية؛ خذ نسخة احتياطية حديثة قبلها. كما يمكن استيراد وتصدير CSV للأصناف.';
    if(v.contains('qr')||v.contains('باركود')||v.contains('الكود'))return 'يمكن إنشاء وطباعة ملصق للمنتج يحتوي اسمه وكوده وQR. قارئ الكاميرا يقرأ QR والباركود على الأجهزة المدعومة. لو الكاميرا لم تعمل، راجع إذن الكاميرا واستخدم البحث بالكود.';
    if(v.contains('الانترنت')||v.contains('إنترنت')||v.contains('اوفلاين')||v.contains('دون اتصال'))return 'قاعدة البيانات والبحث والعمليات الأساسية محلية على الجهاز، لذلك لا تحتاج إنترنت بعد التثبيت. لا يوجد تزامن تلقائي بين جهازين؛ استخدم النسخ الاحتياطي لنقل البيانات.';
    if(v.contains('الطباعة'))return 'يمكن طباعة تقارير المخزون وحركات البيع والشراء والتقارير المالية وقوائم العملاء والموردين والمخازن والمصروفات وملصق المنتج، حسب دعم الجهاز والطابعة.';
    if(v.contains('الإعدادات')||v.contains('الاعدادات'))return 'الإعدادات تسمح بتغيير اسم النشاط وشعاره والعملة والخلفية والوضع الليلي ومظهر الألوان، مع خيارات النسخ الاحتياطي والاستعادة.';
    if(v.contains('خارج')||v.contains('معلومة عامة')||v.contains('سؤال عام'))return 'أقدر أجاوب على شوية معلومات عامة ثابتة ومختصرة من الردود المدمجة، لكن النسخة دي محلية ومش متصلة بنموذج ذكاء اصطناعي أو محرك بحث. مش هقدر أضمن إجابة صحيحة لأي سؤال خارجي أو أستخرج تفاصيل منتج من صورة من الإنترنت. لو عايز تحليل صور ومنتجات ومعلومات حديثة بمستوى متقدم، ده محتاج وضع أونلاين وربط خدمة ذكاء اصطناعي بمفتاح API؛ وده مش متوفر في النسخة الحالية.';
    return null;
  }
  int? pageFor(String q) {
    final v=q.replaceFirst(RegExp(r'^(افتح|روح|انتقل إلى|اذهب إلى|اعرض)\s*'),'').trim();
    if(v.contains('الرئيسية')||v.contains('الداشبورد'))return 0;
    if(v.contains('المنتجات')||v.contains('الأصناف'))return 1;
    if(v.contains('المبيعات')||v=='بيع')return 2;
    if(v.contains('المشتريات')||v=='شراء')return 3;
    if(v.contains('الموردين')||v.contains('الموردون'))return 4;
    if(v.contains('العملاء'))return 5;
    if(v.contains('المخازن'))return 6;
    if(v.contains('المصروفات'))return 7;
    if(v.contains('التقارير'))return 8;
    if(v.contains('الإعدادات')||v.contains('الاعدادات'))return 9;
    if(v.contains('بحث الأسعار')||v.contains('بحث الاسعار'))return 10;
    if(v.contains('التصنيفات'))return 11;
    if(v.contains('الأدوات')||v.contains('الادوات'))return 12;
    if(v.contains('المساعد'))return 13;
    return null;
  }
  Future<void> runCommand() async {
    final raw=input.text.trim();if(raw.isEmpty)return;final command=understand(raw);
    setState(()=>busy=true);
    try {
      final conversational=chatAnswer(command);
      if(conversational!=null){setState(()=>reply=conversational);return;}
      final page=pageFor(command);
      if(page!=null&&RegExp(r'^(افتح|روح|انتقل|اذهب|اعرض)').hasMatch(command)){
        widget.go(page);setState(()=>reply='فتحت لك الصفحة المطلوبة.');return;
      }
      final answer=helpAnswer(command);
      if(answer!=null&&!RegExp(r'^(ضيف|اضف|أضف|سجل|عدّل|عدل|غير|غيّر|أرشف|ارشف)').hasMatch(command)){
        setState(()=>reply=answer);return;
      }
      if(RegExp(r'^(ضيف|اضف|أضف)\s+(مهمة|تذكير)').hasMatch(command)){
        final title=command.replaceFirst(RegExp(r'^(ضيف|اضف|أضف)\s+(مهمة|تذكير)\s*'),'').trim();
        if(title.isEmpty){setState(()=>reply='اكتب عنوان المهمة بعد كلمة «ضيف مهمة».');return;}
        if(await confirm('تأكيد إضافة مهمة','سأضيف المهمة: '+title+'؟')){
          await StoreDb.instance.saveTask(title);widget.changed();setState(()=>reply='تمت إضافة المهمة إلى الأدوات الذكية.');
        } else setState(()=>reply='لم أضف المهمة.');
        return;
      }
      if(RegExp(r'^(ضيف|اضف|أضف)\s+مصروف').hasMatch(command)){
        final title=textField(command,'مصروف');
        final amount=double.tryParse(numberField(command,'مبلغ'))??0;
        final category=textField(command,'تصنيف');
        if(title.isEmpty||amount<=0){setState(()=>reply='اكتب المصروف بهذا الشكل: ضيف مصروف نقل مبلغ 150 تصنيف تشغيل');return;}
        if(await confirm('تأكيد المصروف','البيان: '+title+'\nالمبلغ: '+money(amount)+'\nالتصنيف: '+category+'\nهل أسجله؟')){
          await StoreDb.instance.addExpense(title,category,amount,'أضيف بواسطة مساعد البرنامج');widget.changed();setState(()=>reply='تم تسجيل المصروف.');
        } else setState(()=>reply='لم أسجل أي مصروف.');
        return;
      }
      if(RegExp(r'^(سجل|اعمل|نفذ)\s+(بيع|شراء)').hasMatch(command)){
        final sale=command.contains('بيع');
        final query=command.replaceFirst(RegExp(r'^(سجل|اعمل|نفذ)\s+(بيع|شراء)\s*'),'').split(RegExp(r'\s+(كمية|سعر)\s*')).first.trim();
        final found=await StoreDb.instance.products(query);
        if(found.isEmpty){setState(()=>reply='لم أجد المنتج المطلوب. اكتب اسمه أو جزءًا منه.');return;}
        final product=found.first;final qty=int.tryParse(numberField(command,'كمية'))??0;
        final price=double.tryParse(numberField(command,'سعر'))??((sale?product['sell']:product['buy']) as num).toDouble();
        if(qty<=0){setState(()=>reply='حدد الكمية. مثال: سجل بيع فلتر زيت كمية 2 سعر 80');return;}
        final title=sale?'تأكيد تسجيل بيع':'تأكيد تسجيل شراء';
        if(await confirm(title,(sale?'المنتج: ':'المنتج: ')+(product['name']??'').toString()+'\nالكمية: '+qty.toString()+'\nسعر الوحدة: '+money(price)+'\nالإجمالي: '+money(qty*price)+'\nهل أنفّذ الحركة؟')){
          await StoreDb.instance.addMovement(sale?'sale':'purchase',product,qty,price,'تم التسجيل بواسطة مساعد البرنامج');widget.changed();setState(()=>reply=sale?'تم تسجيل البيع وتحديث المخزون.':'تم تسجيل الشراء وتحديث المخزون.');
        } else setState(()=>reply='لم أسجل الحركة.');
        return;
      }
      if(RegExp(r'^(عدّل|عدل)\s+كمية').hasMatch(command)){
        final query=command.replaceFirst(RegExp(r'^(عدّل|عدل)\s+كمية\s*'),'').split(RegExp(r'\s+(إلى|الى)\s*')).first.trim();
        final qty=int.tryParse(numberField(command,'إلى')==''?numberField(command,'الى'):numberField(command,'إلى'));
        final found=await StoreDb.instance.products(query);
        if(found.isEmpty||qty==null){setState(()=>reply='مثال: عدل كمية فلتر الزيت إلى 10');return;}
        final p=found.first;
        if(await confirm('تأكيد تعديل المخزون','المنتج: '+p['name'].toString()+'\nالكمية الحالية: '+p['qty'].toString()+'\nالكمية الجديدة: '+qty.toString())){
          await StoreDb.instance.adjustStock(p,qty,'تسوية بواسطة مساعد البرنامج');widget.changed();setState(()=>reply='تم تعديل الكمية وتسجيل سبب التسوية في سجل المخزون.');
        } else setState(()=>reply='لم أغير الكمية.');
        return;
      }
      if(RegExp(r'^(غير|غيّر|عدل|عدّل)\s+سعر').hasMatch(command)){
        final sale=command.contains('بيع');final buy=command.contains('شراء');
        final key=sale?'سعر بيع':'سعر شراء';
        final query=command.replaceFirst(RegExp(r'^(غير|غيّر|عدل|عدّل)\s+سعر\s+(بيع|شراء)\s*'),'').split(RegExp(r'\s+(إلى|الى)\s*')).first.trim();
        final raw=numberField(command,'إلى').isNotEmpty?numberField(command,'إلى'):numberField(command,'الى');
        final price=double.tryParse(raw);final found=await StoreDb.instance.products(query);
        if((!sale&&!buy)||price==null||found.isEmpty){setState(()=>reply='مثال: غير سعر بيع فلتر الزيت إلى 95');return;}
        final p=found.first;final data=Map<String,Object?>.from(p);data[sale?'sell':'buy']=price;
        if(await confirm('تأكيد تعديل السعر','المنتج: '+p['name'].toString()+'\n'+key+': '+money(price)+'\nهل تحفظ السعر؟')){
          await StoreDb.instance.saveProduct(data,p['id'] as int);await StoreDb.instance.log('تعديل سعر من المساعد',p['name'].toString());widget.changed();setState(()=>reply='تم تحديث السعر وتسجيل التعديل.');
        } else setState(()=>reply='لم أغير السعر.');
        return;
      }
      if(RegExp(r'^(أرشف|ارشف)\s+').hasMatch(command)){
        final query=command.replaceFirst(RegExp(r'^(أرشف|ارشف)\s*'),'').trim();
        final found=await StoreDb.instance.products(query);
        if(found.isEmpty){setState(()=>reply='لم أجد المنتج لأرشفه.');return;}
        final p=found.first;
        if(await confirm('تأكيد أرشفة المنتج','سيتم إخفاء '+p['name'].toString()+' من القائمة النشطة مع الاحتفاظ بسجلاته. متابعة؟')){
          await StoreDb.instance.setArchived(p['id'] as int,true);widget.changed();setState(()=>reply='تمت أرشفة المنتج مع الاحتفاظ بسجلاته.');
        } else setState(()=>reply='لم أؤرشف المنتج.');
        return;
      }
      final addIntent=RegExp(r'^(ضيف|اضف|أضف|سجل|إضافة)\s+(منتج|صنف)').hasMatch(command);
      if(addIntent){
        final name=textField(command,'اسم');
        final qty=int.tryParse(numberField(command,'كمية'))??0;
        final buy=double.tryParse(numberField(command,'شراء'))??0;
        final sell=double.tryParse(numberField(command,'بيع'))??0;
        final category=textField(command,'تصنيف'),brand=textField(command,'ماركة'),manufacturer=textField(command,'شركة');
        final partNo=textField(command,'رقم القطعة'),altPartNo=textField(command,'البديل'),location=textField(command,'مكان التخزين');
        final unit=textField(command,'وحدة'),country=textField(command,'بلد المنشأ'),altNames=textField(command,'أسماء بديلة');
        final specs=textField(command,'مواصفات'),compatibility=textField(command,'متوافق مع'),dimensions=textField(command,'الأبعاد'),weight=textField(command,'وزن');
        if(name.isEmpty){setState(()=>reply='مثال: ضيف منتج اسم فلتر زيت كمية 5 شراء 40 بيع 60 ماركة تويوتا');return;}
        final data={'name':name,'category':category,'qty':qty,'min_qty':0,'buy':buy,'sell':sell,'manufacturer':manufacturer,'part_no':partNo,'alt_part_no':altPartNo,'location':location,'description':'أضيف بواسطة مساعد البرنامج','wholesale':0.0,'brand':brand,'unit':unit.isEmpty?'قطعة':unit,'country':country,'alt_names':altNames,'specs':specs,'image_path':'','sku':'','supplier_id':null,'compatibility':compatibility,'dimensions':dimensions,'weight':weight};
        if(await confirm('مراجعة المنتج قبل الإضافة','الاسم: '+name+'\nالكمية: '+qty.toString()+'\nالشراء: '+money(buy)+'\nالبيع: '+money(sell)+'\nالتصنيف: '+category+'\nالماركة: '+brand+'\nرقم القطعة: '+partNo+'\nالمواصفات: '+specs+'\nهل تضيفه؟')){
          await StoreDb.instance.saveProduct(data,null);await StoreDb.instance.log('إضافة منتج بالمساعد',name);widget.changed();setState(()=>reply='تمت إضافة '+name+'.');
        } else setState(()=>reply='لم أضف المنتج.');
        return;
      }
      if(command.contains('ملخص')||command.contains('إحصائيات')||command.contains('احصائيات')){
        final d=await StoreDb.instance.summary();
        setState(()=>reply='ملخص البرنامج:\nعدد المنتجات: '+d['count'].toString()+'\nإجمالي الوحدات: '+d['qty'].toString()+'\nنواقص المخزون: '+d['low'].toString()+'\nالمبيعات: '+money(d['sales'])+'\nالمشتريات: '+money(d['buys'])+'\nالمصروفات: '+money(d['expense_total'])+'\nالربح التقديري: '+money(d['profit']));
        return;
      }
      final query=clean(command);
      final found=await StoreDb.instance.products(query);
      if(found.isNotEmpty){setState(()=>results=found);setState(()=>reply='وجدت '+found.length.toString()+' نتيجة في بيانات جهازك. اضغط على المنتج لعرض تفاصيله أو تعديله.');}
      else setState(()=>reply='لم أفهم الطلب أو لم أجد المنتج. اكتب «مساعدة» لعرض ما أستطيع فعله، أو «أمثلة للأوامر».');
    } catch(e){if(mounted)setState(()=>reply='تعذر تنفيذ الطلب: '+e.toString().replaceFirst('Exception: ',''));}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> contactSupport()async{
    const phone='584263545601';
    final message=Uri.encodeComponent('مرحباً فريق دعم MY APP 👋\n\nنوع الطلب: استفسار / شكوى / الإبلاغ عن مشكلة\n\nإصدار التطبيق: 3.8.0\nالجهاز: \n\nتفاصيل المشكلة أو الطلب:\n');
    final uri=Uri.parse('https://wa.me/$phone?text=$message');
    if(!await launchUrl(uri,mode:LaunchMode.externalApplication)&&mounted)toast(context,'تعذر فتح واتساب. تأكد من تثبيته أو افتح الرابط من المتصفح.');
  }
  @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(14),children:[
    Card(color:Theme.of(context).colorScheme.primaryContainer,child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[const CircleAvatar(child:Icon(Icons.support_agent)),const SizedBox(width:10),const Expanded(child:Text('مساعد MY APP',style:TextStyle(fontSize:21,fontWeight:FontWeight.w900)))]),
      const SizedBox(height:8),const Text('مساعد محلي بالمصري: يشرح صفحات البرنامج، يفتحها، يبحث عن المنتجات وينفذ أوامر المخزون والمبيعات والمشتريات والمصروفات والمهام بعد موافقتك. لا يحتاج إنترنت للوظائف المحلية، لكنه ليس نموذجاً عاماً مفتوحاً ولا يبحث في الويب.'),
      const SizedBox(height:12),Text(reply),
    ]))),
    TextField(controller:input,minLines:2,maxLines:5,onSubmitted:(_)=>runCommand(),decoration:const InputDecoration(labelText:'اكتب سؤالك أو أمرك',hintText:'مثال: اشرح التقارير\nأو: افتح المنتجات\nأو: سجل بيع فلتر زيت كمية 2 سعر 80',border:OutlineInputBorder())),
    const SizedBox(height:10),FilledButton.icon(onPressed:busy?null:runCommand,icon:busy?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.send),label:const Text('تنفيذ الطلب')),
    const SizedBox(height:12),Card(child:ListTile(leading:const CircleAvatar(backgroundColor:Color(0xFFE5F8EC),child:Icon(Icons.chat,color:Color(0xFF168C4B))),title:const Text('تواصل مع الدعم الفني',style:TextStyle(fontWeight:FontWeight.bold)),subtitle:const Text('استفسار أو شكوى أو الإبلاغ عن مشكلة'),trailing:const Icon(Icons.open_in_new),onTap:contactSupport)),
    const SizedBox(height:14),if(results.isNotEmpty)const Text('نتائج البحث',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
    ...results.map((e)=>Card(child:ListTile(onTap:()=>showProduct(e),leading:const Icon(Icons.inventory_2_outlined),title:Text(e['name'].toString()),subtitle:Text('الكود: '+e['sku'].toString()+' • البدائل: '+e['alt_names'].toString()),trailing:Text(money(e['sell']),style:const TextStyle(fontWeight:FontWeight.bold)))))
  ]);
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key,required this.go,required this.appName}); final ValueChanged<int> go; final String appName;
  @override State<Dashboard> createState()=>_DashboardState();
}
class _DashboardState extends State<Dashboard> {
  Map<String,Object?> data={}; List<Map<String,Object?>> low=[];
  @override void initState(){super.initState();load();}
  Future<void> load() async {
    final d=await StoreDb.instance.summary(); final p=await StoreDb.instance.products();
    if(mounted) setState(() { data=d; low=p.where((e)=>(e['qty'] as int)<=(e['min_qty'] as int)).toList(); });
  }
  Widget stat(String label,String value,IconData icon)=>Expanded(child:Card(child:Padding(padding:const EdgeInsets.symmetric(horizontal:12,vertical:15),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Container(width:36,height:36,decoration:BoxDecoration(color:Theme.of(context).colorScheme.primaryContainer,borderRadius:BorderRadius.circular(12)),child:Icon(icon,color:Theme.of(context).colorScheme.primary,size:20)),
    const SizedBox(height:10),Text(value,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:19,fontWeight:FontWeight.w900)),
    const SizedBox(height:3),Text(label,maxLines:2,overflow:TextOverflow.ellipsis,style:TextStyle(fontSize:11,color:Theme.of(context).colorScheme.onSurfaceVariant))]))));
  @override Widget build(BuildContext context)=>RefreshIndicator(onRefresh:load,child:ListView(padding:const EdgeInsets.all(14),children:[
    Container(width:double.infinity,padding:const EdgeInsets.all(20),decoration:BoxDecoration(
      gradient:LinearGradient(begin:Alignment.topRight,end:Alignment.bottomLeft,colors:[Theme.of(context).colorScheme.primary,Theme.of(context).colorScheme.primary.withOpacity(.78)]),
      borderRadius:BorderRadius.circular(22),boxShadow:[BoxShadow(color:Theme.of(context).colorScheme.primary.withOpacity(.16),blurRadius:18,offset:const Offset(0,8))]
    ),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Row(children:[Icon(Icons.storefront_outlined,color:Colors.white,size:27),SizedBox(width:9),Text('لوحة التحكم',style:TextStyle(color:Colors.white70,fontWeight:FontWeight.w600))]),
      const SizedBox(height:12),Text('أهلاً بك في ${widget.appName}',style:const TextStyle(fontSize:22,fontWeight:FontWeight.w900,color:Colors.white)),
      const SizedBox(height:5),const Text('كل حركة مخزونك ومبيعاتك في مكان واحد.',style:TextStyle(color:Colors.white70)),
      const SizedBox(height:16),Wrap(spacing:8,runSpacing:8,children:[
        FilledButton.tonalIcon(style:FilledButton.styleFrom(backgroundColor:Colors.white,foregroundColor:Theme.of(context).colorScheme.primary),onPressed:()=>widget.go(1),icon:const Icon(Icons.add_box),label:const Text('إضافة / المنتجات')),
        FilledButton.tonalIcon(style:FilledButton.styleFrom(backgroundColor:Colors.white.withOpacity(.16),foregroundColor:Colors.white),onPressed:()=>widget.go(2),icon:const Icon(Icons.point_of_sale),label:const Text('تسجيل بيع')),
        FilledButton.tonalIcon(style:FilledButton.styleFrom(backgroundColor:Colors.white.withOpacity(.16),foregroundColor:Colors.white),onPressed:()=>widget.go(13),icon:const Icon(Icons.support_agent),label:const Text('المساعد')),
        FilledButton.tonalIcon(style:FilledButton.styleFrom(backgroundColor:Colors.white.withOpacity(.16),foregroundColor:Colors.white),onPressed:()=>widget.go(19),icon:const Icon(Icons.warning_amber_rounded),label:const Text('النواقص'))
      ])
    ])),
    Row(children:[stat('عدد المنتجات',(data['count']??0).toString(),Icons.inventory_2),stat('إجمالي الوحدات',(data['qty']??0).toString(),Icons.numbers)]),
    Row(children:[stat('نواقص المخزون',(data['low']??0).toString(),Icons.warning_amber),stat('المنتجات النافدة',(data['out']??0).toString(),Icons.remove_shopping_cart)]),
    Row(children:[stat('قيمة المخزون شراء',money(data['stock']),Icons.account_balance_wallet),stat('قيمة المخزون بيع',money(data['stock_sell']),Icons.price_check)]),
    Row(children:[stat('التصنيفات',(data['categories']??0).toString(),Icons.category),stat('الشركات المصنعة',(data['manufacturers']??0).toString(),Icons.factory)]),
    Row(children:[stat('إجمالي المبيعات',money(data['sales']),Icons.trending_up),stat('إجمالي المشتريات',money(data['buys']),Icons.shopping_bag)]),
    const SizedBox(height:12),const Text('تنبيهات المخزون',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
    if(low.isEmpty) const Card(child:ListTile(leading:Icon(Icons.check_circle,color:Colors.green),title:Text('لا توجد منتجات منخفضة المخزون.')))
    else ...low.map((e)=>Card(child:ListTile(leading:const Icon(Icons.warning_amber,color:Colors.orange),title:Text(e['name'] as String),
      subtitle:Text('المتاح: '+e['qty'].toString()+' — حد التنبيه: '+e['min_qty'].toString())))),
  ]));
}

class InvoicePage extends StatefulWidget {
  const InvoicePage({super.key,required this.changed,this.pendingOnly=false});
  final VoidCallback changed; final bool pendingOnly;
  @override State<InvoicePage> createState()=>_InvoicePageState();
}
class _InvoicePageState extends State<InvoicePage>{
  List<Map<String,Object?>> rows=[];
  @override void initState(){super.initState();load();}
  Future<void> load()async{final r=await StoreDb.instance.invoices(pendingOnly:widget.pendingOnly);if(mounted)setState(()=>rows=r);}
  Future<void> create()async{final products=await StoreDb.instance.products();final customers=await StoreDb.instance.parties('customers');final suppliers=await StoreDb.instance.parties('suppliers');if(!mounted)return;if(products.isEmpty){toast(context,'أضف منتجات أولاً.');return;}final result=await showDialog<bool>(context:context,builder:(_)=>InvoiceEditor(products:products,customers:customers,suppliers:suppliers));if(result==true){await load();widget.changed();}}
   Future<void> append(Map<String,Object?> invoice)async{final products=await StoreDb.instance.products();final suppliers=await StoreDb.instance.parties('suppliers');if(!mounted)return;final result=await showDialog<bool>(context:context,builder:(_)=>InvoiceEditor(products:products,customers:const [],suppliers:suppliers,invoice:invoice));if(result==true){await load();widget.changed();}}
  Future<void> pay(Map<String,Object?> invoice)async{final c=TextEditingController();final due=(invoice['total'] as num).toDouble()-(invoice['paid'] as num).toDouble();final ok=await showDialog<bool>(context:context,builder:(ctx)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:Text('تحصيل دفعة • ${invoice['invoice_no']}'),content:TextField(controller:c,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:InputDecoration(labelText:'المبلغ المتبقي: ${money(due)}')),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('تأكيد التحصيل'))])));if(ok==true){try{await StoreDb.instance.addInvoicePayment(invoice['id'] as int,double.parse(c.text));await load();}catch(e){if(mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}}c.dispose();}
  Future<void> details(Map<String,Object?> e)async{final items=await StoreDb.instance.invoiceItems(e['id'] as int);if(!mounted)return;final total=(e['total'] as num).toDouble(),paid=(e['paid'] as num).toDouble();await showDialog(context:context,builder:(ctx)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:Text('فاتورة ${e['invoice_no']}'),content:SizedBox(width:460,child:SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[Text('العميل: ${e['customer_name']}'),if((e['customer_phone']??'').toString().trim().isNotEmpty)Text('الهاتف: ${e['customer_phone']}'),Text('التاريخ: ${e['created_at']}'),const Divider(),...items.map((x)=>ListTile(dense:true,title:Text(x['product_name'].toString()),subtitle:Text('${x['qty']} × ${money(x['unit_price'])} • ${x['supplier_name']??'بدون مورد'}\nأضيف: ${x['added_at']??e['created_at']}'),isThreeLine:true,trailing:Text(money(x['total'])))),const Divider(),Text('الإجمالي: ${money(total)}'),Text('المدفوع: ${money(paid)}'),Text('المتبقي: ${money(total-paid)}',style:const TextStyle(fontWeight:FontWeight.bold)),if((e['note']??'').toString().isNotEmpty)Text('ملاحظات: ${e['note']}')]))),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إغلاق')),OutlinedButton.icon(onPressed:(){Navigator.pop(ctx);append(e);},icon:const Icon(Icons.add_shopping_cart),label:const Text('إضافة أصناف')),FilledButton.icon(onPressed:()=>printTextReport(context,'فاتورة بيع • ${e['invoice_no']}', ['MY APP — فاتورة بيع','رقم الفاتورة: ${e['invoice_no']}','العميل: ${e['customer_name']}',if((e['customer_phone']??'').toString().trim().isNotEmpty)'الهاتف: ${e['customer_phone']}','التاريخ: ${e['created_at']}','--------------------------------',...items.map((x)=>'${x['product_name']} | ${x['qty']} × ${money(x['unit_price'])} = ${money(x['total'])} | المورد: ${x['supplier_name']??'بدون مورد'} | أضيف: ${x['added_at']??e['created_at']}'),'الإجمالي قبل الخصم: ${money(e['subtotal'])}','الخصم: ${money(e['discount_amount'])}','الإجمالي النهائي: ${money(total)}','المدفوع: ${money(paid)}','المتبقي: ${money(total-paid)}','ملاحظات: ${e['note']}','شكراً لتعاملكم معنا']),icon:const Icon(Icons.picture_as_pdf),label:const Text('طباعة / PDF'))])));}
  @override Widget build(BuildContext context)=>Column(children:[Padding(padding:const EdgeInsets.all(12),child:Row(children:[Expanded(child:Text(widget.pendingOnly?'الفواتير المستحقة':'فواتير البيع',style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold))),IconButton(onPressed:load,icon:const Icon(Icons.refresh)),if(!widget.pendingOnly)FilledButton.icon(onPressed:create,icon:const Icon(Icons.add),label:const Text('فاتورة جديدة'))])),Expanded(child:rows.isEmpty?Center(child:Text(widget.pendingOnly?'لا توجد مبالغ مستحقة حالياً.':'لا توجد فواتير بعد.')):ListView.builder(itemCount:rows.length,itemBuilder:(ctx,i){final e=rows[i];final total=(e['total'] as num).toDouble(),paid=(e['paid'] as num).toDouble(),due=total-paid;return Card(child:ListTile(leading:CircleAvatar(child:Icon(due>0?Icons.pending_actions:Icons.receipt_long)),title:Text('${e['invoice_no']} • ${e['customer_name']}'),subtitle:Text('الإجمالي: ${money(total)} • المدفوع: ${money(paid)} • المتبقي: ${money(due)}\n${e['created_at']}'),isThreeLine:true,onTap:()=>details(e),trailing:PopupMenuButton<String>(onSelected:(v){if(v=='pay')pay(e);else details(e);},itemBuilder:(_)=>[const PopupMenuItem(value:'details',child:Text('تفاصيل وطباعة')),if(due>0)const PopupMenuItem(value:'pay',child:Text('تسجيل دفعة'))])));} ))]);
}
class InvoiceEditor extends StatefulWidget{
  const InvoiceEditor({super.key,required this.products,required this.customers,required this.suppliers,this.invoice});
  final List<Map<String,Object?>> products,customers,suppliers;final Map<String,Object?>? invoice;
  @override State<InvoiceEditor> createState()=>_InvoiceEditorState();
}
class _InvoiceEditorState extends State<InvoiceEditor>{
  final List<Map<String,Object?>> items=[];final discount=TextEditingController(text:'0'),paid=TextEditingController(text:'0'),note=TextEditingController(),customerName=TextEditingController(),customerPhone=TextEditingController();bool percent=false;
  double get subtotal=>items.fold<double>(0,(s,e)=>s+(e['qty'] as int)*(e['unit_price'] as num).toDouble());
  double get discountAmount{final v=double.tryParse(discount.text)??0;return percent?subtotal*v/100:v;}
  double get total=>(subtotal-discountAmount).clamp(0,double.infinity).toDouble();
  @override void dispose(){discount.dispose();paid.dispose();note.dispose();customerName.dispose();customerPhone.dispose();super.dispose();}
  Future<void> addItem() async {
    final available=widget.products.where((p)=>(p['qty'] as int)>0).toList();
    if(available.isEmpty){toast(context,'لا توجد كميات متاحة للبيع.');return;}
    Map<String,Object?> selected=available.first;
    int? selectedSupplier=selected['supplier_id'] as int?;
    final q=TextEditingController(text:'1');
    final price=TextEditingController(text:((selected['sell'] as num).toDouble()/math.max(1,(selected['package_size'] as int? ?? 1))).toStringAsFixed(2));
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,refresh)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(
      shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(22)),
      title:const Row(children:[Icon(Icons.add_shopping_cart),SizedBox(width:8),Text('إضافة صنف للفاتورة')]),
      content:SizedBox(width:440,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        DropdownButtonFormField<int>(value:selected['id'] as int,decoration:const InputDecoration(labelText:'المنتج',prefixIcon:Icon(Icons.inventory_2_outlined)),items:available.map((p)=>DropdownMenuItem<int>(value:p['id'] as int,child:Text('${p['name']} • متاح ${p['qty']} قطعة'))).toList(),onChanged:(id){selected=available.firstWhere((p)=>p['id']==id);selectedSupplier=selected['supplier_id'] as int?;price.text=((selected['sell'] as num).toDouble()/math.max(1,(selected['package_size'] as int? ?? 1))).toStringAsFixed(2);refresh((){});}),
        const SizedBox(height:10),
        Row(children:[Expanded(child:DropdownButtonFormField<int?>(value:selectedSupplier,decoration:const InputDecoration(labelText:'المورد المسؤول عن الصنف',prefixIcon:Icon(Icons.local_shipping_outlined)),items:[const DropdownMenuItem<int?>(value:null,child:Text('بدون مورد')),...widget.suppliers.map((sp)=>DropdownMenuItem<int?>(value:sp['id'] as int,child:Text(sp['name'].toString())))],onChanged:(v)=>refresh(()=>selectedSupplier=v))),IconButton(tooltip:'إضافة مورد جديد',onPressed:()async{final name=TextEditingController(),phone=TextEditingController();final added=await showDialog<bool>(context:ctx,builder:(d)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:const Text('إضافة مورد جديد'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:name,decoration:const InputDecoration(labelText:'اسم المورد *')),TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'رقم الهاتف'))]),actions:[TextButton(onPressed:()=>Navigator.pop(d,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(d,name.text.trim().isNotEmpty),child:const Text('حفظ المورد'))])));if(added==true){await StoreDb.instance.saveParty('suppliers',{'name':name.text.trim(),'phone':phone.text.trim(),'email':'','address':'','notes':'','balance':0},null);final updated=await StoreDb.instance.parties('suppliers');final created=updated.firstWhere((sp)=>sp['name']==name.text.trim());widget.suppliers.add(created);refresh(()=>selectedSupplier=created['id'] as int);}name.dispose();phone.dispose();},icon:const Icon(Icons.add_circle_outline))]),
        TextField(controller:q,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'الكمية بالقطعة',prefixIcon:Icon(Icons.numbers))),
        TextField(controller:price,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'سعر بيع القطعة',prefixIcon:Icon(Icons.payments_outlined))),
        const Padding(padding:EdgeInsets.only(top:6),child:Text('سيُحفظ المورد مع الصنف، ويُسجل وقت إضافة كل صنف بصورة مستقلة.',style:TextStyle(fontSize:12,color:Colors.grey)))
      ]))),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton.icon(onPressed:()=>Navigator.pop(ctx,true),icon:const Icon(Icons.add),label:const Text('إضافة الصنف'))]
    ))));
    if(ok==true){final qty=int.tryParse(q.text)??0,unitPrice=double.tryParse(price.text)??-1;if(qty<=0||unitPrice<0){toast(context,'راجع الكمية والسعر.');}else if(qty>(selected['qty'] as int)){toast(context,'الكمية المطلوبة أكبر من المتاح.');}else{final supplierMatches=widget.suppliers.where((sp)=>sp['id']==selectedSupplier).toList();final supplier=supplierMatches.isEmpty?null:supplierMatches.first;setState(()=>items.add({'product_id':selected['id'],'product_name':selected['name'],'qty':qty,'unit_price':unitPrice,'cost_price':selected['buy'],'supplier_id':selectedSupplier,'supplier_name':supplier?['name']??'' ,'added_at':DateTime.now().toIso8601String()}));}}
    q.dispose();price.dispose();
  }
  Future<void> save()async{final p=double.tryParse(paid.text)??-1;if(p<0||p>total){toast(context,'راجع المبلغ المدفوع.');return;}try{if(widget.invoice!=null){await StoreDb.instance.appendInvoiceItems(widget.invoice!['id'] as int,items);}else{await StoreDb.instance.createInvoice(customerName:customerName.text.trim(),customerPhone:customerPhone.text.trim(),customerId:null,items:items,discountValue:double.tryParse(discount.text)??0,discountPercent:percent,paid:p,note:note.text);}if(mounted)Navigator.pop(context,true);}catch(e){if(mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}}
  @override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:Text(widget.invoice==null?'فاتورة بيع جديدة':'إضافة أصناف إلى ${widget.invoice!['invoice_no']}'),content:SizedBox(width:520,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[if(widget.invoice==null)TextField(controller:customerName,textInputAction:TextInputAction.next,decoration:const InputDecoration(labelText:'اسم العميل',hintText:'اكتب اسم العميل هنا',prefixIcon:Icon(Icons.person_outline))),if(widget.invoice==null)const SizedBox(height:8),if(widget.invoice==null)TextField(controller:customerPhone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'رقم الهاتف (اختياري)',hintText:'يمكن تركه فارغاً',prefixIcon:Icon(Icons.phone_outlined))),if(widget.invoice==null)const SizedBox(height:10),FilledButton.icon(onPressed:addItem,icon:const Icon(Icons.add_shopping_cart),label:const Text('إضافة منتج للفاتورة')),...items.asMap().entries.map((entry){final i=entry.key,e=entry.value;return Card(child:ListTile(title:Text(e['product_name'].toString()),subtitle:Text('${e['qty']} × ${money(e['unit_price'])} • ${e['supplier_name']??'بدون مورد'}\nأضيف: ${e['added_at']??''}'),isThreeLine:true,trailing:Row(mainAxisSize:MainAxisSize.min,children:[Text(money((e['qty'] as int)*(e['unit_price'] as num).toDouble())),IconButton(onPressed:()=>setState(()=>items.removeAt(i)),icon:const Icon(Icons.delete_outline,color:Colors.red))])));}),if(widget.invoice==null)const Divider(),if(widget.invoice==null)SegmentedButton<bool>(segments:const [ButtonSegment(value:false,label:Text('خصم مبلغ')),ButtonSegment(value:true,label:Text('خصم نسبة'))],selected:{percent},onSelectionChanged:(v)=>setState(()=>percent=v.first)),if(widget.invoice==null)TextField(controller:discount,onChanged:(_)=>setState((){}),keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'قيمة الخصم')),if(widget.invoice==null)TextField(controller:paid,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'المبلغ المدفوع')),if(widget.invoice==null)TextField(controller:note,maxLines:2,decoration:const InputDecoration(labelText:'ملاحظات الفاتورة')),const SizedBox(height:8),if(widget.invoice==null)Text('المجموع قبل الخصم: ${money(subtotal)}'),if(widget.invoice==null)Text('قيمة الخصم: ${money(discountAmount)}'),if(widget.invoice==null)Text('الإجمالي النهائي: ${money(total)}',style:const TextStyle(fontWeight:FontWeight.bold,fontSize:18)),if(widget.invoice==null)Text('المتبقي: ${money(total-(double.tryParse(paid.text)??0))}',style:const TextStyle(color:Colors.deepOrange,fontWeight:FontWeight.bold)),if(widget.invoice!=null)Text('قيمة الأصناف الجديدة: ${money(subtotal)}',style:const TextStyle(fontWeight:FontWeight.bold,fontSize:17))]))),actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('إلغاء')),FilledButton(onPressed:save,child:Text(widget.invoice==null?'حفظ وإصدار الفاتورة':'حفظ الأصناف على الفاتورة'))]));
}

Widget _productInfoChip(BuildContext context,String label,String value,IconData icon)=>Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:8),decoration:BoxDecoration(color:Theme.of(context).colorScheme.surfaceContainerHighest,borderRadius:BorderRadius.circular(14)),child:Row(mainAxisSize:MainAxisSize.min,children:[Icon(icon,size:16),const SizedBox(width:5),Text('$label: $value',style:const TextStyle(fontWeight:FontWeight.w700))]));
Widget _productInfoLine(String label,Object? value){final text=(value??'').toString().trim();if(text.isEmpty||text=='null')return const SizedBox.shrink();return Padding(padding:const EdgeInsets.symmetric(vertical:4),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[SizedBox(width:125,child:Text(label,style:const TextStyle(color:Colors.grey))),Expanded(child:Text(text,style:const TextStyle(fontWeight:FontWeight.w600)))]));}

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key,required this.changed}); final VoidCallback changed;
  @override State<ProductsPage> createState()=>_ProductsPageState();
}
class _ProductsPageState extends State<ProductsPage> {
  final search=TextEditingController(); List<Map<String,Object?>> rows=[];
  @override void initState(){super.initState();load();}
  @override void dispose(){search.dispose();super.dispose();}
  Future<void> load() async {final r=await StoreDb.instance.products(search.text);if(mounted)setState(()=>rows=r);}
  Future<void> edit([Map<String,Object?>? row]) async {
    final ok=await showDialog<bool>(context:context,builder:(_)=>ProductDialog(item:row));
    if(ok==true){await load();widget.changed();}
  }
  Future<void> adjust(Map<String,Object?> row) async {
    final qty=TextEditingController(text:row['qty'].toString());final reason=TextEditingController();
    final ok=await showDialog<bool>(context:context,builder:(c)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(
      title:Text('جرد وتسوية '+row['name'].toString()),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        Text('الكمية المسجلة حالياً: '+row['qty'].toString()),
        TextField(controller:qty,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'الكمية الفعلية بعد الجرد')),
        TextField(controller:reason,decoration:const InputDecoration(labelText:'سبب التسوية'))
      ]),
      actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(c,int.tryParse(qty.text)!=null&&int.parse(qty.text)>=0),child:const Text('حفظ التسوية'))])));
    if(ok==true){await StoreDb.instance.adjustStock(row,int.parse(qty.text),reason.text);await load();widget.changed();}
    qty.dispose();reason.dispose();
  }
  Future<void> remove(Map<String,Object?> row) async {
    if(await ask(context,'حذف المنتج','هل تريد حذف '+row['name'].toString()+'؟')!=true)return;
    try{await StoreDb.instance.removeProduct(row['id'] as int);await load();widget.changed();}
    catch(e){if(mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}
  }
  Future<void> favorite(Map<String,Object?> row) async {final id=row['id'] as int;final current=await StoreDb.instance.isFavorite(id);await StoreDb.instance.toggleFavorite(id,!current);if(mounted)toast(context,current?'تمت إزالة المنتج من المفضلة':'تمت إضافة المنتج للمفضلة');}
  Future<void> details(Map<String,Object?> row) async {
    final supplierRows=(await StoreDb.instance.parties('suppliers')).where((x)=>x['id']==row['supplier_id']).toList();
    final supplier=supplierRows.isEmpty?'بدون مورد':supplierRows.first['name'].toString();
    if(!mounted)return;
    await showDialog(context:context,builder:(ctx)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(
      shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(24)),
      title:Row(children:[const Icon(Icons.inventory_2_outlined),const SizedBox(width:8),Expanded(child:Text(row['name'].toString(),style:const TextStyle(fontWeight:FontWeight.w900)))]),
      content:SizedBox(width:460,child:SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        if((row['image_path']??'').toString().isNotEmpty&&File(row['image_path'] as String).existsSync())ClipRRect(borderRadius:BorderRadius.circular(16),child:Image.file(File(row['image_path'] as String),height:170,fit:BoxFit.contain)),
        Wrap(spacing:8,runSpacing:8,children:[_productInfoChip(context,'المتاح',row['qty'].toString(),Icons.inventory_2_outlined),_productInfoChip(context,'حد التنبيه',row['min_qty'].toString(),Icons.warning_amber_outlined),_productInfoChip(context,'الكود',row['sku'].toString(),Icons.qr_code_2)]),
        const Divider(height:24),
        _productInfoLine('التصنيف',row['category']),_productInfoLine('المورد',supplier),_productInfoLine('سعر الشراء',money(row['buy'])),_productInfoLine('سعر البيع',money(row['sell'])),_productInfoLine('سعر الجملة',money(row['wholesale'])),_productInfoLine('الشركة المصنعة',row['manufacturer']),_productInfoLine('الماركة',row['brand']),_productInfoLine('رقم القطعة',row['part_no']),_productInfoLine('الرقم البديل',row['alt_part_no']),_productInfoLine('مكان التخزين',row['location']),_productInfoLine('الوحدة',row['unit']),_productInfoLine('بلد المنشأ',row['country']),_productInfoLine('الموديلات المتوافقة',row['compatibility']),_productInfoLine('المواصفات',row['specs']),_productInfoLine('الأبعاد',row['dimensions']),_productInfoLine('الوزن',row['weight']),_productInfoLine('عدد القطع بالعبوة',row['package_size']),
        if((row['description']??'').toString().trim().isNotEmpty)Padding(padding:const EdgeInsets.only(top:10),child:Text(row['description'].toString()))
      ]))),
      actions:[TextButton.icon(onPressed:()=>Navigator.pop(ctx),icon:const Icon(Icons.close),label:const Text('إغلاق')),FilledButton.icon(onPressed:(){Navigator.pop(ctx);edit(row);},icon:const Icon(Icons.edit_outlined),label:const Text('تعديل المنتج'))]
    )));
  }
  Future<void> history(Map<String,Object?> row) async {
    final items=await StoreDb.instance.priceHistory(row['id'] as int);if(!mounted)return;
    showDialog(context:context,builder:(ctx)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:Text('سجل أسعار ${row['name']}'),content:SizedBox(width:420,height:360,child:items.isEmpty?const Center(child:Text('لا توجد تغييرات مسجلة بعد')):ListView(children:items.map((x)=>ListTile(title:Text('بيع: ${money(x['old_sell'])} ← ${money(x['new_sell'])}'),subtitle:Text('شراء: ${money(x['old_buy'])} ← ${money(x['new_buy'])}\\n${x['created_at']}'))).toList())),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إغلاق'))])));
  }
  @override Widget build(BuildContext context)=>Column(children:[
    Padding(padding:const EdgeInsets.all(12),child:Row(children:[
      Expanded(child:TextField(controller:search,onChanged:(_)=>load(),decoration:const InputDecoration(hintText:'بحث بالاسم أو التصنيف',prefixIcon:Icon(Icons.search)))),
      const SizedBox(width:4),
      IconButton(tooltip:'طباعة الجرد',onPressed:()=>printTextReport(context,'تقرير جرد المنتجات',[
        'عدد المنتجات: ${rows.length}',
        ...rows.map((e)=>'${e['name']} | التصنيف: ${e['category']} | الكمية: ${e['qty']} | حد التنبيه: ${e['min_qty']} | شراء: ${money(e['buy'])} | بيع: ${money(e['sell'])}')
      ]),icon:const Icon(Icons.print_outlined)),
      IconButton.filled(onPressed:()=>edit(),icon:const Icon(Icons.add))])),
    Expanded(child:rows.isEmpty?const Center(child:Text('لا توجد منتجات. اضغط + لإضافة منتج.'))
      :ListView.builder(padding:const EdgeInsets.only(bottom:20),itemCount:rows.length,itemBuilder:(c,i){
        final e=rows[i];final low=(e['qty'] as int)<=(e['min_qty'] as int);
        return Card(child:ListTile(leading:(e['image_path']??'').toString().isNotEmpty&&File(e['image_path'] as String).existsSync()?ClipRRect(borderRadius:BorderRadius.circular(8),child:Image.file(File(e['image_path'] as String),width:48,height:48,fit:BoxFit.cover)):CircleAvatar(child:Icon(low?Icons.warning_amber:Icons.inventory_2)),
          title:Text(e['name'] as String),subtitle:Text('الكود: ${e['sku']??'—'} • '+e['category'].toString()+' • الكمية: '+e['qty'].toString()+' • سعر البيع: '+money(e['sell'])),onTap:()=>details(e),
          trailing:PopupMenuButton<String>(onSelected:(v){if(v=='edit'){edit(e);}else if(v=='adjust'){adjust(e);}else if(v=='history'){history(e);}else if(v=='qr'){showQr(context,e['sku'].toString(),e['name'].toString());}else if(v=='favorite'){favorite(e);}else if(v=='archive'){StoreDb.instance.setArchived(e['id'] as int,true).then((_){load();});}else{remove(e);}},
            itemBuilder:(_)=>const [PopupMenuItem(value:'edit',child:Text('تعديل')),PopupMenuItem(value:'adjust',child:Text('تسوية وجرد الكمية')),PopupMenuItem(value:'history',child:Text('سجل الأسعار')),PopupMenuItem(value:'qr',child:Text('عرض QR')),PopupMenuItem(value:'favorite',child:Text('إضافة / إزالة من المفضلة')),PopupMenuItem(value:'archive',child:Text('أرشفة المنتج')),PopupMenuItem(value:'delete',child:Text('حذف'))])));
      })),
  ]);
}

class ProductDialog extends StatefulWidget {
  const ProductDialog({super.key,this.item}); final Map<String,Object?>? item;
  @override State<ProductDialog> createState()=>_ProductDialogState();
}
class _ProductDialogState extends State<ProductDialog> {
  final form=GlobalKey<FormState>(); late final List<TextEditingController> c; String? imagePath;List<Map<String,Object?>> suppliers=[];int? supplierId;
  @override void initState(){super.initState();final e=widget.item;c=[
    TextEditingController(text:e?['name'] as String? ?? ''),TextEditingController(text:e?['category'] as String? ?? ''),
    TextEditingController(text:(e?['qty']??0).toString()),TextEditingController(text:(e?['min_qty']??0).toString()),
    TextEditingController(text:(e?['buy']??0).toString()),TextEditingController(text:(e?['sell']??0).toString()),TextEditingController(text:e?['manufacturer'] as String? ?? ''),TextEditingController(text:e?['part_no'] as String? ?? ''),TextEditingController(text:e?['alt_part_no'] as String? ?? ''),TextEditingController(text:e?['location'] as String? ?? ''),TextEditingController(text:e?['description'] as String? ?? ''),TextEditingController(text:(e?['wholesale']??0).toString()),TextEditingController(text:e?['brand'] as String? ?? ''),TextEditingController(text:e?['unit'] as String? ?? 'قطعة'),TextEditingController(text:e?['country'] as String? ?? ''),TextEditingController(text:e?['alt_names'] as String? ?? ''),TextEditingController(text:e?['specs'] as String? ?? ''),TextEditingController(text:e?['sku'] as String? ?? ''),TextEditingController(text:e?['compatibility'] as String? ?? ''),TextEditingController(text:e?['dimensions'] as String? ?? ''),TextEditingController(text:e?['weight'] as String? ?? ''),TextEditingController(text:(e?['package_size']??1).toString()) ];imagePath=e?['image_path'] as String?;supplierId=e?['supplier_id'] as int?;loadSuppliers();}
  Future<void> loadSuppliers()async{final rows=await StoreDb.instance.parties('suppliers');if(mounted)setState(()=>suppliers=rows);}
  @override void dispose(){for(final x in c){x.dispose();}super.dispose();}
  String? req(String? v)=>v==null||v.trim().isEmpty?'مطلوب':null;
  String? integer(String? v)=>int.tryParse(v??'')==null||int.parse(v!)<0?'أدخل عدداً صحيحاً':null;
  String? decimal(String? v)=>double.tryParse(v??'')==null||double.parse(v!)<0?'أدخل سعراً صحيحاً':null;
  Widget field(int i,String label,{String? Function(String?)? validator,TextInputType? type})=>Padding(padding:const EdgeInsets.only(bottom:9),
    child:TextFormField(controller:c[i],validator:validator,keyboardType:type,maxLines:2,minLines:1,decoration:InputDecoration(labelText:label,alignLabelWithHint:true)));
  Future<void> pickImage(ImageSource source) async {
    try{final picked=await ImagePicker().pickImage(source:source,imageQuality:82,maxWidth:1600);if(picked==null)return;final dir=await getApplicationSupportDirectory();final ext=p.extension(picked.path);final target=File(p.join(dir.path,'product_'+DateTime.now().microsecondsSinceEpoch.toString()+(ext.isEmpty?'.jpg':ext)));await File(picked.path).copy(target.path);if(mounted)setState(()=>imagePath=target.path);}catch(e){if(mounted)toast(context,'تعذر اختيار الصورة: $e');}
  }
  Future<void> save() async {
    if(!form.currentState!.validate())return;
    try{
      final existing=await StoreDb.instance.products(c[0].text.trim());
      final duplicate=existing.any((e)=>e['name'].toString().trim().toLowerCase()==c[0].text.trim().toLowerCase()&&e['id']!=widget.item?['id']);
      if(duplicate&&await ask(context,'تنبيه تشابه','يوجد منتج مسجل بالاسم نفسه. هل تريد المتابعة وإضافة الصنف على أي حال؟')!=true)return;
      await StoreDb.instance.saveProduct({'name':c[0].text.trim(),'category':c[1].text.trim(),'qty':int.parse(c[2].text),'min_qty':int.parse(c[3].text),'buy':double.parse(c[4].text),'sell':double.parse(c[5].text),'manufacturer':c[6].text.trim(),'part_no':c[7].text.trim(),'alt_part_no':c[8].text.trim(),'location':c[9].text.trim(),'description':c[10].text.trim(),'wholesale':double.parse(c[11].text),'brand':c[12].text.trim(),'unit':c[13].text.trim(),'country':c[14].text.trim(),'alt_names':c[15].text.trim(),'specs':c[16].text.trim(),'image_path':imagePath??'','sku':c[17].text.trim(),'supplier_id':supplierId,'compatibility':c[18].text.trim(),'dimensions':c[19].text.trim(),'weight':c[20].text.trim(),'package_size':int.tryParse(c[21].text)??1},widget.item?['id'] as int?);
      await StoreDb.instance.log(widget.item==null?'إضافة منتج':'تعديل منتج',c[0].text.trim());
      if(mounted)Navigator.pop(context,true);
    }catch(e){if(mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}
  }
  @override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(
    title:Text(widget.item==null?'إضافة منتج':'تعديل منتج'),
    content:SizedBox(width:420,child:Form(key:form,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      if(widget.item!=null) Padding(padding:const EdgeInsets.only(bottom:8),child:Text('كود الصنف: ${widget.item!['sku']??''}',style:const TextStyle(fontWeight:FontWeight.bold,letterSpacing:1.5))),
      field(0,'اسم المنتج *',validator:req),field(1,'التصنيف'),field(17,'كود المنتج (اتركه فارغاً للتوليد التلقائي)'),
      Row(children:[Expanded(child:field(2,'الكمية الأساسية بالقطعة',validator:integer,type:TextInputType.number)),const SizedBox(width:8),Expanded(child:field(3,'حد التنبيه',validator:integer,type:TextInputType.number))]),
      Row(children:[Expanded(child:field(4,'سعر الشراء',validator:decimal,type:const TextInputType.numberWithOptions(decimal:true))),const SizedBox(width:8),Expanded(child:field(5,'سعر البيع',validator:decimal,type:const TextInputType.numberWithOptions(decimal:true)))]),
      const Divider(),field(6,'الشركة المصنعة'),field(7,'رقم القطعة الأصلي'),field(8,'رقم القطعة البديل'),field(9,'مكان التخزين / الرف'),field(10,'الوصف المختصر'),
      Row(children:[Expanded(child:field(11,'سعر الجملة',validator:decimal,type:const TextInputType.numberWithOptions(decimal:true))),const SizedBox(width:8),Expanded(child:field(12,'الماركة'))]),
      Row(children:[Expanded(child:field(13,'وحدة العبوة (مثلاً كرتونة)')),const SizedBox(width:8),Expanded(child:field(14,'بلد المنشأ'))]),field(15,'أسماء أخرى للقطعة'),field(16,'المواصفات الفنية'),field(18,'الموديلات / الأجهزة المتوافقة'),field(19,'المقاسات والأبعاد'),field(20,'الوزن'),field(21,'عدد القطع داخل العبوة',validator:(v)=>int.tryParse(v??'')==null||int.parse(v!)<1?'أدخل عدداً صحيحاً أكبر من صفر':null,type:TextInputType.number),DropdownButtonFormField<int?>(initialValue:supplierId,decoration:const InputDecoration(labelText:'المورد المرتبط'),items:[const DropdownMenuItem<int?>(value:null,child:Text('بدون مورد')),...suppliers.map((s)=>DropdownMenuItem<int?>(value:s['id'] as int,child:Text(s['name'].toString())))],onChanged:(v)=>setState(()=>supplierId=v)),
      if(imagePath!=null&&File(imagePath!).existsSync())Padding(padding:const EdgeInsets.all(8),child:Image.file(File(imagePath!),height:110,fit:BoxFit.contain)),
      Wrap(spacing:8,children:[OutlinedButton.icon(onPressed:()=>pickImage(ImageSource.gallery),icon:const Icon(Icons.photo_library_outlined),label:const Text('اختيار صورة')),OutlinedButton.icon(onPressed:()=>pickImage(ImageSource.camera),icon:const Icon(Icons.camera_alt_outlined),label:const Text('التقاط صورة')),if(imagePath!=null)TextButton(onPressed:()=>setState(()=>imagePath=null),child:const Text('إزالة الصورة'))]),
    ])))),
    actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('إلغاء')),FilledButton(onPressed:save,child:const Text('حفظ'))]));
}

class MovementPage extends StatefulWidget {
  const MovementPage({super.key,required this.kind,required this.changed});final String kind;final VoidCallback changed;
  @override State<MovementPage> createState()=>_MovementPageState();
}
class _MovementPageState extends State<MovementPage> {
  List<Map<String,Object?>> rows=[];
  final Set<int> selectedIds={};
  double collected=0;
  @override void initState(){super.initState();load();}
  Future<void> load() async {final r=await StoreDb.instance.movements(widget.kind);final cash=widget.kind=='sale'?await StoreDb.instance.collectedSales():0.0;if(mounted)setState((){rows=r;collected=cash;});}
  Future<void> mergeSelected() async {
    final chosen=rows.where((e)=>selectedIds.contains(e['id']) && !(e['note']??'').toString().startsWith('فاتورة ')).toList();
    if(chosen.isEmpty){toast(context,'حدد عمليات بيع مستقلة غير مرتبطة بفواتير.');return;}
    final name=TextEditingController(),phone=TextEditingController();
    final total=chosen.fold<double>(0,(s,e)=>s+(e['total'] as num).toDouble());
    final paid=TextEditingController(text:total.toStringAsFixed(2));
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:const Text('إنشاء فاتورة مجمعة'),content:SizedBox(width:420,child:Column(mainAxisSize:MainAxisSize.min,children:[Text('عدد عمليات البيع: ${chosen.length} • الإجمالي: ${money(total)}'),TextField(controller:name,decoration:const InputDecoration(labelText:'اسم العميل *')),TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'رقم الهاتف (اختياري)')),TextField(controller:paid,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'المبلغ المحصّل'))])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('إنشاء الفاتورة'))])));
    if(ok==true){try{await StoreDb.instance.createInvoiceFromSales(operationIds:chosen.map((e)=>e['id'] as int).toList(),customerName:name.text,customerPhone:phone.text,paid:double.parse(paid.text));selectedIds.clear();await load();widget.changed();if(mounted)toast(context,'تم إنشاء فاتورة مجمعة دون خصم المخزون مرة أخرى.');}catch(e){if(mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}}
    name.dispose();phone.dispose();paid.dispose();
  }
  Future<void> add() async {
    final ps=await StoreDb.instance.products();if(!mounted)return;
    if(ps.isEmpty){toast(context,'أضف منتجاً أولاً.');return;}
    final ok=await showDialog<bool>(context:context,builder:(_)=>MovementDialog(kind:widget.kind,products:ps));
    if(ok==true){await load();widget.changed();}
  }
  @override Widget build(BuildContext context) {
    final sale=widget.kind=='sale';final total=rows.fold<double>(0,(s,e)=>s+(e['total'] as num).toDouble());
    return Column(children:[
      if(sale && selectedIds.isNotEmpty) Padding(padding:const EdgeInsets.fromLTRB(12,8,12,0),child:Card(child:ListTile(leading:const Icon(Icons.receipt_long,color:Colors.teal),title:Text('تم تحديد ${selectedIds.length} عملية بيع'),subtitle:const Text('ادمج المنتجات المحددة في فاتورة واحدة'),trailing:FilledButton.icon(onPressed:mergeSelected,icon:const Icon(Icons.merge_type),label:const Text('إنشاء فاتورة'))))),
      Card(child:ListTile(leading:Icon(sale?Icons.point_of_sale:Icons.shopping_cart),title:Text(sale?'إجمالي المبيعات':'إجمالي المشتريات'),
        subtitle:Text(sale?'قيمة البيع: ${money(total)} • المحصّل: ${money(collected)} • المتبقي: ${money((total-collected).clamp(0,double.infinity))}':money(total),style:const TextStyle(fontSize:16,fontWeight:FontWeight.bold)),
        trailing:Row(mainAxisSize:MainAxisSize.min,children:[
          IconButton(tooltip:'طباعة سجل الحركات',onPressed:()=>printTextReport(context,sale?'تقرير المبيعات':'تقرير المشتريات',[
            'عدد الحركات: ${rows.length}',
            ...rows.map((e)=>'${e['product_name']} | الكمية: ${e['qty']} | سعر الوحدة: ${money(e['unit_price'])} | الإجمالي: ${money(e['total'])} | الطرف: ${e['party_name']} | التاريخ: ${e['created_at']} | ملاحظات: ${e['note']}')
          ]),icon:const Icon(Icons.print_outlined)),
          FilledButton.icon(onPressed:add,icon:const Icon(Icons.add),label:Text(sale?'بيع':'شراء'))
        ]))),
      Expanded(child:rows.isEmpty?Center(child:Text(sale?'لا توجد مبيعات مسجلة':'لا توجد مشتريات مسجلة'))
        :ListView.builder(itemCount:rows.length,itemBuilder:(c,i){final e=rows[i];final dt=DateTime.tryParse(e['created_at'] as String? ?? '');
          final selectable=sale && !(e['note']??'').toString().startsWith('فاتورة ');return Card(child:ListTile(leading:selectable?Checkbox(value:selectedIds.contains(e['id']),onChanged:(v)=>setState((){if(v==true){selectedIds.add(e['id'] as int);}else{selectedIds.remove(e['id'] as int);}})):CircleAvatar(child:Icon(sale?Icons.south_west:Icons.north_east)),
            title:Text(e['product_name'] as String),subtitle:Text(e['qty'].toString()+' × '+money(e['unit_price'])+' • '+(dt?.toLocal().toString().substring(0,16)??'')+'\n'+(e['party_name']??'').toString()+' • '+e['note'].toString()),
            isThreeLine:true,
            trailing:PopupMenuButton<String>(
              onSelected:(v) async {
                if(v!='delete')return;
                final confirmed=await ask(context,'حذف الحركة','سيتم حذف الحركة وعكس تأثيرها على الكمية. متابعة؟');
                if(confirmed!=true||!mounted)return;
                try {
                  await StoreDb.instance.deleteMovement(e['id'] as int);
                  await load();
                  widget.changed();
                } catch(err) {
                  if(mounted)toast(context,err.toString().replaceFirst('Exception: ',''));
                }
              },
              itemBuilder:(_)=>const [PopupMenuItem<String>(value:'delete',child:Text('حذف الحركة'))],
            ),
          ));
        })),
    ]);
  }
}

class MovementDialog extends StatefulWidget {
  const MovementDialog({super.key,required this.kind,required this.products});final String kind;final List<Map<String,Object?>> products;
  @override State<MovementDialog> createState()=>_MovementDialogState();
}
class _MovementDialogState extends State<MovementDialog> {
  late Map<String,Object?> selected;late final TextEditingController qty,price,note;final form=GlobalKey<FormState>();
  List<Map<String,Object?>> parties=[]; Map<String,Object?>? selectedParty;
  @override void initState(){super.initState();selected=widget.products.first;qty=TextEditingController(text:'1');
    price=TextEditingController(text:(widget.kind=='sale'?selected['sell']:selected['buy']).toString());note=TextEditingController();loadParties();}
  Future<void> loadParties() async {final r=await StoreDb.instance.parties(widget.kind=='sale'?'customers':'suppliers');if(mounted)setState(()=>parties=r);}
  @override void dispose(){qty.dispose();price.dispose();note.dispose();super.dispose();}
  @override Widget build(BuildContext context) {
    final sale=widget.kind=='sale';
    return Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:Text(sale?'تسجيل بيع':'تسجيل شراء'),
      content:SizedBox(width:420,child:Form(key:form,child:Column(mainAxisSize:MainAxisSize.min,children:[
        DropdownButtonFormField<int>(value:selected['id'] as int,decoration:const InputDecoration(labelText:'المنتج'),
          items:widget.products.map((e)=>DropdownMenuItem<int>(value:e['id'] as int,child:Text(e['name'].toString()+' (المتاح '+e['qty'].toString()+')'))).toList(),
          onChanged:(id){final x=widget.products.firstWhere((e)=>e['id']==id);setState((){selected=x;price.text=(sale?x['sell']:x['buy']).toString();});}),
        if(parties.isNotEmpty) Padding(padding:const EdgeInsets.only(top:10),child:DropdownButtonFormField<int?>(value:selectedParty?['id'] as int?,decoration:InputDecoration(labelText:sale?'العميل (اختياري)':'المورد (اختياري)'),items:[const DropdownMenuItem<int?>(value:null,child:Text('بدون تحديد')), ...parties.map((e)=>DropdownMenuItem<int?>(value:e['id'] as int,child:Text(e['name'].toString())))],onChanged:(id)=>setState(()=>selectedParty=id==null?null:parties.firstWhere((e)=>e['id']==id)))),
        const SizedBox(height:10),TextFormField(controller:qty,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'الكمية'),
          validator:(v)=>int.tryParse(v??'')==null||int.parse(v!)<=0?'أدخل كمية صحيحة':null),
        const SizedBox(height:10),TextFormField(controller:price,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'سعر الوحدة'),
          validator:(v)=>double.tryParse(v??'')==null||double.parse(v!)<0?'أدخل سعراً صحيحاً':null),
        const SizedBox(height:10),TextFormField(controller:note,decoration:const InputDecoration(labelText:'ملاحظة اختيارية')),
        if(sale)Align(alignment:Alignment.centerRight,child:Text('المتاح حالياً: '+selected['qty'].toString())),
      ]))),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('إلغاء')),FilledButton(onPressed:() async {
        if(!form.currentState!.validate())return;
        try{await StoreDb.instance.addMovement(widget.kind,selected,int.parse(qty.text),double.parse(price.text),note.text.trim(),selectedParty);
          if(context.mounted)Navigator.pop(context,true);}
        catch(e){if(context.mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}
      },child:const Text('تأكيد'))]));
  }
}

class PartyPage extends StatefulWidget {
  const PartyPage({super.key,required this.table,required this.title,required this.changed});
  final String table,title; final VoidCallback changed;
  @override State<PartyPage> createState()=>_PartyPageState();
}
class _PartyPageState extends State<PartyPage> {
  List<Map<String,Object?>> rows=[]; final search=TextEditingController();
  @override void initState(){super.initState();load();}
  @override void dispose(){search.dispose();super.dispose();}
  Future<void> load() async {final r=await StoreDb.instance.parties(widget.table,search.text);if(mounted)setState(()=>rows=r);}
  Future<void> edit([Map<String,Object?>? item]) async {
    final name=TextEditingController(text:item?['name'] as String? ?? '');
    final phone=TextEditingController(text:item?['phone'] as String? ?? '');
    final email=TextEditingController(text:item?['email'] as String? ?? '');
    final address=TextEditingController(text:item?['address'] as String? ?? '');
    final notes=TextEditingController(text:item?['notes'] as String? ?? '');
    final balance=TextEditingController(text:(item?['balance']??0).toString());
    final ok=await showDialog<bool>(context:context,builder:(c)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(
      title:Text(item==null?'إضافة '+widget.title:'تعديل '+widget.title),
      content:SizedBox(width:420,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:name,decoration:const InputDecoration(labelText:'الاسم *')),
        TextField(controller:phone,decoration:const InputDecoration(labelText:'الهاتف')),
        TextField(controller:email,decoration:const InputDecoration(labelText:'البريد الإلكتروني')),
        TextField(controller:address,decoration:const InputDecoration(labelText:'العنوان')),
        TextField(controller:notes,decoration:const InputDecoration(labelText:'ملاحظات')),
        TextField(controller:balance,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'الرصيد الافتتاحي')),
      ]))),
      actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(c,name.text.trim().isNotEmpty),child:const Text('حفظ'))])));
    if(ok==true){await StoreDb.instance.saveParty(widget.table,{'name':name.text.trim(),'phone':phone.text.trim(),'email':email.text.trim(),'address':address.text.trim(),'notes':notes.text.trim(),'balance':double.tryParse(balance.text)??0},item?['id'] as int?);await load();widget.changed();}
    name.dispose();phone.dispose();email.dispose();address.dispose();notes.dispose();balance.dispose();
  }
  Future<void> remove(Map<String,Object?> e) async {if(await ask(context,'حذف','هل تريد حذف '+e['name'].toString()+'؟')==true){try{await StoreDb.instance.deleteParty(widget.table,e['id'] as int);await load();}catch(err){if(mounted)toast(context,err.toString().replaceFirst('Exception: ',''));}}}
  @override Widget build(BuildContext context)=>Column(children:[
    Padding(padding:const EdgeInsets.all(12),child:Row(children:[Expanded(child:TextField(controller:search,onChanged:(_)=>load(),decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'بحث'))),IconButton(tooltip:'طباعة القائمة',onPressed:()=>printTextReport(context,'قائمة ${widget.title}',rows.map((e)=>'${e['name']} | الهاتف: ${e['phone']} | البريد: ${e['email']} | العنوان: ${e['address']} | الرصيد الافتتاحي: ${money(e['balance'])}').toList()),icon:const Icon(Icons.print_outlined)),IconButton.filled(onPressed:()=>edit(),icon:const Icon(Icons.add))])),
    Expanded(child:rows.isEmpty?Center(child:Text('لا توجد بيانات في '+widget.title)):ListView.builder(itemCount:rows.length,itemBuilder:(c,i){final e=rows[i];return Card(child:ListTile(title:Text(e['name'] as String),subtitle:Text((e['phone']??'').toString()+' • '+(e['address']??'').toString()),leading:const Icon(Icons.person_outline),trailing:PopupMenuButton<String>(onSelected:(v)=>v=='edit'?edit(e):remove(e),itemBuilder:(_)=>const [PopupMenuItem(value:'edit',child:Text('تعديل')),PopupMenuItem(value:'delete',child:Text('حذف'))])));}))
  ]);
}
class WarehousePage extends StatefulWidget {const WarehousePage({super.key,required this.changed});final VoidCallback changed;@override State<WarehousePage> createState()=>_WarehousePageState();}
class _WarehousePageState extends State<WarehousePage> {
  List<Map<String,Object?>> rows=[];
  @override void initState(){super.initState();load();}
  Future<void> load() async {final r=await StoreDb.instance.parties('warehouses');if(mounted)setState(()=>rows=r);}
  Future<void> edit([Map<String,Object?>? e]) async {
    final name=TextEditingController(text:e?['name'] as String? ?? '');final loc=TextEditingController(text:e?['location'] as String? ?? '');
    final ok=await showDialog<bool>(context:context,builder:(c)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:const Text('بيانات المخزن'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:name,decoration:const InputDecoration(labelText:'اسم المخزن')),TextField(controller:loc,decoration:const InputDecoration(labelText:'الموقع'))]),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(c,name.text.trim().isNotEmpty),child:const Text('حفظ'))])));
    if(ok==true){await StoreDb.instance.saveParty('warehouses',{'name':name.text.trim(),'location':loc.text.trim(),'notes':''},e?['id'] as int?);await load();widget.changed();}name.dispose();loc.dispose();
  }
  @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(12),children:[Row(children:[const Expanded(child:Text('إدارة المخازن',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold))),IconButton(tooltip:'طباعة المخازن',onPressed:()=>printTextReport(context,'قائمة المخازن',rows.map((e)=>'${e['name']} | الموقع: ${e['location']}').toList()),icon:const Icon(Icons.print_outlined)),IconButton.filled(onPressed:()=>edit(),icon:const Icon(Icons.add))]),...rows.map((e)=>Card(child:ListTile(leading:const Icon(Icons.warehouse_outlined),title:Text(e['name'] as String),subtitle:Text(e['location'] as String? ?? ''),trailing:PopupMenuButton<String>(onSelected:(v)async{if(v=='edit'){await edit(e);}else if(await ask(context,'حذف المخزن','هل تريد حذف هذا المخزن؟')==true){try{await StoreDb.instance.deleteWarehouse(e['id'] as int);await load();}catch(err){if(mounted)toast(context,err.toString().replaceFirst('Exception: ',''));}}},itemBuilder:(_)=>const [PopupMenuItem(value:'edit',child:Text('تعديل')),PopupMenuItem(value:'delete',child:Text('حذف'))]))))]);
}
class ExpensePage extends StatefulWidget {const ExpensePage({super.key,required this.changed});final VoidCallback changed;@override State<ExpensePage> createState()=>_ExpensePageState();}
class _ExpensePageState extends State<ExpensePage> {
  List<Map<String,Object?>> rows=[];
  @override void initState(){super.initState();load();}
  Future<void> load() async {final r=await StoreDb.instance.expenses();if(mounted)setState(()=>rows=r);}
  Future<void> add() async {
    final title=TextEditingController(),cat=TextEditingController(text:'عام'),amount=TextEditingController(),note=TextEditingController();
    final ok=await showDialog<bool>(context:context,builder:(c)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:const Text('تسجيل مصروف'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:title,decoration:const InputDecoration(labelText:'البيان')),TextField(controller:cat,decoration:const InputDecoration(labelText:'التصنيف')),TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'المبلغ')),TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظات'))])),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('حفظ'))])));
    if(ok==true){try{await StoreDb.instance.addExpense(title.text,cat.text,double.tryParse(amount.text)??0,note.text);await load();widget.changed();}catch(e){if(mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}}
    title.dispose();cat.dispose();amount.dispose();note.dispose();
  }
  @override Widget build(BuildContext context)=>Column(children:[Card(child:ListTile(title:const Text('إجمالي المصروفات'),trailing:Text(money(rows.fold<double>(0,(a,e)=>a+(e['amount'] as num).toDouble())),style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold)))),Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Align(alignment:Alignment.centerRight,child:TextButton.icon(onPressed:()=>printTextReport(context,'تقرير المصروفات',rows.map((e)=>'${e['title']} | التصنيف: ${e['category']} | المبلغ: ${money(e['amount'])} | التاريخ: ${e['created_at']} | ${e['notes']}').toList()),icon:const Icon(Icons.print_outlined),label:const Text('طباعة المصروفات')))),Expanded(child:rows.isEmpty?const Center(child:Text('لا توجد مصروفات')):ListView.builder(itemCount:rows.length,itemBuilder:(c,i){final e=rows[i];return Card(child:ListTile(title:Text(e['title'] as String),subtitle:Text((e['category']??'').toString()+' • '+(e['notes']??'').toString()),trailing:Row(mainAxisSize:MainAxisSize.min,children:[Text(money(e['amount'])),IconButton(tooltip:'حذف المصروف',icon:const Icon(Icons.delete_outline),onPressed:()async{if(await ask(context,'حذف المصروف','هل تريد حذف هذا المصروف؟')==true){await StoreDb.instance.deleteExpense(e['id'] as int);await load();widget.changed();}})])));})),Padding(padding:const EdgeInsets.all(12),child:FilledButton.icon(onPressed:add,icon:const Icon(Icons.add),label:const Text('إضافة مصروف')))]);
}
class ReportsPage extends StatefulWidget {const ReportsPage({super.key});@override State<ReportsPage> createState()=>_ReportsPageState();}
class _ReportsPageState extends State<ReportsPage> {
  Map<String,Object?> data={};List<Map<String,Object?>> products=[];List<Map<String,Object?>> ops=[];
  @override void initState(){super.initState();load();}
  Future<void> load() async {final d=await StoreDb.instance.summary();final p=await StoreDb.instance.products();final o=await StoreDb.instance.movements();
    if(mounted) setState(() { data=d; products=p; ops=o; });}
  Widget tile(String title,String value,IconData icon)=>Card(child:ListTile(leading:Icon(icon),title:Text(title),trailing:Text(value,style:const TextStyle(fontWeight:FontWeight.bold))));
  @override Widget build(BuildContext context)=>RefreshIndicator(onRefresh:load,child:ListView(padding:const EdgeInsets.all(14),children:[
    const Text('التقارير والجرد',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),
    FilledButton.icon(onPressed:()=>printTextReport(context,'التقرير المالي وتقرير المخزون',[
      'تاريخ التقرير: ${DateTime.now().toLocal()}',
      'عدد المنتجات: ${data['count']??0}',
      'إجمالي الوحدات: ${data['qty']??0}',
      'قيمة المخزون: ${money(data['stock'])}',
      'إجمالي المبيعات: ${money(data['sales'])}',
      'إجمالي المشتريات: ${money(data['buys'])}',
      'الربح التقديري قبل المصروفات: ${money(data['profit'])}',
      'المصروفات: ${money(data['expense_total'])}',
      'الربح بعد المصروفات: ${money(((data['profit'] as num?)??0)-((data['expense_total'] as num?)??0))}',
      'صافي الحركة النقدية: ${money(((data['sales'] as num?)??0)-((data['buys'] as num?)??0))}',
      'تفاصيل المخزون:',
      ...products.map((e)=>'${e['name']} | الكمية: ${e['qty']} | تكلفة الوحدة: ${money(e['buy'])} | إجمالي التكلفة: ${money((e['qty'] as int)*(e['buy'] as num).toDouble())}'),
      'عدد الحركات المسجلة: ${ops.length}',
      ...ops.map((e)=>'${e['kind']=='sale'?'بيع':'شراء'} | ${e['product_name']} | ${e['qty']} × ${money(e['unit_price'])} | الإجمالي: ${money(e['total'])} | ${e['created_at']}')
    ]),icon:const Icon(Icons.print),label:const Text('طباعة التقرير الكامل')),
    tile('قيمة المخزون بسعر الشراء',money(data['stock']),Icons.warehouse_outlined),
    tile('إجمالي المبيعات',money(data['sales']),Icons.trending_up),
    tile('إجمالي المشتريات',money(data['buys']),Icons.shopping_bag_outlined),
    tile('الربح التقديري قبل المصروفات',money(data['profit']),Icons.auto_graph),
    tile('إجمالي المصروفات',money(data['expense_total']),Icons.payments_outlined),
    tile('الربح بعد المصروفات',money(((data['profit'] as num?)??0)-((data['expense_total'] as num?)??0)),Icons.account_balance),
    tile('صافي الحركة النقدية',money(((data['sales'] as num?)??0)-((data['buys'] as num?)??0)),Icons.account_balance),
    const SizedBox(height:10),const Text('الجرد الحالي',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
    ...products.map((e)=>ListTile(dense:true,title:Text(e['name'] as String),subtitle:Text('الكمية '+e['qty'].toString()+' • تكلفة الوحدة '+money(e['buy'])),
      trailing:Text(money((e['qty'] as int)*(e['buy'] as num).toDouble())))),
    const Divider(),Text('عدد الحركات المسجلة: '+ops.length.toString()),
  ]));
}


class WarehouseStockPage extends StatefulWidget {
  const WarehouseStockPage({super.key,required this.changed});
  final VoidCallback changed;
  @override State<WarehouseStockPage> createState()=>_WarehouseStockPageState();
}
class _WarehouseStockPageState extends State<WarehouseStockPage> {
  List<Map<String,Object?>> warehouses=[],products=[],transfers=[];
  int? selectedWarehouse;
  bool loading=true;
  @override void initState(){super.initState();load();}
  Future<void> load() async {
    final w=await StoreDb.instance.parties('warehouses');
    if(w.isEmpty){if(mounted)setState(()=>loading=false);return;}
    final id=selectedWarehouse??w.first['id'] as int;
    final p=await StoreDb.instance.warehouseStock(id);
    final t=await StoreDb.instance.warehouseTransfers();
    if(mounted)setState(() { warehouses=w; selectedWarehouse=id; products=p; transfers=t; loading=false; });
  }
  Future<void> transfer() async {
    if(warehouses.length<2){toast(context,'أضف مخزناً آخر أولاً.');return;}
    final available=products.where((e)=>(e['warehouse_qty'] as int)>0).toList();
    if(available.isEmpty){toast(context,'لا توجد كميات قابلة للتحويل في هذا المخزن.');return;}
    Map<String,Object?> product=available.first;
    int to=warehouses.firstWhere((e)=>e['id']!=selectedWarehouse)['id'] as int;
    final qty=TextEditingController(text:'1'),note=TextEditingController();
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setDialog)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:const Text('تحويل مخزون بين المخازن'),content:SizedBox(width:420,child:Column(mainAxisSize:MainAxisSize.min,children:[
      DropdownButtonFormField<int>(value:product['id'] as int,decoration:const InputDecoration(labelText:'المنتج'),items:available.map((e)=>DropdownMenuItem(value:e['id'] as int,child:Text('${e['name']} • متاح ${e['warehouse_qty']}'))).toList(),onChanged:(v)=>setDialog(()=>product=available.firstWhere((e)=>e['id']==v))),
      DropdownButtonFormField<int>(value:to,decoration:const InputDecoration(labelText:'إلى المخزن'),items:warehouses.where((e)=>e['id']!=selectedWarehouse).map((e)=>DropdownMenuItem(value:e['id'] as int,child:Text(e['name'].toString()))).toList(),onChanged:(v)=>setDialog(()=>to=v!)),
      TextField(controller:qty,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'الكمية')),
      TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظات')),
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('تنفيذ التحويل'))]))));
    if(ok==true){try{await StoreDb.instance.transferStock(productId:product['id'] as int,fromWarehouseId:selectedWarehouse!,toWarehouseId:to,qty:int.parse(qty.text),note:note.text.trim());await load();widget.changed();if(mounted)toast(context,'تم التحويل بنجاح.');}catch(e){if(mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}}
    qty.dispose();note.dispose();
  }
  @override Widget build(BuildContext context){
    if(loading)return const Center(child:CircularProgressIndicator());
    return RefreshIndicator(onRefresh:load,child:ListView(padding:const EdgeInsets.all(14),children:[
      Row(children:[const Expanded(child:Text('توزيع المخزون على المخازن',style:TextStyle(fontSize:21,fontWeight:FontWeight.bold))),FilledButton.icon(onPressed:transfer,icon:const Icon(Icons.swap_horiz),label:const Text('تحويل'))]),
      const SizedBox(height:10),
      DropdownButtonFormField<int>(value:selectedWarehouse,decoration:const InputDecoration(labelText:'اختر المخزن'),items:warehouses.map((e)=>DropdownMenuItem(value:e['id'] as int,child:Text(e['name'].toString()))).toList(),onChanged:(v){if(v!=null){setState(()=>selectedWarehouse=v);load();}}),
      const SizedBox(height:10),
      Card(child:Padding(padding:const EdgeInsets.all(12),child:Text('عدد الأصناف: ${products.length} • إجمالي الكميات في المخزن: ${products.fold<int>(0,(s,e)=>s+(e['warehouse_qty'] as int))}',style:const TextStyle(fontWeight:FontWeight.bold)))),
      ...products.map((e)=>Card(child:ListTile(leading:const Icon(Icons.inventory_2_outlined),title:Text(e['name'].toString()),subtitle:Text('كود: ${e['sku']} • إجمالي كل المخازن: ${e['total_qty']}'),trailing:Text((e['warehouse_qty'] as int).toString(),style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold))))),
      const SizedBox(height:14),const Text('آخر تحويلات المخزون',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
      ...transfers.take(30).map((e)=>ListTile(dense:true,leading:const Icon(Icons.swap_horiz),title:Text('${e['product_name']} • ${e['qty']} قطعة'),subtitle:Text('مخزن ${e['from_warehouse_id']} ← مخزن ${e['to_warehouse_id']} • ${e['created_at']}'))),
    ]));
  }
}


class PartyLedgerPage extends StatefulWidget {
  const PartyLedgerPage({super.key});
  @override State<PartyLedgerPage> createState()=>_PartyLedgerPageState();
}
class _PartyLedgerPageState extends State<PartyLedgerPage> {
  String type='customer';List<Map<String,Object?>> parties=[],entries=[];int? partyId;double balance=0;bool loading=true;
  @override void initState(){super.initState();load();}
  Future<void> load() async {
    final p=await StoreDb.instance.parties(type=='customer'?'customers':'suppliers');
    final id=p.any((e)=>e['id']==partyId)?partyId:(p.isEmpty?null:p.first['id'] as int);
    final l=id==null?<Map<String,Object?>>[]:await StoreDb.instance.partyLedger(type,id);
    final b=id==null?0.0:await StoreDb.instance.partyBalance(type,id);
    if(mounted)setState((){parties=p;partyId=id;entries=l;balance=b;loading=false;});
  }
  Future<void> addPayment() async {
    if(partyId==null){toast(context,'أضف عميلاً أو مورداً أولاً.');return;}
    final amount=TextEditingController(),note=TextEditingController();
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:Text(type=='customer'?'تسجيل تحصيل من العميل':'تسجيل سداد للمورد'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'المبلغ')),TextField(controller:note,decoration:const InputDecoration(labelText:'البيان'))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('حفظ الدفعة'))])));
    if(ok==true){try{await StoreDb.instance.recordPartyPayment(type:type,partyId:partyId!,amount:double.parse(amount.text),note:note.text.trim());await load();if(mounted)toast(context,'تم تسجيل الدفعة.');}catch(e){if(mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}}
    amount.dispose();note.dispose();
  }
  @override Widget build(BuildContext context){
    if(loading)return const Center(child:CircularProgressIndicator());
    return RefreshIndicator(onRefresh:load,child:ListView(padding:const EdgeInsets.all(14),children:[
      const Text('الحسابات والذمم المالية',style:TextStyle(fontSize:21,fontWeight:FontWeight.bold)),
      const SizedBox(height:10),
      SegmentedButton<String>(segments:const [ButtonSegment(value:'customer',label:Text('العملاء'),icon:Icon(Icons.people_alt_outlined)),ButtonSegment(value:'supplier',label:Text('الموردون'),icon:Icon(Icons.local_shipping_outlined))],selected:{type},onSelectionChanged:(v){setState((){type=v.first;loading=true;partyId=null;});load();}),
      const SizedBox(height:10),
      if(parties.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(18),child:Text('لا توجد بيانات لهذا النوع. أضف عميلاً أو مورداً أولاً.'))),
      if(parties.isNotEmpty)DropdownButtonFormField<int>(value:partyId,decoration:const InputDecoration(labelText:'اختر الحساب'),items:parties.map((e)=>DropdownMenuItem(value:e['id'] as int,child:Text(e['name'].toString()))).toList(),onChanged:(v){setState(()=>partyId=v);load();}),
      if(partyId!=null)Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(type=='customer'?'المبلغ المستحق على العميل':'المبلغ المستحق للمورد',style:const TextStyle(fontWeight:FontWeight.bold)),
        Text('الرصيد الافتتاحي: ${money(parties.firstWhere((e)=>e['id']==partyId)['balance'])}',style:TextStyle(fontSize:12,color:Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height:6),Text(money(balance),style:TextStyle(fontSize:25,fontWeight:FontWeight.w900,color:balance>0?Theme.of(context).colorScheme.error:Theme.of(context).colorScheme.primary)),
        const SizedBox(height:10),FilledButton.icon(onPressed:balance>0?addPayment:null,icon:const Icon(Icons.payments_outlined),label:Text(type=='customer'?'تسجيل تحصيل':'تسجيل سداد')),
      ]))),
      const Text('كشف الحساب',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
      ...entries.map((e)=>Card(child:ListTile(leading:Icon(e['entry_type']=='debit'?Icons.add_circle_outline:Icons.remove_circle_outline),title:Text((e['entry_type']=='debit'?'مستحق + ':'دفعة - ')+money(e['amount'])),subtitle:Text('${e['note']} • ${e['created_at']}'),trailing:Text(e['reference'].toString())))),
    ]));
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key,required this.dark,required this.toggle,required this.seedColor,required this.changeSeed,required this.appName,required this.changeAppName,required this.logoPath,required this.changeLogo,required this.backgroundPath,required this.changeBackground,required this.clearBackground});final bool dark;final VoidCallback toggle;final Color seedColor;final ValueChanged<int> changeSeed;final String appName;final ValueChanged<String> changeAppName;final String? logoPath;final VoidCallback changeLogo;final String? backgroundPath;final VoidCallback changeBackground,clearBackground;
  @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(14),children:[
    const Text('الإعدادات',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),
    Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('اسم النشاط التجاري / اسم الواجهة داخل التطبيق',style:TextStyle(fontWeight:FontWeight.bold)),
      const SizedBox(height:8),
      TextFormField(initialValue:appName,onFieldSubmitted:changeAppName,decoration:const InputDecoration(hintText:'اكتب الاسم ثم اضغط تم')),
      TextFormField(initialValue:currencyLabel,onFieldSubmitted:(v)async{await saveCurrency(v);if(context.mounted)toast(context,'تم حفظ العملة.');},decoration:const InputDecoration(labelText:'رمز العملة')),
      const Text('اسم وأيقونة المشغّل الخارجيان ثابتان في ملف التثبيت؛ تغييرهما يتطلب بناء نسخة جديدة.',style:TextStyle(fontSize:11,color:Colors.grey)),
      ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.image_outlined),title:const Text('تغيير الشعار داخل البرنامج'),subtitle:Text(logoPath==null?'لم يتم اختيار شعار بعد':'تم حفظ شعار مخصص على هذا الجهاز'),onTap:changeLogo)
    ]))),
    Card(child:Column(children:[ListTile(leading:const Icon(Icons.wallpaper_outlined),title:const Text('تغيير خلفية البرنامج'),subtitle:Text(backgroundPath==null?'لم يتم اختيار خلفية':'تم حفظ خلفية مخصصة على هذا الجهاز'),onTap:changeBackground),if(backgroundPath!=null) Align(alignment:Alignment.centerLeft,child:TextButton.icon(onPressed:clearBackground,icon:const Icon(Icons.delete_outline),label:const Text('إزالة الخلفية')))])),
    Card(child:SwitchListTile(secondary:const Icon(Icons.dark_mode_outlined),title:const Text('الوضع الليلي'),value:dark,onChanged:(_)=>toggle())),
    Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('لون واجهة البرنامج',style:TextStyle(fontWeight:FontWeight.bold)),
      const SizedBox(height:10),
      Wrap(spacing:10,runSpacing:8,children:[
        for(final c in [0xFF087F68,0xFF1565C0,0xFF6A1B9A,0xFFAD1457,0xFFEF6C00,0xFF455A64,0xFF3949AB])
          InkWell(onTap:()=>changeSeed(c),child:CircleAvatar(backgroundColor:Color(c),child:seedColor.value==c?const Icon(Icons.check,color:Colors.white):null))
      ])
    ]))),
    Card(child:ListTile(leading:const Icon(Icons.backup_outlined),title:const Text('تصدير نسخة احتياطية إلى ملف'),
      subtitle:const Text('حفظ جميع البيانات بصيغة JSON في المكان الذي تختاره'),
      onTap:() async {try{final path=await StoreDb.instance.exportBackup();if(context.mounted)toast(context,path==null?'تم إلغاء الحفظ.':'تم تصدير النسخة بنجاح.');}
        catch(e){if(context.mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}})),
    Card(child:ListTile(leading:const Icon(Icons.table_view_outlined),title:const Text('تصدير جرد المنتجات CSV'),subtitle:const Text('ملف يمكن فتحه في Excel أو برامج الجداول'),onTap:() async {try{final path=await StoreDb.instance.exportInventoryCsv();if(context.mounted)toast(context,path==null?'تم إلغاء التصدير.':'تم تصدير ملف الجرد.');}catch(e){if(context.mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}})),
    Card(child:ListTile(leading:const Icon(Icons.playlist_add_outlined),title:const Text('استيراد أصناف من CSV'),subtitle:const Text('إضافة مجموعة أصناف من ملف Excel محفوظ بصيغة CSV دون حذف الموجود'),onTap:() async {try{final count=await StoreDb.instance.importProductsCsv();if(context.mounted)toast(context,count==0?'لم تتم إضافة أصناف.':'تم استيراد '+count.toString()+' صنف.');}catch(e){if(context.mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}})),
    Card(child:ListTile(leading:const Icon(Icons.file_open_outlined),title:const Text('استيراد نسخة احتياطية من ملف'),
      subtitle:const Text('استعادة المنتجات والحركات والموردين والعملاء والمخازن والمصروفات'),
      onTap:() async {if(await ask(context,'استيراد البيانات','سيتم استبدال البيانات الحالية بمحتويات الملف. متابعة؟')!=true)return;
        try{await StoreDb.instance.importBackup();if(context.mounted)toast(context,'تم استيراد النسخة بنجاح. أعد فتح الصفحات لتحديث البيانات.');}
        catch(e){if(context.mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}})),
    Card(child:ListTile(
      leading:const CircleAvatar(child:Icon(Icons.system_update_alt)),
      title:const Text('تحديث البرنامج عبر الإنترنت'),
      subtitle:const Text('البحث عن تحديثات صغيرة وتنزيلها داخل التطبيق دون ملف APK عندما يكون التحديث متوافقاً.'),
      trailing:const Icon(Icons.chevron_left),
      onTap:()async{
        final updater=ShorebirdUpdater();
        if(!updater.isAvailable){toast(context,'التحديثات السحابية ستعمل بعد تثبيت أول إصدار مهيأ بنظام التحديث.');return;}
        try{
          final status=await updater.checkForUpdate();
          if(status==UpdateStatus.upToDate){if(context.mounted)toast(context,'أنت تستخدم أحدث تحديث متاح.');return;}
          if(status==UpdateStatus.restartRequired){if(context.mounted)toast(context,'تم تنزيل تحديث بالفعل. أغلق التطبيق وافتحه مرة أخرى لتطبيقه.');return;}
          if(status==UpdateStatus.unavailable){if(context.mounted)toast(context,'خدمة التحديث غير متاحة حالياً.');return;}
          final accepted=await showDialog<bool>(context:context,builder:(d)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(
            shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(22)),
            title:const Row(children:[Icon(Icons.system_update_alt),SizedBox(width:8),Text('تحديث جديد متاح')]),
            content:const Text('يوجد تحديث برمجي صغير متاح. سيتم تنزيله الآن، ثم يُطبّق عند إعادة فتح التطبيق. التحديثات التي تتطلب تغييراً في مكونات أندرويد أو الأذونات تحتاج إصدار APK جديداً.'),
            actions:[TextButton(onPressed:()=>Navigator.pop(d,false),child:const Text('لاحقاً')),FilledButton.icon(onPressed:()=>Navigator.pop(d,true),icon:const Icon(Icons.download),label:const Text('تنزيل التحديث'))]
          )));
          if(accepted==true){await updater.update();if(context.mounted)toast(context,'اكتمل تنزيل التحديث. أغلق التطبيق وافتحه لتطبيق النسخة الجديدة.');}
        }catch(e){if(context.mounted)toast(context,'تعذر التحقق من التحديث: ${e.toString().replaceFirst('Exception: ','')}');}
      }
    )),
    const Card(child:ListTile(leading:Icon(Icons.offline_bolt_outlined),title:Text('يعمل دون إنترنت'),
      subtitle:Text('البيانات محفوظة محلياً باستخدام SQLite. لا يحتاج التطبيق إلى حساب أو خادم.'))),
    const Card(child:ListTile(leading:Icon(Icons.info_outline),title:Text('MY APP — إصدار 3.8.0'),
      subtitle:Text('بحث بالاسم والكود والصورة، قارئ QR وباركود بالكاميرا والصور، حاسبة، تصنيفات، مفضلة، أرشيف، سجل أسعار ونسخ احتياطي شامل.'))),
  ]);
}


Future<void> printTextReport(BuildContext context,String title,List<String> lines) async {
  try {
    const double w=1240,h=1754,pad=64;
    final images=<Uint8List>[];
    ui.PictureRecorder? recorder;
    ui.Canvas? canvas;
    double y=0;
    void beginPage() {
      recorder=ui.PictureRecorder();
      canvas=ui.Canvas(recorder!);
      canvas!.drawRect(const ui.Rect.fromLTWH(0,0,w,h),ui.Paint()..color=const ui.Color(0xFFF4F8F6));
      canvas!.drawRRect(ui.RRect.fromRectAndRadius(const ui.Rect.fromLTWH(28,28,w-56,h-56),const ui.Radius.circular(34)),ui.Paint()..color=const ui.Color(0xFFFFFFFF));
      canvas!.drawRRect(ui.RRect.fromRectAndRadius(const ui.Rect.fromLTWH(28,28,w-56,190),const ui.Radius.circular(34)),ui.Paint()..color=const ui.Color(0xFF087F68));
      canvas!.drawRect(const ui.Rect.fromLTWH(28,150,w-56,218),ui.Paint()..color=const ui.Color(0xFF087F68));
      final heading=TextPainter(text:TextSpan(text:title,style:const TextStyle(fontSize:42,fontWeight:FontWeight.bold,color:Color(0xFFFFFFFF))),textDirection:TextDirection.rtl,textAlign:TextAlign.right);
      heading.layout(maxWidth:w-2*pad);
      heading.paint(canvas!,Offset(pad,pad));
      final date=TextPainter(text:TextSpan(text:'تاريخ الطباعة: ${DateTime.now().toLocal().toString().substring(0,16)}',style:const TextStyle(fontSize:22,color:Color(0xFFE2F4EF))),textDirection:TextDirection.rtl,textAlign:TextAlign.right);
      date.layout(maxWidth:w-2*pad);date.paint(canvas!,Offset(pad,pad+heading.height+18));
      y=pad+heading.height+date.height+65;
    }
    Future<void> finishPage() async {
      final picture=recorder!.endRecording();
      final image=await picture.toImage(w.toInt(),h.toInt());
      final bytes=await image.toByteData(format:ui.ImageByteFormat.png);
      if(bytes!=null) images.add(bytes.buffer.asUint8List());
      image.dispose();
    }
    beginPage();
    for(final line in lines) {
      final painter=TextPainter(text:TextSpan(text:line,style:const TextStyle(fontSize:27,color:Color(0xFF161616))),textDirection:TextDirection.rtl,textAlign:TextAlign.right);
      painter.layout(maxWidth:w-2*pad);
      if(y+painter.height+24>h-pad) { await finishPage(); beginPage(); }
      canvas!.drawRRect(ui.RRect.fromRectAndRadius(ui.Rect.fromLTWH(pad-8,y-7,w-2*pad+16,painter.height+18),const ui.Radius.circular(12)),ui.Paint()..color=const ui.Color(0xFFF0F6F3));
      painter.paint(canvas!,Offset(pad,y));
      y+=painter.height+28;
    }
    await finishPage();
    final document=pw.Document();
    for(final bytes in images) {
      document.addPage(pw.Page(pageFormat:pdf.PdfPageFormat.a4,margin:pw.EdgeInsets.zero,build:(_)=>pw.Image(pw.MemoryImage(bytes),fit:pw.BoxFit.fill)));
    }
    await Printing.layoutPdf(name:'MYAPP_Report.pdf',onLayout:(_)=>document.save());
  } catch(e) {
    if(context.mounted) toast(context,'تعذر تجهيز الطباعة: $e');
  }
}

Future<void> saveCurrency(String value) async {final v=value.trim().isEmpty?'ج.م':value.trim();final prefs=await SharedPreferences.getInstance();await prefs.setString('currencyLabel',v);currencyLabel=v;}
String money(Object? value)=>((value as num?)??0).toStringAsFixed(2)+' '+currencyLabel;
Future<bool?> ask(BuildContext context,String title,String body)=>showDialog<bool>(context:context,builder:(c)=>Directionality(textDirection:TextDirection.rtl,
  child:AlertDialog(title:Text(title),content:Text(body),actions:[
    TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),
    FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('تأكيد'))])));
void toast(BuildContext context,String text)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(text),duration:const Duration(seconds:5)));

class ShortagesPage extends StatefulWidget {const ShortagesPage({super.key});@override State<ShortagesPage> createState()=>_ShortagesPageState();}
class _ShortagesPageState extends State<ShortagesPage>{
 List<Map<String,Object?>> rows=[];bool loading=true;
 @override void initState(){super.initState();load();}
 Future<void> load()async{if(mounted)setState(()=>loading=true);final r=await StoreDb.instance.shortageGroups();if(mounted)setState((){rows=r;loading=false;});}
 @override Widget build(BuildContext context){
  final groups=<String,List<Map<String,Object?>>>{};for(final e in rows){final k=(e['supplier_name']??'بدون مورد').toString();(groups[k]??=[]).add(e);}
  return RefreshIndicator(onRefresh:load,child:ListView(padding:const EdgeInsets.all(14),children:[
   Container(padding:const EdgeInsets.all(18),decoration:BoxDecoration(gradient:LinearGradient(colors:[Theme.of(context).colorScheme.primary,Theme.of(context).colorScheme.tertiary]),borderRadius:BorderRadius.circular(22)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    const Row(children:[Icon(Icons.warning_amber_rounded,color:Colors.white,size:28),SizedBox(width:8),Text('كشف النواقص',style:TextStyle(color:Colors.white,fontSize:22,fontWeight:FontWeight.w900))]),
    const SizedBox(height:8),Text('المنتجات التي وصلت إلى حد التنبيه أو أقل، مجمعة حسب المورد',style:TextStyle(color:Colors.white.withOpacity(.9))),
    const SizedBox(height:12),Text('عدد المنتجات الناقصة: ${rows.length}',style:const TextStyle(color:Colors.white,fontSize:17,fontWeight:FontWeight.bold))
   ])),
   const SizedBox(height:10),
   if(loading)const Center(child:Padding(padding:EdgeInsets.all(28),child:CircularProgressIndicator())),
   if(!loading&&rows.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(24),child:Column(children:[Icon(Icons.inventory_2_outlined,size:42),SizedBox(height:8),Text('لا توجد نواقص حالياً',style:TextStyle(fontWeight:FontWeight.bold)),Text('تظهر هنا المنتجات التي لها مبيعات ووصل رصيدها إلى حد التنبيه أو أقل.')]))),
   ...groups.entries.map((g){final sold=g.value.fold<int>(0,(v,e)=>v+(e['sold_qty'] as int));return Card(clipBehavior:Clip.antiAlias,child:ExpansionTile(leading:CircleAvatar(child:Icon(g.key=='بدون مورد'?Icons.help_outline:Icons.local_shipping_outlined)),title:Text(g.key,style:const TextStyle(fontWeight:FontWeight.w900)),subtitle:Text('${g.value.length} منتج ناقص • إجمالي المباع: $sold'),children:g.value.map((e){final qty=e['qty'] as int,min=e['min_qty'] as int,soldQty=e['sold_qty'] as int;return ListTile(leading:const Icon(Icons.inventory_2_outlined),title:Text(e['product_name'].toString(),style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('مباع: $soldQty • المتبقي: $qty ${e['unit']} • حد التنبيه: $min\nالمطلوب للوصول لحد التنبيه: ${math.max(min-qty,0)}'),isThreeLine:true,trailing:Text('كود ${e['sku']}',style:Theme.of(context).textTheme.labelSmall));}).toList()));})
  ]));
 }
}
