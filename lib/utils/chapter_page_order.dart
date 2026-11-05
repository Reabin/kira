/// Keeps server page offsets stable while reversing the catalogue's page order.
class ChapterPageOrder {
  const ChapterPageOrder({required this.totalPages, required this.reversed});

  final int totalPages;
  final bool reversed;

  int serverPage(int displayedPage) =>
      reversed ? totalPages - 1 - displayedPage : displayedPage;

  int displayedPage(int serverPage) =>
      reversed ? totalPages - 1 - serverPage : serverPage;

  int get firstServerPage => totalPages > 0 ? serverPage(0) : 0;
}
