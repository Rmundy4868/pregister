import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

Future<String?> saveTextFile({
  required String content,
  required String fileName,
  String mimeType = 'text/plain',
  bool saveToDownloads = false,
}) async {
  if (saveToDownloads) {
    final downloadsDir = _downloadsDirectoryPath();
    if (downloadsDir == null || downloadsDir.isEmpty) {
      throw StateError('Could not resolve Downloads folder.');
    }

    final directory = Directory(downloadsDir);
    if (!await directory.exists()) {
      throw FileSystemException(
        'Downloads folder does not exist',
        directory.path,
      );
    }

    final targetPath = await _nextAvailablePath(
      directoryPath: directory.path,
      requestedFileName: fileName,
    );
    await File(targetPath).writeAsString(content, encoding: utf8);
    return targetPath;
  }

  final saveLocation = await getSaveLocation(suggestedName: fileName);
  if (saveLocation == null) {
    return null;
  }

  final file = XFile.fromData(
    utf8.encode(content),
    mimeType: mimeType,
    name: fileName,
  );
  await file.saveTo(saveLocation.path);
  return saveLocation.path;
}

String? _downloadsDirectoryPath() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final userProfile = env['USERPROFILE']?.trim() ?? '';
    if (userProfile.isNotEmpty) {
      return '$userProfile\\Downloads';
    }
    return null;
  }

  final home = env['HOME']?.trim() ?? '';
  if (home.isNotEmpty) {
    return '$home/Downloads';
  }
  return null;
}

Future<String> _nextAvailablePath({
  required String directoryPath,
  required String requestedFileName,
}) async {
  final dotIndex = requestedFileName.lastIndexOf('.');
  final hasExtension = dotIndex > 0 && dotIndex < requestedFileName.length - 1;
  final base = hasExtension
      ? requestedFileName.substring(0, dotIndex)
      : requestedFileName;
  final ext = hasExtension ? requestedFileName.substring(dotIndex) : '';

  var attempt = 0;
  while (true) {
    final candidateName = attempt == 0 ? '$base$ext' : '$base ($attempt)$ext';
    final separator = Platform.isWindows ? '\\' : '/';
    final candidatePath = '$directoryPath$separator$candidateName';
    if (!await File(candidatePath).exists()) {
      return candidatePath;
    }
    attempt += 1;
  }
}
