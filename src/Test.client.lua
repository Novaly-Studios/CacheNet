local CacheNet = require(script.Parent)
    local TypeGuard = CacheNet.TypeGuard

local Test = CacheNet.new("Test", TypeGuard.Array(TypeGuard.Cacheable(TypeGuard.String())))
task.wait(2)
Test:FireServer({"AAAA", "BBBB", "CCCC"})
task.wait(1)
Test:FireServer({"CCCC"})