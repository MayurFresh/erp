import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A photo taken with the camera or chosen from the gallery.
class PickedPhoto {
  const PickedPhoto({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  /// File name sent with the upload, e.g. `IMG_0042.jpg`.
  final String name;

  /// `image/jpeg`, `image/png` or `image/webp` (what `POST /files` accepts).
  final String mimeType;
  final Uint8List bytes;
}

/// Where DPR photos come from. Extend this class (rather than implementing
/// it) to inherit [unavailableMessage].
///
/// To enable photos, override [photoSourceProvider] with an implementation
/// backed by `image_picker`, e.g.
///
/// ```dart
/// class ImagePickerPhotoSource extends PhotoSource {
///   @override
///   Future<PickedPhoto?> pick({required bool camera}) async {
///     final file = await ImagePicker().pickImage(
///       source: camera ? ImageSource.camera : ImageSource.gallery,
///       maxWidth: 1600,
///       imageQuality: 70,
///     );
///     if (file == null) return null;
///     return PickedPhoto(
///       name: file.name,
///       mimeType: file.mimeType ?? 'image/jpeg',
///       bytes: await file.readAsBytes(),
///     );
///   }
/// }
/// ```
abstract class PhotoSource {
  const PhotoSource();

  /// Takes ([camera]) or chooses a photo; `null` when the user cancels.
  Future<PickedPhoto?> pick({required bool camera});

  /// When non-null, photo buttons show this message instead of picking.
  String? get unavailableMessage => null;

  /// Whether the device can take photos (hides the camera button if not).
  bool get supportsCamera => true;
}

/// Default until a picker plugin is added: every pick returns `null`.
class UnavailablePhotoSource extends PhotoSource {
  const UnavailablePhotoSource();

  static const message = 'Photo capture will be enabled soon.';

  @override
  Future<PickedPhoto?> pick({required bool camera}) async => null;

  @override
  String? get unavailableMessage => message;
}

final photoSourceProvider = Provider<PhotoSource>(
  (ref) => const UnavailablePhotoSource(),
);
