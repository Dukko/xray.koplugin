# X-Ray Plugin for KOReader (Entity Footnotes patch)

![Platform](https://img.shields.io/badge/platform-KOReader-green.svg)
![License](https://img.shields.io/badge/license-MIT-yellow.svg)
![Status](https://img.shields.io/badge/status-community--patch-blue.svg)

> **This is a community patch, not the official plugin.** It's a fork of
> [ultimatejimmy/xray.koplugin](https://github.com/ultimatejimmy/xray.koplugin) that adds one extra
> feature: **Entity Footnotes**, which underlines AI-identified characters, locations, historical
> figures, and terms directly in the reading text and shows their description on tap - the same
> in-text interaction the original already has for unit conversions. See
> [ultimatejimmy/xray.koplugin#100](https://github.com/ultimatejimmy/xray.koplugin/pull/100) for the
> full discussion.
>
> It wasn't merged upstream because scanning has to re-run every time the AI finds new entities
> while you read (not just once at book open like the unit converter), and on some e-ink devices
> that scan is still perceptible even though it no longer blocks input. If you're comfortable with
> that tradeoff, this patch is for you. For everyone else, use the
> [official plugin](https://github.com/ultimatejimmy/xray.koplugin) - all credit for X-Ray itself
> goes to [ultimatejimmy](https://github.com/ultimatejimmy).
>
> This patch has its own update channel (see `xray_updater.lua`), separate from the official
> plugin's, so the built-in update checker won't silently replace it with vanilla upstream.

This plugin brings Kindle-style X-Ray features to KOReader. It uses AI to track characters, build plot timelines, and provide insights while you read.

<p align="center">
  <img src="https://github.com/ultimatejimmy/koreader-xray-plugin/wiki/img/menu_main.png" width="45%" />
  <img src="https://github.com/ultimatejimmy/koreader-xray-plugin/wiki/img/character_detail.png" width="45%" />
</p>

## What it does

- **AI-Powered Insights**: Supports Google Gemini, OpenAI, **DeepSeek**, **Claude**, and **Custom API** providers (like OpenRouter).
- **Character Tracking**: View bios and roles. Now supports **Merging Duplicates** with AI-consolidated summaries.
- **Customizable Detail**: Choose between short or long AI descriptions to fit your preference.
- **Linked Entries**: Automatically connect related characters and locations through smart cross-referencing.
- **Plot Timeline**: Keeps track of major events chapter by chapter, strictly sorted by physical page location for accuracy.
- **Historical Context**: Pulls real-world info for historical figures and locations.
- **Mention Scanning**: Find every occurrence of a character or location throughout the book, complete with page numbers and context snippets for quick navigation.
- **Spoiler Protection**: "Spoiler-free" mode only reads up to your current page so future twists aren't ruined.
- **Auto Fetching while you read**: Automatically fetches data in the background when you get to a new chapter.
- **X-Ray Mode & Inline Fetching**: Get instant lookups by tapping the "X-Ray" button in dictionary or selection popups. If an entity is missing, the plugin can fetch it on-the-fly using AI without requiring a full book scan.
- **Entity Footnotes** *(patch-only)*: Underlines AI-identified characters, locations, historical figures, and terms directly in the text, with a tap-to-reveal footnote popup. Runs as a chunked background scan so page turns stay responsive. Toggle it and its categories from the X-Ray menu.
- **Silent Weekly Updates**: Automatically checks for new plugin versions in the background once a week.
- **Offline First**: You only need internet to fetch the data. After that, it's saved locally.
- **Multilingual**: Available in English, German, French, Spanish, Brazilian Portuguese, Russian, Ukrainian, Turkish, Simplified Chinese, Dutch, Hungarian, Polish, Indonesian, Arabic, Italian, Serbian, and Japanese.

## Documentation

For full setup instructions and a deep dive into features, check out the **[GitHub Wiki](https://github.com/ultimatejimmy/koreader-xray-plugin/wiki)**.

- **[Get Started](https://github.com/ultimatejimmy/koreader-xray-plugin/wiki/1.-Get-Started)**: Installation and API key setup.
- **[Core Content & Features](https://github.com/ultimatejimmy/koreader-xray-plugin/wiki/2.-Core-Features)**: Characters, Timeline, Glossary, and Series recap.
- **[Lookups & Navigation](https://github.com/ultimatejimmy/koreader-xray-plugin/wiki/3.-Lookups-&-Navigation)**: In-text lookups, footnote popup UI, Gestures, and Mention scanning.
- **[Data Management & Settings](https://github.com/ultimatejimmy/koreader-xray-plugin/wiki/4.-Data-Management)**: Merging duplicates, verbosity settings, and language localization.
- **[AI Providers & Models](https://github.com/ultimatejimmy/koreader-xray-plugin/wiki/5.-AI-Providers-&-Models)**: Supported APIs, models, and reasoning effort.
- **[Spoiler Protection](https://github.com/ultimatejimmy/koreader-xray-plugin/wiki/6.-Spoiler-Protection)**: How we keep the story safe.
- **[Fetching Data](https://github.com/ultimatejimmy/koreader-xray-plugin/wiki/7.-Fetching)**: Background fetching, manual fetching, and targeted lookups.
- **[Advanced Configuration & Maintenance](https://github.com/ultimatejimmy/koreader-xray-plugin/wiki/Advanced-Usage)**: Custom endpoints, config files, formats, logs, and maintenance tools.

## Support me

[liberapay](https://liberapay.com/ultimatejimmy)  

[Buy me a coffee](https://www.buymeacoffee.com/ultimatejimmy)

