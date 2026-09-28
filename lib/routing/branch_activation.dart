import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 主导航分支的「激活且停稳」信号。
///
/// 背景：五个分支页面随 StatefulShellRoute 常驻挂载（preload），initState 里
/// 发起的首次数据加载会在启动时全部执行；隐藏分支的数据回填（骨架 → 内容）
/// 又会把待重绘欠账攒到用户第一次切过去的那一帧，表现为首次切页掉帧。把首次
/// 加载推迟到「本分支成为当前页且切页停稳」之后：启动只加载当前页，其他页面
/// 停留在框架（骨架屏），内容在首次切到并停稳后才请求。
///
/// 信号由分支容器（`_AnimatedBranchContainer`）写入：某分支在无切换/拖动动画
/// 的情况下持续停留一小段时间后广播其序号；页面侧经 [BranchDeferredInit] 消费。
class BranchActivationScope extends InheritedWidget {
  const BranchActivationScope({
    super.key,
    required this.branchIndex,
    required this.settledBranch,
    required super.child,
  });

  /// 本分支的固定序号（由分支容器按子节点位置写入，页面无需硬编码）。
  final int branchIndex;

  /// 最近一次停稳激活的分支序号；null = 启动以来还没有分支停稳过。
  final ValueListenable<int?> settledBranch;

  /// 本分支当前是否处于「激活且停稳」状态。
  bool get isSettledActive => settledBranch.value == branchIndex;

  @override
  bool updateShouldNotify(BranchActivationScope oldWidget) => false;

  /// 页面只在 initState 里取一次 [settledBranch] 引用并自行监听，
  /// 不走依赖注册，因此这里的更新通知恒为 false。
  static BranchActivationScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<BranchActivationScope>();
}

/// 分支页把「首次数据加载」推迟到本分支激活的统一入口。
///
/// 用法：State 混入 [BranchDeferredInit]，把 initState 里的首次加载挪进
/// [onBranchFirstActivated]，并在 initState 末尾调用一次
/// [deferInitialLoadToBranchActivation]：
///
/// ```dart
/// class _FooState extends State<Foo> with BranchDeferredInit {
///   @override
///   void initState() {
///     super.initState();
///     deferInitialLoadToBranchActivation();
///   }
///
///   @override
///   void onBranchFirstActivated() {
///     _load(); // 原 initState 里的首次加载
///   }
/// }
/// ```
///
/// 语义：分支从未被切到过就一直不加载；切到并停稳后恰好回调一次；之后切回
/// 不再重复（页面状态保留，数据新鲜度由 CachedRepository 的刷新策略负责）。
/// 不在主导航分支容器内（页面被独立宿主/测试直接挂载）时保持旧版行为，
/// initState 立即加载。
mixin BranchDeferredInit<T extends StatefulWidget> on State<T> {
  bool _branchInitialLoadStarted = false;
  ValueListenable<int?>? _settledBranchSource;
  VoidCallback? _branchActivationListener;

  /// 本分支首次激活（成为当前页且切页停稳）时执行的首次加载。
  @protected
  void onBranchFirstActivated();

  /// 首次加载是否已开始；页面里激活前的其他加载入口（如设置变更触发的
  /// 重载）用它跳过——激活回调会按最新状态做首次加载。
  @protected
  bool get branchInitialLoadStarted => _branchInitialLoadStarted;

  /// initState 末尾调用一次：把 [onBranchFirstActivated] 安排到本分支首次
  /// 「激活且停稳」时执行；调用时已激活则立即执行。
  @protected
  void deferInitialLoadToBranchActivation() {
    assert(!_branchInitialLoadStarted);
    final scope = BranchActivationScope.maybeOf(context);
    if (scope == null || scope.isSettledActive) {
      _runBranchInitialLoad();
      return;
    }
    _settledBranchSource = scope.settledBranch;
    _branchActivationListener = () {
      if (scope.settledBranch.value == scope.branchIndex) {
        _runBranchInitialLoad();
      }
    };
    scope.settledBranch.addListener(_branchActivationListener!);
  }

  void _runBranchInitialLoad() {
    if (_branchInitialLoadStarted) return;
    _branchInitialLoadStarted = true;
    _stopListening();
    onBranchFirstActivated();
  }

  void _stopListening() {
    final listener = _branchActivationListener;
    final source = _settledBranchSource;
    if (listener != null && source != null) {
      source.removeListener(listener);
    }
    _branchActivationListener = null;
    _settledBranchSource = null;
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }
}
