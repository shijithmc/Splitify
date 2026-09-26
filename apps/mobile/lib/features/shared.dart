import 'package:flutter/material.dart';
import '../core/controller.dart';
import '../main.dart';

Future<T?> openPage<T>(
  BuildContext context,
  AppController c,
  Widget page,
) async {
  c.protect(true);
  try {
    return await Navigator.of(
      context,
    ).push<T>(MaterialPageRoute(builder: (_) => page));
  } finally {
    c.protect(false);
  }
}

void message(BuildContext context, Object text) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$text'), behavior: SnackBarBehavior.floating),
    );
  }
}

Future<void> act(BuildContext context, Future<void> Function() callback) async {
  try {
    await callback();
  } catch (e) {
    if (context.mounted) message(context, e);
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = 'Confirm',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
Future<String?> askText(
  BuildContext context,
  String title,
  String label, {
  String initial = '',
  int maxLength = 100,
}) async {
  final input = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: input,
        autofocus: true,
        maxLength: maxLength,
        decoration: InputDecoration(labelText: label),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (input.text.trim().isNotEmpty) {
              Navigator.pop(context, input.text.trim());
            }
          },
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  // Dialog route may still animate with the controller attached.
  return value;
}

class SectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionTitle(this.title, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 14),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              letterSpacing: -.5,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class EmptyCard extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final Widget? action;
  const EmptyCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          Icon(icon, size: 44, color: green),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}

class PageBody extends StatelessWidget {
  final List<Widget> children;
  const PageBody({super.key, required this.children});
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(22, 12, 22, 40),
    children: children,
  );
}
