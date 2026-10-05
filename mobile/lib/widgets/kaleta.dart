import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Fond animé KALETA : vert nuit, halos vert néon et or qui dérivent lentement, rayons de la coiffe
/// du masque qui tournent doucement, et une photo du lieu en filigrane (facultative).
class KaletaBackdrop extends StatefulWidget {
  final Widget child;
  /// Photo du restaurant (assets/images/venue_*.jpg) affichée très assombrie derrière les halos.
  final String? photo;
  /// Rayons de la coiffe derrière le contenu (écran d'accueil, connexion).
  final bool rays;

  const KaletaBackdrop({super.key, required this.child, this.photo, this.rays = true});

  @override
  State<KaletaBackdrop> createState() => _KaletaBackdropState();
}

class _KaletaBackdropState extends State<KaletaBackdrop> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 18))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: AppColors.brandDark),
        if (widget.photo != null)
          Opacity(
            opacity: 0.32,
            child: Image.asset(widget.photo!, fit: BoxFit.cover, gaplessPlayback: true),
          ),
        // Voile : la photo s'efface vers le vert nuit en bas (lisibilité du formulaire).
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x9903150F), Color(0xE603150F), AppColors.brandDark],
              stops: [0, 0.45, 0.85],
            ),
          ),
        ),
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, _) => CustomPaint(painter: _GlowPainter(_c.value, rays: widget.rays)),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _GlowPainter extends CustomPainter {
  final double t;
  final bool rays;
  _GlowPainter(this.t, {required this.rays});

  void _orb(Canvas canvas, Offset center, double radius, Color color) {
    final paint = Paint()
      ..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)])
          .createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final a = t * 2 * math.pi;
    final w = size.width, h = size.height;
    _orb(canvas, Offset(w * (0.15 + 0.12 * math.sin(a)), h * (0.18 + 0.06 * math.cos(a))), w * 0.75,
        AppColors.neon.withValues(alpha: 0.16));
    _orb(canvas, Offset(w * (0.9 + 0.08 * math.cos(a * 2)), h * (0.42 + 0.08 * math.sin(a))), w * 0.6,
        AppColors.accent.withValues(alpha: 0.12));
    _orb(canvas, Offset(w * (0.35 + 0.15 * math.cos(a)), h * (0.92 + 0.04 * math.sin(a * 2))), w * 0.8,
        AppColors.deep.withValues(alpha: 0.55));

    if (!rays) return;
    // Rayons de la coiffe du masque, centrés en haut, en rotation lente.
    final center = Offset(w / 2, h * 0.2);
    final paint = Paint()
      ..shader = RadialGradient(colors: [
        AppColors.neon.withValues(alpha: 0.10),
        AppColors.neon.withValues(alpha: 0),
      ]).createShader(Rect.fromCircle(center: center, radius: h * 0.6));
    const count = 18;
    for (var i = 0; i < count; i++) {
      final angle = a / 3 + i * 2 * math.pi / count;
      final path = Path()
        ..moveTo(center.dx, center.dy)
        ..lineTo(center.dx + h * math.cos(angle - 0.035), center.dy + h * math.sin(angle - 0.035))
        ..lineTo(center.dx + h * math.cos(angle + 0.035), center.dy + h * math.sin(angle + 0.035))
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.t != t || old.rays != rays;
}

/// Logotype « KALETA » animé : lettres en Playfair Display traversées d'un reflet néon, puis
/// « ★★★ TERRASSE · LOUNGE » en or (comme sur l'enseigne du restaurant).
class KaletaWordmark extends StatefulWidget {
  final double size;
  final bool showTagline;
  const KaletaWordmark({super.key, this.size = 46, this.showTagline = true});

  @override
  State<KaletaWordmark> createState() => _KaletaWordmarkState();
}

class _KaletaWordmarkState extends State<KaletaWordmark> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return Semantics(
      label: 'KALETA, Terrasse et Lounge',
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _c,
              builder: (_, child) {
                // Reflet qui balaie les lettres de gauche à droite, puis une pause.
                final p = (_c.value * 1.6 - 0.3);
                return ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (rect) => LinearGradient(
                    colors: const [Color(0xFF1FA64F), AppColors.neon, Color(0xFFE9FFD9), AppColors.neon, Color(0xFF1FA64F)],
                    stops: [0, (p - 0.12).clamp(0.0, 1.0), p.clamp(0.0, 1.0), (p + 0.12).clamp(0.0, 1.0), 1],
                  ).createShader(rect),
                  child: child,
                );
              },
              child: Text(
                'KALETA',
                style: TextStyle(
                  fontFamily: displayFont,
                  fontWeight: FontWeight.w900,
                  fontSize: size,
                  letterSpacing: size * 0.08,
                  height: 1,
                  shadows: [Shadow(color: AppColors.neon.withValues(alpha: 0.55), blurRadius: size * 0.5)],
                ),
              ),
            ),
            if (widget.showTagline) ...[
              SizedBox(height: size * 0.18),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _goldLine(size),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: size * 0.15),
                    child: Text('★ ★ ★', style: TextStyle(color: AppColors.accent, fontSize: size * 0.2)),
                  ),
                  _goldLine(size),
                ],
              ),
              SizedBox(height: size * 0.1),
              Text(
                'TERRASSE · LOUNGE',
                style: TextStyle(
                  color: AppColors.goldLight,
                  fontSize: size * 0.28,
                  fontWeight: FontWeight.w600,
                  letterSpacing: size * 0.12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _goldLine(double size) => Container(
        width: size * 1.1,
        height: 1.2,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [AppColors.accent.withValues(alpha: 0), AppColors.accent]),
        ),
      );
}

/// Panneau « verre fumé » : fond flou translucide et liseré or, pour les formulaires sur fond animé.
class GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const GlassPanel({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(22, 26, 22, 22)});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            color: dark ? AppColors.darkSurface.withValues(alpha: 0.62) : Colors.white.withValues(alpha: 0.9),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.28)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Champ de formulaire qui s'illumine (halo néon) quand il a le focus, et rougeoie en cas d'erreur.
class GlowField extends StatefulWidget {
  final TextEditingController? controller;
  final String label;
  final IconData icon;
  final String? hint;
  final String? helper;
  final bool obscure;
  final bool canReveal;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final Iterable<String>? autofillHints;
  final TextCapitalization textCapitalization;
  final int? maxLength;

  const GlowField({
    super.key,
    this.controller,
    required this.label,
    required this.icon,
    this.hint,
    this.helper,
    this.obscure = false,
    this.canReveal = false,
    this.keyboardType,
    this.textInputAction,
    this.validator,
    this.onSubmitted,
    this.onChanged,
    this.autofillHints,
    this.textCapitalization = TextCapitalization.none,
    this.maxLength,
  });

  @override
  State<GlowField> createState() => _GlowFieldState();
}

class _GlowFieldState extends State<GlowField> {
  final _focus = FocusNode();
  bool _focused = false;
  bool _hidden = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glow = _hasError ? scheme.error : AppColors.neon;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          if (_focused || _hasError)
            BoxShadow(color: glow.withValues(alpha: _focused ? 0.28 : 0.15), blurRadius: 18, spreadRadius: 0.5),
        ],
      ),
      child: TextFormField(
        controller: widget.controller,
        focusNode: _focus,
        obscureText: widget.obscure && _hidden,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        textCapitalization: widget.textCapitalization,
        autofillHints: widget.autofillHints,
        maxLength: widget.maxLength,
        onFieldSubmitted: widget.onSubmitted,
        onChanged: widget.onChanged,
        validator: widget.validator == null
            ? null
            : (v) {
                final error = widget.validator!(v);
                final hasError = error != null;
                if (hasError != _hasError) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _hasError = hasError);
                  });
                }
                return error;
              },
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          helperText: widget.helper,
          helperMaxLines: 2,
          counterText: '',
          prefixIcon: AnimatedScale(
            scale: _focused ? 1.18 : 1,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutBack,
            child: Icon(widget.icon),
          ),
          suffixIcon: widget.obscure && widget.canReveal
              ? IconButton(
                  tooltip: _hidden ? 'Afficher' : 'Masquer',
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (c, a) => RotationTransition(turns: Tween(begin: 0.75, end: 1.0).animate(a), child: FadeTransition(opacity: a, child: c)),
                    child: Icon(
                      _hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                      key: ValueKey(_hidden),
                    ),
                  ),
                  onPressed: () => setState(() => _hidden = !_hidden),
                )
              : null,
        ),
      ),
    );
  }
}

/// Bouton principal KALETA : dégradé vert néon, reflet qui passe en boucle, appui qui s'enfonce,
/// et transformation en pastille ronde avec un indicateur pendant le chargement.
class GlowButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  /// Variante or (actions secondaires de prestige : réserver, signature du chef).
  final bool gold;

  const GlowButton({super.key, required this.label, this.icon, this.onPressed, this.loading = false, this.gold = false});

  @override
  State<GlowButton> createState() => _GlowButtonState();
}

class _GlowButtonState extends State<GlowButton> with SingleTickerProviderStateMixin {
  late final AnimationController _shine = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))
    ..repeat();
  bool _down = false;

  @override
  void dispose() {
    _shine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;
    final colors = widget.gold
        ? const [AppColors.goldLight, AppColors.accent, AppColors.goldDark]
        : const [Color(0xFF3FD162), Color(0xFF17924A), Color(0xFF0F6B37)];
    final foreground = widget.gold ? AppColors.ink : Colors.white;
    return LayoutBuilder(builder: (context, constraints) {
      final full = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
      return Center(
        child: Semantics(
          button: true,
          enabled: enabled,
          label: widget.label,
          child: GestureDetector(
            onTapDown: enabled ? (_) => setState(() => _down = true) : null,
            onTapUp: enabled ? (_) => setState(() => _down = false) : null,
            onTapCancel: () => setState(() => _down = false),
            onTap: enabled ? widget.onPressed : null,
            child: AnimatedScale(
              scale: _down ? 0.96 : 1,
              duration: const Duration(milliseconds: 120),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeInOutCubic,
                width: widget.loading ? 56 : full,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: LinearGradient(
                    colors: enabled || widget.loading ? colors : colors.map((c) => c.withValues(alpha: 0.4)).toList(),
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    if (enabled || widget.loading)
                      BoxShadow(
                        color: (widget.gold ? AppColors.accent : AppColors.neon).withValues(alpha: _down ? 0.25 : 0.4),
                        blurRadius: _down ? 10 : 22,
                        offset: const Offset(0, 6),
                      ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (enabled)
                        Positioned.fill(
                          child: AnimatedBuilder(
                            animation: _shine,
                            builder: (_, _) => FractionalTranslation(
                              translation: Offset(-1.2 + _shine.value * 3, 0),
                              child: Transform(
                                transform: Matrix4.skewX(-0.4),
                                child: FractionallySizedBox(
                                  widthFactor: 0.25,
                                  alignment: Alignment.centerLeft,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(colors: [
                                        Colors.white.withValues(alpha: 0),
                                        Colors.white.withValues(alpha: 0.28),
                                        Colors.white.withValues(alpha: 0),
                                      ]),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: widget.loading
                            ? SizedBox(
                                key: const ValueKey('loading'),
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2.6, color: foreground),
                              )
                            : Row(
                                key: const ValueKey('label'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      widget.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.fade,
                                      softWrap: false,
                                      style: TextStyle(
                                        color: foreground,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 16,
                                        letterSpacing: 0.6,
                                      ),
                                    ),
                                  ),
                                  if (widget.icon != null) ...[
                                    const SizedBox(width: 10),
                                    Icon(widget.icon, color: foreground, size: 20),
                                  ],
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}
