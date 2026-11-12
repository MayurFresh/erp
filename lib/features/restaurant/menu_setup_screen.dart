import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/search_field.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton;
import 'rest_models.dart';
import 'rest_perms.dart';
import 'rest_repository.dart';
import 'rest_widgets.dart';
import 'setup_widgets.dart';

/// `/restaurant/menu`: categories and menu entries, with today's availability.
class MenuSetupScreen extends ConsumerStatefulWidget {
  const MenuSetupScreen({super.key});

  @override
  ConsumerState<MenuSetupScreen> createState() => _MenuSetupScreenState();
}

class _MenuSetupScreenState extends ConsumerState<MenuSetupScreen> {
  String _query = '';
  final _busy = <String>{};

  Future<void> _edit([MenuEntry? entry]) async {
    final saved = await showFormDialog<bool>(
      context: context,
      builder: (_) => _MenuEntryDialog(entry: entry),
    );
    if (saved == true) ref.bumpRest();
  }

  Future<void> _categories() async {
    await showFormDialog<void>(
      context: context,
      builder: (_) => const _CategoriesDialog(),
    );
    ref.bumpRest();
  }

  Future<void> _toggle(MenuEntry e, bool on) async {
    if (!_busy.add(e.itemId)) return;
    final ok = await restGuarded(
      context,
      () => ref.read(restaurantRepositoryProvider).saveMenuEntry(e.itemId, {
        'available': on,
      }),
    );
    _busy.remove(e.itemId);
    if (ok) ref.bumpRest();
  }

  Future<void> _remove(MenuEntry e) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${e.name} from the menu?'),
        content: const Text(
          'The item stays in Items; it just stops showing on the order screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final ok = await restGuarded(
      context,
      () => ref.read(restaurantRepositoryProvider).deleteMenuEntry(e.itemId),
    );
    if (ok) ref.bumpRest();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    return CGate(
      anyOf: const [RestPerm.manage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Menu',
            actions: [
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: _categories,
                icon: const Icon(Icons.category_outlined),
                label: const Text('Categories'),
              ),
              FilledButton.icon(
                style: bigButton,
                onPressed: () => _edit(),
                icon: const Icon(Icons.add),
                label: const Text('Add menu item'),
              ),
            ],
          ),
          FilterBar(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: SearchField(
                  onChanged: (q) =>
                      setState(() => _query = q.trim().toLowerCase()),
                ),
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(restMenuProvider),
              onRetry: () => ref.invalidate(restMenuProvider),
              data: (all) {
                final shown = [
                  for (final e in all)
                    if (_query.isEmpty || e.name.toLowerCase().contains(_query))
                      e,
                ];
                if (shown.isEmpty) {
                  return const EmptyView(
                    icon: Icons.restaurant_menu,
                    message: 'No menu items yet. Add the first one.',
                  );
                }
                final groups = <String, List<MenuEntry>>{};
                for (final e in shown) {
                  (groups[e.categoryName ?? 'No category'] ??= []).add(e);
                }
                return ListView(
                  padding: EdgeInsets.all(pageGutter(context)),
                  children: [
                    for (final g in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.only(
                          top: Space.sm,
                          bottom: Space.xs,
                        ),
                        child: Text(g.key, style: theme.textTheme.titleMedium),
                      ),
                      for (final e in g.value)
                        Container(
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: colors.hairline),
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                            vertical: Space.xs,
                          ),
                          child: Row(
                            children: [
                              DietMark(e.diet),
                              const SizedBox(width: Space.md),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      e.name,
                                      style: theme.textTheme.bodyLarge,
                                    ),
                                    Text(
                                      '${formatMoney(e.price)} · GST ${formatPlain(e.gstRate)}% · ${e.station}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              Tooltip(
                                message: 'Available today',
                                child: Switch(
                                  value: e.availableToday,
                                  onChanged: (v) => _toggle(e, v),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Edit',
                                onPressed: () => _edit(e),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: 'Remove from menu',
                                onPressed: () => _remove(e),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------- entries

class _ItemChoice {
  const _ItemChoice(this.id, this.name);

  final String id;
  final String name;
}

class _MenuEntryDialog extends ConsumerStatefulWidget {
  const _MenuEntryDialog({this.entry});

  final MenuEntry? entry;

  @override
  ConsumerState<_MenuEntryDialog> createState() => _MenuEntryDialogState();
}

class _MenuEntryDialogState extends ConsumerState<_MenuEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController();
  late final _price = TextEditingController();
  late final _gst = TextEditingController(text: '5');
  late final _short = TextEditingController(
    text: widget.entry?.shortName ?? '',
  );
  late final _station = TextEditingController(
    text: widget.entry?.station ?? 'Main',
  );
  late Diet _diet = widget.entry?.diet ?? Diet.veg;
  late String? _categoryId = widget.entry?.categoryId;
  late bool _available = widget.entry?.availableToday ?? true;
  bool _existing = false;
  _ItemChoice? _item;

  bool get _editing => widget.entry != null;

  @override
  void dispose() {
    for (final c in [_name, _price, _gst, _short, _station]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickItem() async {
    final api = ref.read(apiClientProvider);
    final picked = await showSearchPicker<Json>(
      context: context,
      title: 'Choose an item',
      search: (q) async {
        final page = await api.getJson('/items', query: {'q': q, 'limit': 30});
        return asJsonList(page['data']);
      },
      titleBuilder: (_, j) => Text(asString(j['name'])),
      subtitleBuilder: (_, j) => Text(formatMoney(asDouble(j['salePrice']))),
    );
    if (picked != null) {
      setState(
        () => _item = _ItemChoice(
          asString(picked['id']),
          asString(picked['name']),
        ),
      );
    }
  }

  Future<void> _save() async {
    final repo = ref.read(restaurantRepositoryProvider);
    final common = {
      'categoryId': _categoryId,
      'diet': _diet.wire,
      'available': _available,
      'station': _station.text.trim(),
      'shortName': trimmedOrNull(_short.text),
    };
    if (_editing) {
      await repo.saveMenuEntry(widget.entry!.itemId, common);
    } else if (_existing) {
      await repo.createMenuEntry({'itemId': _item!.id, ...common});
    } else {
      await repo.createMenuEntry({
        'newItem': {
          'name': _name.text.trim(),
          'salePrice': parseNumber(_price.text.trim()),
          'gstRate': parseNumber(_gst.text.trim()) ?? 5,
        },
        ...common,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories =
        ref.watch(restCategoriesProvider).value ?? const <MenuCategory>[];
    final stations =
        ref.watch(restSettingsProvider).value?.stations ?? const ['Main'];
    return EditDialog(
      title: _editing ? 'Edit ${widget.entry!.name}' : 'Add menu item',
      formKey: _formKey,
      onSave: _save,
      children: [
        if (_editing)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: Text(
              'Name, price and GST rate are changed in Items.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else ...[
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('New dish')),
              ButtonSegment(value: true, label: Text('Existing item')),
            ],
            selected: {_existing},
            onSelectionChanged: (s) => setState(() => _existing = s.first),
          ),
          const SizedBox(height: Space.md),
          if (_existing)
            PickerField(
              label: 'Item',
              value: _item?.name,
              onTap: _pickItem,
              validator: () => _item == null ? 'Choose an item' : null,
            )
          else ...[
            TextFormField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (v) => requiredField(v, 'Name'),
            ),
            const SizedBox(height: Space.md),
            FieldPair(
              TextFormField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Price',
                  prefixText: '$moneySymbol ',
                ),
                validator: (v) => requiredNumber(v, label: 'Price', min: 0),
              ),
              TextFormField(
                controller: _gst,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'GST %',
                  helperText: 'Usually 5',
                ),
                validator: (v) =>
                    requiredNumber(v, label: 'GST', min: 0, max: 28),
              ),
            ),
          ],
          const SizedBox(height: Space.md),
        ],
        DropdownButtonFormField<String?>(
          initialValue: categories.any((c) => c.id == _categoryId)
              ? _categoryId
              : null,
          decoration: const InputDecoration(labelText: 'Category'),
          items: [
            const DropdownMenuItem(value: null, child: Text('No category')),
            for (final c in categories)
              DropdownMenuItem(value: c.id, child: Text(c.name)),
          ],
          onChanged: (v) => _categoryId = v,
        ),
        const SizedBox(height: Space.md),
        SegmentedButton<Diet>(
          showSelectedIcon: false,
          segments: [
            for (final d in Diet.values)
              ButtonSegment(
                value: d,
                label: Text(d.label),
                icon: DietMark(d, size: 14),
              ),
          ],
          selected: {_diet},
          onSelectionChanged: (s) => setState(() => _diet = s.first),
        ),
        const SizedBox(height: Space.md),
        TextFormField(
          controller: _station,
          decoration: const InputDecoration(labelText: 'Kitchen station'),
          inputFormatters: [LengthLimitingTextInputFormatter(40)],
          validator: (v) => requiredField(v, 'Station'),
        ),
        Wrap(
          spacing: Space.sm,
          children: [
            for (final s in {...stations, 'Main', 'Tandoor', 'Bar'})
              ActionChip(
                label: Text(s),
                onPressed: () => setState(() => _station.text = s),
              ),
          ],
        ),
        const SizedBox(height: Space.md),
        TextFormField(
          controller: _short,
          decoration: const InputDecoration(
            labelText: 'Short name on the KOT (optional)',
          ),
          inputFormatters: [LengthLimitingTextInputFormatter(40)],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _available,
          onChanged: (v) => setState(() => _available = v),
          title: const Text('Available today'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- categories

class _CategoriesDialog extends ConsumerWidget {
  const _CategoriesDialog();

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, [
    MenuCategory? c,
  ]) async {
    final saved = await showFormDialog<bool>(
      context: context,
      builder: (_) => _CategoryDialog(category: c),
    );
    if (saved == true) ref.bumpRest();
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    MenuCategory c,
  ) async {
    final ok = await restGuarded(
      context,
      () => ref.read(restaurantRepositoryProvider).deleteCategory(c.id),
    );
    if (ok) ref.bumpRest();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => AlertDialog(
    title: const Text('Menu categories'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: AsyncValueView(
        value: ref.watch(restCategoriesProvider),
        onRetry: () => ref.invalidate(restCategoriesProvider),
        data: (cats) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (cats.isEmpty) const Text('No categories yet.'),
            for (final c in cats)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(c.name),
                subtitle: Text('Order ${c.sortOrder}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Edit',
                      onPressed: () => _edit(context, ref, c),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      onPressed: () => _delete(context, ref, c),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: Space.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => _edit(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('Add category'),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Done'),
      ),
    ],
  );
}

class _CategoryDialog extends ConsumerStatefulWidget {
  const _CategoryDialog({this.category});

  final MenuCategory? category;

  @override
  ConsumerState<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends ConsumerState<_CategoryDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.category?.name ?? '');
  late final _sort = TextEditingController(
    text: '${widget.category?.sortOrder ?? 0}',
  );

  @override
  void dispose() {
    _name.dispose();
    _sort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EditDialog(
    title: widget.category == null ? 'Add category' : 'Edit category',
    formKey: _formKey,
    onSave: () => ref
        .read(restaurantRepositoryProvider)
        .saveCategory(
          id: widget.category?.id,
          body: {
            'name': _name.text.trim(),
            'sortOrder': int.tryParse(_sort.text.trim()) ?? 0,
          },
        ),
    children: [
      TextFormField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        validator: (v) => requiredField(v, 'Name'),
      ),
      const SizedBox(height: Space.md),
      TextFormField(
        controller: _sort,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(
          labelText: 'Position in the menu',
          helperText: 'Smaller numbers come first',
        ),
      ),
    ],
  );
}
