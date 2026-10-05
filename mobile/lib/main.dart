import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'providers/auth_provider.dart';
import 'providers/cart_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/admin/admin_shell.dart';
import 'screens/auth/login_screen.dart';
import 'screens/client/client_shell.dart';
import 'screens/connection_screen.dart';
import 'screens/driver/driver_order_detail_screen.dart';
import 'screens/driver/driver_shell.dart';
import 'screens/onboarding_screen.dart';
import 'screens/shared/order_detail_screen.dart';
import 'screens/splash_screen.dart';
import 'services/api.dart';
import 'services/error_reporter.dart';
import 'services/maps_link.dart';
import 'services/push_service.dart';
import 'services/shared_location.dart';
import 'theme.dart';

/// Messager global : messages affichés hors de tout écran précis (ex. position partagée depuis Google Maps).
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Navigateur racine : à la déconnexion (ou session expirée), on ferme tous les écrans poussés.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Plantages remontés au serveur (journal du gérant) : jamais bloquant. Pas de runZonedGuarded :
  // PlatformDispatcher.onError attrape déjà les erreurs asynchrones, sans souci de zone.
  ErrorReporter.instance.install();

  // Réception des positions partagées depuis l'app Google Maps (sans bloquer le démarrage).
  unawaited(SharedLocationService.instance.init().catchError((Object e) {
    if (kDebugMode) debugPrint('Partage Google Maps indisponible : $e');
  }));

  // Notifications push : sans Firebase configuré, sans effet ; ne bloque jamais.
  unawaited(PushService.instance.init().catchError((Object e) {
    if (kDebugMode) debugPrint('Notifications indisponibles : $e');
  }));

  final cart = CartProvider();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: cart),
        ChangeNotifierProvider(create: (_) => AuthProvider(cart: cart)..init()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()..init()),
      ],
      child: const KaletaApp(),
    ),
  );
}

class KaletaApp extends StatelessWidget {
  const KaletaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (_, themeProvider, _) {
        return MaterialApp(
          title: 'KALETA',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: themeProvider.themeMode,
          // Calendriers, sélecteurs et textes système en français.
          locale: const Locale('fr'),
          supportedLocales: const [Locale('fr')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const _Root(),
        );
      },
    );
  }
}

/// Aiguille vers l'onboarding, l'espace client, livreur ou admin selon le compte connecté.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool? _onboardingCompleted;

  final _shared = SharedLocationService.instance;
  final _push = PushService.instance;
  late final AuthProvider _auth = context.read<AuthProvider>();

  /// Compte affiché au dernier passage (pour détecter déconnexion et changement de compte).
  int? _shownUserId;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
    _shownUserId = _auth.user?.id;
    _auth.addListener(_onAuthChanged);
    _shared.pending.addListener(_onSharedLocation);
    _shared.failure.addListener(_onSharedFailure);
    _push.onOpenOrder.addListener(_onOpenOrder);
    if (_shared.pending.value != null) _onSharedLocation();
    if (_shared.failure.value != null) _onSharedFailure();
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _shared.pending.removeListener(_onSharedLocation);
    _shared.failure.removeListener(_onSharedFailure);
    _push.onOpenOrder.removeListener(_onOpenOrder);
    super.dispose();
  }

  /// Déconnexion, session expirée ou changement de compte : on revient à l'écran racine
  /// (sinon les écrans poussés resteraient au-dessus de l'écran de connexion).
  void _onAuthChanged() {
    final id = _auth.user?.id;
    if (id == _shownUserId) return;
    final hadUser = _shownUserId != null;
    _shownUserId = id;
    if (hadUser) {
      navigatorKey.currentState?.popUntil((r) => r.isFirst);
      if (id == null && _auth.sessionExpired) {
        _showMessage('Votre session a expiré. Reconnectez-vous.');
      }
    }
    // Notification touchée avant la fin de la connexion : on l'ouvre maintenant.
    if (id != null) _onOpenOrder();
  }

  /// Notification touchée : ouvre la commande concernée selon le compte connecté.
  void _onOpenOrder() {
    final orderId = _push.onOpenOrder.value;
    final user = _auth.user;
    if (orderId == null || user == null || _auth.initializing || _auth.offline) return;
    _push.onOpenOrder.value = null;
    // Après la construction de l'espace (premier affichage juste après la connexion).
    WidgetsBinding.instance.addPostFrameCallback((_) => _openOrder(orderId, user));
  }

  Future<void> _openOrder(int orderId, AppUser user) async {
    if (!mounted || _auth.user?.id != user.id) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    if (!user.isDriver) {
      nav.push(MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: orderId, admin: user.isAdmin)));
      return;
    }
    // Livreur : sa livraison s'il y a accès, sinon l'onglet « À livrer » (nouvelle commande prête).
    try {
      final order = await Api.instance.order(orderId);
      if (!mounted || _auth.user?.id != user.id) return;
      nav.push(MaterialPageRoute(builder: (_) => DriverOrderDetailScreen(order: order)));
    } catch (_) {
      if (!mounted || _auth.user?.id != user.id) return;
      nav.popUntil((r) => r.isFirst);
      _findDriverShell()?.goTo(DriverShellState.availableTab);
    }
  }

  /// Espace livreur affiché sous la racine (null si un autre espace est affiché).
  DriverShellState? _findDriverShell() {
    DriverShellState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is DriverShellState) {
        found = e.state as DriverShellState;
        return;
      }
      e.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  /// Position reçue de Google Maps : si aucun écran (commande) ne l'a utilisée dans la seconde,
  /// on prévient le client qu'elle servira pour sa prochaine commande.
  void _onSharedLocation() {
    final ImportedLocation? received = _shared.pending.value;
    if (received == null) return;
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted || !identical(_shared.pending.value, received)) return;
      final user = _auth.user;
      final String message;
      if (user != null && (user.isAdmin || user.isDriver)) {
        // Livreur / admin : message neutre, la position n'est pas gardée.
        _shared.consume();
        message = 'Position Google Maps reçue : elle ne sert que pour les commandes clients.';
      } else {
        message = '📍 Position reçue de Google Maps : elle sera utilisée pour votre prochaine commande';
      }
      _showMessage(message);
    });
  }

  void _onSharedFailure() {
    final message = _shared.failure.value;
    if (message == null) return;
    _showMessage(message);
  }

  void _showMessage(String message) {
    final messenger = scaffoldMessengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 5)));
  }

  Future<void> _checkOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _onboardingCompleted = prefs.getBool('onboarding_completed') ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (_onboardingCompleted == null || auth.initializing) {
      return const SplashScreen();
    }

    // Compte enregistré mais serveur injoignable : on réessaie sans déconnecter.
    if (auth.offline) return const ConnectionScreen();

    // Onboarding réservé aux clients (ni admin ni livreur).
    if (_onboardingCompleted == false && auth.user != null && !auth.user!.isAdmin && !auth.user!.isDriver) {
      return OnboardingScreen(
        onComplete: () {
          if (mounted) setState(() => _onboardingCompleted = true);
        },
      );
    }

    final Widget child;
    if (auth.user == null) {
      child = const LoginScreen();
    } else if (auth.user!.isAdmin) {
      child = const AdminShell();
    } else if (auth.user!.isDriver) {
      child = const DriverShell();
    } else {
      child = const ClientShell();
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      // Clé par compte : un nouveau compte repart d'un espace neuf (onglets, listes, minuteries).
      child: KeyedSubtree(key: ValueKey('${child.runtimeType}-${auth.user?.id}'), child: child),
    );
  }
}
