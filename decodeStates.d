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
 
import std.stdio;
import std.getopt;
import std.exception;
import std.c.stdlib;
import std.algorithm;
import std.parallelism;
import std.string;
import std.typecons;
import std.regex;
import std.conv;
import std.range;
import std.math;
import model.msmc_hmm;
import model.data;
import model.time_intervals;
import model.msmc_model;
import model.propagation_core_fastImpl;
import branchlength;
import model.triple_index;
import model.stateVec;


double mutationRate, recombinationRate;
size_t nrTimeSegments=40, nrTtotSegments=40;
string inputFileName;
size_t nrHaplotypes;
string treeFileName;
bool onlySim;

void main(string[] args) {
  try {
    parseCommandlineArgs(args);
  }
  catch (Exception e) {
    stderr.writeln(e.msg);
    displayHelpMessage();
    exit(0);
  }
  run();
}

void parseCommandlineArgs(string[] args) {
  getopt(args,
         std.getopt.config.caseSensitive,
         "mutationRate|m", &mutationRate,
         "recombinationRate|r", &recombinationRate,
         "nrTimeSegments|t", &nrTimeSegments,
         "nrTtotSegments|T", &nrTtotSegments,
         "onlySim", &onlySim);

  enforce(args.length == 3, "need one site-file and one tree file");
  inputFileName = args[1];
  treeFileName = args[2];
  nrHaplotypes = getNrHaplotypesFromFile(inputFileName);
  enforce(mutationRate > 0, "need positive mutationRate");
  enforce(recombinationRate > 0, "need positive recombinationRate");
}

void displayHelpMessage() {
  stderr.writeln("Usage: decodeStates [options] <site_file> <tree_file> 
Options:
-m, --mutationRate <double>
-r, --recombinationRate <double>
-t, --nrTimeSegments <int>
-T, --nrTtotSegments <int>
--onlySim");
}

void run() {
  
  auto subpopLabels = new size_t[nrHaplotypes];
  auto model = MSMCmodel.withTrivialLambda(mutationRate, recombinationRate, subpopLabels, nrTimeSegments, nrTtotSegments);
  
  auto segsites = readSegSites(inputFileName);
  auto chr = File(inputFileName, "r").byLine().front().strip().split()[0].dup;
  
  MSMC_hmm hmm;
  State_t forwardState, backwardState;
  if(!onlySim) {
    hmm = makeHMM(model, segsites);
    stderr.writeln("running HMM");
    hmm.runForward();
    forwardState = hmm.propagationCore.newForwardState();
    backwardState = hmm.propagationCore.newBackwardState();
  }
  
  writeln("chr\tpos\talleles\ttype\tt\ttState\tT\tTState\ttSim\ttSimState\tTSim\tTSimState");
  
  auto allele_order = canonicalAlleleOrder(nrHaplotypes);
  auto missingAlleleString = new char[nrHaplotypes];
  missingAlleleString[] = '?';
  
  string[] outputLines;
  auto simStateParser = new SimStateParser(treeFileName, nrTimeSegments, nrTtotSegments);
  foreach_reverse(segsite; segsites) {
    double t, tTot;
    size_t tState;

    if(!onlySim) {
      hmm.getForwardState(forwardState, segsite.pos);
      hmm.getBackwardState(backwardState, segsite.pos);

      auto posterior = forwardState.vec.dup;
      posterior[] *= backwardState.vec[];
      // stderr.writeln(segsite.pos, "\t", forwardState.vec[0..5], "\t", backwardState.vec[0..5]);
      assert(!posterior.reduce!"a+b"().isnan());
      
      tState = getMaxPosterior(posterior);
      auto tMarginalState = model.marginalIndex.getMarginalIndexFromIndex(tState);
      t = model.timeIntervals.meanTime(tMarginalState, nrHaplotypes);
      tTot = model.tTotIntervals.meanTime(segsite.i_Ttot, 2);
    }
    
    auto tSimPair = simStateParser.getFirstPair(segsite.pos);
    auto tSim = tSimPair[0];
    auto tSimInterval = model.timeIntervals.findIntervalForTime(tSim);
    auto tSimState = model.marginalIndex.getIndexFromTriple(Triple(tSimInterval, tSimPair[1], tSimPair[2]));
    auto tTotSim = simStateParser.getTtot(segsite.pos);
    auto tTotSimState = model.tTotIntervals.findIntervalForTime(tTotSim);
    auto al = segsite.obs[0] > 0 ? allele_order[segsite.obs[0] - 1] : missingAlleleString;
    
    auto eType = getEmissionType(al.idup, tSimPair[1], tSimPair[2]);
    
    outputLines ~= format("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", chr, segsite.pos, al, eType, t, 
                          tState, tTot, segsite.i_Ttot, tSim, tSimState, tTotSim, tTotSimState);
  }
  
  foreach_reverse(line; outputLines) {
    writeln(line);
  }
}

MSMC_hmm makeHMM(MSMCmodel model, SegSite_t[] segsites) {

  stderr.writeln("generating propagation core");
  auto propagationCore = new PropagationCoreFast(model, 1000);
  
  stderr.writeln("estimating branchlengths");
  // estimateTotalBranchlengths(segsites, model, nrTtotSegments);
  readTotalBranchlengths(segsites, model, nrTtotSegments, treeFileName);

  stderr.writeln("generating Hidden Markov Model");
  return new MSMC_hmm(propagationCore, segsites);
}

size_t getMaxPosterior(double[] posterior) {
  size_t maxIndex = 0;
  double max = posterior[maxIndex];
  foreach(i, p; posterior[1 .. $]) {
    if(p > max) {
      maxIndex = i + 1;
      max = p;
    }
  }
  return maxIndex;
}

class SimStateParser {
  
  Tuple!(size_t, double, size_t, size_t, double)[] data;
  size_t lastIndex;
  
  this(string treeFileName, size_t nrTimeSegments, size_t nrTtotSegments) {
    
    stderr.writeln("reading tree file ", treeFileName);
    auto treeFile = File(treeFileName, "r");
    auto pos = 0UL;
    foreach(line; treeFile.byLine) {
      auto fields = line.strip().split();
      auto l = fields[0].to!size_t;
      auto str = fields[1];
      auto tFirst = getFirst(str);
      auto tTot = getTotalLeafLength(str);
      // stderr.writeln(str, " ", tTot);
      pos += l;
      data ~= tuple(pos, tFirst[0], tFirst[1], tFirst[2], tTot);
    }
  }
  
  auto getFirstPair(size_t pos) {
    auto index = getIndex(pos);
    auto a = data[index][1];
    auto i = data[index][2];
    auto j = data[index][3];
    return tuple(a, i, j);
  }
  
  double getTtot(size_t pos) {
    auto index = getIndex(pos);
    return data[index][4];
  }

  private size_t getIndex(size_t pos) {
    while(data[lastIndex][0] < pos)
      lastIndex += 1;
    while(lastIndex > 0 && data[lastIndex - 1][0] >= pos)
      lastIndex -= 1;
    return lastIndex;
  }
  
}

private auto getFirst(in char[] str) {
  static auto tfirstRegex = regex(r"\((\d+):([\d\.e-]+),(\d+):[\d\.e-]+\)", "g");
  
  auto matches = match(str, tfirstRegex);
  auto triples = matches.map!(m => tuple(2.0 * m.captures[2].to!double(),
                                         m.captures[1].to!size_t(),
                                         m.captures[3].to!size_t()))();
  auto min_triple = triples.minCount!"a[0] < b[0]"()[0];
  if(min_triple[1] > min_triple[2])
    swap(min_triple[1], min_triple[2]);
  return min_triple;
}

version(unittest) {
  import std.math;
} 

unittest {

  auto tree = "(5:0.1,((2:8.1,1:8.1):0.1,((4:0.1,0:0.1):0.004,3:0.1):0.004):0.01);";
  auto f = getFirst(tree);
  assert(approxEqual(f[0], 2.0 * 0.1, 0.00001, 0.0));
  assert(f[1] == 0);
  assert(f[2] == 4);
  tree = "((((2:8.3,1:8.3):0.12,(0:0.11,3:0.11):0.004):0.0046,4:0.12):1.06,5:1.19);";
  f = getFirst(tree);
  assert(approxEqual(f[0], 2.0 * 0.11, 0.00001, 0.0));
  assert(f[1] == 0);
  assert(f[2] == 3);
}

private double getTotalBranchLength(in char[] str) {
  static auto tTotRegex = regex(r":([\d+\.e-]+)", "g");

  auto matches = match(str, tTotRegex);
  auto times = matches.map!(m => m.captures[1].to!double());
  auto sum = 2.0 * times.reduce!"a+b"();
  return sum;
}

unittest {
  auto tree = "(5:0.1,((2:8.1,1:8.1):0.1,((4:0.1,0:0.1):0.004,3:0.1):0.004):0.01);";
  assert(approxEqual(getTotalBranchLength(tree), 2.0 * 16.718, 0.00001, 0.0));
  tree = "((((2:8.3,1:8.3):0.12,(0:0.11,3:0.11):0.004):0.0046,4:0.12):1.06,5:1.19);";
  assert(approxEqual(getTotalBranchLength(tree), 2.0 * 19.3186, 0.0001, 0.0));
}


double getTotalLeafLength(in char[] str) {
  static auto tTotRegex = regex(r"\d+:([\d+\.e-]+)", "g");

  auto matches = match(str, tTotRegex);
  auto times = matches.map!(m => m.captures[1].to!double());
  auto sum = 2.0 * times.reduce!"a+b"();
  return sum;
}

unittest {
  auto tree = "(5:0.1,((2:8.1,1:8.1):0.1,((4:0.1,0:0.1):0.004,3:0.1):0.004):0.01);";
  assert(approxEqual(getTotalLeafLength(tree), 2.0 * 16.6, 0.0001, 0.0));
  tree = "((((2:8.3,1:8.3):0.122683,(0:0.11,3:0.11):0.00415405):0.00462688,4:0.12):1.06837,5:1.19);";
  assert(approxEqual(getTotalLeafLength(tree), 2.0 * 18.13, 0.0001, 0.0));
}

string getEmissionType(string alleles, size_t ind1, size_t ind2) {
  auto count_0 = count(alleles, '0');
  auto count_1 = alleles.length - count_0;
  if(count_0 == 0 || count_1 == 0)
    return "noMut";
  if(count_0 == 1 || count_1 == 1) {
    if(alleles[ind1] == alleles[ind2])
      return "singletonOutside";
    else
      return "singletonInside";
  }
  if(alleles[ind1] == alleles[ind2])
    return "multiton";
  return "doubleMut";
}