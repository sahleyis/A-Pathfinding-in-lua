--// This is in  starterGui/TextButton/LocalScript
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local button = script.Parent

local RunPathfinderEvent = ReplicatedStorage:WaitForChild("RunPathfinderEvent")

local isRunning = false

button.MouseButton1Click:Connect(function()
	if isRunning then return end
	isRunning = true

	button.Text = "Calculating..."
	button.BackgroundColor3 = Color3.new(0.5, 0.5, 0.5)

	-- Fire the signal to the Server
	RunPathfinderEvent:FireServer()

	-- Wait for a cooldown before allowing another click to ensure everything is cleaned up
	task.wait(5)
	button.Text = "Run Pathfinding"
	button.BackgroundColor3 = Color3.new(1, 1, 1)
	isRunning = false
end)
