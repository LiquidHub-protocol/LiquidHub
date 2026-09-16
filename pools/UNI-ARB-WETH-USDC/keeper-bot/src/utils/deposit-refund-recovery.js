'use strict';

const { Contract } = require('ethers');
const VAULT_RECOVERY_ABI = [
  'function getNextPendingDeposit() view returns(address user,uint256 amount0,uint256 amount1,uint256 timestamp,bool exists)',
  'function depositRefundDelay() view returns(uint256)',
  'function dnDepositRefundDelay() view returns(uint256)',
  'function initialPositionEstablished() view returns(bool)',
  'function isRebalancing() view returns(bool)',
  'function refundStaleDeposit(address depositor)',
];
const PAUSE_ABI = ['function inflowsPaused() view returns(bool)'];
const MIN_FAILURE_SECONDS = 600;

function isConfirmedEvmRevert(error) {
  if (error?.code !== 'CALL_EXCEPTION' || !['call', 'estimateGas'].includes(error.action)) return false;
  // ethers also wraps JSON-RPC infrastructure errors in CALL_EXCEPTION. Its
  // generated message (including "missing revert data") is not EVM evidence.
  const rpcError = error.info?.error;
  const rpcMessage = typeof rpcError?.message === 'string' ? rpcError.message : '';
  const explicitRevert = /^(?:execution reverted\b|VM Exception while processing transaction:\s*revert\b)/i.test(rpcMessage.trim());
  if (!explicitRevert && rpcError && (
    [-32700, -32600, -32601, -32602, -32603, -32002, -32005, 429, 500, 502, 503, 504].includes(Number(rpcError.code))
    || /\b(?:internal (?:server )?error|timeout|timed out|rate limit|too many requests|unavailable)\b/i.test(rpcMessage)
  )) return false;
  if (typeof error.data === 'string' && /^0x(?:[0-9a-f]{2})+$/i.test(error.data)) return true;
  // An empty Solidity revert remains usable when the RPC explicitly reports it.
  return (error.data == null || error.data === '0x')
    && Boolean(rpcError && (Number(rpcError.code) === 3 || explicitRevert));
}

function markDepositSimulationError(error) {
  // Only an actual deposit eth_call revert is evidence; not RPC, gas or broadcast errors.
  if (error && typeof error === 'object') {
    delete error.depositSimulationReverted;
    if (error.action === 'call' && isConfirmedEvmRevert(error)) error.depositSimulationReverted = true;
  }
  return error;
}

async function readRecoverySnapshot({ rpcPool, vaultAddress, pauseControllerAddress, strategyEngine, isDn }) {
  return rpcPool.executeWithRetry(async provider => {
    const block = await provider.getBlock('latest');
    const at = { blockTag: block.number };
    const vault = new Contract(vaultAddress, VAULT_RECOVERY_ABI, provider);
    const engine = strategyEngine.connect(provider);
    const [head, delay] = await Promise.all([
      vault.getNextPendingDeposit(at), vault[isDn ? 'dnDepositRefundDelay' : 'depositRefundDelay'](at),
    ]);
    const key = head.exists ? [head.user.toLowerCase(), head.timestamp, head.amount0, head.amount1].map(String).join(':') : null;
    const snapshot = { key, user: head.user, now: Number(block.timestamp), eligible: false };
    // Ordinary young deposits do not need additional maintenance/governance reads.
    if (!head.exists || BigInt(delay) <= 0n || BigInt(block.timestamp) < BigInt(head.timestamp) + BigInt(delay)) return snapshot;
    const [initialized, locked, paused, decision, due] = await Promise.all([
      vault.initialPositionEstablished(at), vault.isRebalancing(at),
      new Contract(pauseControllerAddress, PAUSE_ABI, provider).inflowsPaused(at),
      engine.previewDecision(at), engine.checkpointDue(at),
    ]);
    snapshot.eligible = Boolean(initialized && !locked && !paused && decision.dataFresh && !due
      && [0, 1].includes(Number(decision.action)));
    return snapshot;
  });
}

async function processDepositWithRecovery(options) {
  const { state, attempt, simulate, readSnapshot, sendRefund } = options;
  const reset = () => { delete state.key; delete state.first; delete state.last; delete state.failures; delete state.proofVersion; };
  // Counters saved before explicit EVM classification are not proof of reverts.
  if (state.key && (state.proofVersion !== 1 || ![state.first, state.last, state.failures].every(Number.isSafeInteger)
    || state.first < 0 || state.last < state.first || state.failures < 1)) reset();
  let before = null;
  try { before = await readSnapshot(); } catch { /* Monitoring must not prevent a normal deposit. */ }
  let result, error;
  try { result = await attempt(); } catch (caught) { error = caught; }
  const original = () => { if (error) throw error; return result; };
  if (!(error?.depositSimulationReverted || result?.simulationReverted)
    || result?.stateMayHaveChanged || result?.deferred || result?.deferredForMaintenance || !before?.eligible) {
    reset(); return original();
  }
  let after;
  try { after = await readSnapshot(); } catch { reset(); return original(); }
  if (!after.eligible || after.key !== before.key) { reset(); return original(); }
  if (state.key !== after.key || after.now < state.last) {
    reset(); Object.assign(state, { key: after.key, first: after.now, last: after.now, failures: 1, proofVersion: 1 });
  } else if (after.now - state.last >= 60) {
    state.last = after.now; state.failures++;
  }
  if (state.failures < 3 || after.now - state.first < MIN_FAILURE_SECONDS) return original();
  const key = after.key;
  const guarded = async () => {
    const current = await readSnapshot();
    if (!current.eligible || current.key !== key) throw Object.assign(new Error('Deposit recovery deferred: head or maintenance changed'), { code: 'DEPOSIT_RECOVERY_DEFERRED' });
    let stillFails = false;
    try { await simulate(); } catch (failure) {
      if (!failure?.depositSimulationReverted) throw failure;
      stillFails = true;
    }
    if (!stillFails) throw Object.assign(new Error('Deposit is processable again; normal processing takes priority'), { code: 'DEPOSIT_RECOVERY_DEFERRED' });
    const latest = await readSnapshot();
    if (!latest.eligible || latest.key !== key) throw Object.assign(new Error('Deposit recovery head changed'), { code: 'DEPOSIT_RECOVERY_DEFERRED' });
  };
  try {
    const receipt = await sendRefund(after.user, guarded);
    reset();
    const hash = receipt.hash || receipt.transactionHash;
    return { success: true, refunded: true, txHash: hash, txHashes: [hash] };
  } catch (failure) {
    reset();
    if (failure?.code === 'DEPOSIT_RECOVERY_DEFERRED') return { success: false, deferred: true, deferredForMaintenance: true, error: failure.message, txHashes: [] };
    throw failure; // Preserve signed-transaction uncertainty and the existing nonce recovery.
  }
}

async function sendDepositRefund({ rpcPool, walletForProvider, vaultAddress }, user, guard) {
  return rpcPool.executeSignedTxWithRetry(async provider => {
    await guard();
    const wallet = walletForProvider(provider);
    const vault = new Contract(vaultAddress, VAULT_RECOVERY_ABI, wallet);
    // Bind the depositor in calldata: a different head can never be refunded by a race.
    await vault.refundStaleDeposit.staticCall(user);
    const request = await vault.refundStaleDeposit.populateTransaction(user);
    const [gas, block] = await Promise.all([
      provider.estimateGas({ ...request, from: wallet.address }), provider.getBlock('latest'),
    ]);
    if (gas >= BigInt(block.gasLimit)) throw new Error('Deposit refund exceeds the block gas limit');
    const buffered = gas + gas / 5n;
    request.gasLimit = buffered < BigInt(block.gasLimit) ? buffered : BigInt(block.gasLimit) - 1n;
    return { wallet, request };
  }, 'refundStaleDeposit');
}

module.exports = { isConfirmedEvmRevert, markDepositSimulationError, processDepositWithRecovery, readRecoverySnapshot, sendDepositRefund };
