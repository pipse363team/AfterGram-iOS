<div align="center">

# AfterGram · iOS

**Local retention of deleted Telegram messages and media on iPhone and iPad.**

![Platform](https://img.shields.io/badge/platform-iOS%20%2F%20iPadOS-black)
![Base](https://img.shields.io/badge/Telegram-13.0-26A5E4)
![Status](https://img.shields.io/badge/status-experimental-orange)

[Русский](README.md) · **English**

</div>

---

AfterGram is an experimental modification of the official Telegram iOS 13.0 source. Messages deleted by another participant remain in the local chat history, become translucent, and receive a deletion indicator.

**iOS/iPadOS only.** There are no Android, Windows, or macOS client builds. Windows can be used to prepare the repository and start a remote build; compilation runs on macOS.

> **Status:** the implementation is prepared in source form. iOS compilation, XCTest execution, and device testing have not yet been confirmed. No verified IPA is available. This is an unofficial client, unaffiliated with Telegram.

## Features

| Feature | Implementation |
| --- | --- |
| Retention in the chat | Loaded messages remain in history after a remote deletion event |
| Deletion indicator | 50% opacity, a trash icon, and a “Deleted” label underneath |
| Media | Retention is implemented for text, photos, GIFs, videos, and round video messages |
| File copies | Complete media files are stored outside Telegram’s normal cache |
| Downloads ahead of deletion | Media in displayed messages are downloaded in advance, two resources at a time |
| Albums | Deleted members are separated so other members keep their original opacity |
| Settings | “Deleted Messages” in account settings lets you disable the feature |
| Builds | GitHub Actions: macOS, tests, and an IPA for subsequent re-signing |

## Limitations

Retention works with messages the client has already loaded. Playback after deletion requires a complete download or a file that is still available from the server. Messages never loaded by the client and unavailable files cannot be recovered.

Downloads start for messages displayed in the chat. The complete history of every chat is not downloaded automatically. Downloads consume network data and device storage.

Separate file copies survive normal Telegram cache clearing. Manually deleting a message removes its chat record but does not guarantee removal of every backup file. These files are removed with the account/app data.

Secret chats, scheduled messages, and bulk history clearing through `min_available_id` are not covered yet. Server operations on an already deleted message may be unavailable.

## Build an IPA without owning a Mac

The source and workflow must be present on your GitHub repository’s default branch.

### 1. Obtain a Telegram API ID and API hash

1. Open [my.telegram.org](https://my.telegram.org/auth?to=apps).
2. Enter your Telegram phone number in international format.
3. Sign in using the code sent through Telegram.
4. Open **API development tools** and complete the application form. Example values: title `AfterGram iOS`, short name `aftergramios`, platform **iOS**, description `Personal iOS Telegram client build`.
5. Save **App api_id** and **App api_hash**. If an application already exists, use its displayed credentials.

The API ID identifies your application; the API hash is a 32-character string. These are not a bot token or a Telegram login code.

### 2. Configure GitHub Actions secrets

Open **Settings → Secrets and variables → Actions → Secrets → New repository secret** and add:

| Name | Secret |
| --- | --- |
| `TELEGRAM_API_ID` | Your **App api_id** |
| `TELEGRAM_API_HASH` | Your **App api_hash** |

Do not put actual values in README files, commits, or public messages.

### 3. Run the build

1. Open **Actions**.
2. Select **Telegram 13.0 with retained messages**.
3. Click **Run workflow**, choose **main**, and leave tests enabled.
4. Click the green **Run workflow** button.
5. After a successful run, download the **TelegramRetention-13.0** artifact from the run page.

The artifact contains `TelegramRetention.ipa`, signed ad hoc for subsequent re-signing. It is not an App Store installation package. Signing for installation on your iPhone is a separate step. Extensions and the Watch app are disabled in this build; push notifications depend on the re-signing provisioning profile.

If the workflow is missing, make sure `.github/workflows/retention-build.yml` is present on the default branch and enable Actions if GitHub prompts you.

## Validation and development

Upstream: [TelegramMessenger/Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS), tag `release-13.0.0`, commit `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838`.

Patch application against this baseline, changed Swift syntax relative to upstream, YAML, and build preparation scripts have been checked. Five tests cover the deletion marker, retained bytes, GIF/video/round-video metadata, and deletion behavior. Running them requires macOS.

[Implementation and device test scenarios](docs/deleted-message-retention.md) · [Original Telegram build guide](docs/upstream-build-guide.md) · [Workflow](.github/workflows/retention-build.yml)

When reporting a bug, include your iOS version, message type, reproduction steps, and the failed Actions step log for build failures.

## Credits

Based on the official [Telegram iOS source](https://github.com/TelegramMessenger/Telegram-iOS). [WhiteGram](https://github.com/WhiteGram/WhiteGram-iOS) was inspected as a possible feature source; no anti-delete mechanism was found in the published branch that was examined. Other WhiteGram features are not included in this implementation.

Telegram is a trademark of its respective owner. AfterGram identifies an unofficial modification, not a product of the Telegram team.
