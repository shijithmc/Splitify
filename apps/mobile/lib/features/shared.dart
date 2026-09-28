import 'package:flutter/material.dart';
import '../core/controller.dart';
import '../core/design.dart';
import '../core/native_services.dart';

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
  } on IdentityCancelled {
    // Canceling a provider prompt is also valid during linking or deletion.
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
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontFamily: 'Outfit',
              fontSize: 18,
              fontWeight: FontWeight.w600,
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
  final String? illustrationAsset;
  const EmptyCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.illustrationAsset,
  });
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          if (illustrationAsset case final asset?)
            EditorialArtwork(asset: asset, height: 160)
          else
            ExcludeSemantics(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: HisaabColors.lilac,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 32, color: HisaabColors.primary),
              ),
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: children,
      ),
    ),
  );
}

/// Bundled decorative artwork; the adjacent copy carries its meaning.
class EditorialArtwork extends StatelessWidget {
  final String asset;
  final double? height;
  final BorderRadius? borderRadius;
  final BoxFit fit;
  const EditorialArtwork({
    super.key,
    required this.asset,
    this.height,
    this.borderRadius,
    this.fit = BoxFit.contain,
  });

  @override
  Widget build(BuildContext context) {
    final artwork = ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(22),
      child: LayoutBuilder(
        builder: (context, constraints) => Image.asset(
          asset,
          width: double.infinity,
          height: height,
          fit: fit,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
          cacheWidth: constraints.hasBoundedWidth
              ? (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                    .round()
                    .clamp(1, 1536)
              : 1024,
        ),
      ),
    );
    return height == null
        ? AspectRatio(aspectRatio: 3 / 2, child: artwork)
        : SizedBox(height: height, child: artwork);
  }
}

/// Group names and types remain visible alongside this decorative thumbnail.
class GroupArtwork extends StatelessWidget {
  final String type;
  final double size;
  const GroupArtwork({super.key, required this.type, this.size = 64});
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: EditorialArtwork(
      asset: HisaabArt.forGroup(type),
      height: size,
      borderRadius: BorderRadius.circular(16),
      fit: BoxFit.contain,
    ),
  );
}
