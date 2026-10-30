import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../common/boq_picker.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../common/photo_widgets.dart';
import '../data/construction_repository.dart';
import '../data/photo_source.dart';
import '../models/dpr_models.dart';
import '../models/labour_models.dart';
import '../models/project_models.dart';
import '../../../widgets/busy.dart';

/// Creates a DPR, or replaces all editable content of a draft DPR.
class DprFormScreen extends ConsumerStatefulWidget {
  const DprFormScreen({
    super.key,
    this.dprId,
    this.initialLocationId,
    this.initialDate,
  });

  final String? dprId;
  final String? initialLocationId;
  final String? initialDate;

  @override
  ConsumerState<DprFormScreen> createState() => _DprFormScreenState();
}

class _DprFormScreenState extends ConsumerState<DprFormScreen>
    with DirtyTracking<DprFormScreen> {
  final _formKey = GlobalKey<FormState>();
  String? _locationId;
  late DateTime _date;
  String _weather = '';
  String _summary = '';
  String _hindrances = '';
  final List<_WorkRow> _work = [];
  final Map<Trade, int> _labour = {};
  final List<_EquipmentRow> _equipment = [];
  final List<DprPhoto> _photos = [];
  bool _loading = false;
  bool _busy = false;

  /// Bumped when the form is filled from the server (load, copy yesterday)
  /// so fields built with `initialValue` show the new values.
  int _generation = 0;

  /// Set when the loaded DPR is no longer a draft (the server refuses edits).
  DprStatus? _notEditable;

  /// Editing a rejected report: saving keeps it rejected until resubmitted.
  bool _rejected = false;

  bool get _editing => widget.dprId != null;

  @override
  void initState() {
    super.initState();
    _locationId = widget.initialLocationId;
    _date = parseApiDate(widget.initialDate) ?? today();
    final id = widget.dprId;
    if (id != null) _load(id);
  }

  Future<void> _load(String id) async {
    setState(() => _loading = true);
    try {
      final dpr = await ref.read(constructionRepositoryProvider).dpr(id);
      if (!mounted) return;
      setState(() {
        _locationId = dpr.locationId;
        _date = parseApiDate(dpr.date) ?? today();
        _weather = dpr.weather ?? '';
        _summary = dpr.summary ?? '';
        _hindrances = dpr.hindrances ?? '';
        _work
          ..clear()
          ..addAll(dpr.workDone.map(_WorkRow.fromModel));
        _labour
          ..clear()
          ..addEntries(
            dpr.labour.map(
              (row) => MapEntry(Trade.parse(row.trade), row.count),
            ),
          );
        _equipment
          ..clear()
          ..addAll(dpr.equipment.map(_EquipmentRow.fromModel));
        _photos
          ..clear()
          ..addAll(dpr.photos);
        _notEditable = dpr.isDraft || dpr.isRejected ? null : dpr.status;
        _rejected = dpr.isRejected;
        _generation++;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnackBar(context, error);
    }
  }

  /// Fills work, labour, equipment and hindrances from the site's latest
  /// DPR (`GET /dprs/previous`). Weather, summary and photos stay empty.
  Future<void> _copyPrevious() async {
    final site = _locationId;
    if (site == null) return;
    setState(() => _busy = true);
    try {
      final previous = await ref
          .read(constructionRepositoryProvider)
          .previousDpr(site);
      if (!mounted) return;
      if (previous == null) {
        showInfoSnackBar(context, 'No earlier report for this site.');
        return;
      }
      setState(() {
        _work
          ..clear()
          ..addAll(previous.workDone.map(_WorkRow.fromModel));
        _labour
          ..clear()
          ..addEntries(
            previous.labour.map((r) => MapEntry(Trade.parse(r.trade), r.count)),
          );
        _equipment
          ..clear()
          ..addAll(previous.equipment.map(_EquipmentRow.fromModel));
        _hindrances = previous.hindrances ?? '';
        _generation++;
      });
      showSuccess(
        context,
        'Copied from the report of ${formatDate(previous.date)}',
      );
    } catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _attachPhoto({required bool camera}) async {
    final source = ref.read(photoSourceProvider);
    final unavailable = source.unavailableMessage;
    if (unavailable != null) {
      showInfoSnackBar(context, unavailable);
      return;
    }
    final picked = await source.pick(camera: camera);
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final file = await ref
          .read(constructionRepositoryProvider)
          .uploadPhoto(picked);
      if (!mounted) return;
      setState(() {
        _photos.add(DprPhoto(fileId: file.id));
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showErrorSnackBar(context, error);
    }
  }

  Future<void> _save({required bool submit}) async {
    if (!_formKey.currentState!.validate()) return;
    final location = _locationId;
    if (location == null) return;
    if (_date.isAfter(today())) {
      showInfoSnackBar(context, 'Date cannot be in the future.');
      return;
    }
    for (final row in _work) {
      final qty = row.qtyText.trim().isEmpty
          ? null
          : double.tryParse(row.qtyText);
      if (row.description.trim().isEmpty ||
          (row.qtyText.trim().isNotEmpty && (qty == null || qty <= 0))) {
        showInfoSnackBar(context, 'Check the work description and quantity.');
        return;
      }
    }
    for (final row in _equipment) {
      if (row.name.trim().isEmpty ||
          (double.tryParse(row.hoursText) ?? -1) < 0) {
        showInfoSnackBar(context, 'Check equipment names and hours.');
        return;
      }
    }
    setState(() => _busy = true);
    try {
      final draft = DprDraft(
        locationId: location,
        date: apiDate(_date),
        weather: _weather.trim().isEmpty ? null : _weather.trim(),
        summary: _summary.trim().isEmpty ? null : _summary.trim(),
        hindrances: _hindrances.trim().isEmpty ? null : _hindrances.trim(),
        workDone: [
          for (final row in _work)
            DprWork(
              boqLineId: row.boqLineId,
              description: row.description.trim(),
              qty: row.qtyText.trim().isEmpty
                  ? null
                  : double.parse(row.qtyText.trim()),
              unit: row.unit.trim().isEmpty ? null : row.unit.trim(),
            ),
        ],
        labour: [
          for (final entry in _labour.entries)
            if (entry.value > 0)
              DprLabour(trade: entry.key.api, count: entry.value),
        ],
        equipment: [
          for (final row in _equipment)
            DprEquipment(
              name: row.name.trim(),
              hours: double.parse(row.hoursText.trim()),
            ),
        ],
        photos: _photos,
        submit: submit,
      );
      final repo = ref.read(constructionRepositoryProvider);
      // One request: `submit` is part of the create / PATCH body, so a
      // failed submit never leaves a stray draft behind.
      final saved = _editing
          ? await repo.updateDpr(widget.dprId!, draft)
          : await repo.createDpr(draft);
      ref.bumpC(const [CKind.dprs]);
      if (!mounted) return;
      showSuccess(context, submit ? 'Report submitted' : 'Draft saved');
      context.go('/dprs/${saved.id}');
    } catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    if (_loading) return const LoadingView();
    if (_notEditable != null) {
      return EmptyView(
        icon: Icons.lock_outline,
        message:
            'This report is ${_notEditable!.label.toLowerCase()}; only drafts '
            'and rejected reports can be edited.',
        action: FilledButton(
          onPressed: () => leave('/dprs/${widget.dprId}'),
          child: const Text('Open the report'),
        ),
      );
    }
    return CGate(
      anyOf: const [CPerm.dprCreate, CPerm.dprApprove],
      child: Form(
        key: _formKey,
        onChanged: markDirty,
        child: BottomBarLayout(
          bar: Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                style: bigOutlinedButton,
                onPressed: _busy ? null : () => _save(submit: false),
                child: Text(_rejected ? 'Save changes' : 'Save draft'),
              ),
              FilledButton(
                style: bigButton,
                onPressed: _busy || !perms.can(CPerm.dprCreate)
                    ? null
                    : () => _save(submit: true),
                child: Text(_rejected ? 'Save & resubmit' : 'Save & submit'),
              ),
            ],
          ),
          child: KeyedSubtree(
            key: ValueKey(_generation),
            child: CPage(
              maxWidth: 900,
              children: [
                SectionCard(
                  title: 'Report',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FormRow(
                        children: [
                          SiteField(
                            value: _locationId,
                            onChanged: (value) =>
                                setState(() => _locationId = value),
                          ),
                          DateField(
                            label: 'Report date',
                            value: _date,
                            lastDate: today(),
                            onChanged: (value) => setState(() => _date = value),
                          ),
                        ],
                      ),
                      if (!_editing && _locationId != null) ...[
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            style: bigOutlinedButton,
                            onPressed: _busy ? null : _copyPrevious,
                            icon: const Icon(Icons.content_copy),
                            label: const Text('Copy yesterday'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SectionCard(
                  title: 'Progress',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Weather',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final key in {
                            ...weatherKeys,
                            if (_weather.trim().isNotEmpty) _weather.trim(),
                          })
                            ChoiceChip(
                              avatar: Icon(_weatherIcon(key), size: 18),
                              label: Text(weatherLabel(key)),
                              selected: _weather == key,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.padded,
                              onSelected: (on) =>
                                  setState(() => _weather = on ? key : ''),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: _summary,
                        minLines: 3,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          labelText: 'Summary',
                          alignLabelWithHint: true,
                        ),
                        onChanged: (value) => _summary = value,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: _hindrances,
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'Hindrances',
                          alignLabelWithHint: true,
                        ),
                        onChanged: (value) => _hindrances = value,
                      ),
                    ],
                  ),
                ),

                SectionCard(
                  title: 'Work done',
                  child: Column(
                    children: [
                      for (final row in _work) ...[
                        _WorkEditor(
                          row: row,
                          siteId: _locationId,
                          onChanged: () => setState(() {}),
                          onRemove: () => setState(() => _work.remove(row)),
                        ),
                        const SizedBox(height: 12),
                      ],
                      OutlinedButton.icon(
                        style: bigOutlinedButton,
                        onPressed: () => setState(() => _work.add(_WorkRow())),
                        icon: const Icon(Icons.add),
                        label: const Text('Add work item'),
                      ),
                    ],
                  ),
                ),
                SectionCard(
                  title: 'Labour by trade',
                  child: Column(
                    children: [
                      for (final trade in Trade.values)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(child: Text(trade.label)),
                              CountStepper(
                                value: (_labour[trade] ?? 0).toDouble(),
                                label: trade.label,
                                onChanged: (value) => setState(() {
                                  _labour[trade] = value.round();
                                }),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                SectionCard(
                  title: 'Equipment',
                  child: Column(
                    children: [
                      for (final row in _equipment) ...[
                        _EquipmentEditor(
                          row: row,
                          onChanged: () => setState(() {}),
                          onRemove: () =>
                              setState(() => _equipment.remove(row)),
                        ),
                        const SizedBox(height: 12),
                      ],
                      OutlinedButton.icon(
                        style: bigOutlinedButton,
                        onPressed: () =>
                            setState(() => _equipment.add(_EquipmentRow())),
                        icon: const Icon(Icons.add),
                        label: const Text('Add equipment'),
                      ),
                    ],
                  ),
                ),

                SectionCard(
                  title: 'Photos',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_photos.isEmpty) const Text('No photos attached.'),
                      if (_photos.isNotEmpty)
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final (index, photo) in _photos.indexed)
                              SizedBox(
                                width: 160,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Stack(
                                      children: [
                                        FileThumb(
                                          fileId: photo.fileId,
                                          size: 160,
                                          onTap: () => showPhotoViewer(
                                            context,
                                            _photos,
                                            index,
                                          ),
                                        ),
                                        Positioned(
                                          top: 0,
                                          right: 0,
                                          child: IconButton.filled(
                                            tooltip: 'Remove photo',
                                            onPressed: () => setState(() {
                                              _photos.removeAt(index);
                                            }),
                                            icon: const Icon(Icons.close),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    TextFormField(
                                      key: ValueKey('caption-${photo.fileId}'),
                                      initialValue: photo.caption,
                                      maxLength: 300,
                                      decoration: const InputDecoration(
                                        labelText: 'Caption',
                                        isDense: true,
                                        counterText: '',
                                      ),
                                      onChanged: (value) =>
                                          _photos[index] = DprPhoto(
                                            fileId: photo.fileId,
                                            caption: trimmedOrNull(value),
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            style: bigOutlinedButton,
                            onPressed: _busy
                                ? null
                                : () => _attachPhoto(camera: true),
                            icon: const Icon(Icons.photo_camera_outlined),
                            label: const Text('Camera'),
                          ),
                          OutlinedButton.icon(
                            style: bigOutlinedButton,
                            onPressed: _busy
                                ? null
                                : () => _attachPhoto(camera: false),
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('Gallery'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _weatherIcon(String key) => switch (key) {
  'sunny' => Icons.wb_sunny_outlined,
  'cloudy' => Icons.cloud_outlined,
  'rain' => Icons.water_drop_outlined,
  'hot' => Icons.thermostat,
  'cold' => Icons.ac_unit,
  _ => Icons.wb_cloudy_outlined,
};

class _WorkRow {
  _WorkRow({
    this.boqLineId,
    this.description = '',
    this.qtyText = '',
    this.unit = '',
  });

  factory _WorkRow.fromModel(DprWork work) => _WorkRow(
    boqLineId: work.boqLineId,
    description: work.description,
    qtyText: work.qty == null ? '' : formatPlain(work.qty),
    unit: work.unit ?? '',
  );

  String? boqLineId;
  BoqLine? boq;
  String description;
  String qtyText;
  String unit;
}

class _EquipmentRow {
  _EquipmentRow({this.name = '', this.hoursText = ''});

  factory _EquipmentRow.fromModel(DprEquipment equipment) => _EquipmentRow(
    name: equipment.name,
    hoursText: formatPlain(equipment.hours),
  );

  String name;
  String hoursText;
}

class _WorkEditor extends ConsumerWidget {
  const _WorkEditor({
    required this.row,
    required this.siteId,
    required this.onChanged,
    required this.onRemove,
  });

  final _WorkRow row;
  final String? siteId;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = siteId == null
        ? const <BoqLine>[]
        : ref.watch(boqForSiteProvider(siteId!)).value ?? const <BoqLine>[];
    BoqLine? linked = row.boq;
    for (final line in lines) {
      if (line.id == row.boqLineId) linked = line;
    }
    // Fields are rebuilt when the BOQ link changes so they show the
    // description and unit copied from the line.
    final fieldKey = '${identityHashCode(row)}-${row.boqLineId}';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: lines.isEmpty
                        ? null
                        : () async {
                            final picked = await pickBoqLine(
                              context,
                              ref,
                              lines: lines,
                            );
                            if (picked == null) return;
                            // Today's quantity is typed by the user; the
                            // BOQ line's total qty is not today's work.
                            row.boq = picked;
                            row.boqLineId = picked.id;
                            row.description = picked.description;
                            row.unit = picked.unit;
                            onChanged();
                          },
                    icon: const Icon(Icons.account_tree_outlined),
                    label: Text(
                      linked?.label ??
                          (row.boqLineId == null
                              ? 'Choose BOQ line (optional)'
                              : 'BOQ line linked'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (row.boqLineId != null)
                  IconButton(
                    tooltip: 'Unlink BOQ line',
                    constraints: BoxConstraints.tight(kTapTarget),
                    onPressed: () {
                      row.boq = null;
                      row.boqLineId = null;
                      onChanged();
                    },
                    icon: const Icon(Icons.link_off),
                  ),
                IconButton(
                  tooltip: 'Remove work item',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: ValueKey('$fieldKey-description'),
              initialValue: row.description,
              decoration: const InputDecoration(labelText: 'Description'),
              onChanged: (value) {
                row.description = value;
                onChanged();
              },
            ),
            const SizedBox(height: 10),
            FormRow(
              children: [
                TextFormField(
                  key: ValueKey('$fieldKey-qty'),
                  initialValue: row.qtyText,
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput(decimals: 3)],
                  decoration: const InputDecoration(labelText: 'Quantity'),
                  onChanged: (value) {
                    row.qtyText = value;
                    onChanged();
                  },
                ),
                TextFormField(
                  key: ValueKey('$fieldKey-unit'),
                  initialValue: row.unit,
                  decoration: const InputDecoration(labelText: 'Unit'),
                  onChanged: (value) {
                    row.unit = value;
                    onChanged();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EquipmentEditor extends StatelessWidget {
  const _EquipmentEditor({
    required this.row,
    required this.onChanged,
    required this.onRemove,
  });

  final _EquipmentRow row;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: TextFormField(
              initialValue: row.name,
              decoration: const InputDecoration(labelText: 'Equipment'),
              onChanged: (value) {
                row.name = value;
                onChanged();
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextFormField(
              initialValue: row.hoursText,
              keyboardType: decimalKeyboard,
              inputFormatters: [decimalInput(decimals: 2)],
              decoration: const InputDecoration(labelText: 'Hours'),
              onChanged: (value) {
                row.hoursText = value;
                onChanged();
              },
            ),
          ),
          IconButton(
            tooltip: 'Remove equipment',
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    ),
  );
}
