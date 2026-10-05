import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../services/driver_tracker.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../utils/polling.dart';
import '../../widgets/common.dart';
import '../../widgets/route_map.dart';
import 'delivery_card.dart';
import 'driver_actions.dart';

/// Détail d'une livraison côté livreur : client, articles, note, carte, actions.
class DriverOrderDetailScreen extends StatefulWidget {
  final Order order;
  final ValueChanged<Order>? onTaken;

  const DriverOrderDetailScreen({super.key, required this.order, this.onTaken});

  @override
  State<DriverOrderDetailScreen> createState() => _DriverOrderDetailScreenState();
}

class _DriverOrderDetailScreenState extends State<DriverOrderDetailScreen> {
  late Order _order = widget.order;
  LatLng? _restaurant;
  String _restaurantAddress = '';
  bool _busy = false;

  /// Livraison en cours : la commande est relue toutes les 8 s (position en direct du client).
  Timer? _refresh;
  static const _refreshEvery = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _refresh = Timer.periodic(_refreshEvery, (_) => _reload());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  /// Relit la commande pendant la livraison (position du client, annulation...), sans bloquer l'écran.
  Future<void> _reload() async {
    final o = _order;
    if (_busy || !canMarkDelivered(o, currentUserId(context)) || !isRouteOnTop(context)) return;
    try {
      final fresh = await Api.instance.order(o.id);
      if (mounted && !_busy) setState(() => _order = fresh);
    } catch (_) {
      // Réseau : on réessaiera au prochain tour.
    }
  }

  Future<void> _loadSettings() async {
    try {
      final s = await Api.instance.settings();
      if (!mounted) return;
      setState(() {
        if (s.restaurantLat != null && s.restaurantLng != null) {
          _restaurant = LatLng(s.restaurantLat!, s.restaurantLng!);
        }
        _restaurantAddress = s.restaurantAddress;
      });
    } catch (_) {
      // Pas de carte : le reste de l'écran fonctionne.
    }
  }

  Future<void> _act(Future<Order?> Function() action, {bool popAfter = false, bool taken = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final updated = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (updated != null) _order = updated;
    });
    if (updated == null) return;
    if (taken) widget.onTaken?.call(updated);
    if (popAfter) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final o = _order;
    final me = currentUserId(context);
    final finished = o.status == 'delivered' || o.isCancelled;
    final address = (o.address ?? '').trim();
    final distance = distanceFromRestaurant(o, _restaurant);
    final note = (o.note ?? '').trim();

    return Scaffold(
      appBar: AppBar(
        title: Text('Livraison n°${o.id}'),
        actions: [
          if (canRelease(o, me))
            PopupMenuButton<String>(
              tooltip: 'Plus d\'actions',
              enabled: !_busy,
              onSelected: (v) {
                if (v == 'release') _act(() => releaseDelivery(context, o), popAfter: true);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'release',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.undo_rounded, color: AppColors.danger),
                    title: Text('Rendre la livraison'),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Row(
            children: [
              StatusChip(status: o.status),
              const Spacer(),
              Text(
                'Commandée à ${formatTime(o.createdAt)}',
                style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Client : appui = Google Maps.
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => openClientNavigation(context, o),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      o.customerName.isEmpty ? 'Client' : o.customerName,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.phone_rounded, color: cs.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            o.phone.isEmpty ? 'Pas de numéro' : formatPhoneDisplay(o.phone),
                            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: cs.primary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          o.hasLocation ? Icons.location_on_rounded : Icons.location_off_outlined,
                          color: o.hasLocation ? brandColor(context) : cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            [
                              address.isEmpty ? 'Adresse non précisée' : address,
                              if (distance != null) 'À $distance du restaurant (vol d\'oiseau)',
                              if (!o.hasLocation) 'Pas de position GPS : recherche par adresse',
                            ].join('\n'),
                            style: TextStyle(fontSize: 15, color: cs.onSurface),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Appuyez ici pour ouvrir Google Maps',
                      style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 54)),
                  onPressed: () => callClient(context, o),
                  icon: const Icon(Icons.call_rounded),
                  label: const Text('Appeler'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 54)),
                  onPressed: () => openClientNavigation(context, o),
                  icon: const Icon(Icons.navigation_rounded),
                  label: const Text('Itinéraire'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          PaymentBanner(order: o),
          if (o.awaitingReceipt) ...[const SizedBox(height: 8), const AwaitingReceiptBadge()],
          if (canTake(o)) ...[
            const SizedBox(height: 12),
            _bigButton(
              icon: Icons.delivery_dining_rounded,
              label: 'Je prends cette livraison',
              color: brandColor(context),
              onPressed: () => _act(() => takeDelivery(context, o), taken: true),
            ),
          ] else if (canMarkDelivered(o, me)) ...[
            const SizedBox(height: 12),
            _bigButton(
              icon: Icons.check_circle_rounded,
              label: 'Livraison faite',
              color: AppColors.green,
              onPressed: () => _act(() => markDeliveryDone(context, o)),
            ),
          ],
          if (finished && o.receivedAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Reçu confirmé par le client le ${formatDateTime(o.receivedAt!)}',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ] else if (o.driverDeliveredAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Livraison faite le ${formatDateTime(o.driverDeliveredAt!)}',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
          if (note.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.sticky_note_2_rounded, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Note du client : $note',
                      style: TextStyle(fontSize: 15, color: cs.onSurface, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text('Articles (${o.itemCount})', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  for (final it in o.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${it.quantity} ×', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(it.name, style: const TextStyle(fontSize: 16)),
                                // Pack : contenu, pour vérifier le sac avant de partir.
                                if (it.details != null && it.details!.isNotEmpty)
                                  ItemDetailsText(it.details!, maxLines: null, fontSize: 13),
                              ],
                            ),
                          ),
                          Text(formatPrice(it.total), style: TextStyle(color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  const Divider(),
                  if (o.deliveryFee > 0) _line('Livraison', o.deliveryFee, cs),
                  if (o.paymentFee > 0) _line('Frais de paiement', o.paymentFee, cs),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('Total', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                        ),
                        Price(o.total, size: 18),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_restaurant != null && o.hasLocation) ...[
            const SizedBox(height: 16),
            const Text('Itinéraire', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (o.customerLocation != null) ...[
              CustomerLiveBanner(location: o.customerLocation!, until: o.liveShareUntil),
              const SizedBox(height: 10),
            ],
            // Livraison en cours : ma position (celle que voit le client) s'affiche sur la carte.
            ValueListenableBuilder<DriverLocation?>(
              valueListenable: DriverTracker.instance.position,
              builder: (context, mine, _) => RouteMap(
                from: _restaurant!,
                to: LatLng(o.deliveryLat!, o.deliveryLng!),
                customer: o.customerLocation,
                fromLabel: _restaurantAddress.isEmpty ? 'Restaurant' : 'Restaurant : $_restaurantAddress',
                toLabel: o.customerLocation != null
                    ? 'Client en direct (il partage sa position)'
                    : address.isEmpty
                        ? 'Client'
                        : 'Client : $address',
                driver: canMarkDelivered(o, me) ? (mine ?? o.driverLocation) : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _line(String label, int amount, ColorScheme cs) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: TextStyle(color: cs.onSurfaceVariant)),
        ),
        Text(formatPrice(amount), style: TextStyle(color: cs.onSurfaceVariant)),
      ],
    ),
  );

  Widget _bigButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(60),
        backgroundColor: color,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
      ),
      onPressed: _busy ? null : onPressed,
      icon: _busy
          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
          : Icon(icon, size: 28),
      label: Text(label),
    );
  }
}
