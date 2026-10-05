'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
function syncDirectory(filename) {
  const fd = fs.openSync(path.dirname(filename), 'r');
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}
// Resolve only after both contents and the directory entry are durable.
function durableWriteFileSync(filename, data, options = {}) {
  const temp = `${filename}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`;
  let fd;
  try {
    fd = fs.openSync(temp, 'wx', options.mode ?? 0o600);
    fs.writeFileSync(fd, data, options);
    fs.fsyncSync(fd);
    fs.closeSync(fd); fd = undefined;
    fs.renameSync(temp, filename);
    syncDirectory(filename);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    try { fs.unlinkSync(temp); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
function durableUnlinkSync(filename) {
  fs.unlinkSync(filename);
  syncDirectory(filename);
}
module.exports = { durableWriteFileSync, durableUnlinkSync, syncDirectory };
