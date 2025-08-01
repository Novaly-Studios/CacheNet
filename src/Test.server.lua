local ReplicatedFirst = game:GetService("ReplicatedFirst")
    local CacheNet = require(ReplicatedFirst.CacheNet)

local RemoteEvent = Instance.new("RemoteEvent")
RemoteEvent.Parent = workspace

local Test = CacheNet.new(RemoteEvent, CacheNet.TypeGuard.Any())

while (#game.Players:GetPlayers() == 0) do
    task.wait()
end

Test:FireClient(game.Players:GetPlayers()[1], "AHHHHHHHHHHHHH")
