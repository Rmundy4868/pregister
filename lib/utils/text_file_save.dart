import 'text_file_save_io.dart'
    if (dart.library.html) 'text_file_save_web.dart'
    as impl;

Future<String?> saveTextFile({
  required String content,
  required String fileName,
  String mimeType = 'text/plain',
  bool saveToDownloads = false,
}) {
  return impl.saveTextFile(
    content: content,
    fileName: fileName,
    mimeType: mimeType,
    saveToDownloads: saveToDownloads,
  );
}
