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

MSMCmodel getMaximization(double[] eVec, double[][] eMat, size_t[] alleleCounts, MSMCmodel params,
                          in size_t[] timeSegmentPattern, bool fixedPopSize, bool fixedRecombination)
{
  auto minFunc = new MinFunc(eVec, eMat, alleleCounts, params, timeSegmentPattern, fixedPopSize, fixedRecombination);

  auto powell = new Powell!MinFunc(minFunc);
  auto x = minFunc.initialValues();
  auto startVal = minFunc(x);
  auto xNew = powell.minimize(x);
  auto endVal = minFunc(xNew);
  logInfo(format(", Q-function before: %s, after:%s\n", startVal, endVal));
  return minFunc.makeParamsFromVec(xNew);
}

class MinFunc {
  
  MSMCmodel initialParams;
  const size_t[] timeSegmentPattern;
  size_t nrSubpopPairs, nrParams;
  const double[] expectationResultVec;
  const double[][] expectationResultMat;
  const size_t[] alleleCounts;
  bool fixedPopSize, fixedRecombination;
  
  this(in double[] expectationResultVec, in double[][] expectationResultMat, in size_t[] alleleCounts, 
       MSMCmodel initialParams, in size_t[] timeSegmentPattern, bool fixedPopSize, bool fixedRecombination)
  {
    this.initialParams = initialParams;
    this.timeSegmentPattern = timeSegmentPattern;
    this.expectationResultVec = expectationResultVec;
    this.expectationResultMat = expectationResultMat;
    this.alleleCounts = alleleCounts;
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
    MSMCmodel newParams = makeParamsFromVec(x);
    return -logLikelihood(newParams);
  };
  
  double[] initialValues()
  out(x) {
    assert(x.length == nrParams);
  }
  body {
    auto x = getXfromLambdaVec(initialParams.lambdaVec);
    if(!fixedRecombination)
      x ~= log(initialParams.recombinationRate);
    return x;
  }
  
  double[] getXfromLambdaVec(double[] lambdaVec)
  out(x) {
    if(fixedPopSize)
      assert(x.length == timeSegmentPattern.length * (nrSubpopPairs - initialParams.nrSubpopulations));
    else
      assert(x.length == timeSegmentPattern.length * nrSubpopPairs);
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
        if(p1 == p2) {
          if(!fixedPopSize) {
            ret ~= log(lambdaVec[lIndex]);
          }
        }
        else {
          auto marginalIndex1 = initialParams.marginalIndex.subpopulationTripleToMarginalIndexMap[triple.time][p1][p1];
          auto marginalIndex2 = initialParams.marginalIndex.subpopulationTripleToMarginalIndexMap[triple.time][p2][p2];
          auto lambda1 = lambdaVec[marginalIndex1];
          auto lambda2 = lambdaVec[marginalIndex2];
          auto lambda12 = lambdaVec[lIndex];
          if(lambda12 >= 0.5 * (lambda1 + lambda2))
            lambda12 = 0.4999999999 * (lambda1 + lambda2);
          auto ratio = 2.0 * lambda12 / (lambda1 + lambda2);
          ret ~= tan(ratio * PI - PI_2);
        }
      }
      count += nrIntervalsInSegment;
    }
    return ret;
  }
  
  MSMCmodel makeParamsFromVec(in double[] x) {
    auto lambdaVec = fixedPopSize ? getLambdaVecFromXfixedPop(x) : getLambdaVecFromX(x);
    auto recombinationRate = fixedRecombination ? initialParams.recombinationRate : getRecombinationRateFromX(x);
    return new MSMCmodel(initialParams.mutationRate, recombinationRate, initialParams.subpopLabels, lambdaVec, initialParams.nrTimeIntervals, initialParams.nrTtotIntervals, initialParams.emissionRate.directedEmissions);
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
            auto marginalIndex1 = 
                initialParams.marginalIndex.subpopulationTripleToMarginalIndexMap[triple.time][p1][p1];
            auto marginalIndex2 = 
                initialParams.marginalIndex.subpopulationTripleToMarginalIndexMap[triple.time][p2][p2];
            auto lambda1 = lambdaVec[marginalIndex1];
            auto lambda2 = lambdaVec[marginalIndex2];
            auto ratio = (atan(x[segmentIndex * valuesPerTime + xIndex]) + PI_2) / PI;
            lambdaVec[lIndex] = ratio * 0.5 * (lambda1 + lambda2);
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
          lambdaVec[lIndex] = exp(x[xIndex]);
        }
        foreach(subpopPairIndex; 0 .. nrSubpopPairs) {
          auto lIndex = timeIndex * nrSubpopPairs + subpopPairIndex;
          auto tripleIndex = initialParams.marginalIndex.getIndexFromMarginalIndex(lIndex);
          auto triple = initialParams.marginalIndex.getTripleFromIndex(tripleIndex);
          auto p1 = initialParams.subpopLabels[triple.ind1];
          auto p2 = initialParams.subpopLabels[triple.ind2];

          if(p1 != p2) {
            auto xIndex = segmentIndex * nrSubpopPairs + subpopPairIndex;
            auto marginalIndex1 = 
                initialParams.marginalIndex.subpopulationTripleToMarginalIndexMap[triple.time][p1][p1];
            auto marginalIndex2 = 
                initialParams.marginalIndex.subpopulationTripleToMarginalIndexMap[triple.time][p2][p2];
            auto lambda1 = lambdaVec[marginalIndex1];
            auto lambda2 = lambdaVec[marginalIndex2];
            auto ratio = (atan(x[xIndex]) + PI_2) / PI;
            lambdaVec[lIndex] = ratio * 0.5 * (lambda1 + lambda2);
          }
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
    return exp(x[$ - 1]);
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
    foreach(i, a; alleleCounts)
      ret += cast(double)a * log(params.emissionRate.equilibriumEmissionProb(cast(int)i));
    return ret;
  }
}

unittest {
  writeln("test minfunc.getLambdaFromX");
  import std.conv;
  
  auto lambdaVec = [1, 1.5, 3, 1, 1.5, 3, 4, 4.5, 6, 4, 4.5, 6];
  auto params = new MSMCmodel(0.01, 0.001, [0U, 0, 1, 1], lambdaVec, 4, 4, false);
  auto expectationResultVec = new double[params.nrMarginals];
  auto expectationResultMat = new double[][](params.nrMarginals, params.nrMarginals);
  auto alleleCounts = new size_t[cast(int)(params.nrHaplotypes / 2)];
  auto timeSegmentPattern = [2UL, 2];
  
  auto minFunc = new MinFunc(expectationResultVec, expectationResultMat, alleleCounts, params,  
                             timeSegmentPattern, false, false);
  auto rho = 0.001;
  auto x = minFunc.getXfromLambdaVec(lambdaVec);
  x ~= log(rho);
  auto lambdaFromX = minFunc.getLambdaVecFromX(x);
  auto rhoFromX = minFunc.getRecombinationRateFromX(x);
  foreach(i; 0 .. lambdaVec.length)
    assert(approxEqual(lambdaFromX[i], lambdaVec[i], 1.0e-8, 0.0), text(lambdaFromX[i], " ", lambdaVec[i]));
  assert(approxEqual(rhoFromX, rho, 1.0e-8, 0.0), text([rhoFromX, rho]));

  minFunc = new MinFunc(expectationResultVec, expectationResultMat, alleleCounts, params, 
                        timeSegmentPattern, true, false);
  x = minFunc.getXfromLambdaVec(lambdaVec);
  x ~= log(rho);
  lambdaFromX = minFunc.getLambdaVecFromXfixedPop(x);
  rhoFromX = minFunc.getRecombinationRateFromX(x);
  foreach(i; 0 .. lambdaVec.length)
    assert(approxEqual(lambdaFromX[i], lambdaVec[i], 1.0e-8, 0.0), text(lambdaFromX[i], " ", lambdaVec[i]));
  assert(approxEqual(rhoFromX, rho, 1.0e-8, 0.0));

  minFunc = new MinFunc(expectationResultVec, expectationResultMat, alleleCounts, params, 
                        timeSegmentPattern, false, true);
  x = minFunc.getXfromLambdaVec(lambdaVec);
  lambdaFromX = minFunc.getLambdaVecFromX(x);
  foreach(i; 0 .. lambdaVec.length)
    assert(approxEqual(lambdaFromX[i], lambdaVec[i], 1.0e-8, 0.0), text(lambdaFromX[i], " ", lambdaVec[i]));
}
  
// unittest {
//   import std.random;
//   writeln("test maximization step");
//   auto lambdaVec = new double[12];
//   lambdaVec[] = 1.0;
//   auto params = new MSMCmodel(0.01, 0.001, [0UL, 0, 1, 1], lambdaVec, 4, 4);
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
