import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/auth_api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../client/profile/help_screen.dart' show dialNumber, openExternalLink, whatsappNumber;

/// Demandes « mot de passe oublié » : sans prestataire SMS, l'admin communique le code
/// au client par téléphone ou WhatsApp, puis marque la demande comme traitée.
class PasswordResetsScreen extends StatefulWidget {
  const PasswordResetsScreen({super.key});

  @override
  State<PasswordResetsScreen> createState() => _PasswordResetsScreenState();
}

class _PasswordResetsScreenState extends State<PasswordResetsScreen> {
  List<PasswordResetRequest>? _items;
  Object? _error;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await fetchPasswordResets();
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _done(PasswordResetRequest r) async {
    final ok = await confirmDialog(
      context,
      'Demande traitée ?',
      'Confirmez que le code a été communiqué à ${r.name.isEmpty ? r.phone : r.name}. '
          'La demande disparaîtra de la liste.',
      confirm: 'Traité',
    );
    if (!ok || !mounted) return;
    setState(() => _busy.add(r.id));
    try {
      await markPasswordResetDone(r.id);
      if (!mounted) return;
      setState(() => _items?.removeWhere((e) => e.id == r.id));
      passwordResetCount.value = _items?.length ?? 0;
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(r.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    Widget body;
    if (items == null && _error != null) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 80),
          EmptyState(
            emoji: '📡',
            title: 'Chargement impossible',
            message: '$_error',
            action: FilledButton(onPressed: _load, child: const Text('Réessayer')),
          ),
        ],
      );
    } else if (items == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (items.isEmpty) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 80),
          EmptyState(
            emoji: '🔑',
            title: 'Aucune demande en attente',
            message: 'Les demandes « mot de passe oublié » des clients apparaîtront ici.',
          ),
        ],
      );
    } else {
      body = ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: items.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          if (i == 0) return const _Help();
          final r = items[i - 1];
          return _ResetCard(request: r, busy: _busy.contains(r.id), onDone: () => _done(r));
        },
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Mots de passe oubliés')),
      body: RefreshIndicator(onRefresh: _load, child: body),
    );
  }
}

class _Help extends StatelessWidget {
  const _Help();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      'Vérifiez l\'identité du client (nom, commandes récentes), puis appelez-le ou écrivez-lui sur '
      'WhatsApp pour lui donner son code. Ne communiquez le code qu\'au numéro du compte.',
      style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
    );
  }
}

class _ResetCard extends StatelessWidget {
  final PasswordResetRequest request;
  final bool busy;
  final VoidCallback onDone;
  const _ResetCard({required this.request, required this.busy, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = request;
    final code = r.code;
    final message = code == null
        ? 'Bonjour, ici KALETA au sujet de votre demande de nouveau mot de passe.'
        : 'Bonjour, ici KALETA. Votre code pour choisir un nouveau mot de passe est : $code';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.person_rounded, color: brandColor(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.name.isEmpty ? r.phone : r.name,
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      if (r.name.isNotEmpty) Text(r.phone, style: TextStyle(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                if (r.createdAt != null)
                  Text(timeAgo(r.createdAt!), style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: code == null
                  ? Text('Code envoyé par SMS au client.', style: TextStyle(color: cs.onSurfaceVariant))
                  : Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Code à communiquer',
                                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                              SelectableText(
                                code,
                                style: TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 6,
                                  color: r.expired ? cs.onSurfaceVariant : cs.onSurface,
                                ),
                              ),
                              if (r.expired)
                                const Text('Code expiré : le client doit refaire une demande',
                                    style: TextStyle(fontSize: 12, color: AppColors.danger)),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copier le code',
                          icon: const Icon(Icons.copy_rounded),
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: code));
                            if (context.mounted) showMessage(context, 'Code copié');
                          },
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openExternalLink(
                      context,
                      Uri(scheme: 'tel', path: dialNumber(r.phone)),
                      'Impossible de lancer l\'appel vers ${r.phone}',
                    ),
                    icon: const Icon(Icons.call_rounded),
                    label: const Text('Appeler'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openExternalLink(
                      context,
                      Uri.parse('https://wa.me/${whatsappNumber(r.phone)}?text=${Uri.encodeComponent(message)}'),
                      'Impossible d\'ouvrir WhatsApp',
                    ),
                    icon: const Icon(Icons.chat_rounded, color: AppColors.green),
                    label: const Text('WhatsApp'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: busy ? null : onDone,
              icon: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check_rounded),
              label: const Text('Traité'),
            ),
          ],
        ),
      ),
    );
  }
}
