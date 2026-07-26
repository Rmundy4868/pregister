import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

class ReceiptPreviewSection extends StatelessWidget {
  const ReceiptPreviewSection({
    super.key,
    required this.title,
    required this.pdfBuilder,
    this.receiptFormat = const PdfPageFormat(
      3.25 * PdfPageFormat.inch,
      11 * PdfPageFormat.inch,
      marginLeft: 0,
      marginRight: 0,
      marginTop: 0,
      marginBottom: 0,
    ),
    this.previewHeight = 360,
    this.previewWidth = 396,
  });

  final String title;
  final Future<List<int>> Function(PdfPageFormat) pdfBuilder;
  final PdfPageFormat receiptFormat;
  final double previewHeight;
  final double previewWidth;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SizedBox(
          height: previewHeight,
          width: previewWidth,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: PdfPreview(
              canChangePageFormat: false,
              canChangeOrientation: false,
              canDebug: false,
              maxPageWidth: 320,
              initialPageFormat: receiptFormat,
              build: (format) async {
                final bytes = await pdfBuilder(format);
                return Uint8List.fromList(bytes);
              },
            ),
          ),
        ),
      ],
    );
  }
}
