require 'optim'
local tnt = require 'torchnet'

local function getIterator(mode)
   return tnt.ParallelDatasetIterator{
      nthread = 1,
      init    = function() require 'torchnet' end,
      closure = function()

         local matio = require 'matio'
         local npy4th = require 'npy4th'
         local all_depths = npy4th.loadnpy('depths.npy')
         local all_images = npy4th.loadnpy('images.npy')
         local splits = matio.load('splits2.mat')
         
         local images
         local depths

         if mode == 'train' then
            local train_idx = splits['trainNdxs']
            local train_idx = train_idx:view(train_idx:nElement())
            images = all_images:index(1, train_idx:long())
            depths = all_depths:index(1, train_idx:long())
         else
            local test_idx = splits['testNdxs']
            local test_idx = test_idx:view(test_idx:nElement())
            images = all_images:index(1, test_idx:long())
            depths = all_depths:index(1, test_idx:long())
         end

         local n_data = images:size(1)
         print('# of data:', n_data)

         local input_width = 320
         local input_height = 240

         local output_width = 320
         local output_height = 240

         require 'nnx'
         local input_resample = nn.SpatialReSampling{owidth=input_width,oheight=input_height}
         local output_resample = nn.SpatialReSampling{owidth=output_width,oheight=output_height}
         images = input_resample:forward(images:double())
         depths = output_resample:forward(depths:double())

         local n_data = images:size(1)
         
         return tnt.BatchDataset{
            batchsize = 8,
            dataset = tnt.ListDataset{
               list = torch.range(1, n_data):long(),
               load = function(idx)
                  return {
                     input  = images[idx],
                     target = depths[idx]
                  }  
               end,
            }
         }
      end,
   }
end

local model_file = arg[1]
local max_epock = tonumber(arg[2])
local gpu = tonumber(arg[3])
local out_file = arg[4]
local resume = tonumber(arg[5])
local lr = tonumber(arg[6])

local net = dofile(model_file)
local criterion = nn.MSECriterion()

local engine = tnt.OptimEngine()
local meter  = tnt.AverageValueMeter()

engine.hooks.onForwardCriterion = function(state)
   meter:add(state.criterion.output)
end

engine.hooks.onEndEpoch = function(state)
   mean, std = meter:value()
   print(state.epoch, mean)
   meter:reset()
   
   if state.epoch % 50 == 0 then
     local checkpoint = {}
     state.network:clearState()
     checkpoint.model = state.network
     checkpoint.epoch = state.epoch
     torch.save(out_file, checkpoint)
   end
   
end

require 'cunn'
require 'cutorch'
require 'cudnn'

cutorch.setDevice(gpu)   
net = net:cuda()
criterion = criterion:cuda()
cudnn.convert(net, cudnn)
net:training()

local igpu, tgpu = torch.CudaTensor(), torch.CudaTensor()
engine.hooks.onSample = function(state)
   igpu:resize(state.sample.input:size() ):copy(state.sample.input)
   tgpu:resize(state.sample.target:size()):copy(state.sample.target)
   state.sample.input  = igpu
   state.sample.target = tgpu
end  

engine:train{
   network   = net,
   iterator  = getIterator('train'),
   criterion = criterion,
   maxepoch  = max_epoch,
   optimMethod = optim.adadelta,
   optimState = {
      weightDecay = 0.0005,
      momentum = 0.9,
      learningRateDecay = 1e-7,
   }      
}