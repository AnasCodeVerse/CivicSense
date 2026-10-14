// CivicSense – on-device image classifier
//
// Runs our TensorFlow Lite model (MobileNetV2-based) directly on the phone,
// so residents get a category suggestion even with no internet.
// The model knows three classes:
//   pothole, garbage  -> real issues, suggested as the report category
//   normal            -> no civic issue in the photo, so the report is not filed
//
// Excerpt from the CivicSense Flutter app. Full source available on request.

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class ClassifierService {
  Interpreter? _interpreter;
  List<String> _labels = [];
  static const int _inputSize = 224;
  bool _labelsLoaded = false;

  ClassifierService() {
    _loadModel();
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/model.tflite');
    } catch (e) {
      // Model failed to load. classifyImage() returns 'unavailable' and the
      // resident simply picks the category by hand.
      debugPrint('Model load failed: $e');
    }

    try {
      final labelsData = await rootBundle.loadString('assets/labels.txt');
      _labels = labelsData
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      _labelsLoaded = true;
    } catch (e) {
      debugPrint('Labels file not found, using defaults: $e');
    }

    if (!_labelsLoaded) {
      _labels = ['garbage', 'normal', 'pothole'];
    }
  }

  Future<Map<String, dynamic>> classifyImage(File imageFile) async {
    if (_interpreter == null) {
      await _loadModel();
    }
    if (_interpreter == null) {
      // Distinct sentinel — 'unavailable' is not a real class. The report
      // screen recognizes this and treats it as "AI ran but failed",
      // showing the uncertain badge so the user knows to pick manually,
      // rather than silently falling through as if the photo was 'normal'.
      return {'label': 'unavailable', 'confidence': 0.0};
    }

    try {
      final bytes = await imageFile.readAsBytes();
      final rawImage = img.decodeImage(Uint8List.fromList(bytes));
      if (rawImage == null) {
        return {'label': 'unavailable', 'confidence': 0.0};
      }

      final resized = img.copyResize(rawImage, width: _inputSize, height: _inputSize);

      // Build input tensor with [-1, 1] normalization (MobileNetV2 standard)
      final input = List.generate(
        1,
        (_) => List.generate(
          _inputSize,
          (y) => List.generate(
            _inputSize,
            (x) {
              final pixel = resized.getPixel(x, y);
              return [
                (pixel.r / 127.5) - 1.0,
                (pixel.g / 127.5) - 1.0,
                (pixel.b / 127.5) - 1.0,
              ];
            },
          ),
        ),
      );

      final outputSize = _labels.isNotEmpty ? _labels.length : 3;
      final output = List.filled(outputSize, 0.0).reshape([1, outputSize]);
      _interpreter!.run(input, output);

      final scores = List<double>.from(output[0] as List);

      // Find max
      double maxScore = scores[0];
      int maxIdx = 0;
      for (int i = 1; i < scores.length; i++) {
        if (scores[i] > maxScore) {
          maxScore = scores[i];
          maxIdx = i;
        }
      }

      final label = _labels.isNotEmpty && maxIdx < _labels.length
          ? _labels[maxIdx].toLowerCase()
          : ['garbage', 'normal', 'pothole'][maxIdx.clamp(0, 2)];

      return {'label': label, 'confidence': maxScore};
    } catch (e) {
      debugPrint('Classification error: $e');
      return {'label': 'unavailable', 'confidence': 0.0};
    }
  }

  void dispose() {
    _interpreter?.close();
  }
}
