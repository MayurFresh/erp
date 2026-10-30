import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/construction_repository.dart';
import '../models/dpr_models.dart';

/// A photo from `GET /files/:id`, fetched with the auth header and shown
/// with [Image.memory]. Square; [onTap] opens it larger.
class FileThumb extends ConsumerWidget {
  const FileThumb({
    super.key,
    required this.fileId,
    this.size = 96,
    this.onTap,
    this.fit = BoxFit.cover,
  });

  final String fileId;

  /// `null` fills the parent.
  final double? size;
  final VoidCallback? onTap;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = ref.watch(fileBytesProvider(fileId));
    Widget placeholder(IconData icon) =>
        Center(child: Icon(icon, color: scheme.onSurfaceVariant, size: 32));
    final child = switch (bytes) {
      AsyncValue(:final value?) when value.isNotEmpty => Image.memory(
        value,
        fit: fit,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder(Icons.broken_image_outlined),
      ),
      AsyncValue(hasError: true) => Tooltip(
        message: 'Could not load the photo. Tap to retry.',
        child: InkWell(
          onTap: () => ref.invalidate(fileBytesProvider(fileId)),
          child: placeholder(Icons.refresh),
        ),
      ),
      AsyncValue(hasValue: true) => placeholder(Icons.image_not_supported),
      _ => const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    };
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: child),
      ),
    );
  }
}

/// Full-screen photo viewer with captions; swipe between photos.
Future<void> showPhotoViewer(
  BuildContext context,
  List<DprPhoto> photos,
  int initialIndex,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: _PhotoViewer(photos: photos, initialIndex: initialIndex),
    ),
  );
}

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({required this.photos, required this.initialIndex});

  final List<DprPhoto> photos;
  final int initialIndex;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Photo ${_index + 1} of ${widget.photos.length}'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pages,
              onPageChanged: (i) => setState(() => _index = i),
              children: [
                for (final p in widget.photos)
                  InteractiveViewer(
                    child: FileThumb(
                      fileId: p.fileId,
                      size: null,
                      fit: BoxFit.contain,
                    ),
                  ),
              ],
            ),
          ),
          if (photo.caption != null && photo.caption!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                photo.caption!,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
        ],
      ),
    );
  }
}
