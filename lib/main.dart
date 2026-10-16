import 'barcode_scanner_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:vibration/vibration.dart';

void main() => runApp(const PackSureApp());

class PackSureApp extends StatelessWidget {
  const PackSureApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PackSureAI',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF145DA0)), useMaterial3: true),
    home: const PackSureHome(),
  );
}

class ScanResult {
  final String rawText, productName, mrp, quantity, manufacturer, dateInfo;
  final List<String> found, missing;
  const ScanResult({required this.rawText, required this.productName, required this.mrp,
    required this.quantity, required this.manufacturer, required this.dateInfo,
    required this.found, required this.missing});
  String get spoken {
    final missingText = missing.isEmpty ? 'No basic screening fields were missing from the OCR result.' : 'Not detected: ${missing.join(", ")}.';
    return 'Scan completed. Product name: $productName. '
      'Maximum retail price: ${mrp.isEmpty ? "not detected" : mrp}. '
      'Quantity: ${quantity.isEmpty ? "not detected" : quantity}. '
      'Manufacturer information: ${manufacturer.isEmpty ? "not detected" : manufacturer}. '
      'Date information: ${dateInfo.isEmpty ? "not detected" : dateInfo}. $missingText '
      'This is a basic text screening only. It is not an official legal compliance decision and does not prove that food is safe to eat.';
  }
}

class PackSureHome extends StatefulWidget {
  const PackSureHome({super.key});
  @override
  State<PackSureHome> createState() => _PackSureHomeState();
}

class _PackSureHomeState extends State<PackSureHome> {
  final _tts = FlutterTts();
  OnDeviceTranslator? _translator;
  final _picker = ImagePicker();
  final _speech = stt.SpeechToText();
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  bool _busy = false,
      _ttsOn = true,
      _voiceOn = true,
      _speechReady = false,
      _isSpeaking = false;
  String _language = 'English',
      _locale = 'en-US',
      _status = 'Ready to scan a packaged product.';
  ScanResult? _result;
  String _lastSpokenText = '';
  final List<ScanResult> _history = [];

  @override
  void initState() {
    super.initState();
    _tts.setStartHandler(() {
      if (mounted) {
        setState(() => _isSpeaking = true);
      }
    });

    _tts.setCompletionHandler(() {
      if (mounted) {
        setState(() => _isSpeaking = false);
      }
    });

    _tts.setCancelHandler(() {
      if (mounted) {
        setState(() => _isSpeaking = false);
      }
    });
    _loadPrefs();
    _initSpeech();
    _configureTts();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    _language = p.getString('language') ?? 'English';
    _locale = p.getString('locale') ?? 'en-US';
    _ttsOn = p.getBool('tts') ?? true;
    _voiceOn = p.getBool('voice') ?? true;
    if (mounted) setState(() {});
    await _configureTts();
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('language', _language);
    await p.setString('locale', _locale);
    await p.setBool('tts', _ttsOn);
    await p.setBool('voice', _voiceOn);
  }

  Future<void> _configureTts() async {
    await _tts.setLanguage(_locale);
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
  }

  Future<void> _say(String text) async {
    if (!_ttsOn) return;

    await _tts.stop();

    _lastSpokenText = text;

    if (mounted) {
      setState(() => _isSpeaking = false);
    }

    try {
      String translatedText = text;

      if (_language != 'English') {
        final targetLanguage = _language == 'Bengali'
            ? TranslateLanguage.bengali
            : TranslateLanguage.hindi;

        await _translator?.close();

        _translator = OnDeviceTranslator(
          sourceLanguage: TranslateLanguage.english,
          targetLanguage: targetLanguage,
        );

        translatedText = await _translator!.translateText(text);
      }

      await _configureTts();

      await _tts.speak(translatedText);
    } catch (e) {
      await _tts.speak(text);
    }
  }

  Future<void> _stopTalking() async {
    await _tts.stop();

    if (mounted) {
      setState(() => _isSpeaking = false);
    }
  }

  Future<void> _toggleTalking() async {
    if (_isSpeaking) {
      await _stopTalking();
    } else if (_result != null) {
      await _say(_result!.spoken);
    } else if (_lastSpokenText.isNotEmpty) {
      await _say(_lastSpokenText);
    } else {
      await _say('Ready to scan a packaged product.');
    }
  }


  Future<void> _initSpeech() async {
    try {
      final ok = await _speech.initialize(onError: (e) {
        if (mounted) setState(() => _status = 'Voice recognition: ${e.errorMsg}');
      });
      if (mounted) setState(() => _speechReady = ok);
    } catch (_) {
      if (mounted) setState(() => _speechReady = false);
    }
  }

  Future<void> _buzz([int ms = 150]) async {
    try {
      if (await Vibration.hasVibrator()) {
        await Vibration.vibrate(duration: ms);
      } else {
        await SystemSound.play(SystemSoundType.alert);
      }
    } catch (_) {
      await SystemSound.play(SystemSoundType.alert);
    }
  }

  Future<void> _setLanguage(String v) async {
    setState(() {
      _language = v;
      _locale = v == 'Bengali' ? 'bn-IN' : v == 'Hindi' ? 'hi-IN' : 'en-US';
    });
    await _savePrefs();
    await _configureTts();
    await _say('$v selected. PackSureAI is ready.');
  }

  Future<void> _scan(ImageSource source) async {
    if (_busy) return;
    setState(() { _busy = true; _status = 'Opening camera or image picker.'; _result = null; });
    await _say('Take a clear photo of the product label. Keep the text inside the photo.');
    try {
      final file = await _picker.pickImage(source: source, imageQuality: 90, maxWidth: 2200);
      if (file == null) {
        setState(() { _busy = false; _status = 'Scan cancelled. You can try again.'; });
        await _say('Scan cancelled.');
        return;
      }
      setState(() => _status = 'Reading label text. Please wait.');
      await _say('Image captured. Reading label text. Please wait.');
      final ocr = await _recognizer.processImage(InputImage.fromFilePath(file.path));
      if (ocr.text.trim().isEmpty) {
        setState(() { _busy = false; _status = 'No readable text. Try brighter light and a closer, steady photo.'; });
        await _say('No readable text detected. Use brighter light and take a closer, steady photo.');
        await _buzz(450);
        return;
      }
      final result = _analyse(ocr.text);
      setState(() {
        _result = result;
        _history.insert(0, result);
        _busy = false;
        _status = 'Analysis completed. Review the detected fields and warnings.';
      });
      await _buzz();
      await _say(result.spoken);
    } catch (_) {
      setState(() { _busy = false; _status = 'Could not scan this image. Check permissions and try again.'; });
      await _say('Could not scan this image. Check camera permission and try again.');
    }
  }

  ScanResult _analyse(String text) {
    final lines = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final mrp = RegExp(r'(?:MRP|M\.R\.P\.|MAXIMUM RETAIL PRICE|RETAIL PRICE)\s*[:\-]?\s*(?:RS\.?|₹|INR)?\s*[\d,]+(?:\.\d{1,2})?', caseSensitive: false).firstMatch(text);
    final qty = RegExp(r'\b(?:NET\s*(?:QUANTITY|QTY|WT|WEIGHT)|QUANTITY|NET CONTENTS?)\s*[:\-]?\s*\d+(?:\.\d+)?\s*(?:KG|G|GM|GRAMS?|MG|ML|LIT(?:RE|ER)S?|PCS?|PIECES?)\b|\b\d+(?:\.\d+)?\s*(?:KG|G|GM|GRAMS?|MG|ML|LIT(?:RE|ER)S?|PCS?|PIECES?)\b', caseSensitive: false).firstMatch(text);
    final man = RegExp(r'(?:MANUFACTURED BY|MANUFACTURER|MFG\.?\s*BY|PACKED BY|PACKER|MARKETED BY)', caseSensitive: false).firstMatch(text);
    final date = RegExp(r'(?:MFG\.?\s*DATE|MANUFACTURING DATE|PACKED ON|PKD\.?\s*ON|BEST BEFORE|USE BY|EXP(?:IRY)?\.?\s*DATE|DATE OF EXPIRY)', caseSensitive: false).firstMatch(text);
    String name = 'Not confidently detected';
    for (final line in lines.take(5)) {
      final u = line.toUpperCase();
      if (line.length >= 3 && !['MRP', 'PRICE', 'MANUFACT', 'PACKED', 'NET QUANTITY', 'INGREDIENT'].any(u.contains)) {
        name = line; break;
      }
    }
    final found = <String>[], missing = <String>[];
    void check(bool yes, String label) { (yes ? found : missing).add(label); }
    check(mrp != null, 'MRP / retail price');
    check(qty != null, 'Quantity');
    check(man != null, 'Manufacturer/packer/marketer keyword');
    check(date != null, 'Date-related label keyword');
    String context(RegExpMatch? m) {
      if (m == null) return '';
      final end = (m.start + 100 < text.length) ? m.start + 100 : text.length;
      return text.substring(m.start, end).replaceAll('\n', ', ').trim();
    }
    return ScanResult(rawText: text, productName: name, mrp: mrp?.group(0) ?? '',
      quantity: qty?.group(0) ?? '', manufacturer: context(man), dateInfo: context(date),
      found: found, missing: missing);
  }

  Future<void> _openBarcodeScanner() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => BarcodeScannerScreen(
          language: _language,
          speak: _say,
        ),
      ),
    );
  }

  Future<void> _voiceCommand() async {
    if (!_voiceOn) {
      await _say('Voice commands are turned off in settings.');
      return;
    }

    if (!_speechReady) {
      await _say(
        'Voice recognition is unavailable. Use the accessible buttons instead.',
      );
      return;
    }

    await _say(
      'Listening. Say scan product, repeat, price, quantity, warnings, or help.',
    );

    await _speech.listen(
      localeId: _locale,
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 2),
      onResult: (r) {
        if (r.finalResult) {
          _handleCommand(r.recognizedWords.toLowerCase());
        }
      },
    );
  }

  Future<void> _handleCommand(String c) async {
    if (c.contains('scan')) { await _scan(ImageSource.camera); }
    else if (c.contains('repeat') || c.contains('again')) {
      await _say(_result?.spoken ?? 'There is no result to repeat.');
    } else if (c.contains('price') || c.contains('mrp')) {
      await _say(_result == null ? 'Scan a product first.' : 'Price: ${_result!.mrp.isEmpty ? "not detected" : _result!.mrp}.');
    } else if (c.contains('quantity') || c.contains('weight')) {
      await _say(_result == null ? 'Scan a product first.' : 'Quantity: ${_result!.quantity.isEmpty ? "not detected" : _result!.quantity}.');
    } else if (c.contains('warning') || c.contains('missing')) {
      await _say(_result == null ? 'Scan a product first.' : (_result!.missing.isEmpty ? 'No basic screening fields missing.' : 'Not detected: ${_result!.missing.join(", ")}'));
    } else if (c.contains('help')) {
      await _say('Say scan product to start, repeat to hear the result, price or quantity for details, or warnings for missing fields.');
    } else {
      await _say('Command not recognized. Try scan, repeat, price, quantity, warnings, or help.');
    }
  }

  void _showHistory() {
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (ctx) => SafeArea(
      child: SizedBox(height: MediaQuery.of(ctx).size.height * .65, child: Padding(
        padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Scan History', style: Theme.of(ctx).textTheme.headlineSmall),
          const SizedBox(height: 10),
          if (_history.isEmpty) const Text('No scans yet.')
          else Expanded(child: ListView.builder(itemCount: _history.length, itemBuilder: (_, i) {
            final item = _history[i];
            return Semantics(button: true, label: 'Previous scan ${i + 1}: ${item.productName}. Activate to hear result.',
              child: ListTile(leading: const Icon(Icons.history), title: Text(item.productName),
                subtitle: Text(item.mrp.isEmpty ? 'MRP not detected' : item.mrp),
                onTap: () { Navigator.pop(ctx); setState(() => _result = item); _say(item.spoken); }));
          })),
        ]),
      )),
    ));
    _say('Scan history opened.');
  }

  void _showSettings() {
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) => SafeArea(child: Padding(padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Accessibility Settings', style: Theme.of(ctx).textTheme.headlineSmall),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(value: _language, decoration: const InputDecoration(labelText: 'Spoken language', border: OutlineInputBorder()),
            items: const [DropdownMenuItem(value: 'English', child: Text('English')), DropdownMenuItem(value: 'Bengali', child: Text('Bengali')), DropdownMenuItem(value: 'Hindi', child: Text('Hindi'))],
            onChanged: (v) { if (v != null) { _setLanguage(v); refresh(() {}); } }),
          SwitchListTile(title: const Text('Text-to-speech'), value: _ttsOn, onChanged: (v) async {
            setState(() => _ttsOn = v); refresh(() {}); await _savePrefs(); if (v) _say('Text to speech enabled.');
          }),
          SwitchListTile(title: const Text('Voice commands'), value: _voiceOn, onChanged: (v) async {
            setState(() => _voiceOn = v); refresh(() {}); await _savePrefs(); _say(v ? 'Voice commands enabled.' : 'Voice commands disabled.');
          }),
          const Text('Bengali/Hindi speech depends on the voices installed on your phone.'),
        ]),
      )),
    ));
  }

  Widget _button(String label, String hint, IconData icon, VoidCallback? action, {bool primary = false}) {
    return Semantics(button: true, label: label, hint: hint, enabled: action != null,
      child: SizedBox(width: double.infinity, child: primary
        ? FilledButton.icon(onPressed: action, icon: Icon(icon), label: Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text(label, style: const TextStyle(fontSize: 17))))
        : OutlinedButton.icon(onPressed: action, icon: Icon(icon), label: Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text(label, style: const TextStyle(fontSize: 17))))));
  }

  Widget _field(String label, String value) => Padding(padding: const EdgeInsets.only(bottom: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 3), Text(value.isEmpty ? 'Not detected' : value, style: const TextStyle(fontSize: 16)),
    ]));

  @override
  void dispose() {
    _recognizer.close();
    _translator?.close();
    _tts.stop();
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(appBar: AppBar(title: const Text('PackSureAI'), actions: [
      IconButton(tooltip: 'Accessibility settings',
          onPressed: _showSettings,
          icon: const Icon(Icons.accessibility_new)),
      IconButton(tooltip: 'Scan history',
          onPressed: _showHistory,
          icon: const Icon(Icons.history)),
    ]),
        body: SafeArea(child: ListView(padding: const EdgeInsets.all(18), children: [
      Semantics(header: true, child: Text('Accessible Product Label Scanner', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold))),
      const SizedBox(height: 8),
      const Text('Scan packaged-product labels, listen to detected information, and review basic screening warnings.', style: TextStyle(fontSize: 16)),
      const SizedBox(height: 16),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.record_voice_over, size: 32, semanticLabel: 'Voice guidance'), const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Voice guidance: $_language', style: const TextStyle(fontWeight: FontWeight.bold)), const SizedBox(height: 4), Text(_status, style: const TextStyle(fontSize: 15)),
        ])),
      ]))),
      const SizedBox(height: 12),
      _button('Scan Product with Camera',
          'Opens the camera to take a clear photo of the product label.',
          Icons.camera_alt, _busy ? null : () => _scan(ImageSource.camera),
          primary: true),
          const SizedBox(height: 8),
      _button('Scan Barcode',
          'Scan a food product barcode to retrieve available product information.',
          Icons.qr_code_scanner, _busy ? null : _openBarcodeScanner,
          ),
      const SizedBox(height: 8),
      _button('Choose Product Image',
          'Select an existing photo of a product label.',
          Icons.photo_library, _busy ? null : () => _scan(ImageSource.gallery)),
      const SizedBox(height: 8),
      _button('Voice Commands',
          'Say scan product, repeat, price, quantity, warnings, or help.',
          Icons.mic, _busy ? null : _voiceCommand),
      const SizedBox(height: 8),
      _button(_isSpeaking ? 'Stop Talking' : 'Talk / Read Result',
            _isSpeaking
                ? 'Stop the current voice message.'
                : 'Read the latest scan result or repeat the last voice message.',
            _isSpeaking ? Icons.stop_circle : Icons.volume_up,
            _toggleTalking,
            primary: true,
          ),
      const SizedBox(height: 8),
      const SizedBox(height: 8),
      _button('Repeat Last Result',
          'Speaks the latest scan result again.',
          Icons.volume_up, r == null ? null : () => _say(r.spoken)),
      const SizedBox(height: 8),
      _button('Scan History',
          'Open scans from this app session.',
          Icons.history, _showHistory),
      const SizedBox(height: 8),
      _button('Accessibility Settings',
          'Change spoken language, text-to-speech, and voice commands.',
          Icons.accessibility_new, _showSettings),
      if (_busy) ...[const SizedBox(height: 16), const Center(child: CircularProgressIndicator(semanticsLabel: 'Processing product image')), const Center(child: Text('Please wait while the image is processed.'))],
      if (r != null) ...[
        const SizedBox(height: 22), Semantics(header: true, child: Text('Scan Result', style: Theme.of(context).textTheme.headlineSmall)),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Product name', style: Theme.of(context).textTheme.titleMedium), SelectableText(r.productName, style: const TextStyle(fontSize: 17)),
          const Divider(height: 24), _field('MRP / retail price', r.mrp), _field('Quantity', r.quantity),
          _field('Manufacturer/packer text', r.manufacturer), _field('Date-related text', r.dateInfo),
          const Divider(height: 24), Text('Detected fields (${r.found.length})', style: Theme.of(context).textTheme.titleMedium),
          if (r.found.isEmpty) const Text('No screening fields detected.'),
          ...r.found.map((s) => ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.check_circle_outline), title: Text(s), dense: true)),
          const SizedBox(height: 8), Text('Not detected (${r.missing.length})', style: Theme.of(context).textTheme.titleMedium),
          if (r.missing.isEmpty) const Text('No basic screening fields were missing from this OCR result.'),
          ...r.missing.map((s) => ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.warning_amber), title: Text(s), dense: true)),
          ExpansionTile(title: const Text('View all text detected by OCR'), children: [Padding(padding: const EdgeInsets.all(12), child: SelectableText(r.rawText))]),
          const SizedBox(height: 8), _button('Speak Result', 'Read product details and limitations aloud.', Icons.volume_up, () => _say(r.spoken), primary: true),
        ]))),
      ],
      const SizedBox(height: 18),
      const Card(child: Padding(padding: EdgeInsets.all(14), child: Text(
        'Prototype disclaimer: This app demonstrates image-based text extraction and basic keyword screening. It is not an official Legal Metrology compliance determination and cannot confirm whether food is safe to eat. Always verify important label details manually.',
        style: TextStyle(fontSize: 14)))),
    ])));
  }
}
