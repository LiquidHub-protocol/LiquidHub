'use strict';
function strictInteger(value, name = 'value', min = 0, max = Number.MAX_SAFE_INTEGER) {
  const raw = String(value ?? '');
  const result = Number(raw);
  if (!/^-?\d+$/.test(raw) || !Number.isSafeInteger(result) || result < min || result > max) {
    throw new Error(`${name} must be an integer in [${min}, ${max}]`);
  }
  return result;
}
module.exports = { strictInteger };
