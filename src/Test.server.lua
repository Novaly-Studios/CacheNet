local CacheNet = require(script.Parent)
    local TypeGuard = CacheNet.TypeGuard

local Test = CacheNet.new("Test", TypeGuard.Array(TypeGuard.Cacheable(TypeGuard.String())))
Test.OnServerEvent:Connect(function(...)
    print("Received", ...)
end)
