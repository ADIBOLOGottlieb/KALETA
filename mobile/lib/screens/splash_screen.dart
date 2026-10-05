import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/animations.dart';
import '../widgets/common.dart';
import '../widgets/kaleta.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
  // Le réveil du serveur peut durer jusqu'à une minute : on explique l'attente.
  late final Timer _slowTimer = Timer(const Duration(seconds: 4), () {
    if (mounted) setState(() => _slow = true);
  });
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _slowTimer; // Démarre le minuteur.
  }

  @override
  void dispose() {
    _slowTimer.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.brandDark,
      body: KaletaBackdrop(
        photo: 'assets/images/venue_facade.jpg',
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 280,
                height: 280,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Deux ondes néon qui se propagent derrière le masque.
                    for (final offset in const [0.0, 0.5])
                      AnimatedBuilder(
                        animation: _pulse,
                        builder: (_, _) {
                          final v = (_pulse.value + offset) % 1;
                          return Container(
                            width: 170 + 110 * v,
                            height: 170 + 110 * v,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: AppColors.neon.withValues(alpha: 0.5 * (1 - v)), width: 2),
                            ),
                          );
                        },
                      ),
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 1300),
                      curve: Curves.elasticOut,
                      builder: (_, v, child) => Transform.rotate(
                        angle: (1 - v) * -0.6,
                        child: Transform.scale(scale: 0.3 + 0.7 * v, child: child),
                      ),
                      child: const AppLogo(size: 170, glow: true),
                    ),
                  ],
                ),
              ),
              const FadeSlideIn(
                delay: Duration(milliseconds: 450),
                child: KaletaWordmark(size: 50),
              ),
              const SizedBox(height: 18),
              FadeSlideIn(
                delay: const Duration(milliseconds: 800),
                child: Text(
                  "L'ambiance se prépare…",
                  style: TextStyle(
                    fontFamily: displayFont,
                    fontStyle: FontStyle.italic,
                    color: AppColors.goldLight.withValues(alpha: 0.9),
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              AnimatedOpacity(
                opacity: _slow ? 1 : 0,
                duration: const Duration(milliseconds: 400),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.neon),
                      ),
                      SizedBox(height: 12),
                      Text(
                        "Connexion au serveur…\nAu premier lancement, cela peut prendre jusqu'à une minute.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
