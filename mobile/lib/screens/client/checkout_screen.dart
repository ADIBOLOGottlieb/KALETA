import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/cart_provider.dart';
import '../../services/api.dart';
import '../../services/live_location_sharer.dart';
import '../../services/maps_link.dart';
import '../../services/order_events.dart';
import '../../services/shared_location.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import 'gps_picker_screen.dart';
import 'location_import_sheet.dart';
import 'opening_hours_banner.dart';
import 'order_estimate.dart';
import 'profile/saved_addresses_screen.dart';

/// Finalisation de la commande. Retourne la [Order] créée via `Navigator.pop`.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _address;
  late final TextEditingController _phone;
  final _note = TextEditingController();
  String _mode = 'delivery';
  String _payment = 'cash';
  AppSettings? _settings;
  bool _settingsFailed = false; // 3 essais sans succès : bouton « Réessayer »
  bool _submitting = false;
  LocationData? _location;
  // Dernière adresse remplie automatiquement (profil, GPS, « Mes adresses »).
  String? _prefilledAddress;
  // Devis des frais de livraison pour la position choisie (GET /api/delivery/quote).
  DeliveryQuote? _quote;
  bool _quoting = false;
  int _quoteSeq = 0; // ignore les réponses d'une position précédente
  String? _quotedKey; // position du dernier devis demandé
  // Mode de frais 'zone' : liste des zones et zone choisie (ou reconnue d'après la position).
  List<DeliveryZone>? _zones;
  bool _zonesLoading = false;
  bool _zonesFailed = false;
  int? _zoneId;
  bool _zoneRecognized = false; // présélectionnée d'après la position
  bool _zoneChosen = false; // choisie à la main (ou mémorisée) : le devis ne l'écrase pas
  int? _savedAddressId; // adresse enregistrée utilisée (sa zone est mémorisée sur l'appareil)

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().user;
    _prefilledAddress = user?.address;
    _address = TextEditingController(text: user?.address ?? '');
    _phone = TextEditingController(text: user?.phone ?? '');
    _loadSettings();
    // Position partagée depuis Google Maps (avant ou pendant l'ouverture de cet écran).
    SharedLocationService.instance.pending.addListener(_onSharedLocation);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSharedLocation());
  }

  /// Réglages à jour (ouverture, minimum, frais) : 3 essais espacés, puis bouton « Réessayer ».
  Future<void> _loadSettings() async {
    if (_settingsFailed) setState(() => _settingsFailed = false);
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final s = await Api.instance.settings(fresh: true);
        if (mounted) {
          setState(() => _settings = s);
          if (s.feeByZone && _zones == null) _loadZones();
          _refreshQuote();
        }
        return;
      } catch (_) {
        if (!mounted) return;
        if (attempt < 3) await Future.delayed(Duration(seconds: 2 * attempt));
        if (!mounted) return;
      }
    }
    setState(() => _settingsFailed = true);
  }

  @override
  void dispose() {
    SharedLocationService.instance.pending.removeListener(_onSharedLocation);
    _address.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _zoneMode => _settings?.feeByZone == true;

  /// Zone choisie (null si aucune).
  DeliveryZone? get _zone {
    final id = _zoneId;
    if (id == null) return null;
    for (final z in _zones ?? const <DeliveryZone>[]) {
      if (z.id == id) return z;
    }
    return null;
  }

  /// Nom de la zone choisie (liste des zones, sinon le devis s'il l'a reconnue).
  String? get _zoneName => _zone?.name ?? (_quote?.zoneId == _zoneId ? _quote?.zoneName : null);

  /// Charge les zones de livraison (mode 'zone').
  Future<void> _loadZones() async {
    setState(() {
      _zonesLoading = true;
      _zonesFailed = false;
    });
    try {
      final zones = await Api.instance.deliveryZones(fresh: true);
      if (!mounted) return;
      setState(() {
        _zones = zones;
        _zonesLoading = false;
        if (_zoneId != null && !zones.any((z) => z.id == _zoneId)) {
          _zoneId = null;
          _zoneRecognized = false;
          _zoneChosen = false;
        }
      });
      _restoreSavedAddressZone();
    } catch (_) {
      if (mounted) {
        setState(() {
          _zonesLoading = false;
          _zonesFailed = true;
        });
      }
    }
  }

  /// Frais de livraison affichés : en mode zone, le prix de la zone choisie ; sinon le devis pour
  /// la position, ou (devis en cours ou impossible) les frais de base. Le serveur recalcule à la commande.
  int _getDeliveryFee() {
    if (_mode != 'delivery') return 0;
    if (_zoneMode) {
      final zone = _zone;
      if (zone != null) return zone.fee;
      if (_zoneId != null && _quote?.zoneId == _zoneId) return _quote!.fee;
      return 0;
    }
    return _quote?.fee ?? _settings?.deliveryFee ?? 0;
  }

  /// Montant estimé (sous-total + livraison + frais mobile money facturés au client).
  OrderEstimate _estimate(CartProvider cart) => OrderEstimate.compute(
        subtotal: cart.subtotal,
        delivery: _mode == 'delivery',
        deliveryFee: _getDeliveryFee(),
        paymentMethod: _payment,
        feePercent: _settings == null ? 0 : _feePercent(),
      );

  /// Mode zone : aucune zone choisie (ou adresse hors des zones) → commande impossible.
  bool get _zoneMissing => _mode == 'delivery' && _zoneMode && _zoneId == null;

  /// Adresse hors de la zone de livraison (devis du serveur). En mode zone, seule l'absence de zone bloque :
  /// le client peut choisir sa zone à la main même si sa position n'a pas été reconnue.
  bool get _outOfZone =>
      _mode == 'delivery' && (_zoneMode ? _zoneMissing : (_quote != null && !_quote!.withinZone));

  /// Message mode zone : celui du serveur, sinon « Choisissez votre zone de livraison ».
  String get _zoneMessage {
    final q = _quote;
    if (q != null && q.zoneId == null && (q.message ?? '').trim().isNotEmpty) return outOfZoneMessage(q);
    return 'Choisissez votre zone de livraison';
  }

  /// Le client choisit sa zone dans la liste.
  void _selectZone(int? id) {
    setState(() {
      _zoneId = id;
      _zoneChosen = id != null;
      _zoneRecognized = id != null && _quote?.zoneId == id;
    });
  }

  static String _addressZoneKey(int addressId) => 'saved_address_zone_$addressId';

  /// Adresse enregistrée : reprend la zone mémorisée sur l'appareil (si elle existe toujours).
  Future<void> _restoreSavedAddressZone() async {
    final addressId = _savedAddressId;
    if (addressId == null || !_zoneMode || _zones == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getInt(_addressZoneKey(addressId));
      if (!mounted || id == null || addressId != _savedAddressId) return;
      if (_zones!.any((z) => z.id == id)) {
        setState(() {
          _zoneId = id;
          _zoneChosen = true;
          _zoneRecognized = false;
        });
      }
    } catch (_) {
      // Mémoire locale indisponible : le client choisit sa zone.
    }
  }

  /// Mémorise la zone de l'adresse enregistrée utilisée pour la prochaine commande.
  Future<void> _rememberSavedAddressZone() async {
    final addressId = _savedAddressId;
    final zoneId = _zoneId;
    if (addressId == null || zoneId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_addressZoneKey(addressId), zoneId);
    } catch (_) {}
  }

  /// Demande le devis de livraison quand la position change (sans effet si déjà demandé).
  Future<void> _refreshQuote() async {
    final loc = _location;
    if (loc == null || _settings == null) return;
    final key = '${loc.lat.toStringAsFixed(5)},${loc.lng.toStringAsFixed(5)}';
    if (key == _quotedKey && (_quote != null || _quoting)) return;
    _quotedKey = key;
    final seq = ++_quoteSeq;
    setState(() {
      _quote = null;
      _quoting = true;
    });
    DeliveryQuote? quote;
    try {
      quote = await Api.instance.deliveryQuote(lat: loc.lat, lng: loc.lng);
    } catch (_) {
      // Devis impossible (réseau) : frais de base affichés, le serveur tranchera.
      quote = null;
    }
    if (!mounted || seq != _quoteSeq) return;
    setState(() {
      _quote = quote;
      _quoting = false;
      if (quote == null) _quotedKey = null; // nouvel essai au prochain changement
      // Mode zone : présélectionne la zone reconnue d'après la position (sauf choix du client).
      if (quote != null && _zoneMode && !_zoneChosen) {
        _zoneId = quote.zoneId;
        _zoneRecognized = quote.zoneId != null;
      }
    });
  }

  /// Change la position de livraison et relance le devis.
  void _setLocation(LocationData loc) {
    setState(() => _location = loc);
    _refreshQuote();
  }

  /// Taux des frais du moyen sélectionné (commission de l'agrégateur pour cet opérateur).
  /// Taux FACTURÉ AU CLIENT : 0 quand le restaurant absorbe la commission.
  double _feePercent() => _settings?.clientFeePercentFor(_payment) ?? 0;

  /// Remplit le champ adresse sans écraser ce que le client a tapé lui-même :
  /// seulement s'il est vide ou s'il contient encore l'adresse pré-remplie précédente.
  void _prefillAddress(String? address) {
    final a = address?.trim() ?? '';
    if (a.isEmpty) return;
    final current = _address.text.trim();
    if (current.isEmpty || current == (_prefilledAddress ?? '').trim()) {
      _address.text = a;
      _prefilledAddress = a;
    }
  }

  /// Choix de la position : Google Maps (partage / lien), coordonnées, plus code ou GPS.
  Future<void> _selectLocation() async {
    final loc = await showLocationImportSheet(context, initialLat: _location?.lat, initialLng: _location?.lng);
    if (loc == null || !mounted) return;
    _savedAddressId = null; // nouvelle position : ce n'est plus l'adresse enregistrée
    _prefillAddress(loc.address);
    _setLocation(loc);
  }

  /// Une position partagée depuis Google Maps est arrivée : on l'utilise directement,
  /// sauf si la feuille « Choisir ma position » est ouverte (elle s'en charge).
  void _onSharedLocation() {
    final service = SharedLocationService.instance;
    if (!mounted || service.pending.value == null || isLocationImportSheetOpen) return;
    final imported = service.consume();
    if (imported != null) _useImported(imported);
  }

  Future<void> _useImported(ImportedLocation imported) async {
    final loc = LocationData(lat: imported.lat, lng: imported.lng, address: importedAddressText(imported));
    _mode = 'delivery';
    _savedAddressId = null;
    _prefillAddress(loc.address);
    _setLocation(loc);
    showMessage(context, 'Position reçue de Google Maps ✅');
    if ((imported.address?.trim() ?? '').isNotEmpty) return;
    // Pas d'adresse partagée : on la cherche (OpenStreetMap) pour pré-remplir le champ.
    final address = await resolveImportedAddress(imported);
    final current = _location;
    if (!mounted || address == null || current == null) return;
    if (current.lat != imported.lat || current.lng != imported.lng) return;
    setState(() {
      _location = LocationData(lat: current.lat, lng: current.lng, address: address);
      _prefillAddress(address);
    });
  }

  /// « Mes adresses » : remplit l'adresse et, si elle en a une, la position GPS.
  Future<void> _pickSavedAddress() async {
    final a = await showSavedAddressPicker(context);
    if (a == null || !mounted) return;
    setState(() {
      _address.text = a.address;
      _prefilledAddress = a.address;
      _savedAddressId = a.id;
    });
    _restoreSavedAddressZone();
    if (a.lat != null && a.lng != null) _setLocation(LocationData(lat: a.lat!, lng: a.lng!, address: a.address));
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final cart = context.read<CartProvider>();
    final settings = _settings;
    if (settings != null && !settings.isOpen) {
      showMessage(context, closedOrderMessage(settings), error: true);
      return;
    }
    if (_outOfZone) {
      showMessage(context, _zoneMode ? _zoneMessage : outOfZoneMessage(_quote!), error: true);
      return;
    }
    if (settings != null && cart.subtotal < settings.minOrder) {
      showMessage(context, 'Commande minimum : ${formatPrice(settings.minOrder)}', error: true);
      return;
    }
    if (_mode == 'delivery' && _location == null) {
      showMessage(context, 'Veuillez sélectionner votre localisation', error: true);
      return;
    }

    setState(() => _submitting = true);
    try {
      final order = await Api.instance.createOrder({
        'items': cart.toOrderItems(),
        'mode': _mode,
        'address': _mode == 'delivery' ? _address.text.trim() : null,
        'phone': _phone.text.trim(),
        'note': _note.text.trim(),
        'payment_method': _payment,
        'location': _mode == 'delivery' ? _location?.toJson() : null,
      }, zoneId: _mode == 'delivery' && _zoneMode ? _zoneId : null);
      notifyOrdersChanged();
      // Position en direct choisie (comme WhatsApp) : le partage démarre dès que la commande existe.
      final live = _mode == 'delivery' ? _location?.liveMinutes : null;
      if (live != null) {
        LiveLocationSharer.instance.start(order.id, live).catchError((Object e) {
          if (mounted) showMessage(context, e is StateError ? e.message : e, error: true);
          return order;
        });
      }
      if (_mode == 'delivery' && _zoneMode) _rememberSavedAddressZone();
      // Panier vidé seulement après la boîte de confirmation (sinon récapitulatif vide derrière).
      if (!mounted) {
        cart.clear();
        return;
      }
      // Retient l'adresse pour la prochaine fois.
      final auth = context.read<AuthProvider>();
      if (_mode == 'delivery' && (auth.user?.address ?? '').isEmpty) {
        auth.updateProfile({'address': _address.text.trim()}).catchError((_) {});
      }
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Text('🎉', style: TextStyle(fontSize: 48)),
          title: const Text('Commande envoyée !'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Votre commande n°${order.id} a bien été reçue. ${isMobileMoney(order.paymentMethod) ? 'Réglez-la maintenant par ${paymentLabel(order.paymentMethod)} pour que le restaurant la lance.' : 'Vous pouvez suivre sa préparation en temps réel.'}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              // Montant officiel renvoyé par le serveur.
              Text(
                'Total : ${formatPrice(order.total)}',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: brandColor(context)),
              ),
            ],
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(isMobileMoney(order.paymentMethod) ? 'Payer maintenant' : 'Suivre ma commande')),
          ],
        ),
      );
      cart.clear();
      if (mounted) Navigator.pop(context, order);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Choix de la zone (« Tokoin — 800 FCFA »), avec la zone reconnue d'après la position.
  Widget _zonePicker(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final zones = _zones;
    if (zones == null) {
      if (_zonesFailed) {
        return Card(
          color: scheme.errorContainer,
          child: ListTile(
            leading: Icon(Icons.cloud_off_rounded, color: scheme.onErrorContainer),
            title: Text('Impossible de charger les zones de livraison.',
                style: TextStyle(color: scheme.onErrorContainer)),
            trailing: TextButton(onPressed: _loadZones, child: const Text('Réessayer')),
          ),
        );
      }
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))),
      );
    }
    if (zones.isEmpty) {
      return _zoneNotice(context, 'Aucune zone de livraison disponible pour le moment. Optez pour « À emporter ».');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<int>(
          key: ValueKey('zone-$_zoneId'),
          initialValue: zones.any((z) => z.id == _zoneId) ? _zoneId : null,
          isExpanded: true,
          decoration: const InputDecoration(
            hintText: 'Choisissez votre zone',
            prefixIcon: Icon(Icons.place_rounded),
          ),
          items: [
            for (final z in zones)
              DropdownMenuItem(
                value: z.id,
                child: Text(zoneOptionLabel(z), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _zonesLoading ? null : _selectZone,
        ),
        if (_zoneId != null && _zoneRecognized)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Row(
              children: [
                const Icon(Icons.my_location_rounded, size: 16, color: AppColors.green),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    "Zone reconnue d'après votre position. Vous pouvez la changer.",
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        if (_zoneId == null && _mode == 'delivery') ...[
          const SizedBox(height: 10),
          _zoneNotice(context, '$_zoneMessage.'),
        ],
      ],
    );
  }

  Widget _zoneNotice(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(Icons.wrong_location_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: scheme.onErrorContainer, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final estimate = _estimate(cart);
    final deliveryFee = estimate.deliveryFee;
    final paymentFee = estimate.paymentFee;
    final settings = _settings;
    final closed = settings != null && !settings.isOpen;
    return Scaffold(
      appBar: AppBar(title: const Text('Finaliser la commande')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_settingsFailed) ...[
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: Icon(Icons.cloud_off_rounded, color: Theme.of(context).colorScheme.onErrorContainer),
                  title: Text(
                    'Impossible de charger les informations du restaurant (horaires, frais).',
                    style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                  ),
                  trailing: TextButton(onPressed: _loadSettings, child: const Text('Réessayer')),
                ),
              ),
              const SizedBox(height: 16),
            ],
            // Fermé (« ouvre lundi à 10:00 ») ou fermeture dans moins de 30 min.
            if (settings != null)
              OpeningHoursBanner(
                settings: settings,
                margin: const EdgeInsets.only(bottom: 16),
                onExpired: _loadSettings,
              ),
            const _Label('Mode de retrait'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'delivery', label: Text('Livraison'), icon: Icon(Icons.delivery_dining_rounded)),
                ButtonSegment(value: 'pickup', label: Text('À emporter'), icon: Icon(Icons.storefront_rounded)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: AppColors.brand,
                selectedForegroundColor: Colors.white,
                backgroundColor: Theme.of(context).colorScheme.surface,
              ),
            ),
            const SizedBox(height: 20),
            if (_mode == 'delivery') ...[
              Row(
                children: [
                  const Expanded(child: _Label('Adresse de livraison')),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextButton.icon(
                      onPressed: _pickSavedAddress,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.bookmark_rounded, size: 18),
                      label: const Text('Mes adresses'),
                    ),
                  ),
                ],
              ),
              TextFormField(
                controller: _address,
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: 'Quartier, rue, point de repère (ex : Tokoin, Bè...)',
                  prefixIcon: Icon(Icons.location_on_rounded),
                ),
                validator: (v) =>
                    _mode == 'delivery' && (v == null || v.trim().isEmpty) ? 'Indiquez votre adresse' : null,
              ),
              const SizedBox(height: 14),
              const _Label('Localisation'),
              FilledButton(
                onPressed: _selectLocation,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(_location == null
                    ? '📍 Envoyer ma position'
                    : '📍 Changer ma position'),
              ),
              const SizedBox(height: 10),
              Material(
                color: _location != null
                    ? AppColors.green.withValues(alpha: 0.12)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: _selectLocation,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.map_rounded, color: _location != null ? Colors.green : brandColor(context)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _location != null
                                ? [
                                    if (_location!.liveMinutes != null)
                                      '🟢 Position en direct · ${liveShareDurations[_location!.liveMinutes] ?? '${_location!.liveMinutes} min'}',
                                    if ((_location!.address ?? '').trim().isNotEmpty) _location!.address!.trim(),
                                    '${_location!.lat.toStringAsFixed(4)}, ${_location!.lng.toStringAsFixed(4)}',
                                  ].join('\n')
                                : 'Aucune position choisie : le livreur en a besoin pour vous trouver.',
                            style: TextStyle(
                              color: _location != null ? AppColors.green : Theme.of(context).colorScheme.onSurfaceVariant,
                              fontSize: _location != null ? 13 : 14,
                              fontWeight: _location != null ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                        Icon(Icons.arrow_forward_rounded, color: _location != null ? Colors.green : brandColor(context), size: 18),
                      ],
                    ),
                  ),
                ),
              ),
              if (_zoneMode) ...[
                const SizedBox(height: 16),
                const _Label('Zone de livraison'),
                _zonePicker(context),
              ],
              if (_outOfZone && !_zoneMode) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.wrong_location_rounded, color: Theme.of(context).colorScheme.onErrorContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${outOfZoneMessage(_quote!)}. Choisissez une autre position ou optez pour « À emporter ».',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ] else if (_settings != null) ...[
              Card(
                child: ListTile(
                  leading: Icon(Icons.storefront_rounded, color: brandColor(context)),
                  title: const Text('À récupérer au restaurant'),
                  subtitle: Text(_settings!.restaurantAddress),
                ),
              ),
              const SizedBox(height: 16),
            ],
            const _Label('Téléphone de contact'),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.phone_rounded)),
              validator: (v) => (v == null || v.trim().length < 8) ? 'Numéro invalide' : null,
            ),
            const SizedBox(height: 16),
            const _Label('Note pour la cuisine (optionnel)'),
            TextFormField(
              controller: _note,
              maxLines: 2,
              decoration: const InputDecoration(hintText: 'Ex : sans piment, bien cuit...'),
            ),
            const SizedBox(height: 20),
            const _Label('Paiement'),
            Card(
              child: RadioGroup<String>(
                groupValue: _payment,
                onChanged: (v) => setState(() => _payment = v!),
                child: Column(
                  children: [
                    for (final e in paymentMethods.entries)
                      RadioListTile<String>(
                        value: e.key,
                        title: Text(e.key == 'cash' && _mode == 'pickup' ? 'Espèces au retrait' : e.value),
                        // Frais affichés seulement s'ils sont facturés au client.
                        subtitle: isMobileMoney(e.key) && _settings != null && _settings!.clientFeePercentFor(e.key) > 0
                            ? Text('Frais ${formatPercent(_settings!.clientFeePercentFor(e.key))} %')
                            : null,
                        secondary: Icon(paymentIcon(e.key), color: brandColor(context)),
                      ),
                  ],
                ),
              ),
            ),
            if (_payment != 'cash')
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 4),
                child: Text(
                  '${_settings?.paymentProvider == 'kadev' ? 'Après validation, vous serez redirigé vers la page de paiement sécurisée (KADEV PAY). ' : 'Après validation, vous recevrez une demande de paiement sur votre téléphone : confirmez-la avec votre code PIN. '}'
                  '${_feePercent() > 0 ? "Des frais de ${formatPercent(_feePercent())} % (commission ${paymentLabel(_payment).split(' ').first}) s'ajoutent au total." : "Aucun frais de paiement : même prix qu'en espèces."}',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12.5),
                ),
              ),
            const SizedBox(height: 20),
            const _Label('Récapitulatif'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    for (final l in cart.lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Text('${l.quantity}×', style: const TextStyle(fontWeight: FontWeight.w800)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(l.product.name),
                                  if (l.product.isPack && l.product.packItems.every((c) => c.name.isNotEmpty))
                                    ItemDetailsText(l.product.packSummary),
                                ],
                              ),
                            ),
                            Text(formatPrice(l.total)),
                          ],
                        ),
                      ),
                    const Divider(height: 20),
                    _TotalRow('Sous-total', cart.subtotal),
                    if (_mode == 'delivery')
                      _TotalRow(
                        // Mode zone : « Livraison (Tokoin) », ou « Livraison (zone à choisir) ».
                        _zoneMode
                            ? (_zoneName == null ? 'Livraison (zone à choisir)' : deliveryLineLabel(null, zoneName: _zoneName))
                            : deliveryLineLabel(_quote),
                        deliveryFee,
                        // Devis en cours : frais de base affichés en attendant.
                        trailing: _quoting
                            ? const Padding(
                                padding: EdgeInsets.only(left: 8),
                                child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                              )
                            : null,
                      ),
                    if (_payment != 'cash' && paymentFee > 0)
                      _TotalRow('Frais ${paymentLabel(_payment).split(' ').first} (${formatPercent(_feePercent())} %)', paymentFee),
                    const SizedBox(height: 6),
                    _TotalRow('Total', estimate.total, bold: true),
                    if (_mode == 'delivery' && settings != null && settings.feeByDistance && _quote == null && !_quoting)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Frais de livraison selon la distance : montant exact confirmé à la commande.',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 100),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        color: Theme.of(context).colorScheme.surface,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: SafeArea(
          top: false,
          child: FilledButton(
            // Sans les réglages, les frais affichés seraient faux : on attend leur chargement.
            // Fermé ou hors zone : commande impossible (le message est affiché plus haut).
            onPressed: _submitting ||
                    _settings == null ||
                    cart.isEmpty ||
                    closed ||
                    _outOfZone ||
                    (_mode == 'delivery' && _location == null)
                ? null
                : _submit,
            child: _submitting
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text(closed
                    ? 'Restaurant fermé'
                    : _zoneMissing
                        ? 'Choisissez votre zone de livraison'
                    : _outOfZone
                        ? 'Adresse hors zone de livraison'
                        : 'Commander • ${formatPrice(estimate.total)}'),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      );
}

class _TotalRow extends StatelessWidget {
  final String label;
  final int amount;
  final bool bold;
  final Widget? trailing; // ex. indicateur de devis en cours
  const _TotalRow(this.label, this.amount, {this.bold = false, this.trailing});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w900 : FontWeight.w500,
      fontSize: bold ? 17 : 14,
      color: bold ? brandColor(context) : Theme.of(context).colorScheme.onSurface,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Text(label, style: style),
        ?trailing,
        const Spacer(),
        Text(formatPrice(amount), style: style),
      ]),
    );
  }
}
