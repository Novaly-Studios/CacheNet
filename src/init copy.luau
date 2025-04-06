local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RunService = game:GetService("RunService")
    local IsClient = RunService:IsClient()

local Players = game:GetService("Players")

local Caches = script.Caches
    local PermanentCache = require(Caches.Permanent)
    local CircularCache = require(Caches.Circular)
    local LRUCache = require(Caches.LeastRecentlyUsed)

local TypeGuard = require(script.Parent.TypeGuard)
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

local VALID_CACHE_TYPE = TypeGuard.Or(
    TypeGuard.String():MinLength(4):MaxLength(128),
    TypeGuard.Instance()
)

local RemoteWrapper = {}
RemoteWrapper.__index = RemoteWrapper
RemoteWrapper.TypeGuard = TypeGuard -- Better for the user to implement these using 
RemoteWrapper.Caches = {
    Permanent = PermanentCache;
    Circular = CircularCache;
    LRU = LRUCache;
}

type Config = {
    SerializeType: ("Byte" | "Bit")?;
    CacheClass: (typeof(CircularCache.new(1)) | typeof(LRUCache.new(1)))?;
    CacheSize: number?;

    ValidCacheTypes: {
        [string]: ((Value: any) -> (boolean));
    }?;
}

function RemoteWrapper.new(RemoteID: string, Definition: TypeGuard.SignatureTypeChecker, Config: Config?)
    local RemoteEvent

    if (IsClient) then
        RemoteEvent = CustomRemotes:WaitForChild(RemoteID)
    else
        RemoteEvent = Instance.new("RemoteEvent")
        RemoteEvent.Name = RemoteID
        RemoteEvent.Parent = CustomRemotes
    end

    local Event = XSignal.PureXSignal.new()

    local self = setmetatable({
        _ValidCacheType = (Config and Config.ValidCacheTypes or VALID_CACHE_TYPE);
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

    self._RemoteConnection = (IsClient and RemoteEvent.OnClientEvent:Connect(function(Data, CacheDifferences)
        self:_ReceiveEvent(Data, self:_GetOrCreateNodeState("Server"), CacheDifferences)
    end) or RemoteEvent.OnServerEvent:Connect(function(Player, Data, CacheDifferences)
        local SenderID = Player.Name
        self:_ReceiveEvent(Data, self:_GetOrCreateNodeState(SenderID), CacheDifferences, SenderID)
    end))

    assert(RemoteHooks[RemoteID] == nil, `Remote ID {RemoteID} already exists`)
    RemoteHooks[RemoteID] = self
    return self
end

function RemoteWrapper:_ReceiveEvent(Data, SenderNodeState, CacheDifferences, SenderID)
    SenderNodeState.BeginReceive(CacheDifferences)
    Data = SenderNodeState.Definition:Deserialize(Data, self._SerializeType)

    if (IsClient) then
        self.OnClientEvent:Fire(Data)
        return
    end

    local Player = Players:FindFirstChild(SenderID)

    if (Player) then
        self.OnServerEvent:Fire(Player, Data)
    end
end

function RemoteWrapper:_GetOrCreateNodeState(Recipient: string)
    local NodeToState = self._NodeToState
        local NodeState = NodeToState[Recipient]

    if (not NodeState) then
        local ReceivingCacheDifferencesIncrementalIndex
        local ReceivingCacheDifferences
        local CacheDifferences = {}

        local ValidCacheTypes = self._ValidCacheTypes
        local CacheClass = self._CacheClass
            local Cache = CacheClass.new(self._CacheSize)
                local GetIndexFromValue = Cache.GetIndexFromValue
                local GetValueFromIndex = Cache.GetValueFromIndex

        local function _GetIndexFromValue(Value)
            -- Check to see if the type can be cached.
            local Type = typeof(Value)
            local Validator = ValidCacheTypes[Type]

            if (not Validator:_Check(Value)) then
                return nil
            end

            -- Register in cache, then in cache differences if it's the time the value has been encountered
            -- in the state of the cache. Also want to record simple refs to other attempted calls for values
            -- which were already encountered to avoid desync.
            local Index, FirstEncounter = GetIndexFromValue(Cache, Value)

            if (FirstEncounter) then
                table.insert(CacheDifferences, Value)
            else
                table.insert(CacheDifferences, Index)
            end

            return Index
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

function RemoteWrapper:_SerializePackage(Data: any, Recipient: string): (buffer, any)
    local NodeState = self:_GetOrCreateNodeState(Recipient)
    local Result = NodeState.Definition:Serialize(Data, self._SerializeType)
    local Original = NodeState.CacheDifferences

    -- Separate out Instance values from other values and put in a separate table
    -- since only Roblox can serialize references to them. Substitute in original
    -- table with indexes to those Instance array values.

    local CacheDifferences = table.clone(Original)
    local InstanceRefs = {}

    for Index, Value in CacheDifferences do
        if (typeof(Value) == "Instance") then
            table.insert(InstanceRefs, Index)
            CacheDifferences[Index] = #InstanceRefs
        end
    end

    table.clear(Original)
    return Result, CacheDifferences, InstanceRefs
end

function RemoteWrapper:FireAllClients(Data: any)
    -- Potentially bad performance: has to be re-serialized with each server, client pair's cache since they will all be different.
    -- Solution: implement a shared cache option between all nodes eventually, check if that's active, then it can just call the remote's FireAllClients.
    for _, Player in ActivePlayers do
        self:FireClient(Player, Data)
    end
end

function RemoteWrapper:FireClient(Recipient: Player, Data: any)
    -- local Serialized, CacheDifferences = self:_SerializePackage(Data, Recipient.Name)
    -- self._RemoteEvent:FireClient(Recipient, Serialized, CacheDifferences)
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
