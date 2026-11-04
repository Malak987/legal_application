import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../constants/colors.dart';
import '../models/product_model.dart';
import '../views/home/details.dart';

class ProductCard extends StatefulWidget {
  final String imagePath;
  final String name;
  final String price;
  final Product? lawyer;
  final double? rating;
  final VoidCallback? onTap;
  final bool isFavorited;
  final VoidCallback? onFavoriteTap;
  final String language;

  const ProductCard({
    super.key,
    required this.imagePath,
    required this.name,
    required this.price,
    this.lawyer,
    this.rating,
    this.onTap,
    this.isFavorited = false,
    this.onFavoriteTap,
    this.language = 'en',
  });

  @override
  State<ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends State<ProductCard> {
  late bool _isFavorited;

  @override
  void initState() {
    super.initState();
    _isFavorited = widget.isFavorited;
  }

  @override
  Widget build(BuildContext context) {
    final displayRating = widget.rating ?? widget.lawyer?.rating ?? 4.0;
    final specialty = widget.lawyer?.specialty;

    return Semantics(
      button: true,
      child: GestureDetector(
        onTap:
            widget.onTap ??
            () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (_) => LegalServiceDetailsScreen(
                        lawyer: widget.lawyer,
                        lawyerId: widget.lawyer?.id,
                      ),
                ),
              );
            },
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.blueAccent.withAlpha((0.2 * 255).toInt()),
                spreadRadius: 2,
                blurRadius: 7,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildImageSection()),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: widget.name,
                      excludeFromSemantics: true,
                      child: Text(
                        widget.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (specialty != null && specialty.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Tooltip(
                        message: specialty,
                        excludeFromSemantics: true,
                        child: Text(
                          specialty,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.text1Color,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    // Natural wrapping keeps both the actual rating and the
                    // complete price readable at narrow widths / large text.
                    SizedBox(
                      width: double.infinity,
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.star,
                                color: Colors.amber,
                                size: 16,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                displayRating.toStringAsFixed(1),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            widget.price,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: AppColors.buttonColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageSection() {
    final fallback = Image.asset(
      'images/lawyer2.png',
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      width: double.infinity,
      height: double.infinity,
      errorBuilder:
          (_, __, ___) => Container(
            color: AppColors.bgColor,
            child: const Icon(Icons.person, color: AppColors.text3Color),
          ),
    );

    Widget imageWidget;
    if (widget.imagePath.isEmpty) {
      imageWidget = fallback;
    } else if (widget.imagePath.startsWith('http')) {
      imageWidget = CachedNetworkImage(
        imageUrl: widget.imagePath,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        width: double.infinity,
        height: double.infinity,
        placeholder:
            (context, url) => Container(
              color: Colors.grey[200],
              child: const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    AppColors.buttonColor,
                  ),
                ),
              ),
            ),
        errorWidget: (context, url, error) => fallback,
        fadeOutDuration: const Duration(milliseconds: 500),
        fadeInDuration: const Duration(milliseconds: 500),
      );
    } else {
      imageWidget = Image.asset(
        widget.imagePath,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => fallback,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: imageWidget,
        ),
        PositionedDirectional(
          top: 1,
          end: 1,
          child: IconButton(
            tooltip:
                widget.language == 'ar'
                    ? (_isFavorited ? 'إزالة من المفضلة' : 'إضافة إلى المفضلة')
                    : (_isFavorited
                        ? 'Remove from favorites'
                        : 'Add to favorites'),
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            padding: const EdgeInsets.all(9),
            iconSize: 30,
            onPressed: () {
              setState(() {
                _isFavorited = !_isFavorited;
              });
              if (widget.onFavoriteTap != null) {
                widget.onFavoriteTap!();
              }
            },
            icon: CircleAvatar(
              radius: 15,
              backgroundColor: Colors.white,
              child: Icon(
                _isFavorited ? Icons.favorite : Icons.favorite_border,
                size: 18,
                color: Colors.redAccent,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
