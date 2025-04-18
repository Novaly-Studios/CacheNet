# CacheNet

A RemoteEvent wrapper for TypeGuard which integrates its ValueCache wrapper, creating synchronized caches between sender-receiver pairs, along with all the inherent TypeGuard serialization & deserialization features. These caches save space for commonly repeated values. Fixed-size self-overwriting caches are used to allow the potentially large amount of cached data transferred in a session to be mostly garbage collected and not waste memory. Currently this implements two cache types:

- Circular: a fixed-size circular buffer which circles back around when full and overwrites previously recorded values.
- LRU: a least-recently-used cache which removes a value which has not been used recently when full, allowing commonly used values to have a longer lifetime in the cache.
- Permanent: a dynamic-size cache which does not remove values, allowing all values to be stored in memory until the cache is garbage collected. Not generally recommended unless the only cached values are known values which can stay around for the session.

## Todos

- Option to have the cache synchronized between all devices instead of just pairs of devices
- Synchronized dictionary compression (*should natively integrate with the TypeGuard buffer compression cache without any further action when that is finished)
- Client-to-client communication layer?
  - Abstract away from RemoteEvents and have a RemoteEvent layer sitting above
  - Can then use this as Vapor's Actor-to-Actor communication layer
- Time-based removal of cache items?
- Luau type definitions
- Unreliable remotes / split into 900 byte chunks

## Examples

```lua
-- Client
local Test = Remote.new("Test", TypeGuard.Array(TypeGuard.Cacheable(TypeGuard.String())))
task.wait(2)
Test:FireServer({"AAAA", "BBBB", "CCCC"})
task.wait(1)
Test:FireServer({"CCCC"})
```

```lua
local Test = Remote.new("Test", TypeGuard.Array(TypeGuard.Cacheable(TypeGuard.String())))
Test.OnServerEvent:Connect(function(...)
    print("Received", ...)
end)
```
