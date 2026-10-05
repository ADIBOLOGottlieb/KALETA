import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../theme.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../../widgets/kaleta.dart';
import 'forgot_password_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _shakeKey = GlobalKey<ShakeState>();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) {
      _shakeKey.currentState?.shake();
      return;
    }
    setState(() => _loading = true);
    try {
      await context.read<AuthProvider>().login(_phone.text.trim(), _password.text);
    } catch (e) {
      _shakeKey.currentState?.shake();
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Écran de connexion toujours sombre : c'est la vitrine du lounge, quel que soit le thème choisi.
    return Theme(
      data: buildDarkTheme(),
      child: Builder(builder: (context) {
        return Scaffold(
          backgroundColor: AppColors.brandDark,
          body: KaletaBackdrop(
            photo: 'assets/images/venue_facade.jpg',
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(
                      children: [
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.4, end: 1),
                          duration: const Duration(milliseconds: 1000),
                          curve: Curves.elasticOut,
                          builder: (_, v, child) => Transform.scale(scale: v, child: child),
                          child: const Hero(tag: 'kaleta-logo', child: AppLogo(size: 112, glow: true)),
                        ),
                        const SizedBox(height: 16),
                        const FadeSlideIn(delay: Duration(milliseconds: 150), child: KaletaWordmark(size: 38)),
                        const SizedBox(height: 28),
                        FadeSlideIn(
                          delay: const Duration(milliseconds: 300),
                          offset: const Offset(0, 0.08),
                          child: Shake(
                            key: _shakeKey,
                            child: GlassPanel(
                              child: Form(
                                key: _formKey,
                                child: AutofillGroup(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Text('Bon retour parmi nous', style: Theme.of(context).textTheme.headlineSmall),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Cuisine d\'Afrique, grillades au feu de bois et cocktails signature, livrés chez vous.',
                                        style: TextStyle(color: mutedColor(context), fontSize: 13, height: 1.4),
                                      ),
                                      const SizedBox(height: 22),
                                      FadeSlideIn(
                                        delay: const Duration(milliseconds: 450),
                                        offset: const Offset(-0.15, 0),
                                        child: GlowField(
                                          controller: _phone,
                                          label: 'Numéro de téléphone',
                                          icon: Icons.phone_rounded,
                                          keyboardType: TextInputType.phone,
                                          textInputAction: TextInputAction.next,
                                          autofillHints: const [AutofillHints.telephoneNumber],
                                          validator: (v) =>
                                              (v == null || v.trim().isEmpty) ? 'Entrez votre numéro' : null,
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                      FadeSlideIn(
                                        delay: const Duration(milliseconds: 550),
                                        offset: const Offset(-0.15, 0),
                                        child: GlowField(
                                          controller: _password,
                                          label: 'Mot de passe',
                                          icon: Icons.lock_rounded,
                                          obscure: true,
                                          canReveal: true,
                                          autofillHints: const [AutofillHints.password],
                                          onSubmitted: (_) => _submit(),
                                          validator: (v) =>
                                              (v == null || v.isEmpty) ? 'Entrez votre mot de passe' : null,
                                        ),
                                      ),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton(
                                          onPressed: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => ForgotPasswordScreen(initialPhone: _phone.text.trim()),
                                            ),
                                          ),
                                          child: const Text('Mot de passe oublié ?'),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      FadeSlideIn(
                                        delay: const Duration(milliseconds: 650),
                                        child: GlowButton(
                                          label: 'Entrer au lounge',
                                          icon: Icons.arrow_forward_rounded,
                                          loading: _loading,
                                          onPressed: _submit,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        FadeSlideIn(
                          delay: const Duration(milliseconds: 800),
                          child: TextButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const RegisterScreen()),
                            ),
                            child: Text.rich(TextSpan(
                              text: 'Première visite ? ',
                              style: TextStyle(color: mutedColor(context), fontWeight: FontWeight.w500),
                              children: const [
                                TextSpan(
                                  text: 'Créer un compte',
                                  style: TextStyle(color: AppColors.goldLight, fontWeight: FontWeight.w800),
                                ),
                              ],
                            )),
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
      }),
    );
  }
}
