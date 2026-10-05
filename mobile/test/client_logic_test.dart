import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaleta/models.dart';
import 'package:kaleta/providers/token_store.dart';
import 'package:kaleta/screens/client/opening_hours_banner.dart';
import 'package:kaleta/screens/client/order_estimate.dart';
import 'package:kaleta/services/error_reporter.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppSettings _settings({required bool open, DateTime? nextOpening, DateTime? nextClosing}) => AppSettings(
      deliveryFee: 500,
      minOrder: 0,
      isOpen: open,
      restaurantPhone: '',
      restaurantAddress: '',
      nextOpeningAt: nextOpening,
      nextClosingAt: nextClosing,
    );

void main() {
  group('total de la commande (frais mobile money compris)', () {
    test('livraison au devis + frais Flooz sur sous-total + livraison', () {
      final e = OrderEstimate.compute(
        subtotal: 19700,
        delivery: true,
        deliveryFee: 1300,
        paymentMethod: 'flooz',
        feePercent: 2,
      );
      expect(e.deliveryFee, 1300);
      expect(e.paymentFee, 429); // 21 000 / 0,98 = 21 428,57 -> 21 429
      expect(e.total, 21429);
    });

    test('espèces : pas de frais ; à emporter : pas de livraison', () {
      final cash = OrderEstimate.compute(
          subtotal: 5000, delivery: true, deliveryFee: 800, paymentMethod: 'cash', feePercent: 2);
      expect(cash.paymentFee, 0);
      expect(cash.total, 5800);
      final pickup = OrderEstimate.compute(
          subtotal: 5000, delivery: false, deliveryFee: 800, paymentMethod: 'mixx', feePercent: 3.5);
      expect(pickup.deliveryFee, 0);
      expect(pickup.total, 5000 + pickup.paymentFee);
      expect(pickup.paymentFee, 182); // 5 000 / 0,965 = 5 181,35 -> 5 182
    });

    test('libellés de livraison', () {
      expect(deliveryLineLabel(null), 'Livraison');
      expect(deliveryLineLabel(DeliveryQuote(fee: 1300, distanceKm: 3.4)), 'Livraison (3,4 km)');
      expect(outOfZoneMessage(DeliveryQuote(fee: 0, withinZone: false, maxKm: 15)),
          'Adresse hors de la zone de livraison (maximum 15,0 km)');
      expect(
          outOfZoneMessage(DeliveryQuote(fee: 0, withinZone: false, message: 'Trop loin.')), 'Trop loin');
    });
  });

  group('horaires', () {
    final now = DateTime(2026, 10, 7, 23, 0); // mercredi 23:00

    test("prochaine ouverture : aujourd'hui, demain, jour de la semaine", () {
      expect(describeOpeningTime(DateTime(2026, 10, 7, 23, 30), now), "aujourd'hui à 23:30");
      expect(describeOpeningTime(DateTime(2026, 10, 8, 10, 0), now), 'demain à 10:00');
      expect(describeOpeningTime(DateTime(2026, 10, 12, 10, 0), now), 'lundi à 10:00');
      expect(describeOpeningTime(DateTime(2026, 10, 20, 9, 5), now), 'le 20/10 à 09:05');
    });

    test('bandeau fermé et message de commande', () {
      final closed = _settings(open: false, nextOpening: DateTime(2026, 10, 12, 10, 0));
      expect(closedBannerText(closed, now: now), 'Fermé — ouvre lundi à 10:00');
      expect(closedOrderMessage(closed, now: now), contains('lundi à 10:00'));
      // Fermé manuellement : pas d'heure connue.
      expect(closedBannerText(_settings(open: false), now: now), 'Fermé pour le moment');
    });

    test('rappel de fermeture moins de 30 min avant', () {
      final soon = _settings(open: true, nextClosing: DateTime(2026, 10, 7, 23, 20));
      expect(closingSoonText(soon, now: now), 'Ferme à 23:20');
      final later = _settings(open: true, nextClosing: DateTime(2026, 10, 7, 23, 45));
      expect(closingSoonText(later, now: now), isNull);
      expect(closingSoonText(_settings(open: true), now: now), isNull);
    });

    test('réglages périmés une fois l\'heure prévue passée', () {
      expect(openingStateExpired(_settings(open: false, nextOpening: DateTime(2026, 10, 7, 22)), now: now), isTrue);
      expect(openingStateExpired(_settings(open: true, nextClosing: DateTime(2026, 10, 8)), now: now), isFalse);
      expect(openingStateExpired(_settings(open: false), now: now), isFalse);
    });
  });

  group('remontée des plantages', () {
    test('données sensibles masquées', () {
      final s = ErrorReporter.sanitize(
          'Échec {"phone":"+228 90 12 34 56","password":"secret123"} Authorization: Bearer abc.def-ghi '
          'token=eyJhbGciOiJIUzI1NiJ9.eyJpZCI6MX0.sig');
      expect(s, isNot(contains('secret123')));
      expect(s, isNot(contains('abc.def-ghi')));
      expect(s, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(s, isNot(contains('90 12 34 56')));
      expect(s, contains('Échec'));
    });

    test('anti-rafale : même message 1 fois par minute, 20 par session', () {
      var now = DateTime(2026, 10, 4, 12);
      final r = ErrorReporter(clock: () => now);
      expect(r.shouldSend('A'), isTrue);
      expect(r.shouldSend('A'), isFalse);
      now = now.add(const Duration(seconds: 61));
      expect(r.shouldSend('A'), isTrue);
      for (var i = 0; i < 30; i++) {
        r.shouldSend('B$i');
      }
      expect(r.sentCount, ErrorReporter.maxPerSession);
      expect(r.shouldSend('C'), isFalse);
    });

    test('textes tronqués', () {
      expect(ErrorReporter.truncate('abc', 10), 'abc');
      expect(ErrorReporter.truncate('a' * 600, 500).length, 500);
    });
  });

  group('jeton chiffré', () {
    test("migration : l'ancien jeton passe dans le stockage chiffré et quitte SharedPreferences", () async {
      SharedPreferences.setMockInitialValues({TokenStore.legacyKey: 'ancien-jeton'});
      FlutterSecureStorage.setMockInitialValues({});
      final store = TokenStore();
      expect(await store.read(), 'ancien-jeton'); // pas de déconnexion
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TokenStore.legacyKey), isNull);
      expect(await const FlutterSecureStorage().read(key: 'auth_token'), 'ancien-jeton');
      expect(await store.read(), 'ancien-jeton'); // lecture suivante : stockage chiffré
    });

    test('enregistrement et déconnexion', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final store = TokenStore();
      expect(await store.read(), isNull);
      expect(await store.save('nouveau'), isTrue);
      expect(await store.read(), 'nouveau');
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('stockage chiffré déjà rempli : la copie en clair est effacée', () async {
      SharedPreferences.setMockInitialValues({TokenStore.legacyKey: 'vieux'});
      FlutterSecureStorage.setMockInitialValues({'auth_token': 'actuel'});
      expect(await TokenStore().read(), 'actuel');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(TokenStore.legacyKey), isFalse);
    });
  });
}
