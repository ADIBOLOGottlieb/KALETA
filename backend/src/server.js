const path = require('path');
const fs = require('fs');
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { rateLimit, ipKeyGenerator } = require('express-rate-limit');
const multer = require('multer');
const { db, transaction, getSettings } = require('./db');
const authModule = require('./auth');
const { requireAuth, requireAdmin, requireManager } = authModule;
const { seedIfEmpty } = require('./seed');
const { log, requestLogger, lastHourMetrics } = require('./logger');
const { audit, raiseAlert, checkOrder, startMonitoring, orderRate } = require('./monitor');
const payments = require('./payments');
const delivery = require('./delivery');
const { ORDER_STATUSES, adminTransitionError } = require('./order-status');
const notify = require('./notify');
const { computeDeliveryFee } = require('./delivery-fee');
const packs = require('./packs');
const hours = require('./hours');
const { createGeoRouter } = require('./geo');
const { createErrorRouter } = require('./error-log');
const zones = require('./zones');
const { createReportsRouter } = require('./reports');

/** Téléphone normalisé (auth.js) ; repli : numéro tel quel. */
const normalizePhone = (p) => (typeof authModule.normalizePhone === 'function' ? authModule.normalizePhone(p) : p) || p;

/** Module optionnel (legal.js, sms.js...) : null s'il n'existe pas. */
function optionalModule(name) {
  try {
    return require(name);
  } catch (e) {
    if (e.code === 'MODULE_NOT_FOUND' && String(e.message).includes(name.replace('./', ''))) return null;
    throw e;
  }
}
const legal = optionalModule('./legal');
const sms = optionalModule('./sms');

/** Réglages légaux et OTP exposés à l'app (fonctions de legal.js / sms.js, avec repli). */
function accountSettings(req) {
  let legalInfo = {};
  try {
    legalInfo = (typeof legal?.legalSettings === 'function' && legal.legalSettings(req)) || {};
  } catch (err) {
    log.warn('legalSettings', { error: err.message });
  }
  let otp = false;
  try {
    otp = typeof sms?.otpRequired === 'function' ? !!sms.otpRequired() : false;
  } catch (err) {
    log.warn('otpRequired', { error: err.message });
  }
  return {
    otp_required: otp,
    terms_version: legalInfo.terms_version ?? '2026-10',
    terms_url: legalInfo.terms_url ?? '/legal/cgu',
    privacy_url: legalInfo.privacy_url ?? '/legal/confidentialite',
  };
}

seedIfEmpty();
packs.ensurePacksCategory();

const app = express();
// TRUST_PROXY=1 (nombre de proxys devant le serveur, ex : Render) ou une liste d'IP / 'loopback'.
// Un nombre doit être passé en Number : en texte, Express le lirait comme une adresse IP.
const trustProxy = process.env.TRUST_PROXY ?? 'loopback';
app.set('trust proxy', /^\d+$/.test(trustProxy) ? Number(trustProxy) : trustProxy);
app.disable('x-powered-by');
// La CSP des pages de paiement est définie dans payments.js ; l'API ne sert que du JSON.
app.use(helmet({ contentSecurityPolicy: false, crossOriginResourcePolicy: { policy: 'cross-origin' } }));
app.use(cors());
app.use(requestLogger);

// Limite globale anti-abus : 300 requêtes / minute / IP.
app.use(
  rateLimit({
    windowMs: 60 * 1000,
    limit: 300,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    message: { error: 'Trop de requêtes, patientez un instant.' },
    handler: (req, res, _next, options) => {
      raiseAlert('rate_limit', 'warning', `Trafic anormal depuis l'IP ${req.ip}`, { key: req.ip }, 15);
      res.status(options.statusCode).json(options.message);
    },
  }),
);

// Le webhook de paiement lit le corps brut : il est monté avant express.json().
app.use(payments.router);
app.use(express.json({ limit: '100kb' }));

// Compte client (profil, mot de passe, avatar, adresses...) : backend/src/account.js.
// Suppression de son compte par un livreur : ses livraisons en cours repartent dans « À livrer ».
// (req.user est rempli par requireAuth d'account.js ; on agit une fois la réponse envoyée.)
app.delete('/api/auth/me', (req, res, next) => {
  res.on('finish', () => {
    if (res.statusCode < 300 && req.user?.id) {
      try {
        delivery.releaseDriverOrders(req.user.id, 'driver_account_deleted');
        delivery.forgetDriverLocation(req.user.id);
      } catch (err) {
        log.error('libération des livraisons', { userId: req.user.id, error: err.message });
      }
    }
  });
  next();
});
// Obligatoire : inscription et connexion sont dans account.js.
app.use(require('./account').router);
// Notifications push : enregistrement des jetons des appareils (push.js).
app.use(require('./push').router);
// Journal des erreurs : rapports de plantage de l'app et consultation par le gérant (error-log.js).
app.use(createErrorRouter());
// Cartes : adresse d'une position et itinéraire, via le serveur avec cache (geo.js).
app.use(createGeoRouter());
// Personnel : gérants et comptes cuisine (staff.js).
app.use(require('./staff').router);
// Bases existantes : un propriétaire (compte ADMIN_PHONE ou plus ancien gérant) que personne d'autre ne peut désactiver.
// (Après account.js, qui ajoute la colonne deleted_at.)
require('./staff').ensureOwner();

const UPLOAD_DIR = path.join(__dirname, '..', 'uploads');
fs.mkdirSync(UPLOAD_DIR, { recursive: true });
app.use('/uploads', express.static(UPLOAD_DIR));
app.use('/public', express.static(path.join(__dirname, '..', 'public')));

const upload = multer({
  storage: multer.diskStorage({
    destination: UPLOAD_DIR,
    filename: (_req, file, cb) => {
      const ext = (path.extname(file.originalname).toLowerCase().match(/^\.(jpe?g|png|webp)$/) || ['.jpg'])[0];
      cb(null, `${Date.now()}-${Math.round(Math.random() * 1e6)}${ext}`);
    },
  }),
  limits: { fileSize: 5 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => cb(null, /^image\/(jpeg|png|webp)$/.test(file.mimetype)),
});

// Quantité maximale d'un même article dans une commande (une seule constante, exposée dans /api/settings).
const MAX_QUANTITY_PER_ITEM = 999;

const PAYMENT_METHODS = ['cash', ...payments.MOBILE_METHODS];

/** Texte facultatif : '' si absent, 400 si ce n'est pas une chaîne (évite les 500 sur `.trim()`). */
function optText(value, label) {
  if (value === undefined || value === null) return '';
  if (typeof value !== 'string') throw httpError(400, `${label} invalide`);
  return value.trim();
}

/** Pagination ?limit=&before_id= (défaut 50, max 200). */
function pageParams(q) {
  const limit = Math.min(Math.max(Number.parseInt(q.limit, 10) || 50, 1), 200);
  const before = Number.parseInt(q.before_id, 10);
  return { limit, beforeId: Number.isInteger(before) && before > 0 ? before : null };
}

/** Liste paginée (tri par id décroissant) + en-tête X-Has-More. */
function sendPage(res, req, where, params) {
  const { limit, beforeId } = pageParams(req.query);
  const conds = where ? [where] : [];
  const args = [...params];
  if (beforeId) {
    conds.push('o.id < ?');
    args.push(beforeId);
  }
  const rows = loadOrders(conds.length ? `WHERE ${conds.join(' AND ')}` : '', args, { orderBy: 'o.id DESC', limit: limit + 1 });
  res.set('X-Has-More', rows.length > limit ? '1' : '0');
  res.set('Access-Control-Expose-Headers', 'X-Has-More');
  res.json(rows.slice(0, limit).map((o) => presentOrder(o, req.user)));
}

// Transforme les erreurs levées (sync ou async) en réponses JSON.
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

const orderLimiter = rateLimit({
  windowMs: 10 * 60 * 1000,
  limit: 10,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  keyGenerator: (req) => (req.user ? `user-${req.user.id}` : ipKeyGenerator(req.ip)),
  message: { error: 'Trop de commandes en peu de temps. Patientez quelques minutes.' },
});

/** Produit au format API (packs : contenu, valeur, économie, disponibilité selon les plats). */
const mapProduct = (p, byId) => packs.presentProduct(p, byId);

/**
 * Retire le jeton de paiement et ajoute l'URL de paiement pour le propriétaire de la commande,
 * ainsi que le suivi en direct (driver_location, eta_minutes : voir delivery.trackingInfo).
 */
function presentOrder(o, viewer) {
  if (!o) return o;
  const { payment_token, ...rest } = o;
  // pay_url uniquement pour le parcours navigateur (KADEV) ; sinon paiement par push USSD depuis l'app.
  const canPay =
    viewer && viewer.id === o.user_id && payment_token && payments.usesBrowserCheckout(o.payment_method) &&
    ['pending', 'failed', 'expired'].includes(o.payment_status) && o.status !== 'cancelled';
  return {
    ...rest,
    // Origine (application / vente au comptoir) et zone de livraison retenue.
    source: o.source === 'counter' ? 'counter' : 'app',
    dine_in: !!o.dine_in,
    customer_label: o.customer_label ?? null,
    delivery_zone_id: o.delivery_zone_id ?? null,
    delivery_zone_name: o.delivery_zone_name ?? null,
    delivery_distance_km: o.delivery_distance_km ?? null,
    ...delivery.trackingInfo(o, viewer),
    pay_url: canPay ? `/pay/${o.id}?t=${payment_token}` : null,
  };
}

// Commande + nom du client + livreur (driver_name, driver_phone : null sans livreur).
// Vente au comptoir : customer_name = nom donné par le client (customer_label) ou « Comptoir ».
const ORDER_SELECT = `SELECT o.*,
    CASE WHEN o.source = 'counter' THEN COALESCE(o.customer_label, 'Comptoir') ELSE u.name END AS customer_name,
    d.name AS driver_name, d.phone AS driver_phone
  FROM orders o JOIN users u ON u.id = o.user_id LEFT JOIN users d ON d.id = o.driver_id`;

function loadOrder(id) {
  const order = db.prepare(`${ORDER_SELECT} WHERE o.id = ?`).get(id);
  if (!order) return null;
  order.items = db.prepare('SELECT * FROM order_items WHERE order_id = ?').all(id);
  return order;
}

function loadOrders(where, params, { orderBy = 'o.created_at DESC, o.id DESC', limit = 200 } = {}) {
  const orders = db
    .prepare(`${ORDER_SELECT} ${where} ORDER BY ${orderBy} LIMIT ${Number(limit) || 200}`)
    .all(...params);
  if (orders.length === 0) return orders;
  const ids = orders.map((o) => o.id);
  const items = db
    .prepare(`SELECT * FROM order_items WHERE order_id IN (${ids.map(() => '?').join(',')})`)
    .all(...ids);
  for (const o of orders) o.items = items.filter((i) => i.order_id === o.id);
  return orders;
}

// ---------- Santé ----------

app.get('/api/health', (_req, res) => res.json({ status: 'ok', uptime: Math.round(process.uptime()) }));

// Inscription, connexion, mot de passe oublié et compte : voir account.js.

// ---------- Catalogue public ----------

/**
 * Frais de paiement exposés à l'app : taux par opérateur (commission de l'agrégateur ou réglage
 * admin) + provenance. payment_fee_percent = taux Flooz (compatibilité anciennes versions).
 */
function feeSettings() {
  const fee = payments.feeInfo();
  return {
    payment_fee_percent: fee.by_operator.flooz,
    payment_fee_percent_by_operator: fee.by_operator,
    payment_fee_source: fee.source,
    // Qui paie la commission : 'restaurant' (aucun frais facturé au client) ou 'client' (frais ajoutés au total).
    payment_fees_paid_by: getSettings().payment_fees_paid_by,
    // Réglage admin (repli quand l'agrégateur n'a pas de commission configurée).
    payment_fee_percent_settings: getSettings().payment_fee_percent,
  };
}

/**
 * Ouverture et frais de livraison exposés à l'app. is_open = état EFFECTIF (interrupteur manuel
 * et horaires) ; manual_open = interrupteur manuel seul.
 */
function openingAndFees(s) {
  const state = hours.openState(s);
  return {
    is_open: state.is_open,
    manual_open: s.is_open,
    hours_enabled: s.hours_enabled,
    opening_hours: s.opening_hours,
    next_opening_at: state.next_opening_at,
    next_closing_at: state.next_closing_at,
    delivery_fee_mode: s.delivery_fee_mode,
    delivery_fee_per_km: s.delivery_fee_per_km,
    delivery_free_km: s.delivery_free_km,
    delivery_max_km: s.delivery_max_km,
  };
}

app.get('/api/settings', h((req, res) => {
  const s = getSettings();
  res.json({
    delivery_fee: s.delivery_fee,
    min_order: s.min_order,
    ...openingAndFees(s),
    restaurant_phone: s.restaurant_phone,
    restaurant_address: s.restaurant_address,
    ...feeSettings(),
    payment_mode: payments.paymentInfo().mode,
    payment_provider: payments.paymentInfo().provider,
    max_quantity_per_item: MAX_QUANTITY_PER_ITEM,
    momo_unpaid_cancel_minutes: s.momo_unpaid_cancel_minutes,
    restaurant_lat: s.restaurant_lat,
    restaurant_lng: s.restaurant_lng,
    delivery_auto_confirm_hours: s.delivery_auto_confirm_hours,
    ...accountSettings(req),
  });
}));

/** Zone de livraison choisie (?zone_id= ou corps) : entier > 0, null si absente, 400 sinon. */
function parseZoneId(value) {
  if (value === undefined || value === null || value === '') return null;
  const n = typeof value === 'number' ? value : typeof value === 'string' && /^\d+$/.test(value.trim()) ? Number(value) : NaN;
  if (!Number.isInteger(n) || n <= 0) throw httpError(400, 'Zone de livraison invalide');
  return n;
}

/** Frais de livraison (delivery-fee.js) : zones actives chargées seulement en mode 'zone'. */
function deliveryQuote(settings, loc, zoneId) {
  return computeDeliveryFee(settings, loc, settings.delivery_fee_mode === 'zone' ? zones.activeZones() : [], zoneId);
}

// Devis des frais de livraison pour une position et/ou une zone (même calcul que la commande, delivery-fee.js).
app.get('/api/delivery/quote', h((req, res) => {
  const { lat, lng } = req.query;
  const given = (v) => v !== undefined && v !== '';
  let loc = null;
  if (given(lat) || given(lng)) loc = parseLocation({ lat, lng });
  res.json(deliveryQuote(getSettings(), loc, parseZoneId(req.query.zone_id)));
}));

app.get('/api/categories', h((_req, res) => {
  res.json(db.prepare('SELECT * FROM categories ORDER BY position, id').all());
}));

app.get('/api/products', h((req, res) => {
  const all = req.query.all === '1';
  const rows = db
    .prepare(`SELECT * FROM products ${all ? '' : 'WHERE available = 1'} ORDER BY popular DESC, name`)
    .all();
  const byId = packs.catalogById();
  const list = rows.map((p) => mapProduct(p, byId));
  // Catalogue client : un pack dont un plat est épuisé est masqué.
  res.json(all ? list : list.filter((p) => p.available));
}));

// ---------- Commandes client ----------

function parseLocation(location) {
  if (location == null) return null;
  const lat = Number(location.lat);
  const lng = Number(location.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    throw httpError(400, 'Position de livraison invalide');
  }
  const accuracy = Number(location.accuracy);
  return { lat, lng, accuracy: Number.isFinite(accuracy) ? accuracy : null };
}

/**
 * Lignes de commande : les prix sont TOUJOURS recalculés côté serveur à partir du catalogue.
 * @returns {{ product: object, qty: number }[]}
 */
function priceLines(items) {
  if (!Array.isArray(items) || items.length === 0 || items.length > 50) throw httpError(400, 'Votre panier est vide');
  const getProduct = db.prepare('SELECT * FROM products WHERE id = ?');
  const perProduct = new Map();
  return items.map((it) => {
    const qty = Number(it?.quantity);
    const p = getProduct.get(Number(it?.product_id));
    if (!p || !p.available) throw httpError(400, `Un article n'est plus disponible`);
    const details = packs.lineDetails(p); // pack : tous ses plats doivent être disponibles
    if (!Number.isInteger(qty) || qty < 1) throw httpError(400, 'Quantité invalide');
    const totalQty = (perProduct.get(p.id) || 0) + qty;
    if (totalQty > MAX_QUANTITY_PER_ITEM) {
      throw httpError(400, `Quantité maximale : ${MAX_QUANTITY_PER_ITEM} par article (${p.name})`);
    }
    perProduct.set(p.id, totalQty);
    return { product: p, qty, details };
  });
}

const ORDER_COLUMNS = ['user_id', 'mode', 'address', 'phone', 'note', 'payment_method', 'subtotal', 'delivery_fee', 'total',
  'payment_fee', 'payment_fee_percent', 'payment_status', 'payment_token', 'delivery_lat', 'delivery_lng', 'delivery_accuracy',
  'delivery_distance_km', 'delivery_zone_id', 'delivery_zone_name', 'status', 'source', 'dine_in', 'customer_label'];

/** Insère une commande et ses lignes (transaction) ; colonnes absentes = valeur par défaut. @returns id */
function insertOrder(fields, lines) {
  const row = { status: 'pending', source: 'app', dine_in: 0, customer_label: null, ...fields };
  return transaction(() => {
    const info = db
      .prepare(`INSERT INTO orders (${ORDER_COLUMNS.join(', ')}) VALUES (${ORDER_COLUMNS.map(() => '?').join(', ')})`)
      .run(...ORDER_COLUMNS.map((c) => row[c] ?? null));
    const insertItem = db.prepare(
      'INSERT INTO order_items (order_id, product_id, name, unit_price, quantity, details) VALUES (?, ?, ?, ?, ?, ?)',
    );
    for (const l of lines) {
      insertItem.run(info.lastInsertRowid, l.product.id, l.product.name, l.product.price, l.qty, l.details ?? null);
    }
    return Number(info.lastInsertRowid);
  });
}

/** Téléphone saisi → normalisé ; 400 s'il est invalide. */
function checkedPhone(raw) {
  const phone = String(normalizePhone(raw)).trim();
  if (!/^\+?[\d\s-]{8,20}$/.test(phone) || phone.replace(/\D/g, '').length < 8) throw httpError(400, 'Numéro de téléphone invalide');
  return phone;
}

app.post('/api/orders', requireAuth, orderLimiter, h((req, res) => {
  const settings = getSettings();
  // Interrupteur manuel et horaires d'ouverture (hours.js).
  const openState = hours.openState(settings);
  if (!openState.is_open) throw httpError(400, hours.closedMessage(openState));

  const body = req.body && typeof req.body === 'object' ? req.body : {};
  const { items, mode, payment_method, location } = body;
  if (!Array.isArray(items) || items.length === 0 || items.length > 50) throw httpError(400, 'Votre panier est vide');
  if (!['delivery', 'pickup'].includes(mode)) throw httpError(400, 'Mode de retrait invalide');
  const address = optText(body.address, 'Adresse');
  const note = optText(body.note, 'Note');
  if (mode === 'delivery' && !address) throw httpError(400, 'Adresse de livraison requise');
  const rawPhone = optText(body.phone, 'Numéro de téléphone');
  if (!rawPhone) throw httpError(400, 'Numéro de téléphone requis');
  const phone = checkedPhone(rawPhone);
  if (!PAYMENT_METHODS.includes(payment_method)) throw httpError(400, 'Moyen de paiement invalide');
  if (location != null && typeof location !== 'object') throw httpError(400, 'Position de livraison invalide');
  const loc = mode === 'delivery' ? parseLocation(location) : null;
  const zoneId = mode === 'delivery' ? parseZoneId(body.zone_id) : null;

  const lines = priceLines(items);
  const subtotal = lines.reduce((s, l) => s + l.product.price * l.qty, 0);
  if (subtotal < settings.min_order) throw httpError(400, `Commande minimum : ${settings.min_order} FCFA`);
  // Frais de livraison recalculés par le serveur (jamais le montant envoyé par l'app) : fixe, distance ou zone.
  const quote = mode === 'delivery' ? deliveryQuote(settings, loc, zoneId) : null;
  if (quote && !quote.within_zone) throw httpError(400, quote.message);
  const deliveryFee = quote ? quote.fee : 0;
  // Frais de paiement selon payment_fees_paid_by (payments/core.js) ; le taux est figé sur la commande
  // (commission et net calculés au même taux au moment du paiement).
  const { fee: paymentFee, percent: paymentFeePercent } = payments.paymentFeeDetails(subtotal + deliveryFee, payment_method);
  const mobile = payments.isMobileMoney(payment_method);

  const orderId = insertOrder({
    user_id: req.user.id, mode, address: mode === 'delivery' ? address.slice(0, 300) : null, phone: phone.slice(0, 20),
    note: note.slice(0, 300) || null, payment_method, subtotal, delivery_fee: deliveryFee, total: subtotal + deliveryFee + paymentFee,
    payment_fee: paymentFee, payment_fee_percent: paymentFeePercent, payment_status: mobile ? 'pending' : 'unpaid',
    payment_token: mobile ? payments.newToken() : null, delivery_lat: loc?.lat ?? null, delivery_lng: loc?.lng ?? null,
    delivery_accuracy: loc?.accuracy ?? null, delivery_distance_km: quote?.distance_km ?? null,
    delivery_zone_id: quote?.zone_id ?? null, delivery_zone_name: quote?.zone_name ?? null,
  }, lines);

  const order = loadOrder(orderId);
  audit('order_created', { userId: req.user.id, details: { orderId, total: order.total, payment_method }, ip: req.ip });
  checkOrder(order, { name: order.customer_name });
  notify.newOrder(order);
  res.status(201).json(presentOrder(order, req.user));
}));

// Pagination : ?limit=&before_id= ; en-tête X-Has-More: 1|0.
// Commandes passées dans l'app uniquement (les ventes au comptoir d'un caissier n'y apparaissent pas).
app.get('/api/orders', requireAuth, h((req, res) => {
  sendPage(res, req, `o.user_id = ? AND o.source = 'app'`, [req.user.id]);
}));

app.get('/api/orders/:id', requireAuth, h((req, res) => {
  const order = loadOrder(Number(req.params.id));
  // Le livreur attribué peut aussi relire la commande.
  const allowed = order && (order.user_id === req.user.id || req.user.role === 'admin' || (order.driver_id && order.driver_id === req.user.id));
  if (!allowed) throw httpError(404, 'Commande introuvable');
  res.json(presentOrder(order, req.user));
}));

// Nouveau lien de paiement (après un échec ou un abandon).
app.post('/api/orders/:id/pay', requireAuth, h((req, res) => {
  const order = loadOrder(Number(req.params.id));
  if (!order || order.user_id !== req.user.id) throw httpError(404, 'Commande introuvable');
  if (!payments.isMobileMoney(order.payment_method)) throw httpError(400, 'Cette commande se paie en espèces');
  if (order.payment_status === 'paid') throw httpError(400, 'Cette commande est déjà payée');
  if (order.payment_status === 'refunded') throw httpError(400, 'Cette commande a été remboursée : passez une nouvelle commande');
  if (order.status === 'cancelled') throw httpError(400, 'Cette commande est annulée');
  if (order.status !== 'pending') throw httpError(400, 'Cette commande ne peut plus être payée en ligne');
  db.prepare(`UPDATE orders SET payment_token = ?, payment_status = 'pending', updated_at = datetime('now')
              WHERE id = ? AND payment_status NOT IN ('paid', 'refunded')`)
    .run(payments.newToken(), order.id);
  res.json(presentOrder(loadOrder(order.id), req.user));
}));

app.post('/api/orders/:id/cancel', requireAuth, h((req, res) => {
  const order = loadOrder(Number(req.params.id));
  if (!order || order.user_id !== req.user.id) throw httpError(404, 'Commande introuvable');
  if (order.status !== 'pending') throw httpError(400, 'Cette commande ne peut plus être annulée');
  if (order.payment_status === 'paid') {
    throw httpError(400, 'Commande déjà payée : appelez le restaurant pour l\'annuler et être remboursé');
  }
  const info = db.prepare(`UPDATE orders SET status = 'cancelled', updated_at = datetime('now')
                           WHERE id = ? AND status = 'pending' AND payment_status NOT IN ('paid', 'refunded')`).run(order.id);
  if (!info.changes) throw httpError(409, 'La commande vient de changer : rechargez-la');
  payments.cancelPendingAttempts(order.id, 'Commande annulée par le client');
  audit('order_cancelled', { userId: req.user.id, details: { orderId: order.id, by: 'client' }, ip: req.ip });
  res.json(presentOrder(loadOrder(order.id), req.user));
}));

// Changer d'opérateur mobile money (Flooz ↔ Mixx) avant de payer : frais et total recalculés.
app.post('/api/orders/:id/payment-method', requireAuth, h((req, res) => {
  const method = req.body?.payment_method;
  if (!payments.MOBILE_METHODS.includes(method)) throw httpError(400, 'Moyen de paiement invalide (flooz ou mixx)');
  const order = loadOrder(Number(req.params.id));
  if (!order || order.user_id !== req.user.id) throw httpError(404, 'Commande introuvable');
  if (!payments.isMobileMoney(order.payment_method)) throw httpError(400, 'Cette commande se paie en espèces');
  if (order.payment_status === 'paid') throw httpError(400, 'Cette commande est déjà payée');
  if (order.payment_status === 'refunded') throw httpError(400, 'Cette commande a été remboursée');
  if (order.status !== 'pending') throw httpError(400, 'Le moyen de paiement ne peut plus être changé');
  const pendingAttempt = db
    .prepare(`SELECT id FROM payments WHERE order_id = ? AND status = 'pending'
                AND (expires_at IS NULL OR expires_at > datetime('now')) LIMIT 1`)
    .get(order.id);
  if (pendingAttempt) throw httpError(400, 'Une demande de paiement est en cours : attendez son expiration');
  if (order.payment_method === method) return res.json(presentOrder(order, req.user));
  // Même calcul qu'à la création (payment_fees_paid_by), au taux du nouvel opérateur.
  const { fee, percent } = payments.paymentFeeDetails(order.subtotal + order.delivery_fee, method);
  const total = order.subtotal + order.delivery_fee + fee;
  const info = db
    .prepare(`UPDATE orders SET payment_method = ?, payment_fee = ?, payment_fee_percent = ?, total = ?, updated_at = datetime('now')
              WHERE id = ? AND status = 'pending' AND payment_method = ? AND payment_status NOT IN ('paid', 'refunded')`)
    .run(method, fee, percent, total, order.id, order.payment_method);
  if (!info.changes) throw httpError(409, 'La commande vient de changer : rechargez-la');
  audit('payment_method_changed', {
    userId: req.user.id,
    details: { orderId: order.id, from: order.payment_method, to: method, total: [order.total, total] },
    ip: req.ip,
  });
  res.json(presentOrder(loadOrder(order.id), req.user));
}));

// ---------- Admin ----------
// Tout le personnel (requireAdmin) : commandes, statut, disponibilité des plats. Le reste : gérant (requireManager).

// Chiffre « encaissé ou à encaisser » : commande non annulée ET (espèces OU payée en ligne).
const COUNTED = `status != 'cancelled' AND (payment_method = 'cash' OR payment_status = 'paid')`;

/** Évolution en % (1 décimale) ; null si la référence vaut 0. */
const changePercent = (now, before) => (before ? Math.round(((now - before) / before) * 1000) / 10 : null);

/** Fenêtre de 2 heures consécutives la plus chargée (end_hour peut valoir 24) ; null sans commande. */
function peakWindow(hourly) {
  let best = null;
  for (let hour = 0; hour <= 22; hour++) {
    const n = hourly[hour] + hourly[hour + 1];
    if (n > 0 && (!best || n > best.orders)) best = { start_hour: hour, end_hour: hour + 2, orders: n };
  }
  return best;
}

app.get('/api/admin/stats', requireManager, h((_req, res) => {
  const today = db
    .prepare(
      `SELECT COUNT(*) AS orders, COALESCE(SUM(CASE WHEN ${COUNTED} THEN total END), 0) AS revenue
       FROM orders WHERE date(created_at) = date('now')`,
    )
    .get();
  // Même jour la semaine dernière, jusqu'à la même heure (comparaison à moment égal de la journée).
  const sameDayLastWeek = db
    .prepare(
      `SELECT COUNT(*) AS orders, COALESCE(SUM(CASE WHEN ${COUNTED} THEN total END), 0) AS revenue
       FROM orders WHERE date(created_at) = date('now', '-7 days') AND created_at <= datetime('now', '-7 days')`,
    )
    .get();
  // Commandes non annulées des 30 derniers jours, par heure (Lomé = UTC).
  const hourly = Array(24).fill(0);
  for (const r of db
    .prepare(
      `SELECT CAST(strftime('%H', created_at) AS INTEGER) AS hour, COUNT(*) AS n FROM orders
       WHERE status != 'cancelled' AND created_at >= datetime('now', '-30 days') GROUP BY hour`,
    )
    .all()) {
    if (r.hour >= 0 && r.hour < 24) hourly[r.hour] = Number(r.n);
  }
  // Total : commandes livrées, hors remboursées.
  const total = db
    .prepare(`SELECT COUNT(*) AS orders, COALESCE(SUM(total), 0) AS revenue FROM orders
              WHERE status = 'delivered' AND payment_status != 'refunded'`)
    .get();
  const active = db
    .prepare(`SELECT COUNT(*) AS n FROM orders WHERE status NOT IN ('delivered', 'cancelled')`)
    .get().n;
  const pending = db.prepare(`SELECT COUNT(*) AS n FROM orders WHERE status = 'pending'`).get().n;
  const customers = db.prepare(`SELECT COUNT(*) AS n FROM users WHERE role = 'customer'`).get().n;
  const alerts = db.prepare(`SELECT COUNT(*) AS n FROM alerts WHERE resolved = 0`).get().n;
  const topProducts = db
    .prepare(
      `SELECT oi.name, SUM(oi.quantity) AS quantity, SUM(oi.quantity * oi.unit_price) AS revenue
       FROM order_items oi JOIN orders o ON o.id = oi.order_id
       WHERE o.status != 'cancelled' AND o.payment_status != 'refunded' GROUP BY oi.name ORDER BY quantity DESC LIMIT 5`,
    )
    .all();
  // Aujourd'hui par canal (application / comptoir), mêmes règles que `today`.
  const channelRows = db
    .prepare(
      `SELECT source AS channel, COUNT(*) AS orders, COALESCE(SUM(CASE WHEN ${COUNTED} THEN total END), 0) AS revenue
       FROM orders WHERE date(created_at) = date('now') GROUP BY source`,
    )
    .all();
  const byChannelToday = ['app', 'counter'].map((channel) => {
    const r = channelRows.find((x) => x.channel === channel);
    return { channel, orders: Number(r?.orders ?? 0), revenue: Number(r?.revenue ?? 0) };
  });
  const last7Days = db
    .prepare(
      `SELECT date(created_at) AS day, COUNT(*) AS orders,
              COALESCE(SUM(CASE WHEN ${COUNTED} THEN total END), 0) AS revenue
       FROM orders WHERE date(created_at) >= date('now', '-6 days')
       GROUP BY day ORDER BY day`,
    )
    .all();
  res.json({
    today,
    total,
    active,
    pending,
    customers,
    alerts,
    topProducts,
    last7Days,
    same_day_last_week: { orders: Number(sameDayLastWeek.orders), revenue: Number(sameDayLastWeek.revenue) },
    revenue_change_percent: changePercent(today.revenue, sameDayLastWeek.revenue),
    orders_change_percent: changePercent(today.orders, sameDayLastWeek.orders),
    hourly,
    peak_window: peakWindow(hourly),
    by_channel_today: byChannelToday,
  });
}));

// Pagination : ?limit=&before_id= ; en-tête X-Has-More: 1|0. Filtres : ?status=, ?source=app|counter.
app.get('/api/admin/orders', requireAdmin, h((req, res) => {
  const { status, source } = req.query;
  const conds = [];
  const params = [];
  if (status === 'active') conds.push(`o.status NOT IN ('delivered', 'cancelled')`);
  else if (typeof status === 'string' && ORDER_STATUSES.includes(status)) {
    conds.push('o.status = ?');
    params.push(status);
  }
  if (source !== undefined && source !== '') {
    if (!['app', 'counter'].includes(source)) throw httpError(400, 'Origine invalide (app ou counter)');
    conds.push('o.source = ?');
    params.push(source);
  }
  sendPage(res, req, conds.join(' AND '), params);
}));

// ---------- Vente au comptoir (caisse) : propriétaire et gérants ----------
// Pas de minimum de commande, pas d'horaires, pas de limiteur : le personnel est sur place.
// La commande appartient au membre du personnel (user_id) : il lance lui-même le push USSD
// (POST /api/orders/:id/payments) et suit le paiement (GET /api/orders/:id/payments/current).
app.post('/api/admin/counter-orders', requireAdmin, h((req, res) => {
  const body = req.body && typeof req.body === 'object' ? req.body : {};
  const { service, payment_method } = body;
  if (!['dine_in', 'takeaway'].includes(service)) throw httpError(400, 'Service invalide (sur place ou à emporter)');
  if (!PAYMENT_METHODS.includes(payment_method)) throw httpError(400, 'Moyen de paiement invalide');
  const customerName = optText(body.customer_name, 'Nom du client').slice(0, 60);
  const note = optText(body.note, 'Note');
  const rawPhone = optText(body.phone, 'Numéro de téléphone');
  const mobile = payments.isMobileMoney(payment_method);
  if (mobile && !rawPhone) throw httpError(400, 'Numéro de téléphone requis pour le paiement mobile money');
  const settings = getSettings();
  const phone = rawPhone ? checkedPhone(rawPhone) : String(settings.restaurant_phone || '').trim() || '-';

  const lines = priceLines(body.items);
  const subtotal = lines.reduce((s, l) => s + l.product.price * l.qty, 0);
  // Pas de livraison ; frais de paiement selon payment_fees_paid_by (comme dans l'app).
  const { fee: paymentFee, percent: paymentFeePercent } = payments.paymentFeeDetails(subtotal, payment_method);

  const orderId = insertOrder({
    user_id: req.user.id, mode: 'pickup', address: null, phone: phone.slice(0, 20), note: note.slice(0, 300) || null,
    payment_method, subtotal, delivery_fee: 0, total: subtotal + paymentFee, payment_fee: paymentFee,
    payment_fee_percent: paymentFeePercent,
    // Espèces : encaissé au comptoir, la commande part directement en cuisine.
    status: mobile ? 'pending' : 'confirmed',
    payment_status: mobile ? 'pending' : 'unpaid',
    payment_token: mobile ? payments.newToken() : null,
    source: 'counter', dine_in: service === 'dine_in' ? 1 : 0, customer_label: customerName || null,
  }, lines);

  const order = loadOrder(orderId);
  audit('counter_order_created', {
    userId: req.user.id,
    details: { orderId, total: order.total, payment_method, service, items: lines.length },
    ip: req.ip,
  });
  checkOrder(order, { name: order.customer_name });
  res.status(201).json(presentOrder(order, req.user));
}));

app.patch('/api/admin/orders/:id/status', requireAdmin, h((req, res) => {
  const { status } = req.body || {};
  if (typeof status !== 'string' || !ORDER_STATUSES.includes(status)) throw httpError(400, 'Statut invalide');
  const order = loadOrder(Number(req.params.id));
  if (!order) throw httpError(404, 'Commande introuvable');
  // Machine d'états (order-status.js) : statuts définitifs, livraison sans livreur, retrait...
  const refused = adminTransitionError(order, status);
  if (refused) throw httpError(400, refused);
  if (order.status === status) return res.json(presentOrder(order, req.user));
  // Une commande mobile money n'est préparée qu'une fois le paiement reçu.
  if (status !== 'cancelled' && payments.isMobileMoney(order.payment_method) && order.payment_status !== 'paid') {
    throw httpError(400, order.payment_status === 'refunded'
      ? 'Commande remboursée : elle ne peut plus être lancée'
      : 'Paiement pas encore reçu : impossible de lancer la commande');
  }
  // Retour à une étape avant la livraison : le livreur est retiré (la commande repart dans « À livrer »).
  const backBeforeDelivery = ['pending', 'confirmed', 'preparing', 'ready'].includes(status) && order.driver_id;
  // Mise à jour conditionnée au statut lu : deux changements simultanés ne s'écrasent pas.
  const info = backBeforeDelivery
    ? db.prepare(`UPDATE orders SET status = ?, driver_id = NULL, picked_up_at = NULL, driver_delivered_at = NULL,
                    updated_at = datetime('now') WHERE id = ? AND status = ?`).run(status, order.id, order.status)
    : db.prepare(`UPDATE orders SET status = ?, updated_at = datetime('now') WHERE id = ? AND status = ?`)
      .run(status, order.id, order.status);
  if (!info.changes) throw httpError(409, 'La commande vient de changer : rechargez-la');
  if (status === 'cancelled') payments.cancelPendingAttempts(order.id, 'Commande annulée par le restaurant');
  audit('order_status', { userId: req.user.id, details: { orderId: order.id, from: order.status, to: status, driverId: order.driver_id ?? null, ...(backBeforeDelivery ? { driver_removed: true } : {}) }, ip: req.ip });
  if (status === 'cancelled' && order.payment_status === 'paid') {
    raiseAlert('refund_needed', 'warning', `Commande n°${order.id} annulée alors qu'elle est payée (${order.total} FCFA) : remboursement à prévoir`,
      { key: `order-${order.id}`, orderId: order.id }, 0);
  }
  const updated = loadOrder(order.id);
  notify.statusChanged(updated, status);
  res.json(presentOrder(updated, req.user));
}));

app.post('/api/admin/categories', requireManager, h((req, res) => {
  const { position } = req.body || {};
  const name = optText(req.body?.name, 'Nom');
  const icon = optText(req.body?.icon, 'Icône');
  if (!name) throw httpError(400, 'Nom requis');
  const info = db
    .prepare('INSERT INTO categories (name, icon, position) VALUES (?, ?, ?)')
    .run(name, icon || null, Number(position) || 0);
  audit('category_created', { userId: req.user.id, details: { name }, ip: req.ip });
  res.status(201).json(db.prepare('SELECT * FROM categories WHERE id = ?').get(info.lastInsertRowid));
}));

app.put('/api/admin/categories/:id', requireManager, h((req, res) => {
  const { position } = req.body || {};
  const name = optText(req.body?.name, 'Nom');
  const icon = optText(req.body?.icon, 'Icône');
  if (!name) throw httpError(400, 'Nom requis');
  const info = db
    .prepare('UPDATE categories SET name = ?, icon = ?, position = ? WHERE id = ?')
    .run(name, icon || null, Number(position) || 0, Number(req.params.id));
  if (info.changes === 0) throw httpError(404, 'Catégorie introuvable');
  res.json(db.prepare('SELECT * FROM categories WHERE id = ?').get(Number(req.params.id)));
}));

app.delete('/api/admin/categories/:id', requireManager, h((req, res) => {
  db.prepare('DELETE FROM categories WHERE id = ?').run(Number(req.params.id));
  audit('category_deleted', { userId: req.user.id, details: { id: Number(req.params.id) }, ip: req.ip });
  res.status(204).end();
}));

/** Champs d'un produit ; pack_items (facultatif) = contenu d'un pack, [] ou null pour un plat simple. */
function productFields(body, selfId = null) {
  const { price, category_id, available, popular } = body || {};
  const name = optText(body?.name, 'Nom');
  const description = optText(body?.description, 'Description');
  const imageUrl = optText(body?.image_url, 'Image');
  if (!name) throw httpError(400, 'Nom requis');
  const p = Math.round(Number(price));
  if (!(p > 0 && p < 10_000_000)) throw httpError(400, 'Prix invalide');
  const cat = category_id ? Number(category_id) : null;
  if (cat !== null && !Number.isInteger(cat)) throw httpError(400, 'Catégorie invalide');
  const packItems = packs.parsePackItems(body?.pack_items, selfId);
  return [cat, name, description || null, p, imageUrl || null, available === false ? 0 : 1, popular ? 1 : 0, packItems];
}

app.post('/api/admin/products', requireManager, h((req, res) => {
  const info = db
    .prepare(
      `INSERT INTO products (category_id, name, description, price, image_url, available, popular, pack_items)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(...productFields(req.body));
  audit('product_created', { userId: req.user.id, details: { id: info.lastInsertRowid, name: req.body.name }, ip: req.ip });
  res.status(201).json(mapProduct(db.prepare('SELECT * FROM products WHERE id = ?').get(info.lastInsertRowid)));
}));

app.put('/api/admin/products/:id', requireManager, h((req, res) => {
  const before = db.prepare('SELECT price FROM products WHERE id = ?').get(Number(req.params.id));
  const info = db
    .prepare(
      `UPDATE products SET category_id = ?, name = ?, description = ?, price = ?, image_url = ?,
       available = ?, popular = ?, pack_items = ? WHERE id = ?`,
    )
    .run(...productFields(req.body, Number(req.params.id)), Number(req.params.id));
  if (info.changes === 0) throw httpError(404, 'Produit introuvable');
  const after = db.prepare('SELECT * FROM products WHERE id = ?').get(Number(req.params.id));
  audit('product_updated', {
    userId: req.user.id,
    details: { id: after.id, name: after.name, ...(before.price !== after.price ? { price: [before.price, after.price] } : {}) },
    ip: req.ip,
  });
  res.json(mapProduct(after));
}));

app.patch('/api/admin/products/:id/availability', requireAdmin, h((req, res) => {
  const info = db
    .prepare('UPDATE products SET available = ? WHERE id = ?')
    .run(req.body?.available ? 1 : 0, Number(req.params.id));
  if (info.changes === 0) throw httpError(404, 'Produit introuvable');
  res.json(mapProduct(db.prepare('SELECT * FROM products WHERE id = ?').get(Number(req.params.id))));
}));

app.delete('/api/admin/products/:id', requireManager, h((req, res) => {
  db.prepare('DELETE FROM products WHERE id = ?').run(Number(req.params.id));
  audit('product_deleted', { userId: req.user.id, details: { id: Number(req.params.id) }, ip: req.ip });
  res.status(204).end();
}));

app.post('/api/admin/upload', requireManager, upload.single('image'), h((req, res) => {
  if (!req.file) throw httpError(400, 'Image invalide (JPEG, PNG ou WebP, max 5 Mo)');
  res.status(201).json({ url: `/uploads/${req.file.filename}` });
}));

// 200 comptes au plus ; ?q= recherche (nom, téléphone, e-mail).
app.get('/api/admin/users', requireManager, h((req, res) => {
  const q = typeof req.query.q === 'string' ? req.query.q.trim().slice(0, 50) : '';
  const params = [];
  let where = '';
  if (q) {
    // « ! » sert de caractère d'échappement pour % et _ saisis par l'admin.
    const like = `%${q.replace(/[!%_]/g, (c) => `!${c}`)}%`;
    const digits = q.replace(/\D/g, '');
    where = `WHERE (u.name LIKE ? ESCAPE '!' OR u.phone LIKE ? ESCAPE '!' OR u.email LIKE ? ESCAPE '!'${digits.length >= 3 ? ` OR REPLACE(REPLACE(u.phone, ' ', ''), '+', '') LIKE ?` : ''})`;
    params.push(like, like, like);
    if (digits.length >= 3) params.push(`%${digits}%`);
  }
  res.json(
    db
      .prepare(
        `SELECT u.id, u.name, u.phone, u.email, u.role, u.address, u.created_at, u.active,
                COUNT(o.id) AS orders_count,
                COALESCE(SUM(CASE WHEN o.status = 'delivered' AND o.payment_status != 'refunded' THEN o.total END), 0) AS total_spent
         FROM users u LEFT JOIN orders o ON o.user_id = u.id AND o.source = 'app'
         ${where}
         GROUP BY u.id ORDER BY u.created_at DESC, u.id DESC LIMIT 200`,
      )
      .all(...params),
  );
}));

app.put('/api/admin/settings', requireManager, h((req, res) => {
  const numeric = {
    delivery_fee: [0, 100000],
    min_order: [0, 1000000],
    payment_fee_percent: [0, 10],
    spike_min_orders: [2, 1000],
    spike_factor: [1, 50],
    high_amount_alert: [1000, 100000000],
    momo_unpaid_cancel_minutes: [5, 1440],
    delivery_auto_confirm_hours: [1, 72],
    // Frais de livraison selon la distance (delivery-fee.js) ; delivery_max_km 0 = illimité.
    delivery_fee_per_km: [0, 50000],
    delivery_free_km: [0, 100],
    delivery_max_km: [0, 200],
  };
  const text = ['restaurant_phone', 'restaurant_address'];
  const body = req.body && typeof req.body === 'object' ? req.body : {};
  if (body.delivery_fee_mode !== undefined && !['fixed', 'distance', 'zone'].includes(body.delivery_fee_mode)) {
    throw httpError(400, 'Mode de frais de livraison invalide (fixed, distance ou zone)');
  }
  if (body.payment_fees_paid_by !== undefined && !['restaurant', 'client'].includes(body.payment_fees_paid_by)) {
    throw httpError(400, 'Valeur invalide pour payment_fees_paid_by (restaurant ou client)');
  }
  if (body.hours_enabled !== undefined && ![true, false, 0, 1].includes(body.hours_enabled)) {
    throw httpError(400, 'Valeur invalide pour hours_enabled');
  }
  // Horaires d'ouverture : validés (hours.js) et enregistrés au format JSON normalisé.
  let openingHours;
  if (body.opening_hours !== undefined) {
    const r = hours.validateOpeningHours(body.opening_hours);
    if (r.error) throw httpError(400, r.error);
    openingHours = r.value;
  }
  const upsert = db.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value');
  const changed = {};
  // Position du restaurant : les deux coordonnées ensemble (ou aucune), null pour effacer.
  const hasLat = req.body?.restaurant_lat !== undefined;
  const hasLng = req.body?.restaurant_lng !== undefined;
  let position;
  if (hasLat || hasLng) {
    if (hasLat !== hasLng) throw httpError(400, 'Position du restaurant : latitude et longitude doivent être envoyées ensemble');
    const rawLat = req.body.restaurant_lat;
    const rawLng = req.body.restaurant_lng;
    if (rawLat === null && rawLng === null) {
      position = null;
    } else {
      const toNum = (v) => (typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN);
      const lat = toNum(rawLat);
      const lng = toNum(rawLng);
      if (!Number.isFinite(lat) || lat < -90 || lat > 90) throw httpError(400, 'Latitude du restaurant invalide (entre -90 et 90)');
      if (!Number.isFinite(lng) || lng < -180 || lng > 180) throw httpError(400, 'Longitude du restaurant invalide (entre -180 et 180)');
      position = { lat, lng };
    }
  }
  transaction(() => {
    if (position !== undefined) {
      if (position === null) {
        db.prepare("DELETE FROM settings WHERE key IN ('restaurant_lat', 'restaurant_lng')").run();
      } else {
        upsert.run('restaurant_lat', String(position.lat));
        upsert.run('restaurant_lng', String(position.lng));
      }
      changed.restaurant_lat = position ? position.lat : null;
      changed.restaurant_lng = position ? position.lng : null;
    }
    for (const [key, [min, max]] of Object.entries(numeric)) {
      if (req.body?.[key] === undefined) continue;
      const v = Number(req.body[key]);
      if (!Number.isFinite(v) || v < min || v > max) throw httpError(400, `Valeur invalide pour ${key} (entre ${min} et ${max})`);
      if (key === 'momo_unpaid_cancel_minutes' && !Number.isInteger(v)) throw httpError(400, 'Délai en minutes entières');
      if (key === 'delivery_auto_confirm_hours' && !Number.isInteger(v)) throw httpError(400, 'Délai en heures entières');
      upsert.run(key, String(v));
      changed[key] = v;
    }
    for (const key of text) {
      if (req.body?.[key] === undefined) continue;
      upsert.run(key, String(req.body[key]).trim().slice(0, 200));
      changed[key] = req.body[key];
    }
    // is_open = interrupteur manuel (l'ouverture effective dépend aussi des horaires).
    if (req.body?.is_open !== undefined) {
      upsert.run('is_open', req.body.is_open ? '1' : '0');
      changed.is_open = !!req.body.is_open;
    }
    if (body.delivery_fee_mode !== undefined) {
      upsert.run('delivery_fee_mode', body.delivery_fee_mode);
      changed.delivery_fee_mode = body.delivery_fee_mode;
    }
    // Commission de l'agrégateur : s'applique aux NOUVELLES commandes (les existantes gardent leur total).
    if (body.payment_fees_paid_by !== undefined) {
      upsert.run('payment_fees_paid_by', body.payment_fees_paid_by);
      changed.payment_fees_paid_by = body.payment_fees_paid_by;
    }
    if (body.hours_enabled !== undefined) {
      upsert.run('hours_enabled', body.hours_enabled ? '1' : '0');
      changed.hours_enabled = !!body.hours_enabled;
    }
    if (openingHours !== undefined) {
      upsert.run('opening_hours', JSON.stringify(openingHours));
      changed.opening_hours = openingHours;
    }
  });
  audit('settings_changed', { userId: req.user.id, details: changed, ip: req.ip });
  // payment_fee_percent est validé et enregistré, mais ignoré pour le calcul tant que la commission
  // de l'agrégateur est définie en variable d'environnement (payment_fee_source = 'aggregator').
  // Réponse au même format que GET /api/settings.
  const s = getSettings();
  res.json({
    ...s,
    ...openingAndFees(s),
    ...feeSettings(),
    payment_mode: payments.paymentInfo().mode,
    payment_provider: payments.paymentInfo().provider,
    max_quantity_per_item: MAX_QUANTITY_PER_ITEM,
    ...accountSettings(req),
  });
}));

// ---------- Sécurité & monitoring ----------

app.get('/api/admin/monitoring', requireManager, h((_req, res) => {
  const count = (sql) => db.prepare(sql).get().n;
  const { last10, baselinePer10 } = orderRate();
  res.json({
    payment: payments.paymentInfo(),
    http: lastHourMetrics(),
    orders: {
      last10min: last10,
      baselinePer10min: Math.round(baselinePer10 * 10) / 10,
      lastHour: count(`SELECT COUNT(*) AS n FROM orders WHERE created_at >= datetime('now', '-1 hour')`),
    },
    payments: {
      paid24h: count(`SELECT COUNT(*) AS n FROM payments WHERE status = 'paid' AND updated_at >= datetime('now', '-1 day')`),
      failed24h: count(`SELECT COUNT(*) AS n FROM payments WHERE status = 'failed' AND updated_at >= datetime('now', '-1 day')`),
      pending: count(`SELECT COUNT(*) AS n FROM orders WHERE payment_status = 'pending' AND status != 'cancelled'`),
    },
    security: {
      loginFailures1h: count(`SELECT COUNT(*) AS n FROM audit_logs WHERE action = 'login_failed' AND created_at >= datetime('now', '-1 hour')`),
      adminLogins24h: count(`SELECT COUNT(*) AS n FROM audit_logs WHERE action = 'admin_login' AND created_at >= datetime('now', '-1 day')`),
    },
    alerts: db.prepare('SELECT * FROM alerts ORDER BY resolved, created_at DESC LIMIT 50').all(),
  });
}));

app.post('/api/admin/alerts/:id/resolve', requireManager, h((req, res) => {
  const info = db.prepare('UPDATE alerts SET resolved = 1 WHERE id = ?').run(Number(req.params.id));
  if (info.changes === 0) throw httpError(404, 'Alerte introuvable');
  audit('alert_resolved', { userId: req.user.id, details: { id: Number(req.params.id) }, ip: req.ip });
  res.json({ ok: true });
}));

app.get('/api/admin/audit', requireManager, h((req, res) => {
  const limit = Math.min(Number(req.query.limit) || 100, 500);
  res.json(
    db
      .prepare(
        `SELECT a.*, u.name AS user_name FROM audit_logs a LEFT JOIN users u ON u.id = a.user_id
         ORDER BY a.id DESC LIMIT ?`,
      )
      .all(limit),
  );
}));

// Zones de livraison (zones.js) et rapports par période (reports.js).
app.use(zones.createZonesRouter());
app.use(createReportsRouter());

// Livraison : espace livreur, « Reçu » du client, livreurs et attribution (admin).
app.use(delivery.createDeliveryRouter({ loadOrder, loadOrders, presentOrder }));

// Paiements mobile money : push USSD, file à vérifier, encaissements, reversements, remboursements.
app.use(payments.createApiRouter({ presentOrder, loadOrder }));

app.get('/', (_req, res) => res.json({ name: 'KALETA API', status: 'ok' }));

// Erreurs non gérées (JSON invalide, fichier trop gros...).
app.use((err, req, res, _next) => {
  const status = err.status || err.statusCode || (err.code === 'LIMIT_FILE_SIZE' ? 413 : 500);
  if (status >= 500) log.error('erreur non gérée', { path: req.path, error: err.message });
  res.status(status).json({ error: status === 413 ? 'Fichier trop volumineux' : status < 500 ? 'Requête invalide' : 'Erreur serveur' });
});

startMonitoring();
payments.startPaymentTasks();
delivery.startDeliveryTasks();

const PORT = Number(process.env.PORT) || 4000;
app.listen(PORT, '0.0.0.0', () => {
  log.info('démarrage', { port: PORT, payment: payments.paymentInfo(), fees: payments.feeInfo() });
  console.log(`🎭 API KALETA sur http://localhost:${PORT}`);
});
