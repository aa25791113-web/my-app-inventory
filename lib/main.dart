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
  await InventoryDb.instance.init();
  runApp(const MyApp());
}

class InventoryDb {
  InventoryDb._();
  static final instance = InventoryDb._();
  Database? database;
  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    database = await openDatabase(p.join(dir.path, 'my_app.sqlite'), version: 1,
      onCreate: (db, v) => db.execute('CREATE TABLE products(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, category TEXT NOT NULL DEFAULT "", qty INTEGER NOT NULL DEFAULT 0, min_qty INTEGER NOT NULL DEFAULT 0, buy REAL NOT NULL DEFAULT 0, sell REAL NOT NULL DEFAULT 0)'));
  }
  Future<List<Map<String,Object?>>> list(String q) => database!.query('products',
    where: q.isEmpty ? null : 'name LIKE ? OR category LIKE ?', whereArgs: q.isEmpty ? null : ['%$q%','%$q%'], orderBy: 'name');
  Future<void> save(Map<String,Object?> data, int? id) async {
    if (id == null) { await database!.insert('products', data); }
    else { await database!.update('products', data, where: 'id=?', whereArgs: [id]); }
  }
  Future<void> remove(int id) async { await database!.delete('products', where: 'id=?', whereArgs: [id]); }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override State<MyApp> createState() => _MyAppState();
}
class _MyAppState extends State<MyApp> {
  ThemeMode mode = ThemeMode.light;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => mode = p.getBool('dark') == true ? ThemeMode.dark : ThemeMode.light);
  }
  Future<void> _toggle() async {
    final dark = mode != ThemeMode.dark;
    final p = await SharedPreferences.getInstance();
    await p.setBool('dark', dark);
    if (mounted) setState(() => mode = dark ? ThemeMode.dark : ThemeMode.light);
  }
  ThemeData theme(Brightness b) => ThemeData(useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF087F68), brightness: b));
  @override Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false, title: 'MY APP', theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark), themeMode: mode,
    home: StockPage(dark: mode == ThemeMode.dark, toggle: _toggle));
}

class StockPage extends StatefulWidget {
  const StockPage({super.key, required this.dark, required this.toggle});
  final bool dark; final VoidCallback toggle;
  @override State<StockPage> createState() => _StockPageState();
}
class _StockPageState extends State<StockPage> {
  final search = TextEditingController();
  List<Map<String,Object?>> items = [];
  bool loading = true;
  @override void initState() { super.initState(); refresh(); }
  @override void dispose() { search.dispose(); super.dispose(); }
  Future<void> refresh() async {
    final data = await InventoryDb.instance.list(search.text.trim());
    if (mounted) setState(() { items = data; loading = false; });
  }
  Future<void> edit([Map<String,Object?>? item]) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => ProductForm(item: item));
    if (ok == true) refresh();
  }
  Future<void> remove(Map<String,Object?> item) async {
    final yes = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('حذف المنتج'), content: Text('حذف ${item['name']}؟'),
      actions: [TextButton(onPressed: () => Navigator.pop(c,false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(c,true), child: const Text('حذف'))]));
    if (yes == true) { await InventoryDb.instance.remove(item['id'] as int); refresh(); }
  }
  Widget metric(String label, String value, IconData icon) => Expanded(child: Card(
    child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
      Icon(icon), const SizedBox(height: 6), Text(value, style: const TextStyle(fontSize: 20,fontWeight: FontWeight.bold)),
      Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11))]))));
  @override Widget build(BuildContext context) {
    final total = items.fold<int>(0,(s,e)=>s+(e['qty'] as int));
    final low = items.where((e)=>(e['qty'] as int)<=(e['min_qty'] as int)).length;
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('MY APP',style: TextStyle(fontWeight: FontWeight.w900)), Text('إدارة المخزون',style: TextStyle(fontSize: 12))]),
        actions: [IconButton(onPressed: widget.toggle, icon: Icon(Icons.contrast), tooltip: 'تغيير المظهر')]),
      floatingActionButton: FloatingActionButton.extended(onPressed: ()=>edit(), icon: const Icon(Icons.add), label: const Text('إضافة منتج')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [metric('المنتجات','${items.length}',Icons.inventory_2),metric('إجمالي الكمية','$total',Icons.stacked_bar_chart),metric('نواقص المخزون','$low',Icons.warning_amber)]),
        const SizedBox(height: 12),
        TextField(controller: search,onChanged: (_)=>refresh(),decoration: InputDecoration(hintText:'ابحث عن منتج أو تصنيف',prefixIcon: const Icon(Icons.search),border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)))),
        const SizedBox(height: 16), const Text('المنتجات',style: TextStyle(fontSize:20,fontWeight:FontWeight.bold)),
        if (loading) const Center(child:CircularProgressIndicator())
        else if (items.isEmpty) const Padding(padding: EdgeInsets.all(30),child: Center(child:Text('لا توجد منتجات. أضف أول منتج من الزر بالأسفل.')))
        else ...items.map((e)=>Card(child:ListTile(
          leading: const CircleAvatar(child:Icon(Icons.inventory_2_outlined)),
          title: Text(e['name'] as String),
          subtitle: Text('${e['category']} • الكمية: ${e['qty']} • سعر البيع: ${e['sell']}'),
          trailing: Wrap(children:[
            if ((e['qty'] as int)<=(e['min_qty'] as int)) const Icon(Icons.warning_amber,color:Colors.orange),
            IconButton(onPressed:()=>edit(e),icon:const Icon(Icons.edit_outlined)),
            IconButton(onPressed:()=>remove(e),icon:const Icon(Icons.delete_outline))])))),
        const Padding(padding: EdgeInsets.all(16),child: Text('تُحفظ البيانات على هذا الجهاز دون الحاجة للإنترنت',textAlign:TextAlign.center))
      ])));
  }
}

class ProductForm extends StatefulWidget {
  const ProductForm({super.key,this.item});
  final Map<String,Object?>? item;
  @override State<ProductForm> createState()=>_ProductFormState();
}
class _ProductFormState extends State<ProductForm> {
  final form=GlobalKey<FormState>();
  late final TextEditingController name,category,qty,min,buy,sell;
  @override void initState(){
    super.initState(); final e=widget.item;
    name=TextEditingController(text:e?['name'] as String? ?? '');
    category=TextEditingController(text:e?['category'] as String? ?? '');
    qty=TextEditingController(text:'${e?['qty'] ?? 0}');
    min=TextEditingController(text:'${e?['min_qty'] ?? 0}');
    buy=TextEditingController(text:'${e?['buy'] ?? 0}');
    sell=TextEditingController(text:'${e?['sell'] ?? 0}');
  }
  @override void dispose(){for(final c in [name,category,qty,min,buy,sell]){c.dispose();}super.dispose();}
  String? requiredText(String? v)=>v==null||v.trim().isEmpty?'مطلوب':null;
  String? number(String? v)=>int.tryParse(v??'')==null||int.parse(v!)<0?'أدخل رقماً صحيحاً':null;
  String? price(String? v)=>double.tryParse(v??'')==null||double.parse(v!)<0?'أدخل سعراً صحيحاً':null;
  Widget field(TextEditingController c,String label,{String? Function(String?)? validate,TextInputType? type})=>
    Padding(padding:const EdgeInsets.only(bottom:10),child:TextFormField(controller:c,validator:validate,keyboardType:type,decoration:InputDecoration(labelText:label,border:const OutlineInputBorder())));
  Future<void> save() async {
    if(!form.currentState!.validate())return;
    await InventoryDb.instance.save({'name':name.text.trim(),'category':category.text.trim(),
      'qty':int.parse(qty.text),'min_qty':int.parse(min.text),'buy':double.parse(buy.text),'sell':double.parse(sell.text)},widget.item?['id'] as int?);
    if(mounted)Navigator.pop(context,true);
  }
  @override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:AlertDialog(
    title:Text(widget.item==null?'إضافة منتج':'تعديل منتج'),
    content:SizedBox(width:420,child:Form(key:form,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      field(name,'اسم المنتج',validate:requiredText),field(category,'التصنيف'),
      Row(children:[Expanded(child:field(qty,'الكمية',validate:number,type:TextInputType.number)),const SizedBox(width:8),Expanded(child:field(min,'حد التنبيه',validate:number,type:TextInputType.number))]),
      Row(children:[Expanded(child:field(buy,'سعر الشراء',validate:price,type:const TextInputType.numberWithOptions(decimal:true))),const SizedBox(width:8),Expanded(child:field(sell,'سعر البيع',validate:price,type:const TextInputType.numberWithOptions(decimal:true)))])
    ])))),
    actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('إلغاء')),FilledButton(onPressed:save,child:const Text('حفظ'))]));
}
