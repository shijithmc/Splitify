# Illustrated design assets

The six `illustrations/*-v2.png` scenes were generated using OpenAI's built-in image generation tool for the approved illustrative redesign. Prompt provenance is recorded in `docs/design/illustration-prompts.json` at the repository root. They are bundled locally; the app does not fetch illustration assets at runtime. These scenes are decorative; adjacent text describes the actual account, group or receipt state.

Outfit headings come from Google Fonts. Body text and controls use platform fonts; the previously bundled Work Sans family remains available. The original SIL Open Font License notices are included in `fonts/Outfit-OFL.txt` and `fonts/WorkSans-OFL.txt`. Font families and supported weights are declared in `pubspec.yaml`.

Palette and component defaults live in `lib/core/design.dart`. The shared `EditorialArtwork` widget in `lib/features/shared.dart` constrains decoded image width to the rendered size and excludes decorative images from screen reader output.
