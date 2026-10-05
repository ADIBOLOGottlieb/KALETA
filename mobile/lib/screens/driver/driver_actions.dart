import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../services/api.dart';
import '../../services/driver_api.dart';
import '../../services/driver_tracker.dart';
import '../../services/order_events.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';

/// Numéro composable pour tel: (garde le « + » initial).
String driverDialNumber(String phone) {
  final t = phone.trim();
  final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
  return t.startsWith('+') ? '+$digits' : digits;
}

/// Numéro lisible : « 90 12 34 56 » pour un numéro togolais à 8 chiffres.
String formatPhoneDisplay(String phone) {
  final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
  String pairs(String d) =>
      [for (var i = 0; i < d.length; i += 2) d.substring(i, i + 2 > d.length ? d.length : i + 2)].join(' ');
  if (digits.length == 8) return pairs(digits);
  if (digits.length == 11 && digits.startsWith('228')) return '+228 ${pairs(digits.substring(3))}';
  return phone.trim();
}

/// Distance à vol d'oiseau restaurant → client (« 2,4 km »), null si une position manque.
String? distanceFromRestaurant(Order o, LatLng? restaurant) {
  if (restaurant == null || !o.hasLocation) return null;
  final m = const Distance().as(LengthUnit.Meter, restaurant, LatLng(o.deliveryLat!, o.deliveryLng!));
  if (m < 1000) return '${(m / 10).round() * 10} m';
  return '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
}

/// Commande payée en espèces à la livraison : le livreur encaisse.
bool isCashOrder(Order o) => !isMobileMoney(o.paymentMethod) && !o.isPaid;

/// Ouvre Google Maps en navigation vers le client (guidage moto si l'application est là),
/// repli sur le lien https, puis sur une recherche par adresse si pas de position.
Future<void> openClientNavigation(BuildContext context, Order o) async {
  final uris = <Uri>[];
  // Client en direct : on va là où il est maintenant, pas au point choisi à la commande.
  final live = o.customerLocation;
  if (live != null || o.hasLocation) {
    final lat = live?.lat ?? o.deliveryLat!;
    final lng = live?.lng ?? o.deliveryLng!;
    final dest = '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
    uris
      ..add(Uri.parse('google.navigation:q=$dest&mode=l'))
      ..add(Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$dest&travelmode=driving'));
  } else {
    final address = (o.address ?? '').trim();
    if (address.isEmpty) {
      showMessage(context, 'Ce client n\'a indiqué ni position ni adresse : appelez-le.', error: true);
      return;
    }
    uris.add(Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}'));
  }
  for (final uri in uris) {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (!o.hasLocation && context.mounted) {
          showMessage(context, 'Pas de position GPS : recherche par adresse dans Google Maps.');
        }
        return;
      }
    } catch (_) {
      // On essaie le lien suivant.
    }
  }
  if (context.mounted) {
    showMessage(context, 'Impossible d\'ouvrir Google Maps. Installez Google Maps ou un navigateur.', error: true);
  }
}

/// Appelle le client (numéro de contact de la commande).
Future<void> callClient(BuildContext context, Order o) async {
  final number = driverDialNumber(o.phone);
  if (number.isEmpty) {
    showMessage(context, 'Pas de numéro de téléphone pour ce client.', error: true);
    return;
  }
  var ok = false;
  try {
    ok = await launchUrl(
      Uri(scheme: 'tel', path: number),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {}
  if (!ok && context.mounted) showMessage(context, 'Impossible de lancer l\'appel vers $number.', error: true);
}

/// Id du compte connecté (pour savoir si une livraison est la mienne).
/// (Provider.of sans écoute : utilisable dans build, contrairement à context.read.)
int? currentUserId(BuildContext context) => Provider.of<AuthProvider>(context, listen: false).user?.id;

/// Actions possibles sur une livraison, déduites de son état.
bool canTake(Order o) => o.status == 'ready' && o.isDelivery && !o.hasDriver;
bool canMarkDelivered(Order o, int? me) =>
    o.status == 'delivering' && o.driverDeliveredAt == null && (me == null || o.driverId == me);
bool canRelease(Order o, int? me) => canMarkDelivered(o, me);

String _errorText(Object e, {String? conflict}) {
  if (e is ApiException) {
    if (e.statusCode == 409 && conflict != null) return conflict;
    return e.message;
  }
  return 'Une erreur est survenue. Réessayez.';
}

/// Exécute une action livreur : message clair en cas d'erreur, rechargement des listes dans tous les cas.
Future<Order?> _run(
  BuildContext context,
  Future<Order> Function() action, {
  required String success,
  String? conflict,
}) async {
  try {
    final o = await action();
    if (context.mounted) showMessage(context, success);
    return o;
  } catch (e) {
    if (context.mounted) showMessage(context, _errorText(e, conflict: conflict), error: true);
    return null;
  } finally {
    notifyOrdersChanged();
  }
}

/// « Je prends cette livraison » : la position commence à être partagée avec le client.
Future<Order?> takeDelivery(BuildContext context, Order o) async {
  final taken = await _run(
    context,
    () => takeOrder(o.id),
    success: 'Livraison n°${o.id} prise en charge. Appuyez sur la carte pour lancer Google Maps.',
    conflict: 'Trop tard : cette livraison a déjà été prise par un autre livreur.',
  );
  if (taken != null) DriverTracker.instance.start();
  return taken;
}

/// « Livraison faite » (avec confirmation).
Future<Order?> markDeliveryDone(BuildContext context, Order o) async {
  final cash = isCashOrder(o) ? '\n\nVous devez avoir encaissé ${formatPrice(o.total)} en espèces.' : '';
  final ok = await confirmDialog(
    context,
    'Livraison faite ?',
    'Confirmez que la commande n°${o.id} a été remise à ${o.customerName.isEmpty ? 'le client' : o.customerName}.$cash'
        '\n\nLe client devra ensuite confirmer avec « Reçu ».',
    confirm: 'Oui, livrée',
  );
  if (!ok || !context.mounted) return null;
  final me = currentUserId(context);
  final updated = await _run(
    context,
    () => markDelivered(o.id),
    success: 'Livraison n°${o.id} marquée comme faite. En attente du « Reçu » du client.',
  );
  // Plus de livraison en cours : le partage de position s'arrête.
  if (updated != null) DriverTracker.instance.refresh(me);
  return updated;
}

/// « Rendre la livraison » (avec confirmation) : elle repart dans « À livrer ».
Future<Order?> releaseDelivery(BuildContext context, Order o) async {
  final ok = await confirmDialog(
    context,
    'Rendre la livraison ?',
    'La commande n°${o.id} repartira dans « À livrer » pour un autre livreur.',
    confirm: 'Rendre',
    danger: true,
  );
  if (!ok || !context.mounted) return null;
  final me = currentUserId(context);
  final updated = await _run(context, () => releaseOrder(o.id), success: 'Livraison n°${o.id} rendue.');
  if (updated != null) DriverTracker.instance.refresh(me);
  return updated;
}
