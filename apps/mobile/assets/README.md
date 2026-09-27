# Illustrated design assets

The `illustrations/moments.png`, `illustrations/receipt-story.png` and `illustrations/shared-home.png` assets were generated using OpenAI's built-in image generation tool for the user-approved Hisaab v3 mockups. They are bundled locally; the app does not fetch illustration assets at runtime. These scenes are decorative; adjacent text describes the actual account, group or receipt state.

Outfit headings and Work Sans body fonts come from Google Fonts. The original SIL Open Font License notices are included in `fonts/Outfit-OFL.txt` and `fonts/WorkSans-OFL.txt`. Font families and supported weights are declared in `pubspec.yaml`.

Palette and component defaults live in `lib/core/design.dart`. The shared `EditorialArtwork` widget in `lib/features/shared.dart` constrains decoded image width to the rendered size and excludes decorative images from screen reader output.
