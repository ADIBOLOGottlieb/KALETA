/**
 * Routes JSON des paiements (client + administration). Montées APRÈS express.json().
 * Toute action d'argent côté admin est auditée avec l'agent (req.user.id) ; réservée au gérant (requireManager).
 */
const express = require('express');
const { rateLimit } = require('express-rate-limit');
const { requireAuth, requireManager } = require('../auth');
const { audit } = require('../monitor');
const providers = require('./providers');
const core = require('./core');
const fees = require('./fees');
const tasks = require('./tasks');
const { h, maskPhone, csvCell } = require('./util');

const DISPLAY_NAME = process.env.MERCHANT_DISPLAY_NAME || 'KALETA';

function settlementText(name) {
  switch (name) {
    case 'paygate':
      return 'Les paiements Flooz et Mixx sont encaissés sur votre compte marchand PayGate Global, puis reversés '
        + 'vers vos numéros marchands selon le reversement configuré dans le tableau de bord PayGate '
        + '(automatique quotidien ou à seuil). Délai de reversement : à confirmer avec PayGate.';
    case 'kadev':
      return 'Les paiements sont encaissés par KADEV PAY puis reversés selon votre contrat KADEV PAY.';
    case 'direct':
      return 'Les paiements arrivent directement sur vos comptes marchands Flooz et Mixx.';
    default:
      return 'Mode test : aucun argent réel n\'est encaissé ni reversé.';
  }
}

/**
 * @param {{ presentOrder: Function, loadOrder: Function }} deps fonctions de server.js
 */
function createApiRouter({ presentOrder, loadOrder }) {
  const router = express.Router();
  const orderJson = (id, viewer) => presentOrder(loadOrder(Number(id)), viewer);
  const pair = (result, viewer) => ({ order: orderJson(result.order.id, viewer), payment: core.presentPayment(result.payment) });

  const pushLimiter = rateLimit({
    windowMs: 10 * 60 * 1000,
    limit: 10,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    // Personnel (caisse) : limite par commande, un caissier lance beaucoup de paiements dans la journée.
    keyGenerator: (req) => (req.user.role === 'admin' ? `pay-staff-${req.user.id}-order-${req.params.id}` : `pay-user-${req.user.id}`),
    message: { error: 'Trop de demandes de paiement. Patientez quelques minutes.' },
  });

  // ---------- Client ----------

  router.post('/api/orders/:id/payments', requireAuth, pushLimiter, h(async (req, res) => {
    const result = await core.createAttempt(Number(req.params.id), { phone: req.body?.phone, user: req.user, ip: req.ip });
    res.status(201).json(pair(result, req.user));
  }));

  router.get('/api/orders/:id/payments/current', requireAuth, h(async (req, res) => {
    const result = await core.getCurrent(Number(req.params.id), req.user);
    res.json({ order: orderJson(result.order.id, req.user), payment: core.presentPayment(result.payment) });
  }));

  router.post('/api/orders/:id/payments/current/abandon', requireAuth, h(async (req, res) => {
    const result = await core.abandonCurrent(Number(req.params.id), { user: req.user, ip: req.ip });
    res.json(pair(result, req.user));
  }));

  router.post('/api/orders/:id/payments/current/simulate', requireAuth, h(async (req, res) => {
    const result = await core.simulateCurrent(Number(req.params.id), {
      user: req.user, result: req.body?.result, amount: req.body?.amount, ip: req.ip,
    });
    res.json(pair(result, req.user));
  }));

  // ---------- Admin ----------

  router.get('/api/admin/payments/review', requireManager, h((_req, res) => {
    res.json(core.reviewQueue());
  }));

  router.post('/api/admin/payments/:id/validate', requireManager, h((req, res) => {
    const result = core.validateManual(Number(req.params.id), {
      reference: req.body?.reference, amount: req.body?.amount, agentId: req.user.id, ip: req.ip,
    });
    res.json(pair(result, req.user));
  }));

  router.post('/api/admin/payments/:id/reject', requireManager, h((req, res) => {
    const result = core.rejectPayment(Number(req.params.id), { reason: req.body?.reason, agentId: req.user.id, ip: req.ip });
    res.json(pair(result, req.user));
  }));

  router.get('/api/admin/payments/merchant', requireManager, h((_req, res) => {
    const name = providers.mainName();
    const fee = fees.feeInfo();
    res.json({
      provider: name,
      providers: providers.byOperator(),
      display_name: DISPLAY_NAME,
      flooz: maskPhone(process.env.MERCHANT_FLOOZ_NUMBER),
      mixx: maskPhone(process.env.MERCHANT_MIXX_NUMBER),
      // Commission appliquée (Flooz, pour compatibilité) et détail par opérateur (fees.js).
      provider_fee_percent: fee.by_operator.flooz,
      provider_fee_percent_by_operator: fee.by_operator,
      provider_fee_source: fee.source,
      settlement: settlementText(name),
    });
  }));

  router.get('/api/admin/payments/recent', requireManager, h((req, res) => {
    res.json(core.recentPaid(req.query.since_id));
  }));

  // Rapprochement à la demande (le même tourne chaque jour automatiquement).
  router.post('/api/admin/payments/reconcile', requireManager, h(async (req, res) => {
    res.json(await tasks.reconcile({ agentId: req.user.id, ip: req.ip }));
  }));

  router.get('/api/admin/collections', requireManager, h((req, res) => {
    res.json(core.collections(req.query));
  }));

  router.get('/api/admin/collections/export.csv', requireManager, h((req, res) => {
    const { payments, totals } = core.collections(req.query);
    const header = ['Paiement', 'Commande', 'Date paiement (UTC)', 'Opérateur', 'Prestataire', 'Client', 'Brut (FCFA)',
      'Frais (FCFA)', 'Net (FCFA)', 'Référence opérateur', 'Reversement', 'Référence virement', 'Date reversement', 'Remboursement'];
    const lines = [header.map(csvCell).join(';')];
    for (const p of payments) {
      lines.push([
        p.id, p.order_id, p.paid_at, p.operator, p.provider, p.customer_name, p.gross, p.provider_fee, p.net,
        p.operator_reference, p.settlement_status === 'reverse' ? 'reversé' : 'en attente', p.settlement_reference,
        p.settled_at, p.refund_status === 'refunded' ? `remboursé (${p.refund_reference})` : '',
      ].map(csvCell).join(';'));
    }
    lines.push(['TOTAL', '', '', '', '', '', totals.gross, totals.fees, totals.net, '', `reversé : ${totals.settled}`, '', '', '']
      .map(csvCell).join(';'));
    audit('collections_exported', { userId: req.user.id, details: { filters: req.query, count: payments.length, gross: totals.gross }, ip: req.ip });
    const suffix = [req.query.from, req.query.to].filter(Boolean).join('_') || 'tout';
    res.set('Content-Type', 'text/csv; charset=utf-8');
    res.set('Content-Disposition', `attachment; filename="encaissements_${suffix.replace(/[^\w-]/g, '')}.csv"`);
    res.send(`﻿${lines.join('\r\n')}\r\n`);
  }));

  router.post('/api/admin/settlements', requireManager, h((req, res) => {
    res.json(core.recordSettlement({
      paymentIds: req.body?.payment_ids, reference: req.body?.reference, agentId: req.user.id, ip: req.ip,
    }));
  }));

  router.post('/api/admin/orders/:id/refund', requireManager, h(async (req, res) => {
    const order = await core.refundOrder(Number(req.params.id), { reference: req.body?.reference, agentId: req.user.id, ip: req.ip });
    res.json(orderJson(order.id, req.user));
  }));

  return router;
}

module.exports = { createApiRouter, settlementText };
