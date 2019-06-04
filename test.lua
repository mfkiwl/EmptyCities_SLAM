-- usage: DATA_ROOT=/path/to/data/ th test.lua
-- usage: input=/path/to/input/image/ mask=/path/to/mask/ output=/path/to/output/ th test.lua
--
-- code derived from https://github.com/soumith/dcgan.torch
--

require 'image'
require 'nn'
require 'nngraph'
util = paths.dofile('util/util.lua')
torch.setdefaulttensortype('torch.FloatTensor')

opt = {
	DATA_ROOT = '',             -- path to images (should have subfolders 'train', 'val', etc)
	input = '',                 -- path to input image
	mask = '',					-- path to mask input image
	output =  '',				-- path to save output image
	target = '',
	mask_output = 'mask_output.png',	-- path to mask output image
	data_aug = 0,
	batchSize = 1,              -- # images in batch
	loadSizeH = 256,--550,--550,--256,             -- scale images to this size
	loadSizeW = 768,--1100,--550,--768,
	fineSizeH = 256,--512,--256,             --  then crop to this size
	fineSizeW = 768,--512,--768,
	display = 1,                -- display samples while training. 0 = false
	display_id = 200,           -- display window id.
	gpu = 1,                    -- gpu = 0 is CPU mode. gpu=X is GPU mode on GPU X
	phase = 'test',              -- train, val, test ,etc
	aspect_ratio = 1.0,         -- aspect ratio of result images
	name = 'mGAN',              -- name of experiment, selects which model to run, should generally should be passed on command line
	input_nc = 3,               -- #  of input image channels
	output_nc = 3,              -- #  of output image channels
	input_gan_nc = 1,			-- #  of GAN generator input image channels
	output_gan_nc = 1;			-- #  of GAN generator output image channels
	mask_nc = 1,				-- #  of mask channels
	serial_batches = 1,         -- if 1, takes images in order to make batches, otherwise takes them randomly
	serial_batch_iter = 1,      -- iter into serial image list
	cudnn = 1,                  -- set to 0 to not use cudnn (untested)
	checkpoints_dir = './checkpoints',  -- loads models from here
	results_dir='./results/',   -- saves results here
	which_epoch = 'latest',     -- which epoch to test? set to 'latest' to use latest cached model
	condition_mG = 1,
	netSS_name = 'SemSeg/erfnet.net'
}

-- one-line argument parser. parses enviroment variables to override the defaults
for k,v in pairs(opt) do opt[k] = tonumber(os.getenv(k)) or os.getenv(k) or opt[k] end
opt.nThreads = 1 -- test only works with 1 thread...
print(opt)
if opt.display == 0 then opt.display = false end

opt.manualSeed = torch.random(1, 10000) -- set seed
print("Random Seed: " .. opt.manualSeed)
torch.manualSeed(opt.manualSeed)
torch.setdefaulttensortype('torch.FloatTensor')

opt.netG_name = opt.name .. '/' .. opt.which_epoch .. '_net_G'
local netSS_name = opt.netSS_name

-- useful function for debugging
function pause ()
	print("Press any key to continue.")
	io.flush()
	io.read()
end

if opt.DATA_ROOT ~= '' then
	data_loader = paths.dofile('data/data.lua')
	print('#threads...' .. opt.nThreads)
	data = data_loader.new(opt.nThreads, opt)
	print("Dataset Size: ", data:size())
end

-- index different inputs
local idx_A = nil
local input_nc = opt.input_nc
local output_nc = opt.output_nc
local input_gan_nc = opt.input_gan_nc
local output_gan_nc = opt.output_gan_nc
idx_A = {1, input_nc}

----------------------------------------------------------------------------

local inputRGB = torch.FloatTensor(opt.batchSize, opt.input_nc, opt.fineSizeH, opt.fineSizeW)
if opt.target ~= '' then
	targetRGB = torch.FloatTensor(opt.batchSize, opt.output_nc, opt.fineSizeH, opt.fineSizeW)
end
if opt.mask ~= '' then
	inputMask = torch.FloatTensor(opt.batchSize, opt.mask_nc, opt.fineSizeH, opt.fineSizeW)
end

-- load all models
print('checkpoints_dir', opt.checkpoints_dir)
local netG = util.load(paths.concat(opt.checkpoints_dir, opt.netG_name .. '.t7'), opt)
netG:evaluate()
print(netG)
if opt.mask == '' then
	netSS = torch.load(paths.concat(opt.checkpoints_dir, netSS_name))
	netSS:evaluate()
	netDynSS = nn.Sequential()
	local convDyn = nn.SpatialFullConvolution(20,1,1,1,1,1)
	convDyn.weight[{{1,12},1,1,1}] = -8/20 -- Static
	convDyn.weight[{{13,20},1,1,1}] = 12/20 -- Dynamic
	convDyn.bias:zero()
	netDynSS:add(nn.SoftMax())
	netDynSS:add(convDyn)
	--netDynSS:add(nn.Tanh())
	netDynSS = netDynSS:cuda()
	print(netDynSS)
end

-- this function will be used later for the website
function TableConcat(t1,t2)
	for i=1,#t2 do
		t1[#t1+1] = t2[i]
	end
	return t1
end


local function loadImage(path,bin)

	local sampleSizeH = {input_nc, opt.fineSizeH}
	local sampleSizeW = {input_nc, opt.fineSizeW}
	local loadSizeH   = {input_nc, opt.loadSizeH}
	local loadSizeW   = {input_nc, opt.loadSizeW}
	local oW = sampleSizeW[2]
	local oH = sampleSizeH[2]

	if bin == 1 then
		im = image.load(path, 1, 'float')
		im = im:resize(1,im:size(1),im:size(2))
	else
		im = image.load(path, 3, 'float')
	end

	im = image.scale(im, loadSizeW[2], loadSizeH[2])
	if bin == 1 then
		im = im:resize(1,im:size(2),im:size(3))
		im[im:gt(0)] = 1
	end

	local iH = im:size(2)
	local iW = im:size(3)

	if iH~=oH then     
		h1 = math.ceil(torch.uniform(1e-2, iH-oH))
	end 
	if iW~=oW then
		w1 = math.ceil(torch.uniform(1e-2, iW-oW))
	end
	
	if iH ~= oH or iW ~= oW then 
		im = image.crop(im, w1, h1, w1 + oW, h1 + oH)
	end

	im = im:mul(2):add(-1)

  	assert(im:max()<=1,"input: badly scaled inputs")
  	assert(im:min()>=-1,"input: badly scaled inputs")
  	
	if opt.gpu > 0 then
		im = im:cuda()
	end
	
	im = im:resize(1,im:size(1),im:size(2),im:size(3))

	return im
end

local gen_tm = torch.Timer()
local ss_tm = torch.Timer()
local dynss_tm = torch.Timer()
local filepaths = {} -- paths to images tested on

if opt.DATA_ROOT ~= '' then
	local lGenTime = {}
	local lSSTime = {}
	local lDynSSTime = {}
	for n=1,math.floor(data:size()/opt.batchSize) do
		print('processing batch ' .. n)
		
		local data_curr, filepaths_curr = data:getBatch()
		filepaths_curr = util.basename_batch(filepaths_curr)
		print('filepaths_curr: ', filepaths_curr)
		
		inputRGB = data_curr[{ {}, idx_A, {}, {} }]

		if input_gan_nc == 1 then
			inputGray = util.rgb2gray_batch(inputRGB)
		else
			inputGray = inputRGB
		end

		if opt.gpu > 0 then
			inputRGB = inputRGB:cuda()
			inputGray = inputGray:cuda()
		end
		
		if opt.condition_mG == 1 then
			if opt.mask == '' then
				inputBGR = inputRGB:clone()
				inputBGR = inputBGR:add(1):mul(0.5)
				inputBGR[1][1] = inputRGB[1][3]:clone():add(1):mul(0.5)
				inputBGR[1][3] = inputRGB[1][1]:clone():add(1):mul(0.5)
				ss_tm:reset()
				inputMask = netSS:forward(inputBGR)
				table.insert(lSSTime, ss_tm:time().real)
				dynss_tm:reset()
				inputMask = netDynSS:forward(inputMask)
				inputMask[inputMask:ge(0)] = 1
				inputMask[inputMask:lt(0)] = -1
				table.insert(lDynSSTime, dynss_tm:time().real)
			else
				if opt.target == '' then
					idx_C = {input_nc + 1,input_nc + 1}
				else
					idx_C = {input_nc + output_nc + 1,input_nc + output_nc + 1}
				end
				inputMask = data_curr[{ {}, idx_C, {}, {} }]
				if opt.gpu == 1 then
					inputMask = inputMask:cuda()
				end
			end
			inputGAN = torch.cat(inputGray,inputMask,2)
		else
			inputGAN = inputGray
		end

		if opt.target ~= '' then
			idx_B = {input_nc + 1, input_nc + output_nc}
			targetRGB = data_curr[{ {}, idx_B, {}, {} }]
			if output_gan_nc == 1 then 
				targetGray = util.rgb2gray_batch(targetRGB)
				targetGray = targetGray:add(1):div(2):float()
			else
				targetGray = targetRGB
				targetGray = util.deprocess_batch(targetGray):float()
			end
		end

		if output_gan_nc == 3 then
			output = util.deprocess_batch(netG:forward(inputGAN)):float()
		else
			gen_tm:reset()
			output = netG:forward(inputGAN)
			table.insert(lGenTime, gen_tm:time().real)
			output = output:add(1):div(2):float()
		end
		if input_gan_nc == 3 then
			inputGray = util.deprocess_batch(inputGray):float()
		else
			inputGray = inputGray:add(1):div(2):float()
		end
		

		paths.mkdir(paths.concat(opt.results_dir, opt.netG_name .. '_' .. opt.phase))
		local image_dir = paths.concat(opt.results_dir, opt.netG_name .. '_' .. opt.phase, 'images')
		paths.mkdir(image_dir)
		paths.mkdir(paths.concat(image_dir,'input'))
		paths.mkdir(paths.concat(image_dir,'output'))
		if opt.target ~= '' then
			paths.mkdir(paths.concat(image_dir,'target'))
		end
		paths.mkdir(paths.concat(image_dir,'mask'))

		for i=1, opt.batchSize do
			image.save(paths.concat(image_dir,'input',filepaths_curr[i]), image.scale(inputGray[i],inputGray[i]:size(3),inputGray[i]:size(2)/opt.aspect_ratio))
			image.save(paths.concat(image_dir,'output',filepaths_curr[i]), image.scale(output[i],output[i]:size(3),output[i]:size(2)/opt.aspect_ratio))
			image.save(paths.concat(image_dir,'mask',filepaths_curr[i]), image.scale(inputMask[i]:float(),inputMask[i]:size(3),inputMask[i]:size(2)/opt.aspect_ratio))

		end
		if opt.target ~= '' then
			for i=1, opt.batchSize do
				image.save(paths.concat(image_dir,'target',filepaths_curr[i]), image.scale(targetGray[i],targetGray[i]:size(3),targetGray[i]:size(2)/opt.aspect_ratio))
			end
		end

		print('Saved images to: ', image_dir)

		filepaths = TableConcat(filepaths, filepaths_curr)

		if opt.display then
			disp = require 'display'
			disp.image(util.scaleBatch(inputGray,100,100),{win=opt.display_id, title='input'})
			disp.image(util.scaleBatch(output,100,100),{win=opt.display_id+1, title='output'})
			if opt.target ~= '' then
				disp.image(util.scaleBatch(targetGray,100,100),{win=opt.display_id+2, title='target'})
			end
			print('Displayed images')
		end
		
		filepaths = TableConcat(filepaths, filepaths_curr)
	end

	print("Generator Median Time: ", torch.Tensor(lGenTime):median()[1])
	print("Semantic Segmentation Median Time: ", torch.Tensor(lSSTime):median()[1])
	print("Dynamic Semantic Segmentation Median Time: ", torch.Tensor(lDynSSTime):median()[1])

	-- make webpage
	io.output(paths.concat(opt.results_dir,opt.netG_name .. '_' .. opt.phase, 'index.html'))
	io.write('<table style="text-align:center;">')
	if opt.target ~= '' then
		io.write('<tr><td>Image #</td><td>Input</td><td>Output</td><td>Ground Truth</td></tr>')
		for i=1, #filepaths do
			io.write('<tr>')
			io.write('<td>' .. filepaths[i] .. '</td>')
			io.write('<td><img src="./images/input/' .. filepaths[i] .. '"/></td>')
			io.write('<td><img src="./images/output/' .. filepaths[i] .. '"/></td>')
			io.write('<td><img src="./images/target/' .. filepaths[i] .. '"/></td>')
			io.write('</tr>')
		end
	else
		io.write('<tr><td>Image #</td><td>Input</td><td>Output</td></tr>')
		for i=1, #filepaths do
			io.write('<tr>')
			io.write('<td>' .. filepaths[i] .. '</td>')
			io.write('<td><img src="./images/input/' .. filepaths[i] .. '"/></td>')
			io.write('<td><img src="./images/output/' .. filepaths[i] .. '"/></td>')
			io.write('</tr>')
		end
	end
	io.write('</table>')
	
else
	inputRGB = loadImage(opt.input,0)
	if opt.mask ~= '' then
		inputMask = loadImage(opt.mask,1)
	else
		local inputBGR = inputRGB:clone()
		inputBGR = inputBGR:add(1):mul(0.5)
		inputBGR[1][1] = inputRGB[1][3]:clone():add(1):mul(0.5)
		inputBGR[1][3] = inputRGB[1][1]:clone():add(1):mul(0.5)
		ss_tm:reset()
		inputMask = netSS:forward(inputBGR)
		print("Semantic segmentation time: ", ss_tm:time().real)
		dynss_tm:reset()
		inputMask = netDynSS:forward(inputMask)
		print("Dynamic Semantic segmentation: ", dynss_tm:time().real)
	end

	inputGray = util.rgb2gray_batch(inputRGB:float())
	if opt.gpu > 0 then
		inputGray = inputGray:cuda()
	end
	inputGAN = torch.cat(inputGray,inputMask,2)
	gen_tm:reset()
	output = netG:forward(inputGAN)
	print("Generator time: ", gen_tm:time().real)
	output = output:float():add(1):div(2)

	if opt.output ~= '' then
		image.save(opt.output, output[1])
		if opt.mask == '' then
			local ext = string.sub(opt.output,-4)
			path_mask = string.gsub(opt.output,ext,"_mask.png")
			image.save(path_mask, inputMask[1])
		end
	else
		winqt0 = image.display{image=output[1], win=winqt0}
	end
end