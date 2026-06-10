--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingFramework = require(ReplicatedStorage:WaitForChild("A*Pathfinding"))
local RunPathfinderEvent = ReplicatedStorage:WaitForChild("RunPathfinderEvent")

-- We instantiate the core lifecycle class from the framework here on the server
local DaemonInstance = PathfindingFramework.SimulationLifecycle.new()

-- Bind the network event directly to the boot sequence so the client UI can trigger the computation
RunPathfinderEvent.OnServerEvent:Connect(function()
	DaemonInstance:BootSequence()
end)
