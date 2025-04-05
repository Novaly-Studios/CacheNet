--- Creates a circular cache, where new values are appended onto a fixed-size
--- array and then rotated around when they hit the end, overwriting old
--- values. More computationally fast and less memory intensive than the LRU
--- cache and better for short-lived common values.
local CircularCache = {}
CircularCache.__index = CircularCache

function CircularCache.new(MaxSize: number)
    assert(MaxSize, "No MaxSize provided")
    assert(MaxSize > 0, "MaxSize must be at least 1")

    return setmetatable({
        IndexToValue = {};
        ValueToIndex = {};

        RotatingIndex = 0;
        MaxSize = MaxSize;
    }, CircularCache)
end

function CircularCache:GetIndexFromValue(Value)
    local ValueToIndex = self.ValueToIndex
        local ExistingIndex = ValueToIndex[Value]

    if (ExistingIndex) then
        return ExistingIndex, false
    end

    local MaxSize = self.MaxSize
    local RotatingIndex = self.RotatingIndex
    local Index = RotatingIndex + 1
    RotatingIndex = Index % MaxSize
    self.RotatingIndex = RotatingIndex

    local IndexToValue = self.IndexToValue
    local OldValue = IndexToValue[Index]

    if (OldValue) then
        ValueToIndex[OldValue] = nil
    end

    ValueToIndex[Value] = Index
    IndexToValue[Index] = Value

    return Index, true
end

function CircularCache:GetValueFromIndex(Index)
    return self.IndexToValue[Index]
end

return CircularCache