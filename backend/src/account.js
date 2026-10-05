// Comptes : inscription, connexion, codes de vérification (OTP), mot de passe oublié,
// profil, mot de passe, photo, statistiques, adresses enregistrées, suppression ; pages légales.
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const express = require('express');
const bcrypt = require('bcryptjs');
const multer = require('multer');
const { rateLimit } = require('express-rate-limit');
const { db, transaction } = require('./db');
const {
  requireAuth, requireManager, signToken, normalizePhone, isValidPhone, isInactive, INACTIVE_MESSAGE, adminLevelOf,
} = require('./auth');
const { log } = require('./logger');
const { audit, raiseAlert } = require('./monitor');
const { sendSms, otpRequired, smsChannel } = require('./sms');
const legal = require('./legal');
const push = require('./push');

// ---------- Migrations (idempotentes) ----------

function addColumn(table, column, definition) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);
  if (!cols.includes(column)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
}
addColumn('users', 'avatar_url', 'TEXT');
addColumn('users', 'momo_phone', 'TEXT');
addColumn('users', 'deleted_at', 'TEXT');

db.exec(`
  CREATE TABLE IF NOT EXISTS user_addresses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    address TEXT NOT NULL,
    lat REAL,
    lng REAL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_user_addresses_user ON user_addresses(user_id);

  -- Codes de vérification (inscription, mot de passe oublié). Dates en millisecondes.
  CREATE TABLE IF NOT EXISTS otp_codes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    phone TEXT NOT NULL,
    purpose TEXT NOT NULL,
    user_id INTEGER,
    code_hash TEXT NOT NULL,
    salt TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    ip TEXT,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at INTEGER,
    token_hash TEXT,
    token_expires_at INTEGER,
    token_used_at INTEGER
  );
  CREATE INDEX IF NOT EXISTS idx_otp_phone ON otp_codes(phone, purpose, id);
  CREATE INDEX IF NOT EXISTS idx_otp_ip ON otp_codes(ip, created_at);
  CREATE INDEX IF NOT EXISTS idx_otp_token ON otp_codes(token_hash);

  -- Demandes « mot de passe oublié » : en mode sans SMS, le code est communiqué par l'admin.
  CREATE TABLE IF NOT EXISTS password_resets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    phone TEXT NOT NULL,
    otp_id INTEGER NOT NULL,
    channel TEXT NOT NULL,
    code TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    expires_at INTEGER NOT NULL,
    done_at TEXT,
    done_by INTEGER
  );
  CREATE INDEX IF NOT EXISTS idx_password_resets_status ON password_resets(status, id);
`);

const MAX_ADDRESSES = 10;
const PHONE_RE = /^\+?[\d\s]{8,16}$/;

// ---------- Helpers ----------

const h = (fn) => async (req, res) => {
  try {
    await fn(req, res);
  } catch (err) {
    if (!err.status) log.error('erreur serveur', { path: req.path, error: err.message, stack: err.stack });
    res.status(err.status || 500).json({ error: err.status ? err.message : 'Erreur serveur' });
  }
};

function httpError(status, message) {
  const err = new Error(message);
  err.status = status;
  return err;
}

function publicUser(u) {
  return {
    id: u.id,
    name: u.name,
    phone: u.phone,
    email: u.email,
    role: u.role,
    address: u.address,
    created_at: u.created_at,
    avatar_url: u.avatar_url ?? null,
    momo_phone: u.momo_phone ?? null,
    active: !isInactive(u),
    phone_verified: Number(u.phone_verified ?? 0) === 1,
    terms_accepted_at: u.terms_accepted_at ?? null,
    terms_version: u.terms_version ?? null,
    // Personnel : 'owner' (propriétaire) ou 'manager' (gérant) ; null pour un client ou un livreur.
    admin_level: adminLevelOf(u),
  };
}

function mapAddress(a) {
  return { id: a.id, label: a.label, address: a.address, lat: a.lat, lng: a.lng };
}

const getUser = (id) => db.prepare('SELECT * FROM users WHERE id = ?').get(id);

/** requireAuth + chargement de l'utilisateur ; un compte supprimé n'est plus accepté. */
function requireUser(req, res, next) {
  requireAuth(req, res, () => {
    const user = getUser(req.user.id);
    if (!user || user.deleted_at) return res.status(401).json({ error: 'Session expirée, reconnectez-vous' });
    req.account = user;
    next();
  });
}

// Limite les essais de mot de passe (changement, suppression du compte).
const passwordLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 10,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  keyGenerator: (req) => `user-${req.user.id}`,
  message: { error: 'Trop de tentatives. Réessayez dans 15 minutes.' },
});

// ---------- Photo de profil ----------

const AVATAR_DIR = path.join(__dirname, '..', 'uploads', 'avatars');
fs.mkdirSync(AVATAR_DIR, { recursive: true });

const avatarUpload = multer({
  storage: multer.diskStorage({
    destination: AVATAR_DIR,
    filename: (req, file, cb) => {
      const ext = (path.extname(file.originalname).toLowerCase().match(/^\.(jpe?g|png|webp)$/) || ['.jpg'])[0];
      cb(null, `${req.user.id}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}${ext}`);
    },
  }),
  limits: { fileSize: 5 * 1024 * 1024, files: 1 },
  fileFilter: (_req, file, cb) => cb(null, /^image\/(jpeg|png|webp)$/.test(file.mimetype)),
}).single('image');

/** Supprime le fichier d'une photo de profil (uniquement dans uploads/avatars). */
function removeAvatarFile(url) {
  if (!url || !url.startsWith('/uploads/avatars/')) return;
  const file = path.join(AVATAR_DIR, path.basename(url));
  fs.unlink(file, (err) => {
    if (err && err.code !== 'ENOENT') log.warn('suppression avatar impossible', { file, error: err.message });
  });
}

// ---------- Validation ----------

function cleanText(value, max) {
  return typeof value === 'string' ? value.trim().slice(0, max) : '';
}

function parseCoord(value, limit, label) {
  if (value === undefined || value === null || value === '') return null;
  const n = Number(value);
  if (!Number.isFinite(n) || Math.abs(n) > limit) throw httpError(400, `${label} invalide`);
  return n;
}

function addressFields(body, current = {}) {
  const pick = (k) => (body[k] !== undefined ? body[k] : current[k]);
  const label = typeof pick('label') === 'string' ? pick('label').trim() : '';
  if (label.length < 1 || label.length > 40) throw httpError(400, 'Nom de l\'adresse requis (40 caractères max)');
  const address = cleanText(pick('address'), 300);
  if (!address) throw httpError(400, 'Adresse requise');
  const lat = parseCoord(pick('lat'), 90, 'Latitude');
  const lng = parseCoord(pick('lng'), 180, 'Longitude');
  if ((lat === null) !== (lng === null)) throw httpError(400, 'Position incomplète (latitude et longitude requises)');
  return { label, address, lat, lng };
}

// ---------- Codes de vérification (OTP) ----------

const OTP_PURPOSES = ['register', 'reset'];
const OTP_TTL_MS = 10 * 60 * 1000; // code envoyé par SMS
const OTP_ADMIN_TTL_MS = 60 * 60 * 1000; // code communiqué par le restaurant (le temps de rappeler le client)
const OTP_TOKEN_TTL_MS = 15 * 60 * 1000; // otp_token renvoyé après vérification
const OTP_MAX_ATTEMPTS = 5;
const OTP_LIMITS = { perPhone15min: 3, perPhoneDay: 10, perIpHour: 20 };
const OTP_INVALID = 'Code invalide ou expiré : demandez un nouveau code';

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const hashCode = (salt, code) => sha256(`${salt}:${code}`);

/** Limites par numéro et par IP (en plus de la limite express par IP). */
function checkOtpLimits(phone, ip) {
  const now = Date.now();
  const n = (sql, ...p) => db.prepare(sql).get(...p).n;
  const tooMany =
    n('SELECT COUNT(*) AS n FROM otp_codes WHERE phone = ? AND created_at > ?', phone, now - 15 * 60 * 1000) >= OTP_LIMITS.perPhone15min ||
    n('SELECT COUNT(*) AS n FROM otp_codes WHERE phone = ? AND created_at > ?', phone, now - 24 * 3600 * 1000) >= OTP_LIMITS.perPhoneDay ||
    (ip && n('SELECT COUNT(*) AS n FROM otp_codes WHERE ip = ? AND created_at > ?', ip, now - 3600 * 1000) >= OTP_LIMITS.perIpHour);
  if (tooMany) throw httpError(429, 'Trop de demandes de code. Réessayez plus tard.');
}

/** Crée un code (6 chiffres, haché) et invalide les précédents du même numéro / usage. */
function issueOtp(phone, purpose, { userId = null, ip = null, ttlMs = OTP_TTL_MS } = {}) {
  const now = Date.now();
  const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
  const salt = crypto.randomBytes(16).toString('hex');
  return transaction(() => {
    db.prepare('UPDATE otp_codes SET used_at = ? WHERE phone = ? AND purpose = ? AND used_at IS NULL').run(now, phone, purpose);
    const info = db
      .prepare(`INSERT INTO otp_codes (phone, purpose, user_id, code_hash, salt, ip, created_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(phone, purpose, userId, hashCode(salt, code), salt, ip, now, now + ttlMs);
    return { id: Number(info.lastInsertRowid), code };
  });
}

/**
 * Vérifie le dernier code actif du numéro (5 essais). Renvoie la ligne si le code est bon
 * (le code est alors consommé), sinon lève une erreur 400.
 */
function checkOtpCode(phone, purpose, code) {
  const now = Date.now();
  const row = db
    .prepare('SELECT * FROM otp_codes WHERE phone = ? AND purpose = ? AND used_at IS NULL ORDER BY id DESC LIMIT 1')
    .get(phone, purpose);
  if (!row || row.expires_at <= now) throw httpError(400, OTP_INVALID);
  if (row.attempts >= OTP_MAX_ATTEMPTS) {
    db.prepare('UPDATE otp_codes SET used_at = ? WHERE id = ?').run(now, row.id);
    throw httpError(400, 'Trop d\'essais : demandez un nouveau code');
  }
  const given = Buffer.from(hashCode(row.salt, String(code ?? '').trim()));
  const ok = /^\d{6}$/.test(String(code ?? '').trim()) && crypto.timingSafeEqual(given, Buffer.from(row.code_hash));
  if (!ok) {
    const attempts = row.attempts + 1;
    db.prepare('UPDATE otp_codes SET attempts = ?, used_at = ? WHERE id = ?')
      .run(attempts, attempts >= OTP_MAX_ATTEMPTS ? now : null, row.id);
    const left = OTP_MAX_ATTEMPTS - attempts;
    throw httpError(400, left > 0 ? `Code incorrect (${left} essai${left > 1 ? 's' : ''} restant${left > 1 ? 's' : ''})` : 'Trop d\'essais : demandez un nouveau code');
  }
  db.prepare('UPDATE otp_codes SET used_at = ? WHERE id = ?').run(now, row.id);
  return row;
}

/** Code bon → otp_token (valable 15 min, usage unique). */
function verifyOtp(phone, purpose, code) {
  const row = checkOtpCode(phone, purpose, code);
  const token = crypto.randomBytes(24).toString('hex');
  db.prepare('UPDATE otp_codes SET token_hash = ?, token_expires_at = ? WHERE id = ?')
    .run(sha256(token), Date.now() + OTP_TOKEN_TTL_MS, row.id);
  return token;
}

/** Consomme un otp_token (numéro et usage vérifiés). Lève 400 s'il est invalide. */
function consumeOtpToken(phone, purpose, token) {
  if (typeof token !== 'string' || !token) throw httpError(400, 'Vérification du numéro requise');
  const now = Date.now();
  const row = db
    .prepare(`SELECT * FROM otp_codes WHERE token_hash = ? AND phone = ? AND purpose = ?
              AND token_used_at IS NULL AND token_expires_at > ?`)
    .get(sha256(token), phone, purpose, now);
  if (!row) throw httpError(400, 'Vérification du numéro expirée : demandez un nouveau code');
  db.prepare('UPDATE otp_codes SET token_used_at = ? WHERE id = ?').run(now, row.id);
  return row;
}

/** Compte actif par numéro (normalisé, puis tel que saisi pour les numéros pas encore migrés). */
function findUserByPhone(rawPhone) {
  const n = normalizePhone(rawPhone);
  const raw = typeof rawPhone === 'string' ? rawPhone.trim() : '';
  const get = db.prepare('SELECT * FROM users WHERE phone = ? AND deleted_at IS NULL');
  return (n && get.get(n)) || (raw && raw !== n && get.get(raw)) || null;
}

/** Numéro saisi → normalisé, ou erreur 400. */
function requirePhone(value) {
  const phone = normalizePhone(value);
  if (!isValidPhone(phone)) throw httpError(400, 'Numéro de téléphone invalide');
  return phone;
}

// Hachage factice : même temps de réponse pour un numéro inconnu (pas d'énumération des comptes).
const DUMMY_HASH = bcrypt.hashSync(crypto.randomBytes(16).toString('hex'), 10);
const LOGIN_FAILED = 'Téléphone ou mot de passe incorrect';

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 10,
  skipSuccessfulRequests: true,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  message: { error: 'Trop de tentatives de connexion. Réessayez dans 15 minutes.' },
});
const registerLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  limit: 5,
  skipFailedRequests: true,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  message: { error: 'Trop de comptes créés depuis ce réseau. Réessayez plus tard.' },
});
const otpLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 30,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  message: { error: 'Trop de demandes. Réessayez dans quelques minutes.' },
});

/** Mot de passe oublié : crée la demande et envoie le code (SMS, ou à défaut via l'admin). */
function startPasswordReset(rawPhone, ip) {
  const phone = requirePhone(rawPhone);
  checkOtpLimits(phone, ip);
  const channel = smsChannel();
  const user = findUserByPhone(rawPhone);
  if (!user) {
    // Numéro inconnu : même réponse, un code est créé (jamais communiqué) pour garder les mêmes limites.
    issueOtp(phone, 'reset', { ip });
    audit('password_forgot_unknown', { details: { phone: phone.slice(0, 20) }, ip });
    return { sent: true, channel };
  }
  const ttlMs = channel === 'sms' ? OTP_TTL_MS : OTP_ADMIN_TTL_MS;
  const { id: otpId, code } = issueOtp(phone, 'reset', { userId: user.id, ip, ttlMs });
  db.prepare(`UPDATE password_resets SET status = 'replaced', code = NULL WHERE user_id = ? AND status = 'pending'`).run(user.id);
  const reset = db
    .prepare('INSERT INTO password_resets (user_id, phone, otp_id, channel, code, expires_at) VALUES (?, ?, ?, ?, ?, ?)')
    .run(user.id, user.phone, otpId, channel, channel === 'admin' ? code : null, Date.now() + ttlMs);
  const resetId = Number(reset.lastInsertRowid);
  audit('password_forgot', { userId: user.id, details: { channel, resetId }, ip });
  if (channel === 'sms') {
    // Envoi en arrière-plan (même temps de réponse que pour un numéro inconnu) ; échec → repli admin.
    sendSms(user.phone, `KALETA : votre code de réinitialisation est ${code}. Valable 10 minutes.`)
      .then((r) => {
        if (!r.ok) handOverToAdmin(resetId, otpId, code, user, 'échec SMS');
      })
      .catch(() => handOverToAdmin(resetId, otpId, code, user, 'échec SMS'));
  } else {
    notifyAdmins(resetId, user);
  }
  return { sent: true, channel };
}

/** Repli : le code part chez l'admin (SMS impossible). */
function handOverToAdmin(resetId, otpId, code, user, reason) {
  try {
    const expires = Date.now() + OTP_ADMIN_TTL_MS;
    db.prepare(`UPDATE password_resets SET channel = 'admin', code = ?, expires_at = ? WHERE id = ? AND status = 'pending'`)
      .run(code, expires, resetId);
    db.prepare('UPDATE otp_codes SET expires_at = ? WHERE id = ? AND used_at IS NULL').run(expires, otpId);
    log.warn('mot de passe oublié : repli admin', { resetId, reason });
    notifyAdmins(resetId, user);
  } catch (err) {
    log.error('repli admin impossible', { resetId, error: err.message });
  }
}

function notifyAdmins(resetId, user) {
  const who = `${user.name} (${user.phone})`;
  raiseAlert('password_reset', 'info', `Mot de passe oublié : ${who} attend son code (Plus → Mots de passe oubliés)`,
    { key: `reset-${resetId}`, resetId, userId: user.id }, 0);
  push.notifyRole('admin', {
    title: 'Mot de passe oublié',
    body: `${who} demande un nouveau mot de passe : communiquez-lui le code.`,
    data: { type: 'password_reset', reset_id: String(resetId) },
  }).catch(() => {});
}

// ---------- Routes ----------

const router = express.Router();

// Pages légales publiques et version des conditions.
router.use(legal.router);

const str = (v) => (typeof v === 'string' ? v : '');

router.post('/api/auth/register', registerLimiter, h((req, res) => {
  const body = req.body || {};
  const { name, phone, password, email, address, otp_token, accept_terms } = body;
  for (const [k, v] of Object.entries({ name, phone, password, email, address, otp_token })) {
    if (v !== undefined && v !== null && typeof v !== 'string') throw httpError(400, `Champ ${k} invalide`);
  }
  if (!str(name).trim() || !str(phone).trim() || !password) throw httpError(400, 'Nom, téléphone et mot de passe requis');
  if (password.length < 6) throw httpError(400, 'Le mot de passe doit contenir au moins 6 caractères');
  if (password.length > 200) throw httpError(400, 'Mot de passe trop long');
  if (accept_terms !== true) {
    throw httpError(400, 'Vous devez accepter les conditions d\'utilisation et la politique de confidentialité');
  }
  const normalized = requirePhone(phone);
  if (findUserByPhone(phone)) throw httpError(409, 'Ce numéro est déjà utilisé');
  let verified = false;
  if (otpRequired() || otp_token) {
    consumeOtpToken(normalized, 'register', otp_token);
    verified = true;
  }
  const info = db
    .prepare(`INSERT INTO users (name, phone, email, password_hash, address, phone_verified, terms_accepted_at, terms_version)
              VALUES (?, ?, ?, ?, ?, ?, datetime('now'), ?)`)
    .run(
      name.trim().slice(0, 80), normalized, cleanText(email, 120) || null, bcrypt.hashSync(password, 10),
      cleanText(address, 300) || null, verified ? 1 : 0, legal.TERMS_VERSION,
    );
  const user = getUser(info.lastInsertRowid);
  audit('register', { userId: user.id, details: { phone_verified: verified, terms_version: legal.TERMS_VERSION }, ip: req.ip });
  res.status(201).json({ token: signToken(user), user: publicUser(user) });
}));

router.post('/api/auth/login', loginLimiter, h((req, res) => {
  const { phone, password } = req.body || {};
  const user = findUserByPhone(str(phone));
  // Compte inconnu ou mauvais mot de passe : même message, même temps de calcul.
  const valid = bcrypt.compareSync(str(password), user ? user.password_hash : DUMMY_HASH);
  if (!user || !valid) {
    audit('login_failed', { userId: user?.id ?? null, details: { phone: str(phone).slice(0, 20) }, ip: req.ip });
    throw httpError(401, LOGIN_FAILED);
  }
  // Compte désactivé (livreur) : mot de passe correct mais connexion refusée, avec un message clair.
  if (isInactive(user)) {
    audit('login_refused_inactive', { userId: user.id, ip: req.ip });
    throw httpError(403, INACTIVE_MESSAGE);
  }
  audit(user.role === 'admin' ? 'admin_login' : user.role === 'driver' ? 'driver_login' : 'login', { userId: user.id, ip: req.ip });
  res.json({ token: signToken(user), user: publicUser(user) });
}));

router.post('/api/auth/otp/request', otpLimiter, h(async (req, res) => {
  const { phone, purpose } = req.body || {};
  if (!OTP_PURPOSES.includes(purpose)) throw httpError(400, 'Usage du code invalide');
  if (purpose === 'reset') return res.json(startPasswordReset(phone, req.ip));
  // Inscription : le code part par SMS (seulement si un prestataire est configuré).
  const normalized = requirePhone(phone);
  if (findUserByPhone(phone)) throw httpError(409, 'Ce numéro est déjà utilisé');
  checkOtpLimits(normalized, req.ip);
  const { code } = issueOtp(normalized, 'register', { ip: req.ip });
  const sent = await sendSms(normalized, `KALETA : votre code de vérification est ${code}. Valable 10 minutes.`);
  if (otpRequired() && !sent.ok) throw httpError(503, 'Envoi du SMS impossible pour le moment. Réessayez dans quelques minutes.');
  res.json({ sent: true, channel: otpRequired() ? 'sms' : 'none' });
}));

router.post('/api/auth/otp/verify', otpLimiter, h((req, res) => {
  const { phone, code, purpose } = req.body || {};
  if (!OTP_PURPOSES.includes(purpose)) throw httpError(400, 'Usage du code invalide');
  const normalized = requirePhone(phone);
  res.json({ otp_token: verifyOtp(normalized, purpose, str(code)) });
}));

router.post('/api/auth/password/forgot', otpLimiter, h((req, res) => {
  res.json(startPasswordReset((req.body || {}).phone, req.ip));
}));

router.post('/api/auth/password/reset', otpLimiter, h((req, res) => {
  const { phone, code, otp_token, new_password } = req.body || {};
  if (typeof new_password !== 'string' || new_password.length < 6) {
    throw httpError(400, 'Le nouveau mot de passe doit contenir au moins 6 caractères');
  }
  if (new_password.length > 200) throw httpError(400, 'Mot de passe trop long');
  const normalized = requirePhone(phone);
  const row = otp_token ? consumeOtpToken(normalized, 'reset', otp_token) : checkOtpCode(normalized, 'reset', str(code));
  const user = row.user_id ? getUser(row.user_id) : null;
  if (!user || user.deleted_at || normalizePhone(user.phone) !== normalized) throw httpError(400, OTP_INVALID);
  const viaSms = db.prepare(`SELECT channel FROM password_resets WHERE otp_id = ?`).get(row.id)?.channel === 'sms';
  transaction(() => {
    db.prepare(`UPDATE users SET password_hash = ?, token_version = COALESCE(token_version, 0) + 1,
                  phone_verified = CASE WHEN ? THEN 1 ELSE phone_verified END WHERE id = ?`)
      .run(bcrypt.hashSync(new_password, 10), viaSms ? 1 : 0, user.id);
    db.prepare(`UPDATE password_resets SET status = 'used', code = NULL WHERE otp_id = ?`).run(row.id);
  });
  resolveResetAlerts(row.id);
  audit('password_reset', { userId: user.id, ip: req.ip });
  const fresh = getUser(user.id);
  if (isInactive(fresh)) throw httpError(403, INACTIVE_MESSAGE);
  res.json({ token: signToken(fresh), user: publicUser(fresh) });
}));

function resolveResetAlerts(otpId) {
  const r = db.prepare('SELECT id FROM password_resets WHERE otp_id = ?').get(otpId);
  if (!r) return;
  db.prepare(`UPDATE alerts SET resolved = 1 WHERE type = 'password_reset' AND resolved = 0 AND json_extract(details, '$.resetId') = ?`)
    .run(r.id);
}

/**
 * Demandes qu'un membre du personnel a le droit de voir : jamais celles du propriétaire (sinon un gérant
 * prendrait son compte avec le code) ; celles des gérants, seulement par le propriétaire.
 */
function resetVisibility(actor) {
  return actor.admin_level === 'owner'
    ? `NOT (u.role = 'admin' AND u.admin_level = 'owner')`
    : `u.role != 'admin'`;
}

// Admin : demandes en attente (code en clair À COMMUNIQUER au client, mode sans SMS uniquement).
router.get('/api/admin/password-resets', requireManager, h((req, res) => {
  const rows = db
    .prepare(`SELECT r.*, u.name, u.role FROM password_resets r JOIN users u ON u.id = r.user_id
              WHERE r.status = 'pending' AND r.channel = 'admin' AND r.expires_at > ? AND (${resetVisibility(req.user)})
              ORDER BY r.id DESC LIMIT 100`)
    .all(Date.now());
  res.json(rows.map((r) => ({
    id: r.id,
    user_id: r.user_id,
    name: r.name,
    role: r.role,
    phone: r.phone,
    code: r.code,
    channel: r.channel,
    created_at: r.created_at,
    expires_at: new Date(r.expires_at).toISOString(),
  })));
}));

router.post('/api/admin/password-resets/:id/done', requireManager, h((req, res) => {
  const id = Number(req.params.id);
  const visible = db
    .prepare(`SELECT r.id FROM password_resets r JOIN users u ON u.id = r.user_id WHERE r.id = ? AND (${resetVisibility(req.user)})`)
    .get(id);
  if (!visible) throw httpError(404, 'Demande introuvable ou déjà traitée');
  const info = db
    .prepare(`UPDATE password_resets SET status = 'done', code = NULL, done_at = datetime('now'), done_by = ?
              WHERE id = ? AND status = 'pending'`)
    .run(req.user.id, id);
  if (info.changes === 0) throw httpError(404, 'Demande introuvable ou déjà traitée');
  db.prepare(`UPDATE alerts SET resolved = 1 WHERE type = 'password_reset' AND resolved = 0 AND json_extract(details, '$.resetId') = ?`)
    .run(id);
  audit('password_reset_communicated', { userId: req.user.id, details: { resetId: id }, ip: req.ip });
  res.json({ ok: true });
}));

router.get('/api/auth/me', requireUser, h((req, res) => {
  res.json(publicUser(req.account));
}));

// Le mot de passe n'est plus modifiable ici : voir PUT /api/auth/me/password.
router.put('/api/auth/me', requireUser, h((req, res) => {
  const { name, email, address, momo_phone } = req.body || {};
  const user = req.account;
  let momo = user.momo_phone;
  if (momo_phone !== undefined) {
    momo = typeof momo_phone === 'string' ? momo_phone.trim() : momo_phone == null ? '' : String(momo_phone).trim();
    if (momo && !PHONE_RE.test(momo)) throw httpError(400, 'Numéro mobile money invalide');
    momo = momo || null;
  }
  db.prepare('UPDATE users SET name = ?, email = ?, address = ?, momo_phone = ? WHERE id = ?').run(
    cleanText(name, 80) || user.name,
    email !== undefined ? cleanText(email, 120) || null : user.email,
    address !== undefined ? cleanText(address, 300) || null : user.address,
    momo,
    user.id,
  );
  res.json(publicUser(getUser(user.id)));
}));

router.put('/api/auth/me/password', requireUser, passwordLimiter, h((req, res) => {
  const { old_password, new_password } = req.body || {};
  if (!old_password) throw httpError(400, 'Ancien mot de passe requis');
  if (typeof new_password !== 'string' || new_password.length < 6) {
    throw httpError(400, 'Le nouveau mot de passe doit contenir au moins 6 caractères');
  }
  if (!bcrypt.compareSync(String(old_password), req.account.password_hash)) {
    audit('password_change_failed', { userId: req.account.id, ip: req.ip });
    throw httpError(401, 'Ancien mot de passe incorrect');
  }
  if (new_password.length > 200) throw httpError(400, 'Mot de passe trop long');
  // token_version + 1 : les autres appareils sont déconnectés ; nouveau jeton pour l'appareil courant.
  db.prepare('UPDATE users SET password_hash = ?, token_version = COALESCE(token_version, 0) + 1 WHERE id = ?')
    .run(bcrypt.hashSync(new_password, 10), req.account.id);
  audit('password_changed', { userId: req.account.id, ip: req.ip });
  const user = getUser(req.account.id);
  res.json({ ok: true, token: signToken(user), user: publicUser(user) });
}));

router.post('/api/auth/me/avatar', requireUser, (req, res) => {
  avatarUpload(req, res, (err) => {
    if (err) {
      const tooBig = err.code === 'LIMIT_FILE_SIZE';
      return res.status(tooBig ? 413 : 400).json({
        error: tooBig ? 'Image trop volumineuse (5 Mo max)' : 'Image invalide (JPEG, PNG ou WebP, max 5 Mo)',
      });
    }
    h((req2, res2) => {
      if (!req2.file) throw httpError(400, 'Image invalide (JPEG, PNG ou WebP, max 5 Mo)');
      const old = req2.account.avatar_url;
      db.prepare('UPDATE users SET avatar_url = ? WHERE id = ?').run(`/uploads/avatars/${req2.file.filename}`, req2.account.id);
      removeAvatarFile(old);
      res2.json(publicUser(getUser(req2.account.id)));
    })(req, res);
  });
});

router.delete('/api/auth/me/avatar', requireUser, h((req, res) => {
  removeAvatarFile(req.account.avatar_url);
  db.prepare('UPDATE users SET avatar_url = NULL WHERE id = ?').run(req.account.id);
  res.json(publicUser(getUser(req.account.id)));
}));

// orders_count : commandes non annulées ; total_spent : commandes livrées et réglées
// (espèces encaissées à la livraison, ou mobile money payé ; les remboursées sont exclues).
router.get('/api/auth/me/stats', requireUser, h((req, res) => {
  const row = db
    .prepare(
      `SELECT COUNT(CASE WHEN status != 'cancelled' THEN 1 END) AS orders_count,
              COALESCE(SUM(CASE WHEN status = 'delivered' AND payment_status IN ('paid', 'unpaid') THEN total END), 0) AS total_spent
       FROM orders WHERE user_id = ?`,
    )
    .get(req.account.id);
  res.json({ orders_count: Number(row.orders_count), total_spent: Number(row.total_spent) });
}));

router.get('/api/auth/me/addresses', requireUser, h((req, res) => {
  res.json(db.prepare('SELECT * FROM user_addresses WHERE user_id = ? ORDER BY id').all(req.account.id).map(mapAddress));
}));

router.post('/api/auth/me/addresses', requireUser, h((req, res) => {
  const f = addressFields(req.body || {});
  const n = db.prepare('SELECT COUNT(*) AS n FROM user_addresses WHERE user_id = ?').get(req.account.id).n;
  if (n >= MAX_ADDRESSES) throw httpError(400, `${MAX_ADDRESSES} adresses maximum : supprimez-en une d'abord`);
  const info = db
    .prepare('INSERT INTO user_addresses (user_id, label, address, lat, lng) VALUES (?, ?, ?, ?, ?)')
    .run(req.account.id, f.label, f.address, f.lat, f.lng);
  res.status(201).json(mapAddress(db.prepare('SELECT * FROM user_addresses WHERE id = ?').get(info.lastInsertRowid)));
}));

router.put('/api/auth/me/addresses/:id', requireUser, h((req, res) => {
  const current = db
    .prepare('SELECT * FROM user_addresses WHERE id = ? AND user_id = ?')
    .get(Number(req.params.id), req.account.id);
  if (!current) throw httpError(404, 'Adresse introuvable');
  const f = addressFields(req.body || {}, current);
  db.prepare('UPDATE user_addresses SET label = ?, address = ?, lat = ?, lng = ? WHERE id = ?')
    .run(f.label, f.address, f.lat, f.lng, current.id);
  res.json(mapAddress(db.prepare('SELECT * FROM user_addresses WHERE id = ?').get(current.id)));
}));

router.delete('/api/auth/me/addresses/:id', requireUser, h((req, res) => {
  const info = db
    .prepare('DELETE FROM user_addresses WHERE id = ? AND user_id = ?')
    .run(Number(req.params.id), req.account.id);
  if (info.changes === 0) throw httpError(404, 'Adresse introuvable');
  res.status(204).end();
}));

// Suppression du compte : anonymisation ; les commandes restent pour la comptabilité.
router.delete('/api/auth/me', requireUser, passwordLimiter, h((req, res) => {
  const user = req.account;
  const { password } = req.body || {};
  if (!password) throw httpError(400, 'Mot de passe requis');
  if (user.role === 'admin') throw httpError(403, 'Un compte administrateur ne peut pas être supprimé depuis l\'application');
  if (!bcrypt.compareSync(String(password), user.password_hash)) throw httpError(401, 'Mot de passe incorrect');
  transaction(() => {
    db.prepare('DELETE FROM user_addresses WHERE user_id = ?').run(user.id);
    db.prepare(
      `UPDATE users SET name = 'Compte supprimé', phone = ?, email = NULL, address = NULL, momo_phone = NULL,
         avatar_url = NULL, password_hash = ?, token_version = COALESCE(token_version, 0) + 1,
         deleted_at = datetime('now') WHERE id = ?`,
    ).run(
      `supprime-${user.id}-${crypto.randomBytes(6).toString('hex')}`,
      bcrypt.hashSync(crypto.randomBytes(32).toString('hex'), 10),
      user.id,
    );
  });
  removeAvatarFile(user.avatar_url);
  audit('account_deleted', { userId: user.id, ip: req.ip });
  res.status(204).end();
}));

module.exports = {
  router,
  publicUser,
  // Pour les tests.
  _otp: { issueOtp, checkOtpCode, verifyOtp, consumeOtpToken, checkOtpLimits, OTP_MAX_ATTEMPTS },
};
