/* Copyright (c) 2012,2013 Genome Research Ltd.
 *
 * Author: Stephan Schiffels <stephan.schiffels@sanger.ac.uk>
 *
 * This file is part of msmc.
 * msmc is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation; either version 3 of the License, or (at your option) any later
 * version.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 */
 
import std.math;
import std.stdio;
import std.random;
import std.exception;
import std.algorithm;
import model.msmc_model;
import model.triple_index;
import model.triple_index_marginal;
import powell;
import logger;

MSMCmodel getMaximization(double[] eVec, double[][] eMat, double[][] emissionMat, MSMCmodel params,
                          in size_t[] timeSegmentPattern, bool fixedPopSize, bool fixedRecombination)
{
  auto minFunc = new MinFunc(eVec, eMat, emissionMat, params, timeSegmentPattern, fixedPopSize, fixedRecombination);

  auto powell = new Powell!MinFunc(minFunc);
  auto x = minFunc.initialValues();
  auto startVal = minFunc(x);
  powell.init(x);
  double[] xNew;
  while(powell.iter < 200 && !powell.finished()) {
    logInfo(format("\r  * [%s/200(max)] Maximization Step", powell.iter));
    xNew = powell.step();
    if(powell.iter == 200) {
      logInfo("WARNING: Powell's maximization method exceeding 200 iterations. Taking best value as maximum.");
    }
  }
  auto endVal = minFunc(xNew);
  logInfo(format(", Q-function before: %s, after:%s\n", startVal, endVal));
  return minFunc.makeParamsFromVec(xNew);
}

class MinFunc {
  
  static immutable double penalty = 1.0e20;
  MSMCmodel initialParams;
  const size_t[] timeSegmentPattern;
  size_t nrSubpopPairs, nrParams;
  const double[] expectationResultVec;
  const double[][] expectationResultMat;
  const double[][] emissionResultMat;
  bool fixedPopSize, fixedRecombination;
  
  this(in double[] expectationResultVec, in double[][] expectationResultMat, in double[][] emissionResultMat,
       MSMCmodel initialParams, in size_t[] timeSegmentPattern, bool fixedPopSize, bool fixedRecombination)
  {
    this.initialParams = initialParams;
    this.timeSegmentPattern = timeSegmentPattern;
    this.expectationResultVec = expectationResultVec;
    this.expectationResultMat = expectationResultMat;
    this.emissionResultMat = emissionResultMat;
    this.fixedPopSize = fixedPopSize;
    this.fixedRecombination = fixedRecombination;
    nrSubpopPairs = initialParams.nrSubpopulations * (initialParams.nrSubpopulations + 1) / 2;
    nrParams = nrSubpopPairs * cast(size_t)timeSegmentPattern.length;
    if(!fixedRecombination)
      nrParams += 1;
    if(fixedPopSize)
      nrParams -= initialParams.nrSubpopulations * cast(size_t)timeSegmentPattern.length;
  }
  
  double opCall(in double[] x) {
    if(invalid(x))
      return penalty;
    MSMCmodel newParams = makeParamsFromVec(x);
    return -logLikelihood(newParams);
  };
  
  bool invalid(in double[] x) {
    auto lambdaVec = fixedPopSize ? getLambdaVecFromXfixedPop(x) : getLambdaVecFromX(x);
    auto recombinationRate = fixedRecombination ? initialParams.recombinationRate : getRecombinationRateFromX(x);
    auto marginalIndex = new MarginalTripleIndex(initialParams.nrTimeIntervals, initialParams.subpopLabels);
    
    if(recombinationRate < 0.0 || isNaN(recombinationRate))
      return true;
    
    foreach(au, l; lambdaVec) {
      if(l < 0.0 || isNaN(l))
        return true;
      auto aij = marginalIndex.getIndexFromMarginalIndex(au);
      auto triple = marginalIndex.getTripleFromIndex(aij);
      auto subpop1 = marginalIndex.subpopLabels[triple.ind1];
      auto subpop2 = marginalIndex.subpopLabels[triple.ind2];
      if(subpop1 != subpop2) {
        auto marginalIndex1 = marginalIndex.subpopulationTripleToMarginalIndexMap[triple.time][subpop1][subpop1];
        auto marginalIndex2 = marginalIndex.subpopulationTripleToMarginalIndexMap[triple.time][subpop2][subpop2];
        if(l > 0.5 * (lambdaVec[marginalIndex1] + lambdaVec[marginalIndex2]))
          return true;
      }
    }
    return false;
  }
  
  double[] initialValues()
  out(x) {
    assert(x.length == nrParams);
  }
  body {
    auto x = fixedPopSize ? getXfromLambdaVecFixedPop(initialParams.lambdaVec) : 
             getXfromLambdaVec(initialParams.lambdaVec);
    if(!fixedRecombination)
      x ~= initialParams.recombinationRate;
    return x;
  }
  
  double[] getXfromLambdaVecFixedPop(double[] lambdaVec)
  out(x) {
    assert(x.length == timeSegmentPattern.length * (nrSubpopPairs - initialParams.nrSubpopulations));
  }
  body {
    double[] ret;
    size_t count = 0;
    foreach(nrIntervalsInSegment; timeSegmentPattern) {
      foreach(subpopPairIndex; 0 .. nrSubpopPairs) {
        auto lIndex = count * nrSubpopPairs + subpopPairIndex;
        auto tripleIndex = initialParams.marginalIndex.getIndexFromMarginalIndex(lIndex);
        auto triple = initialParams.marginalIndex.getTripleFromIndex(tripleIndex);
        auto p1 = initialParams.subpopLabels[triple.ind1];
        auto p2 = initialParams.subpopLabels[triple.ind2];
        if(p1 != p2) {
          ret ~= lambdaVec[lIndex];
        }
      }
      count += nrIntervalsInSegment;
    }
    return ret;
  }
  
  double[] getXfromLambdaVec(double[] lambdaVec)
  out(x) {
    assert(x.length == timeSegmentPattern.length * nrSubpopPairs);
  }
  body {
    double[] ret;
    size_t count = 0;
    foreach(nrIntervalsInSegment; timeSegmentPattern) {
      foreach(i; 0 .. nrSubpopPairs)
        ret ~= lambdaVec[count * nrSubpopPairs + i];
      count += nrIntervalsInSegment;
    }
    return ret;
  }
  
  
  MSMCmodel makeParamsFromVec(in double[] x) {
    auto lambdaVec = fixedPopSize ? getLambdaVecFromXfixedPop(x) : getLambdaVecFromX(x);
    auto recombinationRate = fixedRecombination ? initialParams.recombinationRate : getRecombinationRateFromX(x);
    return new MSMCmodel(initialParams.emissionRate.mu, recombinationRate, initialParams.subpopLabels, lambdaVec, initialParams.nrTimeIntervals, initialParams.nrTtotIntervals, initialParams.directedEmissions);
  }
  
  double[] getLambdaVecFromXfixedPop(in double[] x)
  in {
    assert(x.length == nrParams);
  }
  body {
    auto lambdaVec = initialParams.lambdaVec.dup;
    auto timeIndex = 0U;
    auto valuesPerTime = nrSubpopPairs - initialParams.nrSubpopulations;
    foreach(segmentIndex, nrIntervalsInSegment; timeSegmentPattern) {
      foreach(intervalIndex; 0 .. nrIntervalsInSegment) {
        auto xIndex = 0;
        foreach(subpopPairIndex; 0 .. nrSubpopPairs) {
          auto lIndex = timeIndex * nrSubpopPairs + subpopPairIndex;
          auto tripleIndex = initialParams.marginalIndex.getIndexFromMarginalIndex(lIndex);
          auto triple = initialParams.marginalIndex.getTripleFromIndex(tripleIndex);
          auto p1 = initialParams.subpopLabels[triple.ind1];
          auto p2 = initialParams.subpopLabels[triple.ind2];
          if(p1 != p2) {
            lambdaVec[lIndex] = x[segmentIndex * valuesPerTime + xIndex];
            xIndex += 1;
          }
        }
        timeIndex += 1;
      }
    }
    return lambdaVec;
  }
  
  double[] getLambdaVecFromX(in double[] x)
  in {
    assert(x.length == nrParams);
  }
  body {
    auto lambdaVec = initialParams.lambdaVec.dup;
    auto timeIndex = 0U;
    foreach(segmentIndex, nrIntervalsInSegment; timeSegmentPattern) {
      foreach(intervalIndex; 0 .. nrIntervalsInSegment) {
        foreach(subpopPairIndex; 0 .. nrSubpopPairs) {
          auto lIndex = timeIndex * nrSubpopPairs + subpopPairIndex;
          auto xIndex = segmentIndex * nrSubpopPairs + subpopPairIndex;
          lambdaVec[lIndex] = x[xIndex];
        }
        timeIndex += 1;
      }
    }
    return lambdaVec;
  }

  double getRecombinationRateFromX(in double[] x)
  in {
    assert(!fixedRecombination);
  }
  body {
    auto recombinationRate = x[$ - 1];
    return recombinationRate;
  }

  double logLikelihood(MSMCmodel params) {
    double ret = 0.0;
    foreach(au; 0 .. initialParams.nrMarginals) {
      foreach(bv; 0 .. initialParams.nrMarginals) {
        ret += expectationResultMat[au][bv] * log(params.transitionRate.transitionProbabilityQ2(au, bv));
      }
      ret += expectationResultVec[au] * log(
        params.transitionRate.transitionProbabilityQ1(au) + params.transitionRate.transitionProbabilityQ2(au, au)
      );
    }
    // if(params.nrHaplotypes > 2) {
    //   foreach(i; 0 .. params.nrTimeIntervals) {
    //     foreach(int emissionId; 0 .. cast(int)params.emissionRate.getNrEmissionIds()) {
    //       ret += emissionResultMat[i][emissionId] * log(params.emissionRate.emissionProb(emissionId, i));
    //     }
    //   }
    // }
    return ret;
  }

}

unittest {
  writeln("test minfunc.getLambdaFromX");
  
  auto lambdaVec = new double[12];
  foreach(i; 0 .. 12)
    lambdaVec[i] = cast(double)i + 1.0;
  auto params = new MSMCmodel(0.01, 0.001, [0U, 0, 1, 1], lambdaVec, 4, 4, false);
  auto expectationResultVec = new double[params.nrMarginals];
  auto expectationResultMat = new double[][](params.nrMarginals, params.nrMarginals);
  auto emissionResultMat = new double[][](params.nrTimeIntervals, params.emissionRate.getNrEmissionIds);
  auto timeSegmentPattern = [2UL, 2];
  
  auto minFunc = new MinFunc(expectationResultVec, expectationResultMat, emissionResultMat, params, timeSegmentPattern, false, false);
  auto x = [1, 1.5, 3, 4, 4.5, 6, 1.2];
  assert(minFunc.getLambdaVecFromX(x) == [1, 1.5, 3, 1, 1.5, 3, 4, 4.5, 6, 4, 4.5, 6]);
  assert(minFunc.getRecombinationRateFromX(x) == 1.2);
  assert(!minFunc.invalid(x));
  x[1] = 2.5;
  assert(minFunc.invalid(x));
  

  minFunc = new MinFunc(expectationResultVec, expectationResultMat, emissionResultMat, params, timeSegmentPattern, true, false);
  x = [23.4, 35.6, 1.4];
  assert(minFunc.getLambdaVecFromXfixedPop(x) == [1, 23.4, 3, 4, 23.4, 6.0, 7.0, 35.6, 9.0, 10.0, 35.6, 12]);
  assert(minFunc.getRecombinationRateFromX(x) == 1.4);

  minFunc = new MinFunc(expectationResultVec, expectationResultMat, emissionResultMat, params, timeSegmentPattern, false, true);
  x = [1, 2, 3, 4, 5, 6];
  assert(minFunc.getLambdaVecFromX(x) == [1, 2, 3, 1, 2, 3, 4, 5, 6, 4, 5, 6]);
}
  
// unittest {
//   import std.random;
//   writeln("test maximization step");
//   auto lambdaVec = new double[12];
//   lambdaVec[] = 1.0;
//   auto params = new MSMCmodel(0.01, 0.001, [0UL, 0, 1, 1], lambdaVec, 4, 4, false);
// 
//   auto expectationMatrix = new double[][](12, 12);
//   foreach(i; 0 .. 12) foreach(j; 0 .. 12)
//     expectationMatrix[i][j] = params.transitionRate.transitionProbabilityMarginal(i, j) * uniform(700, 1300);
//   auto timeSegmentPattern = [2UL, 2];
//   auto updatedParams = getMaximization(expectationMatrix, params, timeSegmentPattern, false, true);
//     
//   writeln("Maximization test: actual params: ", params);
//   writeln("Maximization test: inferred params: ", updatedParams);
// }
