import 'dart:convert';
import 'dart:typed_data';

import 'package:printing/printing.dart';

/// Saves [bytes] as a file called [filename]: a download on the web, the
/// share sheet (save or send) on Android. Used for CSV, text and JSON files.
Future<void> saveBytesFile(String filename, Uint8List bytes) =>
    Printing.sharePdf(bytes: bytes, filename: filename);

/// Saves [text] as a UTF-8 file called [filename].
Future<void> saveTextFile(String filename, String text) =>
    saveBytesFile(filename, Uint8List.fromList(utf8.encode(text)));
