import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import 'admin_layout.dart';

/// Rapports des ventes par période (gérant) : totaux, CA par jour, répartitions, livreurs, top des plats.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  static const _periods = <String, String>{
    'today': "Aujourd'hui",
    '7d': '7 jours',
    'month': 'Ce mois',
    'last_month': 'Mois dernier',
    'custom': 'Personnalisé',
  };

  String _period = '7d';
  DateTimeRange? _custom;
  SalesReport? _report;
  Object? _error;
  bool _loading = true;
  bool _exporting = false;
  int _requestId = 0;
  final _exportKey = GlobalKey();

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
      case 'month':
        return DateTimeRange(start: DateTime(today.year, today.month), end: today);
      case 'last_month':
        // DateTime(année, mois, 0) = dernier jour du mois précédent.
        return DateTimeRange(start: DateTime(today.year, today.month - 1), end: DateTime(today.year, today.month, 0));
      case 'custom':
        return _custom ?? DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today);
    }
    return DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today);
  }

  static String _dmy(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _rangeLabel() {
    final r = _range;
    return r.start == r.end ? 'le ${_dmy(r.start)}' : 'du ${_dmy(r.start)} au ${_dmy(r.end)}';
  }

  Future<void> _load() async {
    final id = ++_requestId;
    if (!_loading) setState(() => _loading = true);
    final r = _range;
    try {
      final report = await fetchSalesReport(r.start, r.end);
      if (!mounted || id != _requestId) return;
      setState(() {
        _report = report;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _selectPeriod(String p) async {
    if (p == 'custom') return _pickCustomRange();
    if (p == _period) return;
    setState(() => _period = p);
    _load();
  }

  Future<void> _pickCustomRange() async {
    final today = _day(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      locale: const Locale('fr'),
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
    if (picked == null || !mounted) return;
    final start = _day(picked.start), end = _day(picked.end);
    if (end.difference(start).inDays > 365) {
      showMessage(context, 'Période trop longue : 366 jours au maximum.', error: true);
      return;
    }
    setState(() {
      _period = 'custom';
      _custom = DateTimeRange(start: start, end: end);
    });
    _load();
  }

  /// Zone du bouton d'export (requise par la feuille de partage sur iPad).
  Rect? _exportOrigin() {
    final box = _exportKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Télécharge l'export des ventes et le partage (même mécanisme que les encaissements) ;
  /// repli sur le presse-papiers si le partage échoue.
  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final r = _range;
    final period = _rangeLabel();
    CollectionsCsv? csv;
    try {
      csv = await downloadSalesReportCsv(r.start, r.end);
      if (!mounted) return;
      final file = await writeCollectionsCsvFile(csv);
      final label = 'Ventes KALETA $period';
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv', name: csv.fileName)],
          fileNameOverrides: [csv.fileName],
          subject: label,
          title: label,
          text: label,
          sharePositionOrigin: _exportOrigin(),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      if (csv == null) {
        showMessage(context, e, error: true);
      } else {
        await _copy(csv, period);
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _copy(CollectionsCsv csv, String period) async {
    try {
      await Clipboard.setData(ClipboardData(text: csv.text));
    } catch (_) {
      if (mounted) showMessage(context, 'Partage et copie impossibles. Réessayez.', error: true);
      return;
    }
    if (!mounted) return;
    final rows = csv.rows;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 36),
        title: const Text('Partage impossible'),
        content: Text(
          "Le fichier n'a pas pu être partagé depuis ce téléphone. "
          "L'export ($rows commande${rows > 1 ? 's' : ''}, $period) a été copié dans le presse-papiers.\n\n"
          'Collez-le dans un e-mail, une note, WhatsApp ou un tableur (séparateur « ; »).',
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<AuthProvider>().user?.isManager ?? false;
    if (!manager) {
      return Scaffold(
        appBar: AppBar(title: const Text('Rapports')),
        body: const EmptyState(emoji: '🔒', title: 'Réservé au gérant'),
      );
    }
    final report = _report;
    return Scaffold(
      appBar: AppBar(title: const Text('Rapports')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 700 || isAdminTablet(context);
            return ListView(
              padding: EdgeInsets.symmetric(
                vertical: 16,
                horizontal: constraints.maxWidth > 1240 ? (constraints.maxWidth - 1200) / 2 : 16,
              ),
              children: [
                _header(),
                const SizedBox(height: 12),
                if (_loading && report == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 80),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (report == null)
                  ErrorRetry(error: _error ?? 'Erreur', onRetry: _load)
                else ...[
                  if (_loading) const LinearProgressIndicator(minHeight: 2),
                  if (_error != null && !_loading)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Mise à jour impossible : $_error',
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ..._content(report, wide),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in _periods.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: _period == e.key,
                avatar: e.key == 'custom' ? const Icon(Icons.date_range_rounded, size: 18) : null,
                onSelected: (_) => _selectPeriod(e.key),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                'Période : ${_rangeLabel()}',
                style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ),
            FilledButton.tonalIcon(
              key: _exportKey,
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.table_view_rounded),
              label: const Text('Exporter (Excel)'),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _content(SalesReport r, bool wide) {
    Widget pair(Widget a, Widget b) => wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: a),
              const SizedBox(width: 16),
              Expanded(child: b),
            ],
          )
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [a, const SizedBox(height: 20), b]);

    final channel = _section(
      'En ligne / Comptoir',
      _BreakdownCard(
        buckets: _ordered(r.byChannel, const {'app': 'En ligne', 'counter': 'Comptoir'}),
        icons: const {'app': Icons.phone_iphone_rounded, 'counter': Icons.storefront_rounded},
      ),
    );
    final mode = _section(
      'Livraison / À emporter / Sur place',
      _BreakdownCard(
        buckets: _ordered(r.byMode, const {'delivery': 'Livraison', 'pickup': 'À emporter', 'dine_in': 'Sur place'}),
        icons: const {
          'delivery': Icons.delivery_dining_rounded,
          'pickup': Icons.shopping_bag_rounded,
          'dine_in': Icons.restaurant_rounded,
        },
      ),
    );
    final payment = _section(
      'Moyens de paiement',
      _BreakdownCard(
        buckets: _ordered(r.byPayment, const {'cash': 'Espèces', 'flooz': 'Flooz', 'mixx': 'Mixx by Yas'}),
        icons: const {
          'cash': Icons.payments_outlined,
          'flooz': Icons.phone_android_rounded,
          'mixx': Icons.phone_android_rounded,
        },
        showFees: true,
      ),
    );

    return [
      _totals(r, wide),
      const SizedBox(height: 20),
      _section("Chiffre d'affaires par jour", DailyRevenueChart(days: r.daily)),
      const SizedBox(height: 20),
      if (wide) ...[
        pair(channel, mode),
        const SizedBox(height: 20),
        pair(payment, _section('Top 10 des plats', _topProducts(r))),
        const SizedBox(height: 20),
        _section('Livreurs', _drivers(r)),
      ] else ...[
        channel,
        const SizedBox(height: 20),
        mode,
        const SizedBox(height: 20),
        payment,
        const SizedBox(height: 20),
        _section('Livreurs', _drivers(r)),
        const SizedBox(height: 20),
        _section('Top 10 des plats', _topProducts(r)),
      ],
      const SizedBox(height: 24),
    ];
  }

  /// Lignes dans l'ordre voulu, avec 0 pour les clés absentes de la réponse (+ clés inconnues à la fin).
  static List<(String, ReportBucket)> _ordered(List<ReportBucket> raw, Map<String, String> labels) {
    final byKey = <String, ReportBucket>{for (final b in raw) b.key: b};
    return [
      for (final e in labels.entries) (e.value, byKey[e.key] ?? ReportBucket(key: e.key)),
      for (final b in raw)
        if (!labels.containsKey(b.key)) (b.key.isEmpty ? 'Autre' : b.key, b),
    ];
  }

  Widget _section(String title, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
      const SizedBox(height: 10),
      child,
    ],
  );

  Widget _totals(SalesReport r, bool wide) {
    final cards = <Widget>[
      _TotalCard(label: 'Commandes', value: r.orders, icon: Icons.receipt_rounded, color: brandColor(context)),
      _TotalCard(
        label: "Chiffre d'affaires",
        value: r.revenue,
        format: formatPrice,
        icon: Icons.payments_rounded,
        color: AppColors.green,
      ),
      _TotalCard(
        label: 'Panier moyen',
        value: r.avgBasket,
        format: formatPrice,
        icon: Icons.shopping_basket_rounded,
        color: Colors.blue.shade600,
      ),
      _TotalCard(label: 'Annulées', value: r.cancelled, icon: Icons.cancel_outlined, color: Colors.grey.shade600),
      _TotalCard(
        label: "Commissions de l'agrégateur",
        value: r.paymentFees,
        format: formatPrice,
        icon: Icons.account_balance_rounded,
        color: Colors.orange.shade700,
      ),
    ];
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: wide ? 5 : 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        mainAxisExtent: 118,
      ),
      children: [for (final (i, c) in cards.indexed) FadeSlideIn(delay: FadeSlideIn.stagger(i, stepMs: 60), child: c)],
    );
  }

  static String _minutes(double? m) {
    if (m == null) return '—';
    final v = m.round();
    if (v < 60) return '$v min';
    return '${v ~/ 60} h ${(v % 60).toString().padLeft(2, '0')}';
  }

  Widget _drivers(SalesReport r) {
    final scheme = Theme.of(context).colorScheme;
    if (r.byDriver.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text('Aucune livraison sur la période', style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    final head = TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: scheme.onSurfaceVariant);
    const num = TextStyle(fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]);
    Widget cell(String text, {TextStyle? style, TextAlign align = TextAlign.right}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Text(text, textAlign: align, style: style),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Table(
          columnWidths: const {
            0: FlexColumnWidth(2.2),
            1: FlexColumnWidth(1.2),
            2: FlexColumnWidth(1.8),
            3: FlexColumnWidth(1.4),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
              ),
              children: [
                cell('Livreur', style: head, align: TextAlign.left),
                cell('Livr.', style: head),
                cell('Espèces', style: head),
                cell('Durée moy.', style: head),
              ],
            ),
            for (final d in r.byDriver)
              TableRow(
                children: [
                  cell(
                    d.name.isEmpty ? 'Livreur n° ${d.driverId}' : d.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                    align: TextAlign.left,
                  ),
                  cell('${d.deliveries}', style: num),
                  cell(formatPrice(d.cashCollected), style: num),
                  cell(_minutes(d.avgMinutes), style: num),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _topProducts(SalesReport r) {
    final scheme = Theme.of(context).colorScheme;
    final items = r.topProducts.take(10).toList();
    return Card(
      child: items.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(20),
              child: Text('Pas de ventes sur la période', style: TextStyle(color: scheme.onSurfaceVariant)),
            )
          : Column(
              children: [
                for (var i = 0; i < items.length; i++)
                  ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: i == 0 ? AppColors.accent : AppColors.tint,
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.ink),
                      ),
                    ),
                    title: Text(items[i].name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${items[i].quantity} vendu${items[i].quantity > 1 ? 's' : ''}'),
                    trailing: Text(formatPrice(items[i].revenue), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
    );
  }
}

/// Tuile d'un total (même style que les tuiles du tableau de bord, plus compacte).
class _TotalCard extends StatelessWidget {
  final String label;
  final int value;
  final String Function(int) format;
  final IconData icon;
  final Color color;

  const _TotalCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.format = _plain,
  });

  static String _plain(int v) => '$v';

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: color, size: 18),
            ),
            const Spacer(),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: AnimatedCount(
                value: value,
                format: format,
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
              ),
            ),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Répartition : une ligne par catégorie avec barre de proportion (part du chiffre d'affaires).
class _BreakdownCard extends StatelessWidget {
  final List<(String, ReportBucket)> buckets;
  final Map<String, IconData> icons;
  final bool showFees; // commission de l'agrégateur par moyen de paiement

  const _BreakdownCard({required this.buckets, required this.icons, this.showFees = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final totalRevenue = buckets.fold<int>(0, (s, e) => s + e.$2.revenue);
    final totalOrders = buckets.fold<int>(0, (s, e) => s + e.$2.orders);
    // Part du CA ; sans CA (ex. tout à 0), part des commandes.
    double share(ReportBucket b) =>
        totalRevenue > 0 ? b.revenue / totalRevenue : (totalOrders > 0 ? b.orders / totalOrders : 0);
    final bar = dark ? scheme.primary : AppColors.brand;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          children: [
            for (final (label, b) in buckets)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(icons[b.key] ?? Icons.circle_outlined, size: 18, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                        ),
                        Text(
                          '${formatPercent(double.parse((share(b) * 100).toStringAsFixed(1)))} %',
                          style: TextStyle(fontWeight: FontWeight.w900, color: scheme.onSurface),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: share(b)),
                        duration: const Duration(milliseconds: 800),
                        curve: Curves.easeOutCubic,
                        builder: (_, v, _) => LinearProgressIndicator(
                          value: v,
                          minHeight: 8,
                          color: bar,
                          backgroundColor: scheme.onSurfaceVariant.withValues(alpha: 0.15),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${b.orders} commande${b.orders > 1 ? 's' : ''} · ${formatPrice(b.revenue)}'
                      '${showFees && b.key != 'cash' ? ' · commission ${formatPrice(b.fees)}' : ''}',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Histogramme du chiffre d'affaires par jour (même style que le graphique 7 jours du tableau de bord).
/// [days] : un élément par jour (YYYY-MM-DD), dans l'ordre. Au-delà de 14 jours, défilement horizontal.
class DailyRevenueChart extends StatelessWidget {
  final List<DailyStat> days;

  /// Libellé sous chaque barre ; par défaut jour de la semaine (≤ 7 jours) ou « jj/mm ».
  final List<String>? labels;

  /// Barre mise en avant (couleur pleine), par défaut la dernière.
  final int? highlightIndex;

  const DailyRevenueChart({super.key, required this.days, this.labels, this.highlightIndex});

  static const _weekdays = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];

  String _defaultLabel(String day) {
    final d = DateTime.tryParse(day);
    if (d == null) return day;
    if (days.length <= 7) return _weekdays[d.weekday - 1];
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (days.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text('Aucune donnée sur la période', style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    final maxRevenue = days.fold<int>(0, (m, e) => e.revenue > m ? e.revenue : m);
    final highlight = highlightIndex ?? days.length - 1;
    final scroll = days.length > 14;

    Widget bar(int i) {
      final e = days[i];
      return Tooltip(
        message: '${e.orders} commande${e.orders > 1 ? 's' : ''} • ${formatPrice(e.revenue)}',
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              e.orders == 0 ? '' : '${e.orders}',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: maxRevenue == 0 ? 0 : e.revenue / maxRevenue),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => Container(
                height: 4 + 110 * v,
                margin: EdgeInsets.symmetric(horizontal: scroll ? 4 : 6),
                decoration: BoxDecoration(
                  color: i == highlight ? AppColors.brand : AppColors.brand.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              labels != null && i < labels!.length ? labels![i] : _defaultLabel(e.day),
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(fontSize: scroll ? 10 : 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
        child: SizedBox(
          height: 170,
          child: scroll
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true, // jours les plus récents visibles d'abord
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [for (var i = 0; i < days.length; i++) SizedBox(width: 40, child: bar(i))],
                  ),
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [for (var i = 0; i < days.length; i++) Expanded(child: bar(i))],
                ),
        ),
      ),
    );
  }
}
