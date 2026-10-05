import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

String formatPrice(int amount) {
  final digits = amount.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(' ');
    buf.write(digits[i]);
  }
  return '${amount < 0 ? '-' : ''}$buf FCFA';
}

/// Quantité maximale d'un même article dans le panier (même valeur que le serveur).
const maxQuantityPerItem = 999;

/// Lit une quantité saisie au clavier : renvoie null si vide, non numérique ou hors [min]..[max].
int? parseQuantity(String text, {int min = 1, int max = maxQuantityPerItem}) {
  final v = int.tryParse(text.trim());
  if (v == null || v < min || v > max) return null;
  return v;
}

String _two(int n) => n.toString().padLeft(2, '0');

String formatDateTime(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year} à ${_two(d.hour)}h${_two(d.minute)}';

String formatTime(DateTime d) => '${_two(d.hour)}h${_two(d.minute)}';

String timeAgo(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return "à l'instant";
  if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'il y a ${diff.inHours} h';
  return formatDateTime(d);
}

/// Moyens de paiement proposés au Togo.
const paymentMethods = <String, String>{
  'cash': 'Espèces à la livraison',
  'flooz': 'Flooz (Moov Africa)',
  'mixx': 'Mixx by Yas',
};

/// Moyens payés en ligne par mobile money (frais de paiement à la charge du client).
bool isMobileMoney(String method) => method == 'flooz' || method == 'mixx';

// Frais de paiement mobile money : même formule que le serveur (backend/src/payments/fees.js).
// L'agrégateur prélève p % du montant brut payé : pour que le restaurant reçoive [base]
// (sous-total + livraison), le client paie brut = ceil(base / (1 − p/100)).
// Calcul en entiers, taux en centièmes de % (3,5 % → 350).
int _basisPoints(num percent) {
  if (!percent.isFinite || percent <= 0) return 0;
  final bp = (percent * 100).round();
  return bp > 9999 ? 9999 : bp;
}

/// Montant brut à payer pour que le restaurant reçoive [base] après [percent] % de commission.
int paymentGrossFor(int base, num percent) {
  final bp = _basisPoints(percent);
  if (base <= 0 || bp == 0) return base < 0 ? 0 : base;
  final d = 10000 - bp;
  return (base * 10000 + d - 1) ~/ d;
}

/// Frais de paiement facturés au client pour [base] = sous-total + livraison (0 hors mobile money).
int paymentFeeFor(int base, String method, num percent) =>
    isMobileMoney(method) ? paymentGrossFor(base, percent) - (base < 0 ? 0 : base) : 0;

/// Commission de l'agrégateur sur un montant brut (arrondie à l'unité supérieure, comme le serveur).
int providerFeeOn(int gross, num percent) {
  final bp = _basisPoints(percent);
  if (gross <= 0 || bp == 0) return 0;
  return (gross * bp + 9999) ~/ 10000;
}

/// « 2 » plutôt que « 2.0 », « 2,5 » pour les pourcentages décimaux.
String formatPercent(num p) {
  if (p == p.roundToDouble()) return '${p.round()}';
  // Au plus 2 décimales, sans zéros inutiles (3,5 et non 3,50).
  var s = p.toStringAsFixed(2);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  return s.replaceAll('.', ',');
}

// Libellés des anciens moyens de paiement, pour l'historique des commandes.
const _legacyPaymentLabels = <String, String>{
  'tmoney': 'T-Money',
  'orange_money': 'Orange Money',
  'mtn_momo': 'MTN Mobile Money',
  'moov_money': 'Moov Money',
  'wave': 'Wave',
};

/// Libellé lisible du statut de paiement d'une commande.
String paymentStatusLabel(String status) {
  switch (status) {
    case 'unpaid':
      return 'À régler à la remise';
    case 'pending':
      return 'En attente de paiement';
    case 'paid':
      return 'Payée';
    case 'failed':
    case 'expired':
      return 'Paiement non abouti';
    case 'refunded':
      return 'Remboursé';
  }
  return status;
}

/// Compte à rebours « m:ss » (jamais négatif).
String formatCountdown(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds;
  return '${s ~/ 60}:${_two(s % 60)}';
}

/// Mode de retrait lisible : « Livraison · Tokoin », « À emporter »,
/// « Comptoir · Sur place » / « Comptoir · À emporter » (vente saisie à la caisse).
String orderModeLabel(Order o) {
  if (o.isCounter) return o.dineIn ? 'Comptoir · Sur place' : 'Comptoir · À emporter';
  if (o.isDelivery) {
    final zone = (o.deliveryZoneName ?? '').trim();
    return zone.isEmpty ? 'Livraison' : 'Livraison · $zone';
  }
  return 'À emporter';
}

/// Icône du mode de retrait (caisse pour une vente au comptoir).
IconData orderModeIcon(Order o) => o.isCounter
    ? Icons.point_of_sale_rounded
    : o.isDelivery
        ? Icons.delivery_dining_rounded
        : Icons.storefront_rounded;

/// Ligne « Livraison » d'un récapitulatif : « Livraison (Tokoin) », « Livraison (3,4 km) » ou « Livraison ».
String orderDeliveryLineLabel(Order o) {
  final zone = (o.deliveryZoneName ?? '').trim();
  if (zone.isNotEmpty) return 'Livraison ($zone)';
  final km = o.deliveryDistanceKm;
  return km == null ? 'Livraison' : 'Livraison (${km.toStringAsFixed(1).replaceAll('.', ',')} km)';
}

String paymentLabel(String method) => paymentMethods[method] ?? _legacyPaymentLabels[method] ?? method;

IconData paymentIcon(String method) =>
    method == 'cash' ? Icons.payments_outlined : Icons.phone_android_rounded;

String statusLabel(String status, {bool delivery = true}) {
  switch (status) {
    case 'pending':
      return 'En attente';
    case 'confirmed':
      return 'Confirmée';
    case 'preparing':
      return 'En préparation';
    case 'ready':
      return delivery ? 'Prête' : 'Prête à récupérer';
    case 'delivering':
      return 'En livraison';
    case driverDeliveredStep:
      return 'Livrée par le livreur';
    case 'delivered':
      return delivery ? 'Livrée' : 'Récupérée';
    case 'cancelled':
      return 'Annulée';
  }
  return status;
}

Color statusColor(String status) {
  switch (status) {
    case 'pending':
      return Colors.orange.shade700;
    case 'confirmed':
      return Colors.blue.shade600;
    case 'preparing':
      return Colors.deepPurple.shade400;
    case 'ready':
      return Colors.teal.shade600;
    case 'delivering':
      return Colors.indigo.shade500;
    case driverDeliveredStep:
      return Colors.teal.shade700;
    case 'delivered':
      return AppColors.green;
    case 'cancelled':
      return Colors.grey.shade600;
  }
  return Colors.grey;
}

IconData statusIcon(String status) {
  switch (status) {
    case 'pending':
      return Icons.hourglass_top_rounded;
    case 'confirmed':
      return Icons.thumb_up_alt_rounded;
    case 'preparing':
      return Icons.soup_kitchen_rounded;
    case 'ready':
      return Icons.shopping_bag_rounded;
    case 'delivering':
      return Icons.delivery_dining_rounded;
    case driverDeliveredStep:
      return Icons.where_to_vote_rounded;
    case 'delivered':
      return Icons.check_circle_rounded;
    case 'cancelled':
      return Icons.cancel_rounded;
  }
  return Icons.circle;
}

/// Étapes affichées dans le suivi selon le mode de retrait.
List<String> statusSteps(bool delivery) => delivery
    ? ['pending', 'confirmed', 'preparing', 'ready', 'delivering', 'delivered']
    : ['pending', 'confirmed', 'preparing', 'ready', 'delivered'];

/// Prochaine étape proposée à l'administrateur.
String? nextStatus(String status, bool delivery) {
  final steps = statusSteps(delivery);
  final i = steps.indexOf(status);
  if (i < 0 || i == steps.length - 1) return null;
  return steps[i + 1];
}

/// Étape d'affichage (pas un statut serveur) : le livreur a indiqué « Livraison faite »,
/// la commande reste 'delivering' en attendant le « Reçu » du client.
const driverDeliveredStep = 'driver_delivered';

/// Étapes de la frise de suivi : en livraison, « Livrée par le livreur » puis « Reçue ».
List<String> trackingSteps(bool delivery) => delivery
    ? ['pending', 'confirmed', 'preparing', 'ready', 'delivering', driverDeliveredStep, 'delivered']
    : statusSteps(false);

/// Position de la commande dans [trackingSteps] (-1 si annulée ou inconnue).
int trackingIndex(String status, bool delivery, {bool driverDelivered = false}) {
  final steps = trackingSteps(delivery);
  if (delivery && status == 'delivering' && driverDelivered) return steps.indexOf(driverDeliveredStep);
  return steps.indexOf(status);
}

/// Libellé d'une étape de la frise (« Reçue » pour la fin d'une livraison).
String trackingLabel(String step, bool delivery) =>
    delivery && step == 'delivered' ? 'Reçue' : statusLabel(step, delivery: delivery);

/// Prochaine étape proposée par le bouton principal de l'admin. En livraison, « Livrée »
/// n'est proposée qu'après « Livraison faite » du livreur (sinon : action « forcer » à part).
String? adminNextStatus(String status, bool delivery, {bool driverDelivered = false}) {
  final next = nextStatus(status, delivery);
  if (delivery && next == 'delivered' && !driverDelivered) return null;
  return next;
}

const categoryIcons = <String, String>{
  'chicken': '🍗',
  'burger': '🍔',
  'grill': '🥩',
  'fries': '🍟',
  'drink': '🥤',
  'dessert': '🍰',
  'pack': '🍱',
  'pizza': '🍕',
  'salad': '🥗',
  'rice': '🍛',
  'fish': '🐟',
  'soup': '🍲',
  'daily': '📅',
  'star': '✨',
  'african': '🌍',
  'pasta': '🍝',
  'juice': '🧃',
  'cocktail': '🍹',
  'beer': '🍺',
  'wine': '🍾',
  'chicha': '💨',
  'breakfast': '🥐',
};

/// Jours de la semaine (lundi = 1), pour le « Menu du jour » : plats nommés « Lundi · … ».
const dayNames = ['Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'];

/// Jour du menu du jour d'un plat (1 = lundi … 7 = dimanche), ou null si ce n'est pas un menu du jour.
int? dailyMenuWeekday(String productName) {
  final i = productName.indexOf(' · ');
  if (i <= 0) return null;
  final day = productName.substring(0, i).trim().toLowerCase();
  final index = dayNames.indexWhere((d) => d.toLowerCase() == day);
  return index < 0 ? null : index + 1;
}

String categoryEmoji(String? icon) => categoryIcons[icon] ?? '🍽️';
