--!strict
local replicatedStorage = game:GetService("ReplicatedStorage") --// Camel case for variables
local tweenService = game:GetService("TweenService")
local pathfindingFramework = {}

local CONFIG = { --// All Caps for Constants
	MAZE_CELLS_X = 12,
	MAZE_CELLS_Z = 12,
	NODE_SPACING = 4,
	GRID_HEIGHT = 1.5,
	TICK_RATE = 0.015,
	COLORS = {
		EMPTY = BrickColor.new("Medium stone grey"),
		OBSTACLE = BrickColor.new("Really black"),
		START = BrickColor.new("Lime green"),
		DESTINATION = BrickColor.new("Really red"),
		FRONTIER = BrickColor.new("Toothpaste"),
		EVALUATED = BrickColor.new("Deep blue"),
		OPTIMAL_PATH = BrickColor.new("New yeller")
	}
}

-- Custom type definition to satisfy strict mode
type Node = {
	x: number,
	z: number,
	isTraversable: boolean,
	g: number,
	h: number,
	f: number,
	parent: Node?
}

--// I implemented this binary heap class to replace standard table sorting, When dealing with hundreds of nodes, linear searches causes severe frame drops.
--// This keeps extraction time at O(log n)

local BinaryMinHeap = {}
BinaryMinHeap.__index = BinaryMinHeap

function BinaryMinHeap.new()
	return setmetatable({_data = {} :: {Node}}, BinaryMinHeap)
end

function BinaryMinHeap:Push(node: Node)
	table.insert(self._data, node)
	self:_SiftUp(#self._data)
end

function BinaryMinHeap:Pop(): Node?
	local length = #self._data
	if length == 0 then return nil end
	if length == 1 then return table.remove(self._data) end
	local root = self._data[1]
	self._data[1] = table.remove(self._data)
	self:_SiftDown(1)
	return root
end

function BinaryMinHeap:IsEmpty(): boolean
	return #self._data == 0
end

function BinaryMinHeap:_SiftUp(index: number)
	local parentIndex = math.floor(index / 2)
	while index > 1 and self:_Compare(self._data[index], self._data[parentIndex]) do
		self._data[index], self._data[parentIndex] = self._data[parentIndex], self._data[index]
		index = parentIndex
		parentIndex = math.floor(index / 2)
	end
end

function BinaryMinHeap:_SiftDown(index: number)
	local length = #self._data
	while true do
		local left = index * 2
		local right = left + 1
		local smallest = index
		if left <= length and self:_Compare(self._data[left], self._data[smallest]) then
			smallest = left
		end
		if right <= length and self:_Compare(self._data[right], self._data[smallest]) then
			smallest = right
		end
		if smallest == index then break end
		self._data[index], self._data[smallest] = self._data[smallest], self._data[index]
		index = smallest
	end
end

function BinaryMinHeap:_Compare(nodeA: Node, nodeB: Node): boolean
	if nodeA.f == nodeB.f then
		return nodeA.h < nodeB.h
	end
	return nodeA.f < nodeB.f
end

--// This class builds the procedural matrix. I designed it to carve through solid blocks using depth-first recursion so that we never generate an unsolvable layout or isolated topological pockets.

local TopologicalBacktracker = {}
TopologicalBacktracker.__index = TopologicalBacktracker

function TopologicalBacktracker.new(cellsX: number, cellsZ: number)
	local self = setmetatable({}, TopologicalBacktracker)
	self.cellsX = cellsX
	self.cellsZ = cellsZ
	self.width = (cellsX * 2) + 1
	self.depth = (cellsZ * 2) + 1
	self.matrix = {} :: {{number}}
	return self
end

function TopologicalBacktracker:ConstructMatrix(): {{number}}
	for x = 1, self.width do
		self.matrix[x] = {}
		for z = 1, self.depth do
			self.matrix[x][z] = 1
		end
	end
	local visited = {} :: {{boolean}}
	for x = 1, self.cellsX do
		visited[x] = {}
		for z = 1, self.cellsZ do
			visited[x][z] = false
		end
	end
	local originX, originZ = 1, 1
	visited[originX][originZ] = true
	local stack = {}
	table.insert(stack, {x = originX, z = originZ})
	self.matrix[originX * 2][originZ * 2] = 0 

	while #stack > 0 do
		local current = stack[#stack]
		local unvisitedNeighbors = self:_GatherValidVectors(current.x, current.z, visited)

		if #unvisitedNeighbors > 0 then
			local nextVector = unvisitedNeighbors[math.random(1, #unvisitedNeighbors)]
			local wallCarveX = (current.x * 2) + (nextVector.dx / 2)
			local wallCarveZ = (current.z * 2) + (nextVector.dz / 2)
			local targetX = nextVector.nx * 2
			local targetZ = nextVector.nz * 2

			self.matrix[wallCarveX][wallCarveZ] = 0
			self.matrix[targetX][targetZ] = 0
			visited[nextVector.nx][nextVector.nz] = true
			table.insert(stack, {x = nextVector.nx, z = nextVector.nz})
		else
			table.remove(stack)
		end
	end
	self.matrix[2][2] = 0 
	self.matrix[self.width - 1][self.depth - 1] = 0
	return self.matrix
end

type VectorInfo = {dx: number, dz: number, nx: number, nz: number}

function TopologicalBacktracker:_GatherValidVectors(cx: number, cz: number, visitedMap: {{boolean}}): {VectorInfo}
	local valid = {}
	local vectors = {
		{dx = 0, dz = -2, nx = cx, nz = cz - 1},
		{dx = 0, dz = 2, nx = cx, nz = cz + 1},
		{dx = -2, dz = 0, nx = cx - 1, nz = cz},
		{dx = 2, dz = 0, nx = cx + 1, nz = cz}
	}
	for _, v in ipairs(vectors) do
		if v.nx > 0 and v.nx <= self.cellsX and v.nz > 0 and v.nz <= self.cellsZ then
			if not visitedMap[v.nx][v.nz] then
				table.insert(valid, v)
			end
		end
	end
	return valid
end

--// The core mathematical routing class. I abstracted this away from the rendering logic so you could hypothetically run this exact math on headless servers without needing physical Workspace parts.

local AStarHeuristicEngine = {}
AStarHeuristicEngine.__index = AStarHeuristicEngine

function AStarHeuristicEngine.new(topologyMatrix: {{number}})
	local self = setmetatable({}, AStarHeuristicEngine)
	self.matrix = topologyMatrix
	self.boundsX = #topologyMatrix
	self.boundsZ = #topologyMatrix[1]
	self.graph = {} :: {{Node}}
	for x = 1, self.boundsX do
		self.graph[x] = {}
		for z = 1, self.boundsZ do
			self.graph[x][z] = {
				x = x, z = z,
				isTraversable = (topologyMatrix[x][z] == 0),
				g = math.huge, h = 0, f = math.huge,
				parent = nil
			}
		end
	end
	return self
end

function AStarHeuristicEngine:ComputeOptimalPath(startVector: Vector2, endVector: Vector2): ({Node}?, {Node}, {Node})
	local originNode = self.graph[startVector.X][startVector.Y]
	local destinationNode = self.graph[endVector.X][endVector.Y]
	originNode.g = 0
	originNode.f = 0

	local openQueue = BinaryMinHeap.new()
	openQueue:Push(originNode)

	local closedSetLookup = {} :: {[string]: boolean}
	local evaluatedHistory = {} :: {Node}
	local frontierLeftovers = {} :: {Node}

	while not openQueue:IsEmpty() do
		local currentNode = openQueue:Pop()
		if not currentNode then break end

		local nodeKey = currentNode.x .. "_" .. currentNode.z
		if closedSetLookup[nodeKey] then continue end
		closedSetLookup[nodeKey] = true
		table.insert(evaluatedHistory, currentNode)

		if currentNode.x == destinationNode.x and currentNode.z == destinationNode.z then
			for _, leftover in ipairs(openQueue._data) do
				table.insert(frontierLeftovers, leftover)
			end
			return self:_ReconstructTraces(originNode, currentNode), frontierLeftovers, evaluatedHistory
		end

		local orthogonalNeighbors = self:_GetOrthogonalNeighbors(currentNode)
		for _, neighbor in ipairs(orthogonalNeighbors) do
			local neighborKey = neighbor.x .. "_" .. neighbor.z
			if closedSetLookup[neighborKey] then continue end

			local tentativeGCost = currentNode.g + 1 
			if tentativeGCost < neighbor.g then
				neighbor.g = tentativeGCost
				neighbor.h = self:_CalculateManhattanDistance(neighbor, destinationNode)
				neighbor.f = neighbor.g + neighbor.h
				neighbor.parent = currentNode
				openQueue:Push(neighbor)
			end
		end
	end
	return nil, openQueue._data, evaluatedHistory
end

function AStarHeuristicEngine:_GetOrthogonalNeighbors(node: Node): {Node}
	local validNeighbors = {}
	local offsets = { {x = 0, z = -1}, {x = 0, z = 1}, {x = -1, z = 0}, {x = 1, z = 0} }
	for _, offset in ipairs(offsets) do
		local nx = node.x + offset.x
		local nz = node.z + offset.z
		if nx >= 1 and nx <= self.boundsX and nz >= 1 and nz <= self.boundsZ then
			local neighbor = self.graph[nx][nz]
			if neighbor.isTraversable then
				table.insert(validNeighbors, neighbor)
			end
		end
	end
	return validNeighbors
end

function AStarHeuristicEngine:_CalculateManhattanDistance(nodeA: Node, nodeB: Node): number
	return math.abs(nodeA.x - nodeB.x) + math.abs(nodeA.z - nodeB.z)
end

function AStarHeuristicEngine:_ReconstructTraces(startNode: Node, endNode: Node): {Node}
	local sequence = {}
	local current: Node? = endNode
	while current and current ~= startNode do
		table.insert(sequence, 1, current)
		current = current.parent
	end
	table.insert(sequence, 1, startNode)
	return sequence
end

--// I built this class strictly for workspace manipulation. It handles garbage collection automatically via SanitizeWorkspace so we never get memory leaks or Z-fighting ghost blocks.

local ViewportRenderer = {}
ViewportRenderer.__index = ViewportRenderer

function ViewportRenderer.new()
	local self = setmetatable({}, ViewportRenderer)
	self.geometryCache = {} :: {{Part}}
	self:SanitizeWorkspace()
	self.animator = TweenInfo.new(0.15, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	return self
end

function ViewportRenderer:SanitizeWorkspace()
	local legacyContainer = workspace:FindFirstChild("AStar_Container")
	if legacyContainer then legacyContainer:Destroy() end
	self.container = Instance.new("Folder")
	self.container.Name = "AStar_Container"
	self.container.Parent = workspace
	self.geometryCache = {}
end

function ViewportRenderer:ExtrudeTopology(matrix: {{number}}, originVec: Vector2, targetVec: Vector2)
	self:SanitizeWorkspace()
	for x = 1, #matrix do
		self.geometryCache[x] = {}
		for z = 1, #matrix[1] do
			local isSolid = matrix[x][z] == 1
			local block = Instance.new("Part")
			block.Size = Vector3.new(CONFIG.NODE_SPACING - 0.2, CONFIG.GRID_HEIGHT, CONFIG.NODE_SPACING - 0.2)
			block.Position = Vector3.new(x * CONFIG.NODE_SPACING, 0, z * CONFIG.NODE_SPACING)
			block.Anchored = true
			block.Material = Enum.Material.SmoothPlastic
			block.Parent = self.container
			if x == originVec.X and z == originVec.Y then
				block.BrickColor = CONFIG.COLORS.START
			elseif x == targetVec.X and z == targetVec.Y then
				block.BrickColor = CONFIG.COLORS.DESTINATION
			elseif isSolid then
				block.BrickColor = CONFIG.COLORS.OBSTACLE
				block.Size = Vector3.new(CONFIG.NODE_SPACING, CONFIG.GRID_HEIGHT * 3, CONFIG.NODE_SPACING)
				block.Position += Vector3.new(0, CONFIG.GRID_HEIGHT, 0)
			else
				block.BrickColor = CONFIG.COLORS.EMPTY
			end
			self.geometryCache[x][z] = block
		end
		if x % 3 == 0 then task.wait() end
	end
end

function ViewportRenderer:PaintCoordinate(x: number, z: number, targetColor: BrickColor)
	local block = self.geometryCache[x] and self.geometryCache[x][z]
	if block then
		block.BrickColor = targetColor
	end
end

function ViewportRenderer:AnimatePathNode(x: number, z: number, targetColor: BrickColor)
	local block = self.geometryCache[x] and self.geometryCache[x][z]
	if block then
		block.BrickColor = targetColor
		local elevatedPos = block.Position + Vector3.new(0, 1.25, 0)
		local tween = tweenService:Create(block, self.animator, {Position = elevatedPos})
		tween:Play()
	end
end

--// The lifecycle manager orchestrates everything above. We expose this out of the module so your ServerScript just has to call one boot sequence function.

local SimulationLifecycle = {}
SimulationLifecycle.__index = SimulationLifecycle

function SimulationLifecycle.new()
	local self = setmetatable({}, SimulationLifecycle)
	self.renderer = ViewportRenderer.new()
	self.isComputing = false
	return self
end

function SimulationLifecycle:BootSequence()
	if self.isComputing then return end
	self.isComputing = true

	local backtracker = TopologicalBacktracker.new(CONFIG.MAZE_CELLS_X, CONFIG.MAZE_CELLS_Z)
	local rawMatrix = backtracker:ConstructMatrix()
	local originVec = Vector2.new(2, 2)
	local destinationVec = Vector2.new(backtracker.width - 1, backtracker.depth - 1)

	self.renderer:ExtrudeTopology(rawMatrix, originVec, destinationVec)
	task.wait(0.5)

	local engine = AStarHeuristicEngine.new(rawMatrix)
	local optimalSequence, frontierQueue, evaluatedNodes = engine:ComputeOptimalPath(originVec, destinationVec)
	self:_BroadcastSimulation(evaluatedNodes, frontierQueue, optimalSequence, originVec, destinationVec)

	self.isComputing = false
end

function SimulationLifecycle:_BroadcastSimulation(evaluated: {Node}, frontier: {Node}, pathSequence: {Node}?, startV: Vector2, endV: Vector2)
	for _, node in ipairs(evaluated) do
		if self:_IsProtectVector(node.x, node.z, startV, endV) then continue end
		self.renderer:PaintCoordinate(node.x, node.z, CONFIG.COLORS.EVALUATED)
		task.wait(CONFIG.TICK_RATE)
	end
	for _, node in ipairs(frontier) do
		if self:_IsProtectVector(node.x, node.z, startV, endV) then continue end
		self.renderer:PaintCoordinate(node.x, node.z, CONFIG.COLORS.FRONTIER)
	end
	if pathSequence then
		task.wait(0.2)
		for _, node in ipairs(pathSequence) do
			if self:_IsProtectVector(node.x, node.z, startV, endV) then continue end
			self.renderer:AnimatePathNode(node.x, node.z, CONFIG.COLORS.OPTIMAL_PATH)
			task.wait(CONFIG.TICK_RATE * 2)
		end
		task.wait(1) 
		for _, node in ipairs(evaluated) do
			if not self:_IsProtectVector(node.x, node.z, startV, endV) and not self:_IsPathNode(node.x, node.z, pathSequence) then
				self.renderer:PaintCoordinate(node.x, node.z, CONFIG.COLORS.EMPTY)
			end
		end
		for _, node in ipairs(frontier) do
			if not self:_IsProtectVector(node.x, node.z, startV, endV) and not self:_IsPathNode(node.x, node.z, pathSequence) then
				self.renderer:PaintCoordinate(node.x, node.z, CONFIG.COLORS.EMPTY)
			end
		end
	end
end

function SimulationLifecycle:_IsProtectVector(x: number, z: number, startV: Vector2, endV: Vector2): boolean
	return (x == startV.X and z == startV.Y) or (x == endV.X and z == endV.Y)
end

function SimulationLifecycle:_IsPathNode(x: number, z: number, pathSequence: {Node}): boolean
	for _, node in ipairs(pathSequence) do
		if node.x == x and node.z == z then return true end
	end
	return false
end

-- Expose the lifecycle class to the public API
pathfindingFramework.SimulationLifecycle = SimulationLifecycle
return pathfindingFramework
