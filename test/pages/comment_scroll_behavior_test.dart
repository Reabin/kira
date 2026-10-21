import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/pages/chapter_comments/comment_scroll_behavior.dart';

class _Probe extends StatefulWidget {
  const _Probe({required this.onLoadMore});

  final VoidCallback onLoadMore;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with CommentScrollBehavior<_Probe> {
  // 与真实 sheet 一致：请求期间 canLoadMore 为 false，一次滑动只发一次。
  bool _loadingMore = false;

  @override
  bool get canLoadMore => !_loadingMore;

  @override
  void loadMoreComments() {
    if (_loadingMore) return;
    _loadingMore = true;
    widget.onLoadMore();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: handleScrollNotification,
      child: ListView(
        controller: scrollController,
        physics: CommentScrollBehavior.alwaysDraggablePhysics,
        children: const [SizedBox(height: 40, child: Text('only row'))],
      ),
    );
  }
}

void main() {
  testWidgets('下滑手势在内容不满一屏时也能触发加载下一页', (tester) async {
    var loadMoreCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _Probe(onLoadMore: () => loadMoreCalls++)),
      ),
    );

    final state = tester.state<_ProbeState>(find.byType(_Probe));
    expect(state.scrollController.position.maxScrollExtent, 0);

    await tester.drag(find.text('only row'), const Offset(0, -120));
    await tester.pump();

    expect(loadMoreCalls, 1);
  });
}
