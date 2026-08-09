# Entity Footnotes - a KOReader user patch for xray.koplugin

![Platform](https://img.shields.io/badge/platform-KOReader-green.svg)
![License](https://img.shields.io/badge/license-MIT-yellow.svg)
![Status](https://img.shields.io/badge/status-community--patch-blue.svg)

A [KOReader user patch](https://github.com/koreader/koreader/wiki/User-patches) that adds
**Entity Footnotes** to [ultimatejimmy/xray.koplugin](https://github.com/ultimatejimmy/xray.koplugin):
it underlines AI-identified characters, historical figures, locations, and terms directly in
the reading text, and shows the AI-written description in a tap-to-reveal popup - the same
in-text interaction the plugin already has for unit conversions. Scanning runs as a chunked,
non-blocking background task so page turns stay responsive.

See [ultimatejimmy/xray.koplugin#100](https://github.com/ultimatejimmy/xray.koplugin/pull/100)
for the full background: this started as a PR against the plugin itself, but the maintainer
preferred it ship as an optional user patch rather than a permanent part of the plugin, since
the scan has to re-run every time the AI finds new entities (not just once at book open), and
that's more than they want to guarantee UX for on all e-ink devices. This patch takes that
route: it doesn't fork or modify xray.koplugin at all, it just monkey-patches the plugin's
class table at runtime, the same technique xray.koplugin already uses internally for its own
unit-converter underline/tap handling.

All credit for X-Ray itself goes to [ultimatejimmy](https://github.com/ultimatejimmy) - this
repo only adds the one patch file.

## Requirements

- KOReader
- [xray.koplugin](https://github.com/ultimatejimmy/xray.koplugin) installed and set up (API
  key configured, at least one character/location/term fetched for the book you're reading)

## Install

1. Download [`2-xray-entity-footnotes.lua`](https://github.com/Dukko/xray.koplugin/releases/latest)
   from the latest release.
2. Copy it into `koreader/patches/2-xray-entity-footnotes.lua`.
3. Restart KOReader.
4. Open a book, tap the X-Ray menu, and look for **Entity Footnotes** to enable it, pick
   categories, or trigger a manual rescan.

Since this is a patch, not a plugin, it updates independently of xray.koplugin. Updating
xray.koplugin itself (through its own built-in updater or manually) won't touch or remove
this file, and updating this patch never touches xray.koplugin.

## Updating

Replace `koreader/patches/2-xray-entity-footnotes.lua` with the newest version from
[Releases](https://github.com/Dukko/xray.koplugin/releases) and restart KOReader. Watch this
repo (Watch -> Custom -> Releases) on GitHub to get notified when a new version is out.

## Known limitations

- English-only. As an external patch it can't add entries to xray.koplugin's own
  localization files, so menu/notification text falls back to English regardless of your
  KOReader language.
- Scanning is chunked to avoid blocking input, but on slower e-ink devices with very large
  entity lists it can still be briefly perceptible.
