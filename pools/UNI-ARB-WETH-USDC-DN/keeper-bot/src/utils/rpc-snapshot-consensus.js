'use strict';

// Financial values must be compared at the same recent chain state. Caller-owned
// timeouts and chain authentication are retained; this helper never sends a tx.
async function readSnapshotConsensus({
    entries, read, keyOf, withTimeout, authenticate = async () => {},
    allowSingle = false, allowLastSurvivor = false, configuredSourceCount = entries.length,
    label, errorCode, reduceValues, headLag = 1, emergencyPositive,
    onEntryFailure = () => {}, onEntrySuccess = () => {},
}) {
    if (typeof keyOf !== 'function') throw new Error(`${label}: consensus key function is required`);
    // JsonRpcProvider.getBlock briefly caches identical requests. Header reads must
    // bypass that cache so the post-read check can actually detect a reorganization.
    const header = async (provider, tag) => {
        const block = await provider.send('eth_getBlockByNumber', [
            tag === 'latest' ? tag : `0x${tag.toString(16)}`, false,
        ]);
        return block && { number: Number(block.number), hash: block.hash, timestamp: Number(block.timestamp) };
    };
    const validHeader = (block, number) => block
        && Number.isSafeInteger(block.number) && block.number >= 0
        && (number === undefined || block.number === number)
        && /^0x[0-9a-f]{64}$/i.test(block.hash || '')
        && Number.isSafeInteger(block.timestamp)
        && block.timestamp >= Math.floor(Date.now() / 1000) - 120
        && block.timestamp <= Math.floor(Date.now() / 1000) + 30;
    const heads = (await Promise.all(entries.map(async (entry) => {
        try {
            return await withTimeout(async () => {
                await authenticate(entry);
                const block = await header(entry.provider, 'latest');
                if (!validHeader(block)) {
                    onEntryFailure(entry);
                    return null;
                }
                onEntrySuccess(entry);
                return { entry, number: block.number };
            });
        } catch { onEntryFailure(entry); return null; }
    }))).filter(Boolean).sort((a, b) => b.number - a.number);
    // Reserved for an explicitly selected emergency action. Never downgrade a
    // disagreement between two live sources; only a sole authenticated source
    // may be used, with the same recent-header before/after checks below.
    const headQuorum = (allowSingle && entries.length === 1)
        || (allowLastSurvivor && configuredSourceCount >= 3 && heads.length === 1) ? 1 : 2;
    let emergencyObservation = null;
    if (heads.length >= headQuorum) {
        // Start at/just behind the quorum head. A single outlier cannot pick a far
        // future/old block. One bounded fallback tolerates a more delayed source.
        const heights = new Set([
            Math.max(0, heads[headQuorum - 1].number - headLag),
            heads[heads.length - 1].number,
        ]);
        for (const blockTag of heights) {
            const observations = (await Promise.all(heads.map(async ({ entry }) => {
                try {
                    return await withTimeout(async () => {
                        const before = await header(entry.provider, blockTag);
                        if (!validHeader(before, blockTag)) {
                            onEntryFailure(entry);
                            return null;
                        }
                        const value = await read(entry.provider, blockTag);
                        const after = await header(entry.provider, blockTag);
                        if (!validHeader(after, blockTag) || before.hash.toLowerCase() !== after.hash.toLowerCase()) {
                            onEntryFailure(entry);
                            return null;
                        }
                        const key = String(keyOf(value));
                        if (!key) { onEntryFailure(entry); return null; }
                        onEntrySuccess(entry);
                        return { key: `${before.hash.toLowerCase()}:${key}`, value };
                    });
                } catch { onEntryFailure(entry); return null; }
            }))).filter(Boolean);
            const quorum = headQuorum;
            const groups = new Map();
            for (const observation of observations) {
                const count = (groups.get(observation.key) || 0) + 1;
                groups.set(observation.key, count);
                if (count >= quorum) {
                    const agreed = reduceValues
                        ? reduceValues(observations.filter(item => item.key === observation.key).map(item => item.value))
                        : observation.value;
                    // One surviving premium may safely request an atomic,
                    // on-chain guarded HF repair. Its negative answer is not
                    // sufficient to certify that the position is healthy.
                    if (allowLastSurvivor && configuredSourceCount >= 3 && quorum === 1
                        && emergencyPositive && !emergencyPositive(agreed)) continue;
                    return agreed;
                }
            }
            // Two authenticated premium sources must agree on the block hash,
            // even when their Aave values disagree. A positive signal can then
            // trigger only the exact atomic on-chain repair, never an ordinary
            // hedge or a conclusion that repair is unnecessary.
            if (emergencyPositive && observations.length >= 2) {
                const byHash = new Map();
                for (const observation of observations) {
                    const hash = observation.key.split(':', 1)[0];
                    const group = byHash.get(hash) || [];
                    group.push(observation);
                    byHash.set(hash, group);
                }
                for (const group of byHash.values()) {
                    if (group.length >= 2) {
                        const positive = group.find(item => emergencyPositive(item.value));
                        if (positive) emergencyObservation = positive.value;
                    }
                }
            }
        }
    }
    if (emergencyObservation) return emergencyObservation;
    const error = new Error(`${label}: recent common-block RPC quorum unavailable or inconsistent`);
    error.code = errorCode;
    throw error;
}

module.exports = { readSnapshotConsensus };
