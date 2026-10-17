--!strict
-- Таблица игроков (Tab / кнопка списка). В тайкунах она есть всегда, и не ради
-- красоты: чужой баланс на экране — это единственная бесплатная причина копить
-- дальше, когда свои линии уже открыты.
--
-- Значения ОБНОВЛЯЮТСЯ ОПРОСОМ раз в секунду, а не из EconomyService.AddCoins.
-- Так сделано намеренно: монеты меняются на каждой проданной детали (до
-- нескольких раз в секунду на игрока), и дёргать leaderstats на каждую продажу
-- значило бы слать репликацию впустую. Секундной задержки на табло не видно.

local Players = game:GetService("Players")

local DataService = require(script.Parent.DataService)

local LeaderboardService = {}

local REFRESH = 1

-- "1234567" -> "1.2M". Полное число в таблицу не влезает: колонка узкая, и
-- десятизначный баланс превращается в кашу. Точное значение игрок видит в HUD.
local UNITS: { { n: number, s: string } } = {
	{ n = 1e12, s = "T" },
	{ n = 1e9, s = "B" },
	{ n = 1e6, s = "M" },
	{ n = 1e3, s = "K" },
}

local function abbrev(value: number): string
	for _, u in UNITS do
		if value >= u.n then
			local scaled = value / u.n
			-- До 10 показываем десятую долю (1.2M), дальше она уже не различима
			-- на глаз и только удлиняет строку (127M вместо 127.4M).
			if scaled < 10 then
				return string.format("%.1f%s", scaled, u.s)
			end
			return string.format("%d%s", math.floor(scaled), u.s)
		end
	end
	return tostring(math.floor(value))
end

local function setup(player: Player)
	-- Папка обязана называться именно leaderstats — Roblox ищет её по имени.
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"

	-- Имя колонки Roblox НЕ переводит (в списке игроков рисуется Instance.Name),
	-- поэтому оно английское для всех: под английское название игры и потому что
	-- «Cash» — стандартная подпись в тайкунах.
	local coins = Instance.new("StringValue")
	coins.Name = "Cash"
	coins.Value = "0"
	coins.Parent = stats

	-- Ребёрты — IntValue, а не строка: по первому числовому значению Roblox
	-- сортирует таблицу, и сортировка по престижу здесь осмысленнее, чем по
	-- текущему балансу, который у всех скачет туда-сюда.
	local rebirths = Instance.new("IntValue")
	rebirths.Name = "Rebirths"
	rebirths.Value = 0
	rebirths.Parent = stats

	stats.Parent = player
end

function LeaderboardService.Init()
	Players.PlayerAdded:Connect(setup)
	-- Игроки, вошедшие ДО инициализации сервиса: в Studio при Play сервер
	-- поднимается уже с игроком в списке, и без этого прохода таблица пустая.
	for _, player in Players:GetPlayers() do
		if player:FindFirstChild("leaderstats") == nil then
			setup(player)
		end
	end

	task.spawn(function()
		while true do
			task.wait(REFRESH)
			for _, player in Players:GetPlayers() do
				local stats = player:FindFirstChild("leaderstats")
				local data = DataService.Get(player)
				if stats ~= nil and data ~= nil then
					local coins = stats:FindFirstChild("Cash") :: StringValue?
					if coins ~= nil then
						coins.Value = abbrev(data.Coins)
					end
					local rebirths = stats:FindFirstChild("Rebirths") :: IntValue?
					if rebirths ~= nil then
						rebirths.Value = data.Rebirths
					end
				end
			end
		end
	end)
end

return LeaderboardService
