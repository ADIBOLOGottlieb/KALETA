import 'package:flutter_test/flutter_test.dart';
import 'package:kaleta/services/maps_link.dart';

void main() {
  void near(num? actual, num expected, [double tol = 1e-4]) {
    expect(actual, isNotNull);
    expect((actual! - expected).abs(), lessThan(tol), reason: 'attendu $expected, obtenu $actual');
  }

  group('parseCoordinatesFromUrl', () {
    test('URL longue : !3d!4d prioritaire sur @', () {
      final l = parseCoordinatesFromUrl(
          'https://www.google.com/maps/place/Chez+Ama/@6.1300,1.2200,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d6.13195!4d1.22281!16s');
      near(l?.lat, 6.13195);
      near(l?.lng, 1.22281);
      expect(l?.label, 'Chez Ama');
      expect(l?.source, 'google_maps');
    });

    test('URL longue avec seulement @lat,lng', () {
      final l = parseCoordinatesFromUrl('https://www.google.com/maps/@6.1319,1.2228,15z');
      near(l?.lat, 6.1319);
      near(l?.lng, 1.2228);
    });

    test('google.com/maps?q=lat,lng', () {
      final l = parseCoordinatesFromUrl('https://www.google.com/maps?q=6.13,1.22');
      near(l?.lat, 6.13);
      near(l?.lng, 1.22);
    });

    test('maps.google.com/?q=… avec autres paramètres', () {
      final l = parseCoordinatesFromUrl('https://maps.google.com/?q=6.1319,1.2228&z=16&hl=fr');
      near(l?.lat, 6.1319);
      near(l?.lng, 1.2228);
    });

    test('search/?api=1&query=', () {
      final l = parseCoordinatesFromUrl('https://www.google.com/maps/search/?api=1&query=6.13%2C1.22');
      near(l?.lat, 6.13);
      near(l?.lng, 1.22);
    });

    test('geo: et geo:0,0?q=', () {
      final a = parseCoordinatesFromUrl('geo:6.13,1.22?q=6.13,1.22(Chez Ama)');
      near(a?.lat, 6.13);
      near(a?.lng, 1.22);
      final b = parseCoordinatesFromUrl('geo:0,0?q=6.1319,1.2228(Repère)');
      near(b?.lat, 6.1319);
      near(b?.lng, 1.2228);
    });

    test('ll= et center=lat%2Clng', () {
      final a = parseCoordinatesFromUrl('https://maps.google.com/maps?ll=6.13,1.22&z=17');
      near(a?.lat, 6.13);
      final b = parseCoordinatesFromUrl(
          'https://www.google.com/maps/@?api=1&map_action=map&center=6.1319%2C1.2228&zoom=17');
      near(b?.lat, 6.1319);
      near(b?.lng, 1.2228);
    });

    test('chemin /maps/search/lat,+lng et /maps/place/lat,lng', () {
      final a = parseCoordinatesFromUrl('https://www.google.com/maps/search/6.1319,+1.2228');
      near(a?.lat, 6.1319);
      near(a?.lng, 1.2228);
      final b = parseCoordinatesFromUrl('https://www.google.com/maps/place/6.1319,1.2228');
      near(b?.lng, 1.2228);
    });

    test('lien court non résolu et URL sans position → null', () {
      expect(parseCoordinatesFromUrl('https://maps.app.goo.gl/AbCdEf12345'), isNull);
      expect(parseCoordinatesFromUrl('https://www.google.com/maps/place/Chez+Ama'), isNull);
      expect(parseCoordinatesFromUrl('geo:0,0'), isNull);
      expect(parseCoordinatesFromUrl('https://maps.google.com/?q=95.0,1.0'), isNull);
    });
  });

  group('parseCoordinateText', () {
    test('décimal avec virgule / espace / point-virgule', () {
      near(parseCoordinateText('6.1319, 1.2228')?.lat, 6.1319);
      near(parseCoordinateText('6.1319,1.2228')?.lng, 1.2228);
      near(parseCoordinateText('6.1319 1.2228')?.lng, 1.2228);
      near(parseCoordinateText('6,1319 ; 1,2228')?.lng, 1.2228);
      near(parseCoordinateText('-33.8688, 151.2093')?.lat, -33.8688);
    });

    test('décimal avec hémisphères', () {
      final p = parseCoordinateText('33.8688° S, 70.6693° W');
      near(p?.lat, -33.8688);
      near(p?.lng, -70.6693);
    });

    test('DMS', () {
      final p = parseCoordinateText('6°07\'55.0"N 1°13\'22.1"E');
      near(p?.lat, 6 + 7 / 60 + 55.0 / 3600);
      near(p?.lng, 1 + 13 / 60 + 22.1 / 3600);
      final q = parseCoordinateText('6° 07′ 55″ N, 1° 13′ 22″ O');
      near(q?.lng, -(1 + 13 / 60 + 22 / 3600));
    });

    test('textes invalides → null', () {
      expect(parseCoordinateText(''), isNull);
      expect(parseCoordinateText('Rue 123, Lomé, Togo'), isNull);
      expect(parseCoordinateText('0.0, 0.0'), isNull);
      expect(parseCoordinateText('95.5, 1.2'), isNull);
      expect(parseCoordinateText('+228 90 12 34 56'), isNull);
    });
  });

  group('decodePlusCode', () {
    test('exemples officiels OLC (Zurich, Praia)', () {
      // 8FVC9G8F+6X : cellule de 0,000125° contenant (47.365562, 8.524813) ; on renvoie son centre.
      final z = decodePlusCode('8FVC9G8F+6X');
      near(z?.lat, 47.365562, 1.25e-4);
      near(z?.lng, 8.524813, 1.25e-4);
      final p = decodePlusCode('796RWF8Q+WF');
      near(p?.lat, 14.917313, 1e-5);
      near(p?.lng, -23.511313, 1e-5);
    });

    test('code complet encodé puis décodé (Lomé)', () {
      final code = encodePlusCode(6.1319, 1.2228);
      final p = decodePlusCode(code);
      near(p?.lat, 6.1319, 2e-4);
      near(p?.lng, 1.2228, 2e-4);
    });

    test('code court récupéré près de Lomé', () {
      final full = encodePlusCode(6.1700, 1.2500);
      final short = '${full.substring(4)} Lomé';
      final p = decodePlusCode(short);
      near(p?.lat, 6.17, 2e-4);
      near(p?.lng, 1.25, 2e-4);
    });

    test('recoverNearest : vecteur officiel et passage de degré', () {
      final a = decodePlusCode('9QCJ+2VX', refLat: 51.3708675, refLng: -1.217765625);
      near(a?.lat, 51.3701125, 1e-6);
      near(a?.lng, -1.217765625, 1e-6);
      // Code juste sous 7° N, référence juste au-dessus : doit rester à 6,99°, pas 7,99°.
      final short = encodePlusCode(6.9995, 1.5).substring(4);
      final b = decodePlusCode(short, refLat: 7.0005, refLng: 1.5);
      near(b?.lat, 6.9995, 2e-4);
    });

    test('codes invalides → null', () {
      expect(decodePlusCode('BONJOUR'), isNull);
      expect(decodePlusCode('6CJ8+X'), isNull);
      expect(decodePlusCode('ZZZZ+ZZ'), isNull);
    });
  });

  group('texte partagé (sans réseau)', () {
    test('looksLikeLocationText', () {
      expect(looksLikeLocationText('Chez Ama\nRue 123, Lomé, Togo\nhttps://maps.app.goo.gl/AbCdEf12345'), isTrue);
      expect(looksLikeLocationText('https://goo.gl/maps/xyz'), isTrue);
      expect(looksLikeLocationText('6.1319, 1.2228'), isTrue);
      expect(looksLikeLocationText('6CJ8+X7 Lomé'), isTrue);
      expect(looksLikeLocationText('Bonjour, je veux 2 poulets'), isFalse);
      expect(looksLikeLocationText('https://example.com/page'), isFalse);
    });

    test('lieu nommé : nom + adresse + URL longue', () async {
      final l = await parseLocationText(
          'Chez Ama\nRue 123, Lomé, Togo\nhttps://www.google.com/maps/place/Chez+Ama/@6.13,1.22,17z/data=!3d6.13195!4d1.22281');
      near(l?.lat, 6.13195);
      expect(l?.label, 'Chez Ama');
      expect(l?.address, 'Rue 123, Lomé, Togo');
      expect(l?.source, 'google_maps');
    });

    test('coordonnées et plus code saisis à la main', () async {
      final a = await parseLocationText('6.1319, 1.2228');
      expect(a?.source, 'coordinates');
      final b = await parseLocationText('${encodePlusCode(6.13, 1.22).substring(4)} Lomé');
      expect(b?.source, 'plus_code');
      near(b?.lat, 6.13, 2e-4);
      expect(await parseLocationText('rien à voir'), isNull);
    });
  });
}
