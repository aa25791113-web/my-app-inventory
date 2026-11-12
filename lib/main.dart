import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    database = await openDatabase(p.join(dir.path, 'my_app.sqlite'), version: 3,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE products(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,category TEXT NOT NULL DEFAULT "",qty INTEGER NOT NULL DEFAULT 0,min_qty INTEGER NOT NULL DEFAULT 0,buy REAL NOT NULL DEFAULT 0,sell REAL NOT NULL DEFAULT 0)');
        await db.execute('CREATE TABLE operations(id INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,product_id INTEGER NOT NULL,product_name TEXT NOT NULL,qty INTEGER NOT NULL,unit_price REAL NOT NULL,total REAL NOT NULL,note TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL,cost_price REAL NOT NULL DEFAULT 0,party_id INTEGER,party_name TEXT NOT NULL DEFAULT "",warehouse_id INTEGER NOT NULL DEFAULT 1)');
        await _createExtendedTables(db);
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
      });
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
  Future<void> saveParty(String table,Map<String,Object?> data,int? id) async { if(id==null){await database!.insert(table,data);}else{await database!.update(table,data,where:'id=?',whereArgs:[id]);} }
  Future<void> deleteParty(String table,int id) async { await database!.delete(table,where:'id=?',whereArgs:[id]); }
  Future<List<Map<String,Object?>>> expenses() => database!.query('expenses',orderBy:'id DESC');
  Future<void> addExpense(String title,String category,double amount,String notes) async {
    if(title.trim().isEmpty||amount<=0) throw Exception('أدخل بيان المصروف ومبلغاً أكبر من صفر.');
    await database!.insert('expenses',{'title':title.trim(),'category':category.trim(),'amount':amount,'notes':notes.trim(),'created_at':DateTime.now().toIso8601String()});
  }
  Future<void> adjustStock(Map<String,Object?> product,int newQty,String reason) async {
    if(newQty<0) throw Exception('الكمية لا يمكن أن تكون سالبة.');
    await database!.transaction((txn) async {
      final old=product['qty'] as int;
      await txn.update('products',{'qty':newQty},where:'id=?',whereArgs:[product['id']]);
      await txn.insert('stock_adjustments',{'product_id':product['id'],'product_name':product['name'],'old_qty':old,'new_qty':newQty,'difference':newQty-old,'reason':reason,'created_at':DateTime.now().toIso8601String()});
    });
  }
  Future<List<Map<String,Object?>>> products([String query = '']) => database!.query('products',
    where: query.trim().isEmpty ? null : 'name LIKE ? OR category LIKE ?',
    whereArgs: query.trim().isEmpty ? null : ['%' + query + '%','%' + query + '%'], orderBy: 'name');
  Future<void> saveProduct(Map<String,Object?> data, int? id) async {
    if (id == null) { await database!.insert('products', data); }
    else { await database!.update('products', data, where: 'id=?', whereArgs: [id]); }
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
    });
  }
  Future<List<Map<String,Object?>>> movements([String? kind]) => database!.query('operations',
    where:kind == null ? null : 'kind=?',whereArgs:kind == null ? null : [kind],orderBy:'id DESC');
  Future<Map<String,Object?>> summary() async {
    final products = await database!.query('products');
    final sales = await database!.rawQuery("SELECT COALESCE(SUM(total),0) AS total FROM operations WHERE kind='sale'");
    final buys = await database!.rawQuery("SELECT COALESCE(SUM(total),0) AS total FROM operations WHERE kind='purchase'");
    final expenses = await database!.rawQuery("SELECT COALESCE(SUM(amount),0) AS total FROM expenses");
    final profit = await database!.rawQuery("SELECT COALESCE(SUM((unit_price-cost_price)*qty),0) AS total FROM operations WHERE kind='sale'");
    return {
      'count':products.length,
      'qty':products.fold<int>(0,(sum,row)=>sum + (row['qty'] as int)),
      'low':products.where((row)=>(row['qty'] as int) <= (row['min_qty'] as int)).length,
      'stock':products.fold<double>(0,(sum,row)=>sum + (row['qty'] as int) * (row['buy'] as num).toDouble()),
      'sales':(sales.first['total'] as num).toDouble(),
      'buys':(buys.first['total'] as num).toDouble(),
      'expense_total':(expenses.first['total'] as num).toDouble(),
      'profit':(profit.first['total'] as num).toDouble(),
    };
  }
  Future<String> backup() async {
    final dir = await getApplicationDocumentsDirectory();
    final data = {'format':'MYAPP_BACKUP_2','products':await database!.query('products'),'operations':await database!.query('operations'),'suppliers':await database!.query('suppliers'),'customers':await database!.query('customers'),'warehouses':await database!.query('warehouses'),'expenses':await database!.query('expenses'),'stock_adjustments':await database!.query('stock_adjustments')};
    final file = File(p.join(dir.path,'my_app_backup.json'));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return file.path;
  }
  Future<String?> exportBackup() async {
    final data = {'format':'MYAPP_BACKUP_2','products':await database!.query('products'),'operations':await database!.query('operations'),'suppliers':await database!.query('suppliers'),'customers':await database!.query('customers'),'warehouses':await database!.query('warehouses'),'expenses':await database!.query('expenses'),'stock_adjustments':await database!.query('stock_adjustments')};
    final bytes=Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(data)));
    return FilePicker.platform.saveFile(dialogTitle:'حفظ النسخة الاحتياطية',fileName:'MYAPP_Backup.json',type:FileType.custom,allowedExtensions:['json'],bytes:bytes);
  }
  Future<String?> exportInventoryCsv() async {
    final rows=await database!.query('products',orderBy:'name');
    String cell(Object? v)=>'"'+(v??'').toString().replaceAll('"','""')+'"';
    final lines=<String>['ID,Product,Category,Quantity,Minimum,Purchase Price,Selling Price'];
    for(final r in rows){lines.add([r['id'],r['name'],r['category'],r['qty'],r['min_qty'],r['buy'],r['sell']].map(cell).join(','));}
    final bytes=Uint8List.fromList(utf8.encode('\uFEFF'+lines.join('\r\n')));
    return FilePicker.platform.saveFile(dialogTitle:'تصدير جرد المنتجات CSV',fileName:'MYAPP_Inventory.csv',type:FileType.custom,allowedExtensions:['csv'],bytes:bytes);
  }
  Future<void> importBackup() async {
    final result=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['json'],withData:true);
    if(result==null||result.files.isEmpty||result.files.first.bytes==null)return;
    final data=jsonDecode(utf8.decode(result.files.first.bytes!)) as Map<String,dynamic>;
    if(data['format']!='MYAPP_BACKUP_1'&&data['format']!='MYAPP_BACKUP_2')throw Exception('ملف النسخة الاحتياطية غير صالح.');
    await database!.transaction((txn) async {
      for(final t in ['stock_adjustments','expenses','operations','products','suppliers','customers','warehouses']){await txn.delete(t);}
      for(final row in data['products'] as List){await txn.insert('products',Map<String,Object?>.from(row as Map));}
      for(final row in data['operations'] as List){final m=Map<String,Object?>.from(row as Map);m.putIfAbsent('cost_price',()=>0.0);m.putIfAbsent('party_id',()=>null);m.putIfAbsent('party_name',()=> '');m.putIfAbsent('warehouse_id',()=>1);await txn.insert('operations',m);}
      for(final table in ['suppliers','customers','warehouses','expenses','stock_adjustments']){for(final row in (data[table] as List? ?? [])){await txn.insert(table,Map<String,Object?>.from(row as Map));}}
      final wh=await txn.rawQuery('SELECT COUNT(*) AS c FROM warehouses');if((wh.first['c'] as int? ?? 0)==0)await txn.insert('warehouses',{'name':'المخزن الرئيسي','location':'','notes':''});
    });
  }
  Future<String> restore() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path,'my_app_backup.json'));
    if (!await file.exists()) throw Exception('لا توجد نسخة احتياطية على الجهاز.');
    final data = jsonDecode(await file.readAsString()) as Map<String,dynamic>;
    if (data['format'] != 'MYAPP_BACKUP_1' && data['format'] != 'MYAPP_BACKUP_2') throw Exception('ملف النسخة الاحتياطية غير صالح.');
    await database!.transaction((txn) async {
      for(final t in ['stock_adjustments','expenses','operations','products','suppliers','customers','warehouses']) { await txn.delete(t); }
      for (final row in data['products'] as List) {
        await txn.insert('products',Map<String,Object?>.from(row as Map));
      }
      for (final row in data['operations'] as List) {
        final m=Map<String,Object?>.from(row as Map);
        m.putIfAbsent('cost_price',()=>0.0);m.putIfAbsent('party_id',()=>null);m.putIfAbsent('party_name',()=> '');m.putIfAbsent('warehouse_id',()=>1);
        await txn.insert('operations',m);
      }
      for(final table in ['suppliers','customers','warehouses','expenses','stock_adjustments']) {
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
  @override void initState(){super.initState();load();}
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() { mode = prefs.getBool('dark') == true ? ThemeMode.dark : ThemeMode.light; seedColor = Color(prefs.getInt('seedColor') ?? 0xFF087F68); appName=prefs.getString('appName') ?? 'MY APP'; logoPath=prefs.getString('logoPath'); });
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
  ThemeData makeTheme(Brightness b)=>ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:seedColor,brightness:b));
  @override Widget build(BuildContext context)=>MaterialApp(debugShowCheckedModeBanner:false,title:'MY APP',
    theme:makeTheme(Brightness.light),darkTheme:makeTheme(Brightness.dark),themeMode:mode,
    home:HomePage(dark:mode==ThemeMode.dark,toggle:toggle,seedColor:seedColor,changeSeed:changeSeed,appName:appName,changeAppName:changeAppName,logoPath:logoPath,changeLogo:changeLogo));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key,required this.dark,required this.toggle,required this.seedColor,required this.changeSeed,required this.appName,required this.changeAppName,required this.logoPath,required this.changeLogo});
  final bool dark; final VoidCallback toggle; final Color seedColor; final ValueChanged<int> changeSeed; final String appName; final ValueChanged<String> changeAppName; final String? logoPath; final VoidCallback changeLogo;
  @override State<HomePage> createState()=>_HomePageState();
}
class _HomePageState extends State<HomePage> {
  int tab=0, refreshId=0;
  void refresh()=>setState(()=>refreshId++);
  @override Widget build(BuildContext context) {
    final pages=[
      Dashboard(key:ValueKey('d'+refreshId.toString()),go:(v)=>setState(()=>tab=v)),
      ProductsPage(key:ValueKey('p'+refreshId.toString()),changed:refresh),
      MovementPage(key:ValueKey('s'+refreshId.toString()),kind:'sale',changed:refresh),
      MovementPage(key:ValueKey('b'+refreshId.toString()),kind:'purchase',changed:refresh),
      PartyPage(key:ValueKey('sup'+refreshId.toString()),table:'suppliers',title:'الموردون',changed:refresh),
      PartyPage(key:ValueKey('cus'+refreshId.toString()),table:'customers',title:'العملاء',changed:refresh),
      WarehousePage(key:ValueKey('wh'+refreshId.toString()),changed:refresh),
      ExpensePage(key:ValueKey('ex'+refreshId.toString()),changed:refresh),
      ReportsPage(key:ValueKey('r'+refreshId.toString())),
      SettingsPage(dark:widget.dark,toggle:widget.toggle,seedColor:widget.seedColor,changeSeed:widget.changeSeed,appName:widget.appName,changeAppName:widget.changeAppName,logoPath:widget.logoPath,changeLogo:widget.changeLogo),
    ];
    const labels=['الرئيسية','المنتجات','المبيعات','المشتريات','الموردون','العملاء','المخازن','المصروفات','التقارير','الإعدادات'];
    const icons=[Icons.dashboard_outlined,Icons.inventory_2_outlined,Icons.point_of_sale,Icons.shopping_cart_outlined,Icons.local_shipping_outlined,Icons.people_alt_outlined,Icons.warehouse_outlined,Icons.payments_outlined,Icons.analytics_outlined,Icons.settings_outlined];
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
        title:const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(widget.appName,style:TextStyle(fontWeight:FontWeight.w900)),
        Text('إدارة المخزون دون إنترنت',style:TextStyle(fontSize:11))])),
      body:IndexedStack(index:tab,children:pages),
      bottomNavigationBar:NavigationBar(selectedIndex:tab==8?4:(tab<4?tab:0),onDestinationSelected:(v)=>setState(()=>tab=v==4?8:v),
        destinations:const [
          NavigationDestination(icon:Icon(Icons.dashboard_outlined),label:'الرئيسية'),
          NavigationDestination(icon:Icon(Icons.inventory_2_outlined),label:'المنتجات'),
          NavigationDestination(icon:Icon(Icons.point_of_sale),label:'المبيعات'),
          NavigationDestination(icon:Icon(Icons.shopping_cart_outlined),label:'المشتريات'),
          NavigationDestination(icon:Icon(Icons.analytics_outlined),label:'التقارير'),
        ]),
    ));
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key,required this.go}); final ValueChanged<int> go;
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
      const Text('أهلاً بك في MY APP',style:TextStyle(fontSize:21,fontWeight:FontWeight.bold)),
      const Text('تابع مخزونك وحركة تجارتك من مكان واحد.'),
      const SizedBox(height:12),Wrap(spacing:8,children:[
        FilledButton.icon(onPressed:()=>widget.go(1),icon:const Icon(Icons.add_box),label:const Text('المنتجات')),
        FilledButton.tonalIcon(onPressed:()=>widget.go(2),icon:const Icon(Icons.point_of_sale),label:const Text('تسجيل بيع'))])]))),
    Row(children:[stat('عدد المنتجات',(data['count']??0).toString(),Icons.inventory_2),stat('إجمالي الوحدات',(data['qty']??0).toString(),Icons.numbers)]),
    Row(children:[stat('نواقص المخزون',(data['low']??0).toString(),Icons.warning_amber),stat('قيمة المخزون',money(data['stock']),Icons.account_balance_wallet)]),
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
        return Card(child:ListTile(leading:CircleAvatar(child:Icon(low?Icons.warning_amber:Icons.inventory_2)),
          title:Text(e['name'] as String),subtitle:Text(e['category'].toString()+' • الكمية: '+e['qty'].toString()+' • سعر البيع: '+money(e['sell'])),
          trailing:PopupMenuButton<String>(onSelected:(v){if(v=='edit'){edit(e);}else if(v=='adjust'){adjust(e);}else{remove(e);}},
            itemBuilder:(_)=>const [PopupMenuItem(value:'edit',child:Text('تعديل')),PopupMenuItem(value:'adjust',child:Text('تسوية وجرد الكمية')),PopupMenuItem(value:'delete',child:Text('حذف'))])));
      })),
  ]);
}

class ProductDialog extends StatefulWidget {
  const ProductDialog({super.key,this.item}); final Map<String,Object?>? item;
  @override State<ProductDialog> createState()=>_ProductDialogState();
}
class _ProductDialogState extends State<ProductDialog> {
  final form=GlobalKey<FormState>(); late final List<TextEditingController> c;
  @override void initState(){super.initState();final e=widget.item;c=[
    TextEditingController(text:e?['name'] as String? ?? ''),TextEditingController(text:e?['category'] as String? ?? ''),
    TextEditingController(text:(e?['qty']??0).toString()),TextEditingController(text:(e?['min_qty']??0).toString()),
    TextEditingController(text:(e?['buy']??0).toString()),TextEditingController(text:(e?['sell']??0).toString())];}
  @override void dispose(){for(final x in c){x.dispose();}super.dispose();}
  String? req(String? v)=>v==null||v.trim().isEmpty?'مطلوب':null;
  String? integer(String? v)=>int.tryParse(v??'')==null||int.parse(v!)<0?'أدخل عدداً صحيحاً':null;
  String? decimal(String? v)=>double.tryParse(v??'')==null||double.parse(v!)<0?'أدخل سعراً صحيحاً':null;
  Widget field(int i,String label,{String? Function(String?)? validator,TextInputType? type})=>Padding(padding:const EdgeInsets.only(bottom:9),
    child:TextFormField(controller:c[i],validator:validator,keyboardType:type,decoration:InputDecoration(labelText:label)));
  Future<void> save() async {
    if(!form.currentState!.validate())return;
    await StoreDb.instance.saveProduct({'name':c[0].text.trim(),'category':c[1].text.trim(),'qty':int.parse(c[2].text),
      'min_qty':int.parse(c[3].text),'buy':double.parse(c[4].text),'sell':double.parse(c[5].text)},widget.item?['id'] as int?);
    if(mounted)Navigator.pop(context,true);
  }
  @override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(
    title:Text(widget.item==null?'إضافة منتج':'تعديل منتج'),
    content:SizedBox(width:420,child:Form(key:form,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      field(0,'اسم المنتج *',validator:req),field(1,'التصنيف'),
      Row(children:[Expanded(child:field(2,'الكمية',validator:integer,type:TextInputType.number)),const SizedBox(width:8),Expanded(child:field(3,'حد التنبيه',validator:integer,type:TextInputType.number))]),
      Row(children:[Expanded(child:field(4,'سعر الشراء',validator:decimal,type:const TextInputType.numberWithOptions(decimal:true))),const SizedBox(width:8),Expanded(child:field(5,'سعر البيع',validator:decimal,type:const TextInputType.numberWithOptions(decimal:true)))]),
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
    Padding(padding:const EdgeInsets.all(12),child:Row(children:[Expanded(child:TextField(controller:search,onChanged:(_)=>load(),decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'بحث'))),IconButton.filled(onPressed:()=>edit(),icon:const Icon(Icons.add))])),
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
  @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(12),children:[Row(children:[const Expanded(child:Text('إدارة المخازن',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold))),IconButton.filled(onPressed:()=>edit(),icon:const Icon(Icons.add))]),...rows.map((e)=>Card(child:ListTile(leading:const Icon(Icons.warehouse_outlined),title:Text(e['name'] as String),subtitle:Text(e['location'] as String? ?? ''),trailing:IconButton(onPressed:()=>edit(e),icon:const Icon(Icons.edit_outlined)))))]);
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
  @override Widget build(BuildContext context)=>Column(children:[Card(child:ListTile(title:const Text('إجمالي المصروفات'),trailing:Text(money(rows.fold<double>(0,(a,e)=>a+(e['amount'] as num).toDouble())),style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold)))),Expanded(child:rows.isEmpty?const Center(child:Text('لا توجد مصروفات')):ListView.builder(itemCount:rows.length,itemBuilder:(c,i){final e=rows[i];return Card(child:ListTile(title:Text(e['title'] as String),subtitle:Text((e['category']??'').toString()+' • '+(e['notes']??'').toString()),trailing:Text(money(e['amount']))));})),Padding(padding:const EdgeInsets.all(12),child:FilledButton.icon(onPressed:add,icon:const Icon(Icons.add),label:const Text('إضافة مصروف')))]);
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
  const SettingsPage({super.key,required this.dark,required this.toggle,required this.seedColor,required this.changeSeed,required this.appName,required this.changeAppName,required this.logoPath,required this.changeLogo});final bool dark;final VoidCallback toggle;final Color seedColor;final ValueChanged<int> changeSeed;final String appName;final ValueChanged<String> changeAppName;final String? logoPath;final VoidCallback changeLogo;
  @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(14),children:[
    const Text('الإعدادات',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),
    Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('اسم النشاط التجاري / عنوان البرنامج',style:TextStyle(fontWeight:FontWeight.bold)),
      const SizedBox(height:8),
      TextFormField(initialValue:appName,onFieldSubmitted:changeAppName,decoration:const InputDecoration(hintText:'اكتب اسم المتجر ثم اضغط تم')),
      ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.image_outlined),title:const Text('تغيير شعار البرنامج'),subtitle:Text(logoPath==null?'لم يتم اختيار شعار بعد':'تم حفظ شعار مخصص على هذا الجهاز'),onTap:changeLogo)
    ]))),
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
    Card(child:ListTile(leading:const Icon(Icons.file_open_outlined),title:const Text('استيراد نسخة احتياطية من ملف'),
      subtitle:const Text('استعادة المنتجات والحركات والموردين والعملاء والمخازن والمصروفات'),
      onTap:() async {if(await ask(context,'استيراد البيانات','سيتم استبدال البيانات الحالية بمحتويات الملف. متابعة؟')!=true)return;
        try{await StoreDb.instance.importBackup();if(context.mounted)toast(context,'تم استيراد النسخة بنجاح. أعد فتح الصفحات لتحديث البيانات.');}
        catch(e){if(context.mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}})),
    const Card(child:ListTile(leading:Icon(Icons.offline_bolt_outlined),title:Text('يعمل دون إنترنت'),
      subtitle:Text('البيانات محفوظة محلياً باستخدام SQLite. لا يحتاج التطبيق إلى حساب أو خادم.'))),
    const Card(child:ListTile(leading:Icon(Icons.info_outline),title:Text('MY APP — إصدار 1.0'),
      subtitle:Text('المنتجات والمخزون والمبيعات والمشتريات والتقارير والنسخ الاحتياطي.'))),
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

String money(Object? value)=>((value as num?)??0).toStringAsFixed(2)+' ج.م';
Future<bool?> ask(BuildContext context,String title,String body)=>showDialog<bool>(context:context,builder:(c)=>Directionality(textDirection:TextDirection.rtl,
  child:AlertDialog(title:Text(title),content:Text(body),actions:[
    TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),
    FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('تأكيد'))])));
void toast(BuildContext context,String text)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(text),duration:const Duration(seconds:5)));
