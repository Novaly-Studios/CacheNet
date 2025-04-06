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

local ActivePlayers = {} do
    Players.PlayerAdded:Connect(function(Player)
        table.insert(ActivePlayers, Player)
    end)

    Players.PlayerRemoving:Connect(function(Player)
        table.remove(ActivePlayers, table.find(ActivePlayers, Player))
    end)
end

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
    TypeGuard.String():MinLength(4):MaxLength(128),
    TypeGuard.Instance()
)
local Buffer = TypeGuard.Buffer()
local Package = TypeGuard.Object({
    CacheDifferences = Buffer;
    Payload = Buffer;
}):Strict()

local RemoteWrapper = {}
RemoteWrapper.__index = RemoteWrapper
RemoteWrapper.TypeGuard = TypeGuard -- Better for the user to implement these using 
RemoteWrapper.Caches = {
    Permanent = PermanentCache;
    Circular = CircularCache;
    LRU = LRUCache;
}

type Config = {
    ValidCacheType: SignatureTypeChecker?;
    SerializeType: ("Byte" | "Bit")?;
    CacheClass: (typeof(CircularCache.new(1)) | typeof(LRUCache.new(1)))?;
    CacheSize: number?;
}

function RemoteWrapper.new(RemoteID: string, Definition: SignatureTypeChecker, Config: Config?)
    local RemoteEvent

    if (IsClient) then
        RemoteEvent = CustomRemotes:WaitForChild(RemoteID)
    else
        RemoteEvent = Instance.new("RemoteEvent")
        RemoteEvent.Name = RemoteID
        RemoteEvent.Parent = CustomRemotes
    end

    local Event = XSignal.XSignal.new()
    local ValidCacheType = (Config and Config.ValidCacheType or ValidTypeCache)

    local self = setmetatable({
        _SerializableValidCacheType = TypeGuard.Array(TypeGuard.Or(ValidCacheType, DynamicUInt, InstanceRef));
        _ValidCacheType = ValidCacheType;
        _SerializeType = (Config and Config.SerializeType or "Bit");
        _NodeToState = {};
        _RemoteEvent = RemoteEvent;
        _CacheClass = (Config and Config.CacheClass or CircularCache);
        _Definition = Definition;
        _CacheSize = (Config and Config.CacheSize or 128);
        _RemoteID = RemoteID;

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

    assert(RemoteHooks[RemoteID] == nil, `Remote ID {RemoteID} already exists`)
    RemoteHooks[RemoteID] = self
    return self
end

function RemoteWrapper:_ReceiveEvent(Data, Refs, SenderNodeState, SenderID)
    local Pair = Package:Deserialize(Data)
        local CacheDifferences = self._SerializableValidCacheType:Deserialize(Pair.CacheDifferences)
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
    Payload = SenderNodeState.Definition:Deserialize(Payload, self._SerializeType)

    if (IsClient) then
        self.OnClientEvent:Fire(Payload)
        return
    end

    local Player = Players:FindFirstChild(SenderID)

    if (Player) then
        self.OnServerEvent:Fire(Player, Payload)
    end
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
                if (type(Value) == "number") then
                    Index = Value
                else
                    Index = GetIndexFromValue(Cache, Value)
                end

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
        }
        NodeToState[Recipient] = NodeState
    end

    return NodeState
end

function RemoteWrapper:_SerializePackage(Data: any, Recipient: string): (buffer, {Instance})
    local NodeState = self:_GetOrCreateNodeState(Recipient)
    local Payload = NodeState.Definition:Serialize(Data, self._SerializeType)
    local Original = NodeState.CacheDifferences

    -- Separate out Instance values from other values and put in a separate table
    -- since only Roblox can serialize references to them. Substitute in original
    -- table with indexes to those Instance array values.
    local CacheDifferences = table.clone(Original)
    local InstanceRefs = {}

    for Index, Value in CacheDifferences do
        if (typeof(Value) == "Instance") then
            table.insert(InstanceRefs, Value)
            CacheDifferences[Index] = {_Ref = #InstanceRefs}
        end
    end

    table.clear(Original)

    return Package:Serialize({
        CacheDifferences = self._SerializableValidCacheType:Serialize(CacheDifferences);
        Payload = Payload;
    }), InstanceRefs
end

function RemoteWrapper:FireAllClients(Data: any)
    -- Potentially bad performance: has to be re-serialized with each server, client pair's cache since they will all be different.
    -- Todo: look into "*" identifier instead. Requires appending tag onto data signifying it's a FireAllClients call?
    for _, Player in ActivePlayers do
        self:FireClient(Player, Data)
    end
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
    RemoteHooks[self._RemoteID] = nil
end

return RemoteWrapper
