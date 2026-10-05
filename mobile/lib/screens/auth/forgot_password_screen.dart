import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../services/api.dart';
import '../../services/auth_api.dart';
import '../../theme.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../../widgets/kaleta.dart';
import '../client/profile/help_screen.dart' show dialNumber, openExternalLink, whatsappNumber;

/// « Mot de passe oublié » : numéro → code → nouveau mot de passe (connexion directe ensuite).
class ForgotPasswordScreen extends StatefulWidget {
  final String initialPhone;
  const ForgotPasswordScreen({super.key, this.initialPhone = ''});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _phoneForm = GlobalKey<FormState>();
  final _resetForm = GlobalKey<FormState>();
  late final _phone = TextEditingController(text: widget.initialPhone);
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _loading = false;
  bool _codeStep = false;
  bool _bySms = false; // vrai : code reçu par SMS ; faux : le restaurant appelle le client
  AppSettings? _settings; // numéro du restaurant (mode sans SMS)

  @override
  void initState() {
    super.initState();
    Api.instance.settings().then((s) {
      if (mounted) setState(() => _settings = s);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    for (final c in [_phone, _code, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _requestCode() async {
    if (!_phoneForm.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      final sms = await forgotPassword(_phone.text.trim());
      if (!mounted) return;
      _code.clear();
      setState(() {
        _bySms = sms;
        _codeStep = true;
      });
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reset() async {
    if (!_resetForm.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final auth = context.read<AuthProvider>();
    setState(() => _loading = true);
    try {
      final (token, user) = await resetPassword(
        phone: _phone.text.trim(),
        code: _code.text.trim(),
        newPassword: _password.text,
      );
      await auth.applySession(token, user);
      if (!mounted) return;
      showMessage(context, 'Mot de passe modifié. Bienvenue !');
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _button(String label, VoidCallback onPressed) =>
      GlowButton(label: label, loading: _loading, onPressed: onPressed);

  @override
  Widget build(BuildContext context) {
    // Même univers que la connexion : toujours sombre.
    return Theme(
      data: buildDarkTheme(),
      child: Builder(builder: (context) {
        final cs = Theme.of(context).colorScheme;
        return PopScope(
          canPop: !_codeStep,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _codeStep) setState(() => _codeStep = false);
          },
          child: Scaffold(
            backgroundColor: AppColors.brandDark,
            extendBodyBehindAppBar: true,
            appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('Mot de passe oublié')),
            body: KaletaBackdrop(
              photo: 'assets/images/venue_salle.jpg',
              rays: false,
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: FadeSlideIn(
                        child: GlassPanel(
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 380),
                            curve: Curves.easeOutCubic,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 420),
                              transitionBuilder: (child, anim) => FadeTransition(
                                opacity: anim,
                                child: ScaleTransition(
                                  scale: Tween(begin: 0.94, end: 1.0).animate(anim),
                                  child: child,
                                ),
                              ),
                              child: _codeStep
                                  ? KeyedSubtree(key: const ValueKey('reset'), child: _buildResetStep(cs))
                                  : KeyedSubtree(key: const ValueKey('phone'), child: _buildPhoneStep(cs)),
                            ),
                          ),
                        ),
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

  Widget _buildPhoneStep(ColorScheme cs) {
    return Form(
      key: _phoneForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.lock_reset_rounded, size: 58, color: AppColors.neon),
          const SizedBox(height: 12),
          Text(
            'Indiquez le numéro de téléphone de votre compte. Vous recevrez un code pour choisir '
            'un nouveau mot de passe.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 24),
          GlowField(
            controller: _phone,
            label: 'Numéro de téléphone',
            icon: Icons.phone_rounded,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _loading ? null : _requestCode(),
            validator: (v) => (v == null || v.trim().length < 8) ? 'Entrez un numéro valide' : null,
          ),
          const SizedBox(height: 24),
          _button('Recevoir un code', _requestCode),
        ],
      ),
    );
  }

  Widget _buildResetStep(ColorScheme cs) {
    final phone = _phone.text.trim();
    final restaurant = _settings?.restaurantPhone.trim() ?? '';
    return Form(
      key: _resetForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_bySms ? Icons.sms_rounded : Icons.support_agent_rounded, color: brandColor(context), size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _bySms
                        ? 'Un code à 6 chiffres a été envoyé par SMS au $phone (si un compte existe pour ce numéro). '
                            'Pas de SMS d\'ici quelques minutes ? Le restaurant vous appellera pour vous le donner.'
                        : 'Votre demande a été transmise au restaurant. Le restaurant va vous appeler au $phone '
                            '(ou vous écrire sur WhatsApp) pour vous communiquer le code à 6 chiffres. '
                            'Gardez votre téléphone à portée de main.',
                    style: TextStyle(color: cs.onSurface, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          if (!_bySms && restaurant.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openExternalLink(
                      context,
                      Uri(scheme: 'tel', path: dialNumber(restaurant)),
                      'Impossible de lancer l\'appel vers $restaurant',
                    ),
                    icon: const Icon(Icons.call_rounded),
                    label: const Text('Appeler'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openExternalLink(
                      context,
                      Uri.parse('https://wa.me/${whatsappNumber(restaurant)}'),
                      'Impossible d\'ouvrir WhatsApp',
                    ),
                    icon: const Icon(Icons.chat_rounded),
                    label: const Text('WhatsApp'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          TextFormField(
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Code à 6 chiffres',
              prefixIcon: Icon(Icons.pin_rounded),
              counterText: '',
            ),
            validator: (v) => (v == null || v.trim().length != 6) ? 'Entrez le code à 6 chiffres' : null,
          ),
          const SizedBox(height: 14),
          GlowField(
            controller: _password,
            label: 'Nouveau mot de passe',
            icon: Icons.lock_rounded,
            obscure: true,
            canReveal: true,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.next,
            validator: (v) => (v == null || v.length < 6) ? '6 caractères minimum' : null,
          ),
          const SizedBox(height: 14),
          GlowField(
            controller: _confirm,
            label: 'Confirmer le mot de passe',
            icon: Icons.lock_outline_rounded,
            obscure: true,
            canReveal: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _loading ? null : _reset(),
            validator: (v) => v != _password.text ? 'Les mots de passe ne correspondent pas' : null,
          ),
          const SizedBox(height: 24),
          _button('Changer mon mot de passe', _reset),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loading ? null : _requestAgain,
            child: const Text('Je n\'ai pas reçu de code : refaire une demande'),
          ),
          TextButton(
            onPressed: _loading ? null : () => setState(() => _codeStep = false),
            child: const Text('Modifier mon numéro'),
          ),
        ],
      ),
    );
  }

  /// Nouvelle demande depuis l'étape du code (le formulaire du numéro n'est plus affiché).
  Future<void> _requestAgain() async {
    setState(() => _loading = true);
    try {
      _bySms = await forgotPassword(_phone.text.trim());
      if (mounted) showMessage(context, _bySms ? 'Nouveau code envoyé' : 'Nouvelle demande transmise au restaurant');
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
