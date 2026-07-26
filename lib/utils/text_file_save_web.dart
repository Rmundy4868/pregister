// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html show AnchorElement, Blob, Url;

Future<String?> saveTextFile({
  required String content,
  required String fileName,
  String mimeType = 'text/plain',
  bool saveToDownloads = false,
}) async {
  final url = html.Url.createObjectUrl(html.Blob([content], mimeType));
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', fileName)
    ..click();
  html.Url.revokeObjectUrl(anchor.href ?? url);
  return fileName;
}
