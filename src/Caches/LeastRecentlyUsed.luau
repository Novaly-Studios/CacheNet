--!optimize 2
--!native

--- Creates a least recently used cache, where newly created or accessed values
--- are appended to the front of the queue and older, least recently used values
--- are removed from the end of the queue. Less computationally fast and more
--- memory usage than the circular cache, but better for long-life remotes which
--- have different frequencies of cacheable value occurrance.
local LRUCache = {}
LRUCache.__index = LRUCache

function LRUCache.new(MaxSize: number)
    assert(MaxSize, "No MaxSize provided")
    assert(MaxSize > 0, "MaxSize must be at least 1")

    return setmetatable({
        AvailableIndexes = {};
        ValueToNode = {};
        IndexToNode = {};
        RightMost = nil;
        LeftMost = nil;
        MaxSize = MaxSize;
        Size = 0;
    }, LRUCache)
end

function LRUCache:_RemoveNode(Node)
    local NodeRight = Node.Right
    local NodeLeft = Node.Left

    if (NodeLeft) then
        NodeLeft.Right = NodeRight
    end

    if (NodeRight) then
        NodeRight.Left = NodeLeft
    end

    if (self.LeftMost == Node) then
        self.LeftMost = NodeRight
    end

    if (self.RightMost == Node) then
        self.RightMost = NodeLeft
    end

    Node.Right = nil
    Node.Left = nil
end

function LRUCache:_InsertAtLeftMost(Node)
    local LeftMost = self.LeftMost

    Node.Left = nil
    Node.Right = LeftMost

    if (LeftMost) then
        LeftMost.Left = Node
    end

    self.LeftMost = Node

    if (not self.RightMost) then
        self.RightMost = Node
    end
end

function LRUCache:GetIndexFromValue(Value)
    local ValueToNode = self.ValueToNode
        local Node = ValueToNode[Value]

    -- Already exists, bump to left side of list (most recently used).
    if (Node) then
        self:_RemoveNode(Node)
        self:_InsertAtLeftMost(Node)
        return Node.Index, false
    end

    local AvailableIndexes = self.AvailableIndexes
    local IndexToNode = self.IndexToNode
    local Index

    if (#AvailableIndexes > 0) then
        Index = table.remove(AvailableIndexes)
    else
        Index = #IndexToNode + 1
    end

    Node = {Value = Value, Index = Index}
    ValueToNode[Value] = Node
    IndexToNode[Index] = Node
    self:_InsertAtLeftMost(Node)

    local Size = self.Size
    Size += 1

    if (Size > self.MaxSize) then
        local Evict = self.RightMost
        self:_RemoveNode(Evict)

        local EvictIndex = Evict.Index
        ValueToNode[Evict.Value] = nil
        IndexToNode[EvictIndex] = nil
        table.insert(AvailableIndexes, EvictIndex)
        Size -= 1
    end

    self.Size = Size
    return Index, true
end

function LRUCache:GetValueFromIndex(Index)
    local Node = self.IndexToNode[Index]
    return (Node and Node.Value or nil)
end

return LRUCache