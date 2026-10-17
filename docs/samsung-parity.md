# Соответствие Samsung Boosty TV

Эталон — существующие `web/tv/app.js`, `player.js`, `preview.js` и тесты в отдельном `../boosty-tv`. Интерфейс адаптирован к SwiftUI и Siri Remote. Поиск, избранное, офлайн-загрузка и отдельная история отсутствуют в Samsung и не входят в этот перенос.

| Возможности Samsung | Реализация Apple TV | Проверка |
| --- | --- | --- |
| HTTPS/base path, QR на телефоне, SMS/resend, TTL, новый код | `BrokerClient`, `RootView`, общая web-страница телефона | Core wire tests; настоящий SMS требует аккаунта |
| Подтверждение профиля на TV, другой аккаунт, пояснение о Google/телефоне | `RootView`, `AppModel` | AppModel pairing/cancellation tests |
| Восстановление cookie/proof, per-server session, logout с подтверждением | Keychain `SessionStore`, `AppModel`, `LibraryView` | Смена сервера, corrupt/delete-failure и logout tests |
| Session-only вход при ошибке сохранения | `AppModel.sessionNotice` | Consumed-pair persistence-failure test |
| Runtime 401 → новый QR, отмена и фон polling | Model-owned recovery и polling tasks | QR/post/player caller cancellation; server/logout during recovery; scene activation tests |
| EN по умолчанию, RU/EN с сохранением, ошибки и дата/время | `AppLanguage`, `Resources`, root locale | Localization lookup, persistence и no-network/no-reset tests |
| Каталог авторов с аватарами/названием/именем, empty subscriptions | `LibraryView`, subscription pagination | AppModel all-subscription pages; UI acceptance |
| Все авторы/конкретный автор, manual/auto pagination near last 6 | `LibraryView`, `AppModel.loadFeed` | Pagination, author identity и exact-page retry tests |
| Newest-first, dedup `(blog,id)`, повтор cursor | `PostKey`, упорядоченное объединение в `AppModel` | Composite dedup внутри/между страницами, global sort, cursor-loop tests |
| Карточка: preview, summary, дата/время, duration/text-images, locked | `PostCard` | UI acceptance; данные из реального DTO |
| Полный reader, изображения/ошибка, accessibility, empty/locked post | `PostView`, `RemoteImage` | UI acceptance; одинаковый порядок body blocks |
| Ссылки/файлы → QR телефона, отмена stale и auth recovery | `PhoneLinkView`, `AppModel.qrCode` | Core QR validation; current/stale auth and caller-cancellation tests |
| Главы: время/описание, focus frame без запуска, точный video/seconds | `PostView`, общий `FramePreview` | Preview identity/fractional target tests; UI acceptance |
| Back → прежний reader/card/scroll/страницы | `NavigationStack`, explicit focused PostKey, cancellation token | No-feed-reset и pending-open tests; UI acceptance |
| HLS → Full HD → другой MP4, одинаковый UA, resume/start zero | `AppModel`, `PlaybackController`, `BrokerClient` | Source preference, explicit zero, known/unknown duration и UA tests |
| `/api/progress` cached fallback при временном upstream сбое | `AppModel.play`, существующий broker | Transient 503 fallback; malformed/negative/string/403 rejection |
| Качество во время просмотра с прежней позицией/паузой | `PlaybackPanel`, `PlaybackController.changeQuality` | Paused quality, failed-source recovery и stale-operation tests |
| Главы/текущая глава, сегментированная шкала измеренной длительности | `PlaybackTimeline`, `PlaybackPanel` | Sorted unique current-video chapters, duration bounds/segments tests |
| Scrub ±10, выбор без seek, confirm/Back cancel, честное время кадра | `PlaybackController`, `PlaybackPanel`, `FramePreviewCard` | Real controller confirm/cancel and nearest/exact frame tests; UI acceptance |
| Debounce 250ms, idle prefetch 100ms до 4, TTL 5m/LRU32/4MiB | Общий session-scoped `FramePreview` | TTL nonextension, limits, promotion, priorities, stale/access-clear tests |
| Restart после конца, seek ошибки, refresh signed URL/retry | `PlaybackController`, native AVPlayer | Ended replay/chapter seek, seek failure/cancel, current/stale 401 tests |
| Периодический/final progress, pause/background/close, быстрый reopen/backward | `PlaybackProgress`, `PlaybackController`, snapshot в `AppModel` | Ordered shared writes, bounded flush, acknowledged-read race и external progress tests |
| Native transport, hide controls, Play/Pause/Siri Remote | `AVPlayerViewController` и доступные SwiftUI панели | UI remote acceptance; жесты физического Siri Remote требуют приставки |
| Корневой Back и явная смена сервера | Штатный Back tvOS; пункт профиля в `LibraryView` | Back из ленты/setup → Home без сброса входа; отмена/подтверждение отключения в профиле |

## Предел проверки

Unit-тесты проверяют production API, AppModel, очередь и контроллер, подменяя внешние сетевые/медиа границы и системное хранилище. Расширенные UI-тесты используют отдельное приложение `BoostyAppleTVFixture` с теми же production views и AppModel, оперативным хранилищем сессии для неподписанного запуска. Его тестовый URLProtocol доверяет только конкретному CA для localhost с обычной проверкой hostname и цепочки. Этот код отсутствует в основной схеме `BoostyAppleTV`.

UI-данные и подтверждение телефона моделируются локальным HTTPS broker. В режиме fixture host AVPlayer получает публичный тестовый HLS Apple. Это проверка экранов и системного плеера, не реального входа в Boosty или подписанных CDN URL. Настоящий аккаунт, физический пульт и TestFlight требуют отдельной приёмки; установка и запуск подписанной сборки отмечены ниже.

## Результаты 17 октября 2026

- 105 unit-тестов прошли: 26 Core и 79 AppState, включая деление длинного текста и нативные метаданные глав.
- 11 UI-тестов прошли без skips: setup/HTTP, QR ссылок и файлов, автопагинация и Back к последней карточке, chapter preview/качество при паузе/scrub cancel/native player, EN/RU без сброса ленты, reader Back/focus, длинный текст после верхних ссылок, Back → Home и явное отключение через профиль.
- Основная схема `BoostyAppleTV` успешно собрана для tvOS Simulator и Apple TV без подписи, отдельно от fixture host.
- Подписанная версия 0.1.2 (3) установлена и запущена на физической Apple TV 4K третьего поколения. Это подтверждает установку и запуск, не реальный аккаунт/CDN или жесты пульта. Актуальные команды и границы проверки — в [development.md](development.md).

Перед публикацией очищенного кода повторный UI-прогон дал 10/11: ожидание
готовности/воспроизведения внешнего HLS-примера в сценарии плеера завершилось
таймаутом, отдельный повтор также не прошёл. Причина не установлена; исторический
результат 11/11 выше не заменяет эту проверку. Unit-тесты и сборка прошли.
