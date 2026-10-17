--!strict
-- Загрузка/сохранение прогресса игрока. pcall-guarded, автосейв, BindToClose —
-- тот же паттерн надёжности, что и в прошлом проекте.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

-- РАЗНЫЕ хранилища для Studio и живой игры. Как только у плейса появился
-- настоящий PlaceId и включён доступ к API, Play в Studio начинает читать и
-- писать НАСТОЯЩИЙ прогресс игроков — отладочный запуск затирал бы им сохранения.
-- Суффикс разводит эти два мира: в Studio своё хранилище, которое не жалко.
--
-- Побочный плюс: студийное хранилище пустое, поэтому Config.Economy.StartCoins
-- снова выдаёт отладочную гору монет, а не подтягивает боевой баланс.
local STORE_NAME = if RunService:IsStudio() then "FactoryTycoon_v1_studio" else "FactoryTycoon_v1"

-- В неопубликованном плейсе GetDataStore сам кидает ошибку ("must publish to access
-- DataStore"), а не только GetAsync/SetAsync — без pcall это валит весь require()
-- модуля и обрушивает бутстрап сервера целиком. Фолбэк: работаем без сохранения.
local store: DataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[DataService] DataStore недоступен (плейс не опубликован?) — прогресс не сохраняется: " .. tostring(result))
	end
end

export type PlayerData = {
	Coins: number,
	-- Каждая линия хранит своё состояние: открыта ли она и до какой стадии куплены
	-- её ворота. Линии работают одновременно, поэтому одного общего тира мало.
	LineUnlocked: { [string]: boolean },
	LineStage: { [string]: number },
	LineHammers: { [string]: number }, -- сколько станков работает на линии (1..3)
	Rebirths: number,
	Hammer: string, -- Id экипированного молота-скина станка
	OwnedHammers: { [string]: boolean },
	OwnedPets: { [string]: number }, -- Id питомца -> сколько штук выбито
	EquippedPets: { string }, -- до PetData.MaxEquipped надетых, бонусы складываются
	-- Куплено за робуксы. Владение ПРОПУСКАМИ здесь не хранится: источник правды —
	-- MarketplaceService, иначе пропуск, купленный на другом сервере, не увидится.
	-- Купленное благоустройство. Ребёрт его НЕ сбрасывает: это престиж за всю
	-- историю аккаунта, а не часть цикла, который обнуляется.
	Facilities: { [string]: boolean },
	-- Купленное оружие. Ребёрт тоже не трогает: это вещи в рюкзаке, а не прогресс
	-- цеха, и отбирать их за ребёрт значило бы наказывать за него.
	Weapons: { [string]: boolean },
	BoostUntil: number, -- os.time, до которого действует ускорение ×2
	FreePetRolls: number, -- бесплатные крутки питомцев из бандла
	-- Id обработанных чеков. Roblox может прислать один и тот же чек повторно, пока
	-- сервер не вернул PurchaseGranted, — без этого списка бандл выдался бы дважды.
	HandledReceipts: { string },
	-- ── Возвращаемость ───────────────────────────────────────────────────────
	-- os.time последнего сохранения. От него считается офлайн-доход.
	LastSeen: number,
	-- Снимок дохода в монетах за секунду на момент последнего сохранения. Хранится
	-- ИМЕННО снимком, а не пересчитывается из линий при входе: формула цены живёт
	-- в ProductionLineService и завязана на множители питомцев, ребёрта и завода,
	-- а её копия здесь разъехалась бы с оригиналом при первой правке баланса.
	IncomePerSec: number,
	-- Номер СУТОК по UTC (os.time // 86400) последнего забора ежедневки. Именно
	-- сутки, а не «24 часа с прошлого раза»: скользящее окно наказывает того, кто
	-- заходит чуть раньше вчерашнего, и серия рвётся без вины игрока.
	LastDailyDay: number,
	DailyStreak: number,
	-- os.time, раньше которого бесплатная крутка недоступна.
	NextFreeRoll: number,
	-- Уже введённые коды: повторный ввод не должен выдавать награду снова.
	RedeemedCodes: { string },
	-- ── Ежедневные задания ───────────────────────────────────────────────────
	-- Номер суток по UTC, на которые выданы задания. Отличается от сегодняшнего —
	-- значит пора раздать новые и обнулить прогресс.
	QuestDay: number,
	QuestIds: { string },
	QuestProgress: { [string]: number },
	QuestDone: { [string]: boolean },
	-- Выключил ли игрок фоновую музыку. Хранится ИМЕННО как "выключено", а не
	-- "включено": у всех старых сохранений поля нет, nil читается как false, и
	-- музыка по умолчанию играет — то же самое, что у новичка.
	MusicOff: boolean,
	PointerOff: boolean,
	DoorBought: boolean,
	TutorialCompleted: boolean,
	TutorialEarned: boolean,
	OrdersCompleted: number,
	VehicleSmashes: number,
	-- Транспорт покупается навсегда и не сбрасывается ребёртом. Мотоцикл стартовый,
	-- остальные машины становятся отдельной веткой прогрессии гаража.
	OwnedVehicles: { [string]: boolean },
	GoldenProductsClaimed: number,
}

local function defaultData(): PlayerData
	return {
		-- Config.Economy.StartCoins сам разбирается, где он выполняется: в Studio это
		-- отладочная гора монет, в опубликованной игре ноль. Здесь ничего менять
		-- перед релизом не нужно.
		Coins = Config.Economy.StartCoins,
		-- Дефолт строится из Config.Lines, а не списком: добавил линию в конфиг —
		-- она сама появилась в сохранении, без правки этого файла.
		LineUnlocked = (function()
			local t: { [string]: boolean } = {}
			for _, line in Config.Lines do
				t[line.Id] = false
			end
			return t
		end)(),
		LineStage = (function()
			local t: { [string]: number } = {}
			for _, line in Config.Lines do
				t[line.Id] = 1
			end
			return t
		end)(),
		LineHammers = (function()
			local t: { [string]: number } = {}
			for _, line in Config.Lines do
				t[line.Id] = 1
			end
			return t
		end)(),
		Rebirths = 0,
		Hammer = "Hammer",
		OwnedHammers = { Hammer = true },
		OwnedPets = {},
		EquippedPets = {},
		Facilities = {},
		Weapons = {},
		BoostUntil = 0,
		FreePetRolls = 0,
		HandledReceipts = {},
		-- LastSeen = 0 у новичка: офлайн-доход не начислится, потому что снимок
		-- дохода тоже ноль. Специальной ветки «первый вход» не нужно.
		LastSeen = 0,
		IncomePerSec = 0,
		LastDailyDay = 0,
		DailyStreak = 0,
		NextFreeRoll = 0,
		RedeemedCodes = {},
		QuestDay = 0,
		QuestIds = {},
		QuestProgress = {},
		QuestDone = {},
		MusicOff = false,
		PointerOff = false,
		DoorBought = false,
		TutorialCompleted = false,
		TutorialEarned = false,
		OrdersCompleted = 0,
		VehicleSmashes = 0,
		OwnedVehicles = { Bike = true },
		GoldenProductsClaimed = 0,
	}
end

local DataService = {}
local cache: { [Player]: PlayerData } = {}
local loadFailed: { [Player]: boolean } = {}

function DataService.Load(player: Player): PlayerData
	if cache[player] then return cache[player] end
	local data: PlayerData
	if not store then
		data = defaultData()
	else
		local ok, result = pcall(function()
			return store:GetAsync("Player_" .. player.UserId)
		end)
		if ok and result then
			-- Слияние с дефолтами, а не голый каст: сейв, записанный прошлой версией,
			-- не содержит полей, добавленных позже (например UpgraderStage), и они
			-- пришли бы как nil — падение на первой же арифметике с ними.
			local merged = defaultData()
			for key, value in result :: { [string]: any } do
				if (merged :: any)[key] ~= nil then
					(merged :: any)[key] = value
				end
			end
			data = merged
		else
			if not ok then
				-- Never overwrite a real save with fallback data after a read failure.
				loadFailed[player] = true
				warn("[DataService] Не удалось загрузить данные " .. player.Name .. ": " .. tostring(result))
			end
			data = defaultData()
		end
	end
	cache[player] = data
	return data
end

function DataService.Get(player: Player): PlayerData?
	return cache[player]
end

function DataService.Save(player: Player)
	local data = cache[player]
	if not data or not store or loadFailed[player] then
		return
	end
	local ok, err = pcall(function()
		store:SetAsync("Player_" .. player.UserId, data)
	end)
	if not ok then
		warn("[DataService] Не удалось сохранить данные " .. player.Name .. ": " .. tostring(err))
	end
end

function DataService.Release(player: Player)
	cache[player] = nil
	loadFailed[player] = nil
end

function DataService.Init()
	Players.PlayerRemoving:Connect(function(player)
		DataService.Save(player)
		DataService.Release(player)
	end)

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			DataService.Save(player)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(120)
			for _, player in Players:GetPlayers() do
				DataService.Save(player)
			end
		end
	end)
end

return DataService
