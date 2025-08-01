local ReplicatedFirst = game:GetService("ReplicatedFirst")
    local CacheNet = require(ReplicatedFirst.CacheNet)

local Test = CacheNet.new(workspace:WaitForChild("RemoteEvent"), CacheNet.TypeGuard.Any())

Test.OnClientEvent:Connect(function(Data)
    print("Received Data:", Data)
end)
