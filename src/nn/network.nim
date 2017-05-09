import nnenv
import "layers/layers", "lossfuncs/lossfuncs", "optimizers/optimizers", "measures/measures", options
import "../linalg/matrix"
import "../utils/mysequtils"

import algorithm, future

const DEBUG = false

type
  Network* = ref object of RootObj
    layers: seq[Layer]
    lossfunc: LossFunc
    optimizer: Optimizer

proc newNetwork*(layers: seq[Layer], lossfunc: LossFunc, optimizer: Optimizer): Network =
  new(result)
  result.layers = layers
  result.lossfunc = lossfunc
  result.optimizer = optimizer

proc layer*(self: Network, idx: int): Layer =
  self.layers[idx]

proc weights*(self: Network, idx: int): Matrix[NNFloat] =
  if self.layers[idx] of Links:
    var links = Links(self.layers[idx])
    result = links.weights
  else:
    result = nil

proc update(self: var Network, res: TrResults, cnt, hit, miss: int, loss: NNFloat) =
  res.currentCount += cnt
  res.hitCount += hit
  res.missCount += miss
  res.totalLoss += loss

proc forward*(self: var Network, input: Matrix[NNFloat]): seq[Matrix[NNFloat]]

proc probs(self: var Network, input: Matrix[NNFloat]): Matrix[NNFloat] =
  var output = self.forward(input).last
  result = output

proc predict*(self: var Network, input: Matrix[NNFloat]): Matrix[int] =
  var probs = self.probs(input)
  result = self.lossfunc.predictFromProbs(probs)

proc lossFromProbs(self: var Network; predictions, expected: Matrix[NNFloat]): NNFloat =
  self.lossfunc.loss(predictions, expected).reduce(0.0, (acc, val: NNFloat) => acc + val)

proc loss*(self: var Network; input, expected: Matrix[NNFloat]): NNFloat =
  var probs = self.probs(input)
  self.lossFromProbs(probs, expected)

proc hitMissCntFromProbs(self: var Network; probs, expected: Matrix[NNFloat]): tuple[hit, miss: int] =
  var
    probNorm = self.lossfunc.predictFromProbs(probs) 
    expectedNorm = self.lossfunc.predictFromProbs(expected)
  result = probNorm.reduce(
    (0, 0),
    proc(acc: tuple[hit, miss: int], val: int, row, col: int): tuple[hit, miss: int] =
      if expectedNorm[row, 0] == val:
        result = (acc.hit + 1, acc.miss)
      else:
        result = (acc.hit, acc.miss + 1)
  )

proc forward*(self: var Network, input: Matrix[NNFloat]): seq[Matrix[NNFloat]] =
  result = newSeq[Matrix[NNFloat]]()
  result.add(self.layers[0].compute(input))
  for i in 1..<self.layers.len:
    result.add(self.layers[i].compute(result.last))

proc backward*(self: var Network; outputs: seq[Matrix[NNFloat]], expected: Matrix[NNFloat]): seq[tuple[idx: int, gradient: Matrix[NNFloat]]] =
  result = newSeq[tuple[idx: int, gradient: Matrix[NNFloat]]]()
  var localGrads = @[self.lossfunc.delta(outputs.last, expected)]
  for i in countDown(self.layers.len-2, 1):
    if self.layers[i] of Links:
      let gradient = outputs[i-1].t() * localGrads.last
      result.add((i, gradient))

    let localGrad = self.layers[i].delta(outputs[i], localGrads.last)
    localGrads.add(localGrad)

proc checkGradient*(self: var Network; input, expected: Matrix[NNFloat]; gradients: seq[tuple[idx: int, gradient: Matrix[NNFloat]]]; options: Options)

proc runBatch(self: var Network; input, expected: Matrix[NNFloat]; options: Options): tuple[hit, miss: int, loss: NNFloat] =
  var outputs = self.forward(input)
  let gradients = self.backward(outputs, expected)
  for item in gradients:
    var
      (idx, gradient) = (item.idx, item.gradient)
      links = Links(self.layers[idx])
      weights = links.weights.transform((val: NNFloat) => val / input.row.NNFloat)
    self.optimizer.update(weights, gradient)
  let loss = self.lossFromProbs(outputs.last, expected)
  let (hit, miss) = self.hitMissCntFromProbs(outputs.last, expected)
  result = (hit, miss, loss)
  when DEBUG: self.checkGradient(input, expected, gradients, options)

proc runEpoch(self: var Network; input, expected: Matrix[NNFloat]; options: Options) =
  let batches: int = (input.row + options.batchSize - 1) div options.batchSize
  var res = TrResults(totalCount: input.row)
  for i in 0..<batches:
    let lb = i*options.batchSize
    let ub = min((i + 1)*options.batchSize, input.row) - 1
    var
      x = input.slice(lb, ub)
      y = expected.slice(lb, ub)

    let (hit, miss, loss) = self.runBatch(x, y, options)
    self.update(res, (ub - lb + 1), hit, miss, loss)
    options.formatter.batchEnd(res)

proc train*(self: var Network, input, expected: Matrix[NNFloat], options: Options) = 
  for i in 1..options.epochs:
    options.formatter.epochStart(i, options.epochs)
    self.runEpoch(input, expected, options)
    options.formatter.epochEnd(i, options.epochs)


proc checkGradient*(self: var Network; input, expected: Matrix[NNFloat]; gradients: seq[tuple[idx: int, gradient: Matrix[NNFloat]]]; options: Options) =
  const h = 1e-4
  options.formatter.off
  defer: options.formatter.on
  for item in gradients:
    var
      (idx, gradient) = (item.idx, item.gradient)
      links = Links(self.layers[idx])
    for i in 0..<links.weights.row:
      for j in 0..<links.weights.col:
        let x = links.weights[i, j]
        links.weights[i, j] = x - h
        let fx1 = self.loss(input, expected)
        links.weights[i, j] = x + h
        let fx2 = self.loss(input, expected)
        links.weights[i, j] = x
        let numericDiff = (fx2 - fx1) / (2.0 * h)
        assert abs(gradient[i, j] -  numericDiff) <= 1e-6, $gradient[i, j] & " " & $numericDiff
      
