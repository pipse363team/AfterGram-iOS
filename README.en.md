<div align="center">

# AfterGram for iOS

An unofficial Telegram client for iPhone and iPad that keeps messages you have already received when someone deletes them.

![iOS / iPadOS](https://img.shields.io/badge/iOS%20%2F%20iPadOS-only-black)
![Telegram 13.0](https://img.shields.io/badge/Telegram-13.0-26A5E4)

[Русский](README.md) · **English** · [Download IPA](https://github.com/pipse363team/AfterGram-iOS/releases/download/latest/TelegramRetention.ipa) · [All releases](https://github.com/pipse363team/AfterGram-iOS/releases)

</div>

AfterGram is based on Telegram iOS 13.0. A deleted message stays in its original place in the chat, dimmed with a trash icon and a “Deleted” label.

## What it does

- Keeps messages your device received when another participant deletes them.
- Retains photos, GIFs, videos, and round video messages if the file finished downloading.
- Stores media copies separately from Telegram’s regular cache.
- Lets you turn retention off in **Settings → Deleted Messages**.

AfterGram cannot restore messages the device never received, or media that did not finish downloading and is no longer available from Telegram. Secret chats, scheduled messages, and some bulk history-clearing actions are not supported yet. Retained files use storage and are not removed by Telegram’s regular cache cleanup.

## Download and install

1. Download the [latest IPA](https://github.com/pipse363team/AfterGram-iOS/releases/download/latest/TelegramRetention.ipa) or open the [latest release page](https://github.com/pipse363team/AfterGram-iOS/releases/tag/latest). The file is named **TelegramRetention.ipa**.
2. Install the IPA with an iOS sideloading tool that can sign apps. For free Apple ID signing, you can use [Sideloadly](https://sideloadly.io/) on Windows or macOS.
3. Connect your iPhone or iPad and follow the installer’s instructions. If iOS asks, trust the signing certificate in Settings and enable Developer Mode.

The release IPA must be signed with your own certificate before installation. Free Apple ID signing may require reinstalling the app periodically. App extensions and the Apple Watch app are disabled in this build. Native push availability depends on the signing certificate and provisioning profile.

## Notifications with ntfy

The current AfterGram server delivers notifications through the [ntfy iOS app](https://apps.apple.com/app/ntfy/id1625396347). Setup is for the server owner and requires their private API token. Do not publish the token or topic name.

1. Open the [notification setup page](https://pipse363team.github.io/AfterGram-iOS/webpush/) in Safari. Enter the API address `https://144.31.165.8:9443` and the API token provided by the server owner. The page stores them in this browser on this device.
2. Install ntfy. In ntfy, open **Settings → Default server** and enter `https://144.31.165.8:9444`.
3. Return to the AfterGram page and tap **Get ntfy setup**. In ntfy, tap **+**, add a subscription, and paste only the topic name shown on the page.
4. Tap **Send a test notification** on the setup page. Once it arrives, notifications are set up. When you tap a real alert, iOS may show ntfy first; the result depends on the app version and device settings.

The notification bridge checks each chat’s Telegram notification settings and skips chats muted in Telegram. Notification contents and the chat route are handled by the personal server; the ntfy iOS app uses ntfy.sh as its relay. Allow notifications for ntfy in iOS Settings.

## Plugins

Plugins are available in a separate [GitHub Actions build](https://github.com/pipse363team/AfterGram-iOS/actions/workflows/plugin-sdk.yml). Open a successful run and download the **AfterGram-13.0-plugins** artifact.

Import `.plugin`, `.py`, and Elyx source packages in **Settings → Plugins**. Use **Prepare for iOS** for supported Android calls. Compatibility depends on the APIs used by each plugin; Xposed and arbitrary Android screens require porting.

[Supported features](docs/aftergram-plugins.md) · [Example plugin](examples/plugins/aftergram_tools.plugin)

## Build it yourself

You can build through GitHub Actions; a local Mac is not required.

1. Fork this repository.
2. Get an app `api_id` and `api_hash` from [my.telegram.org/apps](https://my.telegram.org/apps).
3. Add them as `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` under **Settings → Secrets and variables → Actions**.
4. In **Actions**, select **Telegram 13.0 with retained messages** and click **Run workflow**. Leave tests enabled.
5. After the workflow succeeds, download the **TelegramRetention-13.0** artifact. It contains the IPA, which must be signed before installation.

Keep API values out of source files and README files.

## Found a problem?

[Open an issue](https://github.com/pipse363team/AfterGram-iOS/issues) with your iOS version, what you did, and what happened. For retention issues, include the message type and whether the media finished downloading. A screenshot or short recording helps too.

[How message retention works](docs/deleted-message-retention.md) · [Original Telegram build guide](docs/upstream-build-guide.md)

This project is based on [Telegram iOS](https://github.com/TelegramMessenger/Telegram-iOS), tag `release-13.0.0`. AfterGram is not affiliated with Telegram.
