class LegalCategory {
  const LegalCategory({required this.id, required this.name, this.slug = ''});

  final String id;
  final String name;
  final String slug;

  factory LegalCategory.fromJson(Map<String, dynamic> json) => LegalCategory(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        slug: json['slug']?.toString() ?? '',
      );
}
