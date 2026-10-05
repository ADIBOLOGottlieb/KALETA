import 'package:flutter_test/flutter_test.dart';
import 'package:kaleta/models.dart';

Map<String, dynamic> _order(Map<String, dynamic> extra) => {
      'id': 12,
      'user_id': 3,
      'status': 'delivering',
      'mode': 'delivery',
      'phone': '90000000',
      'payment_method': 'flooz',
      'subtotal': 5000,
      'delivery_fee': 1300,
      'payment_fee': 129,
      'total': 6429,
      'created_at': '2026-10-04 12:00:00',
      'updated_at': '2026-10-04 12:05:00',
      'customer_name': 'Ama',
      'items': [
        {'product_id': 1, 'name': 'Poulet braisé', 'unit_price': 2500, 'quantity': 2},
      ],
      ...extra,
    };

void main() {
  group('Order', () {
    test('suivi en direct : driver_location, eta_minutes, delivery_distance_km', () {
      final o = Order.fromJson(_order({
        'driver_id': 7,
        'driver_name': 'Kofi',
        'driver_location': {
          'lat': 6.13,
          'lng': 1.22,
          'accuracy': 12,
          'heading': 90.5,
          'updated_at': '2026-10-04 12:04:00',
        },
        'eta_minutes': 8,
        'delivery_distance_km': 3.4,
      }));
      expect(o.driverLocation, isNotNull);
      expect(o.driverLocation!.lat, 6.13);
      expect(o.driverLocation!.lng, 1.22);
      expect(o.driverLocation!.accuracy, 12.0);
      expect(o.driverLocation!.heading, 90.5);
      expect(o.driverLocation!.updatedAt.toUtc(), DateTime.utc(2026, 10, 4, 12, 4));
      expect(o.etaMinutes, 8);
      expect(o.deliveryDistanceKm, 3.4);
      expect(o.isTrackable, isTrue);
      expect(o.itemCount, 2);
    });

    test('sans position du livreur : champs null, pas de suivi', () {
      final o = Order.fromJson(_order({'driver_location': null, 'eta_minutes': null}));
      expect(o.driverLocation, isNull);
      expect(o.etaMinutes, isNull);
      expect(o.deliveryDistanceKm, isNull);
      expect(o.isTrackable, isFalse);
    });

    test('position invalide ignorée ; « Livraison faite » arrête le suivi', () {
      final bad = Order.fromJson(_order({
        'driver_location': {'lat': 'x', 'lng': 1.2},
      }));
      expect(bad.driverLocation, isNull);
      final done = Order.fromJson(_order({
        'driver_location': {'lat': 6.1, 'lng': 1.2, 'updated_at': '2026-10-04 12:04:00'},
        'driver_delivered_at': '2026-10-04 12:10:00',
      }));
      expect(done.awaitingReceipt, isTrue);
      expect(done.isTrackable, isFalse);
    });
  });

  group('AppSettings', () {
    final json = {
      'delivery_fee': 500,
      'min_order': 2000,
      'is_open': false,
      'manual_open': true,
      'hours_enabled': true,
      'opening_hours': {
        'mon': [
          ['10:00', '14:00'],
          ['18:00', '22:00'],
        ],
        'sun': [],
        'xyz': [
          ['01:00', '02:00'],
        ],
      },
      'next_opening_at': '2026-10-05T10:00:00.000Z',
      'next_closing_at': null,
      'delivery_fee_mode': 'distance',
      'delivery_fee_per_km': 200,
      'delivery_free_km': 2,
      'delivery_max_km': 15.5,
      'restaurant_phone': '+22890000000',
      'restaurant_address': 'Lomé',
    };

    test('horaires : état effectif, interrupteur manuel, plages et prochaine ouverture', () {
      final s = AppSettings.fromJson(json);
      expect(s.isOpen, isFalse);
      expect(s.manualOpen, isTrue);
      expect(s.hoursEnabled, isTrue);
      expect(s.openingHours['mon'], [
        ['10:00', '14:00'],
        ['18:00', '22:00'],
      ]);
      expect(s.openingHours['sun'], isEmpty);
      expect(s.openingHours.containsKey('xyz'), isFalse);
      expect(s.nextOpeningAt!.toUtc(), DateTime.utc(2026, 10, 5, 10));
      expect(s.nextClosingAt, isNull);
    });

    test('frais au kilomètre', () {
      final s = AppSettings.fromJson(json);
      expect(s.feeByDistance, isTrue);
      expect(s.deliveryFeePerKm, 200);
      expect(s.deliveryFreeKm, 2.0);
      expect(s.deliveryMaxKm, 15.5);
    });

    test('anciens serveurs : manual_open absent = is_open, frais fixes', () {
      final s = AppSettings.fromJson({'delivery_fee': 500, 'min_order': 0, 'is_open': true});
      expect(s.manualOpen, isTrue);
      expect(s.hoursEnabled, isFalse);
      expect(s.openingHours, isEmpty);
      expect(s.feeByDistance, isFalse);
      expect(s.deliveryMaxKm, 0);
    });

    test("toJson renvoie l'interrupteur manuel dans is_open (pas l'état effectif)", () {
      final s = AppSettings.fromJson(json);
      final out = s.toJson();
      expect(out['is_open'], isTrue); // manuel ouvert, même si fermé par les horaires
      expect(out['hours_enabled'], isTrue);
      expect(out['delivery_fee_mode'], 'distance');
      expect(out['delivery_fee_per_km'], 200);
      expect(out['delivery_max_km'], 15.5);
      expect((out['opening_hours'] as Map)['mon'], hasLength(2));
    });
  });

  group('AdminStats', () {
    test('comparaison avec la semaine dernière et créneau de pointe', () {
      final s = AdminStats.fromJson({
        'today': {'orders': 12, 'revenue': 60000},
        'total': {'orders': 300, 'revenue': 1500000},
        'active': 3,
        'pending': 1,
        'customers': 80,
        'topProducts': [],
        'last7Days': [],
        'same_day_last_week': {'orders': 10, 'revenue': 50000},
        'revenue_change_percent': 20,
        'orders_change_percent': 20.0,
        'hourly': [for (var h = 0; h < 24; h++) h == 12 ? 9 : 1],
        'peak_window': {'start_hour': 12, 'end_hour': 14, 'orders': 10},
      });
      expect(s.lastWeekOrders, 10);
      expect(s.lastWeekRevenue, 50000);
      expect(s.revenueChangePercent, 20.0);
      expect(s.ordersChangePercent, 20.0);
      expect(s.hourly, hasLength(24));
      expect(s.hourly[12], 9);
      expect(s.peakStartHour, 12);
      expect(s.peakEndHour, 14);
    });

    test('sans point de comparaison ni commande : null', () {
      final s = AdminStats.fromJson({
        'today': {'orders': 0, 'revenue': 0},
        'total': {'orders': 0, 'revenue': 0},
        'revenue_change_percent': null,
        'orders_change_percent': null,
        'peak_window': null,
      });
      expect(s.revenueChangePercent, isNull);
      expect(s.ordersChangePercent, isNull);
      expect(s.peakStartHour, isNull);
      expect(s.peakEndHour, isNull);
      expect(s.hourly, isEmpty);
      expect(s.lastWeekOrders, 0);
    });
  });

  group('AppUser', () {
    AppUser user(String role, [String? level]) =>
        AppUser.fromJson({'id': 1, 'name': 'X', 'phone': '9', 'role': role, 'admin_level': level});

    test('propriétaire et gérant', () {
      expect(user('admin', 'owner').isOwner, isTrue);
      expect(user('admin', 'owner').isManager, isTrue);
      expect(user('admin', 'manager').isManager, isTrue);
      expect(user('admin', 'manager').isOwner, isFalse);
      // Ancien compte admin sans niveau = gérant.
      expect(user('admin').isManager, isTrue);
      expect(user('admin').isOwner, isFalse);
      expect(user('admin').adminLevel, isNull);
    });

    test("client et livreur ne sont ni propriétaire ni gérant", () {
      for (final role in ['customer', 'driver']) {
        expect(user(role).isManager, isFalse);
        expect(user(role, 'owner').isOwner, isFalse);
      }
    });

    test('StaffMember : ancien niveau « cuisine » lu comme gérant', () {
      StaffMember member(String? level) =>
          StaffMember.fromJson({'id': 1, 'name': 'X', 'phone': '9', 'admin_level': level, 'created_at': '2026-01-01'});
      expect(member('owner').isOwner, isTrue);
      expect(member('manager').adminLevel, 'manager');
      expect(member('kitchen').adminLevel, 'manager');
      expect(member(null).adminLevel, 'manager');
    });
  });

  test('DeliveryQuote : distance, zone et limite', () {
    final q = DeliveryQuote.fromJson({
      'fee': 1300,
      'distance_km': 3.4,
      'mode': 'distance',
      'within_zone': true,
      'max_km': null,
    });
    expect(q.fee, 1300);
    expect(q.distanceKm, 3.4);
    expect(q.withinZone, isTrue);
    expect(q.maxKm, isNull);
    final out = DeliveryQuote.fromJson({
      'fee': 3500,
      'distance_km': 18.2,
      'mode': 'distance',
      'within_zone': false,
      'max_km': 15,
      'message': 'Adresse hors de la zone de livraison (18,2 km, maximum 15 km)',
    });
    expect(out.withinZone, isFalse);
    expect(out.maxKm, 15.0);
    expect(out.message, contains('hors de la zone'));
  });
}
