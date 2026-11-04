class Product {
  final String imagePath;
  final String name;
  final String price;

  // Optional fields populated from the backend API.
  final String? id;
  final String? specialty;
  final String? categoryId;
  final double? rating;
  final String? location;
  final String? experience;
  final String? bio;
  final String? userId;
  final bool? isPopular;
  final bool? isTop;

  /// The lawyer's hourly rate, as stored on the `lawyers` document.
  ///
  /// This is the number the backend multiplies by `hours` to produce a
  /// booking's `totalPrice`; `price` above is only the display string.
  final double? priceValue;

  Product({
    required this.imagePath,
    required this.name,
    required this.price,
    this.id,
    this.specialty,
    this.categoryId,
    this.rating,
    this.location,
    this.priceValue,
    this.experience,
    this.bio,
    this.userId,
    this.isPopular,
    this.isTop,
  });
}
