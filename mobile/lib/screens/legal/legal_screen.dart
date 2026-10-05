import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../services/auth_api.dart';
import '../../theme.dart';

export '../../services/auth_api.dart' show LegalDoc;

/// Version de l'app : `--dart-define=APP_VERSION=1.2.3` au build, sinon valeur par défaut.
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');

String legalTitle(LegalDoc doc) =>
    doc == LegalDoc.terms ? 'Conditions d\'utilisation' : 'Politique de confidentialité';

/// Ouvre la page publique dans le navigateur externe (pas de WebView).
/// Hors ligne ou si le navigateur ne s'ouvre pas : affiche le résumé intégré.
Future<void> openLegalDoc(BuildContext context, LegalDoc doc) async {
  final uri = await legalUrl(doc);
  var ok = false;
  try {
    // Vérifie d'abord que la page est joignable (sinon le navigateur afficherait une erreur).
    final res = await http.head(uri).timeout(const Duration(seconds: 8));
    if (res.statusCode < 400) ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => LegalScreen(doc: doc)));
  }
}

/// Résumé intégré d'un document légal (repli hors ligne), avec lien vers la version complète.
class LegalScreen extends StatelessWidget {
  final LegalDoc doc;
  const LegalScreen({super.key, required this.doc});

  Future<void> _openBrowser(BuildContext context) async {
    var ok = false;
    try {
      ok = await launchUrl(await legalUrl(doc), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Impossible d\'ouvrir le navigateur. Vérifiez votre connexion.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sections = doc == LegalDoc.terms ? _termsSummary : _privacySummary;
    return Scaffold(
      appBar: AppBar(title: Text(legalTitle(doc))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(Icons.wifi_off_rounded, color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Résumé disponible hors ligne. La version complète s\'ouvre dans le navigateur.',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _openBrowser(context),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Lire la version complète'),
          ),
          const SizedBox(height: 8),
          for (final (title, body) in sections) ...[
            const SizedBox(height: 16),
            Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: brandColor(context))),
            const SizedBox(height: 6),
            Text(body, style: TextStyle(color: cs.onSurface, height: 1.45)),
          ],
        ],
      ),
    );
  }
}

const _termsSummary = <(String, String)>[
  (
    'Le service',
    'KALETA (Lomé, Togo) permet de commander des plats à emporter ou en livraison. '
        'Les prix, frais de livraison et éventuels frais de paiement sont affichés avant la validation.',
  ),
  (
    'Votre compte',
    'Vous créez un compte avec votre nom, votre numéro de téléphone et un mot de passe. Vous êtes '
        'responsable de la confidentialité de votre mot de passe et de l\'exactitude de vos informations.',
  ),
  (
    'Commandes et paiement',
    'Une commande est confirmée par le restaurant. Le paiement se fait en espèces ou par mobile money '
        '(Flooz, Mixx by Yas) via un agrégateur de paiement : votre code PIN ne nous est jamais demandé.',
  ),
  (
    'Annulation et remboursement',
    'Une commande non confirmée peut être annulée dans l\'application. Une commande payée puis annulée '
        'est remboursée sur le numéro utilisé pour le paiement.',
  ),
  (
    'Suppression du compte',
    'Vous pouvez supprimer votre compte à tout moment : Profil > « Supprimer mon compte ».',
  ),
];

const _privacySummary = <(String, String)>[
  (
    'Données collectées',
    'Nom, numéro de téléphone, e-mail (facultatif), adresses et position GPS de livraison, photo de '
        'profil (facultative) et historique de vos commandes.',
  ),
  (
    'Pourquoi',
    'Préparer et livrer vos commandes, vous contacter à leur sujet, gérer les paiements et la sécurité '
        'de votre compte. Vos données ne sont pas vendues.',
  ),
  (
    'Paiement',
    'Le paiement mobile money passe par un agrégateur agréé. Aucun code PIN n\'est collecté par '
        'l\'application.',
  ),
  (
    'Conservation',
    'Vos données sont conservées tant que votre compte est actif. À la suppression du compte, vos '
        'informations personnelles sont effacées ; l\'historique des commandes est gardé de façon '
        'anonyme pour la comptabilité.',
  ),
  (
    'Vos droits',
    'Vous pouvez consulter, corriger ou supprimer vos informations depuis votre profil, ou en '
        'contactant le restaurant par téléphone ou WhatsApp.',
  ),
];
