--!strict
-- Ежедневные задания.
--
-- Зачем отдельным сервисом: ежедневная награда в RetentionService платит за ЗАХОД,
-- и её можно забрать, не сыграв ни секунды. Задание платит за игру, и именно оно
-- превращает короткий заход «забрал и вышел» в сессию. Длина сессии — второй по
-- весу сигнал подбора после возвращаемости.
--
-- Три задания в сутки и обязательно разных родов: три подряд «продай N» читаются
-- как одно задание, разбитое на три строки, и мотивируют не больше одного.
--
-- Всё считает СЕРВЕР. Клиент не сообщает о прогрессе вообще: он только получает
-- готовый список. Любой счётчик, которому клиент может прибавить, — это бесплатные
-- монеты для того, кто откроет проводник.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local ProductionLineService = require(script.Parent.ProductionLineService)
local HammerGachaService = require(script.Parent.HammerGachaService)
local PetService = require(script.Parent.PetService)
local TycoonService = require(script.Parent.TycoonService)
local FactoryOrderService = require(script.Parent.FactoryOrderService)
local VehicleService = require(script.Parent.VehicleService)

local QuestService = {}

local SECONDS_PER_DAY = 86400

-- Отсчёт минут для заданий на время идёт от ЗАХОДА, а не копится в сохранении:
-- задание «сыграй 10 минут» должно требовать десяти минут подряд, иначе оно
-- закрывается само собой за десять заходов по минуте и ничего не удерживает.
local sessionStart: { [Player]: number } = {}

local function utcDay(t: number): number
	return math.floor(t / SECONDS_PER_DAY)
end

local function findQuest(id: string): any
	for _, q in Config.Quests.Pool do
		if q.Id == id then
			return q
		end
	end
	return nil
end

-- Выбор заданий на сутки. Зерно собрано из номера суток и id игрока, поэтому
-- набор ОДИНАКОВ при каждом перезаходе в эти сутки и РАЗНЫЙ у соседа: случайный
-- выбор при каждом входе позволял бы перезаходить, пока не выпадет лёгкое.
local function rollQuests(player: Player, day: number): { string }
	local rng = Random.new(day * 7919 + player.UserId % 100000)
	local pool = table.clone(Config.Quests.Pool)
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local picked: { string } = {}
	local usedKinds: { [string]: boolean } = {}
	for _, q in pool do
		if #picked >= Config.Quests.PerDay then
			break
		end
		if not usedKinds[q.Kind] then
			usedKinds[q.Kind] = true
			table.insert(picked, q.Id)
		end
	end
	-- Если родов в пуле меньше, чем заданий на сутки, добираем чем есть.
	for _, q in pool do
		if #picked >= Config.Quests.PerDay then
			break
		end
		if table.find(picked, q.Id) == nil then
			table.insert(picked, q.Id)
		end
	end
	return picked
end

-- Отправка списка ДРОССЕЛИРУЕТСЯ. Прогресс рода Sell прибавляется на каждой
-- проданной детали, то есть по несколько раз в секунду на игрока, и слать на
-- каждую продажу таблицу из трёх заданий шести игрокам — это десятки лишних
-- пакетов в секунду ради строки, которая на глаз меняется раз в несколько секунд.
-- Ровно по этой причине и таблица игроков обновляется опросом, а не из AddCoins.
--
-- Завершение задания и смена суток шлются НЕМЕДЛЕННО: там задержка была бы видна.
local dirty: { [Player]: boolean } = {}

local function push(player: Player)
	local data = DataService.Get(player)
	if data == nil then
		return
	end
	local list = {}
	for _, id in data.QuestIds do
		local cfg = findQuest(id)
		if cfg ~= nil then
			table.insert(list, {
				Id = id,
				Text = cfg.Text,
				Target = cfg.Target,
				Progress = math.min(data.QuestProgress[id] or 0, cfg.Target),
				Done = data.QuestDone[id] == true,
			})
		end
	end
	dirty[player] = nil
	Remotes.Get("QuestsChanged"):FireClient(player, list)
end

local function ensureDay(player: Player)
	local data = DataService.Get(player)
	if data == nil then
		return
	end
	local today = utcDay(os.time())
	-- Конфиг заданий может измениться посреди суток. Не оставляем игроку старые
	-- удалённые Id (например прежние пассивные Sell60/Sell200): такой слот вообще
	-- не рисуется и до следующего UTC-дня выглядит как пропавшее задание.
	local currentSetIsValid = data.QuestDay == today and #data.QuestIds > 0
	if currentSetIsValid then
		for _, id in data.QuestIds do
			if findQuest(id) == nil then
				currentSetIsValid = false
				break
			end
		end
	end
	if currentSetIsValid then
		return
	end
	data.QuestDay = today
	data.QuestIds = rollQuests(player, today)
	data.QuestProgress = {}
	data.QuestDone = {}
end

local function complete(player: Player, data: DataService.PlayerData, id: string, cfg: any)
	data.QuestDone[id] = true
	local rate = ProductionLineService.GetBaseIncomePerSecond(player)
	local coins = math.max(math.floor(rate * cfg.IncomeSeconds), cfg.MinCoins)
	EconomyService.AddCoins(player, coins)
	local text = "Quest done: " .. cfg.Text .. " - " .. coins .. " coins"
	if cfg.FreeRolls > 0 then
		data.FreePetRolls += cfg.FreeRolls
		text ..= " + " .. cfg.FreeRolls .. (if cfg.FreeRolls == 1 then " free pet roll" else " free pet rolls")
	end
	Remotes.Get("PurchaseNotice"):FireClient(player, text)
end

-- Единая точка прибавки прогресса. Её зовут места, где событие ПРОИСХОДИТ, а не
-- этот сервис: иначе пришлось бы требовать QuestService из ProductionLineService
-- и получить кольцо в зависимостях.
function QuestService.Progress(player: Player, kind: string, amount: number)
	local data = DataService.Get(player)
	if data == nil or amount <= 0 then
		return
	end
	ensureDay(player)
	local changed = false
	for _, id in data.QuestIds do
		if data.QuestDone[id] then
			continue
		end
		local cfg = findQuest(id)
		if cfg == nil or cfg.Kind ~= kind then
			continue
		end
		local now = (data.QuestProgress[id] or 0) + amount
		data.QuestProgress[id] = now
		changed = true
		if now >= cfg.Target then
			complete(player, data, id, cfg)
			push(player) -- закрытое задание показываем сразу
			changed = false
		end
	end
	if changed then
		dirty[player] = true
	end
end

-- Вызывается ПОСЛЕ создания участка: награда за задание считается от дохода, а до
-- участка GetBaseIncomePerSecond вернул бы ноль.
function QuestService.Setup(player: Player)
	ensureDay(player)
	sessionStart[player] = os.time()
	push(player)
end

function QuestService.Init()
	-- Крючки ставятся отсюда, а не из тех сервисов: зависимость односторонняя,
	-- QuestService знает про них, они про QuestService — нет.
	HammerGachaService.OnRolled = function(player: Player)
		QuestService.Progress(player, "Roll", 1)
	end
	PetService.OnRolled = function(player: Player)
		QuestService.Progress(player, "Roll", 1)
	end
	TycoonService.OnUpgradeBought = function(player: Player)
		QuestService.Progress(player, "Buy", 1)
	end
	FactoryOrderService.OnCompleted = function(player: Player)
		QuestService.Progress(player, "Order", 1)
	end
	VehicleService.OnSmashed(function(player: Player, _target: Instance)
		QuestService.Progress(player, "Smash", 1)
	end)

	-- Задержка ровно та же, что у надбавки за друзей: участок выдаётся в своём
	-- обработчике PlayerAdded, и до его конца доход считать не с чего.
	Players.PlayerAdded:Connect(function(player)
		task.delay(2, function()
			if player.Parent ~= nil then
				QuestService.Setup(player)
			end
		end)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(QuestService.Setup, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		sessionStart[player] = nil
		dirty[player] = nil
	end)

	-- Слив накопленного прогресса раз в секунду: на глаз это то же самое, что
	-- мгновенно, а пакетов уходит на порядок меньше.
	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in Players:GetPlayers() do
				if dirty[player] then
					push(player)
				end
			end
		end
	end)

	-- Задания на время тикают сами: считать их через общий крючок неоткуда, а
	-- полминуты — достаточная точность для порога в десять минут.
	task.spawn(function()
		while true do
			task.wait(30)
			for _, player in Players:GetPlayers() do
				local started = sessionStart[player]
				local data = DataService.Get(player)
				if started == nil or data == nil then
					continue
				end
				-- Смена суток проверяется ЗДЕСЬ, а не только при входе: тот, кто
				-- сидит в игре через полночь по UTC, иначе остался бы со вчерашними
				-- заданиями до перезахода, причём закрытыми. Ежедневная награда
				-- сутки проверяет на каждом заборе и такой дыры не имеет.
				local before = data.QuestDay
				ensureDay(player)
				if data.QuestDay ~= before then
					sessionStart[player] = os.time()
					started = sessionStart[player]
					push(player)
				end
				local minutes = math.floor((os.time() - started) / 60)
				for _, id in data.QuestIds do
					if data.QuestDone[id] then
						continue
					end
					local cfg = findQuest(id)
					if cfg ~= nil and cfg.Kind == "Playtime" then
						data.QuestProgress[id] = minutes
						if minutes >= cfg.Target then
							complete(player, data, id, cfg)
						end
					end
				end
				push(player)
			end
		end
	end)
end

return QuestService
