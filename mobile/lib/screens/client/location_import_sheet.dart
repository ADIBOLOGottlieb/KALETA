import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../services/geo_service.dart';
import '../../services/maps_link.dart';
import '../../services/shared_location.dart';
import '../../theme.dart';
import '../../widgets/route_map.dart';
import 'gps_picker_screen.dart';

int _openSheets = 0;

/// Vrai tant qu'une feuille « Choisir ma position » est ouverte : elle traite elle-même
/// les positions partagées depuis Google Maps (les autres écrans doivent alors les ignorer).
bool get isLocationImportSheetOpen => _openSheets > 0;

/// Adresse lisible d'une position importée : nom du lieu + adresse partagés par Google Maps.
String? importedAddressText(ImportedLocation loc) {
  final parts = <String>[];
  final label = loc.label?.trim() ?? '';
  final address = loc.address?.trim() ?? '';
  if (label.isNotEmpty) parts.add(label);
  if (address.isNotEmpty && address != label) parts.add(address);
  return parts.isEmpty ? null : parts.join(', ');
}

/// Adresse d'une position importée : celle de Google Maps si présente, sinon Nominatim (gratuit).
Future<String?> resolveImportedAddress(ImportedLocation loc) async {
  final address = loc.address?.trim() ?? '';
  if (address.isNotEmpty) return importedAddressText(loc);
  String? found;
  try {
    found = await GeoService.instance.reverse(loc.lat, loc.lng);
  } catch (_) {
    found = null;
  }
  final label = loc.label?.trim() ?? '';
  final f = found?.trim() ?? '';
  if (label.isNotEmpty && f.isNotEmpty && !f.startsWith(label)) return '$label, $f';
  if (f.isNotEmpty) return f;
  return label.isEmpty ? null : label;
}

/// Feuille du bas « Choisir ma position » : Google Maps (partage ou lien copié), saisie d'un
/// lien / de coordonnées / d'un plus code, ou GPS du téléphone. Aucune API Google payante :
/// l'aperçu utilise OpenStreetMap. Renvoie la position confirmée, ou null si le client ferme.
Future<LocationData?> showLocationImportSheet(BuildContext context, {double? initialLat, double? initialLng}) async {
  _openSheets++;
  try {
    return await showModalBottomSheet<LocationData>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => _LocationImportSheet(initialLat: initialLat, initialLng: initialLng),
    );
  } finally {
    _openSheets--;
  }
}

class _LocationImportSheet extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;

  const _LocationImportSheet({this.initialLat, this.initialLng});

  @override
  State<_LocationImportSheet> createState() => _LocationImportSheetState();
}

class _LocationImportSheetState extends State<_LocationImportSheet> {
  final _shared = SharedLocationService.instance;
  final _input = TextEditingController();
  late final AppLifecycleListener _lifecycle;

  bool _openedMaps = false;
  bool _mapsFailed = false;
  bool _parsing = false;
  String? _inputError;
  String? _clipText; // lien détecté dans le presse-papiers
  String? _ignoredClip; // lien déjà proposé / utilisé

  // Étape de confirmation.
  ImportedLocation? _candidate;
  String? _candidateAddress;
  bool _addressLoading = false;
  int _addressSeq = 0;

  AppSettings? _settings;

  @override
  void initState() {
    super.initState();
    _shared.pending.addListener(_onPending);
    _shared.resolving.addListener(_onResolving);
    _shared.failure.addListener(_onFailure);
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    _loadSettings();
    // Une position partagée attendait déjà : on la propose tout de suite.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPending());
  }

  @override
  void dispose() {
    _shared.pending.removeListener(_onPending);
    _shared.resolving.removeListener(_onResolving);
    _shared.failure.removeListener(_onFailure);
    _lifecycle.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final s = await Api.instance.settings();
      if (mounted) setState(() => _settings = s);
    } catch (_) {
      // Sans la position du restaurant : simple carte avec le marqueur.
    }
  }

  void _onPending() {
    if (!mounted || _shared.pending.value == null) return;
    final loc = _shared.consume();
    if (loc != null) _showCandidate(loc);
  }

  void _onResolving() {
    if (mounted) setState(() {});
  }

  /// Partage reçu mais illisible : on l'explique dans la feuille.
  void _onFailure() {
    final message = _shared.failure.value;
    if (mounted && message != null && _candidate == null) setState(() => _inputError = message);
  }

  Future<void> _onResume() async {
    if (!_openedMaps || !mounted) return;
    // Laisse le temps à un éventuel partage d'arriver avant de regarder le presse-papiers.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted || _candidate != null || _shared.resolving.value) return;
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    } catch (_) {
      text = null;
    }
    if (!mounted || text == null || text.isEmpty || text == _ignoredClip) return;
    if (looksLikeLocationText(text)) setState(() => _clipText = text);
  }

  Future<void> _openMaps() async {
    final lat = _candidate?.lat ?? widget.initialLat;
    final lng = _candidate?.lng ?? widget.initialLng;
    var ok = false;
    try {
      ok = await openGoogleMapsForPicking(lat: lat, lng: lng);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _mapsFailed = !ok;
      if (ok) _openedMaps = true;
    });
  }

  Future<void> _parse(String text, {bool fromClipboard = false}) async {
    final t = text.trim();
    if (t.isEmpty) {
      setState(() => _inputError = 'Collez d\'abord un lien Google Maps, des coordonnées ou un plus code.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _parsing = true;
      _inputError = null;
    });
    final loc = await parseLocationText(t);
    if (!mounted) return;
    setState(() => _parsing = false);
    if (loc == null) {
      setState(() {
        if (fromClipboard) {
          _ignoredClip = t;
          _clipText = null;
        }
        _inputError = 'Position introuvable dans ce texte. Vérifiez votre connexion, ou collez le lien '
            '« Partager » de Google Maps, des coordonnées (ex. 6.1319, 1.2228) ou un plus code (ex. 6CJ8+X7 Lomé).';
      });
      return;
    }
    if (fromClipboard) _ignoredClip = t;
    _showCandidate(loc);
  }

  Future<void> _paste() async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    } catch (_) {
      text = null;
    }
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      setState(() => _inputError = 'Le presse-papiers est vide. Dans Google Maps, touchez « Partager » puis « Copier ».');
      return;
    }
    setState(() {
      _input.text = text!;
      _inputError = null;
    });
  }

  void _showCandidate(ImportedLocation loc) {
    final seq = ++_addressSeq;
    final shared = (loc.address?.trim() ?? '').isNotEmpty;
    setState(() {
      _candidate = loc;
      _clipText = null;
      _inputError = null;
      _candidateAddress = shared ? importedAddressText(loc) : null;
      _addressLoading = !shared;
    });
    if (shared) return;
    resolveImportedAddress(loc).then((a) {
      if (!mounted || seq != _addressSeq) return;
      setState(() {
        _candidateAddress = a;
        _addressLoading = false;
      });
    });
  }

  Future<void> _useGps() async {
    final loc = await Navigator.push<LocationData>(
      context,
      MaterialPageRoute(builder: (_) => GpsPickerScreen(initialLat: widget.initialLat, initialLng: widget.initialLng)),
    );
    if (loc != null && mounted) Navigator.pop(context, loc);
  }

  Future<void> _adjust() async {
    final c = _candidate;
    if (c == null) return;
    final loc = await Navigator.push<LocationData>(
      context,
      MaterialPageRoute(builder: (_) => GpsPickerScreen(initialLat: c.lat, initialLng: c.lng)),
    );
    if (loc == null || !mounted) return;
    // Garde le nom du lieu partagé si la carte n'a pas trouvé d'adresse.
    final address = (loc.address?.trim() ?? '').isNotEmpty ? loc.address : _candidateAddress;
    Navigator.pop(
      context,
      LocationData(lat: loc.lat, lng: loc.lng, accuracy: loc.accuracy, address: address, liveMinutes: loc.liveMinutes),
    );
  }

  void _confirm() {
    final c = _candidate;
    if (c == null) return;
    Navigator.pop(context, LocationData(lat: c.lat, lng: c.lng, accuracy: null, address: _candidateAddress));
  }

  void _back() {
    _addressSeq++;
    setState(() {
      _candidate = null;
      _candidateAddress = null;
      _addressLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.only(bottom: bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: _candidate != null ? _buildConfirm(context) : _buildChoose(context),
      ),
    );
  }

  // ---------------------------------------------------------------- Choix

  Widget _buildChoose(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final busy = _parsing || _shared.resolving.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Où vous livrer ?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text(
          'Envoyez votre position comme sur WhatsApp, ou choisissez votre maison dans Google Maps.',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        // Comme WhatsApp : « Position » → en direct, position actuelle ou point sur la carte.
        Material(
          color: AppColors.green.withValues(alpha: 0.12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: AppColors.green.withValues(alpha: 0.5)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: busy ? null : _useGps,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.green),
                    child: const Icon(Icons.share_location_rounded, color: Colors.white, size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Envoyer ma position',
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: cs.onSurface)),
                        const SizedBox(height: 2),
                        Text(
                          'En direct (le livreur vous suit) ou position actuelle',
                          style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (busy) ...[
          _BusyCard(text: _parsing ? 'Lecture de la position…' : 'Lecture de la position reçue de Google Maps…'),
          const SizedBox(height: 16),
        ],
        if (_clipText != null && !busy) ...[
          _ClipboardCard(
            text: _clipText!,
            onUse: () => _parse(_clipText!, fromClipboard: true),
            onDismiss: () => setState(() {
              _ignoredClip = _clipText;
              _clipText = null;
            }),
          ),
          const SizedBox(height: 16),
        ],
        FilledButton.icon(
          onPressed: busy ? null : _openMaps,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(60),
            textStyle: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          icon: const Icon(Icons.map_rounded, size: 26),
          label: const Text('Choisir ma position dans Google Maps'),
        ),
        if (_mapsFailed) ...[
          const SizedBox(height: 8),
          Text(
            'Google Maps ne s\'ouvre pas sur ce téléphone. Installez ou mettez à jour Google Maps, '
            'ou utilisez votre position GPS ci-dessous.',
            style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
        const SizedBox(height: 14),
        const _Step(
          number: 1,
          icon: Icons.touch_app_rounded,
          text: 'Appuyez longuement sur votre maison pour poser un repère',
        ),
        const _Step(number: 2, icon: Icons.share_rounded, text: 'Touchez Partager'),
        const _Step(number: 3, icon: Icons.fastfood_rounded, text: 'Choisissez KALETA'),
        if (_openedMaps)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'KALETA n\'apparaît pas ? Touchez « Copier le lien » dans Google Maps puis revenez ici.',
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 18),
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('ou', style: TextStyle(color: cs.onSurfaceVariant)),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _input,
          minLines: 1,
          maxLines: 3,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          onSubmitted: busy ? null : (v) => _parse(v),
          onChanged: (_) {
            if (_inputError != null) setState(() => _inputError = null);
          },
          decoration: InputDecoration(
            labelText: 'Ou collez un lien Google Maps, des coordonnées ou un plus code',
            hintText: 'ex. https://maps.app.goo.gl/…, 6.1319, 1.2228 ou 6CJ8+X7 Lomé',
            prefixIcon: const Icon(Icons.link_rounded),
            errorText: _inputError,
            errorMaxLines: 4,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : _paste,
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                icon: const Icon(Icons.content_paste_rounded),
                label: const Text('Coller'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: busy ? null : () => _parse(_input.text),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Valider'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- Confirmation

  Widget _buildConfirm(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = _candidate!;
    final point = LatLng(c.lat, c.lng);
    final s = _settings;
    final restaurant = s != null && s.restaurantLat != null && s.restaurantLng != null
        ? LatLng(s.restaurantLat!, s.restaurantLng!)
        : null;
    final sourceText = switch (c.source) {
      'google_maps' => 'Position reçue de Google Maps',
      'plus_code' => 'Position du plus code',
      _ => 'Position des coordonnées',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Retour',
              onPressed: _back,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 4),
            const Expanded(
              child: Text('Est-ce bien ici ?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Row(
            children: [
              const Icon(Icons.check_circle_rounded, size: 18, color: AppColors.green),
              const SizedBox(width: 6),
              Expanded(
                child: Text(sourceText, style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        if (restaurant != null)
          RouteMap(
            key: ValueKey('${c.lat},${c.lng}'),
            from: restaurant,
            to: point,
            height: 200,
            fromLabel: s!.restaurantAddress.trim().isEmpty ? null : s.restaurantAddress,
          )
        else
          _PointMap(key: ValueKey('${c.lat},${c.lng}'), point: point),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.location_on_rounded, color: brandColor(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_addressLoading)
                      Row(
                        children: [
                          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 8),
                          Text('Recherche de l\'adresse…', style: TextStyle(color: cs.onSurfaceVariant)),
                        ],
                      )
                    else
                      Text(
                        _candidateAddress ?? 'Adresse inconnue : vous pourrez préciser un repère à la commande.',
                        style: TextStyle(
                          fontWeight: _candidateAddress != null ? FontWeight.w700 : FontWeight.w400,
                          color: _candidateAddress != null ? cs.onSurface : cs.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      '${c.lat.toStringAsFixed(5)}, ${c.lng.toStringAsFixed(5)}',
                      style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _addressLoading ? null : _confirm,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          icon: const Icon(Icons.check_rounded),
          label: const Text('Confirmer cette position'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _adjust,
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.edit_location_alt_rounded),
          label: const Text('Ajuster sur la carte'),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _back,
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: const Text('Choisir une autre position'),
        ),
      ],
    );
  }
}

/// Petite carte OpenStreetMap centrée sur le point choisi (sans itinéraire).
class _PointMap extends StatelessWidget {
  final LatLng point;

  const _PointMap({required this.point, super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 200,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: point,
            initialZoom: 16,
            minZoom: 5,
            maxZoom: 19,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.pinchZoom | InteractiveFlag.pinchMove | InteractiveFlag.doubleTapZoom,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: GeoService.osmTileUrl,
              maxNativeZoom: 19,
              userAgentPackageName: GeoService.tileUserAgentPackage,
            ),
            MarkerLayer(markers: [deliveryMarker(point)]),
            SimpleAttributionWidget(
              source: const Text('OpenStreetMap', style: TextStyle(fontSize: 10.5)),
              backgroundColor: Colors.white.withValues(alpha: 0.8),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int number;
  final IconData icon;
  final String text;

  const _Step({required this.number, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.brand.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: brandColor(context)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: '$number. ', style: TextStyle(fontWeight: FontWeight.w900, color: brandColor(context))),
                TextSpan(text: text),
              ]),
              style: TextStyle(fontSize: 14.5, color: cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

class _BusyCard extends StatelessWidget {
  final String text;

  const _BusyCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }
}

class _ClipboardCard extends StatelessWidget {
  final String text;
  final VoidCallback onUse;
  final VoidCallback onDismiss;

  const _ClipboardCard({required this.text, required this.onUse, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
      decoration: BoxDecoration(
        color: AppColors.green.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.green.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.link_rounded, color: AppColors.green),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Lien Google Maps détecté', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
              IconButton(
                tooltip: 'Ignorer',
                onPressed: onDismiss,
                icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: onUse,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.green,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(50),
              ),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Utiliser cette position'),
            ),
          ),
        ],
      ),
    );
  }
}
