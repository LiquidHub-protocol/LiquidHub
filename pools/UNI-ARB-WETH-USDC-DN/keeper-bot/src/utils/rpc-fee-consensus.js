'use strict';

// No absolute gas ceiling: reject a lone outlier, not a genuinely expensive
// emergency. The quorum is determined by configuration, never by survivors.
function corroborateNumbers(values, required = 2) {
  const sorted = values.filter(value => value !== null && value !== undefined)
    .map(BigInt).filter(value => value >= 0n).sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
  if (sorted.length < required) throw new Error('RPC estimate quorum unavailable');
  if (sorted.length === 1) return sorted[0];
  if (sorted.length === 2 && sorted[1] * 100n > sorted[0] * 125n) {
    throw new Error('RPC estimates disagree');
  }
  return sorted[Math.floor(sorted.length / 2)];
}

async function readFeeConsensus(providers, read, required = 2) {
  for (let attempt = 0; attempt < 2; attempt++) {
    const values = await Promise.all(providers.map(async provider => {
      try { return await read(provider); } catch { return null; }
    }));
    try {
      return corroborateNumbers(values, required);
    } catch (error) {
      // A fresh estimate resolves short-lived state races without accepting a
      // lone quote or imposing an arbitrary HF gas ceiling.
      if (attempt === 1 || error.message !== 'RPC estimates disagree') throw error;
    }
  }
}

async function readFeeDataConsensus(providers, read, required = 2) {
  const observations = await Promise.all(providers.map(async provider => {
    try { return await read(provider); } catch { return null; }
  }));
  const result = {};
  // A corroborated legacy gasPrice is an independent safe fallback when only
  // an EIP-1559 subfield disagrees. Do not let a partial 1559 quote suppress
  // the HF repair lane; nonce/receipt quorum remains unchanged.
  for (const field of ['gasPrice', 'maxFeePerGas', 'maxPriorityFeePerGas']) {
    const values = observations.filter(Boolean).map(value => value[field]);
    if (values.filter(value => value != null).length < required) {
      result[field] = null;
      continue;
    }
    try {
      result[field] = corroborateNumbers(values, required);
    } catch (error) {
      if (field === 'gasPrice' || result.gasPrice == null) throw error;
      result[field] = null;
    }
  }
  if (result.maxFeePerGas == null || result.maxPriorityFeePerGas == null) {
    result.maxFeePerGas = null;
    result.maxPriorityFeePerGas = null;
    if (result.gasPrice == null) throw new Error('RPC fee quorum unavailable');
  }
  return result;
}

module.exports = { corroborateNumbers, readFeeConsensus, readFeeDataConsensus };
