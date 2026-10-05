// Packs de menu (node --test). Serveur de test sur le port 4615 (base temporaire).
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const bcrypt = require('bcryptjs');

const BACKEND = path.join(__dirname, '..');
const PORT = 4615;
const BASE = `http://localhost:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function startServer(dir) {
  const env = {
    ...process.env, PORT: String(PORT), DB_PATH: path.join(dir, 'packs.db'), LOG_DIR: path.join(dir, 'logs'), LOG_CONSOLE: '0',
    JWT_SECRET: 'test-secret-features', ADMIN_PHONE: '0700000000', ADMIN_PASSWORD: 'admin123', NODE_ENV: 'test',
    PAYMENT_PROVIDER: '', PAYGATE_AUTH_TOKEN: '', KADEV_PUBLIC_KEY: '', KADEV_SECRET_KEY: '', ALLOW_SIMULATION: '',
    PROVIDER_FEE_PERCENT: '', PROVIDER_FEE_PERCENT_FLOOZ: '', PROVIDER_FEE_PERCENT_MIXX: '', SMS_PROVIDER: '',
    FIREBASE_SERVICE_ACCOUNT: '', BACKUP_GITHUB_REPO: '', BACKUP_GITHUB_TOKEN: '',
    // Aucun appel réseau réel : services de cartes injoignables (non utilisés par ces tests).
    NOMINATIM_URL: 'http://127.0.0.1:9', OSRM_URL: 'http://127.0.0.1:9',
    PAYMENT_TASK_INTERVAL_MS: '600000', RECONCILE_DELAY_MS: '3600000', DELIVERY_TASK_INTERVAL_MS: '600000',
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
    return { status: res.status, data };
  };
  return { call, token: () => token, setToken: (t) => (token = t) };
}
async function login(phone, password) {
  const c = client();
  const r = await c.call('POST', '/api/auth/login', { phone, password });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  c.setToken(r.data.token);
  c.user = r.data.user;
  return c;
}

test('packs : catalogue, création, disponibilité, commande', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ezazozo-packs-'));
  const srv = startServer(dir);
  t.after(() => stop(srv));
  await waitHealth(srv);
  const sql = new DatabaseSync(path.join(dir, 'packs.db'));
  sql.exec('PRAGMA busy_timeout = 5000');
  t.after(() => sql.close());

  const admin = await login('0700000000', 'admin123');
  sql.prepare('INSERT INTO users (name, phone, password_hash) VALUES (?, ?, ?)').run('Client', '+22893111111', bcrypt.hashSync('secret123', 4));
  const cust = await login('93111111', 'secret123');

  const cats = (await admin.call('GET', '/api/categories')).data;
  const packsCat = cats.find((c) => c.name === 'Packs');
  assert.ok(packsCat, 'catégorie Packs créée');

  let products = (await cust.call('GET', '/api/products')).data;
  const solo = products.find((p) => p.name === 'Pack Solo');
  assert.ok(solo && solo.is_pack);
  assert.deepEqual(solo.pack_items.map((i) => [i.name, i.quantity]), [['Tilapia braisé', 1], ['Attiéké', 1], ['Bissap', 1]]);
  assert.equal(solo.pack_value, 8000 + 1500 + 2000);
  assert.equal(solo.savings, 11500 - 10000);
  const plain = products.find((p) => p.name === 'Alloco');
  assert.equal(plain.is_pack, false);
  assert.deepEqual(plain.pack_items, []);

  // Création d'un pack par le gérant.
  const burger = products.find((p) => p.name === 'Hamburger');
  const fries = products.find((p) => p.name === 'Frites');
  const created = await admin.call('POST', '/api/admin/products', {
    name: 'Pack Midi', price: 3000, category_id: packsCat.id,
    pack_items: [{ product_id: burger.id, quantity: 1 }, { product_id: fries.id, quantity: 1 }],
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  assert.equal(created.data.pack_value, 3500);
  assert.equal(created.data.savings, 500);

  // Refus : pack dans un pack, plat inexistant, quantité invalide, plat d'un pack transformé en pack.
  const nested = await admin.call('POST', '/api/admin/products', { name: 'X', price: 1000, pack_items: [{ product_id: solo.id, quantity: 1 }] });
  assert.equal(nested.status, 400);
  assert.equal((await admin.call('POST', '/api/admin/products', { name: 'X', price: 1000, pack_items: [{ product_id: 99999, quantity: 1 }] })).status, 400);
  assert.equal((await admin.call('POST', '/api/admin/products', { name: 'X', price: 1000, pack_items: [{ product_id: fries.id, quantity: 0 }] })).status, 400);
  const toPack = await admin.call('PUT', `/api/admin/products/${fries.id}`, {
    name: fries.name, price: fries.price, category_id: fries.category_id, pack_items: [{ product_id: burger.id, quantity: 1 }],
  });
  assert.equal(toPack.status, 400);

  // Commande d'un pack : détail figé sur la ligne.
  const order = await cust.call('POST', '/api/orders', {
    items: [{ product_id: solo.id, quantity: 2 }], phone: '93111111', mode: 'pickup', payment_method: 'cash',
  });
  assert.equal(order.status, 201, JSON.stringify(order.data));
  assert.equal(order.data.subtotal, 20000);
  assert.equal(order.data.items[0].details, '1× Tilapia braisé, 1× Attiéké, 1× Bissap');

  // Plat épuisé : le pack disparaît du catalogue client et ne peut plus être commandé.
  const attieke = products.find((p) => p.name === 'Attiéké');
  await admin.call('PATCH', `/api/admin/products/${attieke.id}/availability`, { available: false });
  products = (await cust.call('GET', '/api/products')).data;
  assert.ok(!products.some((p) => p.name === 'Pack Solo'));
  const adminList = (await admin.call('GET', '/api/products?all=1')).data;
  const soloAdmin = adminList.find((p) => p.name === 'Pack Solo');
  assert.equal(soloAdmin.available, false);
  assert.equal(soloAdmin.available_raw, true);
  assert.equal(soloAdmin.components_available, false);
  const refused = await cust.call('POST', '/api/orders', {
    items: [{ product_id: solo.id, quantity: 1 }], phone: '93111111', mode: 'pickup', payment_method: 'cash',
  });
  assert.equal(refused.status, 400);
});
