import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:share_plus/share_plus.dart';

import '../../models_admin.dart';
import '../../services/admin_api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';

/// Encaissements mobile money : totaux, détail par jour et par opérateur, suivi des reversements.
class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({super.key});

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  static const _periods = <String, String>{
    'today': "Aujourd'hui",
    '7d': '7 jours',
    '30d': '30 jours',
    'custom': 'Personnalisé',
  };
  static const _operators = <String?, String>{null: 'Tous', 'flooz': 'Flooz', 'mixx': 'Mixx'};
  static const _settlements = <String?, String>{null: 'Tous', 'en_attente': 'En attente', 'reverse': 'Reversé'};

  String _period = '7d';
  DateTimeRange? _custom;
  String? _operator;
  String? _settlement;

  CollectionsReport? _report;
  Object? _error;
  bool _loading = true;
  bool _exporting = false;
  final _exportKey = GlobalKey();
  bool _settling = false;
  int _requestId = 0;
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTimeRange get _range {
    final today = _day(DateTime.now());
    switch (_period) {
      case 'today':
        return DateTimeRange(start: today, end: today);
      case '30d':
        return DateTimeRange(start: today.subtract(const Duration(days: 29)), end: today);
      case 'custom':
        return _custom ?? DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today);
    }
    return DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today);
  }

  Map<String, String> get _query {
    final r = _range;
    return collectionsQuery(from: r.start, to: r.end, operator: _operator, settlement: _settlement);
  }

  Future<void> _load() async {
    final id = ++_requestId;
    if (!_loading) setState(() => _loading = true);
    try {
      final report = await fetchCollections(_query);
      if (!mounted || id != _requestId) return;
      setState(() {
        _report = report;
        _error = null;
        _loading = false;
        // Ne garde que les paiements encore visibles et en attente de reversement.
        final pendingIds = report.payments.where((p) => !p.isSettled).map((p) => p.id).toSet();
        _selected.retainAll(pendingIds);
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _changeFilters(VoidCallback change) {
    setState(() {
      change();
      _selected.clear();
    });
    _load();
  }

  Future<void> _pickCustomRange() async {
    final today = _day(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: today,
      initialDateRange: _custom ?? DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today),
      helpText: 'Choisir la période',
      saveText: 'Valider',
      cancelText: 'Annuler',
      confirmText: 'Valider',
      fieldStartLabelText: 'Début',
      fieldEndLabelText: 'Fin',
    );
    if (picked == null) return;
    _changeFilters(() {
      _period = 'custom';
      _custom = DateTimeRange(start: _day(picked.start), end: _day(picked.end));
    });
  }

  /// Zone du bouton d'export (requise par la feuille de partage sur iPad).
  Rect? _exportOrigin() {
    final box = _exportKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Exporte le CSV : [share] = fichier via la feuille de partage, sinon copie dans le presse-papiers.
  Future<void> _export({required bool share}) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final period = _rangeLabel();
    CollectionsCsv? csv;
    try {
      csv = await downloadCollectionsCsv(_query);
      if (!mounted) return;
      if (!share) {
        await _copy(csv, period);
        return;
      }
      final file = await writeCollectionsCsvFile(csv);
      final label = 'Encaissements KALETA $period';
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'text/csv', name: csv.fileName)],
        fileNameOverrides: [csv.fileName],
        subject: label,
        title: label,
        text: label,
        sharePositionOrigin: _exportOrigin(),
      ));
    } catch (e) {
      if (!mounted) return;
      if (csv == null) {
        // Échec du téléchargement : message du serveur.
        showMessage(context, e, error: true);
      } else {
        // Partage impossible : repli sur le presse-papiers.
        await _copy(csv, period, shareFailed: true);
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _copy(CollectionsCsv csv, String period, {bool shareFailed = false}) async {
    try {
      await Clipboard.setData(ClipboardData(text: csv.text));
    } catch (e) {
      if (mounted) {
        showMessage(context, shareFailed ? 'Partage et copie impossibles. Réessayez.' : 'Copie impossible. Réessayez.',
            error: true);
      }
      return;
    }
    if (!mounted) return;
    final rows = csv.rows;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          shareFailed ? Icons.warning_amber_rounded : Icons.content_paste_rounded,
          color: shareFailed ? Colors.orange.shade700 : AppColors.green,
          size: 36,
        ),
        title: Text(shareFailed ? 'Partage impossible' : 'Export CSV copié'),
        content: Text(
          '${shareFailed ? "Le fichier n'a pas pu être partagé depuis ce téléphone. " : ''}'
          'Le CSV ($rows paiement${rows > 1 ? 's' : ''}, période $period) '
          'a été copié dans le presse-papiers.\n\n'
          'Collez-le dans un e-mail, une note, WhatsApp ou un tableur '
          '(séparateur « ; »), puis enregistrez-le en .csv si besoin.',
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _settle() async {
    final report = _report;
    if (report == null || _selected.isEmpty) return;
    final ids = _selected.toList();
    final net = report.payments.where((p) => _selected.contains(p.id)).fold<int>(0, (s, p) => s + p.net);
    final reference = await showDialog<String>(
      context: context,
      builder: (_) => _SettlementDialog(count: ids.length, net: net),
    );
    if (reference == null || !mounted) return;
    setState(() => _settling = true);
    try {
      final n = await createSettlement(ids, reference);
      if (!mounted) return;
      _selected.clear();
      showMessage(context, '$n paiement${n > 1 ? 's' : ''} marqué${n > 1 ? 's' : ''} comme reversé${n > 1 ? 's' : ''}');
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _settling = false);
    }
  }

  static String _short(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

  String _rangeLabel() {
    final r = _range;
    if (r.start == r.end) return 'du ${_short(r.start)}/${r.start.year}';
    return 'du ${_short(r.start)} au ${_short(r.end)}/${r.end.year}';
  }

  /// « 2026-10-01 » → « 01/10 ».
  static String _dayLabel(String ymd) {
    final p = ymd.split('-');
    return p.length == 3 ? '${p[2]}/${p[1]}' : ymd;
  }

  Widget _chips<T>(Map<T, String> options, T value, void Function(T) onSelected) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        children: [
          for (final o in options.entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(o.value),
                selected: value == o.key,
                showCheckmark: false,
                selectedColor: AppColors.brand,
                backgroundColor: cs.surface,
                labelStyle: TextStyle(
                  color: value == o.key ? Colors.white : cs.onSurface,
                  fontWeight: FontWeight.w700,
                ),
                onSelected: (_) => onSelected(o.key),
              ),
            ),
        ],
      ),
    );
  }

  Widget _filterLabel(String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final report = _report;
    final selectedNet = report == null
        ? 0
        : report.payments.where((p) => _selected.contains(p.id)).fold<int>(0, (s, p) => s + p.net);

    final filters = <Widget>[
      _filterLabel('Période'),
      _chips<String>(_periods, _period, (k) {
        if (k == 'custom') {
          _pickCustomRange();
        } else if (k != _period) {
          _changeFilters(() => _period = k);
        }
      }),
      if (_period == 'custom')
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text('Période ${_rangeLabel()}', style: TextStyle(color: cs.onSurfaceVariant)),
        ),
      _filterLabel('Opérateur'),
      _chips<String?>(_operators, _operator, (k) {
        if (k != _operator) _changeFilters(() => _operator = k);
      }),
      _filterLabel('Reversement'),
      _chips<String?>(_settlements, _settlement, (k) {
        if (k != _settlement) _changeFilters(() => _settlement = k);
      }),
    ];

    final List<Widget> content;
    if (report == null) {
      content = [
        if (_error != null)
          ErrorRetry(error: _error!, onRetry: _load)
        else
          const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          ),
      ];
    } else {
      final pending = report.payments.where((p) => !p.isSettled).toList();
      final allSelected = pending.isNotEmpty && pending.every((p) => _selected.contains(p.id));
      content = [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text('Actualisation impossible : $_error', style: TextStyle(color: cs.error)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _TotalsGrid(totals: report.totals),
        ),
        const SectionTitle('Par jour et opérateur'),
        if (report.summary.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text('Aucun encaissement sur cette période.', style: TextStyle(color: cs.onSurfaceVariant)),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 18,
                  horizontalMargin: 14,
                  headingTextStyle: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurface),
                  columns: [
                    DataColumn(label: Text('Jour')),
                    DataColumn(label: Text('Opérateur')),
                    DataColumn(label: Text('Encaissé'), numeric: true),
                    DataColumn(label: Text('Frais'), numeric: true),
                    DataColumn(label: Text('Net'), numeric: true),
                    DataColumn(label: Text('Reversé'), numeric: true),
                  ],
                  rows: [
                    for (final d in report.summary)
                      DataRow(cells: [
                        DataCell(Text(_dayLabel(d.day))),
                        DataCell(Text(operatorShortLabel(d.operator))),
                        DataCell(Text(formatPrice(d.gross))),
                        DataCell(Text(formatPrice(d.fees))),
                        DataCell(Text(formatPrice(d.net), style: const TextStyle(fontWeight: FontWeight.w700))),
                        DataCell(Text(formatPrice(d.settled))),
                      ]),
                  ],
                ),
              ),
            ),
          ),
        SectionTitle(
          'Paiements (${report.payments.length})',
          trailing: pending.isEmpty
              ? null
              : TextButton(
                  onPressed: () => setState(() {
                    if (allSelected) {
                      _selected.clear();
                    } else {
                      _selected.addAll(pending.map((p) => p.id));
                    }
                  }),
                  child: Text(allSelected ? 'Tout désélectionner' : 'Sélectionner les en attente'),
                ),
        ),
        if (report.payments.isEmpty)
          const EmptyState(
            emoji: '💸',
            title: 'Aucun paiement',
            message: 'Aucun paiement mobile money ne correspond à ces filtres.',
          )
        else
          for (final p in report.payments)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: _PaymentTile(
                payment: p,
                selected: _selected.contains(p.id),
                onChanged: p.isSettled
                    ? null
                    : (v) => setState(() {
                          if (v) {
                            _selected.add(p.id);
                          } else {
                            _selected.remove(p.id);
                          }
                        }),
              ),
            ),
        const SizedBox(height: 24),
      ];
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Encaissements'),
        actions: [
          PopupMenuButton<bool>(
            key: _exportKey,
            tooltip: 'Exporter en CSV',
            enabled: !_exporting,
            onSelected: (share) => _export(share: share),
            icon: _exporting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Icon(Icons.ios_share_rounded),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: true,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.share_rounded),
                  title: Text('Partager le fichier CSV'),
                  subtitle: Text('WhatsApp, e-mail, Drive, Excel…'),
                ),
              ),
              PopupMenuItem(
                value: false,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.content_copy_rounded),
                  title: Text('Copier'),
                  subtitle: Text('Dans le presse-papiers'),
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: _loading && report != null
            ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator(minHeight: 3))
            : null,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [...filters, ...content],
        ),
      ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : Material(
              color: cs.surfaceContainerHighest,
              elevation: 8,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_selected.length} sélectionné${_selected.length > 1 ? 's' : ''}',
                              style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurface),
                            ),
                            Text('Net : ${formatPrice(selectedNet)}', style: TextStyle(color: cs.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                        onPressed: _settling ? null : _settle,
                        icon: _settling
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5))
                            : const Icon(Icons.account_balance_rounded),
                        label: const Text('Marquer comme reversé'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _TotalsGrid extends StatelessWidget {
  final CollectionTotals totals;
  const _TotalsGrid({required this.totals});

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      _TotalTile(label: 'Encaissé', value: totals.gross, icon: Icons.payments_rounded, color: AppColors.green),
      _TotalTile(label: 'Frais', value: totals.fees, icon: Icons.percent_rounded, color: Colors.orange.shade700),
      _TotalTile(
        label: 'Net à recevoir',
        value: totals.toReceive,
        icon: Icons.hourglass_bottom_rounded,
        color: brandColor(context),
      ),
      _TotalTile(
        label: 'Déjà reversé',
        value: totals.settled,
        icon: Icons.account_balance_rounded,
        color: Colors.blue.shade600,
      ),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.9,
      children: tiles,
    );
  }
}

class _TotalTile extends StatelessWidget {
  final String label;
  final int value;
  final IconData icon;
  final Color color;
  const _TotalTile({required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatPrice(value),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: cs.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentTile extends StatelessWidget {
  final CollectionPayment payment;
  final bool selected;
  final ValueChanged<bool>? onChanged; // null = déjà reversé (non sélectionnable)

  const _PaymentTile({required this.payment, required this.selected, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = payment;
    final settled = p.isSettled;
    final details = <String>[
      if (p.customerName.isNotEmpty) p.customerName,
      if (p.paidAt != null) 'Payé le ${formatDateTime(p.paidAt!)}',
      'Brut ${formatPrice(p.gross)} • Frais ${formatPrice(p.providerFee)}',
      if ((p.operatorReference ?? '').isNotEmpty) 'Réf. opérateur : ${p.operatorReference}',
      if (settled)
        'Reversé${p.settledAt != null ? ' le ${formatDateTime(p.settledAt!)}' : ''}'
            '${(p.settlementReference ?? '').isNotEmpty ? ' • virement ${p.settlementReference}' : ''}',
    ];
    final onChanged = this.onChanged;
    return Card(
      margin: EdgeInsets.zero,
      color: selected ? cs.primaryContainer.withValues(alpha: 0.5) : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onChanged == null ? null : () => onChanged(!selected),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 14, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 44,
                child: settled
                    ? const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Icon(Icons.check_circle_rounded, color: AppColors.green),
                      )
                    : Checkbox(
                        value: selected,
                        onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
                      ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Commande n°${p.orderId} • ${operatorShortLabel(p.operator)}',
                            style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurface),
                          ),
                        ),
                        Text(
                          formatPrice(p.net),
                          style: TextStyle(fontWeight: FontWeight.w900, color: cs.onSurface),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(details.join('\n'), style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: (settled ? AppColors.green : Colors.orange.shade700).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        settled ? 'Reversé' : 'En attente de reversement',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: settled ? AppColors.green : Colors.orange.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettlementDialog extends StatefulWidget {
  final int count;
  final int net;
  const _SettlementDialog({required this.count, required this.net});

  @override
  State<_SettlementDialog> createState() => _SettlementDialogState();
}

class _SettlementDialogState extends State<_SettlementDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reference = TextEditingController();

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, _reference.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = widget.count;
    return AlertDialog(
      title: const Text('Marquer comme reversé'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$n paiement${n > 1 ? 's' : ''} • net ${formatPrice(widget.net)}.\n'
                'Indiquez la référence du virement reçu du prestataire.',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _reference,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Référence du virement *', hintText: 'Ex. : VIR-2026-10-01'),
                validator: (v) => (v ?? '').trim().length < 3 ? 'La référence du virement est obligatoire' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: _submit,
          child: const Text('Confirmer'),
        ),
      ],
    );
  }
}
