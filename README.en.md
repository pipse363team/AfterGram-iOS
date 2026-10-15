<div align="center">

# AfterGram for iOS

Telegram for iPhone and iPad that keeps deleted messages.

![iOS / iPadOS](https://img.shields.io/badge/iOS%20%2F%20iPadOS-only-black)
![Telegram 13.0](https://img.shields.io/badge/Telegram-13.0-26A5E4)

[Русский](README.md) · **English** · [Download IPA](https://github.com/pipse363team/AfterGram-iOS/releases)

</div>

When someone deletes a message, AfterGram keeps it in its original place in the chat. It appears at 50% opacity, with a trash icon and a “Deleted” label underneath.

Based on the official Telegram iOS 13.0 client. Adds deleted message retention.

## Features

- Keeps loaded messages when another participant deletes them.
- Retains photos, GIFs, videos, and round video messages when their files have fully downloaded.
- Stores media copies separately from Telegram’s normal cache.
- Downloads media ahead of time for messages you display in a chat.
- Lets you disable retention in **Settings → Deleted Messages**.

**AfterGram is available only for iOS and iPadOS.** It is an unofficial client and is not affiliated with Telegram.

## Plugins

Import `.plugin`, `.py` and Elyx source packages in **Settings → Plugins**. Choose **Prepare for iOS** when supported Android calls need adaptation.

The engine supports native settings and dialogs, text and media operations, Telegram API requests and background tasks. Compatibility depends on the APIs each plugin uses; Xposed and arbitrary Android screens require porting.

[Supported features](docs/aftergram-plugins.md) · [Example plugin](examples/plugins/aftergram_tools.plugin)

## Installation

1. Download **AfterGram-13.0.ipa** from [Releases](https://github.com/pipse363team/AfterGram-iOS/releases).
2. Sign the IPA with your own signing certificate using a compatible installation tool, or use free Apple ID signing through [Sideloadly](https://sideloadly.io/) on Windows or macOS.
3. Install the signed IPA on your iPhone or iPad.
4. If prompted, trust the app in your device settings and enable Developer Mode.

The release IPA needs to be re-signed before installation. App extensions and the Apple Watch app are disabled in this build. Push notification availability depends on the signing setup and provisioning profile.

## How retention works

Open a chat and let the media download. If the message is then deleted from another device, it stays in your local history. Playing a deleted video or GIF requires a complete copy of the file.

AfterGram cannot recover messages your client never received, or files that were not fully downloaded and are no longer available from the server. It does not automatically download the entire history of every chat.

Retained files use storage and survive normal cache clearing. Manually deleting a message removes it from the chat but does not yet guarantee removal of every file copy. These copies are removed with account or app data.

Secret chats, scheduled messages, and some forms of bulk history clearing are not supported yet. Actions that require the original message on the server may stop working after deletion.

## Build it yourself

You can build through GitHub Actions from Windows or another computer without owning a Mac.

1. Fork the repository.
2. Get your **App api_id** and **App api_hash** from [my.telegram.org/apps](https://my.telegram.org/apps).
3. Add them as `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` under **Settings → Secrets and variables → Actions**.
4. In **Actions**, select **Telegram 13.0 with retained messages**, then **Run workflow**. Leave tests enabled.
5. After the build succeeds, download **TelegramRetention-13.0** from **Artifacts**. It contains `TelegramRetention.ipa`, which needs to be re-signed for installation.

Keep API hash values out of source files and README files.

## Found a bug?

[Open an issue](https://github.com/pipse363team/AfterGram-iOS/issues) with your iOS version, the steps you took, and what happened. For retention problems, include the message type and whether the media finished downloading. A screenshot or short screen recording helps.

[How retention is implemented](docs/deleted-message-retention.md) · [Original build guide](docs/upstream-build-guide.md)

Based on [Telegram iOS](https://github.com/TelegramMessenger/Telegram-iOS), tag `release-13.0.0`. Message retention was implemented in this project.
