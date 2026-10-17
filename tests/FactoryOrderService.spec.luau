-- Run with Studio execute_luau in Edit. Isolated fake clock/data; no game saves.
local folder = Instance.new("Folder")
folder.Name = "FactoryOrderTestFixture"
folder.Parent = game.ServerStorage
local fake = Instance.new("ModuleScript", folder)
fake.Name = "Fakes"
fake.Source = [==[
local f = { Time = 1000, Grants = 0, Notices = {} }
local function signal()
 local callbacks = {}
 return { Connect = function(_, cb) table.insert(callbacks, cb) end, Fire = function(_, ...) for _, cb in callbacks do cb(...) end end }
end
f.Player = Instance.new("Folder")
f.Player:SetAttribute("HasPlot", true)
f.Data = {TutorialCompleted=true, LineUnlocked={Wood=true}, LineStage={Wood=2}, OrdersCompleted=0, FreePetRolls=0, Coins=0}
f.Players = { GetPlayers=function()return {f.Player}end, PlayerRemoving=signal() }
local events={}
f.Remotes = {Get=function(name)
 if not events[name]then events[name]={OnServerEvent=signal(),FireClient=function(_,p,t,e)table.insert(f.Notices,{text=t,error=e})end}end
 return events[name]
end}
f.DataService={Get=function()return f.Data end}
f.Economy={AddCoins=function(_,amount)f.Data.Coins+=amount;f.Grants+=1 end}
f.Production={GetBaseIncomePerSecond=function()return 10 end}
f.Chassis = nil
f.Vehicles={GetDrivenChassis=function()return f.Chassis end}
f.Retention={PushState=function()end}
f.Config={Lines={{Id="Wood",Products={{DisplayName="Plank"},{DisplayName="Stool"}}}}}
f.Config.GetLine=function()return f.Config.Lines[1]end
f.Spawn=function(fn)f.Loop=coroutine.create(fn)end
f.Tick=function()local ok,e=coroutine.resume(f.Loop)assert(ok,e)end
return f
]==]
local fixture = Instance.new("ModuleScript", folder)
fixture.Name = "Service"
local source = game.ServerScriptService.Server.Services.FactoryOrderService.Source
local function replace(old, new)
 local start, finish = source:find(old, 1, true)
 assert(start, "Missing injection site: " .. old)
 source = source:sub(1,start-1)..new..source:sub(finish+1)
end
replace('game:GetService("Players")', 'require(script.Parent.Fakes).Players')
replace('require(ReplicatedStorage.Shared.Config)', 'require(script.Parent.Fakes).Config')
replace('require(ReplicatedStorage.Shared.Remotes)', 'require(script.Parent.Fakes).Remotes')
replace('require(script.Parent.DataService)', 'require(script.Parent.Fakes).DataService')
replace('require(script.Parent.EconomyService)', 'require(script.Parent.Fakes).Economy')
replace('require(script.Parent.ProductionLineService)', 'require(script.Parent.Fakes).Production')
replace('require(script.Parent.RetentionService)', 'require(script.Parent.Fakes).Retention')
replace('require(script.Parent.VehicleService)', 'require(script.Parent.Fakes).Vehicles')
replace('workspace:GetServerTimeNow()', 'require(script.Parent.Fakes).Time')
replace('task.spawn(function()', 'require(script.Parent.Fakes).Spawn(function()')
replace('task.wait(0.1)', 'coroutine.yield()')
fixture.Source = source
local f = require(fake)
local ok, result = pcall(function()
 require(fixture).Init()
 local p=f.Player
 local function accept() f.Remotes.Get("RequestFactoryOrder").OnServerEvent:Fire(p) end
 local function sold(line,stage)f.Production.OnOrderProductSold(p,line or "Wood",stage or 2)end
 local function deliver()
  assert(p:GetAttribute("OrderState")=="Delivering")
  local target=p:GetAttribute("OrderDestination")
  f.Chassis={Position=target,AssemblyLinearVelocity=Vector3.new(80,0,0)}
  f.Tick()
  f.Chassis=nil
 end
 f.Tick(); assert(p:GetAttribute("OrderState")=="Ready")
 f.Data.TutorialCompleted=false;accept();assert(p:GetAttribute("OrderState")=="Ready")
 f.Data.TutorialCompleted=true; f.Time+=1;accept()
 assert(p:GetAttribute("OrderState")=="Active")
 local deadline=p:GetAttribute("OrderEndsAt")
 f.Time+=1;accept();assert(p:GetAttribute("OrderEndsAt")==deadline)
 sold("Stone",2);sold("Wood",1);assert(p:GetAttribute("OrderProgress")==0)
 for _=1,12 do sold()end
 assert(p:GetAttribute("OrderState")=="Delivering" and f.Grants==0)
 local deliveryDeadline=p:GetAttribute("OrderEndsAt")
 sold();assert(p:GetAttribute("OrderProgress")==12 and p:GetAttribute("OrderEndsAt")==deliveryDeadline)
 f.Time+=3;f.Tick();assert(f.Grants==0,"On foot cannot deliver")
 local target=p:GetAttribute("OrderDestination")
 f.Chassis={Position=target+Vector3.new(50,0,0),AssemblyLinearVelocity=Vector3.new(80,0,0)}
 f.Tick();assert(f.Grants==0,"Outside vehicle cannot deliver")
 deliver()
 assert(f.Data.Coins==900 and f.Data.OrdersCompleted==1 and f.Grants==1)
 assert(p:GetAttribute("OrderDestination")==nil)
 sold(); f.Time+=1; accept(); assert(f.Grants==1 and p:GetAttribute("OrderState")=="Complete")
 f.Time+=121;f.Tick();accept()
 for _=1,18 do sold()end
 deliver()
 assert(f.Data.OrdersCompleted==2 and f.Data.FreePetRolls==0)
 f.Time+=121;f.Tick();accept()
 assert(p:GetAttribute("OrderRolls")==1)
 for _=1,24 do sold()end
 deliver()
 assert(f.Data.OrdersCompleted==3 and f.Data.FreePetRolls==1 and f.Grants==3)
 assert(p:GetAttribute("SupplierRank")=="TRUSTED SUPPLIER")
 f.Time+=121;f.Tick();accept();f.Time+=91;sold()
 assert(p:GetAttribute("OrderState")=="Expired" and f.Grants==3)
 f.Time+=121;f.Tick();accept();for _=1,12 do sold()end
 assert(p:GetAttribute("OrderState")=="Delivering")
 f.Time+=181;f.Tick();assert(p:GetAttribute("OrderState")=="Expired" and f.Grants==3 and p:GetAttribute("OrderDestination")==nil)
 f.Time+=121;f.Tick();accept();f.Time+=91;f.Tick()
 assert(p:GetAttribute("OrderState")=="Expired" and f.Grants==3)
 f.Players.PlayerRemoving:Fire(p)
 return "PASS: tutorial gate, duplicate requests, wrong line/stage, packing gives no bonus, on-foot/outside rejection, instant high-speed touch, 3 deliveries, exactly-once payment, cooldown, pet roll, rank, packing/delivery expiration, cleanup"
end)
if f.Loop then coroutine.close(f.Loop) end
f.Player:Destroy()
folder:Destroy()
assert(ok,result)
return result
