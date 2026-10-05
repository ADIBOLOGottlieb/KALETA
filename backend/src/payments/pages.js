/**
 * Pages HTML /pay/:id (parcours navigateur KADEV PAY, conservé) et webhooks des prestataires.
 * Monté AVANT express.json() : le webhook KADEV vérifie une signature sur le corps brut.
 */
const crypto = require('crypto');
const express = require('express');
const { db } = require('../db');
const { log } = require('../logger');
const { audit, raiseAlert } = require('../monitor');
const providers = require('./providers');
const core = require('./core');
const { parseJson, normalizeMomoPhone } = require('./util');

const kadev = providers.registry.kadev;

const newToken = () => crypto.randomBytes(24).toString('hex');

function findOrderForPayment(id, token) {
  const order = db
    .prepare(`SELECT o.*, u.name AS customer_name, u.email AS customer_email FROM orders o
              JOIN users u ON u.id = o.user_id WHERE o.id = ?`)
    .get(Number(id));
  if (!order || !token || !order.payment_token) return null;
  const a = Buffer.from(String(token));
  const b = Buffer.from(order.payment_token);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  return order;
}

/** Tentative du parcours navigateur : la tentative en attente du bon prestataire, sinon une nouvelle. */
function browserAttempt(order, provider) {
  const cur = core.currentPayment(order.id);
  if (cur && cur.status === 'pending' && cur.provider === provider.name) return cur;
  const id = core.openAttempt(order, provider, normalizeMomoPhone(order.phone) || order.phone);
  return core.getPayment(id);
}

const esc = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const fcfaLong = (n) => `${String(Math.round(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')} FCFA`;

function page(res, { title, body, script = '', nonce = '' }) {
  res.set(
    'Content-Security-Policy',
    [
      "default-src 'self'",
      `script-src 'self' 'nonce-${nonce}' https://pay.kadev.ci`,
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: https:",
      "connect-src 'self' https:",
      'frame-src https:',
    ].join('; '),
  );
  res.type('html').send(`<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)} – KALETA</title>
<style>
  *{box-sizing:border-box} body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#F8F3E8;color:#1A1410}
  header{background:linear-gradient(135deg,#17924A,#0F4F38 55%,#03150F);border-bottom:2px solid #D4B566;color:#fff;padding:28px 20px 60px;text-align:center}
  header img{width:84px;height:84px;border-radius:50%;object-fit:contain;background:#03150F;box-shadow:0 8px 24px rgba(0,0,0,.2)}
  header h1{font-size:20px;margin:12px 0 0}
  main{max-width:460px;margin:-40px auto 24px;padding:0 16px}
  .card{background:#fff;border-radius:20px;padding:20px;box-shadow:0 8px 30px rgba(15,79,56,.15)}
  .row{display:flex;justify-content:space-between;padding:6px 0;color:#7A6A64} .row b{color:#2B1B17}
  .total{border-top:1px dashed #e5d8cf;margin-top:8px;padding-top:12px;font-size:18px} .total b{color:#0F7A3A}
  button,.btn{display:block;width:100%;border:0;border-radius:14px;padding:16px;font-size:16px;font-weight:700;margin-top:14px;cursor:pointer;text-align:center;text-decoration:none}
  .primary{background:linear-gradient(135deg,#3FD162,#0F6B37);color:#fff} .ghost{background:#f1e9e2;color:#2B1B17} .ok{background:#2E9E5B;color:#fff}
  .badge{display:inline-block;background:#D4B566;color:#2B1B17;border-radius:20px;padding:4px 10px;font-size:12px;font-weight:700}
  .muted{color:#7A6A64;font-size:13px;text-align:center;margin-top:14px} .center{text-align:center}
  .big{font-size:54px;text-align:center;margin:4px 0}
</style></head>
<body><header><img src="/public/logo.png" alt="KALETA"><h1>${esc(title)}</h1></header>
<main>${body}</main>${script ? `<script nonce="${nonce}">${script}</script>` : ''}</body></html>`);
}

function summary(order) {
  return `<div class="row"><span>Commande</span><b>n°${order.id}</b></div>
    <div class="row"><span>Sous-total</span><b>${fcfaLong(order.subtotal)}</b></div>
    ${order.delivery_fee ? `<div class="row"><span>Livraison</span><b>${fcfaLong(order.delivery_fee)}</b></div>` : ''}
    ${order.payment_fee ? `<div class="row"><span>Frais de paiement (${String(core.orderFeePercent(order)).replace('.', ',')} %)</span><b>${fcfaLong(order.payment_fee)}</b></div>` : ''}
    <div class="row total"><span>Total à payer</span><b>${fcfaLong(order.total)}</b></div>`;
}

function resultPage(res, order) {
  const paid = order.payment_status === 'paid';
  page(res, {
    title: paid ? 'Paiement réussi' : 'Paiement non abouti',
    body: `<div class="card center">
      <div class="big">${paid ? '✅' : '⚠️'}</div>
      <p><b>${paid ? `Merci ! La commande n°${order.id} est payée.` : `Le paiement de la commande n°${order.id} n'a pas été confirmé.`}</b></p>
      <p class="muted">${paid ? 'Vous pouvez revenir dans l\'application pour suivre votre commande.' : 'Revenez dans l\'application pour réessayer ou choisir un autre moyen de paiement.'}</p>
    </div>`,
  });
}

const reloadOrder = (id) => db.prepare('SELECT * FROM orders WHERE id = ?').get(id);

const router = express.Router();

router.get('/pay/:id', (req, res) => {
  const order = findOrderForPayment(req.params.id, req.query.t);
  if (!order) return res.status(404).type('text').send('Lien de paiement invalide ou expiré.');
  if (['paid', 'refunded'].includes(order.payment_status) || order.status === 'cancelled') return resultPage(res, order);

  const nonce = crypto.randomBytes(16).toString('base64');
  const methodLabel = order.payment_method === 'flooz' ? 'Flooz (Moov Africa)' : 'Mixx by Yas';
  const provider = providers.forOperator(order.payment_method);

  if (provider.name === 'simulation' && !providers.simulationAllowed()) {
    return page(res, {
      title: 'Paiement',
      body: `<div class="card center"><p><b>Mode test désactivé.</b></p>
        <p class="muted">Le paiement en ligne n'est pas encore activé : contactez le restaurant pour régler votre commande.</p></div>`,
    });
  }
  if (provider.name === 'simulation') {
    return page(res, {
      title: 'Paiement',
      nonce,
      body: `<div class="card"><span class="badge">MODE TEST — aucun argent réel</span>
        <p>Paiement par <b>${esc(methodLabel)}</b></p>${summary(order)}
        <form method="post" action="/pay/${order.id}/simulate?t=${esc(req.query.t)}">
          <button class="primary" name="result" value="paid">Simuler un paiement réussi</button>
          <button class="ghost" name="result" value="failed">Simuler un échec</button>
        </form>
        <p class="muted">Configurez un prestataire de paiement sur le serveur pour activer les vrais paiements.</p></div>`,
    });
  }
  if (provider.name !== 'kadev') {
    return page(res, {
      title: 'Paiement',
      body: `<div class="card center"><p>Le paiement se fait directement depuis l'application : vous recevrez une
        demande sur votre téléphone à valider avec votre code secret.</p></div>`,
    });
  }

  const base = `${req.protocol}://${req.get('host')}`;
  const returnUrl = `${base}/pay/${order.id}/return?t=${encodeURIComponent(req.query.t)}`;
  const opts = {
    public_key: kadev.publicKey,
    amount: order.total,
    // L'e-mail est obligatoire chez KADEV : on génère une adresse technique si le client n'en a pas.
    email: order.customer_email || `client${order.user_id}@clients.kaleta.tg`,
    method: 'momo',
    name: order.customer_name,
    phone: order.phone,
    callback_url: returnUrl,
    metadata: { order_id: order.id, operator: order.payment_method },
  };
  page(res, {
    title: 'Paiement',
    nonce,
    body: `<div class="card"><p>Paiement par <b>${esc(methodLabel)}</b></p>${summary(order)}
      <button class="primary" id="pay">Payer ${fcfaLong(order.total)}</button>
      <p class="muted" id="msg">Paiement sécurisé par KADEV PAY</p></div>
      <script src="https://pay.kadev.ci/js/v1/kadev-pay.js"></script>`,
    script: `
      var opts = ${JSON.stringify(opts).replace(/</g, '\\u003c')};
      var msg = document.getElementById('msg');
      function launch(){
        if (!window.KadevPay) { msg.textContent = 'Chargement du paiement…'; return setTimeout(launch, 500); }
        KadevPay.checkout(Object.assign({}, opts, {
          onSuccess: function(r){
            msg.textContent = 'Vérification du paiement…';
            fetch('/pay/${order.id}/confirm?t=${encodeURIComponent(req.query.t)}', {
              method: 'POST', headers: {'Content-Type':'application/json'},
              body: JSON.stringify({ reference: r && r.reference })
            }).then(function(){ location.href = ${JSON.stringify(returnUrl)} + '&reference=' + encodeURIComponent(r && r.reference || ''); });
          },
          onClose: function(){ msg.textContent = 'Paiement interrompu. Appuyez sur « Payer » pour réessayer.'; }
        }));
      }
      document.getElementById('pay').addEventListener('click', launch);
      launch();`,
  });
});

router.post('/pay/:id/simulate', express.urlencoded({ extended: false }), async (req, res) => {
  const order = findOrderForPayment(req.params.id, req.query.t);
  if (!order || providers.forOperator(order.payment_method).name !== 'simulation') {
    return res.status(404).type('text').send('Lien de paiement invalide.');
  }
  if (!providers.simulationAllowed()) return res.status(403).type('text').send('Mode test désactivé.');
  if (!['paid', 'refunded'].includes(order.payment_status) && order.status !== 'cancelled') {
    const p = browserAttempt(order, providers.registry.simulation);
    const result = req.body.result === 'paid' ? 'paid' : 'failed';
    db.prepare('UPDATE payments SET provider_state = ? WHERE id = ?').run(JSON.stringify({ ...parseJson(p.provider_state), result }), p.id);
    audit('payment_simulated', { userId: order.user_id, details: { orderId: order.id, paymentId: p.id, result, via: 'page' }, ip: req.ip });
    await core.refreshAttempt(core.getPayment(p.id));
  }
  resultPage(res, reloadOrder(order.id));
});

/** Rattache une référence KADEV à la tentative de la commande puis la vérifie auprès de l'API. */
async function confirmKadevReference(order, reference) {
  // Une référence KADEV ne paie qu'une seule commande.
  const elsewhere = db
    .prepare(`SELECT id, order_id FROM payments WHERE provider = 'kadev' AND provider_reference = ? AND order_id != ? LIMIT 1`)
    .get(reference, order.id);
  if (elsewhere) {
    raiseAlert('payment_reference_reuse', 'critical',
      `Référence KADEV ${reference} présentée pour la commande n°${order.id} alors qu'elle appartient à la commande n°${elsewhere.order_id}`,
      { key: `kadev-${reference}`, orderId: order.id, otherOrderId: elsewhere.order_id }, 60);
    audit('payment_reference_reuse', { details: { orderId: order.id, otherOrderId: elsewhere.order_id, reference } });
    const err = new Error('Référence de paiement déjà utilisée pour une autre commande');
    err.status = 409;
    throw err;
  }
  const existing = db.prepare('SELECT * FROM payments WHERE provider_reference = ? AND order_id = ?').get(reference, order.id);
  const p = existing || browserAttempt(order, kadev);
  if (!existing) db.prepare('UPDATE payments SET provider_reference = ?, reference = ? WHERE id = ?').run(reference, reference, p.id);
  return core.refreshAttempt(core.getPayment(p.id), { force: true });
}

router.post('/pay/:id/confirm', express.json(), async (req, res) => {
  const order = findOrderForPayment(req.params.id, req.query.t);
  if (!order || providers.forOperator(order.payment_method).name !== 'kadev') return res.status(404).json({ error: 'Introuvable' });
  const reference = String(req.body?.reference || '').slice(0, 100);
  if (!reference) return res.status(400).json({ error: 'Référence manquante' });
  try {
    const p = await confirmKadevReference(order, reference);
    res.json({ paid: p.status === 'paid' });
  } catch (err) {
    if (err.status === 409) return res.status(409).json({ error: err.message });
    log.error('vérification KADEV', { orderId: order.id, error: err.message });
    res.status(502).json({ error: 'Vérification impossible, réessayez' });
  }
});

router.get('/pay/:id/return', async (req, res) => {
  let order = findOrderForPayment(req.params.id, req.query.t);
  if (!order) return res.status(404).type('text').send('Lien de paiement invalide.');
  if (providers.forOperator(order.payment_method).name === 'kadev' && order.payment_status !== 'paid' && req.query.reference) {
    try {
      await confirmKadevReference(order, String(req.query.reference).slice(0, 100));
    } catch (err) {
      log.error('vérification KADEV (retour)', { orderId: order.id, error: err.message });
    }
    order = reloadOrder(order.id);
  }
  resultPage(res, order);
});

/**
 * Webhook KADEV PAY : signature HMAC-SHA512 vérifiée, puis revérification via l'API.
 * ⚠️ En-tête avec « _ » : si un proxy nginx est placé devant, activer `underscores_in_headers on;`.
 */
router.post('/api/payments/kadev/webhook', express.raw({ type: '*/*', limit: '100kb' }), async (req, res) => {
  const v = kadev.verifyWebhook(req);
  if (!v) {
    audit('webhook_invalid_signature', { ip: req.ip, details: { provider: 'kadev' } });
    raiseAlert('webhook_invalid', 'critical', `Webhook de paiement avec signature invalide (IP ${req.ip})`, { key: req.ip });
    return res.status(401).end();
  }
  res.status(200).json({ received: true }); // Répondre vite ; le traitement continue.
  if (v.ignored) return;
  const known = db.prepare('SELECT * FROM payments WHERE provider_reference = ? ORDER BY id DESC').get(v.providerReference);
  if (known && v.orderId != null && String(v.orderId) !== String(known.order_id)) {
    raiseAlert('payment_reference_mismatch', 'critical',
      `Webhook KADEV : référence ${v.providerReference} annoncée pour la commande n°${v.orderId}, connue pour la commande n°${known.order_id}`,
      { key: `kadev-${v.providerReference}`, orderId: known.order_id }, 60);
    return;
  }
  const orderId = known?.order_id ?? v.orderId;
  const order = orderId && reloadOrder(Number(orderId));
  if (!order) return log.warn('webhook KADEV sans commande associée', { reference: v.providerReference });
  try {
    await confirmKadevReference(order, v.providerReference);
  } catch (err) {
    log.error('webhook KADEV', { reference: v.providerReference, error: err.message });
  }
});

/**
 * Webhook PayGate Global : NON signé. On ne le croit jamais : il ne fait que
 * déclencher une revérification de la tentative via /api/v2/status.
 */
router.post(
  '/api/payments/paygate/webhook',
  express.json({ limit: '20kb' }),
  express.urlencoded({ extended: false, limit: '20kb' }),
  async (req, res) => {
    res.status(200).json({ received: true });
    const v = providers.registry.paygate.verifyWebhook(req);
    if (!v) return log.warn('webhook PayGate ignoré (identifiant absent ou invalide)', { ip: req.ip });
    const p = db.prepare('SELECT * FROM payments WHERE identifier = ?').get(v.identifier);
    if (!p || p.provider !== 'paygate') return log.warn('webhook PayGate : tentative inconnue', { identifier: v.identifier, ip: req.ip });
    audit('payment_webhook', { ip: req.ip, details: { provider: 'paygate', paymentId: p.id, orderId: p.order_id } });
    try {
      await core.refreshAttempt(p, { force: p.status !== 'paid' });
    } catch (err) {
      log.error('webhook PayGate', { paymentId: p.id, error: err.message });
    }
  },
);

module.exports = { router, newToken };
