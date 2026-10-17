--!strict
-- Timed factory contracts. Only real server-side sales advance a contract.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local Production = require(script.Parent.ProductionLineService)
local Retention = require(script.Parent.RetentionService)
local Vehicles = require(script.Parent.VehicleService)
local Service = {}
Service.OnCompleted = nil :: ((Player) -> ())?
local DURATION = 90
local COOLDOWN = 120
type Order = { Line: string, Stage: number, Target: number, Progress: number, Coins: number, Rolls: number, EndsAt: number, Destination: Vector3? }
local active: { [Player]: Order } = {}
local readyAt: { [Player]: number } = {}
local requestAt: { [Player]: number } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function rank(completed: number): string
	return if completed >= 25 then "MASTER SUPPLIER" elseif completed >= 10 then "EXPERT SUPPLIER" elseif completed >= 3 then "TRUSTED SUPPLIER" else "NEW SUPPLIER"
end

local function offer(player: Player): Order?
	local data = DataService.Get(player)
	if not data or not data.TutorialCompleted or player:GetAttribute("HasPlot") ~= true then return nil end
	local lines = {}
	for _, line in Config.Lines do
		if data.LineUnlocked[line.Id] then table.insert(lines, line) end
	end
	if #lines == 0 then return nil end
	local line = lines[(data.OrdersCompleted % #lines) + 1]
	local stage = data.LineStage[line.Id] or 1
	local target = 12 + (data.OrdersCompleted % 3) * 6
	return { Line = line.Id, Stage = stage, Target = target, Progress = 0,
		Coins = math.max(150, math.floor(Production.GetBaseIncomePerSecond(player) * 90)),
		Rolls = if (data.OrdersCompleted + 1) % 3 == 0 then 1 else 0, EndsAt = 0 }
end

local function show(player: Player, order: Order, state: string)
	local line = Config.GetLine(order.Line)
	player:SetAttribute("OrderLine", order.Line)
	player:SetAttribute("OrderProduct", if line then line.Products[order.Stage].DisplayName else order.Line)
	player:SetAttribute("OrderTarget", order.Target)
	player:SetAttribute("OrderProgress", order.Progress)
	player:SetAttribute("OrderCoins", order.Coins)
	player:SetAttribute("OrderRolls", order.Rolls)
	player:SetAttribute("OrderEndsAt", order.EndsAt)
	player:SetAttribute("OrderState", state)
end

local function finish(player: Player, success: boolean)
	local order = active[player]
	if not order then return end
	active[player] = nil -- retire before issuing rewards; repeated sales cannot pay twice
	readyAt[player] = now() + COOLDOWN
	player:SetAttribute("OrderReadyAt", readyAt[player])
	player:SetAttribute("OrderState", if success then "Complete" else "Expired")
	player:SetAttribute("OrderDestination", nil)
	if not success then
		Remotes.Get("PurchaseNotice"):FireClient(player, "Order expired. You keep all your sales!", true)
		return
	end
	local data = DataService.Get(player)
	if not data then return end
	data.OrdersCompleted += 1
	data.FreePetRolls += order.Rolls
	EconomyService.AddCoins(player, order.Coins)
	player:SetAttribute("OrdersCompleted", data.OrdersCompleted)
	player:SetAttribute("SupplierRank", rank(data.OrdersCompleted))
	Retention.PushState(player)
	if Service.OnCompleted ~= nil then Service.OnCompleted(player) end
	Remotes.Get("PurchaseNotice"):FireClient(player, "ORDER DELIVERED! +" .. order.Coins .. " coins" .. (if order.Rolls > 0 then " + FREE PET ROLL!" else ""))
end

function Service.Init()
	Remotes.Get("RequestFactoryOrder").OnServerEvent:Connect(function(player)
		local time = now()
		if time - (requestAt[player] or 0) < 0.5 then return end
		requestAt[player] = time
		if active[player] or time < (readyAt[player] or 0) then return end
		local order = offer(player)
		if not order or order.Destination then return end
		order.EndsAt = time + DURATION
		active[player] = order
		show(player, order, "Active")
		Remotes.Get("PurchaseNotice"):FireClient(player, "Rush order started! Keep your " .. order.Line .. " line running.")
	end)
	Production.OnOrderProductSold = function(player, lineId, stage)
		local order = active[player]
		if not order or order.Destination then return end
		if now() >= order.EndsAt then finish(player, false); return end
		if lineId ~= order.Line or stage < order.Stage then return end
		order.Progress += 1
		player:SetAttribute("OrderProgress", order.Progress)
		if order.Progress >= order.Target then
			local chassis = Vehicles.GetDrivenChassis(player)
			local plot = workspace:FindFirstChild(player.Name .. "_Plot")
			local x = if chassis then chassis.Position.X elseif plot and plot:IsA("Model") then plot:GetPivot().Position.X else 350
			order.Destination = Vector3.new(if x < 350 then 600 else 100, 0.7, 106)
			order.EndsAt = now() + 180
			player:SetAttribute("OrderDestination", order.Destination)
			player:SetAttribute("OrderEndsAt", order.EndsAt)
			player:SetAttribute("OrderState", "Delivering")
			Remotes.Get("PurchaseNotice"):FireClient(player, "Cargo ready! Drive to the gold delivery zone.")
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		active[player] = nil; readyAt[player] = nil; requestAt[player] = nil
	end)
	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				local data = DataService.Get(player)
				if data then
					player:SetAttribute("OrdersCompleted", data.OrdersCompleted)
					player:SetAttribute("SupplierRank", rank(data.OrdersCompleted))
				end
				local order = active[player]
				if order and now() >= order.EndsAt then
					finish(player, false)
				elseif order and order.Destination then
					local chassis = Vehicles.GetDrivenChassis(player)
					local delta = if chassis then chassis.Position - order.Destination else Vector3.zero
					-- Аркадная доставка: достаточно коснуться прямоугольной зоны любой частью
					-- шасси. Не заставляем тормозить — влететь в финиш на полном ходу веселее.
					local inside = chassis ~= nil and math.abs(delta.X) <= 14.5 and math.abs(delta.Z) <= 10
					if inside then finish(player, true) end
				elseif not order and now() >= (readyAt[player] or 0) then
					local nextOrder = offer(player)
					if nextOrder then show(player, nextOrder, "Ready") end
				end
			end
			task.wait(0.1)
		end
	end)
end

return Service
