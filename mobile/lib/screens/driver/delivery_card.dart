import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../models.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../../widgets/route_map.dart' show CustomerLivePin;
import 'driver_actions.dart';
import 'driver_order_detail_screen.dart';

/// Carte d'une livraison. Appui : Google Maps en navigation vers le client ;
/// appui long ou « Détails » : écran détail.
class DeliveryCard extends StatefulWidget {
  final Order order;
  final LatLng? restaurant;

  /// Appelé après une prise en charge réussie (ex : aller à l'onglet « Mes livraisons »).
  final ValueChanged<Order>? onTaken;

  const DeliveryCard({super.key, required this.order, this.restaurant, this.onTaken});

  @override
  State<DeliveryCard> createState() => _DeliveryCardState();
}

class _DeliveryCardState extends State<DeliveryCard> {
  bool _busy = false;

  Order get o => widget.order;

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openDetail() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DriverOrderDetailScreen(order: o, onTaken: widget.onTaken),
    ));
  }

  Future<void> _take() => _guard(() async {
        final updated = await takeDelivery(context, o);
        if (updated != null) widget.onTaken?.call(updated);
      });

  Future<void> _done() => _guard(() async {
        await markDeliveryDone(context, o);
      });

  Future<void> _release() => _guard(() async {
        await releaseDelivery(context, o);
      });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final me = currentUserId(context);
    final finished = o.status == 'delivered' || o.isCancelled;
    final distance = distanceFromRestaurant(o, widget.restaurant);
    final address = (o.address ?? '').trim();
    final time = finished
        ? (o.receivedAt ?? o.driverDeliveredAt ?? o.updatedAt)
        : (o.pickedUpAt ?? o.createdAt);

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Historique : l'appui ouvre le détail ; sinon, Google Maps directement.
        onTap: finished ? _openDetail : () => openClientNavigation(context, o),
        onLongPress: _openDetail,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('N° ${o.id}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  const SizedBox(width: 10),
                  Flexible(child: StatusChip(status: o.status)),
                  const Spacer(),
                  Icon(Icons.schedule_rounded, size: 16, color: cs.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    finished ? formatDateTime(time) : formatTime(time),
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.person_rounded, size: 22, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      o.customerName.isEmpty ? 'Client' : o.customerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Téléphone du client : bien visible.
              Row(
                children: [
                  Icon(Icons.phone_rounded, size: 22, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      o.phone.isEmpty ? 'Pas de numéro' : formatPhoneDisplay(o.phone),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(o.hasLocation ? Icons.location_on_rounded : Icons.location_off_outlined,
                      size: 22, color: o.hasLocation ? brandColor(context) : cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          address.isEmpty ? 'Adresse non précisée' : address,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, color: cs.onSurface),
                        ),
                        Text(
                          [
                            if (distance != null) 'À $distance du restaurant (vol d\'oiseau)',
                            if (!o.hasLocation) 'Pas de position GPS',
                          ].join(' • '),
                          style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                        ),
                        // Le client partage sa position en direct : « Itinéraire » mène là où il est.
                        if (o.customerLocation != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(4, 3, 10, 3),
                              decoration: BoxDecoration(
                                color: AppColors.green.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: AppColors.green.withValues(alpha: 0.5)),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(width: 22, height: 22, child: CustomerLivePin()),
                                  SizedBox(width: 6),
                                  Text(
                                    'Client en direct',
                                    style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              PaymentBanner(order: o),
              if (o.awaitingReceipt) ...[
                const SizedBox(height: 8),
                const AwaitingReceiptBadge(),
              ],
              if (!finished) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
                        onPressed: () => callClient(context, o),
                        icon: const Icon(Icons.call_rounded),
                        label: const Text('Appeler'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                        onPressed: () => openClientNavigation(context, o),
                        icon: const Icon(Icons.navigation_rounded),
                        label: const Text('Itinéraire'),
                      ),
                    ),
                  ],
                ),
              ],
              if (canTake(o)) ...[
                const SizedBox(height: 10),
                _MainButton(
                  busy: _busy,
                  icon: Icons.delivery_dining_rounded,
                  label: 'Je prends cette livraison',
                  color: brandColor(context),
                  onPressed: _take,
                ),
              ] else if (canMarkDelivered(o, me)) ...[
                const SizedBox(height: 10),
                _MainButton(
                  busy: _busy,
                  icon: Icons.check_circle_rounded,
                  label: 'Livraison faite',
                  color: AppColors.green,
                  onPressed: _done,
                ),
              ],
              Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: _openDetail,
                    icon: const Icon(Icons.receipt_long_rounded),
                    label: Text('Détails (${o.itemCount} article${o.itemCount > 1 ? 's' : ''})'),
                  ),
                  const Spacer(),
                  if (canRelease(o, me))
                    PopupMenuButton<String>(
                      tooltip: 'Plus d\'actions',
                      enabled: !_busy,
                      icon: const Icon(Icons.more_vert_rounded),
                      onSelected: (v) {
                        if (v == 'release') _release();
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
            ],
          ),
        ),
      ),
    );
  }
}

class _MainButton extends StatelessWidget {
  final bool busy;
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  const _MainButton({
    required this.busy,
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(58),
        backgroundColor: color,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
      ),
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
          : Icon(icon, size: 26),
      label: Text(label),
    );
  }
}

/// Montant et mode de paiement : « À encaisser » (espèces) ou « Déjà payé ».
class PaymentBanner extends StatelessWidget {
  final Order order;
  const PaymentBanner({super.key, required this.order});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final o = order;
    final Color color;
    final IconData icon;
    final String title;
    final String subtitle;
    if (o.isPaid) {
      color = AppColors.green;
      icon = Icons.verified_rounded;
      title = 'Déjà payé ✅';
      subtitle = '${formatPrice(o.total)} • ${paymentLabel(o.paymentMethod)} • rien à encaisser';
    } else if (isCashOrder(o)) {
      color = dark ? AppColors.accent : const Color(0xFF9A6A00);
      icon = Icons.payments_rounded;
      title = 'À encaisser : ${formatPrice(o.total)}';
      subtitle = 'Espèces à la livraison';
    } else {
      color = AppColors.danger;
      icon = Icons.warning_amber_rounded;
      title = 'Paiement non reçu';
      subtitle = '${formatPrice(o.total)} • ${paymentLabel(o.paymentMethod)} • ${paymentStatusLabel(o.paymentStatus)}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color)),
                Text(subtitle, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Le livreur a indiqué « Livraison faite » : on attend la confirmation du client.
class AwaitingReceiptBadge extends StatelessWidget {
  const AwaitingReceiptBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Colors.indigo.shade400;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.hourglass_top_rounded, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'En attente du Reçu client',
              style: TextStyle(fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
