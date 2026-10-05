// Notifications push (Firebase Cloud Messaging, API HTTP v1), sans dépendance externe.
// Interface stable utilisée par le reste du serveur ; sans FIREBASE_SERVICE_ACCOUNT, tout est sans effet.
//
// FIREBASE_SERVICE_ACCOUNT : JSON du compte de service Firebase (brut ou encodé en base64).
// FCM_API_URL (tests uniquement) : remplace https://fcm.googleapis.com.
const crypto = require('node:crypto');
const express = require('express');
const { db } = require('./db');
const { requireAuth } = require('./auth');
const { log } = require('./logger');

const router = express.Router();

db.exec(`
  CREATE TABLE IF NOT EXISTS push_tokens (
    token TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_push_tokens_user ON push_tokens(user_id);
`);

const MAX_TOKENS_PER_USER = 10;
const CONCURRENCY = 10;
const HTTP_TIMEOUT_MS = 10_000;
const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

// ---------- Configuration ----------

let configCache = { raw: undefined, value: null };

/** Compte de service lu depuis l'environnement (null si absent ou invalide). Relu si la variable change. */
function getConfig() {
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT || '';
  if (raw === configCache.raw) return configCache.value;
  let value = null;
  if (raw.trim()) {
    try {
      const text = raw.trim().startsWith('{') ? raw : Buffer.from(raw, 'base64').toString('utf8');
      const sa = JSON.parse(text);
      if (!sa.client_email || !sa.private_key || !sa.project_id) throw new Error('champs manquants');
      value = {
        clientEmail: sa.client_email,
        privateKey: sa.private_key.replace(/\\n/g, '\n'),
        projectId: sa.project_id,
        tokenUri: sa.token_uri || 'https://oauth2.googleapis.com/token',
      };
    } catch (e) {
      // Message générique : l'erreur de JSON.parse citerait un morceau de la clé privée.
      const reason = e instanceof SyntaxError ? 'JSON invalide (ni brut ni base64)' : e.message;
      log.error('FIREBASE_SERVICE_ACCOUNT illisible : notifications push désactivées', { reason });
    }
  }
  configCache = { raw, value };
  accessToken = null;
  return value;
}

/** Vrai si les notifications push sont configurées. */
const isConfigured = () => getConfig() !== null;

// ---------- Jeton d'accès OAuth2 (JWT RS256 signé localement) ----------

let accessToken = null; // { value, expiresAt }
let pendingToken = null;

const b64url = (input) => Buffer.from(input).toString('base64url');

function signJwt(cfg) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({ iss: cfg.clientEmail, scope: SCOPE, aud: cfg.tokenUri, iat: now, exp: now + 3600 }));
  const signature = crypto.sign('RSA-SHA256', Buffer.from(`${header}.${claims}`), cfg.privateKey);
  return `${header}.${claims}.${signature.toString('base64url')}`;
}

async function fetchAccessToken(cfg) {
  const res = await fetch(cfg.tokenUri, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: signJwt(cfg),
    }).toString(),
    signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.access_token) {
    throw new Error(`OAuth ${res.status} ${body.error || ''} ${body.error_description || ''}`.trim());
  }
  const ttl = Number(body.expires_in) || 3600;
  return { value: body.access_token, expiresAt: Date.now() + Math.max(ttl - 120, 30) * 1000 };
}

/** Jeton d'accès en cache (renouvelé 2 min avant expiration ; une seule demande à la fois). */
async function getAccessToken(cfg) {
  if (accessToken && accessToken.expiresAt > Date.now()) return accessToken.value;
  if (!pendingToken) {
    pendingToken = fetchAccessToken(cfg)
      .then((t) => { accessToken = t; return t.value; })
      .finally(() => { pendingToken = null; });
  }
  return pendingToken;
}

// ---------- Envoi ----------

/** Nettoie le message : titre/corps en texte, data = objet de chaînes. */
function buildPayload(token, message) {
  const data = {};
  for (const [k, v] of Object.entries((message && message.data) || {})) {
    if (v !== undefined && v !== null) data[String(k)] = String(v);
  }
  const title = String((message && message.title) || 'KALETA').slice(0, 200);
  const body = String((message && message.body) || '').slice(0, 1000);
  return {
    message: {
      token,
      notification: { title, body },
      data,
      android: { priority: 'high', notification: { channel_id: 'commandes', sound: 'default' } },
      apns: { payload: { aps: { sound: 'default' } } },
    },
  };
}

/** Jeton désormais invalide côté FCM (application désinstallée, jeton expiré ou mal formé). */
function isInvalidToken(status, body) {
  if (status === 404) return true;
  const err = (body && body.error) || {};
  const codes = (err.details || []).map((d) => d && d.errorCode);
  if (codes.includes('UNREGISTERED')) return true;
  return status === 400 && err.status === 'INVALID_ARGUMENT' && /registration token/i.test(err.message || '');
}

const apiBase = () => (process.env.FCM_API_URL || 'https://fcm.googleapis.com').replace(/\/+$/, '');

/** Envoie à un jeton ; renvoie 'ok' | 'invalid' | 'error'. Ne lève jamais. */
async function sendOne(cfg, token, message, retried = false) {
  try {
    const bearer = await getAccessToken(cfg);
    const res = await fetch(`${apiBase()}/v1/projects/${encodeURIComponent(cfg.projectId)}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(buildPayload(token, message)),
      signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
    });
    if (res.ok) return 'ok';
    const body = await res.json().catch(() => ({}));
    if (res.status === 401 && !retried) {
      accessToken = null; // jeton d'accès révoqué ou expiré : on en redemande un, une fois
      return sendOne(cfg, token, message, true);
    }
    if (isInvalidToken(res.status, body)) return 'invalid';
    log.warn('Notification push refusée', { status: res.status, fcm_error: body.error && body.error.status });
    return 'error';
  } catch (e) {
    log.warn('Notification push impossible', { error: e.message });
    return 'error';
  }
}

/** Envoie à une liste de jetons, au plus CONCURRENCY en parallèle ; supprime les jetons invalides. */
async function sendToTokens(tokens, message) {
  const cfg = getConfig();
  if (!cfg || tokens.length === 0) return { sent: 0, invalid: 0, failed: 0 };
  const stats = { sent: 0, invalid: 0, failed: 0 };
  const queue = [...new Set(tokens)];
  const worker = async () => {
    while (queue.length) {
      const token = queue.shift();
      const result = await sendOne(cfg, token, message);
      if (result === 'ok') stats.sent++;
      else if (result === 'invalid') {
        stats.invalid++;
        try { db.prepare('DELETE FROM push_tokens WHERE token = ?').run(token); } catch { /* ignoré */ }
      } else stats.failed++;
    }
  };
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, queue.length) }, worker));
  if (stats.invalid) log.info('Jetons push invalides supprimés', { count: stats.invalid });
  return stats;
}

// Comptes joignables : actifs et non supprimés (colonnes absentes sur une vieille base = ignorées).
function activeUserFilter() {
  const cols = db.prepare('PRAGMA table_info(users)').all().map((c) => c.name);
  const parts = [];
  if (cols.includes('active')) parts.push('(u.active IS NULL OR u.active = 1)');
  if (cols.includes('deleted_at')) parts.push('u.deleted_at IS NULL');
  return parts.length ? ` AND ${parts.join(' AND ')}` : '';
}

/** Envoie une notification à un utilisateur (tous ses appareils). Ne lève jamais d'erreur. */
async function notifyUser(userId, message) {
  try {
    if (!isConfigured()) return;
    const rows = db.prepare(
      `SELECT t.token FROM push_tokens t JOIN users u ON u.id = t.user_id WHERE t.user_id = ?${activeUserFilter()}`,
    ).all(Number(userId));
    await sendToTokens(rows.map((r) => r.token), message);
  } catch (e) {
    log.error('notifyUser a échoué', { error: e.message });
  }
}

/** Envoie une notification à tous les comptes actifs d'un rôle ('admin' | 'driver'). Ne lève jamais d'erreur. */
async function notifyRole(role, message) {
  try {
    if (!isConfigured()) return;
    const rows = db.prepare(
      `SELECT t.token FROM push_tokens t JOIN users u ON u.id = t.user_id WHERE u.role = ?${activeUserFilter()}`,
    ).all(String(role));
    await sendToTokens(rows.map((r) => r.token), message);
  } catch (e) {
    log.error('notifyRole a échoué', { error: e.message });
  }
}

// ---------- Routes ----------

const validToken = (t) => typeof t === 'string' && t.length >= 10 && t.length <= 4096;

// Enregistre le jeton de l'appareil. Un jeton n'appartient qu'à un compte : il change de propriétaire
// si un autre compte se connecte sur le même téléphone.
router.post('/api/push/token', requireAuth, (req, res) => {
  const { token, platform } = req.body || {};
  if (!validToken(token)) return res.status(400).json({ error: 'Jeton de notification invalide' });
  const plat = typeof platform === 'string' ? platform.slice(0, 20) : null;
  db.prepare(
    `INSERT INTO push_tokens (token, user_id, platform) VALUES (?, ?, ?)
     ON CONFLICT(token) DO UPDATE SET user_id = excluded.user_id, platform = excluded.platform,
       updated_at = datetime('now')`,
  ).run(token, req.user.id, plat);
  // Au plus MAX_TOKENS_PER_USER appareils par compte : les plus anciens sont oubliés.
  db.prepare(
    `DELETE FROM push_tokens WHERE user_id = ? AND token NOT IN (
       SELECT token FROM push_tokens WHERE user_id = ? ORDER BY updated_at DESC, rowid DESC LIMIT ?)`,
  ).run(req.user.id, req.user.id, MAX_TOKENS_PER_USER);
  res.json({ ok: true, enabled: isConfigured() });
});

// Oublie le jeton (déconnexion). Seul le compte propriétaire peut le supprimer.
router.delete('/api/push/token', requireAuth, (req, res) => {
  const { token } = req.body || {};
  if (!validToken(token)) return res.status(400).json({ error: 'Jeton de notification invalide' });
  db.prepare('DELETE FROM push_tokens WHERE token = ? AND user_id = ?').run(token, req.user.id);
  res.json({ ok: true });
});

module.exports = { router, notifyUser, notifyRole, isConfigured };
