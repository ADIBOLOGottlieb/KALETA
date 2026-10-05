import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaleta/models.dart';
import 'package:kaleta/providers/cart_provider.dart';
import 'package:kaleta/utils/format.dart' show maxQuantityPerItem;
import 'package:shared_preferences/shared_preferences.dart';

Product _p(int id, int price, {String? name, bool available = true}) =>
    Product(id: id, name: name ?? 'Plat $id', price: price, available: available);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('ajout, quantités et total', () {
    final cart = CartProvider();
    var notified = 0;
    cart.addListener(() => notified++);
    expect(cart.isEmpty, isTrue);

    cart.add(_p(1, 2500));
    cart.add(_p(2, 1000), 3);
    cart.add(_p(1, 2500)); // même plat : quantité cumulée
    expect(cart.lines, hasLength(2));
    expect(cart.quantityOf(1), 2);
    expect(cart.quantityOf(2), 3);
    expect(cart.count, 5);
    expect(cart.subtotal, 2 * 2500 + 3 * 1000);
    expect(notified, 3);

    cart.add(_p(3, 500), 0); // quantité nulle ignorée
    expect(cart.quantityOf(3), 0);

    expect(cart.toOrderItems(), [
      {'product_id': 1, 'quantity': 2},
      {'product_id': 2, 'quantity': 3},
    ]);
  });

  test('modification et retrait', () {
    final cart = CartProvider()
      ..add(_p(1, 2500))
      ..add(_p(2, 1000), 2);
    cart.setQuantity(1, 4);
    expect(cart.quantityOf(1), 4);
    cart.setQuantity(2, 0); // 0 = retrait
    expect(cart.quantityOf(2), 0);
    expect(cart.lines, hasLength(1));
    cart.setQuantity(99, 3); // produit absent : rien
    expect(cart.lines, hasLength(1));
    cart.setQuantity(1, maxQuantityPerItem + 50);
    expect(cart.quantityOf(1), maxQuantityPerItem);
    cart.remove(1);
    expect(cart.isEmpty, isTrue);
    expect(cart.subtotal, 0);
  });

  test('vider le panier', () {
    final cart = CartProvider()..add(_p(1, 2500), 2);
    cart.clear();
    expect(cart.isEmpty, isTrue);
    expect(cart.count, 0);
  });

  group('syncWithCatalog', () {
    test('rien ne change : null', () {
      final cart = CartProvider()..add(_p(1, 2500));
      expect(cart.syncWithCatalog([_p(1, 2500), _p(2, 900)]), isNull);
      expect(CartProvider().syncWithCatalog([_p(1, 1)]), isNull); // panier vide
    });

    test('prix mis à jour', () {
      final cart = CartProvider()..add(_p(1, 2500), 2);
      final msg = cart.syncWithCatalog([_p(1, 3000)]);
      expect(msg, "Le prix d'un article du panier a changé.");
      expect(cart.subtotal, 6000);
      expect(cart.quantityOf(1), 2);
    });

    test('produits supprimés ou indisponibles retirés', () {
      final cart = CartProvider()
        ..add(_p(1, 2500, name: 'Poulet braisé'))
        ..add(_p(2, 1000))
        ..add(_p(3, 800));
      final one = CartProvider()..add(_p(1, 2500, name: 'Poulet braisé'));
      expect(one.syncWithCatalog([_p(1, 2500, available: false)]),
          '« Poulet braisé » n\'est plus disponible : retiré du panier.');
      expect(one.isEmpty, isTrue);

      final msg = cart.syncWithCatalog([_p(1, 2500, available: false), _p(3, 900)]);
      expect(msg, contains('2 articles ne sont plus disponibles'));
      expect(msg, contains("Le prix d'un article du panier a changé."));
      expect(cart.lines.map((l) => l.product.id), [3]);
      expect(cart.subtotal, 900);
    });

    test('nom ou image modifiés : ligne rafraîchie sans message', () {
      final cart = CartProvider()..add(_p(1, 2500, name: 'Ancien'));
      expect(cart.syncWithCatalog([_p(1, 2500, name: 'Nouveau')]), isNull);
      expect(cart.lines.single.product.name, 'Nouveau');
    });
  });

  test('panier enregistré par compte (SharedPreferences)', () async {
    SharedPreferences.setMockInitialValues({
      'cart_v1_5': jsonEncode([
        {'id': 1, 'name': 'Plat 1', 'price': 2500, 'available': true, 'quantity': 2},
        {'id': 0, 'name': 'invalide', 'price': 1, 'quantity': 1},
      ]),
    });
    final cart = CartProvider();
    await cart.attachUser(5);
    expect(cart.quantityOf(1), 2);
    expect(cart.lines, hasLength(1));

    cart.add(_p(2, 1000));
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('cart_v1_5')!) as List;
    expect(saved, hasLength(2));

    // Déconnexion : panier vidé et copie supprimée.
    cart.reset();
    await Future<void>.delayed(Duration.zero);
    expect(cart.isEmpty, isTrue);
    expect(prefs.getString('cart_v1_5'), isNull);
  });
}
