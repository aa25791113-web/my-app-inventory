import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PremiumAssistantPage extends StatefulWidget {
  const PremiumAssistantPage({super.key,this.onNavigate});
  final ValueChanged<int>? onNavigate;
  @override State<PremiumAssistantPage> createState()=>_PremiumAssistantPageState();
}
class _PremiumAssistantPageState extends State<PremiumAssistantPage>{
  final input=TextEditingController();
  final scroll=ScrollController();
  List<Map<String,dynamic>> chats=[];
  int active=-1;
  bool busy=false;
  static const storeKey='assistant_chats_v2';
  @override void initState(){super.initState();load();}
  @override void dispose(){input.dispose();scroll.dispose();super.dispose();}
  Future<void> load()async{
    final p=await SharedPreferences.getInstance();
    try{chats=(jsonDecode(p.getString(storeKey)??'[]') as List).map((e)=>Map<String,dynamic>.from(e)).toList();}
    catch(_){chats=[];}
    if(chats.isNotEmpty)active=0;
    if(mounted)setState((){});
  }
  Future<void> save()async{final p=await SharedPreferences.getInstance();await p.setString(storeKey,jsonEncode(chats));}
  List<Map<String,dynamic>> get msgs=>active<0?[]:List<Map<String,dynamic>>.from(chats[active]['messages'] as List? ?? []);
  void fresh(){setState((){chats.insert(0,{'title':'محادثة جديدة','messages':[],'updated':DateTime.now().toIso8601String()});active=0;});save();}
  int? _route(String q){
    if(RegExp(r'(فاتور|الفواتير|اعمل لي فاتورة|انشئ فاتورة|إنشاء فاتورة)').hasMatch(q))return 14;
    if(RegExp(r'(النواقص|نواقص المخزون|المنتجات الناقصة)').hasMatch(q))return 19;
    if(RegExp(r'(التقرير|التقارير|احصائيات|إحصائيات)').hasMatch(q))return 8;
    if(RegExp(r'(الاعدادات|الإعدادات|تغيير اللون|الخلفية)').hasMatch(q))return 9;
    if(RegExp(r'(المنتجات|الأصناف|الاصناف|المخزون|المخزن)').hasMatch(q))return 1;
    if(RegExp(r'(الموردين|الموردون|المورد)').hasMatch(q))return 4;
    if(RegExp(r'(العملاء|العميل|الزبون)').hasMatch(q))return 5;
    if(RegExp(r'(المبيعات|بيع منتج|عملية بيع)').hasMatch(q))return 2;
    if(RegExp(r'(المشتريات|شراء بضاعة|عملية شراء)').hasMatch(q))return 3;
    if(RegExp(r'(الآلة الحاسبة|الحاسبة|احسب|احسبلي)').hasMatch(q))return 16;
    if(RegExp(r'(بحث الأسعار|بحث عن سعر|دور على سعر)').hasMatch(q))return 10;
    return null;
  }
  String _answer(String raw){
    final q=raw.trim().toLowerCase();
    if(RegExp(r'^(السلام عليكم|سلام عليكم|السلام|اهلا|أهلا|اهلين|هاي|hi|hello)').hasMatch(q))return 'وعليكم السلام ورحمة الله وبركاته 🌟\\nأهلاً بيك! أنا مساعد APP LOL المحلي. أقدر أشرح لك استخدام البرنامج، أوجّهك للصفحة المطلوبة، وأساعدك في الحسابات والمخزون والفواتير.';
    if(q.contains('شكرا')||q.contains('متشكر'))return 'العفو، تحت أمرك. لو محتاج تنفّذ حاجة داخل البرنامج اكتبها بصيغة واضحة، وهوجّهك للمكان المناسب.';
    if(q.contains('اسمك')||q.contains('انت مين')||q.contains('إنت مين'))return 'أنا مساعد APP LOL. شغلي أساعدك في فهم البرنامج، وأوصلّك لصفحات الفواتير والمخزون والتقارير والإعدادات، وأشرح لك خطوات العمل.';
    if(q.contains('فاتور')||q.contains('الفواتير')){
      return 'لإنشاء فاتورة بيع:\\n1) افتح صفحة «الفواتير».\\n2) اضغط «فاتورة جديدة».\\n3) اكتب اسم العميل ورقم هاتفه إن وجد.\\n4) أضف الأصناف وحدد الكمية والسعر والمورد.\\n5) راجع الخصم والمبلغ المدفوع ثم اضغط «حفظ وإصدار الفاتورة».\\nبعد الحفظ افتح الفاتورة لتعاين التصميم، وتحفظها PNG أو تطبعها PDF.';
    }
    if(q.contains('النواقص')||q.contains('نواقص')){
      return 'صفحة «النواقص» تجمع المنتجات التي عليها حركة بيع أو وصلت إلى حد التنبيه، وتعرضها في مجموعات حسب المورد. لكل صنف هتلاقي المباع والمتبقي وحد التنبيه والكمية المقترحة للطلب. المنتجات التي ليس لها مورد تظهر تحت «بدون مورد».';
    }
    if(q.contains('ربح')||q.contains('مكسب')||q.contains('هامش')){
      return 'الربح الإجمالي للصنف = (سعر البيع − تكلفة الشراء) × الكمية المباعة. مثال: اشتريت القطعة بـ 80 وبعتها بـ 100، يبقى ربح القطعة 20. ده قبل خصم المصروفات وأي تكاليف إضافية. راجع تقرير الأرباح والمبيعات عشان تشوف الصورة الكاملة.';
    }
    if(q.contains('جرد')||q.contains('تسوية')){
      return 'لتسوية المخزون: افتح «المنتجات»، اختار الصنف، ثم استخدم إجراء الجرد/التسوية. اكتب الكمية الفعلية وسبب التسوية واحفظ. راجع الكمية بعد الحفظ وسجل النشاط لو عايز تراجع التغيير.';
    }
    if(q.contains('مورد')&& (q.contains('اضاف')||q.contains('إضاف')||q.contains('جديد'))){
      return 'تقدر تضيف المورد من صفحة «الموردون»، أو من نافذة إضافة صنف داخل الفاتورة عن طريق زر إضافة مورد. اربط الصنف بالمورد الصحيح عشان يظهر ضمن مجموعته في كشف النواقص.';
    }
    if(q.contains('عميل')&&(q.contains('اضاف')||q.contains('إضاف')||q.contains('جديد'))){
      return 'افتح صفحة «العملاء» واضغط إضافة عميل، واكتب الاسم وبيانات التواصل. ويمكن إدخال العميل مباشرة عند إنشاء فاتورة بيع وسيُحفظ في سجل العملاء.';
    }
    if(q.contains('نسخ احتياطي')||q.contains('باك اب')||q.contains('backup')){
      return 'من «الإعدادات» اختار «تصدير نسخة احتياطية إلى ملف» واحفظ ملف JSON في مكان آمن. لاسترجاع البيانات استخدم «استيراد نسخة احتياطية». خليك حريص: الاستيراد يستبدل البيانات الحالية بمحتويات النسخة.';
    }
    if(q.contains('تحديث')||q.contains('update')){
      return 'افتح «الإعدادات» ثم «مركز تحديثات APP LOL» واضغط التحقق. لو فيه إصدار APK كامل هيعرض الإصدار والحجم وملاحظات التحديث. التحديثات الجزئية لا تشمل تغييرات أندرويد أو الصلاحيات أو الإضافات الأصلية.';
    }
    if(q.contains('اشعار')||q.contains('إشعار')||q.contains('اشعارات')||q.contains('إشعارات')){
      return 'من «الإعدادات» افتح «إشعارات الهاتف»، فعّل الإذن من نافذة أندرويد، ثم شغّل التنبيهات المطلوبة: المخزون، الفواتير المستحقة، أو تحديثات التطبيق. لو رفضت الإذن، افتح إعدادات الهاتف ← التطبيقات ← APP LOL ← الإشعارات.';
    }
    if(q.contains('pdf')||q.contains('صورة')||q.contains('اطبع')||q.contains('طباعة')){
      return 'من معاينة الفاتورة تقدر تختار «حفظ صورة» لإنشاء PNG، أو «PDF / طباعة» لفتح معاينة الطباعة. باقي التقارير لها خيارات التصدير والطباعة المتاحة داخل كل تقرير.';
    }
    if(q.contains('مخزون')||q.contains('كمية')){
      return 'رصيد المخزون هو الكمية المتاحة حالياً. عند تسجيل بيع صحيح تُخصم الكمية تلقائياً، وعند تسجيل مشتريات تُضاف الكمية. حد التنبيه تحدده من بيانات الصنف، وكشف النواقص يعرض كذلك الأصناف التي عليها حركة بيع.';
    }
    if(q.contains('السلامة')||q.contains('الذكاء الاصطناعي')||q.contains('ذكاء اصطناعي')){
      return 'الذكاء الاصطناعي هو أنظمة حاسوبية تنفّذ مهام تحتاج عادةً إلى فهم أو استنتاج أو تعرّف على الأنماط. المساعد الموجود هنا يعمل محلياً بقواعد ومعلومات مدمجة؛ لذلك يقدر يشرح وظائف البرنامج وأسئلة شائعة، لكنه ليس نموذجاً لغوياً ضخماً ولا يملك معرفة مفتوحة بكل موضوع.';
    }
    if(q.contains('يعني ايه')||q.contains('ما معنى')||q.contains('اشرح')||q.contains('وضح')){
      return 'أكيد. اكتب المصطلح أو الموضوع نفسه، وأنا هشرحه لك بالمصري وبمثال بسيط، وبعدها أديك خلاصة قصيرة. لو سؤالك عن وظيفة في APP LOL اذكر اسم الصفحة أو الزر.';
    }
    if(q.contains('اكتب')||q.contains('صياغة')||q.contains('رسالة')){
      return 'أقدر أساعدك في صياغة رسالة أو إعلان أو وصف. اكتب الفكرة والجهة اللي هتتبعت لها والنبرة المطلوبة (رسمية أو بسيطة)، وهجهز لك نص مرتب.';
    }
    if(q.contains('جمع')||q.contains('طرح')||q.contains('ضرب')||q.contains('قسمة')||q.contains('نسبة')){
      return 'لو عندك مسألة حسابية اكتبها بالأرقام والعملية المطلوبة. وللحسابات العلمية افتح الآلة العلمية من القائمة. أقدر كمان أوضح لك طريقة حساب النسبة أو هامش الربح خطوة بخطوة.';
    }
    return 'وصلني سؤالك، لكن مفيش عندي حالياً نموذج لغوي كامل أو اتصال بحث مباشر أقدر أعتمد عليه للإجابة عن أي موضوع عشوائي.\\nأقدر أساعدك محلياً في وظائف APP LOL، الفواتير والمخزون والموردين والعملاء والتقارير والحسابات، وأشرح موضوعات عامة شائعة. اكتب سؤالك بشكل محدد أو قلّي اسم الصفحة اللي عايز تشتغل فيها.';
  }
  Future<void> send([String? suggested])async{
    final q=(suggested??input.text).trim();if(q.isEmpty||busy)return;
    if(active<0)fresh();input.clear();
    setState((){
      chats[active]['messages']=[...(chats[active]['messages'] as List),{'role':'user','text':q}];
      if(chats[active]['title']=='محادثة جديدة')chats[active]['title']=q.length>32?q.substring(0,32)+'…':q;
      busy=true;
    });
    await save();
    await Future<void>.delayed(const Duration(milliseconds:180));
    if(!mounted)return;
    final route=_route(q);
    if(route!=null)widget.onNavigate?.call(route);
    final response=route==14?'تمام، فتحت لك صفحة الفواتير. اضغط «فاتورة جديدة» وامشي معاك خطوة بخطوة في إدخال العميل والأصناف وحفظ الفاتورة.':route==19?'فتحت لك كشف النواقص. هتلاقي الأصناف متقسمة حسب المورد، ومع كل صنف الكمية المباعة والمتبقية والمقترح طلبه.':route==8?'فتحت لك صفحة التقارير. اختار التقرير اللي محتاجه وحدد الفترة المناسبة.':route==9?'فتحت لك الإعدادات. اختار الجزء اللي عايز تعدّله.':route==1?'فتحت لك المنتجات. استخدم زر الإضافة أو ابحث عن الصنف المطلوب.':route==4?'فتحت لك صفحة الموردين.':route==5?'فتحت لك صفحة العملاء.':route==2?'فتحت لك صفحة المبيعات.':route==3?'فتحت لك صفحة المشتريات.':route==16?'فتحت لك الآلة العلمية.':route==10?'فتحت لك بحث الأسعار.':_answer(q);
    setState((){
      chats[active]['messages']=[...(chats[active]['messages'] as List),{'role':'assistant','text':response}];
      chats[active]['updated']=DateTime.now().toIso8601String();
      busy=false;
    });
    await save();
    WidgetsBinding.instance.addPostFrameCallback((_){if(scroll.hasClients)scroll.animateTo(scroll.position.maxScrollExtent,duration:const Duration(milliseconds:220),curve:Curves.easeOut);});
  }
  Future<void> delete(int i)async{
    final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('حذف المحادثة؟'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('حذف'))]));
    if(ok==true){setState((){chats.removeAt(i);active=chats.isEmpty?-1:active.clamp(0,chats.length-1);});await save();}
  }
  Widget history()=>SizedBox(width:250,child:Column(children:[
    Padding(padding:const EdgeInsets.all(12),child:Row(children:[const Expanded(child:Text('سجل المحادثات',style:TextStyle(fontWeight:FontWeight.bold,fontSize:17))),IconButton(onPressed:fresh,icon:const Icon(Icons.add_comment))])),
    Expanded(child:ListView.builder(itemCount:chats.length,itemBuilder:(c,i)=>ListTile(selected:i==active,title:Text(chats[i]['title'],maxLines:1,overflow:TextOverflow.ellipsis),onTap:()=>setState(()=>active=i),trailing:IconButton(onPressed:()=>delete(i),icon:const Icon(Icons.delete_outline)))))
  ]));
  @override Widget build(BuildContext context){
    final wide=MediaQuery.of(context).size.width>850;
    final chat=Column(children:[
      Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(gradient:LinearGradient(colors:[Theme.of(context).colorScheme.primary,Theme.of(context).colorScheme.tertiary]),borderRadius:BorderRadius.circular(20)),child:const Row(children:[
        Icon(Icons.auto_awesome,color:Colors.white,size:28),SizedBox(width:12),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('مساعد APP LOL',style:TextStyle(color:Colors.white,fontSize:20,fontWeight:FontWeight.w900)),Text('مساعد محلي للبرنامج والأسئلة الشائعة',style:TextStyle(color:Colors.white70,fontSize:12))])),
        Text('OFFLINE',style:TextStyle(color:Colors.white,fontSize:10,fontWeight:FontWeight.bold)),
      ])),
      const SizedBox(height:10),
      Expanded(child:msgs.isEmpty?Center(child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        Icon(Icons.forum_rounded,size:58,color:Theme.of(context).colorScheme.primary),const SizedBox(height:12),
        const Text('أهلاً بيك، أقدر أساعدك في إيه؟',style:TextStyle(fontSize:19,fontWeight:FontWeight.bold)),
        const SizedBox(height:12),
        Wrap(spacing:8,runSpacing:8,alignment:WrapAlignment.center,children:[
          'اعمل فاتورة جديدة','اعرض النواقص','إزاي أحسب الربح؟','إزاي أعمل نسخة احتياطية؟','افتح التقارير'
        ].map((s)=>ActionChip(label:Text(s),onPressed:()=>send(s))).toList())
      ]))):ListView.builder(controller:scroll,padding:const EdgeInsets.all(8),itemCount:msgs.length+(busy?1:0),itemBuilder:(c,i){
        if(i>=msgs.length)return const Padding(padding:EdgeInsets.all(12),child:LinearProgressIndicator());
        final m=msgs[i];final user=m['role']=='user';
        return Align(alignment:user?Alignment.centerLeft:Alignment.centerRight,child:ConstrainedBox(
          constraints:BoxConstraints(maxWidth:MediaQuery.of(context).size.width*(wide?.62:.82)),
          child:Container(margin:const EdgeInsets.symmetric(vertical:6),padding:const EdgeInsets.all(14),decoration:BoxDecoration(
            color:user?Theme.of(context).colorScheme.primaryContainer:Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius:BorderRadius.only(topLeft:const Radius.circular(18),topRight:const Radius.circular(18),bottomLeft:Radius.circular(user?4:18),bottomRight:Radius.circular(user?18:4)),
          ),child:SelectableText(m['text'].toString(),style:const TextStyle(height:1.55))),
        ));
      })),
      Row(children:[
        Expanded(child:TextField(controller:input,minLines:1,maxLines:5,textInputAction:TextInputAction.send,onSubmitted:(_)=>send(),decoration:InputDecoration(hintText:'اسأل بالمصري أو اكتب طلبك...',prefixIcon:const Icon(Icons.chat_bubble_outline),suffixIcon:IconButton(onPressed:input.clear,icon:const Icon(Icons.close))))),
        const SizedBox(width:8),
        IconButton.filledTonal(onPressed:busy?null:fresh,tooltip:'محادثة جديدة',icon:const Icon(Icons.add_comment_outlined)),
        const SizedBox(width:4),
        IconButton.filled(onPressed:busy?null:()=>send(),tooltip:'إرسال',icon:const Icon(Icons.arrow_upward)),
      ]),
      const Padding(padding:EdgeInsets.only(top:6),child:Text('يعمل محلياً دون إنترنت؛ لا يدّعي معرفة كل موضوع ولا ينفّذ إجراءات مالية تلقائياً.',style:TextStyle(fontSize:10,color:Colors.grey))),
    ]);
    return Directionality(textDirection:TextDirection.rtl,child:wide?Row(children:[history(),const VerticalDivider(width:1),Expanded(child:Padding(padding:const EdgeInsets.all(14),child:chat))]):Padding(padding:const EdgeInsets.all(12),child:chat));
  }
}
