import 'package:flutter/material.dart';

import 'business_models.dart';

/// A searchable grid of business types, grouped, with icons.
class BusinessTypePicker extends StatefulWidget {
  const BusinessTypePicker({
    super.key,
    required this.catalogue,
    required this.selected,
    required this.onSelected,
  });

  final BusinessCatalogue catalogue;
  final String? selected;
  final ValueChanged<BusinessTypeDef> onSelected;

  @override
  State<BusinessTypePicker> createState() => _BusinessTypePickerState();
}

class _BusinessTypePickerState extends State<BusinessTypePicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final types = [
      for (final t in widget.catalogue.types)
        if (q.isEmpty ||
            t.name.toLowerCase().contains(q) ||
            t.description.toLowerCase().contains(q))
          t,
    ];
    final groups = [
      ...widget.catalogue.groups,
      const BusinessGroupDef('general', 'Other'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          decoration: const InputDecoration(
            labelText: 'Search your kind of business',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (v) => setState(() => _q = v),
        ),
        const SizedBox(height: 12),
        if (types.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Nothing matches. Try another word or pick General.'),
          ),
        for (final g in groups)
          ..._group(context, g, [
            for (final t in types)
              if (t.group == g.id) t,
          ]),
      ],
    );
  }

  List<Widget> _group(
    BuildContext context,
    BusinessGroupDef group,
    List<BusinessTypeDef> items,
  ) {
    if (items.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 6),
        child: Text(group.name, style: Theme.of(context).textTheme.titleSmall),
      ),
      LayoutBuilder(
        builder: (context, box) {
          final cols = (box.maxWidth / 150).floor().clamp(1, 6);
          final width = (box.maxWidth - (cols - 1) * 8) / cols;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in items)
                SizedBox(
                  width: width,
                  child: _TypeTile(
                    type: t,
                    selected: t.id == widget.selected,
                    onTap: () => widget.onSelected(t),
                  ),
                ),
            ],
          );
        },
      ),
    ];
  }
}

class _TypeTile extends StatelessWidget {
  const _TypeTile({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final BusinessTypeDef type;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: type.name,
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  typeIcon(type.icon),
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 6),
                Text(
                  type.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
