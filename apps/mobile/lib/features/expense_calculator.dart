import 'package:flutter/material.dart';
import '../core/amount_calculator.dart';
import '../core/design.dart';
import '../core/money.dart';

class ExpenseCalculatorPage extends StatefulWidget {
  final String initialAmount;
  const ExpenseCalculatorPage({super.key, this.initialAmount = ''});

  @override
  State<ExpenseCalculatorPage> createState() => _ExpenseCalculatorPageState();
}

class _ExpenseCalculatorPageState extends State<ExpenseCalculatorPage> {
  late final TextEditingController expression;

  @override
  void initState() {
    super.initState();
    expression = TextEditingController(text: widget.initialAmount);
    expression.selection = TextSelection.collapsed(
      offset: expression.text.length,
    );
    expression.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    expression.removeListener(_changed);
    expression.dispose();
    super.dispose();
  }

  void _insert(String value) {
    final selection = expression.selection;
    final start = selection.isValid ? selection.start : expression.text.length;
    final end = selection.isValid ? selection.end : start;
    final text = expression.text.replaceRange(start, end, value);
    if (text.length > maxCalculatorExpressionLength) return;
    expression.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + value.length),
    );
  }

  void _delete() {
    final selection = expression.selection;
    final end = selection.isValid ? selection.end : expression.text.length;
    final start = selection.isValid && !selection.isCollapsed
        ? selection.start
        : end > 0
        ? end - 1
        : 0;
    expression.value = TextEditingValue(
      text: expression.text.replaceRange(start, end, ''),
      selection: TextSelection.collapsed(offset: start),
    );
  }

  @override
  Widget build(BuildContext context) {
    int? amount;
    String? error;
    if (expression.text.trim().isNotEmpty) {
      try {
        amount = calculateAmountPaise(expression.text);
      } on FormatException catch (e) {
        error = e.message;
      }
    }
    final result = amount;
    return Scaffold(
      appBar: AppBar(title: const Text('Calculator')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'A little maths, made easy.',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text('Add up the bill, then bring the total back.'),
                  const SizedBox(height: 24),
                  TextField(
                    key: const Key('calculator-expression'),
                    controller: expression,
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    enableSuggestions: false,
                    minLines: 1,
                    maxLines: 3,
                    maxLength: maxCalculatorExpressionLength,
                    decoration: const InputDecoration(
                      labelText: 'Calculation in rupees',
                      hintText: 'e.g. 240 + 60 ÷ 2',
                      counterText: '',
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: expression.text.isEmpty
                          ? null
                          : expression.clear,
                      child: const Text('Clear'),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: HisaabColors.mint,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Semantics(
                      liveRegion: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('TOTAL'),
                          const SizedBox(height: 8),
                          Text(
                            result == null ? '—' : money(result),
                            key: const Key('calculator-result'),
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            error ?? 'Rounded to the nearest paise.',
                            style: TextStyle(
                              color: error == null
                                  ? HisaabColors.muted
                                  : HisaabColors.warning,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  for (final row in const [
                    ['7', '8', '9', '÷'],
                    ['4', '5', '6', '×'],
                    ['1', '2', '3', '−'],
                    ['.', '0', '⌫', '+'],
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          for (var i = 0; i < row.length; i++) ...[
                            if (i > 0) const SizedBox(width: 8),
                            Expanded(child: _key(row[i])),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('calculator-use'),
                    onPressed: result == null
                        ? null
                        : () => Navigator.pop<int>(context, result),
                    child: Text(
                      result == null ? 'Use amount' : 'Use ${money(result)}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Multiply and divide first. Add and subtract after.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: HisaabColors.muted, fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _key(String value) {
    final label = switch (value) {
      '÷' => 'Divide',
      '×' => 'Multiply',
      '−' => 'Subtract',
      '+' => 'Add',
      '.' => 'Decimal point',
      '⌫' => 'Delete last character',
      _ => value,
    };
    return OutlinedButton(
      key: Key('calculator-key-$value'),
      onPressed: value == '⌫' ? _delete : () => _insert(value),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 56),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        backgroundColor: ['÷', '×', '−', '+'].contains(value)
            ? HisaabColors.mint
            : Colors.white,
      ),
      child: value == '⌫'
          ? const Icon(
              Icons.backspace_outlined,
              semanticLabel: 'Delete last character',
            )
          : Text(
              value,
              semanticsLabel: label,
              style: const TextStyle(fontSize: 22),
            ),
    );
  }
}
