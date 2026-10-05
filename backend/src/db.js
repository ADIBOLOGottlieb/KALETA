const path = require('path');
const { DatabaseSync } = require('node:sqlite');
const { parseOpeningHours } = require('./hours');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, '..', 'eza_zozo.db');
const db = new DatabaseSync(DB_PATH);

db.exec(`
  PRAGMA foreign_keys = ON;
  PRAGMA journal_mode = WAL;
  -- Attend jusqu'à 5 s qu'un autre accès (sauvegarde, test) libère la base au lieu d'échouer.
  PRAGMA busy_timeout = 5000;

  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    phone TEXT NOT NULL UNIQUE,
    email TEXT,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'customer' CHECK (role IN ('customer', 'admin', 'driver')),
    address TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS categories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    icon TEXT,
    position INTEGER NOT NULL DEFAULT 0
  );

  CREATE TABLE IF NOT EXISTS products (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    description TEXT,
    price INTEGER NOT NULL,
    image_url TEXT,
    available INTEGER NOT NULL DEFAULT 1,
    popular INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id),
    status TEXT NOT NULL DEFAULT 'pending',
    mode TEXT NOT NULL CHECK (mode IN ('delivery', 'pickup')),
    address TEXT,
    phone TEXT NOT NULL,
    note TEXT,
    payment_method TEXT NOT NULL,
    subtotal INTEGER NOT NULL,
    delivery_fee INTEGER NOT NULL DEFAULT 0,
    total INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS order_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id INTEGER REFERENCES products(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    unit_price INTEGER NOT NULL,
    quantity INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  -- Tentatives de paiement mobile money (une commande peut en avoir plusieurs).
  CREATE TABLE IF NOT EXISTS payments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    reference TEXT,
    amount INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    raw TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  -- Journal d'audit des actions sensibles.
  CREATE TABLE IF NOT EXISTS audit_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    user_id INTEGER,
    action TEXT NOT NULL,
    details TEXT,
    ip TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_logs(created_at);
  CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_logs(action, created_at);

  -- Alertes de sécurité / monitoring (pics de transactions, attaques...).
  CREATE TABLE IF NOT EXISTS alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    type TEXT NOT NULL,
    severity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    message TEXT NOT NULL,
    details TEXT,
    resolved INTEGER NOT NULL DEFAULT 0
  );
  CREATE INDEX IF NOT EXISTS idx_orders_created ON orders(created_at);
`);

/**
 * Ajoute le rôle 'driver' au CHECK de users.role sur une base existante.
 * SQLite ne sait pas modifier un CHECK : reconstruction de la table (procédure officielle) en
 * reprenant le schéma ACTUEL (toutes les colonnes, y compris celles ajoutées par account.js :
 * avatar_url, momo_phone, deleted_at...). Idempotente : ne fait rien si 'driver' est déjà accepté.
 * @returns true si la table a été reconstruite.
 */
function migrateUsersRole(database) {
  const row = database.prepare(`SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'users'`).get();
  if (!row) return false;
  const checkRe = /CHECK\s*\(\s*role\s+IN\s*\(([^)]*)\)\s*\)/i;
  const m = row.sql.match(checkRe);
  if (!m || /'driver'/.test(m[1])) return false;
  const newSql = row.sql
    .replace(checkRe, "CHECK (role IN ('customer', 'admin', 'driver'))")
    .replace(/^CREATE TABLE\s+(?:IF NOT EXISTS\s+)?["`[]?users["`\]]?/i, 'CREATE TABLE users_new');
  const cols = database.prepare('PRAGMA table_info(users)').all().map((c) => `"${c.name}"`).join(', ');
  // Index et déclencheurs de users (hors index automatiques) à recréer après le renommage.
  const extras = database
    .prepare(`SELECT sql FROM sqlite_master WHERE tbl_name = 'users' AND type IN ('index', 'trigger') AND sql IS NOT NULL`)
    .all()
    .map((r) => r.sql);
  const seq = database.prepare(`SELECT seq FROM sqlite_sequence WHERE name = 'users'`).get()?.seq ?? 0;
  const count = database.prepare('SELECT COUNT(*) AS n FROM users').get().n;
  const brokenBefore = new Set(database.prepare('PRAGMA foreign_key_check').all().map((r) => `${r.table}:${r.rowid}:${r.fkid}`));

  // PRAGMA foreign_keys est sans effet dans une transaction : on le coupe avant.
  database.exec('PRAGMA foreign_keys = OFF');
  try {
    database.exec('BEGIN IMMEDIATE');
    try {
      database.exec(newSql);
      database.exec(`INSERT INTO users_new (${cols}) SELECT ${cols} FROM users`);
      database.exec('DROP TABLE users');
      database.exec('ALTER TABLE users_new RENAME TO users');
      for (const sql of extras) database.exec(sql);
      database.prepare(`UPDATE sqlite_sequence SET seq = MAX(seq, ?) WHERE name = 'users'`).run(seq);
      const copied = database.prepare('SELECT COUNT(*) AS n FROM users').get().n;
      if (copied !== count) throw new Error(`migration users : ${copied} lignes copiées sur ${count}`);
      // Seules les violations apparues avec la migration la bloquent (pas d'éventuelles anciennes).
      const broken = database.prepare('PRAGMA foreign_key_check').all()
        .filter((r) => !brokenBefore.has(`${r.table}:${r.rowid}:${r.fkid}`));
      if (broken.length) throw new Error(`migration users : clés étrangères invalides ${JSON.stringify(broken.slice(0, 5))}`);
      database.exec('COMMIT');
    } catch (err) {
      database.exec('ROLLBACK');
      throw err;
    }
  } finally {
    database.exec('PRAGMA foreign_keys = ON');
  }
  console.log(`🛵 Migration : rôle livreur ajouté à la table users (${count} comptes conservés)`);
  return true;
}

// Migrations : ajoute les colonnes manquantes sur une base existante.
function addColumn(table, column, definition) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);
  if (!cols.includes(column)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
}
migrateUsersRole(db);
// Un compte désactivé (livreur) ne peut plus se connecter ni prendre de livraison.
addColumn('users', 'active', 'INTEGER NOT NULL DEFAULT 1');
// Livraison : livreur attribué, prise en charge, « Livraison faite » (livreur), « Reçu » (client).
addColumn('orders', 'driver_id', 'INTEGER REFERENCES users(id)');
addColumn('orders', 'picked_up_at', 'TEXT');
addColumn('orders', 'driver_delivered_at', 'TEXT');
addColumn('orders', 'received_at', 'TEXT');
db.exec(`
  CREATE INDEX IF NOT EXISTS idx_orders_driver ON orders(driver_id, status);
  CREATE INDEX IF NOT EXISTS idx_orders_status_mode ON orders(status, mode);
`);
addColumn('orders', 'delivery_lat', 'REAL');
addColumn('orders', 'delivery_lng', 'REAL');
addColumn('orders', 'delivery_accuracy', 'REAL');
addColumn('orders', 'payment_fee', 'INTEGER NOT NULL DEFAULT 0');
addColumn('orders', 'payment_status', "TEXT NOT NULL DEFAULT 'unpaid'");
addColumn('orders', 'payment_reference', 'TEXT');
addColumn('orders', 'payment_token', 'TEXT');
addColumn('orders', 'paid_at', 'TEXT');
// Taux des frais mobile money figé à la création (commission de l'agrégateur ou réglage admin).
addColumn('orders', 'payment_fee_percent', 'REAL');
// Packs de menu : contenu d'un pack (JSON [{product_id, quantity}]) et détail figé sur la ligne de commande.
addColumn('products', 'pack_items', 'TEXT');
addColumn('order_items', 'details', 'TEXT');
// Distance estimée restaurant → client (km, 1 décimale) calculée à la création de la commande.
addColumn('orders', 'delivery_distance_km', 'REAL');
// Niveau du personnel (role 'admin') : 'owner' (propriétaire) ou 'manager' (gérant) ; NULL = gérant.
addColumn('users', 'admin_level', 'TEXT');
// Ventes au comptoir (caisse) : origine ('app' | 'counter'), consommation sur place, nom donné par le client.
addColumn('orders', 'source', "TEXT NOT NULL DEFAULT 'app'");
addColumn('orders', 'dine_in', 'INTEGER NOT NULL DEFAULT 0');
addColumn('orders', 'customer_label', 'TEXT');
// Zone de livraison retenue (mode de frais 'zone') ; le nom est figé sur la commande.
addColumn('orders', 'delivery_zone_id', 'INTEGER');
addColumn('orders', 'delivery_zone_name', 'TEXT');
db.exec(`
  CREATE INDEX IF NOT EXISTS idx_orders_source ON orders(source, id);

  -- Zones de livraison : prix par quartier, reconnaissance facultative par un cercle (centre + rayon).
  CREATE TABLE IF NOT EXISTS delivery_zones (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    fee INTEGER NOT NULL,
    active INTEGER NOT NULL DEFAULT 1,
    position INTEGER NOT NULL DEFAULT 0,
    center_lat REAL,
    center_lng REAL,
    radius_km REAL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
`);

db.exec(`
  -- Dernière position d'un livreur, enregistrée seulement pendant une livraison (suivi en direct).
  CREATE TABLE IF NOT EXISTS driver_locations (
    driver_id INTEGER PRIMARY KEY,
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    accuracy REAL,
    heading REAL,
    speed REAL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  -- Journal des erreurs : plantages de l'app (POST /api/client-errors) et erreurs du serveur (log.error).
  CREATE TABLE IF NOT EXISTS error_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    source TEXT NOT NULL CHECK (source IN ('app', 'server')),
    message TEXT NOT NULL,
    stack TEXT,
    context TEXT,
    app_version TEXT,
    platform TEXT,
    user_id INTEGER
  );
  CREATE INDEX IF NOT EXISTS idx_error_logs_source ON error_logs(source, created_at);
`);

// Paiements mobile money : suivi de l'argent (brut, frais, net, reversement, remboursement).
for (const [col, def] of [
  ['operator', 'TEXT'],
  ['phone', 'TEXT'],
  ['identifier', 'TEXT'],
  ['provider_reference', 'TEXT'],
  ['operator_reference', 'TEXT'],
  ['gross_amount', 'INTEGER'],
  ['provider_fee', 'INTEGER NOT NULL DEFAULT 0'],
  ['net_amount', 'INTEGER'],
  ['message', 'TEXT'],
  ['simulated', 'INTEGER NOT NULL DEFAULT 0'],
  ['provider_state', 'TEXT'],
  ['needs_review', 'INTEGER NOT NULL DEFAULT 0'],
  ['expires_at', 'TEXT'],
  ['paid_at', 'TEXT'],
  ['last_checked_at', 'TEXT'],
  ['validated_by', 'INTEGER'],
  ['settlement_status', 'TEXT'],
  ['settled_at', 'TEXT'],
  ['settlement_reference', 'TEXT'],
  ['refund_status', 'TEXT'],
  ['refund_reference', 'TEXT'],
  ['refunded_at', 'TEXT'],
  ['refunded_by', 'INTEGER'],
  // Échec décidé chez nous (abandon, remplacement, annulation, erreur réseau) et non par le
  // prestataire : la tentative est revérifiée pendant 30 min (argent reçu quand même ?).
  ['failure_kind', 'TEXT'],
]) {
  addColumn('payments', col, def);
}
// Reprise des anciennes lignes (avant la refonte des paiements).
db.exec(`
  UPDATE payments SET operator = (SELECT payment_method FROM orders WHERE orders.id = payments.order_id)
    WHERE operator IS NULL;
  UPDATE payments SET provider_reference = reference WHERE provider_reference IS NULL AND reference IS NOT NULL;
  UPDATE payments SET gross_amount = amount, net_amount = amount, paid_at = COALESCE(paid_at, updated_at),
    settlement_status = 'en_attente' WHERE status = 'paid' AND gross_amount IS NULL;
  CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_identifier ON payments(identifier);
  CREATE INDEX IF NOT EXISTS idx_payments_order ON payments(order_id, id);
  CREATE INDEX IF NOT EXISTS idx_payments_status ON payments(status, paid_at);
  CREATE INDEX IF NOT EXISTS idx_payments_provider_ref ON payments(provider_reference);
`);

function transaction(fn) {
  db.exec('BEGIN');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

function optionalNumber(value) {
  if (value == null || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function getSettings() {
  const rows = db.prepare('SELECT key, value FROM settings').all();
  const s = Object.fromEntries(rows.map((r) => [r.key, r.value]));
  return {
    delivery_fee: Number(s.delivery_fee ?? 1000),
    min_order: Number(s.min_order ?? 2000),
    is_open: (s.is_open ?? '1') === '1',
    restaurant_phone: s.restaurant_phone ?? '+228 91 00 84 84',
    restaurant_address: s.restaurant_address ?? "Face au lycée d'Agoè, à côté de l'OTR, Lomé",
    // Taux des frais de paiement mobile money (en %), utilisé seulement sans
    // commission d'agrégateur en variable d'environnement (voir payments/fees.js).
    payment_fee_percent: Number(s.payment_fee_percent ?? 2),
    // Qui paie la commission de l'agrégateur : 'restaurant' (défaut, le client paie le prix affiché)
    // ou 'client' (frais ajoutés au total, voir payments/core.js paymentFeeDetails).
    payment_fees_paid_by: s.payment_fees_paid_by === 'client' ? 'client' : 'restaurant',
    // Seuils de détection de pic de transactions.
    spike_min_orders: Number(s.spike_min_orders ?? 10),
    spike_factor: Number(s.spike_factor ?? 3),
    high_amount_alert: Number(s.high_amount_alert ?? 100000),
    // Annulation automatique d'une commande mobile money non payée (minutes).
    momo_unpaid_cancel_minutes: Number(s.momo_unpaid_cancel_minutes ?? 30),
    // Position du restaurant (départ des itinéraires de livraison) : null tant que non définie.
    restaurant_lat: optionalNumber(s.restaurant_lat),
    restaurant_lng: optionalNumber(s.restaurant_lng),
    // Passage automatique à « livrée » sans « Reçu » du client (heures après « Livraison faite »).
    delivery_auto_confirm_hours: Number(s.delivery_auto_confirm_hours ?? 12),
    // Frais de livraison : 'fixed' (delivery_fee), 'distance' (base + km au-delà des km inclus)
    // ou 'zone' (prix de la zone choisie, table delivery_zones).
    delivery_fee_mode: ['distance', 'zone'].includes(s.delivery_fee_mode) ? s.delivery_fee_mode : 'fixed',
    delivery_fee_per_km: Number(s.delivery_fee_per_km ?? 200),
    delivery_free_km: Number(s.delivery_free_km ?? 2),
    delivery_max_km: Number(s.delivery_max_km ?? 0), // 0 = illimité
    // Horaires d'ouverture (hours.js) ; is_open ci-dessus = interrupteur manuel.
    hours_enabled: (s.hours_enabled ?? '0') === '1',
    opening_hours: parseOpeningHours(s.opening_hours),
  };
}

module.exports = { db, transaction, getSettings, migrateUsersRole };
