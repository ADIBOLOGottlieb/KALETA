/**
 * Livraison : espace livreur, « Reçu » du client, gestion des livreurs et attribution (admin),
 * passage automatique à « livrée » sans « Reçu ».
 *
 * Circuit (commande en mode 'delivery') :
 *   ready (sans livreur) → take/assign → delivering (driver_id, picked_up_at)
 *   → « Livraison faite » (driver_delivered_at, reste delivering)
 *   → « Reçu » client ou délai delivery_auto_confirm_hours → delivered (received_at si client).
 * Toutes les actions sont auditées (agent, commande, livreur).
 */
const express = require('express');
const bcrypt = require('bcryptjs');
const { db, getSettings } = require('./db');
const authModule = require('./auth');
const { requireAuth, requireAdmin, requireManager, requireDriver } = authModule;
const { log } = require('./logger');
const { audit } = require('./monitor');
const notify = require('./notify');
const { roadKm } = require('./delivery-fee');

/** Téléphone normalisé (auth.js) ; repli : numéro tel quel. */
const normalizePhone = (p) => (typeof authModule.normalizePhone === 'function' ? authModule.normalizePhone(p) : p) || p;
/** Déconnecte les autres sessions d'un compte (auth.js) ; sans effet si la fonction n'existe pas. */
const bumpTokenVersion = (id) => (typeof authModule.bumpTokenVersion === 'function' ? authModule.bumpTokenVersion(id) : undefined);
const { h, httpError } = require('./payments/util');
const { isMobileMoney } = require('./payments/core');

const PHONE_RE = /^\+?[\d\s]{8,16}$/;
const SCOPES = ['available', 'mine', 'history'];

/** Une commande mobile money doit être payée avant de partir en livraison. */
function assertPaid(order) {
  if (isMobileMoney(order.payment_method) && order.payment_status !== 'paid') {
    throw httpError(400, 'Paiement pas encore reçu');
  }
}

function driverJson(id) {
  const u = db
    .prepare(
      `SELECT u.*,
         (SELECT COUNT(*) FROM orders o WHERE o.driver_id = u.id AND o.status = 'delivering') AS active_deliveries,
         (SELECT COUNT(*) FROM orders o WHERE o.driver_id = u.id AND o.status = 'delivered') AS delivered_count
       FROM users u WHERE u.id = ?`,
    )
    .get(id);
  if (!u) return null;
  return {
    id: u.id,
    name: u.name,
    phone: u.phone,
    active: Number(u.active ?? 1) === 1,
    active_deliveries: Number(u.active_deliveries),
    delivered_count: Number(u.delivered_count),
    created_at: u.created_at,
  };
}

// ---------- Suivi du livreur en direct ----------

// Position conservée seulement pendant une livraison ; au-delà de 10 min sans mise à jour, elle n'est plus montrée.
const LOCATION_MAX_AGE_MS = 10 * 60 * 1000;
// Envois trop rapprochés ignorés (l'app envoie toutes les ~5 s ou tous les ~25 m).
const LOCATION_MIN_INTERVAL_MS = 3000;
// Estimation d'arrivée : distance par la route (vol d'oiseau × 1,3) à 20 km/h, + 1 min de marge.
const ETA_SPEED_KMH = 20;

/** Date SQLite « YYYY-MM-DD HH:MM:SS » (UTC) → millisecondes. */
const sqlMs = (v) => (v ? Date.parse(`${String(v).replace(' ', 'T')}Z`) : NaN);

/** Livraisons en cours d'un livreur (prises et pas encore indiquées « Livraison faite »). */
const activeDeliveries = (driverId) => db
  .prepare(`SELECT COUNT(*) AS n FROM orders WHERE driver_id = ? AND status = 'delivering' AND driver_delivered_at IS NULL`)
  .get(Number(driverId)).n;

/** Oublie la dernière position d'un livreur (fin des livraisons, compte supprimé ou désactivé). */
function forgetDriverLocation(driverId) {
  db.prepare('DELETE FROM driver_locations WHERE driver_id = ?').run(Number(driverId));
}

/**
 * Suivi d'une commande pour presentOrder : position du livreur (livraison en cours, position de moins
 * de 10 min) et minutes estimées jusqu'au client.
 * @returns {{ driver_location: object|null, eta_minutes: number|null }}
 */
function trackingInfo(order, viewer) {
  const live = customerLiveInfo(order, viewer);
  const none = { driver_location: null, eta_minutes: null, ...live };
  if (!order || order.status !== 'delivering' || order.driver_delivered_at || !order.driver_id) return none;
  const loc = db.prepare('SELECT * FROM driver_locations WHERE driver_id = ?').get(order.driver_id);
  if (!loc || !(Date.now() - sqlMs(loc.updated_at) < LOCATION_MAX_AGE_MS)) return none;
  // Le client partage sa position en direct : l'arrivée est estimée jusqu'à lui.
  const target = live.customer_location ?? { lat: order.delivery_lat, lng: order.delivery_lng };
  const km = roadKm({ lat: loc.lat, lng: loc.lng }, target);
  return {
    ...live,
    driver_location: { lat: loc.lat, lng: loc.lng, accuracy: loc.accuracy, heading: loc.heading, updated_at: loc.updated_at },
    eta_minutes: km === null ? null : Math.max(1, Math.ceil((km / ETA_SPEED_KMH) * 60) + 1),
  };
}

// ---------- Position en direct du client (comme « Position en direct » de WhatsApp) ----------

/** Durées de partage proposées au client, en minutes (15 min, 1 h, 8 h). */
const LIVE_SHARE_MINUTES = [15, 60, 480];

/** Livraison encore en cours côté client : le partage a un sens. */
const liveShareable = (order) =>
  !!order && order.mode === 'delivery' && order.source !== 'counter' && !['delivered', 'cancelled'].includes(order.status);

/** Partage actif : durée non écoulée et livraison en cours. */
const liveShareActive = (order) =>
  liveShareable(order) && !!order.live_share_until && sqlMs(order.live_share_until) > Date.now();

/** Qui voit la position en direct du client : lui-même, le livreur attribué et le personnel. */
const canSeeCustomerLive = (order, viewer) =>
  !!viewer && (viewer.id === order.user_id || viewer.role === 'admin' || (viewer.role === 'driver' && viewer.id === order.driver_id));

/**
 * Position en direct du client pour presentOrder (seulement pour les personnes autorisées).
 * @returns {{ customer_location: object|null, live_share_until: string|null }}
 */
function customerLiveInfo(order, viewer) {
  const none = { customer_location: null, live_share_until: null };
  if (!order || !canSeeCustomerLive(order, viewer) || !liveShareActive(order)) return none;
  const loc = db.prepare('SELECT * FROM customer_live_locations WHERE order_id = ?').get(order.id);
  const fresh = loc && Date.now() - sqlMs(loc.updated_at) < LOCATION_MAX_AGE_MS;
  return {
    live_share_until: order.live_share_until,
    customer_location: fresh
      ? { lat: loc.lat, lng: loc.lng, accuracy: loc.accuracy, heading: loc.heading, updated_at: loc.updated_at }
      : null,
  };
}

/** Arrête le partage en direct d'une commande et oublie la position. */
function stopLiveShare(orderId) {
  db.prepare('UPDATE orders SET live_share_until = NULL WHERE id = ?').run(Number(orderId));
  db.prepare('DELETE FROM customer_live_locations WHERE order_id = ?').run(Number(orderId));
}

/** Positions des partages terminés (durée écoulée, commande livrée ou annulée) : effacées. */
function pruneCustomerLiveLocations() {
  return Number(db.prepare(
    `DELETE FROM customer_live_locations WHERE order_id NOT IN (
       SELECT id FROM orders WHERE live_share_until > datetime('now') AND status NOT IN ('delivered', 'cancelled'))`,
  ).run().changes);
}

/** Position envoyée par l'app : lat/lng obligatoires, précision et cap facultatifs. */
function parsePosition(body) {
  const b = body && typeof body === 'object' ? body : {};
  const lat = optNumber(b.lat);
  const lng = optNumber(b.lng);
  const accuracy = optNumber(b.accuracy);
  const heading = optNumber(b.heading);
  if (lat === null || lng === null || Number.isNaN(lat) || Number.isNaN(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    throw httpError(400, 'Position invalide');
  }
  if (Number.isNaN(accuracy) || (accuracy !== null && accuracy < 0)) throw httpError(400, 'Précision invalide');
  if (Number.isNaN(heading) || (heading !== null && (heading < 0 || heading > 360))) throw httpError(400, 'Direction invalide');
  return { lat, lng, accuracy, heading };
}

function saveCustomerLocation(order, pos) {
  db.prepare(
    `INSERT INTO customer_live_locations (order_id, user_id, lat, lng, accuracy, heading, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
     ON CONFLICT(order_id) DO UPDATE SET lat = excluded.lat, lng = excluded.lng, accuracy = excluded.accuracy,
       heading = excluded.heading, updated_at = excluded.updated_at`,
  ).run(order.id, order.user_id, pos.lat, pos.lng, pos.accuracy, pos.heading);
}

/** Nombre facultatif : null si absent, NaN si invalide. */
function optNumber(v) {
  if (v === undefined || v === null) return null;
  return typeof v === 'number' && Number.isFinite(v) ? v : NaN;
}

function getDriverRow(id) {
  const u = db.prepare('SELECT * FROM users WHERE id = ?').get(Number(id));
  if (!u || u.deleted_at || u.role !== 'driver') return null;
  return u;
}

/**
 * Passe à « livrée » les livraisons indiquées faites par le livreur depuis plus de
 * delivery_auto_confirm_hours sans « Reçu » du client. @returns le nombre de commandes passées.
 */
function autoConfirmDeliveries() {
  const hours = getSettings().delivery_auto_confirm_hours;
  const rows = db
    .prepare(
      `SELECT id, user_id, driver_id, driver_delivered_at FROM orders
       WHERE status = 'delivering' AND driver_delivered_at IS NOT NULL AND driver_delivered_at <= datetime('now', ?)`,
    )
    .all(`-${hours} hours`);
  let done = 0;
  for (const o of rows) {
    const info = db
      .prepare(`UPDATE orders SET status = 'delivered', updated_at = datetime('now')
                WHERE id = ? AND status = 'delivering' AND driver_delivered_at IS NOT NULL`)
      .run(o.id);
    if (!info.changes) continue;
    done++;
    audit('delivery_auto_confirmed', {
      details: { orderId: o.id, userId: o.user_id, driverId: o.driver_id, driver_delivered_at: o.driver_delivered_at, after_hours: hours },
    });
    log.info('livraison confirmée automatiquement', { orderId: o.id, hours });
  }
  return done;
}

/**
 * Remet dans « À livrer » (ready, sans livreur) les livraisons en cours d'un livreur
 * (désactivé, compte supprimé...). Celles déjà indiquées « Livraison faite » restent (attente du « Reçu »).
 * @returns les identifiants des commandes libérées
 */
function releaseDriverOrders(driverId, reason, agentId = null) {
  const rows = db
    .prepare(`SELECT * FROM orders WHERE driver_id = ? AND status = 'delivering' AND driver_delivered_at IS NULL`)
    .all(Number(driverId));
  const released = [];
  for (const o of rows) {
    const info = db
      .prepare(`UPDATE orders SET driver_id = NULL, picked_up_at = NULL, status = 'ready', updated_at = datetime('now')
                WHERE id = ? AND driver_id = ? AND status = 'delivering' AND driver_delivered_at IS NULL`)
      .run(o.id, Number(driverId));
    if (!info.changes) continue;
    released.push(o.id);
    audit('delivery_released', { userId: agentId, details: { orderId: o.id, driverId: Number(driverId), reason } });
    notify.readyForDrivers(o);
  }
  if (released.length) log.info('livraisons libérées', { driverId: Number(driverId), reason, orders: released });
  return released;
}

/** Filet de sécurité : livraisons d'un livreur désactivé, supprimé ou qui n'est plus livreur. */
function releaseOrphanDeliveries() {
  const drivers = db
    .prepare(
      `SELECT DISTINCT o.driver_id AS id, u.role, u.active, u.deleted_at FROM orders o LEFT JOIN users u ON u.id = o.driver_id
       WHERE o.status = 'delivering' AND o.driver_id IS NOT NULL AND o.driver_delivered_at IS NULL`,
    )
    .all();
  let n = 0;
  for (const d of drivers) {
    const gone = !d.role || d.deleted_at || (d.role !== 'driver' && d.role !== 'admin') || Number(d.active ?? 1) === 0;
    if (gone) n += releaseDriverOrders(d.id, !d.role || d.deleted_at ? 'driver_account_deleted' : 'driver_inactive').length;
  }
  return n;
}

/** Positions des livreurs sans livraison en cours (statut changé par l'admin, app fermée...) : effacées. */
function pruneDriverLocations() {
  return Number(db.prepare(
    `DELETE FROM driver_locations WHERE driver_id NOT IN (
       SELECT driver_id FROM orders WHERE status = 'delivering' AND driver_delivered_at IS NULL AND driver_id IS NOT NULL)`,
  ).run().changes);
}

function startDeliveryTasks() {
  const every = Number(process.env.DELIVERY_TASK_INTERVAL_MS) || 5 * 60 * 1000;
  const run = () => {
    try {
      releaseOrphanDeliveries();
      autoConfirmDeliveries();
      pruneDriverLocations();
      pruneCustomerLiveLocations();
    } catch (err) {
      log.error('tâche livraisons', { error: err.message });
    }
  };
  setTimeout(run, Math.min(every, 5000)).unref();
  setInterval(run, every).unref();
}

/**
 * @param {{ loadOrder: Function, loadOrders: Function, presentOrder: Function }} deps fonctions de server.js
 */
function createDeliveryRouter({ loadOrder, loadOrders, presentOrder }) {
  const router = express.Router();
  const orderJson = (id, viewer) => presentOrder(loadOrder(Number(id)), viewer);
  const findOrder = (id) => {
    const order = loadOrder(Number(id));
    if (!order) throw httpError(404, 'Commande introuvable');
    return order;
  };

  // ---------- Livreur ----------

  router.get('/api/driver/orders', requireDriver, h((req, res) => {
    const scope = req.query.scope || 'available';
    if (!SCOPES.includes(scope)) throw httpError(400, 'Liste invalide (available, mine ou history)');
    let rows;
    if (scope === 'available') {
      rows = loadOrders(`WHERE o.status = 'ready' AND o.mode = 'delivery' AND o.driver_id IS NULL`, [],
        { orderBy: 'o.updated_at ASC, o.id ASC' });
    } else if (scope === 'mine') {
      rows = loadOrders(`WHERE o.status = 'delivering' AND o.driver_id = ?`, [req.user.id],
        { orderBy: 'o.driver_delivered_at IS NOT NULL, o.picked_up_at ASC, o.id ASC' });
    } else {
      rows = loadOrders(`WHERE o.status = 'delivered' AND o.driver_id = ?`, [req.user.id],
        { orderBy: 'COALESCE(o.received_at, o.driver_delivered_at, o.updated_at) DESC, o.id DESC', limit: 50 });
    }
    res.json(rows.map((o) => presentOrder(o, req.user)));
  }));

  router.post('/api/driver/orders/:id/take', requireDriver, h((req, res) => {
    const order = findOrder(req.params.id);
    if (order.driver_id) {
      if (order.driver_id === req.user.id && order.status === 'delivering') return res.json(orderJson(order.id, req.user));
      throw httpError(409, 'Cette livraison a déjà été prise par un autre livreur');
    }
    if (order.mode !== 'delivery') throw httpError(400, 'Commande à emporter : pas de livraison');
    if (order.status !== 'ready') throw httpError(400, 'Cette commande n\'est pas prête à être livrée');
    assertPaid(order);
    const info = db
      .prepare(`UPDATE orders SET driver_id = ?, picked_up_at = datetime('now'), driver_delivered_at = NULL,
                  status = 'delivering', updated_at = datetime('now')
                WHERE id = ? AND driver_id IS NULL AND status = 'ready' AND mode = 'delivery'`)
      .run(req.user.id, order.id);
    if (!info.changes) throw httpError(409, 'Cette livraison a déjà été prise par un autre livreur');
    audit('driver_take', { userId: req.user.id, details: { orderId: order.id, driverId: req.user.id }, ip: req.ip });
    notify.statusChanged(order, 'delivering', { driverName: req.user.name });
    notify.driverTook(order, req.user.name);
    res.json(orderJson(order.id, req.user));
  }));

  // Position du livreur (suivi en direct) : enregistrée seulement pendant une livraison en cours.
  // tracking:false → l'app arrête d'envoyer.
  router.post('/api/driver/location', requireDriver, h((req, res) => {
    const body = req.body && typeof req.body === 'object' ? req.body : {};
    const lat = optNumber(body.lat);
    const lng = optNumber(body.lng);
    const accuracy = optNumber(body.accuracy);
    const heading = optNumber(body.heading);
    const speed = optNumber(body.speed);
    if (lat === null || lng === null || Number.isNaN(lat) || Number.isNaN(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      throw httpError(400, 'Position invalide');
    }
    if (Number.isNaN(accuracy) || (accuracy !== null && accuracy < 0)) throw httpError(400, 'Précision invalide');
    if (Number.isNaN(heading) || (heading !== null && (heading < 0 || heading > 360))) throw httpError(400, 'Direction invalide');
    if (Number.isNaN(speed) || (speed !== null && speed < 0)) throw httpError(400, 'Vitesse invalide');

    const active = activeDeliveries(req.user.id);
    if (active === 0) {
      forgetDriverLocation(req.user.id);
      return res.json({ tracking: false, active_orders: 0 });
    }
    const last = db.prepare('SELECT updated_at FROM driver_locations WHERE driver_id = ?').get(req.user.id);
    if (last && Date.now() - sqlMs(last.updated_at) < LOCATION_MIN_INTERVAL_MS) {
      return res.json({ tracking: true, active_orders: active });
    }
    db.prepare(
      `INSERT INTO driver_locations (driver_id, lat, lng, accuracy, heading, speed, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
       ON CONFLICT(driver_id) DO UPDATE SET lat = excluded.lat, lng = excluded.lng, accuracy = excluded.accuracy,
         heading = excluded.heading, speed = excluded.speed, updated_at = excluded.updated_at`,
    ).run(req.user.id, lat, lng, accuracy, heading, speed);
    res.json({ tracking: true, active_orders: active });
  }));

  router.post('/api/driver/orders/:id/delivered', requireDriver, h((req, res) => {
    const order = findOrder(req.params.id);
    if (order.driver_id !== req.user.id) throw httpError(403, 'Cette livraison n\'est pas attribuée à votre compte');
    if (order.status !== 'delivering') throw httpError(400, 'Cette livraison n\'est pas en cours');
    if (!order.driver_delivered_at) {
      db.prepare(`UPDATE orders SET driver_delivered_at = datetime('now'), updated_at = datetime('now')
                  WHERE id = ? AND status = 'delivering' AND driver_id = ? AND driver_delivered_at IS NULL`)
        .run(order.id, req.user.id);
      audit('driver_delivered', {
        userId: req.user.id,
        details: { orderId: order.id, driverId: req.user.id, payment_method: order.payment_method, total: order.total },
        ip: req.ip,
      });
      notify.driverDelivered(order, order.driver_name || req.user.name);
      // Plus aucune livraison en cours : la position n'est plus conservée.
      if (activeDeliveries(req.user.id) === 0) forgetDriverLocation(req.user.id);
    }
    res.json(orderJson(order.id, req.user));
  }));

  router.post('/api/driver/orders/:id/release', requireDriver, h((req, res) => {
    const order = findOrder(req.params.id);
    if (order.driver_id !== req.user.id) throw httpError(403, 'Cette livraison n\'est pas attribuée à votre compte');
    if (order.status !== 'delivering') throw httpError(400, 'Cette livraison n\'est pas en cours');
    if (order.driver_delivered_at) throw httpError(400, 'Livraison déjà indiquée faite : elle ne peut plus être rendue');
    db.prepare(`UPDATE orders SET driver_id = NULL, picked_up_at = NULL, status = 'ready', updated_at = datetime('now')
                WHERE id = ? AND driver_id = ? AND status = 'delivering'`)
      .run(order.id, req.user.id);
    audit('driver_release', { userId: req.user.id, details: { orderId: order.id, driverId: req.user.id }, ip: req.ip });
    if (activeDeliveries(req.user.id) === 0) forgetDriverLocation(req.user.id);
    notify.readyForDrivers(order);
    res.json(orderJson(order.id, req.user));
  }));

  router.get('/api/driver/stats', requireDriver, h((req, res) => {
    const row = db
      .prepare(
        `SELECT
           COUNT(CASE WHEN driver_delivered_at IS NOT NULL AND date(driver_delivered_at) = date('now')
                       AND status IN ('delivering', 'delivered') THEN 1 END) AS today_count,
           COALESCE(SUM(CASE WHEN driver_delivered_at IS NOT NULL AND date(driver_delivered_at) = date('now')
                       AND status IN ('delivering', 'delivered') AND payment_method = 'cash' THEN total END), 0) AS today_cash,
           COUNT(CASE WHEN status = 'delivering' THEN 1 END) AS active_count
         FROM orders WHERE driver_id = ?`,
      )
      .get(req.user.id);
    res.json({ today_count: Number(row.today_count), today_cash: Number(row.today_cash), active_count: Number(row.active_count) });
  }));

  // ---------- Client ----------

  // Position en direct : { minutes: 15 | 60 | 480, lat?, lng?, accuracy?, heading? } démarre (ou prolonge)
  // le partage ; { minutes: 0 } l'arrête et efface la position.
  router.post('/api/orders/:id/live-share', requireAuth, h((req, res) => {
    const order = loadOrder(Number(req.params.id));
    if (!order || order.user_id !== req.user.id) throw httpError(404, 'Commande introuvable');
    const minutes = Number(req.body?.minutes);
    if (minutes === 0) {
      stopLiveShare(order.id);
      return res.json(orderJson(order.id, req.user));
    }
    if (!LIVE_SHARE_MINUTES.includes(minutes)) throw httpError(400, 'Durée de partage invalide (15 min, 1 h ou 8 h)');
    if (!liveShareable(order)) throw httpError(400, 'Le partage de position est possible seulement pendant une livraison');
    const hasPosition = req.body?.lat !== undefined || req.body?.lng !== undefined;
    const pos = hasPosition ? parsePosition(req.body) : null;
    db.prepare(`UPDATE orders SET live_share_until = datetime('now', ?) WHERE id = ?`).run(`+${minutes} minutes`, order.id);
    if (pos) saveCustomerLocation(order, pos);
    audit('customer_live_share', { userId: req.user.id, details: { orderId: order.id, minutes }, ip: req.ip });
    res.json(orderJson(order.id, req.user));
  }));

  // Position du client pendant le partage. sharing:false → l'app arrête d'envoyer (durée écoulée, livrée...).
  router.post('/api/orders/:id/live-location', requireAuth, h((req, res) => {
    const order = loadOrder(Number(req.params.id));
    if (!order || order.user_id !== req.user.id) throw httpError(404, 'Commande introuvable');
    const pos = parsePosition(req.body);
    if (!liveShareActive(order)) {
      stopLiveShare(order.id);
      return res.json({ sharing: false, live_share_until: null });
    }
    const last = db.prepare('SELECT updated_at FROM customer_live_locations WHERE order_id = ?').get(order.id);
    if (!last || Date.now() - sqlMs(last.updated_at) >= LOCATION_MIN_INTERVAL_MS) saveCustomerLocation(order, pos);
    res.json({ sharing: true, live_share_until: order.live_share_until });
  }));

  router.post('/api/orders/:id/received', requireAuth, h((req, res) => {
    const order = loadOrder(Number(req.params.id));
    if (!order || order.user_id !== req.user.id) throw httpError(404, 'Commande introuvable');
    if (order.status === 'delivered') return res.json(orderJson(order.id, req.user));
    if (order.status !== 'delivering' || !order.driver_delivered_at) {
      throw httpError(400, 'Le livreur n\'a pas encore indiqué « Livraison faite »');
    }
    const info = db
      .prepare(`UPDATE orders SET status = 'delivered', received_at = datetime('now'), updated_at = datetime('now')
                WHERE id = ? AND status = 'delivering' AND driver_delivered_at IS NOT NULL`)
      .run(order.id);
    if (info.changes) {
      audit('delivery_received', { userId: req.user.id, details: { orderId: order.id, driverId: order.driver_id }, ip: req.ip });
      notify.deliveryReceived(order);
    }
    res.json(orderJson(order.id, req.user));
  }));

  // ---------- Admin : livreurs ----------

  router.get('/api/admin/drivers', requireAdmin, h((_req, res) => {
    const ids = db
      .prepare(`SELECT * FROM users WHERE role = 'driver' ORDER BY name COLLATE NOCASE, id`)
      .all()
      .filter((u) => !u.deleted_at)
      .map((u) => u.id);
    const list = ids.map(driverJson);
    list.sort((a, b) => Number(b.active) - Number(a.active));
    res.json(list);
  }));

  // Création / modification des livreurs : propriétaire et gérants.
  router.post('/api/admin/drivers', requireManager, h((req, res) => {
    const body = req.body || {};
    // Variante : un client existant devient livreur.
    if (body.user_id !== undefined && body.user_id !== null) {
      const user = db.prepare('SELECT * FROM users WHERE id = ?').get(Number(body.user_id));
      if (!user || user.deleted_at) throw httpError(404, 'Compte introuvable');
      if (user.role === 'driver') throw httpError(409, 'Ce compte est déjà livreur');
      if (user.role !== 'customer') throw httpError(400, 'Un administrateur ne peut pas devenir livreur');
      db.prepare(`UPDATE users SET role = 'driver', active = 1 WHERE id = ?`).run(user.id);
      audit('driver_created', { userId: req.user.id, details: { driverId: user.id, from: 'customer' }, ip: req.ip });
      return res.status(201).json(driverJson(user.id));
    }
    const name = typeof body.name === 'string' ? body.name.trim() : '';
    const phone = typeof body.phone === 'string' && body.phone.trim() ? String(normalizePhone(body.phone.trim())).trim() : '';
    const password = typeof body.password === 'string' ? body.password : '';
    if (!name || !phone || !password) throw httpError(400, 'Nom, téléphone et mot de passe requis');
    if (password.length < 6) throw httpError(400, 'Le mot de passe doit contenir au moins 6 caractères');
    if (!PHONE_RE.test(phone)) throw httpError(400, 'Numéro de téléphone invalide');
    if (db.prepare('SELECT id FROM users WHERE phone = ?').get(phone)) throw httpError(409, 'Ce numéro est déjà utilisé');
    const info = db
      .prepare(`INSERT INTO users (name, phone, password_hash, role, active) VALUES (?, ?, ?, 'driver', 1)`)
      .run(name.slice(0, 80), phone, bcrypt.hashSync(password, 10));
    const id = Number(info.lastInsertRowid);
    audit('driver_created', { userId: req.user.id, details: { driverId: id, name: name.slice(0, 80) }, ip: req.ip });
    res.status(201).json(driverJson(id));
  }));

  router.patch('/api/admin/drivers/:id', requireManager, h((req, res) => {
    const driver = getDriverRow(req.params.id);
    if (!driver) throw httpError(404, 'Livreur introuvable');
    const { active, name, password } = req.body || {};
    const sets = [];
    const params = [];
    const changed = {};
    if (active !== undefined) {
      if (![true, false, 0, 1].includes(active)) throw httpError(400, 'Valeur invalide pour active');
      sets.push('active = ?');
      params.push(active ? 1 : 0);
      changed.active = !!active;
    }
    if (name !== undefined) {
      const n = typeof name === 'string' ? name.trim() : '';
      if (!n) throw httpError(400, 'Nom requis');
      sets.push('name = ?');
      params.push(n.slice(0, 80));
      changed.name = n.slice(0, 80);
    }
    if (password !== undefined) {
      if (typeof password !== 'string' || password.length < 6) {
        throw httpError(400, 'Le mot de passe doit contenir au moins 6 caractères');
      }
      sets.push('password_hash = ?');
      params.push(bcrypt.hashSync(password, 10));
      changed.password = true;
    }
    if (sets.length) {
      db.prepare(`UPDATE users SET ${sets.join(', ')} WHERE id = ?`).run(...params, driver.id);
      audit('driver_updated', { userId: req.user.id, details: { driverId: driver.id, ...changed }, ip: req.ip });
      // Nouveau mot de passe : les sessions ouvertes du livreur sont fermées.
      if (changed.password) bumpTokenVersion(driver.id);
      // Livreur désactivé : ses livraisons en cours repartent dans « À livrer ».
      if (changed.active === false) {
        releaseDriverOrders(driver.id, 'driver_inactive', req.user.id);
        forgetDriverLocation(driver.id);
      }
    }
    res.json(driverJson(driver.id));
  }));

  // Attribuer (driver_id) ou retirer (null) le livreur d'une commande en livraison.
  router.patch('/api/admin/orders/:id/assign', requireAdmin, h((req, res) => {
    const order = findOrder(req.params.id);
    const body = req.body || {};
    if (!('driver_id' in body)) throw httpError(400, 'driver_id requis (ou null pour retirer le livreur)');
    if (order.mode !== 'delivery') throw httpError(400, 'Commande à emporter : pas de livreur');
    if (['delivered', 'cancelled'].includes(order.status)) throw httpError(400, 'Cette commande est terminée');
    if (order.driver_delivered_at) throw httpError(400, 'Livraison déjà indiquée faite par le livreur');

    if (body.driver_id === null) {
      if (order.driver_id) {
        db.prepare(`UPDATE orders SET driver_id = NULL, picked_up_at = NULL,
                      status = CASE WHEN status = 'delivering' THEN 'ready' ELSE status END, updated_at = datetime('now')
                    WHERE id = ?`).run(order.id);
        audit('order_unassigned', { userId: req.user.id, details: { orderId: order.id, driverId: order.driver_id }, ip: req.ip });
        if (order.status === 'delivering') notify.readyForDrivers(order);
      }
      return res.json(orderJson(order.id, req.user));
    }

    const driver = getDriverRow(body.driver_id);
    if (!driver) throw httpError(404, 'Livreur introuvable');
    if (Number(driver.active ?? 1) !== 1) throw httpError(400, 'Ce livreur est désactivé');
    if (!['ready', 'delivering'].includes(order.status)) throw httpError(400, 'La commande doit être prête avant d\'attribuer un livreur');
    assertPaid(order);
    if (order.driver_id !== driver.id) {
      db.prepare(`UPDATE orders SET driver_id = ?, picked_up_at = datetime('now'), status = 'delivering',
                    updated_at = datetime('now') WHERE id = ?`).run(driver.id, order.id);
      audit('order_assigned', {
        userId: req.user.id,
        details: { orderId: order.id, driverId: driver.id, previousDriverId: order.driver_id ?? null, from: order.status },
        ip: req.ip,
      });
      notify.deliveryAssigned(order, driver.id);
      if (order.status !== 'delivering') notify.statusChanged(order, 'delivering', { driverName: driver.name });
    }
    res.json(orderJson(order.id, req.user));
  }));

  return router;
}

module.exports = {
  createDeliveryRouter, startDeliveryTasks, autoConfirmDeliveries, releaseDriverOrders, releaseOrphanDeliveries,
  trackingInfo, forgetDriverLocation, pruneDriverLocations, pruneCustomerLiveLocations, stopLiveShare, LIVE_SHARE_MINUTES,
};
