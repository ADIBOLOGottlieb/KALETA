import 'package:flutter_test/flutter_test.dart';
import 'package:kaleta/models.dart';
import 'package:kaleta/screens/client/order_estimate.dart';
import 'package:kaleta/utils/format.dart';

Map<String, dynamic> _order(Map<String, dynamic> extra) => {
      'id': 40,
      'user_id': 2,
      'status': 'confirmed',
      'mode': 'pickup',
      'phone': '22200000',
      'payment_method': 'cash',
      'subtotal': 6000,
      'delivery_fee': 0,
      'payment_fee': 0,
      'total': 6000,
      'created_at': '2026-10-04 12:00:00',
      'updated_at': '2026-10-04 12:00:00',
      'customer_name': 'Comptoir',
      'items': [
        {'product_id': 1, 'name': 'Poulet braisé', 'unit_price': 3000, 'quantity': 2},
      ],
      ...extra,
    };

Map<String, dynamic> _settingsJson(Map<String, dynamic> extra) => {
      'delivery_fee': 500,
      'min_order': 0,
      'is_open': true,
      'payment_fee_percent': 2,
      'payment_fee_percent_by_operator': {'flooz': 2, 'mixx': 3.5},
      ...extra,
    };

void main() {
  group('DeliveryZone', () {
    test('parsing complet et toJson', () {
      final z = DeliveryZone.fromJson({
        'id': 3,
        'name': 'Tokoin',
        'fee': 800,
        'active': 1,
        'position': 2,
        'center_lat': 6.15,
        'center_lng': 1.22,
        'radius_km': 2.5,
      });
      expect(z.id, 3);
      expect(z.name, 'Tokoin');
      expect(z.fee, 800);
      expect(z.active, isTrue);
      expect(z.position, 2);
      expect(z.hasArea, isTrue);
      expect(z.toJson(), {
        'name': 'Tokoin',
        'fee': 800,
        'active': true,
        'position': 2,
        'center_lat': 6.15,
        'center_lng': 1.22,
        'radius_km': 2.5,
      });
    });

    test('sans cercle, inactive', () {
      final z = DeliveryZone.fromJson({'id': '4', 'name': 'Bè', 'fee': '600', 'active': 0});
      expect(z.id, 4);
      expect(z.fee, 600);
      expect(z.active, isFalse);
      expect(z.hasArea, isFalse);
    });

    test('zone la moins chère et libellés', () {
      final zones = [
        DeliveryZone(id: 1, name: 'Tokoin', fee: 800),
        DeliveryZone(id: 2, name: 'Bè', fee: 600),
        DeliveryZone(id: 3, name: 'Agoè', fee: 300, active: false),
      ];
      expect(cheapestZoneFee(zones), 600);
      expect(cheapestZoneFee(const []), isNull);
      expect(cheapestZoneFee(null), isNull);
      expect(zoneOptionLabel(zones.first), 'Tokoin — ${formatPrice(800)}');
      expect(deliveryLineLabel(null, zoneName: 'Tokoin'), 'Livraison (Tokoin)');
      expect(deliveryLineLabel(DeliveryQuote(fee: 800, mode: 'zone', zoneId: 1, zoneName: 'Tokoin')),
          'Livraison (Tokoin)');
    });
  });

  group('DeliveryQuote (mode zone)', () {
    test('zone reconnue', () {
      final q = DeliveryQuote.fromJson({'fee': 800, 'mode': 'zone', 'zone_id': 1, 'zone_name': 'Tokoin', 'within_zone': true});
      expect(q.mode, 'zone');
      expect(q.zoneId, 1);
      expect(q.zoneName, 'Tokoin');
      expect(q.withinZone, isTrue);
    });

    test('aucune zone : message du serveur', () {
      final q = DeliveryQuote.fromJson({
        'fee': 0,
        'mode': 'zone',
        'zone_id': null,
        'within_zone': false,
        'message': 'Adresse hors des zones de livraison',
      });
      expect(q.zoneId, isNull);
      expect(q.withinZone, isFalse);
      expect(outOfZoneMessage(q), 'Adresse hors des zones de livraison');
      expect(outOfZoneMessage(DeliveryQuote(fee: 0, mode: 'zone', withinZone: false)),
          'Choisissez votre zone de livraison');
    });
  });

  group('AppSettings : frais de paiement et zones', () {
    test('par défaut le restaurant absorbe la commission', () {
      final s = AppSettings.fromJson(_settingsJson({}));
      expect(s.paymentFeesPaidBy, 'restaurant');
      expect(s.clientPaysFees, isFalse);
      expect(s.clientFeePercentFor('flooz'), 0);
      expect(s.clientFeePercentFor('mixx'), 0);
      // Le taux de l'agrégateur reste connu (commission réelle).
      expect(s.feePercentFor('mixx'), 3.5);
    });

    test("'client' : taux de l'opérateur facturé au client", () {
      final s = AppSettings.fromJson(_settingsJson({'payment_fees_paid_by': 'client'}));
      expect(s.clientPaysFees, isTrue);
      expect(s.clientFeePercentFor('flooz'), 2);
      expect(s.clientFeePercentFor('mixx'), 3.5);
    });

    test('valeur inconnue = restaurant', () {
      final s = AppSettings.fromJson(_settingsJson({'payment_fees_paid_by': 'n importe quoi'}));
      expect(s.paymentFeesPaidBy, 'restaurant');
    });

    test('mode zone et toJson', () {
      final s = AppSettings.fromJson(_settingsJson({'delivery_fee_mode': 'zone', 'payment_fees_paid_by': 'client'}));
      expect(s.feeByZone, isTrue);
      expect(s.feeByDistance, isFalse);
      final j = s.toJson();
      expect(j['delivery_fee_mode'], 'zone');
      expect(j['payment_fees_paid_by'], 'client');
      final back = AppSettings.fromJson({...j, 'is_open': true});
      expect(back.feeByZone, isTrue);
      expect(back.clientPaysFees, isTrue);
      expect(AppSettings.fromJson(_settingsJson({'delivery_fee_mode': 'autre'})).deliveryFeeMode, 'fixed');
    });

    test('résumé des frais de livraison (accueil)', () {
      final zone = AppSettings.fromJson(_settingsJson({'delivery_fee_mode': 'zone'}));
      expect(deliveryFeeSummary(zone), 'Livraison selon la zone');
      expect(deliveryFeeSummary(zone, zones: [DeliveryZone(id: 1, name: 'Bè', fee: 600)]),
          'Livraison dès ${formatPrice(600)}');
      final fixed = AppSettings.fromJson(_settingsJson({}));
      expect(deliveryFeeSummary(fixed), 'Livraison ${formatPrice(500)}');
      final distance = AppSettings.fromJson(_settingsJson({'delivery_fee_mode': 'distance'}));
      expect(deliveryFeeSummary(distance), 'Livraison dès ${formatPrice(500)}');
    });
  });

  group('total sans frais quand le restaurant absorbe la commission', () {
    final restaurant = AppSettings.fromJson(_settingsJson({}));
    final client = AppSettings.fromJson(_settingsJson({'payment_fees_paid_by': 'client'}));

    test('même total en espèces, Flooz et Mixx', () {
      final totals = [
        for (final m in ['cash', 'flooz', 'mixx'])
          OrderEstimate.forSettings(restaurant, subtotal: 5000, delivery: true, deliveryFee: 800, paymentMethod: m),
      ];
      for (final e in totals) {
        expect(e.paymentFee, 0);
        expect(e.total, 5800);
      }
    });

    test('le client paie : frais ajoutés comme avant', () {
      final e = OrderEstimate.forSettings(client, subtotal: 19700, delivery: true, deliveryFee: 1300, paymentMethod: 'flooz');
      expect(e.paymentFee, 429);
      expect(e.total, 21429);
      final cash = OrderEstimate.forSettings(client, subtotal: 19700, delivery: true, deliveryFee: 1300, paymentMethod: 'cash');
      expect(cash.paymentFee, 0);
    });
  });

  group('Order comptoir et zone', () {
    test('vente comptoir sur place', () {
      final o = Order.fromJson(_order({'source': 'counter', 'dine_in': 1}));
      expect(o.isCounter, isTrue);
      expect(o.dineIn, isTrue);
      expect(o.isDelivery, isFalse);
      expect(o.customerName, 'Comptoir');
      expect(orderModeLabel(o), 'Comptoir · Sur place');
    });

    test('vente comptoir à emporter avec nom', () {
      final o = Order.fromJson(_order({'source': 'counter', 'dine_in': false, 'customer_name': 'Kossi'}));
      expect(o.isCounter, isTrue);
      expect(o.dineIn, isFalse);
      expect(orderModeLabel(o), 'Comptoir · À emporter');
      expect(o.customerName, 'Kossi');
    });

    test("commande de l'app par défaut", () {
      final o = Order.fromJson(_order({}));
      expect(o.source, 'app');
      expect(o.isCounter, isFalse);
      expect(o.dineIn, isFalse);
      expect(orderModeLabel(o), 'À emporter');
    });

    test('livraison par zone', () {
      final o = Order.fromJson(_order({
        'mode': 'delivery',
        'delivery_fee': 800,
        'delivery_zone_id': 1,
        'delivery_zone_name': 'Tokoin',
      }));
      expect(o.deliveryZoneId, 1);
      expect(o.deliveryZoneName, 'Tokoin');
      expect(orderModeLabel(o), 'Livraison · Tokoin');
      expect(orderDeliveryLineLabel(o), 'Livraison (Tokoin)');
      final km = Order.fromJson(_order({'mode': 'delivery', 'delivery_distance_km': 3.4}));
      expect(orderDeliveryLineLabel(km), 'Livraison (3,4 km)');
      expect(orderModeLabel(km), 'Livraison');
    });
  });

  group('SalesReport', () {
    test('parsing complet', () {
      final r = SalesReport.fromJson({
        'from': '2026-09-01',
        'to': '2026-09-30',
        'totals': {'orders': 120, 'revenue': 600000, 'avg_basket': 5000, 'cancelled': 4, 'payment_fees': 3500},
        'by_channel': [
          {'channel': 'app', 'orders': 80, 'revenue': 420000},
          {'channel': 'counter', 'orders': 40, 'revenue': 180000},
        ],
        'by_mode': [
          {'mode': 'delivery', 'orders': 60, 'revenue': 330000},
          {'mode': 'dine_in', 'orders': 25, 'revenue': 110000},
        ],
        'by_payment': [
          {'method': 'flooz', 'orders': 30, 'revenue': 150000, 'fees': 3000},
        ],
        'by_driver': [
          {'driver_id': 7, 'name': 'Kofi', 'deliveries': 30, 'cash_collected': 90000, 'avg_minutes': 24.5},
        ],
        'daily': [
          {'day': '2026-09-01', 'orders': 4, 'revenue': 20000},
          {'day': '2026-09-02', 'orders': 0, 'revenue': 0},
        ],
        'top_products': [
          {'name': 'Poulet braisé', 'quantity': 50, 'revenue': 150000},
        ],
      });
      expect(r.from, '2026-09-01');
      expect(r.to, '2026-09-30');
      expect(r.orders, 120);
      expect(r.revenue, 600000);
      expect(r.avgBasket, 5000);
      expect(r.cancelled, 4);
      expect(r.paymentFees, 3500);
      expect(r.byChannel.map((b) => b.key), ['app', 'counter']);
      expect(r.byChannel.last.revenue, 180000);
      expect(r.byMode.last.key, 'dine_in');
      expect(r.byPayment.single.fees, 3000);
      expect(r.byDriver.single.name, 'Kofi');
      expect(r.byDriver.single.cashCollected, 90000);
      expect(r.byDriver.single.avgMinutes, 24.5);
      expect(r.daily.length, 2);
      expect(r.daily.last.orders, 0);
      expect(r.topProducts.single.quantity, 50);
    });

    test('réponse vide', () {
      final r = SalesReport.fromJson({});
      expect(r.orders, 0);
      expect(r.byChannel, isEmpty);
      expect(r.byDriver, isEmpty);
      expect(r.daily, isEmpty);
    });
  });
}
