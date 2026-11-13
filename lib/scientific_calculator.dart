import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:math_expressions/math_expressions.dart';

class ScientificCalculatorPage extends StatefulWidget {
  const ScientificCalculatorPage({super.key});
  @override
  State<ScientificCalculatorPage> createState() => _ScientificCalculatorPageState();
}

class _ScientificCalculatorPageState extends State<ScientificCalculatorPage> {
  String expression = '';
  String result = '0';
  String angle = 'DEG';
  String format = 'NORM';
  String answer = '0';
  String memory = '0';
  bool shift = false;
  final List<String> history = [];

  final List<List<String>> keys = const [
    ['SHIFT', '(', ')', 'DEL', 'AC'],
    ['sin', 'cos', 'tan', '√', 'x²'],
    ['log', 'ln', 'abs', 'π', 'e'],
    ['7', '8', '9', '÷', 'mod'],
    ['4', '5', '6', '×', '−'],
    ['1', '2', '3', '0', '+'],
    ['.', 'Ans', 'xʸ', '1/x', '='],
  ];

  void press(String key) {
    setState(() {
      if (key == 'AC') { expression = ''; result = '0'; return; }
      if (key == 'DEL') {
        if (expression.isNotEmpty) expression = expression.substring(0, expression.length - 1);
        return;
      }
      if (key == 'SHIFT') { shift = !shift; return; }
      if (key == '=') { calculate(); return; }
      if (key == 'Ans') { expression += answer; return; }
      if (key == 'π') { expression += 'pi'; return; }
      if (key == 'e') { expression += 'e'; return; }
      if (key == '√') { expression += 'sqrt('; return; }
      if (key == 'x²') { expression += '^2'; return; }
      if (key == 'xʸ') { expression += '^'; return; }
      if (key == '1/x') { expression = '1/($expression)'; return; }
      if (key == 'mod') { expression += '%'; return; }
      if (['sin','cos','tan','log','ln','abs'].contains(key)) {
        final inverse = <String,String>{'sin':'asin','cos':'acos','tan':'atan','log':'10^(','ln':'exp(','abs':'abs'}[key]!;
        expression += (shift && key != 'log' && key != 'ln') ? '$inverse(' : '$key(';
        shift = false;
        return;
      }
      if (key == '÷') { expression += '/'; }
      else if (key == '×') { expression += '*'; }
      else if (key == '−') { expression += '-'; }
      else { expression += key; }
    });
  }

  String normalize(String source) {
    var value = source.replaceAll('×','*').replaceAll('÷','/').replaceAll('−','-');
    value = value.replaceAll('π','pi');
    if (angle == 'DEG') {
      value = value.replaceAllMapped(
        RegExp(r'(sin|cos|tan)\(([-+]?\d+(?:\.\d+)?)\)'),
        (m) => '${m.group(1)}((${m.group(2)}*pi/180))',
      );
    }
    return value;
  }

  void calculate() {
    if (expression.trim().isEmpty) return;
    try {
      final parsed = Parser().parse(normalize(expression));
      final value = parsed.evaluate(EvaluationType.REAL, ContextModel());
      if (!value.isFinite) throw const FormatException('نتيجة غير صالحة');
      final formatted = format == 'SCI'
          ? value.toStringAsExponential(8)
          : format.startsWith('FIX')
              ? value.toStringAsFixed(int.tryParse(format.substring(3)) ?? 2)
              : value == value.roundToDouble()
                  ? value.toInt().toString()
                  : value.toStringAsPrecision(12);
      setState(() {
        result = formatted;
        answer = value.toString();
        history.insert(0, '$expression = $formatted');
        if (history.length > 200) history.removeLast();
        shift = false;
      });
    } catch (_) {
      setState(() => result = 'خطأ في التعبير');
    }
  }

  void memoryAction(String action) {
    final current = double.tryParse(answer) ?? 0;
    setState(() {
      if (action == 'MC') memory = '0';
      if (action == 'MR') expression += memory;
      if (action == 'MS') memory = current.toString();
      if (action == 'M+') memory = ((double.tryParse(memory) ?? 0) + current).toString();
      if (action == 'M-') memory = ((double.tryParse(memory) ?? 0) - current).toString();
    });
  }

  Widget buildKey(String key) {
    final special = ['SHIFT','DEL','AC','='].contains(key);
    final operator = ['÷','×','−','+','xʸ','mod'].contains(key);
    final scheme = Theme.of(context).colorScheme;
    final color = key == '=' ? scheme.primary : key == 'AC' ? scheme.errorContainer :
        special ? scheme.secondaryContainer : operator ? scheme.tertiaryContainer : scheme.surfaceContainerHighest;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: AspectRatio(
          aspectRatio: 1.35,
          child: Material(
            color: color,
            borderRadius: BorderRadius.circular(13),
            child: InkWell(
              borderRadius: BorderRadius.circular(13),
              onTap: () => press(key),
              child: Center(
                child: Text(key, style: TextStyle(
                  fontSize: key.length > 4 ? 12 : 17,
                  fontWeight: FontWeight.w800,
                  color: key == '=' ? Colors.white : scheme.onSurface,
                )),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void showHistory() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          children: [
            const ListTile(title: Text('سجل العمليات', style: TextStyle(fontWeight: FontWeight.bold))),
            ...history.map((item) => ListTile(
              title: Text(item),
              onTap: () {
                setState(() => expression = item.split(' = ').first);
                Navigator.pop(sheetContext);
              },
            )),
            if (history.isEmpty) const ListTile(title: Text('لا توجد عمليات سابقة')),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              Row(children: [
                const Expanded(child: Text('Scientific Calculator', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900))),
                IconButton(onPressed: showHistory, icon: const Icon(Icons.history)),
              ]),
              Card(
                color: scheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Text(angle, style: const TextStyle(fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Text('MEM: $memory'),
                      if (shift) const Text('  SHIFT', style: TextStyle(color: Colors.orange)),
                    ]),
                    const SizedBox(height: 18),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(expression.isEmpty ? '0' : expression, style: const TextStyle(fontSize: 24)),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(result, textAlign: TextAlign.right, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w900)),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'DEG', label: Text('DEG')),
                    ButtonSegment(value: 'RAD', label: Text('RAD')),
                  ],
                  selected: {angle},
                  onSelectionChanged: (values) => setState(() => angle = values.first),
                )),
                const SizedBox(width: 8),
                Expanded(child: DropdownButtonFormField<String>(
                  initialValue: format,
                  decoration: const InputDecoration(labelText: 'Format'),
                  items: ['NORM','SCI','FIX2','FIX4','FIX6'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                  onChanged: (v) => setState(() => format = v ?? 'NORM'),
                )),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 6, children: ['MC','MR','MS','M+','M-'].map((v) =>
                OutlinedButton(onPressed: () => memoryAction(v), child: Text(v))).toList()),
              for (final row in keys) Row(children: row.map(buildKey).toList()),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(onPressed: () => Clipboard.setData(ClipboardData(text: result)), icon: const Icon(Icons.copy), label: const Text('Copy result')),
                OutlinedButton.icon(onPressed: () => setState(() => expression = ''), icon: const Icon(Icons.clear_all), label: const Text('Clear expression')),
                OutlinedButton.icon(onPressed: () => setState(() => history.clear()), icon: const Icon(Icons.delete_sweep), label: const Text('Clear history')),
              ]),
              const Text('يدعم العمليات الحسابية، الأقواس، الأسس، الجذور، الدوال المثلثية واللوغاريتمية، DEG/RAD، الذاكرة، وسجل العمليات.', textDirection: TextDirection.rtl, style: TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}
