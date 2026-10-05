import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models.dart';
import '../../models_admin.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_api.dart';
import '../../services/api.dart';
import '../../services/auth_api.dart';
import '../../services/delivery_api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../client/gps_picker_screen.dart';
import '../client/profile_screen.dart';
import '../legal/legal_screen.dart' show appVersion;
import 'admin_layout.dart';
import 'collections_screen.dart';
import 'delivery_zones_screen.dart';
import 'drivers_screen.dart';
import 'error_logs_screen.dart';
import 'opening_hours_editor.dart';
import 'password_resets_screen.dart';
import 'payments_review_screen.dart';
import 'reports_screen.dart';
import 'staff_screen.dart';

class AdminMoreScreen extends StatefulWidget {
  const AdminMoreScreen({super.key});

  @override
  State<AdminMoreScreen> createState() => _AdminMoreScreenState();
}

class _AdminMoreScreenState extends State<AdminMoreScreen> {
  @override
  void initState() {
    super.initState();
    refreshPasswordResetCount(); // badge « Mots de passe oubliés »
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final owner = user?.isOwner ?? false;
    Future<void> open(Widget page) async {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
      refreshPasswordResetCount();
    }

    Widget tile(IconData icon, String title, Widget page, {String? subtitle, ValueListenable<int>? badge}) => ListTile(
          leading: Icon(icon, color: brandColor(context)),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: badge == null
              ? const Icon(Icons.chevron_right_rounded)
              : ValueListenableBuilder<int>(
                  valueListenable: badge,
                  builder: (_, n, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (n > 0) Badge(label: Text('$n'), backgroundColor: AppColors.danger),
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
          onTap: () => open(page),
        );

    Widget section(String label) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Plus')),
      body: MaxContentWidth(
        maxWidth: 760,
        child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          section('Restaurant'),
          Card(
            child: Column(
              children: [
                tile(Icons.storefront_rounded, 'Paramètres du restaurant', const SettingsScreen(),
                    subtitle: 'Ouverture, frais de livraison, contact'),
                tile(Icons.delivery_dining_rounded, 'Livreurs', const DriversScreen(),
                    subtitle: 'Comptes, activation, livraisons en cours'),
                tile(Icons.people_alt_rounded, 'Clients', const CustomersScreen()),
                tile(Icons.lock_reset_rounded, 'Mots de passe oubliés', const PasswordResetsScreen(),
                    subtitle: 'Codes à communiquer aux clients', badge: passwordResetCount),
              ],
            ),
          ),
          section('Argent'),
          Card(
            child: Column(
              children: [
                tile(Icons.price_check_rounded, 'Paiements à vérifier', const PaymentsReviewScreen(),
                    subtitle: 'Mobile money en attente ou avec un écart', badge: paymentReviewCount),
                tile(Icons.insights_rounded, 'Rapports', const ReportsScreen(),
                    subtitle: 'Ventes par période, livreurs, top des plats, export Excel'),
                tile(Icons.account_balance_wallet_rounded, 'Encaissements', const CollectionsScreen(),
                    subtitle: 'Totaux, frais, reversements, export CSV'),
              ],
            ),
          ),
          section('Apparence'),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: ThemeModeSelector(),
            ),
          ),
          section('Compte'),
          Card(
            child: Column(
              children: [
                if (user != null)
                  tile(Icons.manage_accounts_rounded, 'Mon compte', EditProfileScreen(user: user),
                      subtitle: '${user.phone} • ${owner ? 'Propriétaire' : 'Gérant'}'),
                // Le propriétaire a la main sur tout : gérants et suivi technique de l'app.
                if (owner) ...[
                  tile(Icons.badge_rounded, 'Gérants', const StaffScreen(),
                      subtitle: 'Créer, désactiver ou supprimer les comptes gérant'),
                  tile(Icons.bug_report_rounded, "Erreurs de l'app", const ErrorLogsScreen(),
                      subtitle: "Plantages de l'application et erreurs du serveur"),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () async {
              if (await confirmDialog(context, 'Déconnexion', 'Voulez-vous vous déconnecter ?',
                  confirm: 'Se déconnecter')) {
                if (context.mounted) context.read<AuthProvider>().logout();
              }
            },
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Se déconnecter'),
          ),
          const SizedBox(height: 32),
          const Center(child: AppLogo(size: 80)),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'KALETA • version $appVersion',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fee = TextEditingController();
  final _min = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _cancelMinutes = TextEditingController();
  final _paymentFee = TextEditingController(); // réglage admin (si l'agrégateur n'impose pas ses frais)
  // Confirmation automatique de la réception (heures) : hors AppSettings, lu et enregistré à part.
  final _autoConfirmHours = TextEditingController();
  int? _loadedAutoConfirmHours;
  late final Future<MerchantInfo> _merchant = fetchMerchant();
  AppSettings? _current; // réglages chargés : conserve les champs non modifiés ici
  // Position du restaurant (départ des itinéraires de livraison) ; null si non définie.
  double? _lat;
  double? _lng;
  String? _positionAddress; // adresse renvoyée par la carte (session en cours)
  bool _savingPosition = false;
  bool _manualOpen = true; // interrupteur manuel (l'état effectif dépend aussi des horaires)
  // Horaires d'ouverture automatiques.
  bool _hoursEnabled = false;
  Map<String, List<List<String>>> _hours = defaultOpeningHours();
  // Frais de livraison : 'fixed', 'distance' (base = _fee) ou 'zone' (prix de chaque zone).
  String _feeMode = 'fixed';
  // Zones de livraison (mode 'zone') ; null tant qu'elles ne sont pas chargées.
  List<DeliveryZone>? _zones;
  // Commission Flooz / Mixx : 'restaurant' (absorbée) ou 'client' (ajoutée au prix).
  String _feesPaidBy = 'restaurant';
  final _perKm = TextEditingController();
  final _freeKm = TextEditingController();
  final _maxKm = TextEditingController();
  bool _loaded = false;
  bool _saving = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _fee, _min, _phone, _address, _cancelMinutes, _paymentFee, _autoConfirmHours, _perKm, _freeKm, _maxKm, //
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Zones de livraison (compteur et avertissement du mode « Par zone »).
  Future<void> _loadZones() async {
    try {
      final zones = await fetchDeliveryZones();
      if (mounted) setState(() => _zones = zones);
    } catch (_) {
      // Serveur sans zones ou hors ligne : compteur masqué.
    }
  }

  Future<void> _openZones() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DeliveryZonesScreen(restaurantLat: _lat, restaurantLng: _lng)),
    );
    if (mounted) _loadZones();
  }

  Future<void> _load() async {
    _loadAutoConfirm();
    _loadZones();
    try {
      final s = await Api.instance.settings();
      if (!mounted) return;
      setState(() {
        _fee.text = '${s.deliveryFee}';
        _min.text = '${s.minOrder}';
        _phone.text = s.restaurantPhone;
        _address.text = s.restaurantAddress;
        _manualOpen = s.manualOpen;
        _hoursEnabled = s.hoursEnabled;
        // Jours absents de la réponse : fermés ; aucun horaire enregistré : 10:00–22:00 partout.
        _hours = s.openingHours.isEmpty
            ? defaultOpeningHours()
            : {
                for (final d in AppSettings.weekDays)
                  d: [
                    for (final r in s.openingHours[d] ?? const <List<String>>[]) [...r],
                  ],
              };
        _feeMode = s.deliveryFeeMode;
        _feesPaidBy = s.paymentFeesPaidBy;
        _perKm.text = '${s.deliveryFeePerKm}';
        _freeKm.text = _km(s.deliveryFreeKm);
        _maxKm.text = _km(s.deliveryMaxKm);
        _cancelMinutes.text = '${s.momoUnpaidCancelMinutes}';
        _paymentFee.text = formatPercent(s.paymentFeePercentSettings ?? s.paymentFeePercent);
        _lat = s.restaurantLat;
        _lng = s.restaurantLng;
        _current = s;
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Lit le délai de confirmation automatique (valeur par défaut si le serveur ne l'expose pas).
  Future<void> _loadAutoConfirm() async {
    int hours;
    try {
      hours = await fetchDeliveryAutoConfirmHours();
    } catch (_) {
      hours = defaultDeliveryAutoConfirmHours;
    }
    if (!mounted) return;
    setState(() {
      _loadedAutoConfirmHours = hours;
      _autoConfirmHours.text = '$hours';
    });
  }

  Future<void> _save() async {
    final current = _current;
    if (current == null || !_formKey.currentState!.validate()) return;
    // Horaires : plages valides et sans chevauchement (seulement si les horaires automatiques sont actifs).
    if (_hoursEnabled) {
      for (final d in AppSettings.weekDays) {
        final err = openingRangesError(_hours[d] ?? const []);
        if (err != null) {
          showMessage(context, '${weekDayLabels[d]} : $err', error: true);
          return;
        }
      }
    }
    // Mode « Par zone » sans zone active : les livraisons seraient refusées.
    final zones = _zones;
    if (_feeMode == 'zone' && zones != null && !zones.any((z) => z.active)) {
      final ok = await confirmDialog(
        context,
        'Aucune zone active',
        'En mode « Par zone », les clients ne pourront pas commander en livraison tant qu\'aucune zone '
            'n\'est active. Enregistrer quand même ?',
        confirm: 'Enregistrer',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _saving = true);
    // Frais fixés par l'agrégateur : champ en lecture seule, valeur chargée renvoyée telle quelle
    // (AppSettings.toJson ne l'envoie pas au serveur dans ce cas).
    final feePercent = current.feesFromAggregator
        ? (current.paymentFeePercentSettings ?? current.paymentFeePercent)
        : _parsePercent(_paymentFee.text) ?? current.paymentFeePercent;
    try {
      // Champs non modifiés ici : copyWith renvoie les valeurs chargées pour ne pas les écraser
      // par les valeurs par défaut de AppSettings (ex. frais de paiement 2 %).
      await Api.instance.saveSettings(current.copyWith(
        // Champ masqué en mode « Par zone » : valeur chargée si la saisie est invalide.
        deliveryFee: int.tryParse(_fee.text.trim()) ?? current.deliveryFee,
        minOrder: int.parse(_min.text.trim()),
        manualOpen: _manualOpen,
        hoursEnabled: _hoursEnabled,
        openingHours: _sortedHours(),
        deliveryFeeMode: _feeMode,
        paymentFeesPaidBy: _feesPaidBy,
        // Champs « distance » masqués en prix fixe : valeurs chargées renvoyées telles quelles.
        deliveryFeePerKm: int.tryParse(_perKm.text.trim()) ?? current.deliveryFeePerKm,
        deliveryFreeKm: _parseKm(_freeKm.text) ?? current.deliveryFreeKm,
        deliveryMaxKm: _parseKm(_maxKm.text) ?? current.deliveryMaxKm,
        restaurantPhone: _phone.text.trim(),
        restaurantAddress: _address.text.trim(),
        // Position enregistrée à part (bouton « Placer sur la carte ») : renvoyée telle quelle.
        restaurantLat: _lat,
        restaurantLng: _lng,
        paymentFeePercent: feePercent,
        paymentFeePercentSettings: feePercent,
        momoUnpaidCancelMinutes: int.parse(_cancelMinutes.text.trim()),
      ));
      // Réglage absent de AppSettings : envoyé seul, uniquement s'il a changé.
      final hours = int.tryParse(_autoConfirmHours.text.trim());
      if (hours != null && hours != _loadedAutoConfirmHours) {
        await saveDeliveryAutoConfirmHours(hours);
        _loadedAutoConfirmHours = hours;
      }
      if (!mounted) return;
      showMessage(context, 'Paramètres enregistrés');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Ouvre la carte pour placer le restaurant, puis enregistre aussitôt la position.
  Future<void> _pickPosition() async {
    final loc = await Navigator.push<LocationData>(
      context,
      MaterialPageRoute(builder: (_) => GpsPickerScreen(initialLat: _lat, initialLng: _lng)),
    );
    if (loc == null || !mounted) return;
    final base = _current;
    if (base == null) return;

    // Adresse texte encore vide ou générique : proposer celle trouvée sur la carte.
    final found = loc.address?.trim() ?? '';
    final currentAddress = _address.text.trim();
    var replaceAddress = false;
    if (found.isNotEmpty && found != currentAddress && (currentAddress.isEmpty || currentAddress == 'Lomé, Togo')) {
      replaceAddress = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text("Mettre à jour l'adresse ?"),
              content: Text("Remplacer l'adresse du restaurant par :\n« $found »"),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Garder')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remplacer')),
              ],
            ),
          ) ??
          false;
      if (!mounted) return;
    }

    setState(() => _savingPosition = true);
    try {
      // Enregistre la position à partir des réglages chargés : les modifications du formulaire
      // non encore enregistrées restent à l'écran et partent avec « Enregistrer ».
      // (copyWith garde l'interrupteur manuel, les horaires et les frais au km tels quels.)
      final saved = await Api.instance.saveSettings(base.copyWith(
        restaurantAddress: replaceAddress ? found : base.restaurantAddress,
        restaurantLat: loc.lat,
        restaurantLng: loc.lng,
      ));
      if (!mounted) return;
      setState(() {
        _current = saved;
        _lat = saved.restaurantLat ?? loc.lat;
        _lng = saved.restaurantLng ?? loc.lng;
        _positionAddress = found.isEmpty ? null : found;
        if (replaceAddress) _address.text = found;
      });
      showMessage(context, 'Position du restaurant enregistrée');
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _savingPosition = false);
    }
  }

  /// Ligne « Position du restaurant » : état actuel + bouton vers la carte.
  Widget _positionTile() {
    final scheme = Theme.of(context).colorScheme;
    final lat = _lat;
    final lng = _lng;
    final defined = lat != null && lng != null;
    final address = _positionAddress ?? '';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: defined ? scheme.surfaceContainerHighest : AppColors.brand.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: defined ? null : Border.all(color: AppColors.brand.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(defined ? Icons.place : Icons.location_off_outlined,
                  color: defined ? AppColors.green : brandColor(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Position du restaurant',
                        style: TextStyle(fontWeight: FontWeight.w900, color: scheme.onSurface)),
                    const SizedBox(height: 4),
                    if (!defined)
                      Text("Non définie — les itinéraires de livraison ne s'afficheront pas",
                          style: TextStyle(color: scheme.onSurfaceVariant))
                    else ...[
                      if (address.isNotEmpty) Text(address, style: TextStyle(color: scheme.onSurface)),
                      Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: _savingPosition || _saving ? null : _pickPosition,
              icon: _savingPosition
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.map_outlined),
              label: const Text('Placer sur la carte'),
            ),
          ),
        ],
      ),
    );
  }

  static double? _parsePercent(String? v) => double.tryParse((v ?? '').trim().replaceAll(',', '.'));

  String? _amount(String? v) => int.tryParse(v?.trim() ?? '') == null ? 'Montant invalide' : null;

  /// Kilomètres saisis (virgule ou point), null si invalide.
  static double? _parseKm(String? v) => double.tryParse((v ?? '').trim().replaceAll(',', '.'));

  /// « 2 » plutôt que « 2.0 », « 2,5 » pour les décimales.
  static String _km(double v) => formatPercent(v);

  /// Horaires triés par heure de début (envoyés au serveur).
  Map<String, List<List<String>>> _sortedHours() => {
        for (final d in AppSettings.weekDays)
          d: [...(_hours[d] ?? const <List<String>>[])]
            ..sort((a, b) => (hhmmToMinutes(a[0]) ?? 0).compareTo(hhmmToMinutes(b[0]) ?? 0)),
      };

  /// État effectif enregistré : « Ouvert maintenant — ferme à 22:00 » / « Fermé — ouvre lundi à 10:00 ».
  Widget _openStateCard() {
    final s = _current!;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final String title;
    if (s.isOpen) {
      final closing = s.nextClosingAt;
      title = closing == null ? 'Ouvert maintenant' : 'Ouvert maintenant — ferme ${_when(closing)}';
    } else {
      final opening = s.nextOpeningAt;
      title = opening != null
          ? 'Fermé — ouvre ${_when(opening)}'
          : (!s.manualOpen ? "Fermé (interrupteur manuel)" : 'Fermé');
    }
    final color = s.isOpen ? (dark ? AppColors.darkTertiary : AppColors.green) : scheme.onSurfaceVariant;
    final dirty = _manualOpen != s.manualOpen ||
        _hoursEnabled != s.hoursEnabled ||
        (_hoursEnabled && _sortedHours().toString() != s.openingHours.toString());
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(s.isOpen ? Icons.storefront_rounded : Icons.door_front_door_outlined, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w900, color: scheme.onSurface)),
                if (dirty)
                  Text('Modifications pas encore enregistrées',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// « à 22:00 » (aujourd'hui), « demain à 10:00 » ou « lundi à 10:00 ».
  static String _when(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = DateTime(d.year, d.month, d.day).difference(today).inDays;
    final time = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (days <= 0) return 'à $time';
    // Fermeture à minuit (« 24:00 ») : affichée le jour même.
    if (days == 1 && d.hour == 0 && d.minute == 0) return 'à minuit';
    if (days == 1) return 'demain à $time';
    return '${frenchWeekday(d.weekday)} à $time';
  }

  /// Mode « Par zone » : nombre de zones, bouton de gestion, avertissement sans zone active.
  Widget _zonesCard() {
    final scheme = Theme.of(context).colorScheme;
    final zones = _zones;
    final active = zones?.where((z) => z.active).length ?? 0;
    final noneActive = zones != null && active == 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: noneActive ? AppColors.brand.withValues(alpha: 0.08) : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: noneActive ? Border.all(color: AppColors.brand.withValues(alpha: 0.35)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Le client choisit son quartier (ou il est reconnu par sa position) et paie le prix de la zone.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          if (noneActive) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: brandColor(context), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Aucune zone active : les commandes en livraison seront refusées.',
                    style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          ] else if (zones != null) ...[
            const SizedBox(height: 6),
            Text(
              '$active zone${active > 1 ? 's' : ''} active${active > 1 ? 's' : ''} sur ${zones.length}',
              style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: _openZones,
              icon: const Icon(Icons.map_rounded),
              label: Text(zones == null ? 'Gérer les zones' : 'Gérer les zones (${zones.length})'),
            ),
          ),
        ],
      ),
    );
  }

  /// Frais de livraison : prix fixe, selon la distance (base + prix par km au-delà des km inclus) ou par zone.
  List<Widget> _deliveryFeeFields() {
    final scheme = Theme.of(context).colorScheme;
    final byDistance = _feeMode == 'distance';
    void refresh(String _) => setState(() {});
    return [
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'fixed', label: Text('Prix fixe', textAlign: TextAlign.center)),
          ButtonSegment(value: 'distance', label: Text('Selon la distance', textAlign: TextAlign.center)),
          ButtonSegment(value: 'zone', label: Text('Par zone', textAlign: TextAlign.center)),
        ],
        selected: {_feeMode},
        onSelectionChanged: (v) => setState(() => _feeMode = v.first),
      ),
      const SizedBox(height: 14),
      if (_feeMode == 'zone')
        _zonesCard()
      else
      TextFormField(
        controller: _fee,
        keyboardType: TextInputType.number,
        onChanged: refresh,
        decoration: InputDecoration(
          labelText: byDistance ? 'Prix de base' : 'Frais de livraison',
          helperText: byDistance ? 'Comprend les premiers kilomètres (km inclus)' : 'Même prix pour toutes les adresses',
          suffixText: 'FCFA',
        ),
        validator: _amount,
      ),
      if (byDistance) ...[
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                controller: _freeKm,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: refresh,
                decoration: const InputDecoration(labelText: 'Km inclus', suffixText: 'km'),
                validator: (v) {
                  final n = _parseKm(v);
                  return n == null || n < 0 || n > 100 ? 'Entre 0 et 100' : null;
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _perKm,
                keyboardType: TextInputType.number,
                onChanged: refresh,
                decoration: const InputDecoration(labelText: 'Prix par km', suffixText: 'FCFA'),
                validator: (v) {
                  final n = int.tryParse(v?.trim() ?? '');
                  return n == null || n < 0 || n > 50000 ? 'Entre 0 et 50 000' : null;
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        TextFormField(
          controller: _maxKm,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: refresh,
          decoration: const InputDecoration(
            labelText: 'Distance maximale',
            helperText: '0 = illimitée. Au-delà, la commande en livraison est refusée.',
            helperMaxLines: 2,
            suffixText: 'km',
          ),
          validator: (v) {
            final n = _parseKm(v);
            return n == null || n < 0 || n > 200 ? 'Entre 0 et 200' : null;
          },
        ),
        const SizedBox(height: 12),
        _feeExamples(scheme),
      ],
    ];
  }

  /// Exemples calculés en direct : « 5 km → 1 600 FCFA ».
  Widget _feeExamples(ColorScheme scheme) {
    final base = int.tryParse(_fee.text.trim());
    final perKm = int.tryParse(_perKm.text.trim());
    final freeKm = _parseKm(_freeKm.text);
    final maxKm = _parseKm(_maxKm.text) ?? 0;
    final valid = base != null && perKm != null && freeKm != null;
    const samples = [2.0, 5.0, 8.0, 12.0];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calculate_outlined, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Exemples', style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface)),
            ],
          ),
          const SizedBox(height: 6),
          if (!valid)
            Text('Renseignez le prix de base, les km inclus et le prix par km.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13))
          else
            for (final km in samples)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  maxKm > 0 && km > maxKm
                      ? '${_km(km)} km → hors zone (maximum ${_km(maxKm)} km)'
                      : '${_km(km)} km → ${formatPrice(estimateDeliveryFee(base: base, perKm: perKm, freeKm: freeKm, km: km))}',
                  style: TextStyle(color: scheme.onSurface, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
          const SizedBox(height: 6),
          Text(
            'Distance estimée par le serveur (trajet ≈ 1,3 × la distance à vol d\'oiseau), '
            'arrondie aux 50 FCFA supérieurs.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres')),
      body: !_loaded
          ? (_error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : const Center(child: CircularProgressIndicator()))
          : Form(
              key: _formKey,
              child: ListView(
                // Tablette : formulaire centré, largeur limitée (téléphone : marges inchangées).
                padding: EdgeInsets.symmetric(
                  vertical: 20,
                  horizontal: MediaQuery.sizeOf(context).width > 800 ? (MediaQuery.sizeOf(context).width - 760) / 2 : 20,
                ),
                children: [
                  _openStateCard(),
                  const SizedBox(height: 12),
                  Card(
                    color: _manualOpen
                        ? AppColors.green.withValues(alpha: 0.12)
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: SwitchListTile(
                      value: _manualOpen,
                      activeTrackColor: AppColors.green,
                      onChanged: (v) => setState(() => _manualOpen = v),
                      title: const Text('Ouvert (interrupteur manuel)', style: TextStyle(fontWeight: FontWeight.w900)),
                      subtitle: Text(_manualOpen
                          ? (_hoursEnabled
                              ? 'Les clients peuvent commander pendant les horaires d\'ouverture'
                              : 'Les clients peuvent commander')
                          : 'Fermé quoi qu\'il arrive : les nouvelles commandes sont bloquées'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text("Horaires d'ouverture", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 8),
                  Card(
                    child: SwitchListTile(
                      value: _hoursEnabled,
                      activeTrackColor: AppColors.green,
                      onChanged: (v) => setState(() => _hoursEnabled = v),
                      title: const Text('Horaires automatiques', style: TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text(_hoursEnabled
                          ? 'Le restaurant ouvre et ferme tout seul selon les horaires ci-dessous (heure de Lomé)'
                          : "Désactivé : seul l'interrupteur manuel compte"),
                    ),
                  ),
                  if (_hoursEnabled) ...[
                    const SizedBox(height: 8),
                    OpeningHoursEditor(
                      hours: _hours,
                      onChanged: (h) => setState(() => _hours = h),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const Text('Restaurant', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _min,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Montant minimum de commande', suffixText: 'FCFA'),
                    validator: _amount,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Téléphone du restaurant'),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _address,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Adresse du restaurant'),
                  ),
                  const SizedBox(height: 14),
                  _positionTile(),
                  const SizedBox(height: 24),
                  const Text('Livraison', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 12),
                  ..._deliveryFeeFields(),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _autoConfirmHours,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Confirmation automatique de la réception après',
                      helperText: 'Si le client ne confirme pas « Reçu » après « Livraison faite » du livreur, '
                          'la commande est terminée automatiquement. Entre 1 et 72 heures.',
                      helperMaxLines: 3,
                      suffixText: 'h',
                    ),
                    validator: (v) {
                      final n = int.tryParse(v?.trim() ?? '');
                      if (n == null || n < 1 || n > 72) return 'Entre 1 et 72 heures';
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),
                  const Text('Paiement mobile money', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 12),
                  _paymentFeeField(),
                  const SizedBox(height: 16),
                  _feesPaidBySection(),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _cancelMinutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Annulation auto des commandes mobile money non payées',
                      helperText: 'Délai en minutes, entre 5 et 1440 (24 h)',
                      helperMaxLines: 2,
                      suffixText: 'min',
                    ),
                    validator: (v) {
                      final n = int.tryParse(v?.trim() ?? '');
                      if (n == null || n < 5 || n > 1440) return 'Entre 5 et 1440 minutes';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  _MerchantCard(future: _merchant),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _saving || _savingPosition ? null : _save,
                    child: _saving
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Text('Enregistrer'),
                  ),
                ],
              ),
            ),
    );
  }

  // ---------- Commission Flooz / Mixx : absorbée par le restaurant ou ajoutée au prix ----------

  /// Taux Flooz affiché dans l'exemple : celui de l'agrégateur, sinon la saisie en cours.
  double get _examplePercent {
    final s = _current;
    if (s == null) return 0;
    if (s.feesFromAggregator) return s.feePercentFor('flooz');
    return _parsePercent(_paymentFee.text) ?? s.feePercentFor('flooz');
  }

  Widget _feesPaidBySection() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectedColor = theme.brightness == Brightness.dark ? scheme.primary : AppColors.brand;

    Widget option(String value, String title, String subtitle) {
      final selected = _feesPaidBy == value;
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? selectedColor : scheme.outlineVariant, width: selected ? 2 : 1),
        ),
        child: ListTile(
          onTap: () => setState(() => _feesPaidBy = value),
          leading: Icon(
            selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
            color: selected ? selectedColor : scheme.onSurfaceVariant,
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(subtitle),
        ),
      );
    }

    const amount = 21000;
    final p = _examplePercent;
    final restaurantReceives = amount - providerFeeOn(amount, p);
    final clientPays = paymentGrossFor(amount, p);
    final restaurantPays = _feesPaidBy != 'client';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Commission Flooz / Mixx', style: TextStyle(fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text(
          "L'agrégateur prélève une commission sur chaque paiement mobile money. Choisissez qui la paie.",
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 10),
        option(
          'restaurant',
          'Payée par le restaurant',
          'Le client paie le prix affiché ; la commission est déduite de ce que reçoit le restaurant.',
        ),
        option(
          'client',
          'Ajoutée au prix payé par le client',
          'Le client paie la commission en plus ; le restaurant reçoit le montant de la commande + livraison.',
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.calculate_outlined, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  restaurantPays
                      ? 'Exemple : commande de ${formatPrice(amount)} payée en Flooz (${formatPercent(p)} %) → '
                          'le client paie ${formatPrice(amount)}, le restaurant reçoit ${formatPrice(restaurantReceives)}.'
                      : 'Exemple : commande de ${formatPrice(amount)} payée en Flooz (${formatPercent(p)} %) → '
                          'le client paie ${formatPrice(clientPays)}, le restaurant reçoit ${formatPrice(amount)}.',
                  style: TextStyle(color: scheme.onSurface, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Frais de paiement : modifiables (réglage admin) ou informatifs s'ils sont fixés par l'agrégateur.
  Widget _paymentFeeField() {
    final s = _current;
    if (s != null && s.feesFromAggregator) {
      final scheme = Theme.of(context).colorScheme;
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline_rounded, color: scheme.onSurfaceVariant, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Frais de paiement', style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface)),
                  const SizedBox(height: 4),
                  Text(
                    "Fixés par l'agrégateur : Flooz ${formatPercent(s.feePercentFor('flooz'))} %, "
                    "Mixx ${formatPercent(s.feePercentFor('mixx'))} %. Qui les paie : voir ci-dessous.",
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.3),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return TextFormField(
      controller: _paymentFee,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => setState(() {}), // exemple chiffré en direct
      decoration: const InputDecoration(
        labelText: 'Commission mobile money (taux)',
        helperText: "Entre 0 et 10 %. À remplacer par la commission de l'agrégateur dès qu'elle est configurée.",
        helperMaxLines: 2,
        suffixText: '%',
      ),
      validator: (v) {
        final p = _parsePercent(v);
        if (p == null || p < 0 || p > 10) return 'Entre 0 et 10 %';
        return null;
      },
    );
  }
}

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  late Future<List<CustomerSummary>> _future = Api.instance.users();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Clients')),
      body: FutureBuilder<List<CustomerSummary>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorRetry(
              error: snap.error!,
              onRetry: () => setState(() => _future = Api.instance.users()),
            );
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final q = _query.toLowerCase();
          final users = snap.data!
              .where((c) => !c.user.isAdmin)
              .where((c) => q.isEmpty || c.user.name.toLowerCase().contains(q) || c.user.phone.contains(q))
              .toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: const InputDecoration(
                    hintText: 'Rechercher un client...',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              Expanded(
                child: users.isEmpty
                    ? const EmptyState(emoji: '👥', title: 'Aucun client')
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                        itemCount: users.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          final c = users[i];
                          return Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: AppColors.accent,
                                child: Text(
                                  c.user.name.isEmpty ? '?' : c.user.name[0].toUpperCase(),
                                  style: const TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ),
                              title: Text(c.user.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                              subtitle: Text(
                                '${c.user.phone}\n${c.ordersCount} commande${c.ordersCount > 1 ? 's' : ''} • '
                                '${formatPrice(c.totalSpent)}',
                              ),
                              isThreeLine: true,
                              trailing: IconButton(
                                icon: const Icon(Icons.call_rounded, color: AppColors.green),
                                onPressed: () =>
                                    launchUrl(Uri(scheme: 'tel', path: c.user.phone.replaceAll(' ', ''))),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Compte marchand mobile money, en lecture seule (numéros masqués côté serveur).
class _MerchantCard extends StatelessWidget {
  final Future<MerchantInfo> future;
  const _MerchantCard({required this.future});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<MerchantInfo>(
          future: future,
          builder: (context, snap) {
            final header = Row(
              children: [
                Icon(Icons.store_mall_directory_rounded, color: brandColor(context)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Compte marchand',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: cs.onSurface)),
                ),
                Icon(Icons.lock_outline_rounded, size: 18, color: cs.onSurfaceVariant),
              ],
            );
            if (snap.hasError) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  header,
                  const SizedBox(height: 10),
                  Text('Informations indisponibles : ${snap.error}', style: TextStyle(color: cs.error)),
                ],
              );
            }
            final m = snap.data;
            if (m == null) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  header,
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                ],
              );
            }
            Widget row(String label, String? value) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(label, style: TextStyle(color: cs.onSurfaceVariant)),
                      ),
                      Expanded(
                        child: Text(
                          (value ?? '').isEmpty ? 'Non configuré' : value!,
                          style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface),
                        ),
                      ),
                    ],
                  ),
                );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                const SizedBox(height: 4),
                row('Prestataire', providerLabel(m.provider)),
                row('Nom affiché', m.displayName),
                row('Flooz', m.flooz),
                row('Mixx', m.mixx),
                if (m.settlement.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Reversement', style: TextStyle(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Text(m.settlement, style: TextStyle(color: cs.onSurface)),
                ],
                const SizedBox(height: 10),
                Text(
                  'Ces informations se modifient côté serveur (variables d\'environnement), pas depuis l\'application.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
