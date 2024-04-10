//
//  main.swift
//  mul_col
//
//  Created by Tomasz Kolinko on 24/01/2024.
//
import os
import Foundation
import Metal
import simd
print("starting up")

let log = OSLog(subsystem: "com.kolinko", category: "Performance")
 
let gpu = Gpu()
print("loading")

//runConvert([.mistral, .fp16])
//exit(0)

let stateDim = 4096
let hiddenDim = 14336
let goQ8 = false
let percentLoad = goQ8 ? 0x8 : 0xC // works decently for mixtral// from 0 to max binSize
let bSize: Int

var numLayers = 10
var numExperts = 2
var numTokens = 30

let goNoMuls = false
let goMistral = numExperts == 1
let goVerify = numLayers == 10 && numExperts == 2 && !goNoMuls && !goMistral
let goSaveTests = false


//modelRunTests()


let modelData = Model(numLayers: numLayers, numExperts: numExperts, percentLoad: percentLoad)

let t = Tokeniser(modelData)

//var tokens = [VectorFloat]()
let tokens = t.embed([1, 1602, 460])//[    1,   733, 16289, 28793,  1602,   460,   368, 28804,   733, 28748,
//                          16289, 28793])//

os_signpost(.end, log: log, name: "Loading")

let headDim = 128  // Example head dimension
let numHeadsKV = 8
let numHeads = 32
let kvRepeats : Int = numHeads/numHeadsKV
let maxSeqLen = 2048
let maxTokens = maxSeqLen
let freqsCis = createFreqsCis(headDim: headDim, maxSeqLen: maxSeqLen)

//modelProfile()

print()
gpu.eval()

var silent = true

func runNetwork(isTest: Bool, tokens _tokens: [VectorFloat], quant: Double = 1.0) {
    var tokens = _tokens
    let xkLayerTokenHead = Matrix4DFloat(shape:[numLayers, maxTokens, numHeads, headDim])
    let xvLayerToken = Matrix3DFloat(shape:[numLayers, maxTokens, stateDim])
    
    var h : VectorFloat = tokens[0]
    
    let x1 = VectorFloat(shape:[hiddenDim])
    let x3 = VectorFloat(shape:[hiddenDim])
    let x2 = VectorFloat(shape:[hiddenDim])
    let ffnOut = [VectorFloat]([VectorFloat(shape:[stateDim]), VectorFloat(shape:[stateDim])])
    
    // buffers
    let h_norm = VectorFloat(shape:[stateDim])
    let attnOutput = VectorFloat(shape: [numHeads * headDim])
    let fxn = VectorFloat(shape:[stateDim])
    let gateOut = VectorFloat(shape: [numExperts])
    let gateIdxs = VectorFloat(shape:[2])
    let gateVals = VectorFloat(shape:[2])
    let outputVector = VectorFloat(shape:[modelData.output.outSize])
    let outNormed = VectorFloat(shape: [stateDim])
    
    // timers
    var output = ""
    gpu.warnOfEvals = false
    let finalEvalTime = Date()
    var evalTime = Date()
    var sumPrepTime = Date().timeIntervalSince(evalTime)
    var sumEvalTime = Date().timeIntervalSince(evalTime)

    let _layer = modelData.layers[0]!
    let xq = VectorFloat(shape: [_layer.wq.outSize])
    let xk_temp = VectorFloat(shape: [_layer.wk.outSize])
    let xv_temp = VectorFloat(shape: [_layer.wk.outSize])
    let attnFfnOut = VectorFloat(shape: [_layer.wo.outSize])

    for thisToken in 0...numTokens {
        let scores = MatrixFloat(shape: [numHeads, thisToken+1])

        if thisToken == 2 {
            gpu.eval()
            sumPrepTime = Date().timeIntervalSince(evalTime)
            sumEvalTime = Date().timeIntervalSince(evalTime)
            gpu.warnOfEvals = true
        }
        
        h = tokens[thisToken].copy()

        for layerNo in 0..<numLayers {
            let layer = modelData.layers[layerNo]!
            h.rmsNormFast(out: h_norm)
            
            h_norm.mul(by:layer.attnNorm)

            let xk = xkLayerTokenHead[layerNo][thisToken].asVector()
            let xv = xvLayerToken[layerNo][thisToken]
            
            basicMul(v: h_norm, by: layer.wq.core, out: xq)
            
            basicMul(v: h_norm, by: layer.wk.core, out: xk_temp)
            xk_temp.repeated(kvRepeats, into:xk)
                        
            basicMul(v: h_norm, by: layer.wv.core, out: xv_temp)
            xv_temp.repeated(kvRepeats, into: xv)
            
            let xqHeads = xq.asMatrix(newCols: headDim)
            let xkHeads = xk.asMatrix(newCols: headDim)

            let xkTokenHeads = xkLayerTokenHead[layerNo]
            let xvToken = xvLayerToken[layerNo]
            
            let fCis = freqsCis[thisToken]
            xqHeads.mul(complexArray: fCis)
            xkHeads.mul(complexArray: fCis)
            
            calcScores2(xq_heads: xqHeads, 
                        xkTokenHeads: xkTokenHeads,
                        numTokens: thisToken+1,
                        out: scores)

            scores.softmax()

            sumScores(scores: scores,
                      xvToken: xvToken,
                      numTokens: thisToken+1,
                      out: attnOutput)
            
            basicMul(v: attnOutput, by: layer.wo.core, out: attnFfnOut)
            
            h.add(by: attnFfnOut)
            h.rmsNormFast(out:fxn)
            
            fxn.mul(by:layer.ffnNorm)

            if layer.ffnGate == nil {
                let expIdx = ScalarFloat(value: 0)
                expertMul(v: fxn, by: layer.w1, expNo: expIdx, out: x1, quant: quant)
                expertMul(v: fxn, by: layer.w3, expNo: expIdx, out: x3, quant: quant)
                
                silu(x1, x3, out: x2)
                expertMul(v: x2, by: layer.w2, expNo: expIdx, out: ffnOut[0], quant: quant)
                h.add(by: ffnOut[0])
            } else {
                basicMul(v:fxn, by:layer.ffnGate!, out:gateOut)
                mpsTopK(v: gateOut, topK: 2, outIndexes: gateIdxs, outValues: gateVals)
                
                gateVals.softmax()

                for i in 0..<2 {
                    let expIdx = gateIdxs.scalarAt(i)
                    if !goQ8 {
                        if isTest {
                            bucketMulFast(v: fxn, by: layer.w1, expNo: expIdx, out: x1, quant: quant)
                            bucketMulFast(v: fxn, by: layer.w3, expNo: expIdx, out: x3, quant: quant)
                            
                            silu(x1, x3, out: x2)
                            bucketMulFast(v: x2, by: layer.w2, expNo: expIdx, out: ffnOut[i], quant: quant)
                            ffnOut[i].mul(by: gateVals.scalarAt(i))
                        } else {
                            expertMul(v: fxn, by: layer.w1, expNo: expIdx, out: x1, quant: quant)
                            expertMul(v: fxn, by: layer.w3, expNo: expIdx, out: x3, quant: quant)
                            
                            silu(x1, x3, out: x2)
                            expertMul(v: x2, by: layer.w2, expNo: expIdx, out: ffnOut[i], quant: quant)
                            ffnOut[i].mul(by: gateVals.scalarAt(i))
                        }
                    } else {
                        expertMulQ8(v: fxn, by: layer.w1, expNo: expIdx, out: x1, quant: quant)
                        expertMulQ8(v: fxn, by: layer.w3, expNo: expIdx, out: x3, quant: quant)
                        
                        silu(x1, x3, out: x2)
                        expertMulQ8(v: x2, by: layer.w2, expNo: expIdx, out: ffnOut[i], quant: quant)
                        ffnOut[i].mul(by: gateVals.scalarAt(i))
                    }
                }
                
                h.add(by: ffnOut[0])
                h.add(by: ffnOut[1])
            }
            
          //  gpu.eval()
            gpu.stopCapture()
            
          //  testVec("h-out:\(thisToken):\(layerNo)", h)
        }
        
        
        h.rmsNormFast(out: outNormed)
        outNormed.mul(by: modelData.norm.asVector())
        
        basicMul(v: outNormed, by: modelData.output.core, out: outputVector)
        
        let topKVector = mpsTopK(v: outputVector)
        
        gpu.warnOfEvals = false
        sumPrepTime += Date().timeIntervalSince(evalTime)
        let ptime = Date().timeIntervalSince(evalTime)*1000
        evalTime = Date()
        gpu.eval()
        sumEvalTime += Date().timeIntervalSince(evalTime)
        evalTime = Date()
        testVec32("token:\(thisToken)", h)
        testVec32("ovector:\(thisToken)", outputVector)

        if tokens.count-1 == thisToken {
            tokens.append(modelData.tokEmbeddings.fetchRow(topKVector.scalarAt(0)))
            gpu.eval()


            if thisToken >= 10 && goVerify {
                speedReport()
            }

            testReport(thisToken >= 10)

            let topToken = Int(topKVector.getInt(index: 0))
            let newS = t[topToken].replacingOccurrences(of: "▁", with: " ")
            output += newS
            if (silent) {
                print(newS, terminator: goVerify ? "\n" : "")
                fflush(stdout)
                if output.contains("</s>") {
                    break
                }
            }
        }
        
        gpu.warnOfEvals = true
        
        if !silent {
            print("prep: \(ptime, precision: 2) ms; eval: \(Date().timeIntervalSince(evalTime)*1000, precision: 2) ms")
            evalTime = Date()
        }
        
    }
    
    evalTime = Date()
    gpu.eval()
    gpu.stopCapture()
    
    if let range = output.range(of: "</s>") {
        output = String(output.prefix(upTo: range.lowerBound)) + "ₔ"
    } else {
        output += " ›››"
    }
    
    if !silent {
        print("\(Int(quant*100))% \t \(output)\n")
        
        print("final eval time \(Date().timeIntervalSince(finalEvalTime)*1000, precision: 2) ms")
        
        print("sum eval time \(sumEvalTime*1000, precision: 2) ms")
        print("sum prep time \(sumPrepTime*1000, precision: 2) ms")
        print("avg eval time \(sumEvalTime*1000/Double(tokens.count-2), precision: 2) ms")
        print("avg prep time \(sumPrepTime*1000/Double(tokens.count-2), precision: 2) ms")
        
        print("both \((Double(tokens.count-2)/(sumEvalTime+sumPrepTime)), precision: 2) tps")
        print("just eval \((Double(tokens.count-2)/(sumEvalTime)), precision: 2) tps")
        
    } else {
        speedReport()
    }
    
    func speedReport() {
        print("\n")
        var evalTime = sumEvalTime*1000/Double(tokens.count-2)
        var prepTime = sumPrepTime*1000/Double(tokens.count-2)
        
        evalTime /= Double(numLayers) / 32.0
        prepTime /= Double(numLayers) / 32.0

        sumEvalTime /= Double(numLayers) / 32.0
        sumPrepTime /= Double(numLayers) / 32.0

        
        let sumTps = Double(tokens.count-2)/(sumEvalTime+sumPrepTime)
        let evalTps = Double(tokens.count-2)/(sumEvalTime)
        
        print("\(quant*100, precision: 2)%: \(prepTime, precision: 2)ms + \(evalTime, precision: 2)ms (\(evalTps, precision: 2)/\(sumTps, precision: 2)tps)")
        print("")
    }
    
}

var runControl = false
silent = true
runNetwork(isTest: true, tokens: tokens, quant:1)

var storedIntegers: [Int] = []
var storedStrings: [String] = []

var quant: Double = 1.0 // 0.25
var isTest = true
while true {
    print("Enter 'p XX' to store a number or any text to store it as a string ('q' to quit):")
    while true {
        print("> ", terminator: "")
        if let input = readLine() {
            if let number = Int(input), (0...100).contains(number) {
                quant = Double(number)/100.0
            } else if input == "t" {
                isTest = !isTest
                print("Test switched to " + (isTest ? "ON" : "OFF"))
            } else if input == "w" {
                let tokens = t.embed([    1,   733, 16289, 28793,  1602,   460,   368, 28804,   733, 28748,
                                          16289, 28793])
                runNetwork(isTest: isTest, tokens: tokens, quant:quant)

            } else {
                let tokens = t.embed("[INST]"+input+"[/INST]")
                runNetwork(isTest: isTest, tokens: tokens, quant:quant)
            }
        }
    }
}
