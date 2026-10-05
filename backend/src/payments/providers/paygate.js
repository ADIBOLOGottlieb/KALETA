/**
 * PayGate Global (Togo) — paiement Flooz / Mixx by Yas (ex-T-Money) par push USSD.
 * Le client reçoit une demande sur son téléphone et valide avec SON code PIN :
 * le code PIN n'est jamais demandé ni transmis par notre API.
 *
 * - Lancement : POST https://paygateglobal.com/api/v1/pay
 *     { auth_token, phone_number, amount, description, identifier, network: FLOOZ|TMONEY }
 *     → { tx_reference, status } (0 = enregistrée, 2 = jeton invalide, 4 = paramètres invalides, 6 = doublon)
 * - Statut : POST https://paygateglobal.com/api/v2/status { auth_token, identifier }
 *     → { tx_reference, payment_reference, status, amount?, ... } (0 payé, 2 en cours, 4 expiré, 6 annulé)
 * - Webhook (callback) : NON signé par PayGate → on ne le croit jamais, il déclenche
 *   seulement une revérification via /api/v2/status.
 *
 * L'argent arrive sur le compte marchand PayGate, puis est reversé vers les numéros
 * Flooz / Mixx marchands du restaurant selon le reversement configuré chez PayGate.
 */
const BASE = process.env.PAYGATE_BASE_URL || 'https://paygateglobal.com';
const TOKEN = process.env.PAYGATE_AUTH_TOKEN || '';
const NETWORKS = { flooz: 'FLOOZ', mixx: 'TMONEY' };

const INIT_ERRORS = {
  2: 'Jeton PayGate invalide : vérifiez PAYGATE_AUTH_TOKEN sur le serveur.',
  4: 'Paiement refusé par PayGate : numéro ou montant invalide.',
  6: 'Demande en double refusée par PayGate : réessayez dans un instant.',
};

async function post(path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ auth_token: TOKEN, ...body }),
    signal: AbortSignal.timeout(20000),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`PayGate HTTP ${res.status}`);
  return data;
}

module.exports = {
  name: 'paygate',
  simulated: false,
  expirySeconds: Number(process.env.PAYMENT_EXPIRY_SECONDS) || 120,
  isConfigured: () => !!TOKEN,

  async initiate({ payment, order, phone, operator, amount }) {
    const network = NETWORKS[operator];
    if (!network) return { status: 'failed', message: 'Opérateur non pris en charge par PayGate.' };
    const data = await post('/api/v1/pay', {
      phone_number: phone,
      amount,
      description: `Commande n°${order.id} - ${process.env.MERCHANT_DISPLAY_NAME || 'KALETA'}`.slice(0, 120),
      identifier: payment.identifier,
      network,
    });
    const code = Number(data.status);
    if (code !== 0) return { status: 'failed', message: INIT_ERRORS[code] || `PayGate a refusé la demande (code ${data.status}).`, raw: data };
    return { providerReference: data.tx_reference ? String(data.tx_reference) : null, status: 'pending', raw: data };
  },

  async checkStatus(payment) {
    const data = await post('/api/v2/status', { identifier: payment.identifier });
    const code = Number(data.status);
    const amount = Number(data.amount);
    const base = {
      raw: data,
      providerReference: data.tx_reference ? String(data.tx_reference) : undefined,
      operatorReference: data.payment_reference ? String(data.payment_reference) : undefined,
    };
    if (code === 0) return { ...base, status: 'paid', amount: Number.isFinite(amount) && amount > 0 ? amount : undefined };
    if (code === 2) return { ...base, status: 'pending' };
    if (code === 4) return { ...base, status: 'expired', message: 'Délai dépassé : le paiement n\'a pas été validé sur le téléphone.' };
    if (code === 6) return { ...base, status: 'failed', message: 'Paiement annulé sur le téléphone.' };
    return { ...base, status: 'pending' };
  },

  /** Le webhook n'est PAS signé : on n'en extrait que l'identifiant à revérifier. */
  verifyWebhook(req) {
    const b = req.body && typeof req.body === 'object' ? req.body : {};
    const identifier = typeof b.identifier === 'string' ? b.identifier.trim() : '';
    return /^IVR-\d+-\d+-[0-9a-f]+$/.test(identifier) ? { identifier } : null;
  },
};
