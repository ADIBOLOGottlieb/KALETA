import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../services/geo_service.dart';
import '../theme.dart';

/// Tracé d'un itinéraire : trait rouge épais avec contour clair (lisible sur tous les fonds).
/// [fallback] : ligne droite en pointillés quand l'itinéraire est indisponible.
Polyline routePolyline(List<LatLng> points, {bool fallback = false}) {
  if (fallback) {
    return Polyline(
      points: points,
      strokeWidth: 3.5,
      color: AppColors.brand.withValues(alpha: 0.75),
      borderStrokeWidth: 1.5,
      borderColor: Colors.white.withValues(alpha: 0.85),
      pattern: StrokePattern.dashed(segments: const [10, 8]),
    );
  }
  return Polyline(
    points: points,
    strokeWidth: 5,
    color: AppColors.brand,
    borderStrokeWidth: 2.5,
    borderColor: Colors.white.withValues(alpha: 0.9),
  );
}

/// Marqueur du restaurant (pastille avec vitrine rouge).
Marker restaurantMarker(LatLng point) => Marker(point: point, width: 38, height: 38, child: const RestaurantPin());

/// Marqueur du point de livraison (épingle dont la pointe désigne le point).
Marker deliveryMarker(LatLng point) => Marker(
  point: point,
  width: 40,
  height: 40,
  alignment: Alignment.topCenter,
  child: const Icon(Icons.location_on_rounded, size: 40, color: AppColors.danger),
);

/// Marqueur du client qui partage sa position en direct (comme WhatsApp) : point vert pulsant.
Marker customerLiveMarker(LatLng point, {bool stale = false}) => Marker(
  point: point,
  width: 64,
  height: 64,
  child: CustomerLivePin(stale: stale),
);

/// Point vert entouré d'ondes : « position en direct » du client.
class CustomerLivePin extends StatefulWidget {
  final bool stale;
  const CustomerLivePin({super.key, this.stale = false});

  @override
  State<CustomerLivePin> createState() => _CustomerLivePinState();
}

class _CustomerLivePinState extends State<CustomerLivePin> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.stale ? const Color(0xFF8A7C77) : AppColors.green;
    return Semantics(
      label: 'Position en direct du client',
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, child) => Stack(
          alignment: Alignment.center,
          children: [
            if (!widget.stale)
              Container(
                width: 22 + 42 * _c.value,
                height: 22 + 42 * _c.value,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.4 * (1 - _c.value))),
              ),
            child!,
          ],
        ),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 5)],
          ),
          child: const Icon(Icons.person_rounded, size: 14, color: Colors.white),
        ),
      ),
    );
  }
}

/// Marqueur du livreur (suivi en direct), centré sur sa position.
Marker driverMarker(LatLng point, {double? heading, bool stale = false}) => Marker(
  point: point,
  width: 56,
  height: 56,
  child: DriverPin(heading: heading, stale: stale),
);

/// Scooter dans un cercle rouge ; une flèche autour indique le sens de la marche (cap GPS).
class DriverPin extends StatelessWidget {
  /// Cap en degrés (0 = nord), null si inconnu (livreur à l'arrêt).
  final double? heading;

  /// Dernière position ancienne : marqueur atténué.
  final bool stale;

  const DriverPin({super.key, this.heading, this.stale = false});

  @override
  Widget build(BuildContext context) {
    final color = stale ? const Color(0xFF8A7C77) : AppColors.brand;
    return Semantics(
      label: 'Position du livreur',
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Halo : le livreur reste repérable sur tous les fonds de carte.
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.18)),
          ),
          if (heading != null)
            Transform.rotate(
              angle: heading! * math.pi / 180,
              child: SizedBox(
                width: 56,
                height: 56,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Icon(
                    Icons.navigation_rounded,
                    size: 18,
                    color: color,
                    shadows: const [Shadow(color: Colors.white, blurRadius: 3)],
                  ),
                ),
              ),
            ),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 5, offset: const Offset(0, 2)),
              ],
            ),
            child: const Center(child: Icon(Icons.delivery_dining_rounded, size: 22, color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class RestaurantPin extends StatelessWidget {
  const RestaurantPin({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.brand, width: 2.5),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4)],
      ),
      child: const Center(child: Icon(Icons.storefront_rounded, size: 20, color: AppColors.brand)),
    );
  }
}

/// Lien Google Maps « itinéraire » de [from] à [to].
Uri googleMapsDirectionsUri(LatLng from, LatLng to) => Uri.parse(
  'https://www.google.com/maps/dir/?api=1'
  '&origin=${from.latitude.toStringAsFixed(6)},${from.longitude.toStringAsFixed(6)}'
  '&destination=${to.latitude.toStringAsFixed(6)},${to.longitude.toStringAsFixed(6)}'
  '&travelmode=driving',
);

/// Petite carte d'itinéraire (restaurant → livraison) à placer dans une page qui défile :
/// un doigt fait défiler la page, deux doigts déplacent / zooment la carte.
class RouteMap extends StatefulWidget {
  final LatLng from;
  final LatLng to;
  final double height;
  final String? fromLabel;
  final String? toLabel;

  /// Position du livreur (suivi en direct) : scooter animé, carte cadrée sur le livreur et le client.
  final DriverLocation? driver;

  /// Position en direct du client (partage façon WhatsApp) : marqueur pulsant, itinéraire jusqu'à lui.
  final DriverLocation? customer;

  const RouteMap({
    required this.from,
    required this.to,
    this.height = 220,
    this.fromLabel,
    this.toLabel,
    this.driver,
    this.customer,
    super.key,
  });

  @override
  State<RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<RouteMap> with SingleTickerProviderStateMixin {
  final _geo = GeoService.instance;
  final _map = MapController();
  bool _mapReady = false;

  // Livreur : le marqueur glisse en ~1 s de l'ancienne position vers la nouvelle.
  late final AnimationController _move = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
  late final Animation<double> _moveCurve = CurvedAnimation(parent: _move, curve: Curves.easeInOut);
  LatLng? _driverFrom;
  LatLng? _driverTo;
  double? _headingFrom;
  double? _headingTo;

  /// L'utilisateur a déplacé / zoomé la carte : on ne recadre plus tout seul (bouton « Recentrer »).
  bool _userMoved = false;

  RouteResult? _route;

  /// Client en direct : point de destination de l'itinéraire, mis à jour seulement après 60 m de
  /// déplacement (pas un calcul d'itinéraire à chaque envoi de position).
  LatLng? _customerAnchor;
  static const _anchorMeters = 60.0;
  LatLng? get _customerPoint => widget.customer == null ? null : LatLng(widget.customer!.lat, widget.customer!.lng);
  LatLng get _to => _customerAnchor ?? widget.to;
  bool _loading = true;
  int _seq = 0;

  TileSession? _tileSession;
  int _googleTileErrors = 0;
  String? _googleCopyright;

  @override
  void initState() {
    super.initState();
    final d = widget.driver;
    if (d != null) {
      _driverFrom = _driverTo = LatLng(d.lat, d.lng);
      _headingFrom = _headingTo = d.heading;
    }
    _customerAnchor = _customerPoint;
    _initTiles();
    _loadRoute();
  }

  /// Le client en direct s'est assez déplacé (ou a commencé / arrêté le partage) : nouvel itinéraire.
  bool _moveCustomerAnchor() {
    final p = _customerPoint;
    final a = _customerAnchor;
    if (p == null && a == null) return false;
    if (p == null || a == null || const Distance().as(LengthUnit.Meter, p, a) >= _anchorMeters) {
      _customerAnchor = p;
      return true;
    }
    return false;
  }

  @override
  void didUpdateWidget(RouteMap old) {
    super.didUpdateWidget(old);
    if (old.from != widget.from || old.to != widget.to || _moveCustomerAnchor()) {
      _route = null;
      _loadRoute();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fit();
      });
    }
    _onDriverChanged(old.driver);
  }

  @override
  void dispose() {
    _move.dispose();
    _map.dispose();
    super.dispose();
  }

  /// Nouvelle position du livreur : animation depuis la position affichée, puis recadrage.
  void _onDriverChanged(DriverLocation? old) {
    final d = widget.driver;
    if (d == null) {
      if (_driverTo != null) {
        _move.stop();
        _driverFrom = _driverTo = null;
        _headingFrom = _headingTo = null;
        _autoFit();
      }
      return;
    }
    final target = LatLng(d.lat, d.lng);
    if (target == _driverTo && d.heading == _headingTo) return;
    final appeared = _driverTo == null;
    if (appeared) {
      _driverFrom = _driverTo = target;
      _headingFrom = _headingTo = d.heading;
    } else {
      _driverFrom = _driverPosition; // part de là où le marqueur est affiché (animation en cours comprise)
      _headingFrom = _driverHeading;
      _driverTo = target;
      _headingTo = d.heading;
      _move.forward(from: 0);
    }
    _autoFit();
  }

  LatLng? get _driverPosition {
    final a = _driverFrom, b = _driverTo;
    if (a == null || b == null) return b;
    final t = _moveCurve.value;
    if (t >= 1) return b;
    return LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
  }

  /// Cap interpolé par le plus court chemin (350° → 10° tourne de 20°, pas de 340°).
  double? get _driverHeading {
    final a = _headingFrom, b = _headingTo;
    if (b == null) return null;
    if (a == null) return b;
    final t = _moveCurve.value;
    final delta = ((b - a + 540) % 360) - 180;
    return (a + delta * t) % 360;
  }

  /// Recadrage automatique, sauf si l'utilisateur a déplacé la carte.
  void _autoFit() {
    if (_userMoved) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_userMoved) _fit();
    });
  }

  void _recenter() {
    if (_userMoved) setState(() => _userMoved = false);
    _fit();
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    if (hasGesture && !_userMoved && widget.driver != null) setState(() => _userMoved = true);
  }

  Future<void> _initTiles() async {
    if (!_geo.usesGoogle) return;
    try {
      final session = await _geo.tileSession();
      if (!mounted || session == null) return;
      setState(() => _tileSession = session);
      _refreshCopyright();
    } catch (_) {
      // On reste sur OpenStreetMap.
    }
  }

  void _onGoogleTileError(TileImage tile, Object error, StackTrace? stackTrace) {
    if (_tileSession == null) return;
    _googleTileErrors++;
    if (_googleTileErrors < 4) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tileSession == null) return;
      setState(() {
        _tileSession = null;
        _googleCopyright = null;
      });
      _geo.clearTileSession();
    });
  }

  Future<void> _refreshCopyright() async {
    final session = _tileSession;
    if (session == null || !_mapReady) return;
    final camera = _map.camera;
    final b = camera.visibleBounds;
    try {
      final text = await _geo.viewportCopyright(
        session: session,
        zoom: camera.zoom.clamp(0, 22).round(),
        north: b.north,
        south: b.south,
        east: b.east,
        west: b.west,
      );
      if (mounted && text != null && text != _googleCopyright) setState(() => _googleCopyright = text);
    } catch (_) {}
  }

  Future<void> _loadRoute() async {
    final seq = ++_seq;
    _loading = true;
    final r = await _geo.route(widget.from, _to);
    if (!mounted || seq != _seq) return;
    setState(() {
      _route = r;
      _loading = false;
    });
    if (!_userMoved) _fit();
  }

  void _retry() {
    setState(() => _loading = true);
    _loadRoute();
  }

  /// Suivi en direct : cadrage sur le livreur et le client ; sinon tout l'itinéraire.
  List<LatLng> get _fitPoints {
    final driver = _driverTo;
    if (driver != null) return [driver, _to];
    return [widget.from, _to, ...?_route?.points];
  }

  CameraFit get _cameraFit =>
      CameraFit.coordinates(coordinates: _fitPoints, padding: const EdgeInsets.fromLTRB(36, 44, 36, 28), maxZoom: 17);

  void _fit() {
    if (!_mapReady) return;
    _map.fitCamera(_cameraFit);
    _refreshCopyright();
  }

  void _onMapReady() {
    _mapReady = true;
    _fit();
  }

  Future<void> _openGoogleMaps() async {
    var ok = false;
    try {
      ok = await launchUrl(googleMapsDirectionsUri(widget.from, _to), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Impossible d\'ouvrir Google Maps')));
    }
  }

  Widget _tiles() {
    final session = _tileSession;
    if (session != null) {
      return TileLayer(
        key: ValueKey('google-${session.session}'),
        urlTemplate: session.urlTemplate,
        maxNativeZoom: 22,
        userAgentPackageName: GeoService.tileUserAgentPackage,
        tileProvider: NetworkTileProvider(headers: GeoService.googleHeaders),
        errorTileCallback: _onGoogleTileError,
      );
    }
    return TileLayer(
      key: const ValueKey('osm'),
      urlTemplate: GeoService.osmTileUrl,
      maxNativeZoom: 19,
      userAgentPackageName: GeoService.tileUserAgentPackage,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final route = _route;
    final failed = !_loading && route == null;
    final line = route != null ? routePolyline(route.points) : routePolyline([widget.from, _to], fallback: true);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: widget.height,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCameraFit: _cameraFit,
                    minZoom: 5,
                    maxZoom: 19,
                    backgroundColor: scheme.surfaceContainerHighest,
                    // Pas de glisser à un doigt : la page reste défilable.
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.pinchZoom | InteractiveFlag.pinchMove | InteractiveFlag.doubleTapZoom,
                    ),
                    onMapReady: _onMapReady,
                    onPositionChanged: _onPositionChanged,
                  ),
                  children: [
                    _tiles(),
                    if (!_loading || route != null) PolylineLayer(polylines: [line]),
                    MarkerLayer(markers: [
                      restaurantMarker(widget.from),
                      // Client en direct : son marqueur pulsant remplace l'épingle fixe.
                      if (widget.customer == null) deliveryMarker(widget.to) else customerLiveMarker(_customerPoint!, stale: widget.customer!.isStale),
                    ]),
                    if (_driverTo != null)
                      AnimatedBuilder(
                        animation: _move,
                        builder: (context, _) {
                          final p = _driverPosition;
                          if (p == null) return const SizedBox.shrink();
                          return MarkerLayer(
                            markers: [driverMarker(p, heading: _driverHeading, stale: widget.driver?.isStale ?? false)],
                          );
                        },
                      ),
                    if (_tileSession == null)
                      SimpleAttributionWidget(
                        source: const Text('OpenStreetMap', style: TextStyle(fontSize: 10.5)),
                        backgroundColor: Colors.white.withValues(alpha: 0.8),
                      ),
                  ],
                ),
                if (_tileSession != null)
                  Positioned(
                    left: 6,
                    bottom: 4,
                    right: 60,
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surface.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          child: Text(
                            'Google  ${_googleCopyright ?? '© Google'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10, color: scheme.onSurface),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Material(
                    color: scheme.surface,
                    elevation: 2,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: IconButton(
                      tooltip: 'Recentrer',
                      onPressed: _recenter,
                      color: scheme.onSurface,
                      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.center_focus_strong_rounded, size: 20),
                    ),
                  ),
                ),
                // Carte déplacée à la main pendant le suivi : le recadrage automatique est suspendu.
                if (_userMoved && _driverTo != null)
                  Positioned(
                    bottom: 12,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.brand,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          elevation: 3,
                        ),
                        onPressed: _recenter,
                        icon: const Icon(Icons.my_location_rounded, size: 18),
                        label: const Text('Recentrer'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(
              failed ? Icons.route_outlined : Icons.route_rounded,
              size: 20,
              color: failed ? scheme.onSurfaceVariant : AppColors.brand,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _loading && route == null
                  ? Row(
                      children: [
                        const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Text(
                          'Calcul de l\'itinéraire…',
                          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    )
                  : Text(
                      route != null ? route.summary : 'Itinéraire indisponible',
                      style: TextStyle(
                        fontSize: route != null ? 15 : 13,
                        fontWeight: route != null ? FontWeight.w800 : FontWeight.w500,
                        color: route != null ? scheme.onSurface : scheme.onSurfaceVariant,
                      ),
                    ),
            ),
            if (failed) TextButton(onPressed: _retry, child: const Text('Réessayer')),
          ],
        ),
        if (widget.fromLabel != null || widget.toLabel != null) ...[
          const SizedBox(height: 6),
          if (widget.fromLabel != null) _LegendRow(icon: Icons.storefront_rounded, text: widget.fromLabel!),
          if (widget.toLabel != null) _LegendRow(icon: Icons.location_on_rounded, text: widget.toLabel!),
        ],
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _openGoogleMaps,
          icon: const Icon(Icons.directions_rounded),
          label: const Text('Ouvrir dans Google Maps'),
        ),
      ],
    );
  }
}

class _LegendRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _LegendRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.brand),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bandeau « Le client partage sa position en direct » (côté livreur et personnel) :
/// fraîcheur de la dernière position et fin du partage.
class CustomerLiveBanner extends StatelessWidget {
  final DriverLocation location;
  final DateTime? until;
  const CustomerLiveBanner({super.key, required this.location, this.until});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final age = DateTime.now().difference(location.updatedAt);
    final fresh = age.inSeconds < 60 ? 'à l\'instant' : 'il y a ${age.inMinutes} min';
    final end = until == null
        ? ''
        : ' · jusqu\'à ${until!.hour.toString().padLeft(2, '0')}:${until!.minute.toString().padLeft(2, '0')}';
    final accuracy = location.accuracy != null && location.accuracy! > 0 ? ' · ±${location.accuracy!.round()} m' : '';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.green.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.green.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          SizedBox(width: 40, height: 40, child: CustomerLivePin(stale: location.isStale)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  location.isStale ? 'Dernière position connue du client' : 'Le client partage sa position en direct',
                  style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface),
                ),
                const SizedBox(height: 2),
                Text(
                  'Mise à jour $fresh$accuracy$end',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
