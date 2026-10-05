import 'package:flutter_test/flutter_test.dart';
import 'package:kaleta/models.dart';
import 'package:kaleta/providers/cart_provider.dart';
import 'package:kaleta/utils/format.dart';

void main() {
  test('formatPrice groupe les milliers', () {
    expect(formatPrice(700), '700 FCFA');
    expect(formatPrice(7000), '7 000 FCFA');
    expect(formatPrice(1250000), '1 250 000 FCFA');
  });

  // Mêmes cas que backend/test/fees.test.js (valeurs identiques).
  test("frais de paiement : commission de l'agrégateur reportée sur le client (identique au serveur)", () {
    expect(paymentGrossFor(21000, 2), 21429); // 21 000 / 0,98 = 21 428,57 -> 21 429
    expect(paymentFeeFor(21000, 'flooz', 2), 429);
    expect(providerFeeOn(21429, 2), 429);
    expect(paymentGrossFor(21000, 3.5), 21762); // 21 000 / 0,965 = 21 761,66 -> 21 762
    expect(paymentFeeFor(21000, 'mixx', 3.5), 762);
    expect(providerFeeOn(21762, 3.5), 762);
    expect(paymentFeeFor(4000, 'flooz', 2), 82);
    expect(paymentFeeFor(4000, 'flooz', 2.5), 103);
    expect(paymentFeeFor(4000, 'flooz', 0), 0);
    expect(paymentFeeFor(21000, 'flooz', 1), 213);
    expect(paymentFeeFor(21000, 'flooz', 3), 650);
    expect(paymentFeeFor(4000, 'cash', 2), 0);
    expect(formatPercent(2.0), '2');
    expect(formatPercent(2.5), '2,5');
    expect(formatPercent(3.5), '3,5');
  });

  test('le restaurant reçoit sous-total + livraison (écart ≤ 1 F)', () {
    for (final p in [0, 1, 2, 2.5, 3, 3.5]) {
      for (var base = 2000; base <= 200000; base += 7) {
        final gross = paymentGrossFor(base, p);
        expect(gross - providerFeeOn(gross, p), base, reason: 'p=$p base=$base');
        // Si l'agrégateur arrondit au plus proche ou à l'inférieur : net entre base et base + 1.
        final exact = gross * p / 100;
        for (final fee in [exact.round(), exact.floor()]) {
          expect(gross - fee >= base && gross - fee <= base + 1, isTrue, reason: 'p=$p base=$base');
        }
      }
    }
  });

  test('taux par opérateur lu dans /api/settings (tolérant si absent)', () {
    final s = AppSettings.fromJson({
      'delivery_fee': 1000,
      'payment_fee_percent': 3.5,
      'payment_fee_percent_by_operator': {'flooz': 3.5, 'mixx': 2.5},
      'payment_fee_source': 'aggregator',
    });
    expect(s.feePercentFor('flooz'), 3.5);
    expect(s.feePercentFor('mixx'), 2.5);
    expect(s.feesFromAggregator, isTrue);
    expect(s.toJson().containsKey('payment_fee_percent'), isFalse); // n'écrase pas le réglage admin
    final old = AppSettings.fromJson({'payment_fee_percent': 2});
    expect(old.feePercentFor('mixx'), 2);
    expect(old.paymentFeeSource, 'settings');
    expect(old.toJson()['payment_fee_percent'], 2);
  });

  test('moyens de paiement alignés sur le serveur (flooz, mixx)', () {
    expect(paymentMethods.keys, ['cash', 'flooz', 'mixx']);
    expect(isMobileMoney('mixx'), isTrue);
    expect(isMobileMoney('cash'), isFalse);
    expect(paymentLabel('tmoney'), 'T-Money'); // anciennes commandes
  });

  test('nextStatus suit le mode de retrait', () {
    expect(nextStatus('ready', true), 'delivering');
    expect(nextStatus('ready', false), 'delivered');
    expect(nextStatus('delivered', true), isNull);
    expect(nextStatus('delivering', true), 'delivered');
  });

  test('livraison : « Livraison faite » (livreur) puis « Reçu » (client)', () {
    expect(trackingSteps(true), [
      'pending', 'confirmed', 'preparing', 'ready', 'delivering', driverDeliveredStep, 'delivered',
    ]);
    expect(trackingSteps(false), statusSteps(false));
    expect(trackingIndex('delivering', true), 4);
    expect(trackingIndex('delivering', true, driverDelivered: true), 5);
    expect(trackingIndex('delivered', true), 6);
    expect(trackingIndex('delivered', false), 4);
    expect(trackingIndex('cancelled', true), -1);
    expect(trackingLabel('delivered', true), 'Reçue');
    expect(trackingLabel('delivered', false), 'Récupérée');
    expect(statusLabel(driverDeliveredStep), 'Livrée par le livreur');
    // L'admin ne passe plus « Livrée » tant que le livreur n'a pas confirmé.
    expect(adminNextStatus('delivering', true), isNull);
    expect(adminNextStatus('delivering', true, driverDelivered: true), 'delivered');
    expect(adminNextStatus('ready', true), 'delivering');
    expect(adminNextStatus('ready', false), 'delivered'); // à emporter : inchangé
  });

  test('le panier calcule quantités et sous-total', () {
    final cart = CartProvider();
    final poulet = Product(id: 1, name: 'Poulet', price: 3800);
    final alloco = Product(id: 2, name: 'Alloco', price: 1000);
    cart.add(poulet);
    cart.add(poulet, 2);
    cart.add(alloco);
    expect(cart.count, 4);
    expect(cart.subtotal, 3 * 3800 + 1000);
    cart.setQuantity(1, 0);
    expect(cart.count, 1);
    expect(cart.toOrderItems(), [
      {'product_id': 2, 'quantity': 1},
    ]);
  });

  test('quantité plafonnée à $maxQuantityPerItem par article', () {
    expect(maxQuantityPerItem, 999);
    final cart = CartProvider();
    final poulet = Product(id: 1, name: 'Poulet', price: 3800);
    cart.add(poulet, 120);
    expect(cart.quantityOf(1), 120); // plus de limite à 50
    cart.add(poulet, 900);
    expect(cart.quantityOf(1), maxQuantityPerItem);
    cart.setQuantity(1, 5000);
    expect(cart.quantityOf(1), 999);
    cart.setQuantity(1, 998);
    cart.add(poulet);
    cart.add(poulet);
    expect(cart.quantityOf(1), 999);
    cart.add(Product(id: 2, name: 'Alloco', price: 1000), 2000);
    expect(cart.quantityOf(2), 999);
    cart.add(poulet, 0); // ignoré
    expect(cart.quantityOf(1), 999);
  });

  test('saisie de quantité au clavier', () {
    expect(parseQuantity('12'), 12);
    expect(parseQuantity(' 999 '), 999);
    expect(parseQuantity('1000'), isNull);
    expect(parseQuantity('0'), isNull);
    expect(parseQuantity('0', min: 0), 0); // 0 = retirer l'article
    expect(parseQuantity(''), isNull);
    expect(parseQuantity('abc'), isNull);
  });

  test('statut de paiement et compte à rebours', () {
    expect(paymentStatusLabel('refunded'), 'Remboursé');
    expect(paymentStatusLabel('failed'), 'Paiement non abouti');
    expect(paymentStatusLabel('expired'), 'Paiement non abouti');
    expect(paymentStatusLabel('paid'), 'Payée');
    expect(formatCountdown(const Duration(minutes: 2)), '2:00');
    expect(formatCountdown(const Duration(seconds: 65)), '1:05');
    expect(formatCountdown(const Duration(seconds: -3)), '0:00');
  });

  test('estimation du panier = formule serveur (sous-total + livraison + frais)', () {
    const subtotal = 20000, delivery = 1000;
    final fee = paymentFeeFor(subtotal + delivery, 'flooz', 2);
    expect(fee, 429);
    expect(subtotal + delivery + fee, 21429);
    expect(subtotal + delivery + paymentFeeFor(subtotal + delivery, 'flooz', 3.5), 21762);
  });
}
