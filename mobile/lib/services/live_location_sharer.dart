import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models.dart';
import 'api.dart';

/// Durées proposées pour la position en direct (comme WhatsApp) : 15 min, 1 h, 8 h.
const liveShareDurations = <int, String>{15: '15 minutes', 60: '1 heure', 480: '8 heures'};

/// Démarre (ou prolonge) le partage en direct d'une commande ; [minutes] = 0 l'arrête.
Future<Order> requestLiveShare(int orderId, int minutes, {Position? position}) async {
  final body = <String, dynamic>{'minutes': minutes};
  if (position != null) {
    body.addAll({
      'lat': position.latitude,
      'lng': position.longitude,
      if (position.accuracy > 0) 'accuracy': position.accuracy,
      'heading': ?LiveLocationSharer.headingOf(position),
    });
  }
  return Order.fromJson(await Api.instance.post('/orders/$orderId/live-share', body) as Map<String, dynamic>);
}

/// État du partage, affiché sur la commande du client.
enum LiveShareState { idle, sharing, denied, deniedForever, serviceDisabled }

/// Position en direct du client pendant une livraison : le téléphone envoie sa position au serveur
/// (toutes les 8 s ou dès 20 m parcourus) jusqu'à la fin choisie, la livraison ou l'arrêt par le client.
/// Le livreur attribué la voit bouger sur sa carte.
class LiveLocationSharer extends ChangeNotifier {
  LiveLocationSharer._();
  static final LiveLocationSharer instance = LiveLocationSharer._();

  static const sendInterval = Duration(seconds: 8);
  static const sendDistanceMeters = 20.0;

  int? _orderId;
  DateTime? _until;
  LiveShareState _state = LiveShareState.idle;
  StreamSubscription<Position>? _sub;
  Timer? _endTimer;
  Position? _lastSent;
  DateTime? _lastSentAt;
  bool _sending = false;

  /// Commande dont la position est partagée (null : aucun partage).
  int? get orderId => _orderId;
  DateTime? get until => _until;
  LiveShareState get state => _state;
  bool isSharing(int orderId) => _orderId == orderId && _state == LiveShareState.sharing;

  /// Cap seulement en mouvement (à l'arrêt, le cap du GPS n'a pas de sens).
  static double? headingOf(Position p) => p.speed > 1 && p.heading >= 0 && p.heading <= 360 ? p.heading : null;

  /// Démarre le partage pour [minutes] : envoie la position actuelle puis suit le téléphone.
  /// Renvoie la commande à jour (live_share_until, customer_location).
  Future<Order> start(int orderId, int minutes) async {
    final ok = await _ensurePermission(ask: true);
    if (!ok) throw StateError(_permissionMessage());
    Position? here;
    try {
      here = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
    } catch (_) {
      here = await Geolocator.getLastKnownPosition();
    }
    final order = await requestLiveShare(orderId, minutes, position: here);
    if (here != null) {
      _lastSent = here;
      _lastSentAt = DateTime.now();
    }
    _attach(orderId, order.liveShareUntil);
    return order;
  }

  /// Arrête le partage (bouton « Arrêter de partager »).
  Future<Order?> stopSharing() async {
    final id = _orderId;
    _detach();
    if (id == null) return null;
    return requestLiveShare(id, 0);
  }

  /// Commande du client rechargée : reprend l'envoi si le partage est encore actif côté serveur
  /// (application relancée), ou s'arrête s'il est terminé.
  void syncWith(Order order) {
    if (order.isLiveSharing) {
      if (_orderId != order.id || _sub == null) {
        _ensurePermission(ask: false).then((ok) {
          if (ok) _attach(order.id, order.liveShareUntil);
        });
      } else if (order.liveShareUntil != _until) {
        _attach(order.id, order.liveShareUntil);
      }
    } else if (_orderId == order.id) {
      _detach();
    }
  }

  void _attach(int orderId, DateTime? until) {
    _orderId = orderId;
    _until = until;
    _endTimer?.cancel();
    if (until != null) {
      final left = until.difference(DateTime.now());
      _endTimer = Timer(left.isNegative ? Duration.zero : left, _detach);
    }
    _sub ??= Geolocator.getPositionStream(locationSettings: _settings()).listen(
      _onPosition,
      onError: (_) => _setState(LiveShareState.serviceDisabled),
    );
    _setState(LiveShareState.sharing);
  }

  void _detach() {
    _sub?.cancel();
    _sub = null;
    _endTimer?.cancel();
    _endTimer = null;
    _orderId = null;
    _until = null;
    _lastSent = null;
    _lastSentAt = null;
    _setState(LiveShareState.idle);
  }

  void _setState(LiveShareState s) {
    _state = s;
    notifyListeners();
  }

  Future<bool> _ensurePermission({required bool ask}) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _state = LiveShareState.serviceDisabled;
      return false;
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied && ask) p = await Geolocator.requestPermission();
    if (p == LocationPermission.deniedForever) {
      _state = LiveShareState.deniedForever;
      return false;
    }
    if (p == LocationPermission.denied || p == LocationPermission.unableToDetermine) {
      _state = LiveShareState.denied;
      return false;
    }
    return true;
  }

  String _permissionMessage() => switch (_state) {
        LiveShareState.serviceDisabled => 'Activez la localisation (GPS) du téléphone pour partager votre position.',
        LiveShareState.deniedForever =>
          'La localisation est bloquée pour KALETA : autorisez-la dans les réglages de l\'application.',
        _ => 'Autorisez la localisation pour partager votre position en direct.',
      };

  LocationSettings _settings() {
    if (kIsWeb) return const LocationSettings(accuracy: LocationAccuracy.high);
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
          intervalDuration: const Duration(seconds: 5),
          // Service au premier plan : le partage continue écran verrouillé, avec une notification visible.
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'Position en direct',
            notificationText: 'Le livreur KALETA voit votre position',
            notificationChannelName: 'Position en direct',
            enableWakeLock: true,
            setOngoing: true,
          ),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.high,
          activityType: ActivityType.other,
          pauseLocationUpdatesAutomatically: false,
          allowBackgroundLocationUpdates: false,
        );
      default:
        return const LocationSettings(accuracy: LocationAccuracy.high);
    }
  }

  void _onPosition(Position p) {
    final sent = _lastSent;
    final at = _lastSentAt;
    final due = sent == null ||
        at == null ||
        DateTime.now().difference(at) >= sendInterval ||
        Geolocator.distanceBetween(sent.latitude, sent.longitude, p.latitude, p.longitude) >= sendDistanceMeters;
    if (due) _send(p);
  }

  Future<void> _send(Position p) async {
    final id = _orderId;
    if (_sending || id == null) return;
    _sending = true;
    _lastSent = p;
    _lastSentAt = DateTime.now();
    try {
      final r = await Api.instance.post('/orders/$id/live-location', {
        'lat': p.latitude,
        'lng': p.longitude,
        if (p.accuracy > 0) 'accuracy': p.accuracy,
        'heading': ?headingOf(p),
      });
      // Partage terminé côté serveur (durée écoulée, commande livrée ou annulée) : on arrête.
      if (r is Map && r['sharing'] == false && _orderId == id) _detach();
    } catch (_) {
      // Réseau : on réessaiera au prochain point.
    } finally {
      _sending = false;
    }
  }
}
