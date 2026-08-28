// SPDX-License-Identifier: MIT

const fs = require('fs/promises');
const path = require('path');

const DEFAULT_THRESHOLD = 3;

// Community/test keepers are local-only observers. Telegram and AWS secrets belong exclusively to the protocol bot.
async function reportLocally(message) {
  console.log(`  Keeper incident: ${String(message).replace(/\s*\n\s*/g, ' | ')}`);
  return true;
}

class PersistentActionAlerts {
  constructor({ poolName, stateFile, threshold = DEFAULT_THRESHOLD, sender = reportLocally }) {
    this.poolName = poolName;
    this.stateFile = stateFile || path.join(__dirname, '..', '..', '.keeper-action-failures.json');
    this.threshold = threshold;
    this.sender = sender;
    this.state = { version: 1, actions: {} };
  }

  async init() {
    try {
      const parsed = JSON.parse(await fs.readFile(this.stateFile, 'utf8'));
      if (parsed?.version === 1 && parsed.actions && typeof parsed.actions === 'object') {
        this.state = parsed;
      }
    } catch (error) {
      if (error.code !== 'ENOENT') {
        console.log(`  Keeper failure state ignored: ${(error.message || '').slice(0, 100)}`);
      }
    }
  }

  async failure(action, error) {
    const previous = this.state.actions[action] || { consecutiveFailures: 0, alerted: false };
    const next = {
      consecutiveFailures: previous.consecutiveFailures + 1,
      alerted: previous.alerted,
      lastError: String(error || 'unknown error').slice(0, 500),
      updatedAt: new Date().toISOString(),
    };
    this.state.actions[action] = next;
    await this._persist();

    if (next.consecutiveFailures >= this.threshold && !next.alerted) {
      const sent = await this.sender(
        `[${this.poolName}] Keeper ${action} failed for ${next.consecutiveFailures} consecutive attempts.\n` +
        `Last error: ${next.lastError}`
      );
      if (sent) {
        next.alerted = true;
        await this._persist();
      }
    }
  }

  async success(action, details = 'action available again') {
    const previous = this.state.actions[action];
    if (!previous || previous.consecutiveFailures === 0) return;

    if (previous.alerted) {
      const sent = await this.sender(
        `[${this.poolName}] Keeper ${action} recovered after ${previous.consecutiveFailures} failed attempts.\n${details}`
      );
      if (!sent) return;
    }
    delete this.state.actions[action];
    await this._persist();
  }

  async critical(action, details) {
    const previous = this.state.actions[action];
    if (previous?.alerted) return false;
    const message = String(details || 'critical condition').slice(0, 1000);
    const sent = await this.sender(`[${this.poolName}] CRITICAL ${action}.\n${message}`);
    this.state.actions[action] = {
      consecutiveFailures: 1,
      alerted: Boolean(sent),
      lastError: message,
      updatedAt: new Date().toISOString(),
    };
    await this._persist();
    return Boolean(sent);
  }

  async _persist() {
    const tmp = `${this.stateFile}.tmp`;
    await fs.writeFile(tmp, `${JSON.stringify(this.state, null, 2)}\n`, { mode: 0o600 });
    await fs.rename(tmp, this.stateFile);
  }
}

module.exports = { PersistentActionAlerts };
