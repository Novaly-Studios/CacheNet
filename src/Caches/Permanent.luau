--- Creates a simple value cache where every cached value persists
--- until this cache is garbage collected. Not recommended unless
--- performance is seriously necessary and there are a fixed number
--- of cacheable values.
local PermanentCache = {}
PermanentCache.__index = PermanentCache

function PermanentCache.new()
    return setmetatable({
        IndexToValue = {};
        ValueToIndex = {};
    }, PermanentCache)
end

function PermanentCache:GetIndexFromValue(Value)
    local ValueToIndex = self.ValueToIndex
        local ExistingIndex = ValueToIndex[Value]

    if (ExistingIndex) then
        return ExistingIndex, false
    end

    local IndexToValue = self.IndexToValue
    table.insert(IndexToValue, Value)

    local Index = #IndexToValue
    ValueToIndex[Value] = Index
    return Index, true
end

function PermanentCache:GetValueFromIndex(Index)
    return self.IndexToValue[Index]
end

return PermanentCache