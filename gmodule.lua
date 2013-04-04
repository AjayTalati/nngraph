
local function istable(x)
	return type(x) == 'table' and not torch.typename(x)
end

local gModule, parent = torch.class('nn.gModule','nn.Module')

function gModule:__init(inputs,outputs)
	parent.__init(self)
	-- the graph is defined backwards, we have the output modules as input here
	-- we will define a dummy output node that connects all output modules
	-- into itself. This will be the output for the forward graph and
	-- input point for the backward graph
	local outnode = nngraph.Node({input={}})
	for i,n in ipairs(outputs) do
		outnode:add(n,true)
	end
	local innode = nngraph.Node({data={},gradOutput={}})
	for i,n in ipairs(inputs) do
		n:add(innode,true)
		-- fix the mapindex for the input data node
		table.insert(innode.data.mapindex,n.data)
		innode.data.mapindex[n.data] = #innode.data.mapindex
	end

	-- the backward graph (bg) is for gradients
	-- the forward graph (fg) is for function evaluation
	self.bg = outnode:graph()
	self.fg = self.bg:reverse()

	-- the complete graph is constructed
	-- now regenerate the graphs with the additional nodes
	self.innode = self.fg:roots()[1]
	self.outnode = outnode
	self.verbose = false

	-- computation on the graph is done through topsort of forward and backward graphs
	self.forwardnodes = self.fg:topsort()
	self.backwardnodes = self.bg:topsort()

	self.output = self.outnode.data.input
	self.gradInput = self.innode.data.gradOutput

	if #outputs > 1 then
		self.output = {}
		for i,node in ipairs(outputs) do
			table.insert(self.output,node.data.module and node.data.module.output or node.data.input)
		end
	else
		local node = outputs[1]
		self.output = node.data.module and node.data.module.output or node.data.input
	end

	if #inputs > 1 then
		self.gradInput = {}
		for i,node in ipairs(inputs) do
			table.insert(self.gradInput,node.data.module and node.data.module.gradInput or nil)
		end
	else
		local node = inputs[1]
		self.gradInput = node.data.module and node.data.module.gradInput or self.innode.data.gradOutput
	end
end

function gModule:updateOutput(input)
	-- we will assume that the input is either a table of stuff
	-- if not we will put it in a table of stuff
	if torch.typename(input) or type(input) ~= 'table' then
		input={input}
	end
	local function neteval(node)
		local function propagate(node,x)
			for i,child in ipairs(node.children) do
				child.data.input = child.data.input or {}
				local mapindex = child.data.mapindex[node.data]
				child.data.input[mapindex] = x
			end
		end
		if node.data.data then
			-- then this is a data node, just propagate into
			-- its children
			-- this is different from a regular data node
			-- the input is expected to be a table of things
			-- where each thing goes into the input of 
			-- corresponding children. So this is like a
			-- dispatcher
			-- the mapindex in a data node indexes the child data 
			-- so that this node can distribute its data to corresponding inputs
			for i,child in ipairs(node.children) do
				local mapindex = node.data.mapindex[child.data]
				if child.data.input then
					table.insert(child.data.input,node.data.data[mapindex])
				else
					child.data.input = {node.data.data[mapindex]}
				end
			end
		elseif not node.data.module and not node.data.criterion and node.data.input then
			-- then this is a data node, just propagate into
			-- its children
			local input = #node.data.input == 1 and node.data.input[1] or node.data.input
			propagate(node,input)
		elseif node.data.module then
			local module = node.data.module
			local input = node.data.input
			if #input == 1 then
				input = input[1]
			end
			-- forward through this node
			local output = module:updateOutput(input)
			-- propagate the output to children
			propagate(node,output)
		elseif node.data.criterion then
			local module = node.data.criterion
			local input = node.data.input
			-- forward through this node
			local output = module:updateOutput(unpack(input))
			-- propagate the output to children
			propagate(node,output)
		else
			if self.verbose then
				print('weird node, skipping :)')
				print(node.data)
			end
		end
		if self.verbose then
			print(' V : ' .. node:label())
		end
	end

	-- set the data field to current input
	local innode = self.innode
	innode.data.data=input
	if #input ~= #innode.data.mapindex then
		print('#inputs      =' .. #input)
		print('#mapindices  =' .. #innode.data.data)
		error('Number of inputs do not match my graph')
	end
	-- first clear the input states
	innode:bfs(function(node)
		local input = node.data.input
		while input and #input>0 do
			table.remove(input)
		end
	end)

	-- the run forward
	for i,node in ipairs(self.forwardnodes) do
		neteval(node)
	end
	-- innode:bfs(neteval)

	-- everything is done, so now I can collect the results
	-- that are stored in outnode.input
	-- local outputs = self.outnode.data.input
	-- self.output = #outputs == 1 and outputs[1] or outputs
	return self.output
end

function gModule:updateGradInput(input,gradOutput)
	-- we will assume that the input is either a table of stuff
	-- if not we will put it in a table of stuff
	if torch.typename(gradOutput) or type(gradOutput) ~= 'table' then
		gradOutput={gradOutput}
	end
	local outputs = {}
	local function neteval(node)
		local function propagate(node,x)
			for i,child in ipairs(node.children) do
				child.data.gradOutput = child.data.gradOutput or {}
				local mapindex = node.data.mapindex[child.data]
				table.insert(child.data.gradOutput,x[mapindex])
			end
		end
		if node.data.data then
			-- then this is a data node, just propagate into
			-- its children
			-- this is different from a regular data node
			-- the input is expected to be a table of things
			-- where each thing goes into the input of 
			-- corresponding children. So this is like a
			-- dispatcher
			for i,child in ipairs(node.children) do
				child.data.gradOutput = child.data.gradOutput or {}
				local mapindex = node.data.mapindex[child.data]
				table.insert(child.data.gradOutput,node.data.data[mapindex])
			end
		elseif not node.data.module and node.data.gradOutput then
			-- then this is a data node, just propagate into
			-- its children
			for i,child in ipairs(node.children) do
				child.data.gradOutput = child.data.gradOutput or {}
				local mapindex = node.data.mapindex[child.data]
				child.data.gradOutput[mapindex] = node.data.gradOutput
			end
		elseif node.data.module then
			local module = node.data.module
			local gradOutput = node.data.gradOutput
			local input = node.data.input
			if #input == 1 then
				input = input[1]
			end
			-- updateGradInput through this node
			if istable(gradOutput) and not istable(module.output) then
				for i=2,#gradOutput do
					gradOutput[1]:add(gradOutput[i])
				end
				gradOutput = gradOutput[1]
			end
			local gradInput = module:updateGradInput(input,gradOutput)
			-- propagate the output to children
			for i,child in ipairs(node.children) do
				child.data.gradOutput = child.data.gradOutput or {}
				local mapindex = node.data.mapindex[child.data]
				local gi
				if istable(gradInput) and istable(input) then
					gi = gradInput[mapindex]
				else
					gi = gradInput
				end
				table.insert(child.data.gradOutput,gi)
			end
		else
			if self.verbose then
				print('weird node, skipping :)')
				print(node.data)
			end
		end
		if self.verbose then
			print(' V : ' .. node:label())
		end
	end
	local outnode = self.outnode
	outnode.data.data=gradOutput
	if #gradOutput ~= #outnode.children then
		print('#outputs   =' .. #outnode.children)
		print('#gradients =' .. #gradOutput)
		error('Number of gradients do not match my graph')
	end
	outnode:bfs(function(node)
		local gradOutput = node.data.gradOutput
		while gradOutput and #gradOutput >0 do
			table.remove(gradOutput)
		end
	end)
	for i,node in ipairs(self.backwardnodes) do
		neteval(node)
	end
	return self.gradInput
end

function gModule:accGradParameters(input,gradOutput,lr)
	-- we will assume that the input is either a table of stuff
	-- if not we will put it in a table of stuff
	if torch.typename(gradOutput) or type(gradOutput) ~= 'table' then
		gradOutput={gradOutput}
	end
	local outputs = {}
	local function neteval(node)
		if node.data.data then
		elseif not node.data.module and node.data.gradOutput then
		elseif node.data.module then
			local module = node.data.module
			local gradOutput = node.data.gradOutput
			local input = node.data.input
			if #input == 1 then
				input = input[1]
			end
			-- accGradParameters through this node
			if istable(gradOutput) and not istable(module.output) then
				for i=2,#gradOutput do
					gradOutput[1]:add(gradOutput[i])
				end
				gradOutput = gradOutput[1]
			end
			module:accGradParameters(input,gradOutput,lr)
		else
			if self.verbose then
				print('weird node, skipping :)')
				print(node.data)
			end
		end
		if self.verbose then
			print(' V : ' .. node:label())
		end
	end
	local outnode = self.outnode
	outnode.data.data=gradOutput
	if #gradOutput ~= #outnode.children then
		print('#outputs   =' .. #outnode.children)
		print('#gradients =' .. #gradOutput)
		error('Number of gradients do not match my graph')
	end
	for i,node in ipairs(self.backwardnodes) do
		neteval(node)
	end
end

function gModule:parameters()
	local p,gp = {},{}
	local innode = self.innode
	innode:bfs(function(node)
		if not node.data.module then
			return
		end

		local mp,mgp = node.data.module:parameters()
		if not mp or not mgp then return end
		for i = 1,#mp do
			table.insert(p,mp[i])
			table.insert(gp,mgp[i])
		end
	end)
	return p,gp
end
