import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import '../widgets/animations.dart';
import '../widgets/kaleta.dart';

/// Une page de présentation : photo du restaurant, accroche et texte.
class _Slide {
  final String photo;
  final IconData icon;
  final String kicker;
  final String title;
  final String description;
  const _Slide(this.photo, this.icon, this.kicker, this.title, this.description);
}

const _slides = [
  _Slide(
    'assets/images/venue_facade.jpg',
    Icons.auto_awesome_rounded,
    'TERRASSE · LOUNGE',
    'Bienvenue chez KALETA',
    'La nouvelle adresse gourmande de Lomé, face au lycée d\'Agoè. Ici, l\'ambiance se prépare… et maintenant elle se commande.',
  ),
  _Slide(
    'assets/images/venue_salle.jpg',
    Icons.public_rounded,
    'CUISINE D\'AFRIQUE',
    '8 pays, 30 spécialités',
    'Ayimolou, fufu sauce arachide, garba, thiep, jollof, poulet DG… et nos brochettes et pizzas au feu de bois.',
  ),
  _Slide(
    'assets/images/venue_terrasse.jpg',
    Icons.local_bar_rounded,
    'MIXOLOGIE',
    'Cocktails signature',
    'Kaleta Sunset, Baobab Cream, Sodabi Citron, jus pressés à la commande et thés Kaleta : la carte du bar, à portée de main.',
  ),
  _Slide(
    'assets/images/venue_rooftop.jpg',
    Icons.delivery_dining_rounded,
    'LIVRAISON & RETRAIT',
    'Commandez, on s\'occupe du reste',
    'Position GPS précise, suivi du livreur en direct, paiement en espèces, Flooz ou Mixx by Yas.',
  ),
];

/// Écran d'onboarding animé (photos du restaurant en parallaxe). Affiché une seule fois.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingScreen({required this.onComplete, super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  bool get _last => _currentPage == _slides.length - 1;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_completed', true);
    if (mounted) widget.onComplete();
  }

  void _nextPage() {
    if (!_last) {
      _pageController.nextPage(duration: const Duration(milliseconds: 550), curve: Curves.easeInOutCubic);
    } else {
      _markCompleted();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildDarkTheme(),
      child: Scaffold(
        backgroundColor: AppColors.brandDark,
        body: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: _slides.length,
              onPageChanged: (i) => setState(() => _currentPage = i),
              itemBuilder: (_, i) => AnimatedBuilder(
                animation: _pageController,
                builder: (context, _) {
                  final page = _pageController.hasClients && _pageController.position.haveDimensions
                      ? _pageController.page ?? 0
                      : 0.0;
                  return _SlideView(slide: _slides[i], delta: i - page, active: i == _currentPage);
                },
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: AnimatedOpacity(
                  opacity: _last ? 0 : 1,
                  duration: const Duration(milliseconds: 250),
                  child: TextButton(onPressed: _last ? null : _markCompleted, child: const Text('Passer')),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (int i = 0; i < _slides.length; i++)
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 350),
                              curve: Curves.easeOutCubic,
                              width: _currentPage == i ? 34 : 8,
                              height: 8,
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: _currentPage == i ? AppColors.neon : Colors.white24,
                                borderRadius: BorderRadius.circular(4),
                                boxShadow: [
                                  if (_currentPage == i)
                                    BoxShadow(color: AppColors.neon.withValues(alpha: 0.6), blurRadius: 10),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      GlowButton(
                        label: _last ? 'Découvrir la carte' : 'Suivant',
                        icon: _last ? Icons.restaurant_menu_rounded : Icons.arrow_forward_rounded,
                        gold: _last,
                        onPressed: _nextPage,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlideView extends StatelessWidget {
  final _Slide slide;
  /// Écart à la page affichée (-1 … 1) : la photo glisse moins vite que le texte (parallaxe).
  final double delta;
  final bool active;
  const _SlideView({required this.slide, required this.delta, required this.active});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final fade = (1 - delta.abs()).clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: Transform.translate(
            offset: Offset(-delta * width * 0.45, 0),
            child: Transform.scale(
              scale: 1.15 + 0.1 * delta.abs(),
              child: Image.asset(slide.photo, fit: BoxFit.cover),
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x6603150F), Color(0x2203150F), Color(0xDD03150F), AppColors.brandDark],
              stops: [0, 0.3, 0.62, 0.85],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 170),
          child: Opacity(
            opacity: fade,
            child: Transform.translate(
              offset: Offset(delta * width * 0.2, 0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Relance l'animation d'entrée à chaque arrivée sur la page.
                  if (active)
                    FadeSlideIn(
                      key: ValueKey(slide.title),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.brand.withValues(alpha: 0.35),
                          border: Border.all(color: AppColors.neon.withValues(alpha: 0.6)),
                          boxShadow: [BoxShadow(color: AppColors.neon.withValues(alpha: 0.35), blurRadius: 20)],
                        ),
                        child: Icon(slide.icon, color: AppColors.neon, size: 28),
                      ),
                    )
                  else
                    const SizedBox(height: 54),
                  const SizedBox(height: 18),
                  Text(
                    slide.kicker,
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 3,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    slide.title,
                    style: const TextStyle(
                      fontFamily: displayFont,
                      fontWeight: FontWeight.w900,
                      fontSize: 34,
                      height: 1.1,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    slide.description,
                    style: const TextStyle(fontSize: 15, color: Color(0xFFD8D1C1), height: 1.55),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
