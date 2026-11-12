import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
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
    database = await openDatabase(p.join(dir.path, 'my_app.sqlite'), version: 2,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE products(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,category TEXT NOT NULL DEFAULT "",qty INTEGER NOT NULL DEFAULT 0,min_qty INTEGER NOT NULL DEFAULT 0,buy REAL NOT NULL DEFAULT 0,sell REAL NOT NULL DEFAULT 0)');
        await db.execute('CREATE TABLE operations(id INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,product_id INTEGER NOT NULL,product_name TEXT NOT NULL,qty INTEGER NOT NULL,unit_price REAL NOT NULL,total REAL NOT NULL,note TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('CREATE TABLE IF NOT EXISTS operations(id INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,product_id INTEGER NOT NULL,product_name TEXT NOT NULL,qty INTEGER NOT NULL,unit_price REAL NOT NULL,total REAL NOT NULL,note TEXT NOT NULL DEFAULT "",created_at TEXT NOT NULL)');
        }
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
  Future<void> addMovement(String kind, Map<String,Object?> product, int qty, double price, String note) async {
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
      });
    });
  }
  Future<List<Map<String,Object?>>> movements([String? kind]) => database!.query('operations',
    where:kind == null ? null : 'kind=?',whereArgs:kind == null ? null : [kind],orderBy:'id DESC');
  Future<Map<String,Object?>> summary() async {
    final products = await database!.query('products');
    final sales = await database!.rawQuery("SELECT COALESCE(SUM(total),0) AS total FROM operations WHERE kind='sale'");
    final buys = await database!.rawQuery("SELECT COALESCE(SUM(total),0) AS total FROM operations WHERE kind='purchase'");
    return {
      'count':products.length,
      'qty':products.fold<int>(0,(sum,row)=>sum + (row['qty'] as int)),
      'low':products.where((row)=>(row['qty'] as int) <= (row['min_qty'] as int)).length,
      'stock':products.fold<double>(0,(sum,row)=>sum + (row['qty'] as int) * (row['buy'] as num).toDouble()),
      'sales':(sales.first['total'] as num).toDouble(),
      'buys':(buys.first['total'] as num).toDouble(),
    };
  }
  Future<String> backup() async {
    final dir = await getApplicationDocumentsDirectory();
    final data = {'format':'MYAPP_BACKUP_1','products':await database!.query('products'),'operations':await database!.query('operations')};
    final file = File(p.join(dir.path,'my_app_backup.json'));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return file.path;
  }
  Future<String> restore() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path,'my_app_backup.json'));
    if (!await file.exists()) throw Exception('لا توجد نسخة احتياطية على الجهاز.');
    final data = jsonDecode(await file.readAsString()) as Map<String,dynamic>;
    if (data['format'] != 'MYAPP_BACKUP_1') throw Exception('ملف النسخة الاحتياطية غير صالح.');
    await database!.transaction((txn) async {
      await txn.delete('operations'); await txn.delete('products');
      for (final row in data['products'] as List) {
        await txn.insert('products',Map<String,Object?>.from(row as Map));
      }
      for (final row in data['operations'] as List) {
        await txn.insert('operations',Map<String,Object?>.from(row as Map));
      }
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
  @override void initState(){super.initState();load();}
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => mode = prefs.getBool('dark') == true ? ThemeMode.dark : ThemeMode.light);
  }
  Future<void> toggle() async {
    final dark = mode != ThemeMode.dark;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark',dark);
    if (mounted) setState(() => mode = dark ? ThemeMode.dark : ThemeMode.light);
  }
  ThemeData makeTheme(Brightness b)=>ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:const Color(0xFF087F68),brightness:b));
  @override Widget build(BuildContext context)=>MaterialApp(debugShowCheckedModeBanner:false,title:'MY APP',
    theme:makeTheme(Brightness.light),darkTheme:makeTheme(Brightness.dark),themeMode:mode,
    home:HomePage(dark:mode==ThemeMode.dark,toggle:toggle));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key,required this.dark,required this.toggle});
  final bool dark; final VoidCallback toggle;
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
      ReportsPage(key:ValueKey('r'+refreshId.toString())),
      SettingsPage(dark:widget.dark,toggle:widget.toggle),
    ];
    const labels=['الرئيسية','المنتجات','المبيعات','المشتريات','التقارير','الإعدادات'];
    const icons=[Icons.dashboard_outlined,Icons.inventory_2_outlined,Icons.point_of_sale,Icons.shopping_cart_outlined,Icons.analytics_outlined,Icons.settings_outlined];
    return Directionality(textDirection:TextDirection.rtl,child:Scaffold(
      appBar:AppBar(title:const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('MY APP',style:TextStyle(fontWeight:FontWeight.w900)),
        Text('إدارة المخزون دون إنترنت',style:TextStyle(fontSize:11))])),
      body:IndexedStack(index:tab,children:pages),
      bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(v)=>setState(()=>tab=v),
        destinations:List.generate(labels.length,(i)=>NavigationDestination(icon:Icon(icons[i]),label:labels[i]))),
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
    if(mounted)setState(()=>{data=d,low=p.where((e)=>(e['qty'] as int)<=(e['min_qty'] as int)).toList()});
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
  Future<void> remove(Map<String,Object?> row) async {
    if(await ask(context,'حذف المنتج','هل تريد حذف '+row['name'].toString()+'؟')!=true)return;
    try{await StoreDb.instance.removeProduct(row['id'] as int);await load();widget.changed();}
    catch(e){if(mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}
  }
  @override Widget build(BuildContext context)=>Column(children:[
    Padding(padding:const EdgeInsets.all(12),child:Row(children:[
      Expanded(child:TextField(controller:search,onChanged:(_)=>load(),decoration:const InputDecoration(hintText:'بحث بالاسم أو التصنيف',prefixIcon:Icon(Icons.search)))),
      const SizedBox(width:8),IconButton.filled(onPressed:()=>edit(),icon:const Icon(Icons.add))])),
    Expanded(child:rows.isEmpty?const Center(child:Text('لا توجد منتجات. اضغط + لإضافة منتج.'))
      :ListView.builder(padding:const EdgeInsets.only(bottom:20),itemCount:rows.length,itemBuilder:(c,i){
        final e=rows[i];final low=(e['qty'] as int)<=(e['min_qty'] as int);
        return Card(child:ListTile(leading:CircleAvatar(child:Icon(low?Icons.warning_amber:Icons.inventory_2)),
          title:Text(e['name'] as String),subtitle:Text(e['category'].toString()+' • الكمية: '+e['qty'].toString()+' • سعر البيع: '+money(e['sell'])),
          trailing:PopupMenuButton<String>(onSelected:(v)=>v=='edit'?edit(e):remove(e),
            itemBuilder:(_)=>const [PopupMenuItem(value:'edit',child:Text('تعديل')),PopupMenuItem(value:'delete',child:Text('حذف'))])));
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
        trailing:FilledButton.icon(onPressed:add,icon:const Icon(Icons.add),label:Text(sale?'بيع':'شراء')))),
      Expanded(child:rows.isEmpty?Center(child:Text(sale?'لا توجد مبيعات مسجلة':'لا توجد مشتريات مسجلة'))
        :ListView.builder(itemCount:rows.length,itemBuilder:(c,i){final e=rows[i];final dt=DateTime.tryParse(e['created_at'] as String? ?? '');
          return Card(child:ListTile(leading:CircleAvatar(child:Icon(sale?Icons.south_west:Icons.north_east)),
            title:Text(e['product_name'] as String),subtitle:Text(e['qty'].toString()+' × '+money(e['unit_price'])+' • '+(dt?.toLocal().toString().substring(0,16)??'')+'\n'+e['note'].toString()),
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
  @override void initState(){super.initState();selected=widget.products.first;qty=TextEditingController(text:'1');
    price=TextEditingController(text:(widget.kind=='sale'?selected['sell']:selected['buy']).toString());note=TextEditingController();}
  @override void dispose(){qty.dispose();price.dispose();note.dispose();super.dispose();}
  @override Widget build(BuildContext context) {
    final sale=widget.kind=='sale';
    return Directionality(textDirection:TextDirection.rtl,child:AlertDialog(title:Text(sale?'تسجيل بيع':'تسجيل شراء'),
      content:SizedBox(width:420,child:Form(key:form,child:Column(mainAxisSize:MainAxisSize.min,children:[
        DropdownButtonFormField<int>(value:selected['id'] as int,decoration:const InputDecoration(labelText:'المنتج'),
          items:widget.products.map((e)=>DropdownMenuItem<int>(value:e['id'] as int,child:Text(e['name'].toString()+' (المتاح '+e['qty'].toString()+')'))).toList(),
          onChanged:(id){final x=widget.products.firstWhere((e)=>e['id']==id);setState((){selected=x;price.text=(sale?x['sell']:x['buy']).toString();});}),
        const SizedBox(height:10),TextFormField(controller:qty,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'الكمية'),
          validator:(v)=>int.tryParse(v??'')==null||int.parse(v!)<=0?'أدخل كمية صحيحة':null),
        const SizedBox(height:10),TextFormField(controller:price,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'سعر الوحدة'),
          validator:(v)=>double.tryParse(v??'')==null||double.parse(v!)<0?'أدخل سعراً صحيحاً':null),
        const SizedBox(height:10),TextFormField(controller:note,decoration:const InputDecoration(labelText:'ملاحظة اختيارية')),
        if(sale)Align(alignment:Alignment.centerRight,child:Text('المتاح حالياً: '+selected['qty'].toString())),
      ]))),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('إلغاء')),FilledButton(onPressed:() async {
        if(!form.currentState!.validate())return;
        try{await StoreDb.instance.addMovement(widget.kind,selected,int.parse(qty.text),double.parse(price.text),note.text.trim());
          if(context.mounted)Navigator.pop(context,true);}
        catch(e){if(context.mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}
      },child:const Text('تأكيد'))]));
  }
}

class ReportsPage extends StatefulWidget {const ReportsPage({super.key});@override State<ReportsPage> createState()=>_ReportsPageState();}
class _ReportsPageState extends State<ReportsPage> {
  Map<String,Object?> data={};List<Map<String,Object?>> products=[];List<Map<String,Object?>> ops=[];
  @override void initState(){super.initState();load();}
  Future<void> load() async {final d=await StoreDb.instance.summary();final p=await StoreDb.instance.products();final o=await StoreDb.instance.movements();
    if(mounted)setState(()=>{data=d,products=p,ops=o});}
  Widget tile(String title,String value,IconData icon)=>Card(child:ListTile(leading:Icon(icon),title:Text(title),trailing:Text(value,style:const TextStyle(fontWeight:FontWeight.bold))));
  @override Widget build(BuildContext context)=>RefreshIndicator(onRefresh:load,child:ListView(padding:const EdgeInsets.all(14),children:[
    const Text('التقارير والجرد',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),
    tile('قيمة المخزون بسعر الشراء',money(data['stock']),Icons.warehouse_outlined),
    tile('إجمالي المبيعات',money(data['sales']),Icons.trending_up),
    tile('إجمالي المشتريات',money(data['buys']),Icons.shopping_bag_outlined),
    tile('صافي الحركة النقدية',money(((data['sales'] as num?)??0)-((data['buys'] as num?)??0)),Icons.account_balance),
    const SizedBox(height:10),const Text('الجرد الحالي',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
    ...products.map((e)=>ListTile(dense:true,title:Text(e['name'] as String),subtitle:Text('الكمية '+e['qty'].toString()+' • تكلفة الوحدة '+money(e['buy'])),
      trailing:Text(money((e['qty'] as int)*(e['buy'] as num).toDouble())))),
    const Divider(),Text('عدد الحركات المسجلة: '+ops.length.toString()),
  ]));
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key,required this.dark,required this.toggle});final bool dark;final VoidCallback toggle;
  @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(14),children:[
    const Text('الإعدادات',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),
    Card(child:SwitchListTile(secondary:const Icon(Icons.dark_mode_outlined),title:const Text('الوضع الليلي'),value:dark,onChanged:(_)=>toggle())),
    Card(child:ListTile(leading:const Icon(Icons.backup_outlined),title:const Text('إنشاء نسخة احتياطية محلية'),
      subtitle:const Text('حفظ المنتجات والمبيعات والمشتريات في ملف JSON'),
      onTap:() async {try{final path=await StoreDb.instance.backup();if(context.mounted)toast(context,'تم حفظ النسخة على الجهاز: '+path);}
        catch(e){if(context.mounted)toast(context,e.toString());}})),
    Card(child:ListTile(leading:const Icon(Icons.settings_backup_restore),title:const Text('استعادة آخر نسخة احتياطية'),
      subtitle:const Text('سيتم استبدال البيانات الحالية بمحتويات النسخة'),
      onTap:() async {if(await ask(context,'استعادة البيانات','سيتم استبدال البيانات الحالية. متابعة؟')!=true)return;
        try{final path=await StoreDb.instance.restore();if(context.mounted)toast(context,'تمت الاستعادة: '+path);}
        catch(e){if(context.mounted)toast(context,e.toString().replaceFirst('Exception: ',''));}})),
    const Card(child:ListTile(leading:Icon(Icons.offline_bolt_outlined),title:Text('يعمل دون إنترنت'),
      subtitle:Text('البيانات محفوظة محلياً باستخدام SQLite. لا يحتاج التطبيق إلى حساب أو خادم.'))),
    const Card(child:ListTile(leading:Icon(Icons.info_outline),title:Text('MY APP — إصدار 1.0'),
      subtitle:Text('المنتجات والمخزون والمبيعات والمشتريات والتقارير والنسخ الاحتياطي.'))),
  ]);
}

String money(Object? value)=>((value as num?)??0).toStringAsFixed(2)+' ج.م';
Future<bool?> ask(BuildContext context,String title,String body)=>showDialog<bool>(context:context,builder:(c)=>Directionality(textDirection:TextDirection.rtl,
  child:AlertDialog(title:Text(title),content:Text(body),actions:[
    TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),
    FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('تأكيد'))])));
void toast(BuildContext context,String text)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(text),duration:const Duration(seconds:5)));
