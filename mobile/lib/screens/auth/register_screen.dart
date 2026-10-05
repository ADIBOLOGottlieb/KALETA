import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../services/api.dart';
import '../../services/auth_api.dart';
import '../../theme.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../../widgets/kaleta.dart';
import '../legal/legal_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _shakeKey = GlobalKey<ShakeState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  late final TapGestureRecognizer _termsTap = TapGestureRecognizer()
    ..onTap = () => openLegalDoc(context, LegalDoc.terms);
  late final TapGestureRecognizer _privacyTap = TapGestureRecognizer()
    ..onTap = () => openLegalDoc(context, LegalDoc.privacy);
  bool _loading = false;
  bool _accepted = false;
  bool _otpRequired = false; // code SMS exigé (réglages du serveur)
  bool _codeStep = false; // étape « saisir le code reçu »

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final s = await Api.instance.settings();
      if (mounted) setState(() => _otpRequired = s.otpRequired);
    } catch (_) {
      // Sans réglages : le serveur signalera si un code est exigé.
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _address, _password, _code]) {
      c.dispose();
    }
    _termsTap.dispose();
    _privacyTap.dispose();
    super.dispose();
  }

  String? _opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _createAccount({String? otpToken}) async {
    final auth = context.read<AuthProvider>();
    final (token, user) = await registerAccount(
      name: _name.text.trim(),
      phone: _phone.text.trim(),
      password: _password.text,
      email: _opt(_email),
      address: _opt(_address),
      otpToken: otpToken,
    );
    await auth.applySession(token, user);
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// Étape 1 : formulaire. Avec code SMS exigé : envoie le code puis passe à l'étape 2.
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      _shakeKey.currentState?.shake();
      return;
    }
    if (!_accepted) {
      _shakeKey.currentState?.shake();
      showMessage(context, 'Acceptez les conditions d\'utilisation pour créer votre compte', error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      if (_otpRequired) {
        await requestOtp(_phone.text.trim());
        if (!mounted) return;
        _code.clear();
        setState(() => _codeStep = true);
        showMessage(context, 'Code envoyé par SMS au ${_phone.text.trim()}');
      } else {
        await _createAccount();
      }
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Étape 2 : vérifie le code puis crée le compte.
  Future<void> _verifyAndCreate() async {
    final code = _code.text.trim();
    if (code.length != 6) {
      showMessage(context, 'Entrez le code à 6 chiffres', error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      final otpToken = await verifyOtp(_phone.text.trim(), code);
      await _createAccount(otpToken: otpToken);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    setState(() => _loading = true);
    try {
      await requestOtp(_phone.text.trim());
      if (mounted) showMessage(context, 'Nouveau code envoyé');
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _button(String label, VoidCallback onPressed, {IconData? icon}) =>
      GlowButton(label: label, icon: icon, loading: _loading, onPressed: onPressed);

  @override
  Widget build(BuildContext context) {
    // Même univers que la connexion : toujours sombre.
    return Theme(
      data: buildDarkTheme(),
      child: Builder(builder: (context) {
        final cs = Theme.of(context).colorScheme;
        return PopScope(
          // Retour pendant l'étape du code : revient au formulaire.
          canPop: !_codeStep,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _codeStep) setState(() => _codeStep = false);
          },
          child: Scaffold(
            backgroundColor: AppColors.brandDark,
            extendBodyBehindAppBar: true,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              title: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(_codeStep ? 'Vérification' : 'Créer un compte', key: ValueKey(_codeStep)),
              ),
            ),
            body: KaletaBackdrop(
              photo: 'assets/images/venue_rooftop.jpg',
              rays: false,
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Column(
                        children: [
                          _StepsIndicator(step: _codeStep ? 1 : 0, total: _otpRequired ? 2 : 1),
                          const SizedBox(height: 18),
                          Shake(
                            key: _shakeKey,
                            child: GlassPanel(
                              child: AnimatedSize(
                                duration: const Duration(milliseconds: 380),
                                curve: Curves.easeOutCubic,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 420),
                                  transitionBuilder: (child, anim) => FadeTransition(
                                    opacity: anim,
                                    child: SlideTransition(
                                      position: Tween(
                                        begin: Offset(child.key == const ValueKey('code') ? 0.25 : -0.25, 0),
                                        end: Offset.zero,
                                      ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
                                      child: child,
                                    ),
                                  ),
                                  child: _codeStep
                                      ? KeyedSubtree(key: const ValueKey('code'), child: _buildCodeStep(cs))
                                      : KeyedSubtree(key: const ValueKey('form'), child: _buildForm(cs)),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
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

  Widget _buildCodeStep(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: FadeSlideIn(child: Icon(Icons.mark_email_unread_rounded, size: 58, color: AppColors.neon)),
        ),
        const SizedBox(height: 12),
        Text(
          'Entrez le code à 6 chiffres envoyé par SMS au ${_phone.text.trim()}.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant, height: 1.4),
        ),
        const SizedBox(height: 22),
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 12, color: AppColors.goldLight),
          decoration: const InputDecoration(labelText: 'Code reçu', counterText: ''),
          onSubmitted: (_) => _loading ? null : _verifyAndCreate(),
        ),
        const SizedBox(height: 22),
        _button('Valider et entrer', _verifyAndCreate, icon: Icons.check_rounded),
        const SizedBox(height: 8),
        TextButton(onPressed: _loading ? null : _resend, child: const Text('Renvoyer le code')),
        TextButton(
          onPressed: _loading ? null : () => setState(() => _codeStep = false),
          child: const Text('Modifier mon numéro'),
        ),
      ],
    );
  }

  Widget _buildForm(ColorScheme cs) {
    // Apparition en cascade des champs.
    Widget field(int i, Widget child) => FadeSlideIn(
          delay: FadeSlideIn.stagger(i + 1, stepMs: 70),
          offset: const Offset(-0.12, 0),
          child: Padding(padding: const EdgeInsets.only(bottom: 14), child: child),
        );
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: Hero(tag: 'kaleta-logo', child: AppLogo(size: 84, glow: true))),
          const SizedBox(height: 14),
          Text(
            'Bienvenue chez KALETA',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'La nouvelle adresse gourmande de Lomé',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: displayFont,
              fontStyle: FontStyle.italic,
              fontSize: 15,
              color: AppColors.goldLight.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: 22),
          field(0, GlowField(
            controller: _name,
            label: 'Nom complet *',
            icon: Icons.person_rounded,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.name],
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Entrez votre nom' : null,
          )),
          field(1, GlowField(
            controller: _phone,
            label: 'Téléphone *',
            icon: Icons.phone_rounded,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.telephoneNumber],
            validator: (v) => (v == null || v.trim().length < 8) ? 'Entrez un numéro valide' : null,
          )),
          field(2, GlowField(
            controller: _email,
            label: 'E-mail (optionnel)',
            icon: Icons.alternate_email_rounded,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
          )),
          field(3, GlowField(
            controller: _address,
            label: 'Adresse de livraison (optionnel)',
            hint: 'Quartier, rue, repère (ex : Agoè, Lomé)',
            icon: Icons.location_on_rounded,
            textInputAction: TextInputAction.next,
          )),
          field(4, GlowField(
            controller: _password,
            label: 'Mot de passe *',
            icon: Icons.lock_rounded,
            obscure: true,
            canReveal: true,
            autofillHints: const [AutofillHints.newPassword],
            onChanged: (_) => setState(() {}),
            validator: (v) => (v == null || v.length < 6) ? '6 caractères minimum' : null,
          )),
          _PasswordStrength(password: _password.text),
          const SizedBox(height: 8),
          // Acceptation obligatoire des conditions (liens vers les documents).
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: _accepted,
                activeColor: brandColor(context),
                onChanged: (v) => setState(() => _accepted = v ?? false),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text.rich(
                    TextSpan(
                      style: TextStyle(color: cs.onSurface, height: 1.35),
                      children: [
                        const TextSpan(text: 'J\'accepte les '),
                        TextSpan(
                          text: 'conditions d\'utilisation',
                          recognizer: _termsTap,
                          style: const TextStyle(
                              color: AppColors.goldLight, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
                        ),
                        const TextSpan(text: ' et la '),
                        TextSpan(
                          text: 'politique de confidentialité',
                          recognizer: _privacyTap,
                          style: const TextStyle(
                              color: AppColors.goldLight, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
                        ),
                        const TextSpan(text: '.'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_otpRequired) ...[
            const SizedBox(height: 8),
            Text(
              'Un code de vérification vous sera envoyé par SMS.',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 20),
          _button(
            _otpRequired ? 'Recevoir mon code' : 'Créer mon compte',
            _submit,
            icon: _otpRequired ? Icons.sms_rounded : Icons.celebration_rounded,
          ),
        ],
      ),
    );
  }
}

/// Étapes de l'inscription : pastilles reliées par une ligne qui se remplit.
class _StepsIndicator extends StatelessWidget {
  final int step;
  final int total;
  const _StepsIndicator({required this.step, required this.total});

  @override
  Widget build(BuildContext context) {
    if (total < 2) return const SizedBox.shrink();
    const labels = ['Vos informations', 'Code SMS'];
    return Row(
      children: [
        for (var i = 0; i < total; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(2)),
                alignment: Alignment.centerLeft,
                child: AnimatedFractionallySizedBox(
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOutCubic,
                  widthFactor: step >= i ? 1 : 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.neon,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: [BoxShadow(color: AppColors.neon.withValues(alpha: 0.6), blurRadius: 8)],
                    ),
                  ),
                ),
              ),
            ),
          Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: step >= i ? AppColors.brand : Colors.white10,
                  border: Border.all(color: step >= i ? AppColors.neon : Colors.white24, width: 1.5),
                ),
                alignment: Alignment.center,
                child: step > i
                    ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                    : Text('${i + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 4),
              Text(labels[i], style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ],
          ),
        ],
      ],
    );
  }
}

/// Jauge animée de solidité du mot de passe.
class _PasswordStrength extends StatelessWidget {
  final String password;
  const _PasswordStrength({required this.password});

  @override
  Widget build(BuildContext context) {
    var score = 0;
    if (password.length >= 6) score++;
    if (password.length >= 10) score++;
    if (RegExp(r'[0-9]').hasMatch(password) && RegExp(r'[A-Za-z]').hasMatch(password)) score++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(password)) score++;
    final (label, color) = switch (score) {
      0 => ('', Colors.transparent),
      1 => ('Faible', const Color(0xFFE57373)),
      2 => ('Correct', AppColors.accent),
      3 => ('Solide', const Color(0xFF7BD88F)),
      _ => ('Excellent', AppColors.neon),
    };
    return AnimatedOpacity(
      opacity: password.isEmpty ? 0 : 1,
      duration: const Duration(milliseconds: 250),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: score / 4),
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => LinearProgressIndicator(
                  value: v,
                  minHeight: 5,
                  color: color,
                  backgroundColor: Colors.white10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 64,
            child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
