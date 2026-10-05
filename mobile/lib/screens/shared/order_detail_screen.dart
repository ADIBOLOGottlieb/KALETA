import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../models.dart';
import '../../services/api.dart';
import '../../services/delivery_api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../services/order_events.dart';
import '../../utils/polling.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../../widgets/route_map.dart';
import '../client/payment_screen.dart';

/// Détail et suivi d'une commande. En mode [admin], affiche les infos client
/// et les actions de changement de statut.
class OrderDetailScreen extends StatefulWidget {
  final int orderId;
  final Order? initial;
  final bool admin;

  /// Ouvre directement la page de paiement (juste après une commande Flooz / Mixx).
  final bool openPayment;

  const OrderDetailScreen({
    super.key,
    required this.orderId,
    this.initial,
    this.admin = false,
    this.openPayment = false,
  });

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  static const _liveInterval = Duration(seconds: 8);

  Order? _order;
  Object? _error;
  bool _busy = false;
  int _gen = 0; // incrémenté à chaque action : invalide les lectures en cours
  // Suivi adapté au statut ; suspendu en arrière-plan et sous un autre écran. Au retour dans
  // l'application (ex. après le paiement dans le navigateur), actualisation immédiate.
  late final SmartPoller _poller;
  // Position du restaurant (départ de l'itinéraire), si l'admin l'a renseignée.
  LatLng? _restaurant;
  // Sans position du restaurant : départ = première position connue du livreur (fixe, pas de recalcul à chaque point).
  LatLng? _trackOrigin;
  String? _restaurantAddress;

  @override
  void initState() {
    super.initState();
    _order = widget.initial;
    _loadRestaurant();

    _poller = SmartPoller(
      onPoll: _load,
      // En préparation / en livraison : 5 s ; en attente / confirmée : 10 s ; terminée : plus de suivi.
      // Livreur suivi en direct : 8 s (le marqueur glisse entre deux positions).
      getInterval: (status) => status == 'delivering' && (_order?.isTrackable ?? false)
          ? _liveInterval
          : SmartPoller.getDefaultInterval(status),
      canPoll: () => isRouteOnTop(context),
    );
    _poller.startPolling(_order?.status ?? 'pending');
    _load();
    if (widget.openPayment && !widget.admin) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pay());
    }
  }

  @override
  void dispose() {
    _poller.stop();
    super.dispose();
  }

  Future<void> _load() async {
    // Une lecture lancée avant une action (annulation, paiement...) ne doit pas écraser son résultat.
    final gen = _gen;
    try {
      final o = await Api.instance.order(widget.orderId);
      if (!mounted || gen != _gen) return;
      _setOrder(o);
      setState(() => _error = null);
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    }
  }

  Future<void> _loadRestaurant() async {
    try {
      final s = await Api.instance.settings();
      final lat = s.restaurantLat;
      final lng = s.restaurantLng;
      if (!mounted || lat == null || lng == null) return;
      setState(() {
        _restaurant = LatLng(lat, lng);
        _restaurantAddress = s.restaurantAddress.trim().isEmpty ? null : s.restaurantAddress.trim();
      });
    } catch (_) {
      // Réglages indisponibles : pas d'itinéraire.
    }
  }

  /// Affiche immédiatement la commande à jour et adapte le rythme du suivi.
  void _setOrder(Order o) {
    setState(() => _order = o);
    _poller.updateStatus(o.status);
  }

  Future<void> _run(Future<Order> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      final o = await action();
      if (!mounted) return;
      _gen++;
      _setOrder(o);
      notifyOrdersChanged();
      showMessage(context, success);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Paiement mobile money : demande envoyée sur le téléphone du client (code PIN),
  /// ou page KADEV PAY dans le navigateur si c'est le prestataire configuré.
  Future<void> _pay() async {
    final o = _order;
    if (o == null || _busy) return;
    setState(() => _busy = true);
    AppSettings? settings;
    try {
      settings = await Api.instance.settings();
    } catch (_) {
      // Réglages indisponibles : on utilise l'écran de paiement intégré.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (settings?.paymentProvider == 'kadev') {
      await _payInBrowser();
      return;
    }
    // L'écran de paiement suit lui-même la tentative : pas de suivi en double dessous.
    _poller.pause();
    final updated = await Navigator.push<Order>(
      context,
      MaterialPageRoute(builder: (_) => PaymentScreen(order: _order ?? o)),
    );
    if (!mounted) return;
    _poller.resume(pollNow: false);
    if (updated != null) {
      _gen++;
      _setOrder(updated);
    }
    notifyOrdersChanged();
    _load();
  }

  /// Ouvre la page de paiement sécurisée KADEV PAY dans le navigateur.
  Future<void> _payInBrowser() async {
    var o = _order;
    if (o == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (o.payUrl == null) {
        o = await Api.instance.renewPayment(o.id);
        if (!mounted) return;
        setState(() => _order = o);
      }
      final ok = await launchUrl(Uri.parse('$apiBaseUrl${o.payUrl}'), mode: LaunchMode.externalApplication);
      if (!ok && mounted) showMessage(context, "Impossible d'ouvrir la page de paiement", error: true);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final ok = await confirmDialog(
      context,
      'Annuler la commande ?',
      widget.admin ? 'Le client verra sa commande comme annulée.' : 'Cette action est définitive.',
      confirm: 'Annuler la commande',
      danger: true,
    );
    if (!ok) return;
    await _run(
      () => widget.admin
          ? Api.instance.setOrderStatus(widget.orderId, 'cancelled')
          : Api.instance.cancelOrder(widget.orderId),
      'Commande annulée',
    );
  }

  /// Client : « J'ai reçu ma commande » → commande complète ('delivered').
  Future<void> _confirmReceived() async {
    final ok = await confirmDialog(
      context,
      'Vous avez reçu votre commande ?',
      'Confirmez seulement si le livreur vous a bien remis votre commande.',
      confirm: "Oui, je l'ai reçue",
    );
    if (!ok || !mounted) return;
    await _run(() => confirmReceived(widget.orderId), 'Merci ! Commande reçue ✅');
  }

  /// Admin : choisit un livreur actif puis lui attribue la livraison.
  Future<void> _assign() async {
    final o = _order;
    if (o == null || _busy) return;
    final driver = await showModalBottomSheet<Driver>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _DriverPicker(currentId: o.driverId),
    );
    if (driver == null || !mounted) return;
    await _run(() => assignDriver(widget.orderId, driver.id), 'Livraison attribuée à ${driver.name}');
  }

  /// Admin : retire le livreur de la commande.
  Future<void> _unassign() async {
    final o = _order;
    if (o == null) return;
    final ok = await confirmDialog(
      context,
      'Retirer le livreur ?',
      '${o.driverName ?? 'Le livreur'} ne sera plus chargé de cette livraison.',
      confirm: 'Retirer',
      danger: true,
    );
    if (!ok || !mounted) return;
    await _run(() => assignDriver(widget.orderId, null), 'Livreur retiré');
  }

  /// Admin : passe la commande « Livrée » sans attendre le livreur ni le client.
  Future<void> _forceDelivered() async {
    final ok = await confirmDialog(
      context,
      'Marquer comme livrée ?',
      "Le livreur n'a pas encore indiqué « Livraison faite ». "
          'La commande sera terminée sans la confirmation du client.',
      confirm: 'Forcer',
      danger: true,
    );
    if (!ok || !mounted) return;
    await _run(() => Api.instance.setOrderStatus(widget.orderId, 'delivered'), 'Commande marquée comme livrée');
  }

  /// Admin : remboursement d'une commande payée puis annulée.
  Future<void> _refund() async {
    // Le champ appartient à la boîte de dialogue : libéré seulement à sa fermeture effective.
    final reference = await showDialog<String>(
      context: context,
      builder: (_) => _RefundDialog(total: _order?.total ?? 0),
    );
    if (reference == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final o = await Api.instance.refundOrder(widget.orderId, reference: reference);
      if (!mounted) return;
      _gen++;
      _setOrder(o);
      notifyOrdersChanged();
      showMessage(context, 'Remboursement enregistré');
    } catch (e) {
      if (!mounted) return;
      final needsRef = reference.isEmpty && e is ApiException && e.isClientError;
      showMessage(
        context,
        needsRef
            ? '$e\nIndiquez la référence du remboursement effectué (transfert mobile money).'
            : e,
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    final dl = o?.isTrackable == true ? o!.driverLocation : null;
    if (_restaurant == null && _trackOrigin == null && dl != null) _trackOrigin = LatLng(dl.lat, dl.lng);
    final restaurant = _restaurant ?? _trackOrigin;
    return Scaffold(
      appBar: AppBar(title: Text('Commande n°${widget.orderId}')),
      body: o == null
          ? (_error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : const Center(child: CircularProgressIndicator()))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  FadeSlideIn(child: _StatusHeader(order: o, admin: widget.admin)),
                  // Client : le livreur dit avoir livré → bouton « J'ai reçu ma commande ».
                  if (!widget.admin && !o.isCounter && o.awaitingReceipt) ...[
                    const SizedBox(height: 16),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 20),
                      child: _ReceiptPrompt(order: o, busy: _busy, onConfirm: _confirmReceived),
                    ),
                  ],
                  if (!widget.admin && o.isDelivery && o.status == 'delivered' && o.receivedAt != null) ...[
                    const SizedBox(height: 16),
                    _ReceivedBanner(receivedAt: o.receivedAt!),
                  ],
                  if (!widget.admin && o.isDelivery && o.hasDriver && !o.isFinished) ...[
                    const SizedBox(height: 16),
                    FadeSlideIn(delay: const Duration(milliseconds: 30), child: _DriverCard(order: o)),
                  ],
                  // Vente au comptoir : ni livreur, ni carte, ni « J'ai reçu ma commande ».
                  if (widget.admin && o.isDelivery && !o.isCounter && !o.isCancelled) ...[
                    const SizedBox(height: 16),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 30),
                      child: _AdminDriverSection(
                        order: o,
                        busy: _busy,
                        onAssign: _assign,
                        onRemove: _unassign,
                      ),
                    ),
                  ],
                  if (isMobileMoney(o.paymentMethod) && (!o.isCancelled || o.isPaid || o.isRefunded)) ...[
                    const SizedBox(height: 16),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 40),
                      child: _PaymentCard(
                        order: o,
                        admin: widget.admin,
                        busy: _busy,
                        onPay: _pay,
                        onCancel: _cancel,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (o.status != 'cancelled')
                    FadeSlideIn(delay: const Duration(milliseconds: 80), child: _Timeline(order: o)),
                  if (widget.admin) ...[
                    const SizedBox(height: 16),
                    FadeSlideIn(delay: const Duration(milliseconds: 140), child: _CustomerCard(order: o)),
                  ],
                  if (restaurant != null && o.isDelivery && !o.isCounter && o.hasLocation && !o.isCancelled) ...[
                    const SizedBox(height: 16),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 170),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(o.isTrackable ? 'Suivi en direct' : 'Itinéraire',
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                              const SizedBox(height: 12),
                              if (_liveTracking(o)) ...[
                                _LiveTrackingBanner(order: o),
                                const SizedBox(height: 12),
                              ],
                              RouteMap(
                                from: restaurant,
                                to: LatLng(o.deliveryLat!, o.deliveryLng!),
                                driver: o.isTrackable ? o.driverLocation : null,
                                fromLabel: _restaurant == null
                                    ? 'Départ du livreur'
                                    : _restaurantAddress != null
                                    ? 'Restaurant • $_restaurantAddress'
                                    : 'Restaurant',
                                toLabel: o.address ?? 'Point de livraison',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FadeSlideIn(delay: const Duration(milliseconds: 200), child: _ItemsCard(order: o)),
                  const SizedBox(height: 16),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 260),
                    child: Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: Icon(orderModeIcon(o), color: brandColor(context)),
                          title: Text(orderModeLabel(o)),
                          subtitle: o.isDelivery && o.address != null ? Text(o.address!) : null,
                        ),
                        ListTile(
                          leading: Icon(paymentIcon(o.paymentMethod), color: brandColor(context)),
                          title: Text(paymentLabel(o.paymentMethod)),
                        ),
                        if (o.note != null)
                          ListTile(
                            leading: Icon(Icons.sticky_note_2_rounded, color: brandColor(context)),
                            title: Text(o.note!),
                          ),
                      ],
                    ),
                  ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
      bottomNavigationBar: o == null ? null : _actions(o),
    );
  }

  Widget? _actions(Order o) {
    final buttons = <Widget>[];
    if (widget.admin) {
      // En livraison, « Livrée » n'est proposée qu'après « Livraison faite » du livreur.
      final next = adminNextStatus(o.status, o.isDelivery, driverDelivered: o.driverDeliveredAt != null);
      final awaitingPayment = isMobileMoney(o.paymentMethod) && !o.isPaid;
      if (next != null && o.status != 'cancelled' && !awaitingPayment) {
        final onBehalf = next == 'delivered' && o.awaitingReceipt;
        buttons.add(FilledButton.icon(
          onPressed: _busy
              ? null
              : () => _run(() => Api.instance.setOrderStatus(o.id, next),
                  onBehalf ? 'Réception confirmée' : 'Statut : ${statusLabel(next, delivery: o.isDelivery)}'),
          icon: Icon(statusIcon(next)),
          label: Text(onBehalf
              ? 'Confirmer la réception (pour le client)'
              : 'Passer à « ${statusLabel(next, delivery: o.isDelivery)} »'),
        ));
      }
      if (o.isDelivery && o.status == 'delivering' && o.driverDeliveredAt == null) {
        buttons.add(TextButton.icon(
          onPressed: _busy ? null : _forceDelivered,
          icon: const Icon(Icons.done_all_rounded),
          label: const Text('Marquer comme livrée (forcer)'),
        ));
      }
      if (!o.isFinished) {
        buttons.add(TextButton(
          onPressed: _busy ? null : _cancel,
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          child: const Text('Annuler la commande'),
        ));
      }
      if (o.isCancelled && o.isPaid) {
        buttons.add(FilledButton.icon(
          onPressed: _busy ? null : _refund,
          icon: const Icon(Icons.currency_exchange_rounded),
          label: Text('Rembourser ${formatPrice(o.total)}'),
        ));
      }
    } else if (o.status == 'pending' && !o.isPaid && !(isMobileMoney(o.paymentMethod) && o.paymentFailed)) {
      // (paiement non abouti : le bouton « Annuler la commande » est dans la carte de paiement)
      buttons.add(OutlinedButton(
        onPressed: _busy ? null : _cancel,
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
        child: const Text('Annuler ma commande'),
      ));
    }
    if (buttons.isEmpty) return null;
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: buttons),
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  final Order order;
  final bool admin;
  const _StatusHeader({required this.order, this.admin = false});

  /// Statut affiché : « Livrée par le livreur » tant que le client n'a pas confirmé.
  String get _step => order.awaitingReceipt ? driverDeliveredStep : order.status;

  String get _message {
    if (order.awaitingReceipt) {
      return admin
          ? 'Le livreur a indiqué « Livraison faite ». En attente du « Reçu » du client.'
          : 'Le livreur indique vous avoir livré. Confirmez la réception ci-dessous.';
    }
    if (order.isCounter) {
      switch (order.status) {
        case 'pending':
          return 'Vente au comptoir : en attente du paiement mobile money.';
        case 'ready':
          return order.dineIn ? 'Commande prête à servir en salle.' : 'Commande prête à remettre au client.';
        case 'delivered':
          return 'Commande remise au client.';
      }
    }
    switch (order.status) {
      case 'pending':
        return 'Le restaurant va bientôt confirmer votre commande.';
      case 'confirmed':
        return 'Votre commande est confirmée et va passer en cuisine.';
      case 'preparing':
        return 'En cuisine : nos chefs préparent votre commande au feu de bois 🔥';
      case 'ready':
        return order.isDelivery ? 'Votre commande attend le livreur.' : 'Votre commande vous attend au restaurant !';
      case 'delivering':
        if (admin) {
          return order.hasDriver ? '${order.driverName ?? 'Le livreur'} est en route 🛵' : 'En route vers le client 🛵';
        }
        return order.hasDriver
            ? '${order.driverName ?? 'Votre livreur'} est en route vers vous 🛵'
            : 'Le livreur est en route vers vous 🛵';
      case 'delivered':
        return 'Bon appétit ! Merci de votre confiance.';
      case 'cancelled':
        return 'Cette commande a été annulée.';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final step = _step;
    final color = statusColor(step);
    // Le bandeau change de couleur en douceur à chaque changement de statut.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOut,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: Colors.white.withValues(alpha: 0.2),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: (child, anim) => RotationTransition(
                turns: Tween(begin: 0.75, end: 1.0).animate(anim),
                child: ScaleTransition(scale: anim, child: child),
              ),
              child: Icon(statusIcon(step), key: ValueKey(step), color: Colors.white, size: 30),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
              child: Column(
              key: ValueKey(step),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusLabel(step, delivery: order.isDelivery),
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(_message, style: const TextStyle(color: Colors.white, height: 1.3)),
                const SizedBox(height: 6),
                Text('Passée le ${formatDateTime(order.createdAt)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  final Order order;
  const _Timeline({required this.order});

  /// Libellé de l'étape, avec l'heure pour les étapes de livraison franchies.
  String _label(String step) {
    final label = trackingLabel(step, order.isDelivery);
    DateTime? at;
    if (step == 'delivering') at = order.pickedUpAt;
    if (step == driverDeliveredStep) at = order.driverDeliveredAt;
    if (step == 'delivered' && order.isDelivery) at = order.receivedAt;
    return at == null ? label : '$label • ${formatTime(at)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Étapes à venir : voile de onSurface, visible en clair comme en sombre.
    final idle = scheme.onSurface.withValues(alpha: 0.10);
    final steps = trackingSteps(order.isDelivery);
    final current = trackingIndex(order.status, order.isDelivery, driverDelivered: order.driverDeliveredAt != null);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            for (var i = 0; i < steps.length; i++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOutBack,
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i <= current ? brandColor(context) : idle,
                          boxShadow: i == current
                              ? [BoxShadow(color: AppColors.brand.withValues(alpha: 0.4), blurRadius: 10)]
                              : null,
                        ),
                        child: Icon(
                          i < current ? Icons.check_rounded : statusIcon(steps[i]),
                          size: 15,
                          color: i <= current ? Colors.white : scheme.onSurfaceVariant,
                        ),
                      ),
                      if (i < steps.length - 1)
                        Container(
                          width: 3,
                          height: 22,
                          margin: const EdgeInsets.symmetric(vertical: 2),
                          alignment: Alignment.topCenter,
                          color: idle,
                          // La ligne se « remplit » jusqu'à l'étape en cours.
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeOut,
                            width: 3,
                            height: i < current ? 22 : 0,
                            color: brandColor(context),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 300),
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontSize: 14,
                          fontWeight: i == current ? FontWeight.w800 : FontWeight.w500,
                          color: i <= current ? scheme.onSurface : scheme.onSurfaceVariant,
                        ),
                        child: Text(_label(steps[i])),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _CustomerCard extends StatelessWidget {
  final Order order;
  const _CustomerCard({required this.order});

  @override
  Widget build(BuildContext context) {
    // Vente comptoir sans nom : le numéro est celui du restaurant, pas de client à appeler.
    final anonymousCounter = order.isCounter && (order.customerName.trim().isEmpty || order.customerName == 'Comptoir');
    final name = order.customerName.trim().isEmpty ? 'Comptoir' : order.customerName;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppColors.accent,
          child: Icon(order.isCounter ? Icons.point_of_sale_rounded : Icons.person_rounded, color: AppColors.ink),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(anonymousCounter
            ? orderModeLabel(order)
            : order.isCounter
                ? '${order.phone}\n${orderModeLabel(order)}'
                : order.hasLocation
                    ? '${order.phone}\nPosition GPS fournie'
                    : order.phone),
        isThreeLine: !anonymousCounter && (order.isCounter || order.hasLocation),
        trailing: anonymousCounter
            ? null
            : Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (order.hasLocation && !order.isCounter) ...[
              IconButton.filled(
                tooltip: 'Itinéraire',
                style: IconButton.styleFrom(backgroundColor: AppColors.brand),
                icon: const Icon(Icons.directions_rounded),
                onPressed: () => launchUrl(
                  Uri.parse(
                    'https://www.google.com/maps/dir/?api=1&destination=${order.deliveryLat},${order.deliveryLng}',
                  ),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              const SizedBox(width: 6),
            ],
            IconButton.filled(
              tooltip: 'Appeler',
              style: IconButton.styleFrom(backgroundColor: AppColors.green),
              icon: const Icon(Icons.call_rounded),
              onPressed: () => launchUrl(Uri(scheme: 'tel', path: order.phone.replaceAll(' ', ''))),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemsCard extends StatelessWidget {
  final Order order;
  const _ItemsCard({required this.order});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Articles', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 12),
            for (final i in order.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.brand.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('${i.quantity}×',
                          style: TextStyle(fontWeight: FontWeight.w800, color: brandColor(context))),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(i.name),
                          // Pack : contenu figé à la commande.
                          if (i.details != null && i.details!.isNotEmpty)
                            ItemDetailsText(i.details!, maxLines: null),
                        ],
                      ),
                    ),
                    Text(formatPrice(i.total)),
                  ],
                ),
              ),
            const Divider(height: 20),
            _row(context, 'Sous-total', order.subtotal),
            if (order.isDelivery) _row(context, orderDeliveryLineLabel(order), order.deliveryFee),
            if (order.paymentFee > 0) _row(context, 'Frais de paiement', order.paymentFee),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text('Total', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                const Spacer(),
                Price(order.total, size: 17),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, int amount) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const Spacer(),
          Text(formatPrice(amount)),
        ]),
      );
}

/// État du paiement mobile money (Flooz / Mixx).
class _PaymentCard extends StatelessWidget {
  final Order order;
  final bool admin;
  final bool busy;
  final VoidCallback onPay;
  final VoidCallback onCancel;
  const _PaymentCard({
    required this.order,
    required this.admin,
    required this.busy,
    required this.onPay,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paid = order.isPaid;
    final refunded = order.isRefunded;
    final failed = order.paymentFailed;
    final Color color;
    final String title;
    final String message;
    final IconData icon;
    if (refunded) {
      color = scheme.tertiary;
      icon = Icons.currency_exchange_rounded;
      title = paymentStatusLabel('refunded');
      message = '${formatPrice(order.total)} remboursés'
          '${order.paymentReference != null ? ' • Réf. ${order.paymentReference}' : ''}';
    } else if (paid && order.isCancelled) {
      color = const Color(0xFFE08A00);
      icon = Icons.currency_exchange_rounded;
      title = admin ? 'Payée puis annulée : à rembourser' : 'Remboursement en cours';
      message = admin
          ? 'Le client a payé ${formatPrice(order.total)} (réf. ${order.paymentReference ?? '-'}). '
              'Remboursez-le puis enregistrez le remboursement.'
          : 'Le restaurant va vous rembourser ${formatPrice(order.total)}.';
    } else if (paid) {
      color = AppColors.green;
      icon = Icons.verified_rounded;
      title = 'Paiement reçu';
      message = 'Réf. ${order.paymentReference ?? '-'}';
    } else if (failed) {
      color = AppColors.danger;
      icon = Icons.error_outline_rounded;
      title = 'Paiement non abouti';
      message = admin
          ? "Le paiement du client n'a pas abouti. La commande ne peut pas être lancée."
          : "Le paiement de ${formatPrice(order.total)} n'a pas été confirmé. "
              'Réessayez ou annulez la commande.';
    } else {
      color = const Color(0xFFE08A00);
      icon = Icons.account_balance_wallet_rounded;
      title = 'En attente de paiement';
      message = admin
          ? 'La commande pourra être lancée dès que le client aura payé.'
          : 'Payez ${formatPrice(order.total)} par ${paymentLabel(order.paymentMethod)} '
              'pour que le restaurant lance votre commande.';
    }
    final canPay = !admin && !paid && !refunded && !order.isCancelled;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: color)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(message, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
            if (canPay) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: busy ? null : onPay,
                icon: Icon(failed ? Icons.refresh_rounded : Icons.lock_rounded),
                label: Text(failed ? 'Réessayer' : 'Payer maintenant'),
              ),
              if (failed && order.status == 'pending') ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: busy ? null : onCancel,
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                  child: const Text('Annuler la commande'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Livraison en route (avant « Livraison faite ») : place pour le suivi en direct du livreur.
bool _liveTracking(Order o) => o.isDelivery && o.status == 'delivering' && o.driverDeliveredAt == null;

/// Suivi en direct : arrivée estimée, ancienneté de la position, ou position pas encore partagée.
class _LiveTrackingBanner extends StatelessWidget {
  final Order order;
  const _LiveTrackingBanner({required this.order});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final loc = order.isTrackable ? order.driverLocation : null;

    if (loc == null) {
      return Row(
        children: [
          Icon(Icons.location_searching_rounded, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              order.hasDriver
                  ? '${_driverLabel(order)} n\'a pas encore partagé sa position.'
                  : 'Le livreur n\'a pas encore partagé sa position.',
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      );
    }

    final eta = order.etaMinutes;
    final ago = DateTime.now().difference(loc.updatedAt).inMinutes;
    final accent = dark ? scheme.primary : AppColors.brand;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: dark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.brand,
            child: Icon(Icons.delivery_dining_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    eta != null ? 'Arrivée estimée : $eta min' : '${_driverLabel(order)} est en route',
                    key: ValueKey(eta),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: scheme.onSurface),
                  ),
                ),
                if (loc.isStale) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Dernière position il y a ${ago < 1 ? 1 : ago} min',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
                  ),
                ] else ...[
                  const SizedBox(height: 2),
                  Text(
                    'Position en direct',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _driverLabel(Order o) => (o.driverName ?? '').trim().isEmpty ? 'Le livreur' : o.driverName!.trim();

void _call(String phone) => launchUrl(Uri(scheme: 'tel', path: phone.replaceAll(' ', '')));

/// Client : bandeau très visible quand le livreur a indiqué « Livraison faite ».
class _ReceiptPrompt extends StatelessWidget {
  final Order order;
  final bool busy;
  final VoidCallback onConfirm;
  const _ReceiptPrompt({required this.order, required this.busy, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const accent = AppColors.green;
    final at = order.driverDeliveredAt;
    final phone = (order.driverPhone ?? '').trim();
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: accent, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.where_to_vote_rounded, color: accent, size: 34),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Le livreur indique vous avoir livré',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: scheme.onSurface),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${_driverLabel(order)} a indiqué « Livraison faite »${at != null ? ' à ${formatTime(at)}' : ''}. '
            'Vous avez bien votre commande ? Confirmez-le pour la terminer.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(58),
              textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
            ),
            onPressed: busy ? null : onConfirm,
            icon: busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  )
                : const Icon(Icons.check_circle_rounded, size: 26),
            label: const Text("J'ai reçu ma commande"),
          ),
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => _call(phone),
              icon: const Icon(Icons.call_rounded),
              label: const Text("Pas reçue ? Appeler le livreur"),
            ),
          ],
        ],
      ),
    );
  }
}

/// Client : commande reçue (« Reçu » confirmé).
class _ReceivedBanner extends StatelessWidget {
  final DateTime receivedAt;
  const _ReceivedBanner({required this.receivedAt});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.green.withValues(alpha: 0.12),
      child: ListTile(
        leading: const Icon(Icons.verified_rounded, color: AppColors.green, size: 30),
        title: Text(
          'Commande reçue le ${formatDateTime(receivedAt)} ✅',
          style: TextStyle(fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface),
        ),
      ),
    );
  }
}

/// Client : livreur attribué (nom + bouton Appeler).
class _DriverCard extends StatelessWidget {
  final Order order;
  const _DriverCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final phone = (order.driverPhone ?? '').trim();
    return Card(
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: AppColors.accent,
          child: Text('🛵', style: TextStyle(fontSize: 20)),
        ),
        title: Text('Votre livreur', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        subtitle: Text(
          _driverLabel(order),
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: scheme.onSurface),
        ),
        trailing: phone.isEmpty
            ? null
            : FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.green,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 40),
                ),
                onPressed: () => _call(phone),
                icon: const Icon(Icons.call_rounded, size: 18),
                label: const Text('Appeler'),
              ),
      ),
    );
  }
}

/// Admin : livreur attribué, attribution / changement / retrait, état de la livraison.
class _AdminDriverSection extends StatelessWidget {
  final Order order;
  final bool busy;
  final VoidCallback onAssign;
  final VoidCallback onRemove;
  const _AdminDriverSection({
    required this.order,
    required this.busy,
    required this.onAssign,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final o = order;
    final phone = (o.driverPhone ?? '').trim();
    // Attribution possible quand la commande est prête ou en livraison (pas après « Livraison faite »).
    final canAssign = (o.status == 'ready' || o.status == 'delivering') && !o.awaitingReceipt;
    String? state;
    Color stateColor = scheme.onSurfaceVariant;
    if (o.awaitingReceipt) {
      state = 'Livrée par ${_driverLabel(o)} à ${formatTime(o.driverDeliveredAt!)} — en attente du « Reçu » client';
      stateColor = const Color(0xFFE08A00);
    } else if (o.status == 'delivered') {
      final by = o.hasDriver ? ' par ${_driverLabel(o)}' : '';
      state = o.receivedAt != null
          ? 'Livrée$by • reçue par le client le ${formatDateTime(o.receivedAt!)}'
          : 'Livrée$by';
      stateColor = AppColors.green;
    } else if (o.hasDriver && o.pickedUpAt != null) {
      state = 'Prise en charge à ${formatTime(o.pickedUpAt!)}';
    } else if (!o.hasDriver && !canAssign) {
      state = 'Attribution possible dès que la commande est prête.';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.delivery_dining_rounded, color: brandColor(context)),
                const SizedBox(width: 10),
                Text('Livreur', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: scheme.onSurface)),
                const Spacer(),
                if (o.hasDriver && phone.isNotEmpty)
                  IconButton.filled(
                    tooltip: 'Appeler le livreur',
                    style: IconButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white),
                    icon: const Icon(Icons.call_rounded, size: 20),
                    onPressed: () => _call(phone),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              o.hasDriver ? '🛵 ${_driverLabel(o)}${phone.isNotEmpty ? ' • $phone' : ''}' : 'Aucun',
              style: TextStyle(
                fontWeight: o.hasDriver ? FontWeight.w700 : FontWeight.w500,
                color: o.hasDriver ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
            if (state != null) ...[
              const SizedBox(height: 6),
              Text(state, style: TextStyle(color: stateColor, fontWeight: FontWeight.w600, height: 1.3)),
            ],
            if (canAssign) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: busy ? null : onAssign,
                      icon: Icon(o.hasDriver ? Icons.swap_horiz_rounded : Icons.person_add_alt_1_rounded),
                      label: Text(o.hasDriver ? 'Changer' : 'Attribuer'),
                    ),
                  ),
                  if (o.hasDriver) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                        onPressed: busy ? null : onRemove,
                        icon: const Icon(Icons.person_remove_rounded),
                        label: const Text('Retirer'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Admin : liste des livreurs actifs (avec leurs livraisons en cours) ; renvoie le livreur choisi.
class _DriverPicker extends StatefulWidget {
  final int? currentId;
  const _DriverPicker({this.currentId});

  @override
  State<_DriverPicker> createState() => _DriverPickerState();
}

class _DriverPickerState extends State<_DriverPicker> {
  late Future<List<Driver>> _future = fetchDrivers();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Choisir un livreur',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: scheme.onSurface)),
            ),
            Flexible(
              child: FutureBuilder<List<Driver>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return SingleChildScrollView(
                      child: ErrorRetry(
                        error: snap.error!,
                        onRetry: () => setState(() => _future = fetchDrivers()),
                      ),
                    );
                  }
                  if (!snap.hasData) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final drivers = snap.data!.where((d) => d.active).toList()
                    ..sort((a, b) => a.activeDeliveries.compareTo(b.activeDeliveries));
                  if (drivers.isEmpty) {
                    return const SingleChildScrollView(
                      child: EmptyState(
                        emoji: '🛵',
                        title: 'Aucun livreur actif',
                        message: 'Ajoutez un livreur depuis « Plus » → « Livreurs ».',
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: drivers.length,
                    itemBuilder: (_, i) {
                      final d = drivers[i];
                      final current = d.id == widget.currentId;
                      final n = d.activeDeliveries;
                      return ListTile(
                        enabled: !current,
                        leading: CircleAvatar(
                          backgroundColor: AppColors.accent,
                          child: Text(
                            d.name.isEmpty ? '?' : d.name[0].toUpperCase(),
                            style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.black87),
                          ),
                        ),
                        title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text(
                          '${d.phone} • ${n == 0 ? 'libre' : '$n livraison${n > 1 ? 's' : ''} en cours'}'
                          '${current ? ' • actuel' : ''}',
                        ),
                        trailing: Icon(
                          n == 0 ? Icons.check_circle_outline_rounded : Icons.delivery_dining_rounded,
                          color: n == 0 ? AppColors.green : scheme.onSurfaceVariant,
                        ),
                        onTap: current ? null : () => Navigator.pop(context, d),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Admin : saisie de la référence d'un remboursement.
class _RefundDialog extends StatefulWidget {
  final int total;
  const _RefundDialog({required this.total});

  @override
  State<_RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends State<_RefundDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rembourser le client ?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Montant payé : ${formatPrice(widget.total)}.'),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Référence du remboursement',
              helperText: 'Obligatoire si vous avez remboursé à la main (transfert Flooz / Mixx).',
              helperMaxLines: 3,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: const Text('Rembourser'),
        ),
      ],
    );
  }
}
