import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../services/api.dart';
import '../../services/geo_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/route_map.dart';

class LocationData {
  final double lat;
  final double lng;
  final double? accuracy;
  final String? address;

  LocationData({required this.lat, required this.lng, this.accuracy, this.address});

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng, 'accuracy': accuracy, 'address': address};
}

/// Choix de la position de livraison sur une carte.
/// Fond Google Maps (Map Tiles API) si une clé est fournie, sinon OpenStreetMap.
/// L'épingle reste au centre : le client fait glisser la carte, cherche un lieu ou utilise « Ma position ».
/// Le point bleu suit le téléphone en direct ; « Ma position » active le suivi, qui s'arrête dès
/// que le client fait glisser la carte.
/// Renvoie un [LocationData] (avec l'adresse trouvée) via `Navigator.pop`.
class GpsPickerScreen extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;

  const GpsPickerScreen({this.initialLat, this.initialLng, super.key});

  @override
  State<GpsPickerScreen> createState() => _GpsPickerScreenState();
}

class _GpsPickerScreenState extends State<GpsPickerScreen> with SingleTickerProviderStateMixin {
  static const _lome = LatLng(6.1319, 1.2228);
  static const _userBlue = Color(0xFF1A73E8);
  static const _minZoom = 5.0;
  static const _maxZoom = 19.0;
  static const _initialZoom = 16.0;

  /// En deçà de cette distance, l'adresse déjà trouvée reste valable.
  static const _addressTolerance = 15.0;

  final _geo = GeoService.instance;
  final _map = MapController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  late final AppLifecycleListener _lifecycle;
  late final LatLng _initialCenter;

  // Position choisie (centre de la carte) et position réelle du téléphone.
  late LatLng _center;
  double? _accuracy;
  LatLng? _userPos;
  double? _userAccuracy;
  bool _locating = false;
  bool _moving = false;
  bool _awaitingSettings = false;
  bool _mapReady = false;
  (LatLng, double)? _pendingMove;
  MapCamera? _camera;
  double _rotation = 0;

  // Gestes en cours (doigts posés sur la carte).
  final Set<int> _pointers = {};

  // Suivi en direct de la position.
  StreamSubscription<Position>? _positionSub;
  bool _trackingWanted = false;
  bool _following = false;

  // Déplacements animés de la caméra.
  late final AnimationController _camAnim;
  bool _animating = false;
  LatLng? _animFrom;
  LatLng? _animTo;
  double _animFromZoom = 0;
  double _animToZoom = 0;
  double _animFromRot = 0;
  double _animToRot = 0;
  double _animBump = 0;

  // Fond de carte.
  TileSession? _tileSession;
  late Widget _tiles;
  int _googleTileErrors = 0;
  int _osmTileErrors = 0;
  bool _tilesUnavailable = false;
  int _tilesGeneration = 0;
  String? _googleCopyright;

  // Recherche.
  Timer? _searchDebounce;
  int _searchSeq = 0;
  bool _searching = false;
  List<PlaceSuggestion> _suggestions = const [];
  String? _searchInfo;

  // Adresse automatique.
  Timer? _settleTimer;
  int _reverseSeq = 0;
  String? _address;
  bool _resolving = true;
  LatLng? _resolvedFor;

  // Itinéraire restaurant → épingle (seulement si la position du restaurant est connue).
  static const _routeTolerance = 10.0;
  LatLng? _restaurant;
  RouteResult? _route;
  LatLng? _routedFor;
  bool _routing = false;
  bool _routeFailed = false;
  int _routeSeq = 0;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume, onPause: _onPause);
    _camAnim = AnimationController(vsync: this)
      ..addListener(_onCameraTick)
      ..addStatusListener(_onCameraStatus);
    final hasInitial = widget.initialLat != null && widget.initialLng != null;
    _initialCenter = hasInitial ? LatLng(widget.initialLat!, widget.initialLng!) : _lome;
    _center = _initialCenter;
    _tiles = _buildTiles();
    _initGoogleTiles();
    _loadRestaurant();
    _scheduleSettle(const Duration(milliseconds: 300));
    if (hasInitial) {
      // Position déjà choisie : on affiche seulement le point bleu, sans déplacer la carte.
      _startTrackingIfAllowed();
    } else {
      // Première ouverture : on tente directement la position du téléphone.
      WidgetsBinding.instance.addPostFrameCallback((_) => _locate());
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _stopTracking();
    _camAnim.dispose();
    _searchDebounce?.cancel();
    _settleTimer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _map.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ Fond de carte

  Future<void> _initGoogleTiles() async {
    if (!_geo.usesGoogle) return;
    try {
      final session = await _geo.tileSession();
      if (!mounted || session == null) return;
      setState(() {
        _tileSession = session;
        _googleTileErrors = 0;
        _tiles = _buildTiles();
      });
      _refreshCopyright();
    } catch (_) {
      // Session impossible : on reste sur OpenStreetMap.
    }
  }

  Widget _buildTiles() {
    final session = _tileSession;
    if (session != null) {
      return TileLayer(
        key: ValueKey('google-${session.session}-$_tilesGeneration'),
        urlTemplate: session.urlTemplate,
        maxNativeZoom: 22,
        userAgentPackageName: GeoService.tileUserAgentPackage,
        tileProvider: NetworkTileProvider(headers: GeoService.googleHeaders),
        errorTileCallback: _onGoogleTileError,
        tileBuilder: _tileBuilder,
        keepBuffer: 3,
        evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
      );
    }
    return TileLayer(
      key: ValueKey('osm-$_tilesGeneration'),
      urlTemplate: GeoService.osmTileUrl,
      maxNativeZoom: 19,
      userAgentPackageName: GeoService.tileUserAgentPackage,
      errorTileCallback: _onOsmTileError,
      tileBuilder: _tileBuilder,
      keepBuffer: 3,
      evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
    );
  }

  /// Case en attente : quadrillage + indicateur de chargement (ou icône d'erreur) au lieu d'un fond vide.
  Widget _tileBuilder(BuildContext context, Widget tileWidget, TileImage tile) {
    if (tile.readyToDisplay && !tile.loadError) return tileWidget;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5), width: 0.5),
          ),
          child: Center(
            child: tile.loadError
                ? Icon(Icons.cloud_off_rounded, size: 20, color: scheme.onSurfaceVariant.withValues(alpha: 0.6))
                : SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  ),
          ),
        ),
        tileWidget,
      ],
    );
  }

  /// Tuiles Google refusées (clé mal restreinte, quota...) : retour sur OpenStreetMap.
  void _onGoogleTileError(TileImage tile, Object error, StackTrace? stackTrace) {
    if (_tileSession == null) return;
    _googleTileErrors++;
    if (_googleTileErrors < 4) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tileSession == null) return;
      setState(() {
        _tileSession = null;
        _googleCopyright = null;
        _tiles = _buildTiles();
      });
      _geo.clearTileSession();
    });
  }

  /// Tuiles OpenStreetMap en échec (pas de réseau...) : bandeau avec « Réessayer ».
  void _onOsmTileError(TileImage tile, Object error, StackTrace? stackTrace) {
    _osmTileErrors++;
    if (_osmTileErrors < 3 || _tilesUnavailable) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_tilesUnavailable) setState(() => _tilesUnavailable = true);
    });
  }

  void _reloadTiles() {
    setState(() {
      _tilesUnavailable = false;
      _osmTileErrors = 0;
      _googleTileErrors = 0;
      _tilesGeneration++;
      _tiles = _buildTiles();
    });
  }

  Future<void> _refreshCopyright() async {
    final session = _tileSession;
    final camera = _camera;
    if (session == null || camera == null) return;
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
      if (!mounted || text == null || text == _googleCopyright) return;
      setState(() => _googleCopyright = text);
    } catch (_) {
      // On garde « © Google ».
    }
  }

  // ------------------------------------------------------------------ Caméra animée

  double get _currentZoom => _mapReady ? _map.camera.zoom : _initialZoom;

  /// Déplacement fluide de la caméra (centre, zoom et éventuellement rotation), image par image.
  void _animateTo(LatLng center, double zoom, {double? rotation}) {
    final target = zoom.clamp(_minZoom, _maxZoom).toDouble();
    if (!_mapReady) {
      _pendingMove = (center, target);
      _center = center;
      return;
    }
    final cam = _map.camera;
    final meters = _metersBetween(cam.center, center);
    var toRot = rotation ?? cam.rotation;
    var delta = (toRot - cam.rotation) % 360;
    if (delta > 180) delta -= 360;
    toRot = cam.rotation + delta;
    if (meters < 0.5 && (target - cam.zoom).abs() < 0.01 && delta.abs() < 0.5) return;

    _animFrom = cam.center;
    _animTo = center;
    _animFromZoom = cam.zoom;
    _animToZoom = target;
    _animFromRot = cam.rotation;
    _animToRot = toRot;
    // Long trajet : on dézoome un peu en route (effet « survol ») pour garder des repères.
    _animBump = meters > 1500 ? math.min(4.0, math.log(meters / 1500) / math.ln2 + 0.5) : 0;
    _camAnim.duration = Duration(milliseconds: (380 + math.min(meters / 15, 620)).round());
    _animating = true;
    _camAnim.forward(from: 0);
  }

  void _onCameraTick() {
    final from = _animFrom;
    final to = _animTo;
    if (!_animating || from == null || to == null) return;
    final t = Curves.easeInOutCubic.transform(_camAnim.value);
    final lat = from.latitude + (to.latitude - from.latitude) * t;
    final lng = from.longitude + (to.longitude - from.longitude) * t;
    final zoom = (_animFromZoom + (_animToZoom - _animFromZoom) * t - _animBump * math.sin(math.pi * t))
        .clamp(_minZoom, _maxZoom)
        .toDouble();
    final rot = _animFromRot + (_animToRot - _animFromRot) * t;
    _map.moveAndRotate(LatLng(lat, lng), zoom, rot);
  }

  void _onCameraStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _animating = false;
    _scheduleSettle(Duration.zero);
  }

  void _stopAnimation() {
    if (!_animating) return;
    _animating = false;
    _camAnim.stop();
  }

  void _zoomBy(double delta) {
    final base = _animating ? _animToZoom : _currentZoom;
    final center = _animating ? (_animTo ?? _center) : _center;
    _animateTo(center, (base + delta).roundToDouble());
  }

  void _resetNorth() {
    final center = _animating ? (_animTo ?? _center) : _center;
    _animateTo(center, _animating ? _animToZoom : _currentZoom, rotation: 0);
  }

  // ------------------------------------------------------------------ Carte

  void _onMapReady() {
    _mapReady = true;
    _camera = _map.camera;
    final pending = _pendingMove;
    _pendingMove = null;
    if (pending != null) _map.move(pending.$1, pending.$2);
    _refreshCopyright();
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    _camera = camera;
    _center = camera.center;
    var changed = false;
    if (hasGesture) {
      _stopAnimation();
      if (_following) {
        _following = false; // Le client reprend la main : le suivi s'arrête.
        changed = true;
      }
      if (_accuracy != null) {
        _accuracy = null; // Placée à la main : la précision GPS ne s'applique plus.
        changed = true;
      }
      if (!_moving) {
        _moving = true;
        changed = true;
      }
      final last = _resolvedFor;
      final far = last == null || _metersBetween(camera.center, last) > _addressTolerance;
      if (far && (_address != null || !_resolving)) {
        _address = null;
        _resolving = true;
        changed = true;
      }
    }
    if ((camera.rotation - _rotation).abs() > 0.5 || ((camera.rotation == 0) != (_rotation == 0))) {
      _rotation = camera.rotation;
      changed = true;
    }
    if (changed) setState(() {});
    // Filet de sécurité : si aucun événement de fin n'arrive, on considère la carte arrêtée.
    _scheduleSettle(const Duration(milliseconds: 700));
  }

  void _onMapEvent(MapEvent event) {
    if (event is MapEventMoveEnd ||
        event is MapEventFlingAnimationEnd ||
        event is MapEventFlingAnimationNotStarted ||
        event is MapEventDoubleTapZoomEnd ||
        event is MapEventRotateEnd) {
      // Court délai : après MoveEnd, une animation d'élan (fling) peut encore démarrer.
      _scheduleSettle(const Duration(milliseconds: 150));
    } else if (event is MapEventScrollWheelZoom) {
      _scheduleSettle(const Duration(milliseconds: 400));
    }
  }

  void _onPointerDown(PointerDownEvent event, LatLng point) {
    _pointers.add(event.pointer);
    _dismissSearch();
    _stopAnimation();
  }

  void _onPointerUp(PointerUpEvent event, LatLng point) => _releasePointer(event.pointer);

  void _onPointerCancel(PointerCancelEvent event, LatLng point) => _releasePointer(event.pointer);

  void _releasePointer(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.isEmpty) _scheduleSettle(const Duration(milliseconds: 250));
  }

  static double _metersBetween(LatLng a, LatLng b) =>
      Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);

  // ------------------------------------------------------------------ Fin de mouvement + adresse

  void _scheduleSettle(Duration delay) {
    _settleTimer?.cancel();
    _settleTimer = Timer(delay, _settle);
  }

  /// La carte est immobile (plus de doigt, plus d'élan, plus d'animation) : l'épingle se pose
  /// et on cherche l'adresse du point.
  void _settle() {
    if (!mounted || _pointers.isNotEmpty || _animating) return;
    if (_moving) setState(() => _moving = false);
    _resolveAddress();
    _updateRoute();
    _refreshCopyright();
  }

  // ------------------------------------------------------------------ Itinéraire

  /// Position du restaurant (réglages), chargée une seule fois.
  Future<void> _loadRestaurant() async {
    try {
      final s = await Api.instance.settings();
      final lat = s.restaurantLat;
      final lng = s.restaurantLng;
      if (!mounted || lat == null || lng == null) return;
      setState(() => _restaurant = LatLng(lat, lng));
      if (!_moving && _pointers.isEmpty && !_animating) _updateRoute();
    } catch (_) {
      // Réglages indisponibles : carte sans itinéraire.
    }
  }

  /// Recalcule l'itinéraire vers le point visé (appelé une fois la carte immobile).
  /// La route précédente reste affichée pendant le calcul.
  Future<void> _updateRoute() async {
    final from = _restaurant;
    if (from == null) return;
    final point = _center;
    final last = _routedFor;
    if (last != null && _metersBetween(point, last) <= _routeTolerance) return;
    final seq = ++_routeSeq;
    _routedFor = point;
    setState(() => _routing = true);
    final r = await _geo.route(from, point);
    if (!mounted || seq != _routeSeq) return;
    setState(() {
      _routing = false;
      _routeFailed = r == null;
      if (r != null) _route = r;
      if (r == null) _routedFor = null; // Nouvel essai au prochain arrêt de la carte.
    });
  }

  List<Polyline> _routeLines(LatLng from) {
    final route = _route;
    final target = _routedFor ?? _center;
    if (route == null) {
      // Itinéraire indisponible : simple ligne droite en pointillés.
      return _routeFailed && !_routing ? [routePolyline([from, target], fallback: true)] : const [];
    }
    final lines = [routePolyline(route.points)];
    // La route s'arrête sur la voie la plus proche : pointillés jusqu'à l'épingle.
    final end = route.points.last;
    if (_metersBetween(end, target) > 15) lines.add(routePolyline([end, target], fallback: true));
    return lines;
  }

  Future<void> _resolveAddress() async {
    final point = _center;
    final last = _resolvedFor;
    if (last != null && _metersBetween(point, last) <= _addressTolerance) {
      if (_resolving) setState(() => _resolving = false);
      return;
    }
    final seq = ++_reverseSeq;
    setState(() {
      _address = null;
      _resolving = true;
    });
    try {
      final address = await _geo.reverse(point.latitude, point.longitude);
      if (!mounted || seq != _reverseSeq) return;
      setState(() {
        _address = address;
        _resolvedFor = point;
        _resolving = false;
      });
    } catch (_) {
      if (!mounted || seq != _reverseSeq) return;
      setState(() {
        _address = null;
        _resolving = false;
      });
    }
  }

  // ------------------------------------------------------------------ Recherche

  void _onSearchChanged(String text) {
    _searchDebounce?.cancel();
    final seq = ++_searchSeq;
    if (text.trim().length < 2) {
      setState(() {
        _suggestions = const [];
        _searching = false;
        _searchInfo = null;
      });
      return;
    }
    setState(() => _searching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 400), () => _runSearch(text, seq));
  }

  Future<void> _runSearch(String text, int seq) async {
    try {
      final results = await _geo.suggestions(text);
      if (!mounted || seq != _searchSeq) return; // Réponse périmée.
      setState(() {
        _suggestions = results;
        _searching = false;
        _searchInfo = results.isEmpty ? 'Aucun lieu trouvé. Essayez un autre nom ou déplacez la carte.' : null;
      });
    } catch (_) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _suggestions = const [];
        _searching = false;
        _searchInfo = 'Recherche indisponible pour le moment. Déplacez la carte à la main.';
      });
    }
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchSeq++;
    _search.clear();
    setState(() {
      _suggestions = const [];
      _searching = false;
      _searchInfo = null;
    });
  }

  Future<void> _selectSuggestion(PlaceSuggestion s) async {
    FocusScope.of(context).unfocus();
    _searchDebounce?.cancel();
    final seq = ++_searchSeq;
    _search.text = s.title;
    setState(() {
      _suggestions = const [];
      _searchInfo = null;
      _searching = !s.hasCoordinates;
    });
    try {
      final place = await _geo.placeDetails(s);
      if (!mounted || seq != _searchSeq) return;
      final point = LatLng(place.lat, place.lng);
      _reverseSeq++; // Ignore un géocodage inverse en cours.
      setState(() {
        _searching = false;
        _following = false;
        _accuracy = null;
        _address = place.address;
        _resolvedFor = place.address != null ? point : null;
        _resolving = place.address == null;
      });
      _animateTo(point, 17);
    } catch (_) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searching = false;
        _searchInfo = 'Impossible d\'ouvrir ce lieu. Réessayez ou déplacez la carte.';
      });
    }
  }

  void _dismissSearch() {
    if (_searchFocus.hasFocus) _searchFocus.unfocus();
    if (_suggestions.isNotEmpty || _searchInfo != null) {
      setState(() {
        _suggestions = const [];
        _searchInfo = null;
      });
    }
  }

  // ------------------------------------------------------------------ Suivi en direct

  LocationSettings _locationSettings() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
          intervalDuration: const Duration(seconds: 2),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
          allowBackgroundLocationUpdates: false,
        );
      default:
        return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5);
    }
  }

  void _startTracking() {
    _trackingWanted = true;
    if (_positionSub != null) return;
    _positionSub = Geolocator.getPositionStream(locationSettings: _locationSettings()).listen(
      _onPosition,
      onError: (Object _) => _stopTracking(), // GPS coupé... ; relancé au retour dans l'appli ou par le bouton.
    );
  }

  void _stopTracking() {
    _positionSub?.cancel();
    _positionSub = null;
  }

  /// Démarre le suivi sans rien demander (autorisation déjà accordée).
  Future<void> _startTrackingIfAllowed() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always && permission != LocationPermission.whileInUse) return;
      if (mounted) _startTracking();
    } catch (_) {}
  }

  void _onPosition(Position p) {
    if (!mounted) return;
    final point = LatLng(p.latitude, p.longitude);
    setState(() {
      _userPos = point;
      _userAccuracy = p.accuracy;
      if (_following) _accuracy = p.accuracy;
    });
    if (_following && _pointers.isEmpty) _animateTo(point, _animating ? _animToZoom : _currentZoom);
  }

  /// Applique une position trouvée par « Ma position » (zoom au moins sur le quartier).
  void _applyFix(Position p) {
    final point = LatLng(p.latitude, p.longitude);
    setState(() {
      _userPos = point;
      _userAccuracy = p.accuracy;
      _accuracy = p.accuracy;
    });
    _animateTo(point, math.max(_currentZoom, 17));
  }

  // ------------------------------------------------------------------ Localisation

  void _onPause() {
    // En arrière-plan : on coupe le GPS (batterie) ; il repart au retour.
    _stopTracking();
    _pointers.clear();
  }

  void _onResume() {
    if (!mounted) return;
    // Retour des réglages Android : on relance la localisation si on l'attendait.
    if (_awaitingSettings) {
      _awaitingSettings = false;
      _locate();
      return;
    }
    if (_trackingWanted) _startTrackingIfAllowed();
  }

  Future<void> _locate() async {
    if (_locating) return;
    setState(() {
      _locating = true;
      _following = true;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _following = false;
        if (mounted) await _askEnableLocationService();
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        _following = false;
        if (mounted) await _askOpenAppSettings();
        return;
      }
      if (permission == LocationPermission.denied) {
        _following = false;
        if (mounted) {
          showMessage(context, 'Autorisez la localisation pour trouver votre position, ou placez l\'épingle à la main.',
              error: true);
        }
        return;
      }
      if (!mounted) return;
      _startTracking();

      // Position déjà suivie : on y va tout de suite, le suivi la tient à jour.
      final known = _userPos;
      if (known != null) {
        setState(() => _accuracy = _userAccuracy);
        _animateTo(known, math.max(_currentZoom, 17));
        return;
      }

      // Sinon : dernière position connue pour réagir vite, puis position précise.
      Position? quick;
      try {
        quick = await Geolocator.getLastKnownPosition();
      } catch (_) {}
      if (!mounted) return;
      if (quick != null && _following) {
        _applyFix(quick);
        setState(() => _locating = false);
      }
      Position? fresh;
      try {
        fresh = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 15),
        );
      } catch (_) {
        // GPS lent (intérieur...) : le suivi en direct prendra le relais.
      }
      if (!mounted) return;
      if (fresh != null && _following) _applyFix(fresh);
      if (quick == null && fresh == null && _userPos == null) {
        setState(() => _following = false);
        showMessage(context, 'Position introuvable pour le moment. Placez l\'épingle à la main.', error: true);
      }
    } catch (_) {
      _following = false;
      if (mounted) {
        showMessage(context, 'Position introuvable pour le moment. Placez l\'épingle à la main.', error: true);
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _askEnableLocationService() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.location_off_rounded, color: brandColor(context)),
        title: const Text('Activer la localisation'),
        content: const Text(
          'La localisation (GPS) de votre téléphone est désactivée. '
          'Activez-la pour placer automatiquement l\'épingle sur votre position. '
          'Vous pouvez aussi chercher votre quartier ou déplacer la carte à la main.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Plus tard')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Activer')),
        ],
      ),
    );
    if (ok != true) return;
    _awaitingSettings = true;
    final opened = await Geolocator.openLocationSettings();
    if (!opened) _awaitingSettings = false;
  }

  Future<void> _askOpenAppSettings() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.location_disabled_rounded, color: brandColor(context)),
        title: const Text('Localisation refusée'),
        content: const Text(
          'KALETA n\'a pas l\'autorisation d\'utiliser votre position. '
          'Ouvrez les réglages de l\'application, puis « Autorisations » > « Position » pour l\'autoriser. '
          'Vous pouvez aussi placer l\'épingle à la main.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Plus tard')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ouvrir les réglages')),
        ],
      ),
    );
    if (ok != true) return;
    _awaitingSettings = true;
    final opened = await Geolocator.openAppSettings();
    if (!opened) _awaitingSettings = false;
  }

  // ------------------------------------------------------------------ Interface

  void _confirm() {
    // Pendant une animation, on retient la destination plutôt qu'un point intermédiaire.
    final point = _animating ? (_animTo ?? _center) : _center;
    final last = _resolvedFor;
    final addressIsCurrent = last != null && _metersBetween(point, last) <= _addressTolerance;
    Navigator.pop(
      context,
      LocationData(
        lat: point.latitude,
        lng: point.longitude,
        accuracy: _accuracy,
        address: addressIsCurrent ? _address : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final userPos = _userPos;
    final userAccuracy = _userAccuracy;
    final restaurant = _restaurant;
    final rotated = _rotation.abs() > 0.5;
    return Scaffold(
      appBar: AppBar(title: const Text('Ma position de livraison')),
      // Le clavier passe par-dessus le panneau du bas au lieu d'écraser la carte.
      resizeToAvoidBottomInset: false,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  // Options stables (centre initial figé) : pas de reconfiguration à chaque image.
                  options: MapOptions(
                    initialCenter: _initialCenter,
                    initialZoom: _initialZoom,
                    minZoom: _minZoom,
                    maxZoom: _maxZoom,
                    backgroundColor: scheme.surfaceContainerHighest,
                    interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
                    onMapReady: _onMapReady,
                    onPositionChanged: _onPositionChanged,
                    onMapEvent: _onMapEvent,
                    onPointerDown: _onPointerDown,
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerCancel,
                  ),
                  children: [
                    _tiles,
                    if (restaurant != null) PolylineLayer(polylines: _routeLines(restaurant)),
                    if (restaurant != null) MarkerLayer(markers: [restaurantMarker(restaurant)]),
                    if (userPos != null && userAccuracy != null && userAccuracy > 0)
                      CircleLayer(
                        circles: [
                          CircleMarker(
                            point: userPos,
                            radius: userAccuracy,
                            useRadiusInMeter: true,
                            color: _userBlue.withValues(alpha: 0.15),
                            borderColor: _userBlue.withValues(alpha: 0.5),
                            borderStrokeWidth: 1,
                          ),
                        ],
                      ),
                    if (userPos != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: userPos,
                            width: 20,
                            height: 20,
                            child: Container(
                              decoration: BoxDecoration(
                                color: _userBlue,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 3),
                                boxShadow: [
                                  BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (_tileSession == null)
                      const RichAttributionWidget(
                        alignment: AttributionAlignment.bottomLeft,
                        attributions: [TextSourceAttribution('OpenStreetMap')],
                      ),
                  ],
                ),
                // Épingle fixe au centre ; la pointe désigne exactement la position choisie.
                // Elle se soulève pendant le mouvement, son ombre reste sur le point visé.
                IgnorePointer(
                  child: Center(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: _moving ? 14 : 8,
                          height: _moving ? 6 : 4,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: _moving ? 0.25 : 0.35),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        AnimatedSlide(
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeOut,
                          offset: Offset(0, _moving ? -0.72 : -0.5),
                          child: Icon(Icons.location_on_rounded, size: 52, color: brandColor(context)),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_tileSession != null)
                  Positioned(
                    left: 8,
                    right: 88,
                    bottom: 6,
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: _GoogleAttribution(copyright: _googleCopyright),
                    ),
                  ),
                if (_tilesUnavailable)
                  Positioned(
                    top: 76,
                    left: 12,
                    right: 12,
                    child: _TilesBanner(
                      onRetry: _reloadTiles,
                      onClose: () => setState(() => _tilesUnavailable = false),
                    ),
                  ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: _buildSearch(scheme),
                ),
                Positioned(
                  right: 16,
                  bottom: 84,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (rotated) ...[
                        _MapButton(
                          tooltip: 'Remettre le nord en haut',
                          onPressed: _resetNorth,
                          child: Transform.rotate(
                            angle: -_rotation * math.pi / 180,
                            child: Icon(Icons.navigation_rounded, color: brandColor(context)),
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      _MapButton(
                        tooltip: 'Zoomer',
                        onPressed: () => _zoomBy(1),
                        child: const Icon(Icons.add_rounded),
                      ),
                      const SizedBox(height: 6),
                      _MapButton(
                        tooltip: 'Dézoomer',
                        onPressed: () => _zoomBy(-1),
                        child: const Icon(Icons.remove_rounded),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton(
                    heroTag: 'locate',
                    onPressed: _locating ? null : _locate,
                    backgroundColor: _following ? AppColors.brand : scheme.surface,
                    foregroundColor: _following ? Colors.white : brandColor(context),
                    tooltip: _following ? 'Suivi de ma position activé' : 'Ma position',
                    child: _locating
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: _following ? Colors.white : brandColor(context),
                            ),
                          )
                        : Icon(_following ? Icons.my_location_rounded : Icons.location_searching_rounded),
                  ),
                ),
              ],
            ),
          ),
          _buildBottomPanel(scheme),
        ],
      ),
    );
  }

  Widget _buildSearch(ColorScheme scheme) {
    final showList = _suggestions.isNotEmpty || _searchInfo != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          elevation: 3,
          borderRadius: BorderRadius.circular(14),
          color: scheme.surface,
          child: TextField(
            controller: _search,
            focusNode: _searchFocus,
            textInputAction: TextInputAction.search,
            onChanged: _onSearchChanged,
            onSubmitted: (_) {
              if (_suggestions.isNotEmpty) _selectSuggestion(_suggestions.first);
            },
            style: TextStyle(color: scheme.onSurface, fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Rechercher un quartier, une rue, un lieu…',
              hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
              prefixIcon: Icon(Icons.search_rounded, color: brandColor(context)),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : (_search.text.isNotEmpty
                      ? IconButton(
                          tooltip: 'Effacer',
                          icon: Icon(Icons.close_rounded, color: scheme.onSurfaceVariant),
                          onPressed: _clearSearch,
                        )
                      : null),
            ),
          ),
        ),
        if (showList) ...[
          const SizedBox(height: 6),
          Material(
            elevation: 3,
            borderRadius: BorderRadius.circular(14),
            color: scheme.surface,
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: _suggestions.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        _searchInfo ?? '',
                        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: _suggestions.length,
                      separatorBuilder: (_, _) => Divider(height: 1, color: scheme.outlineVariant),
                      itemBuilder: (context, i) {
                        final s = _suggestions[i];
                        final subtitle = s.subtitle;
                        return ListTile(
                          dense: true,
                          leading: Icon(Icons.place_outlined, color: scheme.onSurfaceVariant),
                          title: Text(
                            s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600),
                          ),
                          subtitle: subtitle == null
                              ? null
                              : Text(
                                  subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                ),
                          onTap: () => _selectSuggestion(s),
                        );
                      },
                    ),
            ),
          ),
        ],
      ],
    );
  }

  /// Distance et durée depuis le restaurant (estompées pendant le déplacement / le recalcul).
  Widget _buildRouteInfo(ColorScheme scheme) {
    final route = _route;
    final stale = _moving || _routing;
    final Widget content;
    if (route != null) {
      content = Text(
        '${route.summary} depuis le restaurant',
        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: scheme.onSurface),
      );
    } else if (_routing || (!_routeFailed && _routedFor == null)) {
      content = Text('Calcul de l\'itinéraire…', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant));
    } else {
      content = Text('Itinéraire indisponible', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: route != null && stale ? 0.5 : 1,
        child: Row(
          children: [
            Icon(Icons.route_rounded, size: 16, color: route != null ? brandColor(context) : scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(child: content),
            if (_routing)
              const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomPanel(ColorScheme scheme) {
    final coords = '${_center.latitude.toStringAsFixed(5)}, ${_center.longitude.toStringAsFixed(5)}';
    final accuracy = _accuracy;
    final accuracyText = accuracy != null ? 'Précision GPS ±${accuracy.round()} m' : null;
    final address = _address;

    final List<Widget> details;
    if (_resolving && address == null) {
      details = [
        Row(
          children: [
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text('Recherche de l\'adresse…', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
        ),
      ];
    } else if (address != null) {
      details = [
        Text(
          address,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13.5, color: scheme.onSurface),
        ),
        if (accuracyText != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(accuracyText, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ),
      ];
    } else {
      details = [
        Text('Adresse introuvable pour ce point', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            accuracyText != null ? '$coords  •  $accuracyText' : coords,
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ),
      ];
    }

    return Material(
      elevation: 12,
      color: scheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.place_rounded, color: brandColor(context)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Position choisie',
                          style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface),
                        ),
                        const SizedBox(height: 4),
                        ...details,
                        if (_restaurant != null) _buildRouteInfo(scheme),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _confirm,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Confirmer cette position'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Attribution obligatoire des tuiles Google : marque « Google » + copyright des données.
class _GoogleAttribution extends StatelessWidget {
  final String? copyright;

  const _GoogleAttribution({this.copyright});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = copyright ?? '© Google';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Google',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Petit bouton rond posé sur la carte (zoom, boussole).
class _MapButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;

  const _MapButton({required this.tooltip, required this.onPressed, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 3,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        color: scheme.onSurface,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        padding: EdgeInsets.zero,
        icon: child,
      ),
    );
  }
}

/// Bandeau affiché quand le fond de carte ne se charge pas (réseau...).
class _TilesBanner extends StatelessWidget {
  final VoidCallback onRetry;
  final VoidCallback onClose;

  const _TilesBanner({required this.onRetry, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Icon(Icons.cloud_off_rounded, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'La carte se charge mal. Vérifiez votre connexion.',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Réessayer')),
            IconButton(
              tooltip: 'Fermer',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, size: 18, color: scheme.onSurfaceVariant),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
