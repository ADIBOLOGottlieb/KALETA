import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Apparition en fondu + glissement, avec un délai optionnel (effet « cascade »).
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;
  final Offset offset;
  final Curve curve;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 450),
    this.offset = const Offset(0, 0.12),
    this.curve = Curves.easeOutCubic,
  });

  /// Délai en cascade pour le n-ième élément d'une liste, plafonné pour rester rapide.
  static Duration stagger(int index, {int stepMs = 55, int maxMs = 450}) =>
      Duration(milliseconds: (index * stepMs).clamp(0, maxMs));

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _curve = CurvedAnimation(parent: _c, curve: widget.curve);

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween(begin: widget.offset, end: Offset.zero).animate(_curve),
        child: widget.child,
      ),
    );
  }
}

/// Réduit légèrement l'élément pendant l'appui, pour un retour tactile doux.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  const Pressable({super.key, required this.child, this.onTap, this.scale = 0.965});

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (widget.onTap != null && v != _down) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Fait « rebondir » son enfant à chaque changement de [trigger] (ex : badge du panier).
class BounceOnChange extends StatefulWidget {
  final Object? trigger;
  final Widget child;
  const BounceOnChange({super.key, required this.trigger, required this.child});

  @override
  State<BounceOnChange> createState() => _BounceOnChangeState();
}

class _BounceOnChangeState extends State<BounceOnChange> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  late final Animation<double> _scale = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.35).chain(CurveTween(curve: Curves.easeOut)), weight: 35),
    TweenSequenceItem(tween: Tween(begin: 1.35, end: 1.0).chain(CurveTween(curve: Curves.elasticOut)), weight: 65),
  ]).animate(_c);

  @override
  void didUpdateWidget(BounceOnChange old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(scale: _scale, child: widget.child);
}

/// Nombre qui défile de l'ancienne à la nouvelle valeur.
class AnimatedCount extends StatelessWidget {
  final int value;
  final String Function(int) format;
  final TextStyle? style;

  const AnimatedCount({super.key, required this.value, required this.format, this.style});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.toDouble()),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => Text(format(v.round()), style: style),
    );
  }
}

/// Comme IndexedStack (les onglets gardent leur état), avec un fondu + léger zoom
/// lors du changement d'onglet.
///
/// Repose sur [IndexedStack] : seul l'onglet actif est peint et reçoit les appuis.
/// (L'ancienne version empilait tous les onglets en jouant sur l'opacité ; le fondu de
/// l'onglet quitté était gelé par TickerMode, il restait affiché alors que les appuis
/// partaient vers l'onglet actif, invisible dessous.)
class FadeIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;

  const FadeIndexedStack({super.key, required this.index, required this.children});

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 220), value: 1);
  late final Animation<double> _fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
  late final Animation<double> _scale = Tween(begin: 0.985, end: 1.0).animate(_fade);

  @override
  void didUpdateWidget(FadeIndexedStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: widget.index,
      sizing: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          // Même structure pour tous les onglets, sinon Flutter recréerait l'onglet
          // (et perdrait son état : recherche, défilement...) à chaque changement.
          TickerMode(
            enabled: i == widget.index,
            child: FadeTransition(
              opacity: i == widget.index ? _fade : const AlwaysStoppedAnimation(1.0),
              child: ScaleTransition(
                scale: i == widget.index ? _scale : const AlwaysStoppedAnimation(1.0),
                child: widget.children[i],
              ),
            ),
          ),
      ],
    );
  }
}

/// Transition de page KALETA : la nouvelle page monte en fondu depuis un léger zoom arrière,
/// la page quittée recule et s'assombrit (effet « rideau de lounge »).
class KaletaPageTransitionsBuilder extends PageTransitionsBuilder {
  const KaletaPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final enter = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    final leave = CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeInOutCubic);
    return AnimatedBuilder(
      animation: Listenable.merge([enter, leave]),
      child: child,
      builder: (context, child) {
        final t = enter.value;
        final s = leave.value;
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, 36 * (1 - t)),
            child: Transform.scale(
              scale: (0.94 + 0.06 * t) * (1 - 0.05 * s),
              child: ColorFiltered(
                // Page quittée légèrement assombrie.
                colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.35 * s), BlendMode.srcATop),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Secoue son enfant (formulaire invalide, mot de passe erroné) : `key.currentState?.shake()`.
class Shake extends StatefulWidget {
  final Widget child;
  const Shake({super.key, required this.child});

  @override
  State<Shake> createState() => ShakeState();
}

class ShakeState extends State<Shake> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));

  void shake() => _c.forward(from: 0);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (_, child) {
        // Oscillation amortie : 4 allers-retours de plus en plus faibles.
        final t = _c.value;
        final dx = 14 * (1 - t) * math.sin(t * math.pi * 8);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}
