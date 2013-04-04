require 'nngraph'
function t1()
	local x1 = nn.Linear(20,20)()
	local x2 = nn.Linear(10,10)()
	local m0=nn.Linear(20,1)(nn.Tanh()(x1))
	local m1=nn.Linear(10,1)(nn.Tanh()(x2))
	local madd=nn.CAddTable()({m0,m1})
	local m2=nn.Sigmoid()(madd)
	local m3=nn.Tanh()(madd)
	local x = torch.rand(20)
	local y = torch.rand(10)
	gmod = nn.gModule({x1,x2},{m2,m3})
	gmod.verbose = true
	print('forward')
	gmod:updateOutput({x,y})
	print('updateGradInput')
	gmod:updateGradInput({x,y},{torch.rand(1),torch.rand(1)})
	graph.dot(gmod.fg,'forward')
	graph.dot(gmod.bg,'backward')
end

function t2()
	print('compare')
	local m0 = nn.Linear(5,10)()
	local m1 = nn.Linear(10,20)()
	local m2 = nn.Linear(30,50)(nn.JoinTable(1){m0,m1})
	gmod = nn.gModule({m0,m1},{m2})

	local nn0 = nn.Linear(5,10)
	local nn1 = nn.Linear(10,20)
	local nn2 = nn.Linear(30,50)
	local nnmod = nn.Sequential():add(nn.ParallelTable():add(nn0):add(nn1)):add(nn.JoinTable(1)):add(nn2)

	nn0.weight:copy(m0.data.module.weight)
	nn0.bias:copy(m0.data.module.bias)
	nn1.weight:copy(m1.data.module.weight)
	nn1.bias:copy(m1.data.module.bias)
	nn2.weight:copy(m2.data.module.weight)
	nn2.bias:copy(m2.data.module.bias)


	for i=1,5 do
		local x,y = torch.rand(5),torch.rand(10)
		local xx,yy = x:clone(),y:clone()

		gmod:updateOutput({x,y})
		nnmod:updateOutput({xx,yy})
		print('fdiff = ', torch.dist(gmod.output,nnmod.output))

		local odx = torch.rand(50)
		local odxx = odx:clone()

		gmod:updateGradInput({x,y},odx)
		nnmod:updateGradInput({xx,yy},odxx)
		graph.dot(gmod.fg,tostring(i))
		for i,v in ipairs(gmod.gradInput) do
			print('bdiff [' ..i..  '] = ', torch.dist(gmod.gradInput[i],nnmod.gradInput[i]))
		end
	end

	local gms = {m0,m1,m2}
	local nms = {nn0,nn1,nn2}

	for i=1,5 do
		local x,y = torch.rand(5),torch.rand(10)
		local xx,yy = x:clone(),y:clone()

		gmod:updateOutput({x,y})
		nnmod:updateOutput({xx,yy})
		print('fdiff = ', torch.dist(gmod.output,nnmod.output))

		local odx = torch.rand(50)
		local odxx = odx:clone()

		gmod:zeroGradParameters()
		nnmod:zeroGradParameters()

		gmod:updateGradInput({x,y},odx)
		nnmod:updateGradInput({xx,yy},odxx)

		gmod:accGradParameters({x,y},odx)
		nnmod:accGradParameters({xx,yy},odxx)
		graph.dot(gmod.fg)
		for i,v in ipairs(gms) do
			print('accdiff [' ..i..  '] = ', torch.dist(gms[i].data.module.gradWeight,nms[i].gradWeight))
			print('accdiff [' ..i..  '] = ', torch.dist(gms[i].data.module.gradBias,nms[i].gradBias))
		end
	end
end

function t3()
	mlp=nn.Sequential();       --Create a network that takes a Tensor as input
	mlp:add(nn.SplitTable(2))
	c=nn.ParallelTable()      --The two Tensors go through two different Linear
	c:add(nn.Linear(10,3))	   --Layers in Parallel
	c:add(nn.Linear(10,7))
	mlp:add(c)                 --Outputing a table with 2 elements
	p=nn.ParallelTable()      --These tables go through two more linear layers
	p:add(nn.Linear(3,2))	   -- separately.
	p:add(nn.Linear(7,1)) 
	mlp:add(p) 
	mlp:add(nn.JoinTable(1))   --Finally, the tables are joined together and output. 

	pred=mlp:forward(torch.randn(10,2))
	print(pred)

	for i=1,25 do             -- A few steps of training such a network.. 
		x=torch.ones(10,2);
		y=torch.Tensor(3); y:copy(x:select(2,1,1):narrow(1,1,3))
		pred=mlp:forward(x)

		criterion= nn.MSECriterion()
		local err=criterion:forward(pred,y)
		local gradCriterion = criterion:backward(pred,y);
		print(x,y)
		mlp:zeroGradParameters();
		mlp:backward(x, gradCriterion); 
		mlp:updateParameters(0.05);

		print(err)
	end
end

function topsort(a)
	-- first clone the graph
	-- local g = self:clone()
	-- local nodes = g.nodes
	-- local edges = g.edges
	-- for i,node in ipairs(nodes) do
	-- 	node.children = {}
	-- end

	-- reverse the graph
	rg,map = a:reverse()
	local rmap = {}
	for k,v in pairs(map) do
		rmap[v] = k
	end

	-- work on the sorted graph
	sortednodes = {}
	rootnodes = rg:roots()

	if #rootnodes == 0 then
		print('Graph has cycles')
	end

	-- run
	for i,root in ipairs(rootnodes) do
		root:dfs(function(node)
			print(node.id,rmap[node].id)
			-- print(rmap[node])
			table.insert(sortednodes,rmap[node]) end)
	end

	if #sortednodes ~= #a.nodes then
		print('Graph has cycles')
	end
	return sortednodes,rg,rootnodes
end


-- t2()
