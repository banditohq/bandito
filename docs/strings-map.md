# Строки интерфейса: макеты → ключи

Таблица для разработчиков экранов. Источник текстов: русские HTML-макеты (`Main`, `Inspector`, `NewAgent`, `Palette`, `Settings`, `AddServer`, `MenuBar`, `Phone`, `Welcome`, `Account`, `FirstServer`, `FirstAgent`, `Tour`). Русский столбец — это `i18n/ru.json`: для строк из макетов тексты совпадают с макетами.

Генерируется из `i18n/*.json` и раскладки экранов. Правьте строки в `i18n/<code>.json` и запускайте `python3 i18n/build.py`.

## Как подключать

- Доступ из Swift: `L10n` + сегменты ключа с заглавной буквы: `sidebar.newAgent` → `L10n.Sidebar.newAgent`, `server.add.thisMac` → `L10n.Server.Add.thisMac`.
- Плейсхолдер `{count}` — `Int`, остальные (`{name}`, `{time}`, `{server}`, `{percent}`, `{path}` и т. д.) — `String`. Плюралы — функция с `count:`.
- Разделители `·`, стрелки `→`, `↵`, `⌘K`, символ `+` и кавычки «…» во многих строках уже внутри текста. Там, где в макете разделитель стоит отдельным элементом, он указан в описании и добавляется во вью.
- Заголовки секций в макетах написаны ВЕРХНИМ регистром (`ЖДУТ ВАС`, `КОМАНДА`, `РАСПИСАНИЕ`). Строки хранят текст как в макете, а в en — тоже в верхнем регистре.
- `effort.label` подставляет уровень в нижнем регистре: передавайте `L10n.Effort.medium.lowercased()`.
- `sidebar.serverSummary`: `transport` — название (SSH, Tailscale…), `agents` — `L10n.Common.agentCount(count:)`, `working` — `L10n.Common.workingCount(count:)`.
- `thread.placeholder` в ru заканчивается на «…», в en — нет: в en так требует тест `L10nTests`.

## Главное окно (Main)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Главное окно (Main) | `sidebar.search` | Поиск (⌘K) |
| Главное окно (Main) | `sidebar.newAgent` | Новый агент (⌘N) |
| Главное окно (Main) | `sidebar.agents` | КОМАНДА |
| Главное окно (Main) | `sidebar.primary` | главный |
| Главное окно (Main) | `sidebar.team` | Команда |
| Главное окно (Main) | `sidebar.sharedChat` | общий чат · {count} |
| Главное окно (Main) | `sidebar.needsYou` | ЖДУТ ВАС |
| Главное окно (Main) | `sidebar.serverSummary` | по {transport} · {agents} · {working} |
| Главное окно (Main) | `sidebar.connectApps` | Приложения |
| Главное окно (Main) | `common.now` | сейчас |
| Главное окно (Main) | `common.agentCount` | one: {count} агент; few: {count} агента; many: {count} агентов; other: {count} агента (plural) |
| Главное окно (Main) | `common.workingCount` | one: {count} работает; few: {count} работают; many: {count} работают; other: {count} работают (plural) |
| Главное окно (Main) | `status.idle` | ждёт задачу |
| Главное окно (Main) | `status.working` | работает |
| Главное окно (Main) | `status.needsYou` | ждёт вас |
| Главное окно (Main) | `effort.label` | усилие: {level} |
| Главное окно (Main) | `thread.placeholder` | Сообщение для {name}… |
| Главное окно (Main) | `thread.send` | Отправить |
| Главное окно (Main) | `thread.attach` | Прикрепить файлы |
| Главное окно (Main) | `thread.dictate` | Диктовка |
| Главное окно (Main) | `thread.today` | Сегодня |
| Главное окно (Main) | `thread.duration` | {runtime} с |
| Главное окно (Main) | `thread.ranCommands` | one: Выполнил {count} команду; few: Выполнил {count} команды; many: Выполнил {count} команд; other: Выполнил {count} команды (plural) |
| Главное окно (Main) | `thread.reviewApproved` | {name} проверил изменения · одобрил |
| Главное окно (Main) | `chapter.resumed` | Глава {count} · {name} перечитал память и продолжает с того же места |
| Главное окно (Main) | `chapter.usageHint` | Сколько занято в текущей главе |
| Главное окно (Main) | `approval.needsYou` | Ждёт вас |
| Главное окно (Main) | `approval.wants` | {name} хочет выполнить |
| Главное окно (Main) | `approval.wantsPush` | {name} хочет запушить ветку |
| Главное окно (Main) | `approval.approve` | Разрешить |
| Главное окно (Main) | `approval.deny` | Отклонить |
| Главное окно (Main) | `approval.always` | Всегда разрешать {command} в {path} |
| Главное окно (Main) | `approval.rule` | правило: {rule} |
| Главное окно (Main) | `approval.approvedByYou` | Разрешено вами · {time} |
| Главное окно (Main) | `approval.deniedByYou` | Запрещено вами · {time} |
| Главное окно (Main) | `usage.title` | Использование |
| Главное окно (Main) | `usage.refresh` | Обновить |
| Главное окно (Main) | `usage.left` | Осталось {percent} |
| Главное окно (Main) | `usage.exhausted` | Исчерпано |
| Главное окно (Main) | `usage.resetTime` | Сброс в {time} |
| Главное окно (Main) | `usage.resetDate` | Сброс {time} |
| Главное окно (Main) | `usage.resetIn` | Сброс через {time} |
| Главное окно (Main) | `usage.footnote` | Лимиты ваших подписок на этом сервере. Обновлено {time}. |
| Главное окно (Main) | `usage.buttonAria` | Использование: осталось {percent} |
| Главное окно (Main) | `usage.hours` | {count} ч |
| Главное окно (Main) | `usage.days` | {count} дн. |
| Главное окно (Main) | `inspector.toggleAria` | Сведения об агенте (⌘I) |
| Главное окно (Main) | `inspector.schedules` | Расписания |

## Сведения агента (Inspector)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Сведения агента (Inspector) | `sidebar.agentRail` | Агенты |
| Сведения агента (Inspector) | `common.close` | Закрыть |
| Сведения агента (Inspector) | `status.idle` | ждёт задачу |
| Сведения агента (Inspector) | `agentSheet.title` | Новый агент |
| Сведения агента (Inspector) | `agentSheet.model` | Модель |
| Сведения агента (Inspector) | `agentSheet.approvals` | Одобрения |
| Сведения агента (Inspector) | `agentSheet.instructions` | Инструкции |
| Сведения агента (Inspector) | `connect.stateLoggedIn` | вход выполнен |
| Сведения агента (Inspector) | `connect.stateLoginNeeded` | нужен вход |
| Сведения агента (Inspector) | `connect.stateLimitToday` | лимит на сегодня |
| Сведения агента (Inspector) | `chapter.title` | Глава {count} |
| Сведения агента (Inspector) | `chapter.resumed` | Глава {count} · {name} перечитал память и продолжает с того же места |
| Сведения агента (Inspector) | `chapter.startedToday` | идёт с сегодняшнего утра |
| Сведения агента (Inspector) | `chapter.tokensUsed` | one: занято {count} токен; few: занято {count} токена; many: занято {count} токенов; other: занято {count} токена (plural) |
| Сведения агента (Inspector) | `chapter.nextAt` | новая глава после {limit} |
| Сведения агента (Inspector) | `chapter.explainer` | Когда глава заполнится, {name} сам запишет важное в память и начнёт с чистого листа. Переписка в окне остаётся целиком, а каждое новое сообщение не дорожает. |
| Сведения агента (Inspector) | `chapter.usageHint` | Сколько занято в текущей главе |
| Сведения агента (Inspector) | `memory.title` | Память |
| Сведения агента (Inspector) | `memory.header` | ПАМЯТЬ |
| Сведения агента (Inspector) | `memory.splitHeader` | КАК ДЕЛИТЬ НА ГЛАВЫ |
| Сведения агента (Inspector) | `memory.modeAria` | Режим памяти |
| Сведения агента (Inspector) | `memory.smartChapters` | Умные главы |
| Сведения агента (Inspector) | `memory.smart` | Умная |
| Сведения агента (Inspector) | `memory.smartDesc` | Новая глава, когда разговор разрастается, и с утра нового дня. Подходит почти всем. |
| Сведения агента (Inspector) | `memory.daily` | Каждый день |
| Сведения агента (Inspector) | `memory.dailyDesc` | Каждое утро — чистый лист. Для ассистентов с ежедневными задачами. |
| Сведения агента (Inspector) | `memory.full` | Одна длинная глава |
| Сведения агента (Inspector) | `memory.fullDesc` | Агент сам сжимает старое. Удобно для одной большой задачи, но дороже. |
| Сведения агента (Inspector) | `memory.searched` | Поискал в переписке |
| Сведения агента (Inspector) | `memory.searchResult` | one: «{query}» · {count} совпадение, {time}; few: «{query}» · {count} совпадения, {time}; many: «{query}» · {count} совпадений, {time}; other: «{query}» · {count} совпадения, {time} (plural) |
| Сведения агента (Inspector) | `memory.memoryFile` | Главное: проекты, решения, открытые задачи · обновлён в {time} |
| Сведения агента (Inspector) | `memory.notes` | Заметки |
| Сведения агента (Inspector) | `memory.notesMeta` | {files} и ещё {count} |
| Сведения агента (Inspector) | `memory.journal` | Журнал |
| Сведения агента (Inspector) | `memory.journalMeta` | one: Сегодня: {count} запись · вчера: {yesterday}; few: Сегодня: {count} записи · вчера: {yesterday}; many: Сегодня: {count} записей · вчера: {yesterday}; other: Сегодня: {count} записи · вчера: {yesterday} (plural) |
| Сведения агента (Inspector) | `memory.files` | Файлы |
| Сведения агента (Inspector) | `memory.filesMeta` | one: {count} файл, который {name} сделал для себя; few: {count} файла, которые {name} сделал для себя; many: {count} файлов, которые {name} сделал для себя; other: {count} файла, которые {name} сделал для себя (plural) |
| Сведения агента (Inspector) | `memory.footer` | Обычные Markdown-файлы на вашем сервере. Их можно открыть, поправить или удалить — агент прочитает новую версию в следующей главе. |
| Сведения агента (Inspector) | `inspector.details` | Сведения |
| Сведения агента (Inspector) | `inspector.aboutAgent` | Об агенте |
| Сведения агента (Inspector) | `inspector.toggleAria` | Сведения об агенте (⌘I) |
| Сведения агента (Inspector) | `inspector.library` | Библиотека |
| Сведения агента (Inspector) | `inspector.server` | Сервер |
| Сведения агента (Inspector) | `inspector.schedules` | Расписания |
| Сведения агента (Inspector) | `inspector.scheduleHeader` | РАСПИСАНИЕ |
| Сведения агента (Inspector) | `inspector.addSchedule` | Добавить |
| Сведения агента (Inspector) | `inspector.scheduleSummary` | По будням в {time} · следующая {when} |
| Сведения агента (Inspector) | `inspector.nextRun` | Следующий запуск: {time} |
| Сведения агента (Inspector) | `inspector.runNow` | Запустить сейчас |
| Сведения агента (Inspector) | `inspector.rules` | Правила |
| Сведения агента (Inspector) | `inspector.usage` | Использование |
| Сведения агента (Inspector) | `inspector.window.fiveHour` | 5 часов |
| Сведения агента (Inspector) | `inspector.window.sevenDay` | Неделя |
| Сведения агента (Inspector) | `inspector.resets` | Сброс {time} |
| Сведения агента (Inspector) | `inspector.runsOn` | Работает на |
| Сведения агента (Inspector) | `inspector.project` | Проект |
| Сведения агента (Inspector) | `inspector.askRisky` | Спрашивать о рискованном |
| Сведения агента (Inspector) | `inspector.uptime` | one: работает {count} день; few: работает {count} дня; many: работает {count} дней; other: работает {count} дня (plural) |
| Сведения агента (Inspector) | `inspector.serverInfo` | {os} · Bandito {version} · {uptime} |
| Сведения агента (Inspector) | `inspector.instructionsHeader` | ИНСТРУКЦИИ |

## Новый агент (NewAgent)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Новый агент (NewAgent) | `common.recommended` | рекомендуем |
| Новый агент (NewAgent) | `agentSheet.title` | Новый агент |
| Новый агент (NewAgent) | `agentSheet.name` | Имя |
| Новый агент (NewAgent) | `agentSheet.role` | Роль |
| Новый агент (NewAgent) | `agentSheet.roleHint` | видна как метка у имени |
| Новый агент (NewAgent) | `agentSheet.rolePlaceholder` | например, сборщик, ревьюер, дежурный |
| Новый агент (NewAgent) | `agentSheet.avatar` | Аватар |
| Новый агент (NewAgent) | `agentSheet.runtime` | Чем думает |
| Новый агент (NewAgent) | `agentSheet.runtimeHint` | подписки на {server} |
| Новый агент (NewAgent) | `agentSheet.model` | Модель |
| Новый агент (NewAgent) | `agentSheet.modelDefault` | По умолчанию |
| Новый агент (NewAgent) | `agentSheet.folder` | Проект на сервере |
| Новый агент (NewAgent) | `agentSheet.folderHint` | Где лежит код, с которым он работает. |
| Новый агент (NewAgent) | `agentSheet.approvals` | Одобрения |
| Новый агент (NewAgent) | `agentSheet.askAbout` | Что спрашивать у вас |
| Новый агент (NewAgent) | `agentSheet.approvalsHint` | Пуш, деплой, удаление и запись вне {path} ждут вашего «да». Остальное он делает сам. |
| Новый агент (NewAgent) | `agentSheet.instructions` | Инструкции |
| Новый агент (NewAgent) | `agentSheet.instructionsHint` | необязательно, как ТЗ для нового сотрудника |
| Новый агент (NewAgent) | `agentSheet.memoryAuto` | создастся сама |
| Новый агент (NewAgent) | `agentSheet.memoryHint` | Ведёт заметки в своей папке, поэтому помнит всё, а сообщения не дорожают. |
| Новый агент (NewAgent) | `agentSheet.changeLater` | Всё это можно поменять потом. |
| Новый агент (NewAgent) | `agentSheet.create` | Создать {name} |
| Новый агент (NewAgent) | `agentSheet.cancel` | Отмена |
| Новый агент (NewAgent) | `agentSheet.runtimeMissing` | {runtime} не установлен на {server} |
| Новый агент (NewAgent) | `agentSheet.runtimeLogin` | {runtime} не выполнил вход на {server}. Выполните там `{command}`. |
| Новый агент (NewAgent) | `avatar.face` | Лицо: |
| Новый агент (NewAgent) | `runtime.claude` | Claude Code |
| Новый агент (NewAgent) | `runtime.codex` | Codex |
| Новый агент (NewAgent) | `runtime.grok` | Grok |
| Новый агент (NewAgent) | `runtime.api` | API-ключ |
| Новый агент (NewAgent) | `connect.loggedInPlan` | Вход выполнен · {plan} |
| Новый агент (NewAgent) | `connect.needsLogin` | Нужно войти |
| Новый агент (NewAgent) | `connect.limitUntil` | Лимит до {time} |
| Новый агент (NewAgent) | `connect.addKey` | Добавить ключ → |
| Новый агент (NewAgent) | `effort.title` | Усилие |
| Новый агент (NewAgent) | `effort.label` | усилие: {level} |
| Новый агент (NewAgent) | `effort.low` | Низкое |
| Новый агент (NewAgent) | `effort.medium` | Среднее |
| Новый агент (NewAgent) | `effort.high` | Высокое |
| Новый агент (NewAgent) | `effort.xhigh` | Очень |
| Новый агент (NewAgent) | `effort.max` | Максимум |
| Новый агент (NewAgent) | `effort.hint` | Чем выше, тем умнее на сложных задачах, но дольше и быстрее тратит лимит. Для обычной работы хватает среднего. |
| Новый агент (NewAgent) | `approvalMode.risky` | Только рискованное |
| Новый агент (NewAgent) | `approvalMode.always` | Всё подряд |
| Новый агент (NewAgent) | `approvalMode.never` | Ничего |
| Новый агент (NewAgent) | `memory.title` | Память |
| Новый агент (NewAgent) | `memory.smartChapters` | Умные главы |

## Быстрый переход (Palette)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Быстрый переход (Palette) | `common.agents` | АГЕНТЫ |
| Быстрый переход (Palette) | `status.needsYou` | ждёт вас |
| Быстрый переход (Palette) | `new.agent` | Новый агент |
| Быстрый переход (Palette) | `palette.title` | Быстрый переход |
| Быстрый переход (Palette) | `palette.search` | Поиск |
| Быстрый переход (Palette) | `palette.newAgentNamed` | Новый агент — с именем «{name}…» |
| Быстрый переход (Palette) | `palette.pauseAgent` | Поставить на паузу {name} |
| Быстрый переход (Palette) | `palette.onServer` | на {server} |
| Быстрый переход (Palette) | `palette.onServerOffline` | на {server} (не в сети) |
| Быстрый переход (Palette) | `palette.sectionActions` | ДЕЙСТВИЯ |
| Быстрый переход (Palette) | `palette.sectionMessages` | СООБЩЕНИЯ |
| Быстрый переход (Palette) | `palette.hintSelect` | ↑↓ выбрать |
| Быстрый переход (Palette) | `palette.hintOpen` | ↵ открыть |
| Быстрый переход (Palette) | `palette.hintMessage` | ⌘↵ написать |
| Быстрый переход (Palette) | `palette.footerCounts` | {servers} · {agents} |

## Настройки (Settings)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Настройки (Settings) | `settings.title` | Настройки |
| Настройки (Settings) | `settings.sectionsAria` | Разделы настроек |
| Настройки (Settings) | `settings.general` | Общие |
| Настройки (Settings) | `settings.servers` | Серверы |
| Настройки (Settings) | `settings.approvals` | Одобрения |
| Настройки (Settings) | `settings.approvalsIntro` | Bandito проверяет каждое действие агента. Обычная работа идёт сама, а всё, что подходит под правило ниже или встроенную проверку, ждёт вашего решения. |
| Настройки (Settings) | `settings.usage` | Использование |
| Настройки (Settings) | `settings.updates` | Обновления |
| Настройки (Settings) | `settings.close` | Закрыть настройки |
| Настройки (Settings) | `settings.theme` | Тема |
| Настройки (Settings) | `settings.theme.system` | Системная |
| Настройки (Settings) | `settings.theme.dark` | Тёмная |
| Настройки (Settings) | `settings.theme.light` | Светлая |
| Настройки (Settings) | `settings.language` | Язык |
| Настройки (Settings) | `settings.language.system` | Системный |
| Настройки (Settings) | `settings.notifications` | Уведомления |
| Настройки (Settings) | `settings.menuBar` | Показывать в строке меню |
| Настройки (Settings) | `settings.launchAtLogin` | Запускать при входе в систему |
| Настройки (Settings) | `settings.updates.channel` | Канал обновлений |
| Настройки (Settings) | `settings.updates.stable` | Стабильный |
| Настройки (Settings) | `settings.updates.beta` | Бета |
| Настройки (Settings) | `settings.updates.auto` | Обновлять автоматически |
| Настройки (Settings) | `settings.updates.check` | Проверить сейчас |
| Настройки (Settings) | `settings.updates.daemon` | Обновить демон |
| Настройки (Settings) | `settings.updates.restartDaemon` | Перезапустить демон |
| Настройки (Settings) | `rules.newRule` | Новое правило |
| Настройки (Settings) | `rules.when` | Когда агент хочет выполнить |
| Настройки (Settings) | `rules.placeholder` | например, wrangler deploy* |
| Настройки (Settings) | `rules.then` | То |
| Настройки (Settings) | `rules.forWhom` | Для кого |
| Настройки (Settings) | `rules.add` | Добавить |
| Настройки (Settings) | `rules.action` | ДЕЙСТВИЕ |
| Настройки (Settings) | `rules.behavior` | ПОВЕДЕНИЕ |
| Настройки (Settings) | `rules.scope` | ДЛЯ КОГО |
| Настройки (Settings) | `rules.allow` | Разрешать |
| Настройки (Settings) | `rules.ask` | Спрашивать |
| Настройки (Settings) | `rules.deny` | Запрещать |
| Настройки (Settings) | `rules.allAgents` | Все агенты |
| Настройки (Settings) | `rules.wildcardNote` | * — что угодно. Если подходят два правила, побеждает правило конкретного агента, затем более новое. |
| Настройки (Settings) | `rules.editAria` | Изменить правило |
| Настройки (Settings) | `rules.deleteAria` | Удалить правило |
| Настройки (Settings) | `rules.builtin` | Встроенные проверки |
| Настройки (Settings) | `rules.builtinHint` | работают всегда, если правило выше не говорит иначе |
| Настройки (Settings) | `rules.builtinOutsideProject` | запись вне папки проекта |

## Подключение сервера (AddServer)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Подключение сервера (AddServer) | `common.back` | Назад |
| Подключение сервера (AddServer) | `server.add.title` | Подключение сервера |
| Подключение сервера (AddServer) | `server.add.heading` | Подключите сервер |
| Подключение сервера (AddServer) | `server.add.intro` | Код остаётся на вашем сервере. Выберите, как этот Mac до него дотянется, — любой способ даёт одно и то же зашифрованное соединение. |
| Подключение сервера (AddServer) | `server.add.methodAria` | Способ подключения |
| Подключение сервера (AddServer) | `server.add.thisMac` | Этот Mac |
| Подключение сервера (AddServer) | `server.add.thisMacDesc` | Команда прямо здесь. Ничего настраивать не нужно. |
| Подключение сервера (AddServer) | `server.add.ssh` | SSH |
| Подключение сервера (AddServer) | `server.add.sshDesc` | Берём ваш ~/.ssh/config. Bandito сам установится и свяжется по тому же соединению. |
| Подключение сервера (AddServer) | `server.add.tailscale` | Tailscale |
| Подключение сервера (AddServer) | `server.add.tailscaleDesc` | Любой компьютер в вашей сети Tailscale. Без SSH и открытых портов. |
| Подключение сервера (AddServer) | `server.add.direct` | Напрямую (TLS) |
| Подключение сервера (AddServer) | `server.add.directDesc` | Адрес:порт, закреплённый сертификат и код из шести слов. |
| Подключение сервера (AddServer) | `server.add.url` | Свой адрес |
| Подключение сервера (AddServer) | `server.add.urlDesc` | Cloudflare Tunnel, WireGuard, обратный прокси — любой URL до демона. |
| Подключение сервера (AddServer) | `server.add.relay` | Bandito Relay |
| Подключение сервера (AddServer) | `server.add.relayDesc` | Только исходящее, сквозное шифрование. Работает за любым NAT. |
| Подключение сервера (AddServer) | `server.add.host` | Адрес |
| Подключение сервера (AddServer) | `server.add.user` | Пользователь |
| Подключение сервера (AddServer) | `server.add.port` | Порт |
| Подключение сервера (AddServer) | `server.add.fromConfig` | Из {path}: |
| Подключение сервера (AddServer) | `server.add.keysHint` | ключи и jump-хосты берём как есть |
| Подключение сервера (AddServer) | `server.add.code` | Код сопряжения |
| Подключение сервера (AddServer) | `server.add.codeHint` | Выполните `bandito pair` на сервере и введите шесть слов. |
| Подключение сервера (AddServer) | `server.add.install` | Bandito там ещё не установлен. Установить сейчас? |
| Подключение сервера (AddServer) | `server.add.connect` | Подключить |
| Подключение сервера (AddServer) | `server.add.connecting` | Подключаю… |
| Подключение сервера (AddServer) | `server.add.done` | Подключено к {server} |
| Подключение сервера (AddServer) | `server.add.stepSsh` | Подключились по SSH |
| Подключение сервера (AddServer) | `server.add.stepDetect` | Нашли {os} |
| Подключение сервера (AddServer) | `server.add.stepInstall` | Устанавливаем Bandito |
| Подключение сервера (AddServer) | `server.add.stepInstallDetail` | версия {version}, служба пользователя |
| Подключение сервера (AddServer) | `server.add.stepPair` | Связываем с этим Mac |
| Подключение сервера (AddServer) | `server.add.stepPairDetail` | одноразовый код, передаётся по SSH |
| Подключение сервера (AddServer) | `server.add.stepCheck` | Проверяем входы |
| Подключение сервера (AddServer) | `server.add.privacy` | Порты не открываем. Демон слушает только сам сервер, приложение ходит через SSH-туннель. |
| Подключение сервера (AddServer) | `server.stepOf` | ШАГ {step} ИЗ {total} |
| Подключение сервера (AddServer) | `server.status.online` | В сети |
| Подключение сервера (AddServer) | `server.status.offline` | Не в сети |

## Строка меню (MenuBar)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Строка меню (MenuBar) | `common.now` | сейчас |
| Строка меню (MenuBar) | `approval.approve` | Разрешить |
| Строка меню (MenuBar) | `approval.deny` | Отклонить |
| Строка меню (MenuBar) | `menubar.needsYou` | one: {count} агент ждёт вас; few: {count} агента ждут вас; many: {count} агентов ждут вас; other: {count} агента ждут вас (plural) |
| Строка меню (MenuBar) | `menubar.open` | Открыть Bandito |
| Строка меню (MenuBar) | `menubar.pauseAll` | Пауза для всех агентов |
| Строка меню (MenuBar) | `menubar.wantsPush` | хочет запушить |
| Строка меню (MenuBar) | `menubar.openChat` | Открыть чат → |
| Строка меню (MenuBar) | `menubar.working` | РАБОТАЮТ |
| Строка меню (MenuBar) | `menubar.upNext` | ДАЛЬШЕ |
| Строка меню (MenuBar) | `notification.approval` | {name} ждёт вас |
| Строка меню (MenuBar) | `notification.finished` | {name} завершил работу |

## iPhone (Phone)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| iPhone (Phone) | `sidebar.team` | Команда |
| iPhone (Phone) | `sidebar.messageTeam` | Написать команде… |
| iPhone (Phone) | `common.minutesAgo` | {count} мин назад |
| iPhone (Phone) | `common.agents` | АГЕНТЫ |
| iPhone (Phone) | `agentSheet.title` | Новый агент |
| iPhone (Phone) | `approval.approve` | Разрешить |
| iPhone (Phone) | `approval.deny` | Отклонить |
| iPhone (Phone) | `notification.approval` | {name} ждёт вас |

## Приветствие (Welcome)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Приветствие (Welcome) | `common.back` | Назад |
| Приветствие (Welcome) | `common.next` | Дальше |
| Приветствие (Welcome) | `onboarding.welcome.headline` | Ваша AI-команда. |
| Приветствие (Welcome) | `onboarding.welcome.headlineAccent` | На вашем сервере. |
| Приветствие (Welcome) | `onboarding.welcome.subtitle` | Агенты на Claude Code, Codex и Grok с ролями и расписанием. Работают, когда вы закрыли ноутбук, и спрашивают перед всем рискованным. |
| Приветствие (Welcome) | `onboarding.welcome.sleepTitle` | Работают, пока вы спите |
| Приветствие (Welcome) | `onboarding.welcome.sleepText` | Агенты живут на вашем сервере. Закройте Mac — они продолжат задачу и пришлют итог утром. |
| Приветствие (Welcome) | `onboarding.welcome.askTitle` | Спрашивают перед рискованным |
| Приветствие (Welcome) | `onboarding.welcome.askText` | Пуш, деплой, удаление — только с вашего «да». Ответить можно с Mac, из уведомления или с iPhone. |
| Приветствие (Welcome) | `onboarding.welcome.subsTitle` | На подписках, которые у вас уже есть |
| Приветствие (Welcome) | `onboarding.welcome.subsText` | Claude, ChatGPT (Codex) или Grok — Bandito запускает их официальные программы. Никаких новых счетов. |
| Приветствие (Welcome) | `onboarding.welcome.start` | Начать — займёт 3 минуты |
| Приветствие (Welcome) | `onboarding.welcome.haveAccount` | Уже есть аккаунт? |
| Приветствие (Welcome) | `onboarding.welcome.signIn` | Войти |
| Приветствие (Welcome) | `onboarding.welcome.footer` | Открытый код · ваш код и ключи не покидают ваши серверы |

## Аккаунт (Account)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Аккаунт (Account) | `onboarding.account.heroTitle` | Одна команда — на Mac и iPhone |
| Аккаунт (Account) | `onboarding.account.heroText` | Войдите один раз, и все ваши серверы и агенты появятся на любом устройстве. Одобряйте задачи с телефона, даже когда Mac закрыт. |
| Аккаунт (Account) | `onboarding.account.title` | Создайте аккаунт Bandito |
| Аккаунт (Account) | `onboarding.account.subtitle` | Он бесплатный и нужен, чтобы устройства узнавали друг друга. Пароль придумывать не придётся. |
| Аккаунт (Account) | `onboarding.account.continueApple` | Продолжить с Apple |
| Аккаунт (Account) | `onboarding.account.continueGithub` | Продолжить с GitHub |
| Аккаунт (Account) | `onboarding.account.orEmail` | или по почте |
| Аккаунт (Account) | `onboarding.account.emailLabel` | Почта |
| Аккаунт (Account) | `onboarding.account.emailPlaceholder` | you@example.com |
| Аккаунт (Account) | `onboarding.account.sendLink` | Прислать ссылку |
| Аккаунт (Account) | `onboarding.account.privacy` | Мы храним только список ваших серверов — зашифрованным, ключ есть лишь у ваших устройств. Код, ключи API и переписка остаются на ваших серверах. |
| Аккаунт (Account) | `onboarding.account.skip` | Продолжить без аккаунта |
| Аккаунт (Account) | `onboarding.account.skipHint` | всё будет только на этом Mac |

## Первый сервер (FirstServer)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Первый сервер (FirstServer) | `server.add.connect` | Подключить |
| Первый сервер (FirstServer) | `onboarding.server.title` | Где будет жить ваша команда? |
| Первый сервер (FirstServer) | `onboarding.server.subtitle` | Агенты работают на компьютере, который не выключается. Подойдёт свой сервер, домашний ПК или — чтобы просто попробовать — этот Mac. |
| Первый сервер (FirstServer) | `onboarding.server.whereAria` | Где запустить |
| Первый сервер (FirstServer) | `onboarding.server.onThisMac` | На этом Mac |
| Первый сервер (FirstServer) | `onboarding.server.thisMacDesc` | Быстро попробовать. Агенты работают, пока Mac не спит и не закрыт. |
| Первый сервер (FirstServer) | `onboarding.server.minutes` | one: {count} минута; few: {count} минуты; many: {count} минут; other: {count} минуты (plural) |
| Первый сервер (FirstServer) | `onboarding.server.ownServer` | На своём сервере |
| Первый сервер (FirstServer) | `onboarding.server.ownServerDesc` | Работает круглосуточно. VPS, домашний ПК или рабочий сервер — подключимся по SSH и всё установим сами. |
| Первый сервер (FirstServer) | `onboarding.server.noServer` | Сервера нет |
| Первый сервер (FirstServer) | `onboarding.server.noServerDesc` | Подойдёт любой VPS от $5 в месяц. Покажем по шагам, где взять и что нажать. |
| Первый сервер (FirstServer) | `onboarding.server.getServer` | Как получить сервер → |
| Первый сервер (FirstServer) | `onboarding.server.addressTitle` | Адрес сервера |
| Первый сервер (FirstServer) | `onboarding.server.addressHint` | Как вы обычно заходите по SSH: пользователь@адрес. Мы используем ваши ключи из {path} — пароль не спросим. |
| Первый сервер (FirstServer) | `onboarding.server.foundInConfig` | Нашли в ваших настройках: |
| Первый сервер (FirstServer) | `onboarding.server.whatHappens` | Что произойдёт |
| Первый сервер (FirstServer) | `onboarding.server.stepConnect` | Подключимся по SSH |
| Первый сервер (FirstServer) | `onboarding.server.stepInstall` | Установим Bandito (≈ 20 МБ) как службу |
| Первый сервер (FirstServer) | `onboarding.server.stepLink` | Свяжем сервер с этим Mac |
| Первый сервер (FirstServer) | `onboarding.server.stepCheck` | Проверим Claude Code, Codex и Grok и подскажем, где войти |
| Первый сервер (FirstServer) | `onboarding.server.noPorts` | Наружу ничего не открываем: сервер слушает только сам себя. |
| Первый сервер (FirstServer) | `onboarding.server.otherWays` | Другие способы: Tailscale, прямое подключение, свой адрес — {link} |
| Первый сервер (FirstServer) | `onboarding.server.allOptions` | все варианты |

## Первый агент (FirstAgent)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Первый агент (FirstAgent) | `agentSheet.runtime` | Чем думает |
| Первый агент (FirstAgent) | `effort.title` | Усилие |
| Первый агент (FirstAgent) | `effort.medium` | Среднее |
| Первый агент (FirstAgent) | `approvalMode.risky` | Только рискованное |
| Первый агент (FirstAgent) | `inspector.project` | Проект |
| Первый агент (FirstAgent) | `onboarding.agent.title` | Кого нанять первым? |
| Первый агент (FirstAgent) | `onboarding.agent.subtitle` | Выберите готовую роль — мы подставим модель, инструкции и расписание. Всё можно поменять потом, а новых агентов добавить в любой момент. |
| Первый агент (FirstAgent) | `onboarding.agent.yourFirst` | ВАШ ПЕРВЫЙ АГЕНТ |
| Первый агент (FirstAgent) | `onboarding.agent.asks` | Спрашивает |
| Первый агент (FirstAgent) | `onboarding.agent.hire` | Нанять {name} и поздороваться |
| Первый агент (FirstAgent) | `onboarding.agent.firstMessage` | Первое сообщение займёт пару секунд — {name} представится и спросит, с чего начать. |
| Первый агент (FirstAgent) | `template.groupAria` | Шаблон агента |
| Первый агент (FirstAgent) | `template.instructionsHeader` | ИНСТРУКЦИИ ИЗ ШАБЛОНА |
| Первый агент (FirstAgent) | `template.builder.title` | Сборщик |
| Первый агент (FirstAgent) | `template.builder.desc` | Пишет и чинит код, гоняет тесты, открывает PR. |
| Первый агент (FirstAgent) | `template.builder.meta` | Claude Code · среднее усилие |
| Первый агент (FirstAgent) | `template.builder.instructions` | Пишешь и чинишь код в проекте. Делаешь маленькие изменения, гоняешь тесты перед каждым коммитом, открываешь PR и кратко пишешь, что сделал. |
| Первый агент (FirstAgent) | `template.reviewer.title` | Ревьюер |
| Первый агент (FirstAgent) | `template.reviewer.desc` | Смотрит изменения других агентов и ваши PR, ищет ошибки. |
| Первый агент (FirstAgent) | `template.reviewer.meta` | Codex · высокое усилие |
| Первый агент (FirstAgent) | `template.oncall.title` | Дежурный |
| Первый агент (FirstAgent) | `template.oncall.desc` | Следит за продом и логами, будит только по делу. |
| Первый агент (FirstAgent) | `template.oncall.meta` | Claude Code · низкое · проверка каждые 15 мин |
| Первый агент (FirstAgent) | `template.assistant.title` | Ассистент |
| Первый агент (FirstAgent) | `template.assistant.desc` | Почта, календарь, заметки, напоминания — на обычном языке. |
| Первый агент (FirstAgent) | `template.assistant.meta` | Claude Code · среднее · сводка в 09:00 |
| Первый агент (FirstAgent) | `template.researcher.title` | Исследователь |
| Первый агент (FirstAgent) | `template.researcher.desc` | Ищет, читает и сравнивает, приносит выжимку со ссылками. |
| Первый агент (FirstAgent) | `template.researcher.meta` | Grok · высокое усилие |
| Первый агент (FirstAgent) | `template.scratch.title` | С нуля |
| Первый агент (FirstAgent) | `template.scratch.desc` | Пустой агент: сами дадите имя, роль и инструкции. |
| Первый агент (FirstAgent) | `template.scratch.meta` | Любая модель |

## Обучение (Tour)

| Экран (макет) | Ключ | Русский текст |
|---|---|---|
| Обучение (Tour) | `common.next` | Дальше |
| Обучение (Tour) | `tour.hintAria` | Подсказка |
| Обучение (Tour) | `tour.counter` | {step} из {total} |
| Обучение (Tour) | `tour.skip` | Пропустить |
| Обучение (Tour) | `tour.finish` | Начать работу |
| Обучение (Tour) | `tour.team.title` | Это ваша команда |
| Обучение (Tour) | `tour.team.text` | Каждый агент — отдельный чат. Оранжевая точка значит, что кто-то ждёт вашего решения. |
| Обучение (Tour) | `tour.write.title` | Пишите как коллеге |
| Обучение (Tour) | `tour.write.text` | Обычными словами: «добавь тесты для оплаты и открой PR». Агент сам разберётся, что запустить. |
| Обучение (Tour) | `tour.approve.title` | Рискованное — только с вашего «да» |
| Обучение (Tour) | `tour.approve.text` | Пуш, деплой, удаление агент принесёт сюда. Разрешить — кнопкой, отклонить — тоже. Ответить можно и с телефона. |
| Обучение (Tour) | `tour.limits.title` | Сколько осталось |
| Обучение (Tour) | `tour.limits.text` | Здесь видно, сколько лимита осталось у ваших подписок Claude, ChatGPT и Grok — и когда он сбросится. |

## Без макета (уже были или служебные)

Строки, которых нет в макетах: ошибки, баннеры, общие пункты меню профиля, поиск, создание из шапки, контекстное меню агента. Переводы сохранены из прежней версии.

| Раздел | Ключ | Русский текст |
|---|---|---|
| прочее | `app.name` | Bandito |
| прочее | `sidebar.new` | Создать |
| прочее | `sidebar.pinned` | Закреплённые |
| прочее | `sidebar.servers` | Серверы |
| прочее | `common.serverCount` | one: {count} сервер; few: {count} сервера; many: {count} серверов; other: {count} сервера (plural) |
| прочее | `common.comingSoon` | скоро |
| прочее | `agent.menu.pin` | Закрепить |
| прочее | `agent.menu.unpin` | Открепить |
| прочее | `agent.menu.markUnread` | Отметить как непрочитанное |
| прочее | `agent.menu.copyId` | Скопировать ID агента |
| прочее | `agent.menu.pause` | Приостановить |
| прочее | `agent.menu.resume` | Продолжить |
| прочее | `agent.menu.hide` | Скрыть из боковой панели |
| прочее | `agent.menu.delete` | Удалить… |
| прочее | `agent.delete.confirm` | Удалить {name}? Его история останется на сервере. |
| прочее | `status.error` | Ошибка |
| прочее | `status.offline` | Не в сети |
| прочее | `profile.getIphone` | Получить приложение для iPhone |
| прочее | `profile.help` | Справка |
| прочее | `profile.settings` | Настройки… |
| прочее | `profile.addServer` | Добавить сервер |
| прочее | `profile.signOut` | Выйти с этого сервера |
| прочее | `search.placeholder` | Поиск агентов и сообщений |
| прочее | `search.noResults` | Ничего не найдено |
| прочее | `new.to` | Кому: |
| прочее | `new.placeholder` | Начать чат с… |
| прочее | `new.channel` | Новый канал экипажа |
| прочее | `avatar.presets` | Шаблоны |
| прочее | `avatar.generate` | Сгенерировать |
| прочее | `avatar.upload` | Загрузить |
| прочее | `avatar.reset` | Сбросить |
| прочее | `avatar.set` | Установить аватар |
| прочее | `avatar.colorAria` | Цвет аватара |
| прочее | `avatar.colorPeach` | Персиковый |
| прочее | `avatar.colorBlue` | Голубой |
| прочее | `avatar.colorSage` | Шалфей |
| прочее | `avatar.colorPink` | Розовый |
| прочее | `avatar.colorLilac` | Сиреневый |
| прочее | `avatar.colorCream` | Кремовый |
| прочее | `thread.stop` | Остановить |
| прочее | `thread.yesterday` | Вчера |
| прочее | `thread.messageFrom` | Сообщение от {name} |
| прочее | `thread.messageFor` | Сообщение для {name} |
| прочее | `thread.scheduledRun` | Запуск по расписанию |
| прочее | `thread.stopped` | Остановлено |
| прочее | `thread.react` | Реакция |
| прочее | `thread.reply` | Ответить |
| прочее | `thread.more` | Ещё |
| прочее | `thread.copy` | Копировать |
| прочее | `thread.copyMarkdown` | Копировать как Markdown |
| прочее | `thread.hintSend` | ↵ отправить |
| прочее | `thread.hintNewLine` | ⇧↵ новая строка |
| прочее | `thread.hintStop` | ⌘. стоп |
| прочее | `thread.hintSearch` | ⌘K поиск |
| прочее | `approval.deniedByPolicy` | Запрещено правилом |
| прочее | `approval.expired` | Истекло |
| прочее | `banner.notLoggedIn` | {runtime} не выполнил вход на {server}. Выполните там `{command}`. |
| прочее | `banner.offline` | {server} не в сети. Переподключение… |
| прочее | `banner.limit` | Лимит исчерпан. Сброс в {time}. |
| прочее | `banner.retry` | Повторить |
| прочее | `error.generic` | Что-то пошло не так: {message} |
| прочее | `error.disconnected` | Соединение с {server} разорвано |
