import 'package:image_picker/image_picker.dart';

import 'photo_source.dart';

/// DPR photos from the camera or gallery. Images are scaled down so a site
/// photo stays well under the 10 MB upload limit.
class ImagePickerPhotoSource extends PhotoSource {
  ImagePickerPhotoSource([ImagePicker? picker])
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<PickedPhoto?> pick({required bool camera}) async {
    final file = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 70,
    );
    if (file == null) return null;
    return PickedPhoto(
      name: file.name,
      mimeType: _mimeType(file),
      bytes: await file.readAsBytes(),
    );
  }

  @override
  bool get supportsCamera => _picker.supportsImageSource(ImageSource.camera);

  /// `POST /files` accepts JPEG, PNG and WebP; re-encoded picks are JPEG.
  static String _mimeType(XFile file) {
    final type = file.mimeType;
    if (type != null && type.startsWith('image/')) return type;
    final name = file.name.toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }
}
