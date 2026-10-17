# Roblox systems showcase (Luau)

Серверные модули из моей игры Factory Tycoon (Rojo, около 25 сервисов, 44 коммита). Здесь только те части, которые чаще всего заказывают отдельно:

| Модуль | Что показывает |
|---|---|
| `DataService.luau` | Сохранения DataStore: `pcall` на всех вызовах, автосейв, `BindToClose`, отдельное хранилище для Studio, чтобы тесты не затирали боевой прогресс |
| `MonetizationService.luau` | Developer Products и пропуски: `ProcessReceipt` с защитой от повторных чеков, владение пропусками через MarketplaceService |
| `LeaderboardService.luau` | Глобальный лидерборд на OrderedDataStore |
| `QuestService.luau` | Ежедневные задания с привязкой к суткам UTC |
| `FactoryOrderService.luau` + `tests/` | Игровая логика заказов и spec-тест к ней |

Код написан с помощью ИИ-агентов (Claude Code, Codex). Задачи ставил я, проверял плейтестом и тестами.

**Беру заказы:** одна механика в вашем плейсе (сохранения, магазин с проверкой на сервере, лидерборд, ежедневки). Принимается тестом на двух игроках в Studio. Связь: Telegram @twaise12.
