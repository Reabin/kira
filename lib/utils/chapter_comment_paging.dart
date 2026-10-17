/// 章节评论（`/api/v3/roasts`）的分页参数。
///
/// 服务端已把每页条数强制压到 10：请求里传更大的 `limit` 也只返回 10 条，
/// 响应里的 `results.limit` 也回显 10。客户端按实际页宽分页，避免合并逻辑
/// 按错误的页宽推算溢出项。
library;

/// 章节评论接口实际返回的每页条数。
const int chapterCommentPageSize = 10;

/// 打开评论区时默认预取的页数。
const int chapterCommentInitialPages = 2;

/// 连续翻页之间的间隔，避免短时间内连发请求。
const Duration chapterCommentPageGap = Duration(seconds: 1);
