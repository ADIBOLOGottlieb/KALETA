import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'maps_link.dart';

/// Positions reçues par « Partager » depuis l'app Google Maps (Android, ACTION_SEND text/plain).
/// Le texte arrive par le canal natif `kaleta/share` (MainActivity.kt).
class SharedLocationService {
  SharedLocationService._();

  static final instance = SharedLocationService._();

  static const _channel = MethodChannel('kaleta/share');

  /// Dernière position reçue par « Partager » depuis Google Maps, pas encore utilisée.
  final ValueNotifier<ImportedLocation?> pending = ValueNotifier(null);

  /// En cours d'analyse d'un partage (lien court à résoudre).
  final ValueNotifier<bool> resolving = ValueNotifier(false);

  /// Message d'échec du dernier partage illisible (null sinon). Repasse à null avant chaque
  /// nouveau message pour que deux échecs successifs notifient bien les écouteurs.
  final ValueNotifier<String?> failure = ValueNotifier(null);

  static const failureMessage =
      'Impossible de lire cette position. Dans Google Maps, posez un repère puis Partager.';

  bool _initialized = false;
  int _seq = 0;

  /// Appelé dans main() : partage au démarrage + partages suivants.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText' && call.arguments is String) {
        unawaited(handleSharedText(call.arguments as String));
      }
      return null;
    });
    try {
      final text = await _channel
          .invokeMethod<String>('getInitialSharedText')
          .timeout(const Duration(seconds: 3));
      if (text != null && text.trim().isNotEmpty) unawaited(handleSharedText(text));
    } catch (e) {
      // Pas de canal natif (iOS, tests) ou délai dépassé : rien à faire.
      if (kDebugMode) debugPrint('Partage initial indisponible : $e');
    }
  }

  /// Analyse un texte partagé et place le résultat dans [pending] (ou un message dans [failure]).
  Future<void> handleSharedText(String text) async {
    final seq = ++_seq;
    resolving.value = true;
    try {
      final result = await parseLocationText(text);
      if (seq != _seq) return; // un partage plus récent est arrivé entre-temps
      if (result != null) {
        failure.value = null;
        pending.value = result;
      } else {
        failure.value = null;
        failure.value = failureMessage;
      }
    } finally {
      if (seq == _seq) resolving.value = false;
    }
  }

  /// Renvoie [pending] et le remet à null.
  ImportedLocation? consume() {
    final value = pending.value;
    pending.value = null;
    return value;
  }

  /// Déconnexion : oublie la position reçue (elle ne doit pas servir au compte suivant)
  /// et ignore le résultat d'une analyse encore en cours.
  void reset() {
    _seq++;
    pending.value = null;
    failure.value = null;
    resolving.value = false;
  }
}
