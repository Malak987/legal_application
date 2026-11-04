/// A typed page of results returned by an application repository.
///
/// `hasMore` is explicit because public PostgREST responses may omit a total
/// count when the server cannot provide `Content-Range`; callers should not
/// infer it from `items.length` when an exact total is available.
class PaginatedResult<T> {
  const PaginatedResult({
    required this.items,
    required this.page,
    required this.limit,
    required this.total,
    required this.totalPages,
    required this.hasMore,
    this.exactTotal,
  });

  final List<T> items;
  final int page;
  final int limit;
  final int total;
  final int totalPages;
  final bool hasMore;
  final int? exactTotal;

  PaginatedResult<R> map<R>(R Function(T item) convert) => PaginatedResult<R>(
    items: items.map(convert).toList(growable: false),
    page: page,
    limit: limit,
    total: total,
    totalPages: totalPages,
    hasMore: hasMore,
    exactTotal: exactTotal,
  );
}
