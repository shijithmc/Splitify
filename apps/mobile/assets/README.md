# Illustrated design assets

The six `illustrations/*-v3.webp` assets were generated using OpenAI's built-in image generation tool from the approved warm Hisaab mockup. Prompt provenance is recorded in `docs/design/illustration-prompts.json` at the repository root. Scenes are encoded as WebP at quality 90, with maximum widths of 1400 pixels for wide scenes and 768 pixels for small illustrations. The receipt mascot preserves its transparent background. The complete set is approximately 288 KiB and replaces the previous PNG set. They are bundled locally; the app does not fetch illustration assets at runtime. These scenes are decorative; adjacent text describes the actual account, group or receipt state. Welcome and generic group states share the couch scene.

Outfit headings and Work Sans body text come from the existing bundled Google Fonts families. The original SIL Open Font License notices are included in `fonts/Outfit-OFL.txt` and `fonts/WorkSans-OFL.txt`. Font families and supported weights are declared in `pubspec.yaml`.

Palette and component defaults live in `lib/core/design.dart`. The shared `EditorialArtwork` widget in `lib/features/shared.dart` constrains decoded image width to the rendered size and excludes decorative images from screen reader output.
