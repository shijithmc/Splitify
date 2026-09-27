import 'package:flutter/material.dart';
import '../core/controller.dart';
import '../core/design.dart';

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
              fontFamily: 'Outfit',
              fontSize: 21,
              fontWeight: FontWeight.w600,
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
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: HisaabColors.lilac,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Icon(icon, size: 44, color: HisaabColors.primary),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
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
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        physics: const AlwaysScrollableScrollPhysics(),
        children: children,
      ),
    ),
  );
}

/// Decorative scene; the adjacent group name/type provide its semantics.
class GroupArtwork extends StatelessWidget {
  final String type;
  final double size;
  const GroupArtwork({super.key, required this.type, this.size = 64});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _GroupScene(type)),
      ),
    ),
  );
}

class _GroupScene extends CustomPainter {
  final String type;
  const _GroupScene(this.type);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 100, size.height / 100);
    final paint = Paint()..isAntiAlias = true;
    void rect(Rect rect, Color color) =>
        canvas.drawRect(rect, paint..color = color);
    void circle(Offset at, double radius, Color color) =>
        canvas.drawCircle(at, radius, paint..color = color);
    rect(
      const Rect.fromLTWH(0, 0, 100, 100),
      type == 'Trip' ? HisaabColors.mint : HisaabColors.lilac,
    );
    if (type == 'Trip') {
      circle(const Offset(76, 25), 12, const Color(0xFFFFD4A9));
      rect(const Rect.fromLTWH(0, 67, 100, 33), const Color(0xFFAADACB));
      final sand = Path()
        ..moveTo(0, 91)
        ..quadraticBezierTo(35, 66, 100, 86)
        ..lineTo(100, 100)
        ..lineTo(0, 100)
        ..close();
      canvas.drawPath(sand, paint..color = const Color(0xFFFFE3B7));
      canvas.drawLine(
        const Offset(30, 89),
        const Offset(44, 34),
        paint
          ..color = const Color(0xFF956846)
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round,
      );
      final leaf = Path()
        ..moveTo(44, 35)
        ..quadraticBezierTo(61, 8, 79, 23)
        ..quadraticBezierTo(53, 23, 44, 35)
        ..moveTo(44, 35)
        ..quadraticBezierTo(9, 11, 11, 47)
        ..quadraticBezierTo(26, 32, 44, 35)
        ..moveTo(44, 35)
        ..quadraticBezierTo(68, 32, 74, 57)
        ..quadraticBezierTo(53, 40, 44, 35);
      canvas.drawPath(
        leaf,
        paint
          ..color = const Color(0xFF398D78)
          ..style = PaintingStyle.fill,
      );
    } else if (type == 'Home') {
      circle(const Offset(82, 21), 12, const Color(0xFFFFDDB8));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(20, 44, 60, 45),
          const Radius.circular(5),
        ),
        paint..color = const Color(0xFF91B4DF),
      );
      final roof = Path()
        ..moveTo(12, 45)
        ..lineTo(50, 18)
        ..lineTo(88, 45);
      canvas.drawPath(
        roof,
        paint
          ..color = const Color(0xFF4E68C0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..strokeJoin = StrokeJoin.round,
      );
      paint.style = PaintingStyle.fill;
      rect(const Rect.fromLTWH(32, 59, 13, 17), const Color(0xFFFFF2CE));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(57, 59, 14, 30),
          const Radius.circular(3),
        ),
        paint..color = const Color(0xFF506FA0),
      );
    } else {
      final colors = [
        const Color(0xFF6388D2),
        const Color(0xFFC99B79),
        const Color(0xFF77AC95),
      ];
      for (var i = 0; i < 3; i++) {
        final x = 24.0 + i * 26;
        circle(Offset(x, i == 1 ? 34 : 44), 10, colors[i]);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x - 12, i == 1 ? 49 : 59, 24, 27),
            const Radius.circular(9),
          ),
          paint..color = colors[i],
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GroupScene oldDelegate) =>
      oldDelegate.type != type;
}
