--!optimize 2
--!native

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RunService = game:GetService("RunService")
    local IsClient = RunService:IsClient()

local Players = game:GetService("Players")

local Caches = script.Caches
    local PermanentCache = require(Caches.Permanent)
    local CircularCache = require(Caches.Circular)
    local LRUCache = require(Caches.LeastRecentlyUsed)

local TypeGuard = require(script.Parent.TypeGuard)
    type SignatureTypeChecker = TypeGuard.SignatureTypeChecker

local XSignal = require(script.Parent.XSignal)

local CustomRemotes = ReplicatedStorage:FindFirstChild("CustomRemotes")

if (IsClient) then
    CustomRemotes = ReplicatedStorage:WaitForChild("CustomRemotes")
else
    CustomRemotes = Instance.new("Folder")
    CustomRemotes.Name = "CustomRemotes"
    CustomRemotes.Parent = ReplicatedStorage
end

local RemoteHooks = {}

local DynamicUInt = TypeGuard.Number():Integer():Dynamic():Positive()
local InstanceRef = TypeGuard.Object({
    _Ref = DynamicUInt;
}):Strict()
local ValidTypeCache = TypeGuard.Or(
    TypeGuard.String():MinLength(3):MaxLength(128),
    TypeGuard.Instance()
)
local Buffer = TypeGuard.Buffer()
local Package = TypeGuard.Object({
    CacheDifferences = Buffer;
    Payload = Buffer;
}):Strict()
local Any = TypeGuard.Any()

-- Key principle here: each node / device contains a table of caches corresponding to other devices, effectively conceptualized
-- as DeviceA: (DeviceA->DeviceB {}, DeviceB->DeviceA {}), DeviceB: (DeviceB->DeviceA {}, DeviceA->DeviceB {}). That prevents a
-- shared mutable cache between each device pair which would require lockstep networking, but also means the first time data is
-- sent, there might be non-cached duplication. For instance, DeviceA -> DeviceB sends "Hello", DeviceB -> DeviceA sends "Hello".
-- DeviceA's DeviceB cache will update with "Hello", and DeviceB's DeviceA cache will update with "Hello". The next time DeviceA
-- sends "Hello", it will send something cached instead, likewise if DeviceB sends "Hello" to DeviceA. But both will have initially
-- sent a duplicated "Hello" string.

local RemoteWrapper = {}
RemoteWrapper.__index = RemoteWrapper
RemoteWrapper.TypeGuard = TypeGuard -- Better for user to define types using the version of TypeGuard this library uses to prevent incompatibility.
RemoteWrapper.Caches = {
    Permanent = PermanentCache;
    Circular = CircularCache;
    LRU = LRUCache;
}

type Config = {
    ValidCacheType: SignatureTypeChecker?;
    SerializeType: (() -> typeof(TypeGuard.Serializers.Byte()));
    CacheClass: (typeof(CircularCache.new(1)) | typeof(LRUCache.new(1)) | typeof(PermanentCache.new()))?;
    CacheSize: number?;
}

function RemoteWrapper.new(RemoteEvent: RemoteEvent, Definition: SignatureTypeChecker?, Config: Config?): typeof(RemoteWrapper)
    local Existing = RemoteHooks[RemoteEvent]

    if (Existing) then
        assert(Definition == nil, "Attempt to change existing RemoteWrapper definition")
        assert(Config == nil, "Attempt to reconfigure RemoteWrapper")
        return Existing
    end

    local Event = XSignal.XSignal.new()
    local ValidCacheType = (Config and Config.ValidCacheType or ValidTypeCache)

    local self = setmetatable({
        _SerializableValidCacheType = TypeGuard.Array(TypeGuard.Or(ValidCacheType, DynamicUInt, InstanceRef));
        _ValidCacheType = ValidCacheType;
        _SerializeType = (Config and Config.SerializeType or TypeGuard.Serializers.Bit);
        _NodeToState = {};
        _RemoteEvent = RemoteEvent;
        _CacheClass = (Config and Config.CacheClass or LRUCache);
        _Definition = (Definition or Any);
        _CacheSize = (Config and Config.CacheSize or 128);
        _RemoteID = RemoteEvent.Name;

        OnClientEvent = Event;
        OnServerEvent = Event;
    }, RemoteWrapper)

    self._PlayerLeftConnection = Players.PlayerRemoving:Connect(function(Player)
        self._NodeToState[Player.Name] = nil
    end)

    self._RemoteConnection = (IsClient and RemoteEvent.OnClientEvent:Connect(function(Package, Refs)
        self:_ReceiveEvent(Package, Refs, self:_GetOrCreateNodeState("Server"))
    end) or RemoteEvent.OnServerEvent:Connect(function(Player, Package, Refs)
        local SenderID = Player.Name
        self:_ReceiveEvent(Package, Refs, self:_GetOrCreateNodeState(SenderID), SenderID)
    end))

    return self
end

function RemoteWrapper:_ReceiveEvent(Data, Refs, SenderNodeState, SenderID)
    debug.profilebegin(`Deserialize-{self._RemoteID}`)

    local SerializeType = self._SerializeType
    local Pair = Package:Deserialize(Data, SerializeType(), true)
        local CacheDifferences = self._SerializableValidCacheType:Deserialize(Pair.CacheDifferences, SerializeType(), true)
        local Payload = Pair.Payload

    for Key, Value in CacheDifferences do
        if (typeof(Value) ~= "table") then
            continue
        end

        local Ref = Value._Ref

        if (not Ref) then
            continue
        end

        CacheDifferences[Key] = Refs[Ref]
    end

    SenderNodeState.BeginReceive(CacheDifferences)
    Payload = SenderNodeState.Definition:Deserialize(Payload, SerializeType())

    if (IsClient) then
        debug.profileend()
        self.OnClientEvent:Fire(Payload)
        return
    end

    local Player = Players:FindFirstChild(SenderID)

    if (Player) then
        self.OnServerEvent:Fire(Player, Payload)
    end

    debug.profileend()
end

function RemoteWrapper:_GetOrCreateNodeState(Recipient: string)
    local NodeToState = self._NodeToState
        local NodeState = NodeToState[Recipient]

    if (not NodeState) then
        local ReceivingCacheDifferencesIncrementalIndex
        local ReceivingCacheDifferences
        local CacheDifferences = {}

        local ValidCacheType = self._ValidCacheType
            local _Check = ValidCacheType._Check

        local CacheClass = self._CacheClass
            local Cache = CacheClass.new(self._CacheSize)
                local GetIndexFromValue = Cache.GetIndexFromValue
                local GetValueFromIndex = Cache.GetValueFromIndex

        local function _GetIndexFromValue(Value)
            -- Check to see if the type can be cached.
            if (_Check(ValidCacheType, Value)) then
                -- Register in cache, then in cache differences if it's the time the value has been encountered
                -- in the state of the cache. Also want to record simple refs to other attempted calls for values
                -- which were already encountered to avoid desync.
                local Index, FirstEncounter = GetIndexFromValue(Cache, Value)
                table.insert(CacheDifferences, if (FirstEncounter) then Value else Index)
                return Index
            end

            return nil
        end

        local function _GetValueFromIndex(Index)
            local Value = ReceivingCacheDifferences[ReceivingCacheDifferencesIncrementalIndex]

            if (Value) then
                Index = if (type(Value) == "number") then Value else GetIndexFromValue(Cache, Value)
                ReceivingCacheDifferencesIncrementalIndex += 1
            end

            return GetValueFromIndex(Cache, Index)
        end

        local function BeginReceive(Overwrite)
            ReceivingCacheDifferencesIncrementalIndex = 1
            ReceivingCacheDifferences = Overwrite
        end

        NodeState = {
            CacheDifferences = CacheDifferences;
            BeginReceive = BeginReceive;
            Definition = TypeGuard.ValueCache(self._Definition):PersistentCache(_GetIndexFromValue, _GetValueFromIndex);
            Cache = Cache;
        }
        NodeToState[Recipient] = NodeState
    end

    return NodeState
end

function RemoteWrapper:_SerializePackage(Data: any, Recipient: string): (buffer, {Instance})
    debug.profilebegin(`Serialize-{self._RemoteID}`)

    local SerializeType = self._SerializeType
    local NodeState = self:_GetOrCreateNodeState(Recipient)
    local Payload = NodeState.Definition:Serialize(Data, SerializeType())
    local Original = NodeState.CacheDifferences

    -- Separates out Instance values from other values and put in a separate table
    -- since only Roblox can serialize references to them. Substitutes in original
    -- table with indexes to those Instance array values.
    local CacheDifferences = Original
    local InstanceRefs = {}
    local Cloned = false

    for Index, Value in CacheDifferences do
        if (typeof(Value) ~= "Instance") then
            continue
        end

        if (not Cloned) then
            Cloned = true
            CacheDifferences = table.clone(CacheDifferences)
        end

        table.insert(InstanceRefs, Value)
        CacheDifferences[Index] = {_Ref = #InstanceRefs}
    end

    local FinalCacheDifferences = self._SerializableValidCacheType:Serialize(CacheDifferences, SerializeType(), true)
    local FinalPackage = Package:Serialize({
        CacheDifferences = FinalCacheDifferences;
        Payload = Payload;
    }, SerializeType(), true)

    table.clear(Original)
    debug.profileend()

    return FinalPackage, InstanceRefs
end

function RemoteWrapper:FireAllClients(Data: any)
    self._RemoteEvent:FireAllClients(self:_SerializePackage(Data, "*"))
end

function RemoteWrapper:FireClient(Recipient: Player, Data: any)
    self._RemoteEvent:FireClient(Recipient, self:_SerializePackage(Data, Recipient.Name))
end

function RemoteWrapper:FireServer(Data: any)
    self._RemoteEvent:FireServer(self:_SerializePackage(Data, "Server"))
end

function RemoteWrapper:Destroy()
    self._PlayerLeftConnection:Disconnect()
    self._RemoteConnection:Disconnect()
    self.OnServerEvent:DisconnectAll()
end

return RemoteWrapper
