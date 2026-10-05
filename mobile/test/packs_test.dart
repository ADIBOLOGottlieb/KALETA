import 'package:flutter_test/flutter_test.dart';
import 'package:kaleta/models.dart';

/// Pack tel que renvoyé par `GET /api/products?all=1`.
Map<String, dynamic> _pack({bool available = true, bool availableRaw = true, bool componentsAvailable = true}) => {
      'id': 40,
      'category_id': 7,
      'name': 'Pack Solo',
      'description': 'Le repas complet',
      'price': 4900,
      'image_url': null,
      'available': available,
      'available_raw': availableRaw,
      'components_available': componentsAvailable,
      'popular': 0,
      'is_pack': true,
      'pack_items': [
        {'product_id': 1, 'name': 'Demi-poulet braisé', 'quantity': 1, 'price': 3500, 'available': true},
        {'product_id': 5, 'name': 'Alloco', 'quantity': 2, 'price': 500, 'available': componentsAvailable},
        {'product_id': 9, 'name': 'Bissap', 'quantity': 1, 'price': 1000, 'available': true},
      ],
      'pack_value': 5500,
      'savings': 600,
    };

void main() {
  group('Product pack', () {
    test('parse les plats, la valeur, l\'économie et available_raw', () {
      final p = Product.fromJson(_pack());
      expect(p.isPack, isTrue);
      expect(p.packItems, hasLength(3));
      expect(p.packItems[1].productId, 5);
      expect(p.packItems[1].name, 'Alloco');
      expect(p.packItems[1].quantity, 2);
      expect(p.packItems[1].price, 500);
      expect(p.packValue, 5500);
      expect(p.savings, 600);
      expect(p.available, isTrue);
      expect(p.availableRaw, isTrue);
    });

    test('un plat simple n\'est pas un pack', () {
      final p = Product.fromJson({'id': 1, 'name': 'Alloco', 'price': 500, 'available': true, 'pack_items': []});
      expect(p.isPack, isFalse);
      expect(p.packItems, isEmpty);
      expect(p.packValue, isNull);
      expect(p.savings, 0);
      expect(p.availableRaw, isNull);
      expect(p.packBlockedByComponent, isFalse);
      expect(p.packSummary, '');
    });

    test('packSummary liste quantités et noms', () {
      expect(Product.fromJson(_pack()).packSummary, '1× Demi-poulet braisé, 2× Alloco, 1× Bissap');
    });

    test('packBlockedByComponent : activé par l\'admin mais un plat est épuisé', () {
      final blocked = Product.fromJson(_pack(available: false, componentsAvailable: false));
      expect(blocked.available, isFalse);
      expect(blocked.availableRaw, isTrue);
      expect(blocked.packBlockedByComponent, isTrue);

      // Désactivé par l'admin : pas « bloqué par un plat ».
      final off = Product.fromJson(_pack(available: false, availableRaw: false, componentsAvailable: false));
      expect(off.packBlockedByComponent, isFalse);

      expect(Product.fromJson(_pack()).packBlockedByComponent, isFalse);
    });

    test('toJson envoie pack_items et l\'interrupteur brut', () {
      final blocked = Product.fromJson(_pack(available: false, componentsAvailable: false));
      final json = blocked.toJson();
      expect(json['pack_items'], [
        {'product_id': 1, 'quantity': 1},
        {'product_id': 5, 'quantity': 2},
        {'product_id': 9, 'quantity': 1},
      ]);
      // available = interrupteur de l'admin (true), pas la disponibilité calculée (false).
      expect(json['available'], isTrue);

      final off = Product.fromJson(_pack(available: false, availableRaw: false));
      expect(off.toJson()['available'], isFalse);
    });

    test('toJson d\'un plat simple : pack_items vide', () {
      final p = Product(id: 0, name: 'Alloco', price: 500, available: false);
      expect(p.toJson()['pack_items'], isEmpty);
      expect(p.toJson()['available'], isFalse);
    });
  });

  group('OrderItem.details', () {
    test('contenu figé d\'un pack', () {
      final i = OrderItem.fromJson({
        'product_id': 40,
        'name': 'Pack Solo',
        'unit_price': 4900,
        'quantity': 2,
        'details': '1× Demi-poulet braisé, 2× Alloco, 1× Bissap',
      });
      expect(i.details, '1× Demi-poulet braisé, 2× Alloco, 1× Bissap');
      expect(i.total, 9800);
    });

    test('null pour un plat simple', () {
      final i = OrderItem.fromJson({'product_id': 1, 'name': 'Alloco', 'unit_price': 500, 'quantity': 1});
      expect(i.details, isNull);
    });
  });
}
