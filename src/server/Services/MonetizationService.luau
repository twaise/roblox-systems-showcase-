--!strict
-- Покупки за робуксы: игровые пропуска (постоянные) и товары (разовые).
--
-- Правило проекта: за робуксы продаётся только СКОРОСТЬ и УДОБСТВО. Ни одна линия,
-- ни одно изделие и ни один питомец не заперты за оплатой — бесплатный игрок доходит
-- туда же, просто дольше. Поэтому P2W здесь не ломает экономику: покупка сдвигает
-- игрока по той же кривой, а не открывает недоступную ветку.
--
-- Владение пропуском НЕ хранится в сохранении: источник правды — MarketplaceService.
-- Иначе пропуск, купленный на другом сервере, не увиделся бы до перезахода, а
-- возврат средств не отобрался бы никогда.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local ProductionLineService = require(script.Parent.ProductionLineService)

local MonetizationService = {}

local MON = Config.Monetization

-- Кэш владения пропусками. UserOwnsGamePassAsync ходит по сети, дёргать его на
-- каждой продаже нельзя; обновляем при входе и после покупки.
local ownedPasses: { [Player]: { [string]: boolean } } = {}

local function passByKey(key: string)
	for _, p in MON.GamePasses do
		if p.Key == key then
			return p
		end
	end
	return nil
end

local function productByKey(key: string)
	for _, p in MON.Products do
		if p.Key == key then
			return p
		end
	end
	return nil
end

local function productById(id: number)
	for _, p in MON.Products do
		if p.Id == id or (p :: any).SaleId == id then
			return p
		end
	end
	return nil
end

-- ── Ограниченное предложение ────────────────────────────────────────────────────
-- Окно скидки считается от абсолютного времени и потому одинаково у всех игроков
-- сервера: перезаход его не сбрасывает, а обратный отсчёт в UI честный.
function MonetizationService.OfferState(): (boolean, number)
	local cfg = MON.LimitedOffer
	local phase = os.time() % cfg.Period
	if phase < cfg.Window then
		return true, os.time() + (cfg.Window - phase) -- активна, до какого времени
	end
	return false, os.time() + (cfg.Period - phase) -- неактивна, когда начнётся
end

local function boostActive(data: any): boolean
	return data.BoostUntil > os.time()
end

-- ── Применение купленного ───────────────────────────────────────────────────────

local function coinMultiplierFor(player: Player): number
	local mult = 1
	local owned = ownedPasses[player]
	if owned then
		for _, p in MON.GamePasses do
			if owned[p.Key] and (p :: any).CoinMultiplier then
				mult *= (p :: any).CoinMultiplier
			end
		end
	end
	return mult
end

function MonetizationService.ExtraPetSlots(player: Player): number
	local extra = 0
	local owned = ownedPasses[player]
	if owned then
		for _, p in MON.GamePasses do
			if owned[p.Key] and (p :: any).ExtraPetSlots then
				extra += (p :: any).ExtraPetSlots
			end
		end
	end
	return extra
end

local function pushState(player: Player)
	local data = DataService.Get(player)
	if not data then
		return
	end
	local boost = boostActive(data)
	ProductionLineService.SetPurchaseBonuses(
		player,
		coinMultiplierFor(player),
		if boost then MON.BoostMultiplier else 1
	)
	local offerActive, offerAt = MonetizationService.OfferState()
	Remotes.Get("MonetizationChanged"):FireClient(player, {
		Owned = ownedPasses[player] or {},
		BoostUntil = if boost then data.BoostUntil else 0,
		FreePetRolls = data.FreePetRolls,
		ExtraPetSlots = MonetizationService.ExtraPetSlots(player),
		OfferActive = offerActive,
		OfferAt = offerAt,
	})
end

MonetizationService.PushState = pushState

-- Бесплатный короткий буст. Нужен рычагу на втором этаже: сам этаж не давал
-- ничего, и покупка за пять миллионов оставалась чистой декорацией. Рычаг —
-- повторяемый повод туда подниматься, а не разовая галочка.
function MonetizationService.GrantFreeBoost(player: Player, seconds: number)
	local data = DataService.Get(player)
	if data == nil then
		return
	end
	-- Складываем с уже идущим бустом, а не перетираем: иначе рычаг, нажатый во
	-- время купленного за робуксы ускорения, УКОРАЧИВАЛ бы его.
	local from = math.max(data.BoostUntil, os.time())
	data.BoostUntil = from + seconds
	pushState(player)
end

local function refreshPasses(player: Player)
	local owned: { [string]: boolean } = {}
	for _, p in MON.GamePasses do
		if p.Id > 0 then
			-- pcall обязателен: вызов сетевой и падает при любом сбое связи. Без него
			-- один сетевой сбой уронил бы весь вход игрока.
			local ok, result = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, p.Id)
			end)
			owned[p.Key] = ok and result == true
			if not ok then
				warn("[Monetization] Не проверить пропуск " .. p.Key .. ": " .. tostring(result))
			end
		else
			-- Плейс не опубликован: сохраняем то, что выдал тестовый режим Studio.
			owned[p.Key] = (ownedPasses[player] or {})[p.Key] == true
		end
	end
	ownedPasses[player] = owned
end

-- Выдача товара. Одна точка и для настоящего чека, и для тестовой покупки в Studio,
-- чтобы проверенный в Studio путь был ровно тем же, что отработает в проде.
local function grantProduct(player: Player, product: any): boolean
	local data = DataService.Get(player)
	if not data then
		return false
	end
	local parts = {}
	if product.Coins then
		EconomyService.AddCoins(player, product.Coins)
		table.insert(parts, "coins")
	end
	if product.BoostSeconds then
		-- Буст ПРОДЛЕВАЕТСЯ, а не переписывается: купить второй, пока идёт первый,
		-- иначе означало бы выбросить остаток уже оплаченного времени.
		local from = math.max(data.BoostUntil, os.time())
		data.BoostUntil = from + product.BoostSeconds
		table.insert(parts, "boost")
	end
	if product.FreePetRolls then
		data.FreePetRolls += product.FreePetRolls
		table.insert(parts, "pet rolls")
	end
	pushState(player)
	Remotes.Get("PurchaseNotice"):FireClient(player, product.DisplayName .. ": granted (" .. table.concat(parts, ", ") .. ")")
	return true
end

-- ── Бесплатные крутки из бандла ─────────────────────────────────────────────────
-- Дёргается PetService перед списанием монет. Отдельная функция, а не поле данных
-- напрямую, чтобы клиент обновлялся тем же путём, что и от всего остального.
function MonetizationService.TryConsumeFreePetRoll(player: Player): boolean
	local data = DataService.Get(player)
	if not data or data.FreePetRolls <= 0 then
		return false
	end
	data.FreePetRolls -= 1
	pushState(player)
	return true
end

-- ── Запрос покупки от клиента ───────────────────────────────────────────────────

local function onRequestPurchase(player: Player, kind: string, key: string)
	if typeof(kind) ~= "string" or typeof(key) ~= "string" then
		return
	end
	local def = if kind == "Pass" then passByKey(key) else productByKey(key)
	if not def then
		return
	end

	-- Для бандла внутри окна скидки предлагается ОТДЕЛЬНЫЙ дешёвый товар: цену уже
	-- существующего товара Roblox менять не даёт, распродажа делается вторым Id.
	local id = def.Id
	if kind == "Product" and (def :: any).SaleId then
		local active = MonetizationService.OfferState()
		if active and (def :: any).SaleId > 0 then
			id = (def :: any).SaleId
		end
	end

	if id > 0 then
		if kind == "Pass" then
			MarketplaceService:PromptGamePassPurchase(player, id)
		else
			MarketplaceService:PromptProductPurchase(player, id)
		end
		return
	end

	-- Id ещё не проставлен — плейс не опубликован. В Studio выдаём напрямую, чтобы
	-- вся цепочка выдачи была проверяемой до публикации. В живой игре так делать
	-- нельзя ни при каких условиях, поэтому путь закрыт проверкой IsStudio.
	if not RunService:IsStudio() then
		Remotes.Get("PurchaseNotice"):FireClient(player, def.DisplayName .. ": this item is not published yet", true)
		return
	end
	if kind == "Pass" then
		local owned = ownedPasses[player] or {}
		owned[key] = true
		ownedPasses[player] = owned
		pushState(player)
		Remotes.Get("PurchaseNotice"):FireClient(player, def.DisplayName .. ": granted (Studio test mode)")
	else
		grantProduct(player, def)
	end
end

-- ── Приём настоящих покупок ─────────────────────────────────────────────────────

local function processReceipt(info: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(info.PlayerId)
	if not player then
		-- Игрок вышел до выдачи. NotProcessedYet, а не Granted: Roblox пришлёт этот же
		-- чек снова при следующем входе, и покупка не потеряется.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local data = DataService.Get(player)
	if not data then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local receipt = tostring(info.PurchaseId)
	if table.find(data.HandledReceipts, receipt) then
		return Enum.ProductPurchaseDecision.PurchaseGranted -- уже выдали
	end

	local product = productById(info.ProductId)
	if not product then
		warn("[Monetization] Неизвестный товар " .. tostring(info.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not grantProduct(player, product) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	table.insert(data.HandledReceipts, receipt)
	-- Список чеков не растёт бесконечно: он живёт в сохранении, а повторно Roblox
	-- присылает только недавние чеки.
	while #data.HandledReceipts > 50 do
		table.remove(data.HandledReceipts, 1)
	end
	-- Сохраняем СРАЗУ: иначе краш сервера между выдачей и автосейвом стёр бы и
	-- выданное, и отметку о чеке — игрок остался бы без оплаченного товара.
	DataService.Save(player)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function MonetizationService.Init()
	MarketplaceService.ProcessReceipt = processReceipt

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if not wasPurchased then
			return
		end
		for _, p in MON.GamePasses do
			if p.Id == gamePassId then
				local owned = ownedPasses[player] or {}
				owned[p.Key] = true
				ownedPasses[player] = owned
				pushState(player)
				Remotes.Get("PurchaseNotice"):FireClient(player, p.DisplayName .. ": activated")
			end
		end
	end)

	Remotes.Get("RequestPurchase").OnServerEvent:Connect(onRequestPurchase)

	Players.PlayerRemoving:Connect(function(player)
		ownedPasses[player] = nil
	end)

	-- Один общий таймер вместо task.delay на каждую покупку: когда буст истекает,
	-- множитель надо снять, а клиенту показать, что ускорения больше нет.
	task.spawn(function()
		while true do
			task.wait(5)
			for _, player in Players:GetPlayers() do
				local data = DataService.Get(player)
				if data and data.BoostUntil > 0 and data.BoostUntil <= os.time() then
					data.BoostUntil = 0
					pushState(player)
				end
			end
		end
	end)
end

-- Вызывается TycoonService после загрузки данных и постройки участка: раньше
-- ставить множители некуда — участка ещё нет.
function MonetizationService.Setup(player: Player)
	refreshPasses(player)
	pushState(player)
end

return MonetizationService
