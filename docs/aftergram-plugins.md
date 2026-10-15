# Плагины AfterGram

Встроенный Python 3.11 и библиотека совместимости с API exteraGram. Плагины работают в iOS-клиенте через нативные адаптеры. JVM, Xposed и Android SDK в приложение не встроены.

## Установка

1. Открыть **Настройки → Плагины → Импортировать плагин**.
2. Выбрать `.plugin`, `.py` либо исходный пакет `.elyx`/`.eaf`/`.zip`.
3. Проверить результат анализа. Если нужны поддерживаемые замены, нажать **Подготовить для iOS**. Оригинал сохраняется отдельно; до включения код плагина не выполняется.
4. Включить установленный плагин и открыть его настройки.

Для проверки есть **Добавить пример Hello** и команда `.hello Alice`. [AfterGram Tools](../examples/plugins/aftergram_tools.plugin) показывает нативную форму, отправку текста и запрос `help.getNearestDc`: после импорта и включения отправить `.agdemo`.

## Поддержка API

| Возможность | Реализация |
| --- | --- |
| BasePlugin | Загрузка/выгрузка, START/STOP/PAUSE/RESUME, настройки, журнал ошибок |
| Исходящие сообщения | Приоритеты, DEFAULT/CANCEL/MODIFY/MODIFY_FINAL, текст и подписи облачных сообщений, entities |
| Запросы Telegram | 840 методов и 1700 конструкторов, сгенерированных из API этой сборки; `send_request`, callback с response/error, отмена запросов |
| Перехват запросов | `pre_request_hook` и `post_request_hook` для обычного `Network.request`, приоритеты, подстроки, отмена и замена данных; ошибки плагина возвращают исходный пакет |
| Входящие сообщения | `TL_updateNewMessage` и `TL_updateNewChannelMessage` после применения состояния; события доступны для чтения |
| TLRPC | Старый `TLRPC.TL_account_updateProfile` и новый `TL_account.updateProfile`, JavaList, snake_case/camelCase полей, flags/flags2, vectors, bytes |
| Текст | Отправка и редактирование, ответы, отложенная отправка, notify, HTML/Markdown, UTF-16 entities и custom emoji |
| Медиа | `send_photo`, `send_video`, `send_audio`, `send_document`: локальные файлы до 512 MB, подписи с форматированием, спойлеры; копирование в mediaBox перед загрузкой |
| Настройки | Header/Divider/Switch/Input/EditText/Selector/Text, вложенные страницы, длинное нажатие, multiline, max_length, mask, accent/red |
| Диалоги | AlertDialogBuilder: кнопки, списки, простые формы, cancel/dismiss callbacks, текстовый прогресс и загрузка |
| Portable UI | TextView/EditText/Button/LinearLayout/FrameLayout превращаются в содержимое нативной формы; произвольная Android-вёрстка не воспроизводится |
| Меню | Меню сообщений и основное меню внутри экрана плагина |
| Аккаунт | `self.client(account)`, get_user_config, ограниченный get_messages_controller/get_account_instance/get_connections_manager; данные своего пользователя и известные peers |
| Фон | `run_on_queue` использует пул до четырёх Python workers на аккаунт; результаты доставляются через очередь движка. UI callbacks выполняются на очереди движка, действия с UIKit — на main thread |
| Утилиты | Clipboard, Runnable R, отмена запланированных callbacks, Java wrappers для чисел/строк, стандартные каталоги и операции с файлами |
| Ссылки | ACTION_VIEW для http/https/tg/mailto, ACTION_SEND текста через системное меню Share |
| Elyx | JSON/YAML refmap и metadata, исходные модули, assets/strings/settings, относительные импорты |

`UserConfig.selectedAccount` и account helpers используют аккаунт callback. Его ID отличается от Android-индекса. Обращение к другому аккаунту отклоняется. `getInputPeer` использует данные текущего чата либо peers из полученных API-ответов; он не придумывает access hash.

## Автоматическая адаптация

Замены выполняются через AST и сохраняют aliases. Поддержаны группы `org.telegram.messenger`, `java.lang`, переносимые элементы `android.widget`/`android.view`, `android.text.InputType`, `android.content.Intent`/Context, `android.net.Uri` и `LayoutHelper`. Символы без реализации перечисляются в отчёте импорта.

Wire-схема берётся из Swift-сериализаторов этого checkout. Имена 1197 Boolean-флагов сопоставлены по точному constructor ID и имени с [закреплённой официальной TL-схемой](https://github.com/telegramdesktop/tdesktop/blob/d36272b193057a114ef3a9fe7f15a8f8b587c489/Telegram/SourceFiles/mtproto/scheme/api.tl); несовпавшие версии не подмешиваются. Метаданные и SHA-256 источника сохранены в `scripts/plugin-tl-flags.json`. Неизвестное поле даёт ошибку вместо молчаливого игнорирования.

Импорт предварительно проверяет зависимости и доступные SDK-символы. Динамические импорты и все ветки выполнения нельзя проверить статически, поэтому успешно установленный плагин всё равно может потребовать доработки.

## Библиотеки

В IPA входят закреплённые версии requests, urllib3, idna, certifi, charset-normalizer, packaging, чистая Python-часть PyYAML, mpmath, tinydb, beautifulsoup4, soupsieve, typing_extensions, Markdown, python-dateutil, six и pytz. Версии и SHA-256 перечислены в `scripts/prepare-plugin-python.py`; `__requirements__` проверяются с учётом markers для Python 3.11/iOS.

## Выполнение и ошибки

Обычная ошибка показывается коротко, полный traceback доступен в прокручиваемом журнале. Ошибка hook отключает плагин и сохраняет исходный текст/пакет. Неудавшийся callback не отправляет накопленные им действия.

Для загрузки модуля и инициализации плагина действует Python-бюджет в 10 секунд, для остальных foreground callbacks — одна секунда, для worker callbacks — 30 секунд. Opcode tracing покрывает оптимизированные однострочные циклы Python 3.11. Он не может принудительно прервать блокирующую C-функцию: для сети следует задавать timeout. Workers разгружают очередь движка при I/O, но Python GIL сохраняется.

При отключении плагина отменяются его ожидающие запросы, callbacks, меню и диалоги, поздние worker-результаты отбрасываются. Начатую C-функцию остановить принудительно нельзя. iOS может приостановить приложение в фоне, поэтому таймеры не гарантируют непрерывную работу при закрытом приложении.

Код и настройки находятся в `Account.basePath/aftergram-plugins`, отдельно по аккаунтам. Обновление сохраняет настройки и устанавливает плагин выключенным. Python работает в процессе клиента; это не отдельная защитная песочница.

## Границы совместимости

Требуют отдельного переноса: Xposed/DexMaker и произвольный перехват Java-методов, Java reflection, Custom/native Android Views, экраны Android, MVEL-условия меню, меню чата/профиля, изменение входящего состояния до применения к базе, замена медиа при редактировании, compiled Elyx/pyc, Java assets/proxy, межплагинные зависимости, произвольные PyPI wheels и DevServer через ADB. MTProto-методы вне обычного `Network.request` не проходят через request hooks.

Наличие класса TLRPC не означает, что все Android-классы плагина перенесены. Старые имена конструкторов, отсутствующие в текущем API, требуют обновления. Успешный запрос зависит также от серверных прав, состояния аккаунта и доступности peer.

## Проверка и сборка

Локально проходят 38 Python-тестов на Python 3.11. Отдельный iOS XCTest сравнивает Python-пакеты с нативными сериализаторами запросов и проверяет 1700 конструкторов через Swift parse/serialize, встроенные workers, `.plugin`, форматирование и остановку зацикленного callback. Результат новой macOS-сборки и проверка на устройстве фиксируются после их завершения.

Локальная проверка опубликованных исходников: Pangu импортируется с адаптацией Intent/Uri, строит настройки и меняет исходящий текст; Clock Nickname загружается и формирует запрос обновления профиля. Эти проверки не меняли профиль через реальную сеть и не заменяют тестирование на iPhone.

Подготовка runtime, iOS-тесты и сборка IPA — отдельные шаги Actions. Для изменений только собственного Python SDK есть workflow **AfterGram Python SDK update**: он берёт успешную нативную сборку, проверяет отсутствие нативных изменений и равенство wire-схемы, обновляет SDK, заново подписывает затронутые bundles ad hoc и проверяет подписи. Изменения нативного кода, API-схемы или поставляемых библиотек требуют полной сборки. Проверка IPA подтверждает наличие Python.framework, 58 нативных расширений, SDK, TL-схемы и stdlib. Новые совместимые плагины не требуют пересборки приложения; новые нативные API требуют обновления IPA.

Документация SDK: [exteraGram Plugins](https://plugins.exteragram.app/docs). Runtime: [Python Apple Support](https://github.com/beeware/Python-Apple-support).
