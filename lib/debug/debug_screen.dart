import 'package:flutter/material.dart';
import 'dart:io';

class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  String _fileContent = 'Select a file to view...';
  String _selectedFile = 'CMakeLists.txt';
  bool _isLoading = false;

  final List<String> _availableFiles = [
    'CMakeLists.txt',
    'main.cpp',
    'flutter_window.h',
    'flutter_window.cpp',
  ];

  Future<void> _loadFile(String fileName) async {
    setState(() => _isLoading = true);
    try {
      String path = '';
      if (fileName == 'CMakeLists.txt') {
        path = 'windows/flutter/CMakeLists.txt';
      } else if (fileName == 'main.cpp') {
        path = 'windows/runner/main.cpp';
      } else if (fileName == 'flutter_window.h') {
        path = 'windows/runner/flutter_window.h';
      } else if (fileName == 'flutter_window.cpp') {
        path = 'windows/runner/flutter_window.cpp';
      }

      final file = File(path);
      String content;
      if (await file.exists()) {
        content = await file.readAsString();
      } else {
        content = 'File not found: $path\n\nMake sure you run this from the project root directory.';
      }

      setState(() {
        _fileContent = content;
        _selectedFile = fileName;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _fileContent = 'Error loading file: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Debug - Windows Source Files')),
      body: Row(
        children: [
          Container(
            width: 200,
            color: Colors.grey[200],
            child: ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Text(
                    'Files',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ..._availableFiles.map((file) {
                  final isSelected = file == _selectedFile;
                  return ListTile(
                    title: Text(file),
                    selected: isSelected,
                    tileColor: isSelected ? Colors.blue[100] : null,
                    onTap: () => _loadFile(file),
                  );
                }),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: SelectableText(
                        _fileContent,
                        style: const TextStyle(
                          fontFamily: 'Courier New',
                          fontSize: 11,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
