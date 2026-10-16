import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

class BarcodeScannerScreen extends StatefulWidget {
  final String language;
  final Future<void> Function(String) speak;

  const BarcodeScannerScreen({
    super.key,
    required this.language,
    required this.speak,
  });

  @override
  State<BarcodeScannerScreen> createState() =>
      _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen>
    with WidgetsBindingObserver {
  final MobileScannerController _controller =
  MobileScannerController();

  bool _scanned = false;
  bool _loading = false;
  bool _torchOn = false;

  String? _barcode;
  String? _error;
  Map<String, dynamic>? _product;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _controller.stop();
    } else if (state == AppLifecycleState.resumed &&
        mounted &&
        !_scanned) {
      _controller.start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_scanned || _loading) return;

    String? code;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && value.isNotEmpty) {
        code = value;
        break;
      }
    }

    if (code == null) return;

    setState(() {
      _scanned = true;
      _loading = true;
      _barcode = code;
      _product = null;
      _error = null;
    });

    await _controller.stop();
    await _lookup(code);
  }

  Future<void> _lookup(String code) async {
    try {
      final uri = Uri.https(
        'world.openfoodfacts.org',
        '/api/v2/product/$code',
        {
          'fields':
          'product_name,product_name_en,brands,quantity,'
              'ingredients_text,ingredients_text_en,'
              'allergens,allergens_en,nutrition_grades,'
              'nutriments,categories,image_front_url',
        },
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'PackSureAI/1.0 (Flutter mobile app)',
        },
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        throw Exception('Product lookup failed.');
      }

      final data =
      jsonDecode(response.body) as Map<String, dynamic>;

      if (data['status'] != 1 || data['product'] == null) {
        if (!mounted) return;
        setState(() {
          _error =
          'Product not found in the database. '
              'Please use the label scanner to read the package.';
        });
        await widget.speak(
          'Product not found in the database. '
              'Please use the label scanner to read the package.',
        );
        return;
      }

      final product =
      Map<String, dynamic>.from(data['product'] as Map);

      if (!mounted) return;

      setState(() {
        _product = product;
      });

      await widget.speak(_speechSummary(product));
    } on http.ClientException catch (e) {
      debugPrint('Barcode API network error: $e');

      if (!mounted) return;

      setState(() {
        _error = 'Cannot connect to the product database. '
            'Check your internet connection and try again.';
      });

      await widget.speak(
        'Cannot connect to the product database. '
            'Please check your internet connection.',
      );
    } catch (e, stackTrace) {
      debugPrint('Barcode lookup error: $e');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return;

      setState(() {
        _error = 'The product database could not be read. '
            'Please try again.';
      });

      await widget.speak(
        'The product database could not be read. '
            'Please try again.',
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }

  }

  String _text(dynamic value) {
    if (value == null) return 'Not available';
    final result = value.toString().trim();
    return result.isEmpty ? 'Not available' : result;
  }

  String _name(Map<String, dynamic> product) {
    return _text(
      product['product_name'] ?? product['product_name_en'],
    );
  }

  String _ingredients(Map<String, dynamic> product) {
    if (widget.language == 'English') {
      return _text(
        product['ingredients_text_en'] ??
            product['ingredients_text'],
      );
    }
    return _text(product['ingredients_text']);
  }

  String _allergens(Map<String, dynamic> product) {
    if (widget.language == 'English') {
      return _text(
        product['allergens_en'] ?? product['allergens'],
      );
    }
    return _text(product['allergens']);
  }

  String _nutrition(Map<String, dynamic> product) {
    final raw = product['nutriments'];
    if (raw is! Map) return 'Nutrition information unavailable.';

    final nutrition = Map<String, dynamic>.from(raw);
    final values = <String>[];

    void add(String key, String label, String unit) {
      final value = nutrition['${key}_100g'];
      if (value != null) {
        values.add('$label: $value $unit per 100 g');
      }
    }

    add('energy-kcal', 'Energy', 'kcal');
    add('fat', 'Fat', 'g');
    add('saturated-fat', 'Saturated fat', 'g');
    add('carbohydrates', 'Carbohydrates', 'g');
    add('sugars', 'Sugars', 'g');
    add('proteins', 'Protein', 'g');
    add('salt', 'Salt', 'g');

    return values.isEmpty
        ? 'Nutrition information unavailable.'
        : values.join('\n');
  }

  String _speechSummary(Map<String, dynamic> product) {
    return 'Barcode scan completed. '
        'Product name: ${_name(product)}. '
        'Brand: ${_text(product['brands'])}. '
        'Quantity: ${_text(product['quantity'])}. '
        'Ingredients: ${_ingredients(product)}. '
        'Allergens: ${_allergens(product)}. '
        'Nutrition information: ${_nutrition(product)}. '
        'This information may be incomplete or outdated. '
        'Always check the product package. '
        'This scan does not confirm food safety.';
  }

  Widget _detail(String title, String value) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(value),
          ],
        ),
      ),
    );
  }

  Future<void> _scanAgain() async {
    if (!mounted || _loading) return;

    setState(() {
      _scanned = false;
      _barcode = null;
      _product = null;
      _error = null;
      _torchOn = false;
    });

    // Allow the scanner widget to update before restarting the camera.
    await Future<void>.delayed(
      const Duration(milliseconds: 300),
    );

    if (!mounted) return;

    try {
      await _controller.start();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _scanned = true;
        _error = 'Could not restart the camera. '
            'Please close the scanner and open it again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final product = _product;
    final imageUrl = product?['image_front_url']?.toString();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Food Barcode'),
        actions: [
          IconButton(
            tooltip: 'Toggle flashlight',
            onPressed: () async {
              await _controller.toggleTorch();
              if (mounted) {
                setState(() => _torchOn = !_torchOn);
              }
            },
            icon: Icon(
              _torchOn ? Icons.flash_on : Icons.flash_off,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Point your camera at the barcode on the food package.',
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            if (!_scanned) ...[
              const SizedBox(height: 16),
              Visibility(
                visible: !_scanned,
                maintainState: true,
                child: SizedBox(
                  height: 280,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: MobileScanner(
                      controller: _controller,
                      onDetect: _onDetect,
                    ),
                  ),
                ),
              ),
            ],
            if (_loading) ...[
              const SizedBox(height: 20),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 8),
              const Text(
                'Looking up product information...',
                textAlign: TextAlign.center,
              ),
            ],
            if (_barcode != null) ...[
              const SizedBox(height: 12),
              _detail('Barcode number', _barcode!),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              _detail('Result', _error!),
            ],
            if (product != null) ...[
              const SizedBox(height: 16),
              if (imageUrl != null &&
                  imageUrl.startsWith('https://'))
                Image.network(
                  imageUrl,
                  height: 160,
                  errorBuilder: (_, __, ___) =>
                  const SizedBox.shrink(),
                ),
              Text(
                _name(product),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              _detail('Brand', _text(product['brands'])),
              _detail('Quantity', _text(product['quantity'])),
              _detail('Ingredients', _ingredients(product)),
              _detail('Allergens', _allergens(product)),
              _detail(
                'Nutrition per 100 g',
                _nutrition(product),
              ),
              _detail(
                'Nutri-Score',
                _text(product['nutrition_grades']),
              ),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Database information can be incomplete or '
                        'outdated. Missing allergen information does not '
                        'mean allergen-free. A barcode scan cannot prove '
                        'that a food is safe to eat.',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () =>
                    widget.speak(_speechSummary(product)),
                icon: const Icon(Icons.volume_up),
                label: const Text('Read Product Information Again'),
              ),
            ],
            if (_scanned && !_loading) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _scanAgain,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan Another Product'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}