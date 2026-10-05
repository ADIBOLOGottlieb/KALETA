import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/cart_provider.dart';
import '../../services/account_api.dart';
import '../../services/api.dart';
import '../../services/order_events.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../legal/legal_screen.dart';
import 'profile/avatar.dart';
import 'profile/change_password_screen.dart';
import 'profile/delete_account_screen.dart';
import 'profile/edit_profile_screen.dart';
import 'profile/help_screen.dart';
import 'profile/saved_addresses_screen.dart';

// L'écran admin « Plus » ouvre EditProfileScreen depuis ce fichier.
export 'profile/edit_profile_screen.dart' show EditProfileScreen;

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<AccountStats> _stats = fetchAccountStats();

  @override
  void initState() {
    super.initState();
    ordersChanged.addListener(_reloadStats);
  }

  @override
  void dispose() {
    ordersChanged.removeListener(_reloadStats);
    super.dispose();
  }

  void _reloadStats() {
    if (mounted) setState(() => _stats = fetchAccountStats());
  }

  Future<void> _refresh() async {
    _reloadStats();
    await context.read<AuthProvider>().refreshUser();
    try {
      await _stats;
    } catch (_) {
      // Affiché dans la carte des statistiques.
    }
  }

  void _open(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    if (user == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Mon profil')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    EditableAvatar(user: user),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(user.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                          Text(user.phone, style: TextStyle(color: cs.onSurfaceVariant)),
                          if ((user.email ?? '').isNotEmpty)
                            Text(user.email!, style: TextStyle(color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!user.isAdmin) ...[
              const SizedBox(height: 12),
              _StatsCard(future: _stats, onRetry: _reloadStats),
            ],
            const _SectionLabel('Mon compte'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(Icons.edit_rounded, color: brandColor(context)),
                    title: const Text('Modifier mes informations'),
                    subtitle: Text(
                      (user.momoPhone ?? '').isNotEmpty ? 'Mobile money : ${user.momoPhone}' : 'Nom, e-mail, mobile money',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _open(EditProfileScreen(user: user)),
                  ),
                  ListTile(
                    leading: Icon(Icons.location_on_rounded, color: brandColor(context)),
                    title: const Text('Mes adresses'),
                    subtitle: const Text('Maison, bureau...'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _open(const SavedAddressesScreen()),
                  ),
                  ListTile(
                    leading: Icon(Icons.lock_reset_rounded, color: brandColor(context)),
                    title: const Text('Changer mon mot de passe'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _open(const ChangePasswordScreen()),
                  ),
                ],
              ),
            ),
            const _SectionLabel('Apparence'),
            const _ThemeCard(),
            const _SectionLabel('Aide'),
            Card(
              child: Column(
                children: [
                  const _RestaurantContact(),
                  ListTile(
                    leading: Icon(Icons.help_outline_rounded, color: brandColor(context)),
                    title: const Text('Questions fréquentes'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _open(const FaqScreen()),
                  ),
                ],
              ),
            ),
            const _SectionLabel('Informations légales'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(Icons.description_rounded, color: brandColor(context)),
                    title: Text(legalTitle(LegalDoc.terms)),
                    subtitle: user.termsAcceptedAt == null
                        ? null
                        : Text('Acceptées le ${formatDateTime(user.termsAcceptedAt!)}'),
                    trailing: const Icon(Icons.open_in_new_rounded, size: 20),
                    onTap: () => openLegalDoc(context, LegalDoc.terms),
                  ),
                  ListTile(
                    leading: Icon(Icons.privacy_tip_rounded, color: brandColor(context)),
                    title: Text(legalTitle(LegalDoc.privacy)),
                    trailing: const Icon(Icons.open_in_new_rounded, size: 20),
                    onTap: () => openLegalDoc(context, LegalDoc.privacy),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
              onPressed: () async {
                if (await confirmDialog(context, 'Déconnexion', 'Voulez-vous vous déconnecter ?',
                    confirm: 'Se déconnecter')) {
                  if (!context.mounted) return;
                  context.read<CartProvider>().clear();
                  context.read<AuthProvider>().logout();
                }
              },
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Se déconnecter'),
            ),
            // Le serveur refuse la suppression d'un compte administrateur.
            if (!user.isAdmin)
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                onPressed: () => _open(const DeleteAccountScreen()),
                icon: const Icon(Icons.delete_forever_rounded, size: 20),
                label: const Text('Supprimer mon compte'),
              ),
            const SizedBox(height: 24),
            const Center(child: AppLogo(size: 70)),
            const SizedBox(height: 8),
            Center(
              child: Text('KALETA • version $appVersion', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Nombre de commandes et total dépensé.
class _StatsCard extends StatelessWidget {
  final Future<AccountStats> future;
  final VoidCallback onRetry;
  const _StatsCard({required this.future, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<AccountStats>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return Card(
            child: ListTile(
              leading: Icon(Icons.bar_chart_rounded, color: cs.onSurfaceVariant),
              title: const Text('Statistiques indisponibles'),
              trailing: TextButton(onPressed: onRetry, child: const Text('Réessayer')),
            ),
          );
        }
        final s = snap.data;
        final loading = snap.connectionState != ConnectionState.done || s == null;
        Widget tile(IconData icon, String label, String value) => Expanded(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: brandColor(context), size: 22),
                    const SizedBox(height: 8),
                    loading
                        ? const SizedBox(
                            height: 24,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            ),
                          )
                        : FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              value,
                              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: cs.onSurface),
                            ),
                          ),
                    Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            );
        return Row(
          children: [
            tile(Icons.receipt_long_rounded, (s?.ordersCount ?? 0) > 1 ? 'Commandes' : 'Commande',
                '${s?.ordersCount ?? 0}'),
            const SizedBox(width: 12),
            tile(Icons.payments_rounded, 'Total dépensé', formatPrice(s?.totalSpent ?? 0)),
          ],
        );
      },
    );
  }
}

/// Choix du thème : clair, sombre ou celui du téléphone.
class _ThemeCard extends StatelessWidget {
  const _ThemeCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Thème', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            const ThemeModeSelector(),
          ],
        ),
      ),
    );
  }
}

/// Appeler le restaurant ou lui écrire sur WhatsApp (numéro des paramètres).
class _RestaurantContact extends StatefulWidget {
  const _RestaurantContact();

  @override
  State<_RestaurantContact> createState() => _RestaurantContactState();
}

class _RestaurantContactState extends State<_RestaurantContact> {
  late Future<AppSettings> _future = Api.instance.settings();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<AppSettings>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          return ListTile(
            leading: Icon(Icons.support_agent_rounded, color: cs.onSurfaceVariant),
            title: const Text('Contact du restaurant indisponible'),
            subtitle: const Text('Vérifiez votre connexion'),
            trailing: TextButton(
              onPressed: () => setState(() => _future = Api.instance.settings()),
              child: const Text('Réessayer'),
            ),
          );
        }
        final s = snap.data;
        if (s == null) {
          return const ListTile(
            leading: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
            title: Text('Contact du restaurant...'),
          );
        }
        final phone = s.restaurantPhone.trim();
        if (phone.isEmpty) {
          return ListTile(
            leading: Icon(Icons.support_agent_rounded, color: cs.onSurfaceVariant),
            title: const Text('Numéro du restaurant non renseigné'),
            subtitle: s.restaurantAddress.isEmpty ? null : Text(s.restaurantAddress),
          );
        }
        return Column(
          children: [
            ListTile(
              leading: Icon(Icons.call_rounded, color: brandColor(context)),
              title: const Text('Appeler le restaurant'),
              subtitle: Text(s.restaurantAddress.isEmpty ? phone : '$phone\n${s.restaurantAddress}'),
              isThreeLine: s.restaurantAddress.isNotEmpty,
              onTap: () => openExternalLink(
                context,
                Uri(scheme: 'tel', path: dialNumber(phone)),
                'Impossible de lancer l\'appel vers $phone',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.chat_rounded, color: AppColors.green),
              title: const Text('Écrire sur WhatsApp'),
              subtitle: Text(phone),
              onTap: () => openExternalLink(
                context,
                Uri.parse('https://wa.me/${whatsappNumber(phone)}'),
                'Impossible d\'ouvrir WhatsApp',
              ),
            ),
          ],
        );
      },
    );
  }
}
