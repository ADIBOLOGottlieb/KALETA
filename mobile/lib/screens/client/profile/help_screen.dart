import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../widgets/common.dart';

/// Ouvre un lien (tel:, WhatsApp...) dans l'application externe, avec message si échec.
Future<void> openExternalLink(BuildContext context, Uri uri, String failMessage) async {
  bool ok = false;
  try {
    ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) showMessage(context, failMessage, error: true);
}

/// Numéro au format international sans « + » ni espaces, pour wa.me (Togo : 228 par défaut).
String whatsappNumber(String phone) {
  var digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (digits.length == 8) digits = '228$digits';
  return digits;
}

/// Numéro composable pour tel: (garde le « + » initial).
String dialNumber(String phone) {
  final t = phone.trim();
  final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
  return t.startsWith('+') ? '+$digits' : digits;
}

class _Faq {
  final String question;
  final String answer;
  const _Faq(this.question, this.answer);
}

const _faqs = <_Faq>[
  _Faq(
    'Comment passer une commande ?',
    'Ajoutez vos plats au panier depuis l\'accueil, ouvrez le panier puis « Commander ». '
        'Choisissez la livraison ou le retrait au restaurant, votre adresse et le mode de paiement, '
        'puis validez. Vous suivez ensuite l\'avancement dans l\'onglet « Commandes ».',
  ),
  _Faq(
    'Combien de temps prend la livraison ?',
    'Le délai dépend de l\'affluence et de la distance (en général 30 à 60 minutes). '
        'Le statut de votre commande est mis à jour à chaque étape : confirmée, en préparation, '
        'en livraison, livrée. Enregistrer votre position GPS aide le livreur à vous trouver.',
  ),
  _Faq(
    'Quels sont les frais ?',
    'Les frais de livraison sont affichés avant de valider la commande. Un paiement mobile money '
        '(Flooz ou Mixx by Yas) peut inclure de petits frais de service, eux aussi indiqués avant '
        'validation. Le retrait au restaurant n\'a pas de frais de livraison.',
  ),
  _Faq(
    'Comment payer avec Flooz ou Mixx by Yas ?',
    'Choisissez Flooz ou Mixx, indiquez votre numéro : une demande de paiement s\'affiche sur votre '
        'téléphone. Vérifiez le montant puis tapez votre code PIN sur votre téléphone pour valider. '
        'Vous pouvez aussi payer en espèces à la livraison.',
  ),
  _Faq(
    'Mon code PIN mobile money peut-il m\'être demandé ?',
    'Non. Ne communiquez JAMAIS votre code PIN, ni par téléphone, ni par SMS, ni dans l\'application. '
        'KALETA ne vous le demandera jamais : il se saisit uniquement sur votre téléphone, '
        'dans la fenêtre de votre opérateur.',
  ),
  _Faq(
    'Puis-je annuler une commande ?',
    'Oui, tant qu\'elle n\'est pas encore confirmée par le restaurant : ouvrez la commande et '
        'appuyez sur « Annuler ». Une commande déjà payée par mobile money, ou déjà confirmée, '
        's\'annule uniquement en appelant le restaurant.',
  ),
  _Faq(
    'Comment suis-je remboursé ?',
    'Si une commande déjà payée par mobile money est annulée, le restaurant vous rembourse sur le '
        'numéro utilisé pour le paiement. En cas de doute, contactez-nous par téléphone ou WhatsApp '
        'avec le numéro de la commande.',
  ),
  _Faq(
    'Comment supprimer mon compte ?',
    'Profil > « Supprimer mon compte », puis confirmez avec votre mot de passe. Vos informations '
        'personnelles (nom, e-mail, photo, adresses) sont effacées. L\'historique des commandes est '
        'conservé de façon anonyme pour la comptabilité du restaurant.',
  ),
];

/// Questions fréquentes.
class FaqScreen extends StatelessWidget {
  const FaqScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Questions fréquentes')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          for (final f in _faqs)
            Card(
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text(f.question, style: const TextStyle(fontWeight: FontWeight.w700)),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [Text(f.answer, style: TextStyle(color: cs.onSurfaceVariant, height: 1.4))],
              ),
            ),
        ],
      ),
    );
  }
}
