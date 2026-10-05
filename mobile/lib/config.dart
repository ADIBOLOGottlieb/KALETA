/// Adresse de l'API.
///
/// Par défaut : le serveur de production (HTTPS).
/// Le dev local passe par --dart-define=API_URL=http://10.0.2.2:4000 (émulateur Android ;
/// sur un vrai téléphone, l'IP du PC sur le Wi-Fi, ex. http://192.168.1.20:4000).
/// Le HTTP en clair n'est autorisé que dans les builds debug/profile.
const String apiBaseUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'https://eza-zozo-api-5fib.onrender.com',
);

/// Transforme un chemin relatif (`/uploads/...`) renvoyé par l'API en URL complète.
String resolveImageUrl(String? url) {
  if (url == null || url.isEmpty) return '';
  if (url.startsWith('http')) return url;
  return '$apiBaseUrl$url';
}

/// Clé Google Maps Platform (Map Tiles API, Places API (New), Geocoding API, Routes API).
///
/// Lue à la compilation : `flutter build apk --dart-define=GOOGLE_MAPS_API_KEY=...`
/// Sans clé, la carte utilise automatiquement OpenStreetMap + Nominatim.
/// Dans Google Cloud, restreindre la clé aux applications Android
/// (package [androidPackageName] + empreinte SHA-1 du certificat de signature)
/// et aux 4 API ci-dessus.
const String googleMapsApiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

bool get hasGoogleMapsKey => googleMapsApiKey.isNotEmpty;

/// Identifiant Android de l'app (applicationId de android/app/build.gradle.kts).
/// Envoyé dans l'en-tête `X-Android-Package` des appels Google (clé restreinte Android).
const String androidPackageName = 'com.kaleta.app';

/// Empreinte SHA-1 du certificat de signature (ex. `AB:CD:...`), facultative :
/// `--dart-define=GOOGLE_ANDROID_CERT_SHA1=...`. Envoyée dans `X-Android-Cert`,
/// nécessaire pour qu'une clé restreinte « applications Android » accepte les appels REST.
const String googleAndroidCertSha1 = String.fromEnvironment('GOOGLE_ANDROID_CERT_SHA1');
