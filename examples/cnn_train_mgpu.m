function [net, info] = cnn_train_mgpu(net, imdb, getBatch, varargin)
% CNN_TRAIN   Demonstrates training a CNN
%    CNN_TRAIN() is an example learner implementing stochastic
%    gradient descent with momentum to train a CNN. It can be used
%    with different datasets and tasks by providing a suitable
%    getBatch function.
%
%    The function automatically restarts after each training epoch by
%    checkpointing.
%
%    The function supports training on CPU or on one or more GPUs
%    (specify the list of GPU IDs in the `gpus` option). Multi-GPU
%    support is relatively primitive but sufficient to obtain a
%    noticable speedup.

% Copyright (C) 2014-15 Andrea Vedaldi.
% All rights reserved.
%
% This file is part of the VLFeat library and is made available under
% the terms of the BSD license (see the COPYING file).

opts.batchSize = 256 ;
opts.numSubBatches = 1 ;
opts.train = [] ;
opts.val = [] ;
opts.numEpochs = 300 ;
opts.gpus = [] ; % which GPU devices to use (none, one, or more)
opts.learningRate = 0.001 ;
opts.continue = false ;
opts.expDir = fullfile('data','exp') ;
opts.conserveMemory = false ;
opts.sync = true ;
opts.prefetch = false ;
opts.weightDecay = 0.0005 ;
opts.momentum = 0.9 ;
opts.errorType = 'multiclass' ;
opts.plotDiagnostics = false ;
opts.memoryMapFile = fullfile(tempdir, 'matconvnet.bin') ;
opts = vl_argparse(opts, varargin) ;

if ~exist(opts.expDir, 'dir'), mkdir(opts.expDir) ; end
if isempty(opts.train), opts.train = find(imdb.images.set==1) ; end
if isempty(opts.val), opts.val = find(imdb.images.set==2) ; end
if isnan(opts.train), opts.train = [] ; end

% -------------------------------------------------------------------------
%                                                    Network initialization
% -------------------------------------------------------------------------

if ~isempty(opts.train)
  for i=1:numel(net.layers)
    if isfield(net.layers{i}, 'weights')
      J = numel(net.layers{i}.weights) ;
      for j=1:J
        net.layers{i}.momentum{j} = zeros(size(net.layers{i}.weights{j}), 'single') ;
      end
      if ~isfield(net.layers{i}, 'learningRate')
        net.layers{i}.learningRate = ones(1, J, 'single') ;
      end
      if ~isfield(net.layers{i}, 'weightDecay')
        net.layers{i}.weightDecay = ones(1, J, 'single') ;
      end
    end
  end
end

% setup GPUs
numGpus = numel(opts.gpus) ;
if numGpus > 1
  if isempty(gcp('nocreate')),
    parpool('local',numGpus) ;
    spmd, gpuDevice(opts.gpus(labindex)) ; end
  end
end
if exist(opts.memoryMapFile), delete(opts.memoryMapFile) ; end

% -------------------------------------------------------------------------
%                                                        Train and validate
% -------------------------------------------------------------------------

for epoch=1:opts.numEpochs
  learningRate = opts.learningRate(min(epoch, numel(opts.learningRate))) ;

  % fast-forward to last checkpoint
  modelPath = @(ep) fullfile(opts.expDir, sprintf('net-epoch-%d.mat', ep));
  modelFigPath = fullfile(opts.expDir, 'net-train.pdf') ;
  if opts.continue
    if exist(modelPath(epoch),'file')
      if epoch == opts.numEpochs
        load(modelPath(epoch), 'net', 'info') ;
      end
      continue ;
    end
    if epoch > 1
      fprintf('resuming by loading epoch %d\n', epoch-1) ;
      load(modelPath(epoch-1), 'net', 'info') ;
    end
  end

  % move CNN to GPU as needed
  if numGpus == 1
    net = vl_simplenn_move(net, 'gpu') ;
  elseif numGpus > 1
    spmd(numGpus)
      net_ = vl_simplenn_move(net, 'gpu') ;
    end
  end

  % train one epch and validate
  train = opts.train(randperm(numel(opts.train))) ; % shuffle
  val = opts.val ;
  if numGpus <= 1
    [net,stats.train] = process_epoch(opts, getBatch, epoch, train, learningRate, imdb, net) ;
    [~,stats.val] = process_epoch(opts, getBatch, epoch, val, 0, imdb, net) ;
  else
    spmd(numGpus)
      [net_, stats_train_] = process_epoch(opts, getBatch, epoch, train, learningRate, imdb, net_) ;
      [~, stats_val_] = process_epoch(opts, getBatch, epoch, val, 0, imdb, net_) ;
    end
    stats.train = sum([stats_train_{:}],2) ;
    stats.val = sum([stats_val_{:}],2) ;
  end

  % save
  for f = {'train', 'val'}
    f = char(f) ;
    n = numel(eval(f)) ;
    info.(f).objective(epoch) = stats.(f)(1) / n ;
    info.(f).error(epoch) = stats.(f)(2) / n ;
    info.(f).topFiveError(epoch) = stats.(f)(3) / n ;
    info.(f).speed(epoch) = n / stats.(f)(4) ;
  end
  if numGpus > 1
    spmd(numGpus)
      net_ = vl_simplenn_move(net_, 'cpu') ;
    end
    net = net_{1} ;
  else
    net = vl_simplenn_move(net, 'cpu') ;
  end
  save(modelPath(epoch), 'net', 'info') ;

  figure(1) ; clf ;
  subplot(1,2,1) ;
  semilogy(1:epoch, info.train.objective, 'k') ; hold on ;
  semilogy(1:epoch, info.val.objective, 'b') ;
  xlabel('training epoch') ; ylabel('energy') ;
  grid on ;
  h=legend('train', 'val') ;
  set(h,'color','none');
  title('objective') ;
  subplot(1,2,2) ;
  switch opts.errorType
    case 'multiclass'
      plot(1:epoch, info.train.error, 'k') ; hold on ;
      plot(1:epoch, info.train.topFiveError, 'k--') ;
      plot(1:epoch, info.val.error, 'b') ;
      plot(1:epoch, info.val.topFiveError, 'b--') ;
      h=legend('train','train-5','val','val-5') ;
    case 'binary'
      plot(1:epoch, info.train.error, 'k') ; hold on ;
      plot(1:epoch, info.val.error, 'b') ;
      h=legend('train','val') ;
  end
  grid on ;
  xlabel('training epoch') ; ylabel('error') ;
  set(h,'color','none') ;
  title('error') ;
  drawnow ;
  print(1, modelFigPath, '-dpdf') ;
end

% -------------------------------------------------------------------------
function [err, err5] = compute_error(opts, labels, predictions)
% -------------------------------------------------------------------------
switch opts.errorType
  case 'multiclass'
    [~,predictions] = sort(predictions, 3, 'descend') ;
    error = ~bsxfun(@eq, predictions, reshape(labels, 1, 1, 1, [])) ;
    err = sum(sum(sum(error(:,:,1,:)))) ;
    err5 = sum(sum(sum(min(error(:,:,1:5,:),[],3)))) ;
  case 'binary'
    error = bsxfun(@times, predictions, labels) < 0 ;
    err = sum(error(:)) ;
    err5 = 0 ;
end

% -------------------------------------------------------------------------
function  [net,stats,prof] = process_epoch(opts, getBatch, epoch, subset, learningRate, imdb, net)
% -------------------------------------------------------------------------

% validation mode if learning rate is zero
training = learningRate > 0 ;
if training, mode = 'training' ; else, mode = 'validation' ; end
if nargout > 2, mpiprofile on ; end

numGpus = numel(opts.gpus) ;
if numGpus >= 1
  one = gpuArray(single(1)) ;
else
  one = single(1) ;
end
res = [] ;
mmap = [] ;
stats = zeros(4,1) ;

for t=1:opts.batchSize:numel(subset)
  fprintf('%s: epoch %02d: processing batch %3d of %3d ...', mode, epoch, ...
          fix(t/opts.batchSize)+1, ceil(numel(subset)/opts.batchSize)) ;
  batchSize = min(opts.batchSize, numel(subset) - t + 1) ;
  error = [0;0;0] ;

  batchTime = tic ;
  numDone = 0 ;
  for s=1:opts.numSubBatches
    % get this image batch and prefetch the next
    batchStart = t + (labindex-1) + (s-1) * numlabs ;
    batchEnd = min(t+opts.batchSize-1, numel(subset)) ;
    batch = subset(batchStart : opts.numSubBatches * numlabs : batchEnd) ;
    [im, labels] = getBatch(imdb, batch) ;

    if opts.prefetch
      if s==opts.numSubBatches
        batchStart = t + (labindex-1) + opts.batchSize ;
        batchEnd = min(t+2*opts.batchSize-1, numel(subset)) ;
      else
        batchStart = batchStart + numlabs ;
      end
      nextBatch = subset(batchStart : opts.numSubBatches * numlabs : batchEnd) ;
      getBatch(imdb, nextBatch) ;
    end

    if numGpus >= 1
      im = gpuArray(im) ;
    end

    % evaluate CNN
    net.layers{end}.class = labels ;
    if training, dzdy = one; else, dzdy = [] ; end
    res = vl_simplenn(net, im, dzdy, res, ...
                      'accumulate', s ~= 1, ...
                      'disableDropout', ~training, ...
                      'conserveMemory', opts.conserveMemory, ...
                      'sync', opts.sync) ;

    % accumulate training errors
    obj = sum(double(gather(res(end).x))) ;
    [err,err5] = compute_error(opts, labels, gather(res(end-1).x)) ;
    error = error + [obj;err;err5] ;
    numDone = numDone + numel(batch) ;
  end

  % gather and accumulate gradients across labs
  if training
    if numGpus <= 1
      net = accumulate_gradients(opts, learningRate, batchSize, net, res) ;
    else
      if isempty(mmap)
        mmap = map_grads(opts.memoryMapFile, net, res, numGpus) ;
      end
      write_grads(mmap, net, res) ;
      labBarrier() ;
      [net,res] = accumulate_gradients(opts, learningRate, batchSize, net, res, mmap) ;
    end
  end

  % print learning statistics
  batchTime = toc(batchTime) ;
  stats = stats + [error ; batchTime] ;
  speed = batchSize/batchTime ;

  fprintf(' %.2f s (%.1f images/s)', batchTime, speed) ;
  n = (t + batchSize - 1) / max(1,numlabs) ;
  fprintf(' err %.1f err5 %.1f', stats(2)/n*100, stats(3)/n*100) ;
  fprintf(' [done %d of %d]', numDone, batchSize);
  fprintf('\n') ;

  % debug info
  if opts.plotDiagnostics && numGpus <= 1
    figure(2) ; vl_simplenn_diagnose(net,res) ; drawnow ;
  end
end

if nargout > 2
  prof = mpiprofile('info');
  mpiprofile off ;
end

% -------------------------------------------------------------------------
function [net,res] = accumulate_gradients(opts, lr, batchSize, net, res, mmap)
% -------------------------------------------------------------------------
for l=1:numel(net.layers)
  for j=1:numel(res(l).dzdw)
    thisDecay = opts.weightDecay * net.layers{l}.weightDecay(j) ;
    thisLR = lr * net.layers{l}.learningRate(j) ;

    % accumualte from multiple labs (GPUs) if needed
    if nargin >= 6
      tag = sprintf('l%d_%d',l,j) ;
      tmp = zeros(size(mmap.Data(labindex).(tag)), 'single') ;
      for g = setdiff(1:numel(mmap.Data), labindex)
        tmp = tmp + mmap.Data(g).(tag) ;
      end
      res(l).dzdw{j} = res(l).dzdw{j} + tmp ;
    end

    net.layers{l}.momentum{j} = ...
        opts.momentum * net.layers{l}.momentum{j} ...
        - thisDecay * net.layers{l}.weights{j} ...
        - (1 / batchSize) * res(l).dzdw{j} ;

    if isfield(net.layers{l}, 'weights')
      net.layers{l}.weights{j} = net.layers{l}.weights{j} + thisLR * net.layers{l}.momentum{j} ;
    else
      if j == 1
        net.layers{l}.filters = net.layers{l}.filters + thisLR * net.layers{l}.momentum{j} ;
      else
        net.layers{l}.biases = net.layers{l}.biases + thisLR * net.layers{l}.momentum{j} ;
      end
    end
  end
end

% -------------------------------------------------------------------------
function mmap = map_grads(fname, net, res, numGpus)
% -------------------------------------------------------------------------
format = {} ;
for i=1:numel(net.layers)
  for j=1:numel(res(i).dzdw)
    format(end+1,1:3) = {'single', size(res(i).dzdw{j}), sprintf('l%d_%d',i,j)} ;
  end
end
format(end+1,1:3) = {'double', [3 1], 'errors'} ;
if ~exist(fname) && (labindex == 1)
  f = fopen(fname,'wb') ;
  for g=1:numGpus
    for i=1:size(format,1)
      fwrite(f,zeros(format{i,2},format{i,1}),format{i,1}) ;
    end
  end
  fclose(f) ;
end
labBarrier() ;
mmap = memmapfile(fname, 'Format', format, 'Repeat', numGpus, 'Writable', true) ;

% -------------------------------------------------------------------------
function write_grads(mmap, net, res)
% -------------------------------------------------------------------------
for i=1:numel(net.layers)
  for j=1:numel(res(i).dzdw)
    mmap.Data(labindex).(sprintf('l%d_%d',i,j)) = gather(res(i).dzdw{j}) ;
  end
end