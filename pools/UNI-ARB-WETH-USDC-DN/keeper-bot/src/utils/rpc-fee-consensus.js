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

function freshBlock(block) {
  return block && /^0x[0-9a-f]{64}$/i.test(String(block.hash || ''))
    && Number.isSafeInteger(Number(block.timestamp))
    && Math.abs(Math.floor(Date.now() / 1000) - Number(block.timestamp)) <= 120;
}

async function matchingFeeBlock(providers) {
  // A provider that cannot quote fees can still corroborate the chain head.
  // Do not anchor the quorum to the first (possibly divergent) provider.
  const blocks = await Promise.all(providers.map(provider => typeof provider?.getBlock === 'function'
    ? provider.getBlock('latest').catch(() => null) : null));
  for (let index = 0; index < blocks.length; index++) {
    const block = blocks[index];
    if (!freshBlock(block)) continue;
    const indexes = blocks.map((candidate, candidateIndex) => freshBlock(candidate)
      && candidate.hash.toLowerCase() === block.hash.toLowerCase()
      && Number(candidate.number) === Number(block.number)
      && BigInt(candidate.baseFeePerGas || 0n) === BigInt(block.baseFeePerGas || 0n)
      ? candidateIndex : -1).filter(candidateIndex => candidateIndex >= 0);
    if (indexes.length >= 2) return { block, indexes };
  }
  return null;
}

function feeFromBaseFee(block, observation) {
  const baseFee = BigInt(block?.baseFeePerGas || 0n);
  if (!freshBlock(block) || baseFee <= 0n) return null;
  const proposedPriority = BigInt(observation?.maxPriorityFeePerGas || 0n);
  const priority = proposedPriority > 0n && proposedPriority < baseFee * 2n
    ? proposedPriority : baseFee * 2n;
  return { gasPrice: null, maxFeePerGas: baseFee * 3n + priority,
    maxPriorityFeePerGas: priority };
}

async function readFeeConsensus(providers, read, required = 2,
  { hfEmergency = false, configuredSourceCount = providers.length } = {}) {
  for (let attempt = 0; attempt < 2; attempt++) {
    const values = await Promise.all(providers.map(async provider => {
      try { return await read(provider); } catch { return null; }
    }));
    try {
      return corroborateNumbers(values, required);
    } catch (error) {
      if (hfEmergency && configuredSourceCount >= 3 && values.filter(value => value != null).length === 1) {
        const index = values.findIndex(value => value != null);
        const block = typeof providers[index]?.getBlock === 'function'
          ? await providers[index].getBlock('latest') : null;
        const estimate = BigInt(values[index]);
        if (freshBlock(block) && block?.gasLimit && estimate > 0n
            && estimate * 120n / 100n <= BigInt(block.gasLimit)) {
          return estimate;
        }
      }
      if (hfEmergency && error.message === 'RPC estimates disagree' && attempt === 1) {
        const matching = await matchingFeeBlock(providers);
        const estimate = (matching?.indexes || []).reduce((max, index) => values[index] != null
          && BigInt(values[index]) > max ? BigInt(values[index]) : max, 0n);
        if (matching?.block?.gasLimit && estimate > 0n
            && estimate * 120n / 100n <= BigInt(matching.block.gasLimit)) {
          return estimate;
        }
      }
      // A fresh estimate resolves short-lived state races without accepting a
      // lone quote or imposing an arbitrary HF gas ceiling.
      if (attempt === 1 || error.message !== 'RPC estimates disagree') throw error;
    }
  }
}

async function readFeeDataConsensus(providers, read, required = 2,
  { hfEmergency = false, configuredSourceCount = providers.length } = {}) {
  const observations = await Promise.all(providers.map(async provider => {
    try { return await read(provider); } catch { return null; }
  }));
  if (hfEmergency && configuredSourceCount >= 3 && observations.filter(Boolean).length === 1) {
    const index = observations.findIndex(Boolean);
    const block = typeof providers[index]?.getBlock === 'function'
      ? await providers[index].getBlock('latest') : null;
    const fallback = feeFromBaseFee(block, observations[index]);
    if (fallback) return fallback;
  }
  const quote = field => {
    const values = observations.filter(Boolean).map(value => value[field]);
    if (values.filter(value => value != null).length < required) return null;
    try { return corroborateNumbers(values, required); } catch { return null; }
  };
  // A type-2 transaction does not consume the legacy gasPrice. A disagreement
  // on that unused field must not stop an otherwise corroborated HF repair.
  const maxFeePerGas = quote('maxFeePerGas');
  const maxPriorityFeePerGas = quote('maxPriorityFeePerGas');
  if (maxFeePerGas != null && maxPriorityFeePerGas != null) {
    return { gasPrice: quote('gasPrice'), maxFeePerGas, maxPriorityFeePerGas };
  }
  const gasPrice = quote('gasPrice');
  if (gasPrice != null) return { gasPrice, maxFeePerGas: null, maxPriorityFeePerGas: null };
  if (hfEmergency && configuredSourceCount >= 3 && observations.filter(Boolean).length >= 2) {
    const matching = await matchingFeeBlock(providers);
    const quotedIndex = matching?.indexes.find(index => observations[index]);
    const fallback = quotedIndex === undefined ? null
      : feeFromBaseFee(matching.block, observations[quotedIndex]);
    if (fallback) return fallback;
  }
  throw new Error('RPC fee quorum unavailable');
}

module.exports = { corroborateNumbers, readFeeConsensus, readFeeDataConsensus };
