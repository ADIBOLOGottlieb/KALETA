// Commandes & argent (node --test) : machine d'états, validation, pagination, paiements tardifs,
// simulation en production, livreurs désactivés. Serveur de test sur le port 4420 (base temporaire).
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const bcrypt = require('bcryptjs');
const { adminTransitionError, ADMIN_TRANSITIONS } = require('../src/order-status');

const BACKEND = path.join(__dirname, '..');
const PORT = 4420;
const BASE = `http://localhost:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- Machine d'états (module pur) ----------

test('machine d\'états : statuts définitifs', () => {
  for (const from of ['delivered', 'cancelled']) {
    for (const to of ['pending', 'confirmed', 'preparing', 'ready', 'delivering', 'delivered', 'cancelled'].filter((s) => s !== from)) {
      assert.ok(adminTransitionError({ status: from, mode: 'delivery' }, to), `${from} → ${to} doit être refusé`);
      assert.ok(adminTransitionError({ status: from, mode: 'pickup' }, to), `${from} → ${to} (retrait) doit être refusé`);
    }
  }
  assert.deepEqual(ADMIN_TRANSITIONS.delivered, []);
  assert.deepEqual(ADMIN_TRANSITIONS.cancelled, []);
});

test('machine d\'états : livraison et retrait', () => {
  // Jamais « delivering » par un simple changement de statut (livreur obligatoire).
  assert.match(adminTransitionError({ status: 'ready', mode: 'delivery' }, 'delivering'), /livreur/);
  assert.match(adminTransitionError({ status: 'ready', mode: 'pickup' }, 'delivering'), /emporter/);
  // Retrait : ready → delivered ; livraison : delivered seulement depuis delivering.
  assert.equal(adminTransitionError({ status: 'ready', mode: 'pickup' }, 'delivered'), null);
  assert.ok(adminTransitionError({ status: 'preparing', mode: 'pickup' }, 'delivered'));
  assert.ok(adminTransitionError({ status: 'ready', mode: 'delivery' }, 'delivered'));
  assert.equal(adminTransitionError({ status: 'delivering', mode: 'delivery', driver_id: 3 }, 'delivered'), null);
  // Retour en cuisine refusé après « Livraison faite ».
  assert.equal(adminTransitionError({ status: 'delivering', mode: 'delivery', driver_id: 3 }, 'ready'), null);
  assert.ok(adminTransitionError({ status: 'delivering', mode: 'delivery', driver_id: 3, driver_delivered_at: '2026-10-03 10:00:00' }, 'ready'));
  // Avancer / annuler en cuisine.
  for (const from of ['pending', 'confirmed', 'preparing', 'ready']) {
    assert.equal(adminTransitionError({ status: from, mode: 'delivery' }, 'cancelled'), null);
  }
  assert.equal(adminTransitionError({ status: 'pending', mode: 'delivery' }, 'confirmed'), null);
  assert.equal(adminTransitionError({ status: 'pending', mode: 'delivery' }, 'pending'), null); // sans effet
  assert.equal(adminTransitionError({ status: 'pending', mode: 'delivery' }, 'nimporte'), 'Statut invalide');
});

// ---------- Serveur de test ----------

function startServer(dir, extraEnv = {}) {
  const env = {
    ...process.env, PORT: String(PORT), DB_PATH: path.join(dir, 'orders.db'), LOG_DIR: path.join(dir, 'logs'), LOG_CONSOLE: '0',
    JWT_SECRET: 'test-secret-orders', ADMIN_PHONE: '0700000000', ADMIN_PASSWORD: 'admin123', NODE_ENV: 'test',
    PAYMENT_PROVIDER: '', PAYGATE_AUTH_TOKEN: '', KADEV_PUBLIC_KEY: '', KADEV_SECRET_KEY: '', ALLOW_SIMULATION: '',
    PROVIDER_FEE_PERCENT: '', PROVIDER_FEE_PERCENT_FLOOZ: '', PROVIDER_FEE_PERCENT_MIXX: '', SMS_PROVIDER: '',
    FIREBASE_SERVICE_ACCOUNT: '', BACKUP_GITHUB_REPO: '', BACKUP_GITHUB_TOKEN: '',
    PAYMENT_TASK_INTERVAL_MS: '400', RECONCILE_DELAY_MS: '3600000', DELIVERY_TASK_INTERVAL_MS: '600000',
    ...extraEnv,
  };
  const child = spawn(process.execPath, ['src/server.js'], { cwd: BACKEND, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  child.stdout.on('data', (d) => (out += d));
  child.stderr.on('data', (d) => (out += d));
  return { child, out: () => out };
}
const stop = (srv) => new Promise((r) => {
  if (srv.child.exitCode !== null) return r();
  srv.child.once('exit', r);
  srv.child.kill();
});
async function waitHealth(srv) {
  for (let i = 0; i < 80; i++) {
    try {
      if ((await fetch(`${BASE}/api/health`)).ok) {
        // Port déjà pris par un autre serveur : le nôtre s'arrête (EADDRINUSE) → échec clair.
        await sleep(300);
        if (srv.child.exitCode !== null) throw new Error(`port ${PORT} occupé\n${srv.out()}`);
        return;
      }
    } catch (err) {
      if (/occupé/.test(err.message)) throw err;
    }
    if (srv.child.exitCode !== null) break;
    await sleep(150);
  }
  throw new Error(`serveur injoignable\n${srv.out()}`);
}

function client(token = null) {
  const call = async (method, p, body) => {
    const res = await fetch(BASE + p, {
      method,
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let data = text;
    try { data = JSON.parse(text); } catch {}
    return { status: res.status, data, headers: res.headers };
  };
  return { call, setToken: (t) => (token = t) };
}
async function login(phone, password) {
  const c = client();
  const r = await c.call('POST', '/api/auth/login', { phone, password });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  c.setToken(r.data.token);
  return c;
}
async function register(name, phone) {
  const c = client();
  const r = await c.call('POST', '/api/auth/register', { name, phone, password: 'secret123', accept_terms: true });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  c.setToken(r.data.token);
  return c;
}
/** Attend qu'une condition SQL devienne vraie (tâches planifiées). */
async function until(fn, ms = 6000) {
  const end = Date.now() + ms;
  for (;;) {
    const v = fn();
    if (v || Date.now() > end) return v;
    await sleep(150);
  }
}

test('serveur : commandes, argent, livreurs', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ezazozo-orders-'));
  let srv = startServer(dir);
  t.after(() => stop(srv));
  await waitHealth(srv);
  const sql = new DatabaseSync(path.join(dir, 'orders.db'));
  sql.exec('PRAGMA busy_timeout = 5000');
  t.after(() => sql.close());

  const admin = await login('0700000000', 'admin123');
  // Inscription par l'API pour le client principal ; les suivants sont créés en base (limites de débit :
  // 5 inscriptions / h / IP, 10 commandes / 10 min / client).
  let cust = await register('Client Test', '90111111');
  let seq = 0;
  const hash = bcrypt.hashSync('secret123', 4);
  async function freshCustomer() {
    const local = String(92000000 + ++seq);
    sql.prepare(`INSERT INTO users (name, phone, password_hash) VALUES (?, ?, ?)`).run(`Client ${seq}`, `+228${local}`, hash);
    cust = await login(local, 'secret123');
    return cust;
  }
  const products = (await cust.call('GET', '/api/products')).data;
  const big = products.find((p) => p.price >= 3000);
  const base = { items: [{ product_id: big.id, quantity: 1 }], phone: '90 11 11 11' };
  const delivery = (method = 'cash') => cust.call('POST', '/api/orders', {
    ...base, mode: 'delivery', address: 'Tokoin, Lomé', payment_method: method, location: { lat: 6.13, lng: 1.22 },
  });
  const pickup = (method = 'cash') => cust.call('POST', '/api/orders', { ...base, mode: 'pickup', payment_method: method });
  const status = (id, s) => admin.call('PATCH', `/api/admin/orders/${id}/status`, { status: s });

  await t.test('GET /api/settings expose les réglages de compte', async () => {
    const s = (await cust.call('GET', '/api/settings')).data;
    assert.equal(typeof s.otp_required, 'boolean');
    assert.equal(s.terms_version, '2026-10');
    assert.match(s.terms_url, /\/legal\/cgu$/);
    assert.match(s.privacy_url, /\/legal\/confidentialite$/);
  });

  await t.test('validation des types : 400, jamais 500', async () => {
    for (const bad of [
      { ...base, mode: 'pickup', payment_method: 'cash', phone: 90111111 },
      { ...base, mode: 'pickup', payment_method: 'cash', note: 12 },
      { ...base, mode: 'delivery', payment_method: 'cash', address: 42 },
      { ...base, mode: 'delivery', payment_method: 'cash', address: 'Bè', location: 'ici' },
      { ...base, mode: 'pickup', payment_method: 'cash', phone: 'pas un numéro' },
      { ...base, mode: 'pickup', payment_method: ['cash'] },
      { items: [null, 'x'], mode: 'pickup', payment_method: 'cash', phone: '90111111' },
    ]) {
      const r = await cust.call('POST', '/api/orders', bad);
      assert.equal(r.status, 400, JSON.stringify({ bad, r: r.data }));
    }
    const ok = await pickup();
    assert.equal(ok.status, 201);
    assert.equal(ok.data.phone, '+22890111111', 'téléphone normalisé');
    const cat = await admin.call('POST', '/api/admin/categories', { name: 5 });
    assert.equal(cat.status, 400);
  });

  await t.test('commande espèces annulée par le client : plus jamais « delivered »', async () => {
    const o = (await delivery()).data;
    const c = await cust.call('POST', `/api/orders/${o.id}/cancel`);
    assert.equal(c.data.status, 'cancelled');
    for (const s of ['delivered', 'ready', 'pending', 'delivering']) {
      const r = await status(o.id, s);
      assert.equal(r.status, 400, `${s} : ${JSON.stringify(r.data)}`);
    }
    assert.equal(sql.prepare('SELECT status FROM orders WHERE id = ?').get(o.id).status, 'cancelled');
  });

  await t.test('retrait : jamais « delivering », ready → delivered, puis figé', async () => {
    const o = (await pickup()).data;
    assert.equal((await status(o.id, 'ready')).status, 200);
    const r = await status(o.id, 'delivering');
    assert.equal(r.status, 400);
    assert.match(r.data.error, /emporter/);
    assert.equal((await status(o.id, 'delivered')).status, 200);
    assert.equal((await status(o.id, 'cancelled')).status, 400, 'annuler une commande livrée');
    assert.equal((await status(o.id, 'ready')).status, 400);
  });

  await t.test('livraison : « delivering » seulement avec un livreur', async () => {
    await freshCustomer();
    const o = (await delivery()).data;
    assert.equal((await status(o.id, 'ready')).status, 200);
    const r = await status(o.id, 'delivering');
    assert.equal(r.status, 400);
    assert.match(r.data.error, /livreur/);
    assert.equal((await status(o.id, 'delivered')).status, 400, 'ready → delivered sans livreur');
    // Avec un livreur : l'admin peut forcer « delivered ».
    const drv = await admin.call('POST', '/api/admin/drivers', { name: 'Yao', phone: '91222222', password: 'livreur1' });
    assert.equal(drv.status, 201);
    assert.equal(drv.data.phone, '+22891222222');
    const a = await admin.call('PATCH', `/api/admin/orders/${o.id}/assign`, { driver_id: drv.data.id });
    assert.equal(a.data.status, 'delivering');
    assert.equal((await status(o.id, 'delivered')).status, 200);
  });

  await t.test('livreur désactivé : ses livraisons repartent « À livrer »', async () => {
    await freshCustomer();
    const drv = await admin.call('POST', '/api/admin/drivers', { name: 'Koffi', phone: '91333333', password: 'livreur1' });
    const driver = await login('91333333', 'livreur1');
    const o = (await delivery()).data;
    await status(o.id, 'ready');
    const take = await driver.call('POST', `/api/driver/orders/${o.id}/take`);
    assert.equal(take.data.status, 'delivering');
    const off = await admin.call('PATCH', `/api/admin/drivers/${drv.data.id}`, { active: false });
    assert.equal(off.status, 200);
    const after = (await admin.call('GET', `/api/orders/${o.id}`)).data;
    assert.equal(after.status, 'ready');
    assert.equal(after.driver_id, null);
    assert.ok(sql.prepare(`SELECT 1 FROM audit_logs WHERE action = 'delivery_released'`).get());
  });

  await t.test('position en direct du client : partage, livreur, arrêt, confidentialité', async () => {
    await freshCustomer();
    await admin.call('POST', '/api/admin/drivers', { name: 'Kossi', phone: '91444444', password: 'livreur1' });
    const driver = await login('91444444', 'livreur1');
    const o = (await delivery()).data;

    // Durée invalide, retrait refusé, autre client : 404.
    assert.equal((await cust.call('POST', `/api/orders/${o.id}/live-share`, { minutes: 7 })).status, 400);
    const other = await register('Autre', '93999999');
    assert.equal((await other.call('POST', `/api/orders/${o.id}/live-share`, { minutes: 15 })).status, 404);
    const pick = (await pickup()).data;
    assert.equal((await cust.call('POST', `/api/orders/${pick.id}/live-share`, { minutes: 15 })).status, 400);

    // Démarrage avec position : visible par le client.
    const start = await cust.call('POST', `/api/orders/${o.id}/live-share`, { minutes: 60, lat: 6.17, lng: 1.21, accuracy: 12 });
    assert.equal(start.status, 200, JSON.stringify(start.data));
    assert.ok(start.data.live_share_until);
    assert.equal(start.data.customer_location.lat, 6.17);

    // Livreur pas encore attribué : il ne voit rien ; attribué : il suit le client.
    await status(o.id, 'ready');
    const before = (await driver.call('GET', '/api/driver/orders?scope=available')).data.find((x) => x.id === o.id);
    assert.equal(before.customer_location, null);
    await driver.call('POST', `/api/driver/orders/${o.id}/take`);
    await sleep(3100); // envois espacés de 3 s au plus
    const moved = await cust.call('POST', `/api/orders/${o.id}/live-location`, { lat: 6.18, lng: 1.22, heading: 90 });
    assert.deepEqual(moved.data.sharing, true);
    const mine = (await driver.call('GET', '/api/driver/orders?scope=mine')).data.find((x) => x.id === o.id);
    assert.equal(mine.customer_location.lat, 6.18);
    assert.equal(mine.customer_location.heading, 90);
    // Le livreur envoie sa position : l'arrivée est estimée jusqu'au client.
    await driver.call('POST', '/api/driver/location', { lat: 6.16, lng: 1.2 });
    const tracked = (await cust.call('GET', `/api/orders/${o.id}`)).data;
    assert.ok(tracked.driver_location && tracked.eta_minutes >= 1);

    // Position invalide : 400 ; arrêt : plus rien, et l'app est priée d'arrêter d'envoyer.
    assert.equal((await cust.call('POST', `/api/orders/${o.id}/live-location`, { lat: 200, lng: 1 })).status, 400);
    const stopped = await cust.call('POST', `/api/orders/${o.id}/live-share`, { minutes: 0 });
    assert.equal(stopped.data.live_share_until, null);
    assert.equal(stopped.data.customer_location, null);
    assert.equal((await cust.call('POST', `/api/orders/${o.id}/live-location`, { lat: 6.18, lng: 1.22 })).data.sharing, false);
    assert.ok(!sql.prepare('SELECT 1 FROM customer_live_locations WHERE order_id = ?').get(o.id));

    // Partage expiré : plus montré.
    await cust.call('POST', `/api/orders/${o.id}/live-share`, { minutes: 15, lat: 6.18, lng: 1.22 });
    sql.prepare(`UPDATE orders SET live_share_until = datetime('now', '-1 minute') WHERE id = ?`).run(o.id);
    assert.equal((await driver.call('GET', '/api/driver/orders?scope=mine')).data.find((x) => x.id === o.id).customer_location, null);
  });

  await t.test('pagination : limit, before_id, X-Has-More', async () => {
    await freshCustomer();
    for (let i = 0; i < 5; i++) assert.equal((await pickup()).status, 201);
    const all = (await cust.call('GET', '/api/orders?limit=200')).data;
    assert.equal(all.length, 5);
    assert.ok(all.length >= 5);
    const p1 = await cust.call('GET', '/api/orders?limit=2');
    assert.equal(p1.data.length, 2);
    assert.equal(p1.headers.get('x-has-more'), '1');
    assert.deepEqual(p1.data.map((o) => o.id), all.slice(0, 2).map((o) => o.id));
    const p2 = await cust.call('GET', `/api/orders?limit=2&before_id=${p1.data[1].id}`);
    assert.deepEqual(p2.data.map((o) => o.id), all.slice(2, 4).map((o) => o.id));
    const last = await cust.call('GET', `/api/orders?limit=200&before_id=${all[all.length - 2].id}`);
    assert.equal(last.data.length, 1);
    assert.equal(last.headers.get('x-has-more'), '0');
    const adm = await admin.call('GET', '/api/admin/orders?status=active&limit=1');
    assert.equal(adm.data.length, 1);
    assert.equal(adm.headers.get('x-has-more'), '1');
  });

  await t.test('admin users : recherche ?q=', async () => {
    const r = await admin.call('GET', '/api/admin/users?q=Client%20Test');
    assert.equal(r.status, 200);
    assert.equal(r.data.length, 1);
    assert.equal((await admin.call('GET', '/api/admin/users?q=90111')).data.length, 1);
    assert.equal((await admin.call('GET', '/api/admin/users?q=%25')).data.length, 0, '% littéral');
  });

  await t.test('argent reçu sur une tentative abandonnée : commande validée', async () => {
    await freshCustomer();
    const o = (await delivery('flooz')).data;
    const push = await cust.call('POST', `/api/orders/${o.id}/payments`, { phone: '90111111' });
    assert.equal(push.status, 201);
    const ab = await cust.call('POST', `/api/orders/${o.id}/payments/current/abandon`);
    assert.equal(ab.data.payment.status, 'failed');
    // Le client a finalement validé sur son téléphone : le prestataire répond « payé ».
    sql.prepare(`UPDATE payments SET provider_state = '{"result":"paid"}', last_checked_at = NULL WHERE id = ?`).run(push.data.payment.id);
    const paid = await until(() => sql.prepare('SELECT payment_status FROM orders WHERE id = ?').get(o.id).payment_status === 'paid');
    assert.ok(paid, 'commande payée après revérification');
    assert.equal(sql.prepare('SELECT status FROM payments WHERE id = ?').get(push.data.payment.id).status, 'paid');
  });

  await t.test('argent reçu sur une commande annulée : alerte critique « rembourser »', async () => {
    await freshCustomer();
    const o = (await delivery('mixx')).data;
    const push = await cust.call('POST', `/api/orders/${o.id}/payments`, { phone: '90111111' });
    assert.equal((await cust.call('POST', `/api/orders/${o.id}/cancel`)).data.status, 'cancelled');
    sql.prepare(`UPDATE payments SET provider_state = '{"result":"paid"}', last_checked_at = NULL WHERE id = ?`).run(push.data.payment.id);
    const alert = await until(() => sql.prepare(`SELECT * FROM alerts WHERE type = 'refund_needed' AND details LIKE ?`).get(`%"orderId":${o.id}%`));
    assert.ok(alert, 'alerte refund_needed');
    assert.equal(alert.severity, 'critical');
    assert.equal(sql.prepare('SELECT status FROM orders WHERE id = ?').get(o.id).status, 'cancelled');
  });

  await t.test('paiement explicitement refusé par le prestataire : pas de revérification', async () => {
    await freshCustomer();
    const o = (await delivery('flooz')).data;
    const push = await cust.call('POST', `/api/orders/${o.id}/payments`, { phone: '90111111' });
    const sim = await cust.call('POST', `/api/orders/${o.id}/payments/current/simulate`, { result: 'failed' });
    assert.equal(sim.data.payment.status, 'failed');
    sql.prepare(`UPDATE payments SET provider_state = '{"result":"paid"}', last_checked_at = NULL WHERE id = ?`).run(push.data.payment.id);
    await sleep(1500);
    assert.equal(sql.prepare('SELECT status FROM payments WHERE id = ?').get(push.data.payment.id).status, 'failed');
  });

  await t.test('commande remboursée : /pay ne la rouvre pas, stats hors remboursées', async () => {
    await freshCustomer();
    const o = (await pickup('flooz')).data;
    await cust.call('POST', `/api/orders/${o.id}/payments`, { phone: '90111111' });
    const sim = await cust.call('POST', `/api/orders/${o.id}/payments/current/simulate`, { result: 'paid' });
    assert.equal(sim.data.order.payment_status, 'paid');
    assert.equal((await status(o.id, 'ready')).status, 200);
    assert.equal((await status(o.id, 'delivered')).status, 200);
    const before = (await admin.call('GET', '/api/admin/stats')).data;
    const rf = await admin.call('POST', `/api/admin/orders/${o.id}/refund`, { reference: 'RMB-1' });
    assert.equal(rf.data.payment_status, 'refunded');
    const pay = await cust.call('POST', `/api/orders/${o.id}/pay`);
    assert.equal(pay.status, 400);
    assert.equal(sql.prepare('SELECT payment_status FROM orders WHERE id = ?').get(o.id).payment_status, 'refunded');
    const after = (await admin.call('GET', '/api/admin/stats')).data;
    assert.equal(after.total.revenue, before.total.revenue - o.total);
  });

  await t.test('une référence prestataire ne paie qu\'une seule commande', async () => {
    await freshCustomer();
    const a = (await delivery('flooz')).data;
    const pa = (await cust.call('POST', `/api/orders/${a.id}/payments`, { phone: '90111111' })).data.payment;
    assert.equal((await cust.call('POST', `/api/orders/${a.id}/payments/current/simulate`, { result: 'paid' })).data.order.payment_status, 'paid');
    const b = (await delivery('flooz')).data;
    const pb = (await cust.call('POST', `/api/orders/${b.id}/payments`, { phone: '90111111' })).data.payment;
    const refA = sql.prepare('SELECT provider_reference FROM payments WHERE id = ?').get(pa.id).provider_reference;
    sql.prepare('UPDATE payments SET provider_reference = ? WHERE id = ?').run(refA, pb.id);
    const sim = await cust.call('POST', `/api/orders/${b.id}/payments/current/simulate`, { result: 'paid' });
    assert.equal(sim.data.payment.status, 'failed');
    assert.notEqual(sim.data.order.payment_status, 'paid');
    assert.ok(sql.prepare(`SELECT 1 FROM alerts WHERE type = 'payment_reference_mismatch' AND severity = 'critical'`).get());
  });

  await t.test('stats du jour : non annulées ET (espèces OU payées)', async () => {
    const expected = sql.prepare(
      `SELECT COALESCE(SUM(total), 0) AS n FROM orders WHERE date(created_at) = date('now') AND status != 'cancelled'
         AND (payment_method = 'cash' OR payment_status = 'paid')`,
    ).get().n;
    const unpaid = sql.prepare(`SELECT COUNT(*) AS n FROM orders WHERE payment_method != 'cash' AND payment_status != 'paid' AND status != 'cancelled'`).get().n;
    assert.ok(unpaid >= 0);
    const s = (await admin.call('GET', '/api/admin/stats')).data;
    assert.equal(s.today.revenue, expected);
    const naive = sql.prepare(`SELECT COALESCE(SUM(total), 0) AS n FROM orders WHERE status != 'cancelled'`).get().n;
    assert.ok(s.today.revenue < naive, 'les commandes mobile money non payées ne comptent pas');
  });

  await t.test('production : simulation refusée au client (403), sauf ALLOW_SIMULATION=1', async () => {
    await freshCustomer();
    const o = (await delivery('flooz')).data;
    await stop(srv);
    srv = startServer(dir, { NODE_ENV: 'production' });
    await waitHealth(srv);
    const c = await login(`${92000000 + seq}`, 'secret123');
    const s = (await c.call('GET', '/api/settings')).data;
    assert.equal(s.payment_mode, 'test', 'bandeau d\'info inchangé');
    const push = await c.call('POST', `/api/orders/${o.id}/payments`, { phone: '90111111' });
    assert.equal(push.status, 201);
    const sim = await c.call('POST', `/api/orders/${o.id}/payments/current/simulate`, { result: 'paid' });
    assert.equal(sim.status, 403);
    assert.equal(sim.data.error, 'Mode test désactivé');
    assert.notEqual(sql.prepare('SELECT payment_status FROM orders WHERE id = ?').get(o.id).payment_status, 'paid');

    await stop(srv);
    srv = startServer(dir, { NODE_ENV: 'production', ALLOW_SIMULATION: '1' });
    await waitHealth(srv);
    const c2 = await login(`${92000000 + seq}`, 'secret123');
    const sim2 = await c2.call('POST', `/api/orders/${o.id}/payments/current/simulate`, { result: 'paid' });
    assert.equal(sim2.status, 200, JSON.stringify(sim2.data));
    assert.equal(sim2.data.order.payment_status, 'paid');
  });
});
