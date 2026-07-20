const fs = require('fs/promises');
const path = require('path');

const DEFAULT_THRESHOLD = 3;

async function sendTelegram(message) {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  const chatId = process.env.TELEGRAM_CHAT_ID;
  if (!token || !chatId) {
    console.log('  Telegram alert not sent: TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID not configured');
    return false;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const response = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text: message }),
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`Telegram HTTP ${response.status}`);
    return true;
  } catch (error) {
    console.log(`  Telegram alert failed: ${(error.message || '').slice(0, 120)}`);
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

class PersistentActionAlerts {
  constructor({ poolName, stateFile, threshold = DEFAULT_THRESHOLD, sender = sendTelegram }) {
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
        `[${this.poolName}] Keeper ${action} failed for ${next.consecutiveFailures} consecutive cycles.\n` +
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
        `[${this.poolName}] Keeper ${action} recovered after ${previous.consecutiveFailures} failed cycles.\n${details}`
      );
      if (!sent) return;
    }
    delete this.state.actions[action];
    await this._persist();
  }

  async _persist() {
    const tmp = `${this.stateFile}.tmp`;
    await fs.writeFile(tmp, `${JSON.stringify(this.state, null, 2)}\n`, { mode: 0o600 });
    await fs.rename(tmp, this.stateFile);
  }
}

module.exports = { PersistentActionAlerts, sendTelegram };
