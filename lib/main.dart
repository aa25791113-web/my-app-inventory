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
    database = await openDatabase(p.join(dir.path, 'my_app.sqlite'), version: 7,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE products(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,category TEXT NOT NULL DEFAULT "",qty INTEGER NOT NULL DEFAULT 0,min_qty INTEGER NOT NULL DEFAULT 0,buy REAL NOT NULL DEFAULT 0,sell REAL NOT NULL DEFAULT 0,sku TEXT NOT NULL DEFAULT "",manufacturer TEXT NOT NULL DEFAULT "",part_no TEXT NOT NULL DEFAULT "",alt_part_no TEXT NOT NULL DEFAULT "",location TEXT NOT NULL DEFAULT "",description TEXT NOT NULL DEFAULT "",archived INTEGER NOT NULL DEFAULT 0,wholesale REAL NOT NULL DEFAULT 0,brand TEXT NOT NULL DEFAULT "",unit TEXT NOT NULL DEFAULT "قطعة",country TEXT NOT NULL DEFAULT "",alt_names TEXT NOT NULL DEFAULT "",specs TEXT NOT NULL DEFAULT "",image_path TEXT NOT NULL DEFAULT "",supplier_id INTEGER)');
        await db.execute('CREATE TABLE operations(id INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,product_id INTEGER NOT NULL,product_name TEXT NOT NULL,qty INTEGER NOT NULL,unit_price REAL NOT NULL,total REAL NOT NULL,note TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL,cost_price REAL NOT NULL DEFAULT 0,party_id INTEGER,party_name TEXT NOT NULL DEFAULT "",warehouse_id INTEGER NOT NULL DEFAULT 1)');
        await _createExtendedTables(db);
        await _createProductHistory(db);
        await _backfillProductCodes(db);
        await _createSmartTables(db);
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
        if(oldVersion<7){await _upgradeProductColumns(db);await _createSmartTables(db);}
      });
  }

  Future<void> _upgradeProductColumns(DatabaseExecutor db) async {
    final cols=await db.rawQuery('PRAGMA table_info(products)');
    final names=cols.map((e)=>e['name']).toSet();
    final definitions=<String,String>{
      'wholesale':'REAL NOT NULL DEFAULT 0','brand':'TEXT NOT NULL DEFAULT ""',
      'unit':'TEXT NOT NULL DEFAULT "قطعة"','country':'TEXT NOT NULL DEFAULT ""',
      'alt_names':'TEXT NOT NULL DEFAULT ""','specs':'TEXT NOT NULL DEFAULT ""',
      'image_path':'TEXT NOT NULL DEFAULT ""','supplier_id':'INTEGER'
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
  Future<void> saveTask(String title) async {if(title.trim().isNotEmpty)await database!.insert('tasks',{'title':title.trim(),'done':0,'created_at':DateTime.now().toIso8601String()});}
  Future<List<Map<String,Object?>>> tasks()=>database!.query('tasks',orderBy:'done, id DESC');
  Future<void> toggleTask(int id,bool done) async {await database!.update('tasks',{'done':done?1:0},where:'id=?',whereArgs:[id]);}
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
  }
  Future<List<Map<String,Object?>>> parties(String table,[String query='']) => database!.query(table,where:query.trim().isEmpty?null:'name LIKE ?',whereArgs:query.trim().isEmpty?null:['%$query%'],orderBy:'name');
  Future<void> saveParty(String table,Map<String,Object?> data,int? id) async { if(id==null){await database!.insert(table,data);}else{await database!.update(table,data,where:'id=?',whereArgs:[id]);} await log('تعديل بيانات',table); }
  Future<void> deleteParty(String table,int id) async { await database!.delete(table,where:'id=?',whereArgs:[id]); }
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
      await txn.update('products',{'qty':newQty},where:'id=?',whereArgs:[product['id']]);
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
    final source=img.decodeImage(queryBytes);if(source==null)return [];
    final query=img.grayscale(img.copyResize(source,width:8,height:8));
    final qValues=<double>[];for(var y=0;y<8;y++){for(var x=0;x<8;x++){qValues.add(query.getPixel(x,y).r.toDouble());}}
    final avg=qValues.reduce((a,b)=>a+b)/qValues.length;final qBits=qValues.map((v)=>v>=avg).toList();
    final rows=await database!.query('products',where:'image_path<>"" AND archived=0');
    final ranked=<Map<String,Object?>>[];
    for(final row in rows){try{final path=row['image_path'] as String;final file=File(path);if(!await file.exists())continue;final decoded=img.decodeImage(await file.readAsBytes());if(decoded==null)continue;final tiny=img.grayscale(img.copyResize(decoded,width:8,height:8));final values=<double>[];for(var y=0;y<8;y++){for(var x=0;x<8;x++){values.add(tiny.getPixel(x,y).r.toDouble());}}final threshold=values.reduce((a,b)=>a+b)/values.length;var distance=0;for(var i=0;i<64;i++){if((values[i]>=threshold)!=qBits[i])distance++;}ranked.add({...row,'similarity':(64-distance)/64});}catch(_){continue;}}
    ranked.sort((a,b)=>(b['similarity'] as double).compareTo(a['similarity'] as double));return ranked.take(12).toList();
  }

  Future<void> saveProduct(Map<String,Object?> data, int? id) async {
    final v=Map<String,Object?>.from(data);
    if(id==null){final requested=(v['sku']??'').toString().trim().toUpperCase();if(requested.isEmpty){v['sku']=await generateUniqueSku();}else{final exists=await database!.query('products',columns:['id'],where:'sku=?',whereArgs:[requested],limit:1);if(exists.isNotEmpty)throw Exception('هذا الكود مستخدم بالفعل.');v['sku']=requested;}await database!.insert('products',v);return;}
    final rows=await database!.query('products',where:'id=?',whereArgs:[id],limit:1);if(rows.isEmpty)throw Exception('المنتج غير موجود.');
    final old=rows.first;final requested=(v['sku']??'').toString().trim().toUpperCase();if(requested.isEmpty||requested==old['sku']){v['sku']=old['sku'];}else{final exists=await database!.query('products',columns:['id'],where:'sku=? AND id<>?',whereArgs:[requested,id],limit:1);if(exists.isNotEmpty)throw Exception('هذا الكود مستخدم بالفعل.');v['sku']=requested;}final ob=(old['buy'] as num).toDouble(),os=(old['sell'] as num).toDouble(),nb=(v['buy'] as num).toDouble(),ns=(v['sell'] as num).toDouble();
    if(ob!=nb||os!=ns)await database!.insert('price_history',{'product_id':id,'product_name':old['name'],'old_buy':ob,'new_buy':nb,'old_sell':os,'new_sell':ns,'reason':'تعديل السعر','created_at':DateTime.now().toIso8601String()});
    await database!.update('products',v,where:'id=?',whereArgs:[id]);
  }
  Future<void> removeProduct(int id) async {
    final count = Sqflite.firstIntValue(await database!.rawQuery('SELECT COUNT(*) FROM operations WHERE product_id=?',[id])) ?? 0;
    if (count > 0) throw Exception('لا يمكن حذف منتج مرتبط بحركات سابقة.');
    await database!.delete('products',where:'id=?',whereArgs:[id]);
  }
  Future<void> addMovement(String kind, Map<String,Object?> product, int qty, double price, String note, [Map<String,Object?>? party]) async {
    if (qty <= 0 || price < 0) throw Exception('تحقق من الكمية والسعر.');
    await database!.transaction((txn) async {
      final current = product['qty'] as int;
      if (kind == 'sale' && current < qty) throw Exception('الكمية المتاحة لا تكفي.');
      final next = kind == 'sale' ? current - qty : current + qty;
      await txn.update('products', {'qty':next},where:'id=?',whereArgs:[product['id']]);
      await txn.insert('operations', {
        'kind':kind,'product_id':product['id'],'product_name':product['name'],
        'qty':qty,'unit_price':price,'total':qty*price,'note':note,
        'created_at':DateTime.now().toIso8601String(),
        'cost_price':(product['buy'] as num).toDouble(),
        'party_id':party?['id'],'party_name':party?['name'] ?? '','warehouse_id':1,
      });
      await txn.insert('activity_log',{'action':kind=='sale'?'تسجيل بيع':'تسجيل شراء','details':product['name'].toString()+' | كمية: '+qty.toString()+' | إجمالي: '+(qty*price).toString(),'created_at':DateTime.now().toIso8601String()});
    });
  }
  Future<List<Map<String,Object?>>> movements([String? kind]) => database!.query('operations',
    where:kind == null ? null : 'kind=?',whereArgs:kind == null ? null : [kind],orderBy:'id DESC');
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
    return {'format':'MYAPP_BACKUP_3','products':products,'operations':await database!.query('operations'),'suppliers':await database!.query('suppliers'),'customers':await database!.query('customers'),'warehouses':await database!.query('warehouses'),'expenses':await database!.query('expenses'),'stock_adjustments':await database!.query('stock_adjustments'),'price_history':await database!.query('price_history'),'categories':await database!.query('categories'),'favorites':await database!.query('favorites'),'recent_searches':await database!.query('recent_searches'),'activity_log':await database!.query('activity_log'),'tasks':await database!.query('tasks'),'product_notes':await database!.query('product_notes'),'product_images':await database!.query('product_images'),'image_blobs':blobs};
  }
  Future<Map<int,String>> _restoreImageBlobs(Map<String,dynamic> data) async {
    final result=<int,String>{};final blobs=data['image_blobs'] as List? ?? [];if(blobs.isEmpty)return result;
    final dir=await getApplicationSupportDirectory();final imageDir=Directory(p.join(dir.path,'product_images'));await imageDir.create(recursive:true);
    for(final item in blobs){try{final row=Map<String,Object?>.from(item as Map);final id=row['product_id'] as int;final name=(row['name']??'product.jpg').toString();final ext=p.extension(name).isEmpty?'.jpg':p.extension(name);final file=File(p.join(imageDir.path,'product_'+id.toString()+ext));await file.writeAsBytes(base64Decode(row['data'] as String),flush:true);result[id]=file.path;}catch(_){}}
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
      for(final t in ['product_images','product_notes','tasks','activity_log','recent_searches','favorites','categories','price_history','stock_adjustments','expenses','operations','products','suppliers','customers','warehouses']){await txn.delete(t);}
      for(final row in data['products'] as List){final product=Map<String,Object?>.from(row as Map);final id=product['id'] as int?;if(id!=null&&restoredImages.containsKey(id))product['image_path']=restoredImages[id];await txn.insert('products',product);}
      for(final row in data['operations'] as List){final m=Map<String,Object?>.from(row as Map);m.putIfAbsent('cost_price',()=>0.0);m.putIfAbsent('party_id',()=>null);m.putIfAbsent('party_name',()=> '');m.putIfAbsent('warehouse_id',()=>1);await txn.insert('operations',m);}
      for(final table in ['suppliers','customers','warehouses','expenses','stock_adjustments','price_history','categories','favorites','recent_searches','activity_log','tasks','product_notes','product_images']){for(final row in (data[table] as List? ?? [])){await txn.insert(table,Map<String,Object?>.from(row as Map));}}
      final wh=await txn.rawQuery('SELECT COUNT(*) AS c FROM warehouses');if((wh.first['c'] as int? ?? 0)==0)await txn.insert('warehouses',{'name':'المخزن الرئيسي','location':'','notes':''});
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
      for(final t in ['product_images','product_notes','tasks','activity_log','recent_searches','favorites','categories','price_history','stock_adjustments','expenses','operations','products','suppliers','customers','warehouses']) { await txn.delete(t); }
      for (final row in data['products'] as List) {
        final product=Map<String,Object?>.from(row as Map);final id=product['id'] as int?;if(id!=null&&restoredImages.containsKey(id))product['image_path']=restoredImages[id];await txn.insert('products',product);
      }
      for (final row in data['operations'] as List) {
        final m=Map<String,Object?>.from(row as Map);
        m.putIfAbsent('cost_price',()=>0.0);m.putIfAbsent('party_id',()=>null);m.putIfAbsent('party_name',()=> '');m.putIfAbsent('warehouse_id',()=>1);
        await txn.insert('operations',m);
      }
      for(final table in ['suppliers','customers','warehouses','expenses','stock_adjustments','price_history','categories','favorites','recent_searches','activity_log','tasks','product_notes','product_images']) {
        for(final row in (data[table] as List? ?? [])) { await txn.insert(table,Map<String,Object?>.from(row as Map)); }
      }
      final wh=await txn.rawQuery('SELECT COUNT(*) AS c FROM warehouses');
      if((wh.first['c'] as int? ?? 0)==0) await txn.insert('warehouses',{'name':'المخزن الرئيسي','location':'','notes':''});
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
  ThemeData makeTheme(Brightness b)=>ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:seedColor,brightness:b));
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
    ];
    const labels=['الرئيسية','المنتجات','المبيعات','المشتريات','الموردون','العملاء','المخازن','المصروفات','التقارير','الإعدادات','بحث الأسعار','التصنيفات','الأدوات الذكية'];
    const icons=[Icons.dashboard_outlined,Icons.inventory_2_outlined,Icons.point_of_sale,Icons.shopping_cart_outlined,Icons.local_shipping_outlined,Icons.people_alt_outlined,Icons.warehouse_outlined,Icons.payments_outlined,Icons.analytics_outlined,Icons.settings_outlined,Icons.search,Icons.category_outlined,Icons.auto_awesome];
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
        const Text('إدارة المخزون دون إنترنت',style:TextStyle(fontSize:11))])),
      body:Stack(children:[
        if(widget.backgroundPath!=null&&File(widget.backgroundPath!).existsSync()) Positioned.fill(child:Image.file(File(widget.backgroundPath!),fit:BoxFit.cover,errorBuilder:(c,e,st)=>const SizedBox.shrink())),
        IndexedStack(index:tab,children:pages)
      ]),
      bottomNavigationBar:NavigationBar(selectedIndex:tab==10?0:tab==1?1:tab==0?2:tab==8?3:tab==12?4:0,onDestinationSelected:(v)=>setState(()=>tab=[10,1,0,8,12][v]),
        destinations:const [
          NavigationDestination(icon:Icon(Icons.search),label:'بحث الأسعار'),
          NavigationDestination(icon:Icon(Icons.inventory_2_outlined),label:'المنتجات'),
          NavigationDestination(icon:Icon(Icons.dashboard_outlined),label:'الرئيسية'),
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
  Future<void> search(String value) async {final r=await StoreDb.instance.products(value);if(mounted)setState(()=>rows=r);}
  Future<void> imageSearch(ImageSource source) async {
    try{final file=await picker.pickImage(source:source,imageQuality:80,maxWidth:1200);if(file==null)return;setState(()=>searchingImage=true);final matches=await StoreDb.instance.similarProducts(await File(file.path).readAsBytes());if(mounted)setState(()=>rows=matches);if(mounted&&matches.isEmpty)toast(context,'لم نعثر على صور منتجات محفوظة للمقارنة.');}
    catch(e){if(mounted)toast(context,'تعذر تنفيذ البحث بالصورة: $e');}finally{if(mounted)setState(()=>searchingImage=false);}
  }
  Future<void> scanCode() async {
    if(!Platform.isAndroid&&!Platform.isIOS){toast(context,'مسح الكاميرا متاح على الهاتف فقط.');return;}
    await showDialog(context:context,builder:(ctx)=>Dialog(child:SizedBox(width:360,height:460,child:Column(children:[const Padding(padding:EdgeInsets.all(12),child:Text('وجّه الكاميرا نحو QR أو الباركود')),Expanded(child:MobileScanner(onDetect:(capture){final value=capture.barcodes.isEmpty?null:capture.barcodes.first.rawValue;if(value==null||value.isEmpty)return;Navigator.pop(ctx);controller.text=value;search(value);})),TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إغلاق'))]))));
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
        OutlinedButton.icon(onPressed:()=>showQr(ctx,p['sku'].toString(),p['name'].toString()),icon:const Icon(Icons.qr_code),label:const Text('QR'))
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
        OutlinedButton.icon(onPressed:scanCode,icon:const Icon(Icons.qr_code_scanner),label:const Text('مسح كود')),
        OutlinedButton.icon(onPressed:()=>imageSearch(ImageSource.gallery),icon:const Icon(Icons.image_search),label:const Text('بحث بصورة')),
        OutlinedButton.icon(onPressed:()=>imageSearch(ImageSource.camera),icon:const Icon(Icons.camera_alt),label:const Text('تصوير')),
      ]),
      if(searchingImage)const LinearProgressIndicator()
    ]))),
    if(rows.isEmpty)const Padding(padding:EdgeInsets.all(28),child:Center(child:Text('ابدأ بكتابة اسم المنتج أو كوده للعثور على سعره.')))
    else ...rows.map((p)=>Card(child:ListTile(onTap:()=>details(p),leading:(p['image_path']??'').toString().isNotEmpty&&File(p['image_path'] as String).existsSync()?ClipRRect(borderRadius:BorderRadius.circular(8),child:Image.file(File(p['image_path'] as String),width:54,height:54,fit:BoxFit.cover)):const CircleAvatar(child:Icon(Icons.inventory_2)),title:Text(p['name'].toString(),style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text('الكود: '+p['sku'].toString()+' • المتاح: '+p['qty'].toString()),trailing:Text(money(p['sell']),style:const TextStyle(fontWeight:FontWeight.w900,fontSize:16))))),
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
 @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(12),children:[Row(children:[const Expanded(child:Text('تصنيفات الأصناف',style:TextStyle(fontSize:21,fontWeight:FontWeight.bold))),IconButton.filled(onPressed:()=>edit(),icon:const Icon(Icons.add))]),if(rows.isEmpty)const Text('لم تتم إضافة تصنيفات بعد.')else ...rows.map((e)=>Card(child:ListTile(leading:const Icon(Icons.category_outlined),title:Text(e['name'].toString()),subtitle:Text(e['description'].toString()),trailing:IconButton(onPressed:()=>edit(e),icon:const Icon(Icons.edit)))))]);}
 
class SmartToolsPage extends StatefulWidget {const SmartToolsPage({super.key});@override State<SmartToolsPage> createState()=>_SmartToolsPageState();}
class _SmartToolsPageState extends State<SmartToolsPage>{
 int section=0;List<Map<String,Object?>> rows=[];final task=TextEditingController();final bulkValue=TextEditingController();bool bulkPercent=true;
 @override void initState(){super.initState();load();}@override void dispose(){task.dispose();bulkValue.dispose();super.dispose();}
 Future<void> load()async{List<Map<String,Object?>> r=[];if(section==0)r=await StoreDb.instance.favoriteProducts();if(section==1)r=await StoreDb.instance.tasks();if(section==2)r=await StoreDb.instance.activity();if(section==3)r=await StoreDb.instance.recentSearches();if(section==4)r=await StoreDb.instance.archivedProducts();if(section==5)r=await StoreDb.instance.productsWithoutImages();if(section==6)r=await StoreDb.instance.productsWithoutPrices();if(section==7)r=await StoreDb.instance.possibleDuplicates();if(mounted)setState(()=>rows=r);}
 @override Widget build(BuildContext context)=>Column(children:[
  Padding(padding:const EdgeInsets.all(10),child:Wrap(spacing:6,children:[ChoiceChip(label:const Text('المفضلة'),selected:section==0,onSelected:(_){setState(()=>section=0);load();}),ChoiceChip(label:const Text('المهام'),selected:section==1,onSelected:(_){setState(()=>section=1);load();}),ChoiceChip(label:const Text('النشاط'),selected:section==2,onSelected:(_){setState(()=>section=2);load();}),ChoiceChip(label:const Text('عمليات البحث'),selected:section==3,onSelected:(_){setState(()=>section=3);load();}),ChoiceChip(label:const Text('الأرشيف'),selected:section==4,onSelected:(_){setState(()=>section=4);load();}),ChoiceChip(label:const Text('بدون صور'),selected:section==5,onSelected:(_){setState(()=>section=5);load();}),ChoiceChip(label:const Text('بدون سعر'),selected:section==6,onSelected:(_){setState(()=>section=6);load();}),ChoiceChip(label:const Text('التكرارات'),selected:section==7,onSelected:(_){setState(()=>section=7);load();}),ChoiceChip(label:const Text('تعديل أسعار جماعي'),selected:section==8,onSelected:(_){setState(()=>section=8);load();})])),
  if(section==1)Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Row(children:[Expanded(child:TextField(controller:task,decoration:const InputDecoration(hintText:'مهمة جديدة'))),IconButton.filled(onPressed:()async{await StoreDb.instance.saveTask(task.text);task.clear();await load();},icon:const Icon(Icons.add))])),
  Expanded(child:section==8?ListView(padding:const EdgeInsets.all(14),children:[const Text('تعديل سعر البيع لمجموعة المنتجات',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),const SizedBox(height:12),SegmentedButton<bool>(segments:const [ButtonSegment(value:true,label:Text('نسبة مئوية')),ButtonSegment(value:false,label:Text('مبلغ ثابت'))],selected:{bulkPercent},onSelectionChanged:(v)=>setState(()=>bulkPercent=v.first)),TextField(controller:bulkValue,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'قيمة الزيادة',hintText:'مثال: 5')),const SizedBox(height:12),FilledButton.icon(onPressed:()async{final v=double.tryParse(bulkValue.text);if(v==null||v<0){toast(context,'أدخل قيمة صحيحة.');return;}await StoreDb.instance.bulkAdjustSellingPrices(v,bulkPercent,'تعديل جماعي من الأدوات');bulkValue.clear();toast(context,'تم تحديث الأسعار وتسجيل السعر السابق لكل منتج.');await load();},icon:const Icon(Icons.price_change),label:const Text('تطبيق على جميع المنتجات'))]):rows.isEmpty?const Center(child:Text('لا توجد بيانات هنا بعد.')):ListView.builder(itemCount:rows.length,itemBuilder:(c,i){final e=rows[i];if(section==0)return Card(child:ListTile(title:Text(e['name'].toString()),subtitle:Text('الكود: '+e['sku'].toString()+' • '+money(e['sell']))));if(section==1)return CheckboxListTile(value:e['done']==1,title:Text(e['title'].toString()),onChanged:(v)async{await StoreDb.instance.toggleTask(e['id'] as int,v==true);await load();});if(section==2)return ListTile(leading:const Icon(Icons.history),title:Text(e['action'].toString()),subtitle:Text(e['details'].toString()),trailing:Text((e['created_at']??'').toString().split('T').first));if(section==3)return ListTile(leading:const Icon(Icons.search),title:Text(e['query'].toString()),subtitle:Text((e['created_at']??'').toString()));if(section==7)return ListTile(leading:const Icon(Icons.copy_all),title:Text(e['name'].toString()),trailing:Text('عدد النسخ: '+e['amount'].toString()));return ListTile(leading:Icon(section==4?Icons.archive:section==5?Icons.image_not_supported:Icons.price_change),title:Text(e['name'].toString()),subtitle:Text('الكود: '+(e['sku']??'').toString()+' • السعر: '+money(e['sell'])),trailing:section==4?IconButton(tooltip:'استعادة',icon:const Icon(Icons.unarchive),onPressed:()async{await StoreDb.instance.setArchived(e['id'] as int,false);await load();}):null);}))
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
  Widget stat(String label,String value,IconData icon)=>Expanded(child:Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(children:[
    Icon(icon),const SizedBox(height:5),Text(value,style:const TextStyle(fontSize:19,fontWeight:FontWeight.bold)),
    Text(label,textAlign:TextAlign.center,style:const TextStyle(fontSize:11))]))));
  @override Widget build(BuildContext context)=>RefreshIndicator(onRefresh:load,child:ListView(padding:const EdgeInsets.all(14),children:[
    Card(color:Theme.of(context).colorScheme.primaryContainer,child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('أهلاً بك في ${widget.appName}',style:const TextStyle(fontSize:21,fontWeight:FontWeight.bold)),
      const Text('تابع مخزونك وحركة تجارتك من مكان واحد.'),
      const SizedBox(height:12),Wrap(spacing:8,children:[
        FilledButton.icon(onPressed:()=>widget.go(1),icon:const Icon(Icons.add_box),label:const Text('المنتجات')),
        FilledButton.tonalIcon(onPressed:()=>widget.go(2),icon:const Icon(Icons.point_of_sale),label:const Text('تسجيل بيع'))])]))),
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
          title:Text(e['name'] as String),subtitle:Text('الكود: ${e['sku']??'—'} • '+e['category'].toString()+' • الكمية: '+e['qty'].toString()+' • سعر البيع: '+money(e['sell'])),
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
    TextEditingController(text:(e?['buy']??0).toString()),TextEditingController(text:(e?['sell']??0).toString()),TextEditingController(text:e?['manufacturer'] as String? ?? ''),TextEditingController(text:e?['part_no'] as String? ?? ''),TextEditingController(text:e?['alt_part_no'] as String? ?? ''),TextEditingController(text:e?['location'] as String? ?? ''),TextEditingController(text:e?['description'] as String? ?? ''),TextEditingController(text:(e?['wholesale']??0).toString()),TextEditingController(text:e?['brand'] as String? ?? ''),TextEditingController(text:e?['unit'] as String? ?? 'قطعة'),TextEditingController(text:e?['country'] as String? ?? ''),TextEditingController(text:e?['alt_names'] as String? ?? ''),TextEditingController(text:e?['specs'] as String? ?? ''),TextEditingController(text:e?['sku'] as String? ?? '') ];imagePath=e?['image_path'] as String?;supplierId=e?['supplier_id'] as int?;loadSuppliers();}
  Future<void> loadSuppliers()async{final rows=await StoreDb.instance.parties('suppliers');if(mounted)setState(()=>suppliers=rows);}
  @override void dispose(){for(final x in c){x.dispose();}super.dispose();}
  String? req(String? v)=>v==null||v.trim().isEmpty?'مطلوب':null;
  String? integer(String? v)=>int.tryParse(v??'')==null||int.parse(v!)<0?'أدخل عدداً صحيحاً':null;
  String? decimal(String? v)=>double.tryParse(v??'')==null||double.parse(v!)<0?'أدخل سعراً صحيحاً':null;
  Widget field(int i,String label,{String? Function(String?)? validator,TextInputType? type})=>Padding(padding:const EdgeInsets.only(bottom:9),
    child:TextFormField(controller:c[i],validator:validator,keyboardType:type,decoration:InputDecoration(labelText:label)));
  Future<void> pickImage(ImageSource source) async {
    try{final picked=await ImagePicker().pickImage(source:source,imageQuality:82,maxWidth:1600);if(picked==null)return;final dir=await getApplicationSupportDirectory();final ext=p.extension(picked.path);final target=File(p.join(dir.path,'product_'+DateTime.now().microsecondsSinceEpoch.toString()+(ext.isEmpty?'.jpg':ext)));await File(picked.path).copy(target.path);if(mounted)setState(()=>imagePath=target.path);}catch(e){if(mounted)toast(context,'تعذر اختيار الصورة: $e');}
  }
  Future<void> save() async {
    if(!form.currentState!.validate())return;
    await StoreDb.instance.saveProduct({'name':c[0].text.trim(),'category':c[1].text.trim(),'qty':int.parse(c[2].text),'min_qty':int.parse(c[3].text),'buy':double.parse(c[4].text),'sell':double.parse(c[5].text),'manufacturer':c[6].text.trim(),'part_no':c[7].text.trim(),'alt_part_no':c[8].text.trim(),'location':c[9].text.trim(),'description':c[10].text.trim(),'wholesale':double.parse(c[11].text),'brand':c[12].text.trim(),'unit':c[13].text.trim(),'country':c[14].text.trim(),'alt_names':c[15].text.trim(),'specs':c[16].text.trim(),'image_path':imagePath??'','sku':c[17].text.trim(),'supplier_id':supplierId},widget.item?['id'] as int?);
    await StoreDb.instance.log(widget.item==null?'إضافة منتج':'تعديل منتج',c[0].text.trim());
    if(mounted)Navigator.pop(context,true);
  }
  @override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(
    title:Text(widget.item==null?'إضافة منتج':'تعديل منتج'),
    content:SizedBox(width:420,child:Form(key:form,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      if(widget.item!=null) Padding(padding:const EdgeInsets.only(bottom:8),child:Text('كود الصنف: ${widget.item!['sku']??''}',style:const TextStyle(fontWeight:FontWeight.bold,letterSpacing:1.5))),
      field(0,'اسم المنتج *',validator:req),field(1,'التصنيف'),field(17,'كود المنتج (اتركه فارغاً للتوليد التلقائي)'),
      Row(children:[Expanded(child:field(2,'الكمية',validator:integer,type:TextInputType.number)),const SizedBox(width:8),Expanded(child:field(3,'حد التنبيه',validator:integer,type:TextInputType.number))]),
      Row(children:[Expanded(child:field(4,'سعر الشراء',validator:decimal,type:const TextInputType.numberWithOptions(decimal:true))),const SizedBox(width:8),Expanded(child:field(5,'سعر البيع',validator:decimal,type:const TextInputType.numberWithOptions(decimal:true)))]),
      const Divider(),field(6,'الشركة المصنعة'),field(7,'رقم القطعة الأصلي'),field(8,'رقم القطعة البديل'),field(9,'مكان التخزين / الرف'),field(10,'الوصف المختصر'),
      Row(children:[Expanded(child:field(11,'سعر الجملة',validator:decimal,type:const TextInputType.numberWithOptions(decimal:true))),const SizedBox(width:8),Expanded(child:field(12,'الماركة'))]),
      Row(children:[Expanded(child:field(13,'الوحدة')),const SizedBox(width:8),Expanded(child:field(14,'بلد المنشأ'))]),field(15,'أسماء أخرى للقطعة'),field(16,'المواصفات الفنية'),DropdownButtonFormField<int?>(initialValue:supplierId,decoration:const InputDecoration(labelText:'المورد المرتبط'),items:[const DropdownMenuItem<int?>(value:null,child:Text('بدون مورد')),...suppliers.map((s)=>DropdownMenuItem<int?>(value:s['id'] as int,child:Text(s['name'].toString())))],onChanged:(v)=>setState(()=>supplierId=v)),
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
  @override void initState(){super.initState();load();}
  Future<void> load() async {final r=await StoreDb.instance.movements(widget.kind);if(mounted)setState(()=>rows=r);}
  Future<void> add() async {
    final ps=await StoreDb.instance.products();if(!mounted)return;
    if(ps.isEmpty){toast(context,'أضف منتجاً أولاً.');return;}
    final ok=await showDialog<bool>(context:context,builder:(_)=>MovementDialog(kind:widget.kind,products:ps));
    if(ok==true){await load();widget.changed();}
  }
  @override Widget build(BuildContext context) {
    final sale=widget.kind=='sale';final total=rows.fold<double>(0,(s,e)=>s+(e['total'] as num).toDouble());
    return Column(children:[
      Card(child:ListTile(leading:Icon(sale?Icons.point_of_sale:Icons.shopping_cart),title:Text(sale?'إجمالي المبيعات':'إجمالي المشتريات'),
        subtitle:Text(money(total),style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),
        trailing:Row(mainAxisSize:MainAxisSize.min,children:[
          IconButton(tooltip:'طباعة سجل الحركات',onPressed:()=>printTextReport(context,sale?'تقرير المبيعات':'تقرير المشتريات',[
            'عدد الحركات: ${rows.length}',
            ...rows.map((e)=>'${e['product_name']} | الكمية: ${e['qty']} | سعر الوحدة: ${money(e['unit_price'])} | الإجمالي: ${money(e['total'])} | الطرف: ${e['party_name']} | التاريخ: ${e['created_at']} | ملاحظات: ${e['note']}')
          ]),icon:const Icon(Icons.print_outlined)),
          FilledButton.icon(onPressed:add,icon:const Icon(Icons.add),label:Text(sale?'بيع':'شراء'))
        ]))),
      Expanded(child:rows.isEmpty?Center(child:Text(sale?'لا توجد مبيعات مسجلة':'لا توجد مشتريات مسجلة'))
        :ListView.builder(itemCount:rows.length,itemBuilder:(c,i){final e=rows[i];final dt=DateTime.tryParse(e['created_at'] as String? ?? '');
          return Card(child:ListTile(leading:CircleAvatar(child:Icon(sale?Icons.south_west:Icons.north_east)),
            title:Text(e['product_name'] as String),subtitle:Text(e['qty'].toString()+' × '+money(e['unit_price'])+' • '+(dt?.toLocal().toString().substring(0,16)??'')+'\n'+(e['party_name']??'').toString()+' • '+e['note'].toString()),
            isThreeLine:true,trailing:Text(money(e['total']),style:const TextStyle(fontWeight:FontWeight.bold))));
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
  Future<void> remove(Map<String,Object?> e) async {if(await ask(context,'حذف','هل تريد حذف '+e['name'].toString()+'؟')==true){await StoreDb.instance.deleteParty(widget.table,e['id'] as int);await load();}}
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
  @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(12),children:[Row(children:[const Expanded(child:Text('إدارة المخازن',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold))),IconButton(tooltip:'طباعة المخازن',onPressed:()=>printTextReport(context,'قائمة المخازن',rows.map((e)=>'${e['name']} | الموقع: ${e['location']}').toList()),icon:const Icon(Icons.print_outlined)),IconButton.filled(onPressed:()=>edit(),icon:const Icon(Icons.add))]),...rows.map((e)=>Card(child:ListTile(leading:const Icon(Icons.warehouse_outlined),title:Text(e['name'] as String),subtitle:Text(e['location'] as String? ?? ''),trailing:IconButton(onPressed:()=>edit(e),icon:const Icon(Icons.edit_outlined)))))]);
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
  @override Widget build(BuildContext context)=>Column(children:[Card(child:ListTile(title:const Text('إجمالي المصروفات'),trailing:Text(money(rows.fold<double>(0,(a,e)=>a+(e['amount'] as num).toDouble())),style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold)))),Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Align(alignment:Alignment.centerRight,child:TextButton.icon(onPressed:()=>printTextReport(context,'تقرير المصروفات',rows.map((e)=>'${e['title']} | التصنيف: ${e['category']} | المبلغ: ${money(e['amount'])} | التاريخ: ${e['created_at']} | ${e['notes']}').toList()),icon:const Icon(Icons.print_outlined),label:const Text('طباعة المصروفات')))),Expanded(child:rows.isEmpty?const Center(child:Text('لا توجد مصروفات')):ListView.builder(itemCount:rows.length,itemBuilder:(c,i){final e=rows[i];return Card(child:ListTile(title:Text(e['title'] as String),subtitle:Text((e['category']??'').toString()+' • '+(e['notes']??'').toString()),trailing:Text(money(e['amount']))));})),Padding(padding:const EdgeInsets.all(12),child:FilledButton.icon(onPressed:add,icon:const Icon(Icons.add),label:const Text('إضافة مصروف')))]);
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
    const Card(child:ListTile(leading:Icon(Icons.offline_bolt_outlined),title:Text('يعمل دون إنترنت'),
      subtitle:Text('البيانات محفوظة محلياً باستخدام SQLite. لا يحتاج التطبيق إلى حساب أو خادم.'))),
    const Card(child:ListTile(leading:Icon(Icons.info_outline),title:Text('MY APP — إصدار 3.1.0'),
      subtitle:Text('بحث بالاسم والكود والصورة، أكواد فريدة، صور محلية، QR، تصنيفات، مفضلة، أرشيف، سجل أسعار ونسخ احتياطي شامل.'))),
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
      canvas!.drawRect(const ui.Rect.fromLTWH(0,0,w,h),ui.Paint()..color=const ui.Color(0xFFFFFFFF));
      final heading=TextPainter(text:TextSpan(text:title,style:const TextStyle(fontSize:42,fontWeight:FontWeight.bold,color:Color(0xFF111111))),textDirection:TextDirection.rtl,textAlign:TextAlign.right);
      heading.layout(maxWidth:w-2*pad);
      heading.paint(canvas!,Offset(pad,pad));
      final date=TextPainter(text:TextSpan(text:'تاريخ الطباعة: ${DateTime.now().toLocal().toString().substring(0,16)}',style:const TextStyle(fontSize:22,color:Color(0xFF555555))),textDirection:TextDirection.rtl,textAlign:TextAlign.right);
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
      painter.paint(canvas!,Offset(pad,y));
      y+=painter.height+24;
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
