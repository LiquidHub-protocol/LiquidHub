'use strict';

// Select a bounded tranche by simulating the canonical public route. No caller
// can choose the beneficiary, oracle floor, router or an arbitrary swap payload.
const REVENUE_CONVERSION_ABI = [
  'function usdc() view returns (address)',
  'function wrappedNative() view returns (address)',
  'function wrapNativeFees()',
  'function previewFeeConversion(address) view returns (uint256,uint256,uint64)',
  'function previewSourceFeeConversion(address,address) view returns (uint256,uint256,uint64)',
  'function convertFeeChunk(address,uint256) returns (uint256)',
  'function convertSourceFeeChunk(address,address,uint256) returns (uint256)',
];
async function prepareFeeConversion(treasury, provider, from, { token, source }, maxGas = 500000n) {
  const preview = source
    ? await treasury.previewSourceFeeConversion(source, token)
    : await treasury.previewFeeConversion(token);
  let amount = BigInt(preview[0]);
  if (amount === 0n) return null;
  let lastError;
  // These are read-only simulations; broadcast/reconciliation happens once in
  // the caller's existing signer lock and transaction journal.
  for (let attempt = 0; attempt < 8 && amount > 0n; attempt++, amount /= 2n) {
    const request = source
      ? await treasury.convertSourceFeeChunk.populateTransaction(source, token, amount)
      : await treasury.convertFeeChunk.populateTransaction(token, amount);
    try {
      const gas = await provider.estimateGas({ ...request, from });
      if (gas > maxGas) throw new Error('Fee conversion exceeds gas budget');
      return { request, amount };
    } catch (error) { lastError = error; }
  }
  throw lastError || new Error('No executable fee conversion tranche');
}
module.exports = { REVENUE_CONVERSION_ABI, prepareFeeConversion };

async function prepareNativeWrap(treasury, provider, from, maxGas = 500000n) {
  const token = await treasury.wrappedNative();
  if (/^0x0{40}$/i.test(token)) return null;
  const amount=await provider.getBalance(treasury.target);
  if(amount===0n || !await treasury.assetSealed(token))return null;
  const feed=await treasury.swapFeeds(token);
  const oracle=new (require('ethers').Contract)(feed,[
    'function decimals() view returns(uint8)',
    'function latestRoundData() view returns(uint80,int256,uint256,uint256,uint80)',
  ],provider);
  const [round,decimals,maxAge,usdcDecimals,minUsdc,block]=await Promise.all([
    oracle.latestRoundData(),oracle.decimals(),treasury.swapFeedMaxAges(token),
    treasury.usdcDecimals(),treasury.conversionMinUsdc(token),provider.getBlock('latest'),
  ]);
  const now=BigInt(block.timestamp);
  if(round[1]<=0n||round[3]<=0n||round[3]>now||now-round[3]>maxAge||round[4]<round[0]||decimals>18n)throw new Error('Native conversion oracle invalid');
  // Avoid spending operator gas to wrap unsolicited dust. The actual USDC
  // conversion still enforces its own stablecoin price and slippage floor.
  if(amount*round[1]*10n**usdcDecimals/(10n**decimals*10n**18n)<minUsdc)return null;
  const request=await treasury.wrapNativeFees.populateTransaction();
  if(await provider.estimateGas({...request,from})>maxGas)throw new Error('Native wrap exceeds gas budget');
  return {request,token};
}
REVENUE_CONVERSION_ABI.push(
  'function assetSealed(address) view returns(bool)',
  'function swapFeeds(address) view returns(address)',
  'function swapFeedMaxAges(address) view returns(uint32)',
  'function usdcDecimals() view returns(uint8)',
  'function conversionMinUsdc(address) view returns(uint256)',
);
module.exports.prepareNativeWrap=prepareNativeWrap;
