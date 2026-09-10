'use strict';

// Financial values must be compared at the same recent chain state. Caller-owned
// timeouts and chain authentication are retained; this helper never sends a tx.
async function readSnapshotConsensus({
    entries, read, keyOf, withTimeout, authenticate = async () => {},
    allowSingle = false, label, errorCode,
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
                return validHeader(block) ? { entry, number: block.number } : null;
            });
        } catch { return null; }
    }))).filter(Boolean).sort((a, b) => b.number - a.number);
    const headQuorum = allowSingle && heads.length === 1 ? 1 : 2;
    if (heads.length >= headQuorum) {
        // Start just behind the quorum head. A single outlier cannot pick a far
        // future/old block. One bounded fallback tolerates a more delayed source.
        const heights = new Set([
            Math.max(0, heads[headQuorum - 1].number - 1),
            heads[heads.length - 1].number,
        ]);
        for (const blockTag of heights) {
            const observations = (await Promise.all(heads.map(async ({ entry }) => {
                try {
                    return await withTimeout(async () => {
                        const before = await header(entry.provider, blockTag);
                        if (!validHeader(before, blockTag)) return null;
                        const value = await read(entry.provider, blockTag);
                        const after = await header(entry.provider, blockTag);
                        if (!validHeader(after, blockTag) || before.hash.toLowerCase() !== after.hash.toLowerCase()) return null;
                        const key = String(keyOf(value));
                        if (!key) return null;
                        return { key: `${before.hash.toLowerCase()}:${key}`, value };
                    });
                } catch { return null; }
            }))).filter(Boolean);
            const quorum = allowSingle && observations.length === 1 ? 1 : 2;
            const groups = new Map();
            for (const observation of observations) {
                const count = (groups.get(observation.key) || 0) + 1;
                groups.set(observation.key, count);
                if (count >= quorum) return observation.value;
            }
        }
    }
    const error = new Error(`${label}: recent common-block RPC quorum unavailable or inconsistent`);
    error.code = errorCode;
    throw error;
}

module.exports = { readSnapshotConsensus };
