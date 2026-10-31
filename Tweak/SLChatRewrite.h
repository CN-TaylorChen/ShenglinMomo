//
//  SLChatRewrite.h
//  声临 · 陌陌版 —— 聊天记录修改（仅本机渲染层）
//
//  v0.4.97：长按任意文本气泡 → 菜单里多一项「修改」→ 改完当场生效。
//  实现走 MDBaseMessage 的 body getter：气泡文案、行高、会话列表预览、复制 / 转发
//  全都读同一个 getter，所以改写后各处天然一致，不存在「气泡换了、行高没换」的错位。
//
//  注意：改写只写本机偏好，不碰陌陌的 com.momo.db，也不碰消息模型本体。
//  服务器与对方消息永远是原文。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

BOOL SLChatRewriteEnabled(void);
BOOL SLChatRewriteResetOnLeave(void);
void SLChatRewriteSetEnabled(BOOL on);
void SLChatRewriteSetResetOnLeave(BOOL on);

/// 该消息当前应该显示的文本。没有改写记录时原样返回 orig。
NSString *SLChatRewriteTextForMsgid(id _Nullable msgid, NSString *_Nullable orig);

/// 同一份改写记录可以挂多个 id（msgid / uuid / 菜单里的 "seq-uuid" 串），
/// 任一命中就算命中 —— 陌陌的菜单 id 与消息对象的 msgid 不是同一个值。
NSString *SLChatRewriteTextForIds(NSArray *_Nullable ids, NSString *_Nullable orig);

/// 一条消息要挂的全部 id：msgid / uuid + extra。
/// 只收「这条消息独有」的值 —— remoteid 是全会话共用的（对方 uid），
/// autoid 和 "CFD" 这种 3 位序号会撞车，挂上去就是「改 A，B 也变」。
NSArray *SLChatRewriteAliasesForMessage(id _Nullable message, NSString *_Nullable extra);

/// 纯字符串替换：认不出消息、只拿得到一段字面时用（气泡标签）。
/// 命中返回新文本，没命中返回 nil。
NSString *_Nullable SLChatRewriteTextForPlainString(NSString *_Nullable s);

/// 这条消息能不能当文本改。
/// 卡片 / 小程序 / 礼物这类消息的 body 是一坨 JSON（卡片配置），不是展示文本，
/// 改了也不会变 —— 与其让用户对着 JSON 编辑，不如直接拦掉。
BOOL SLChatRewriteMessageIsText(id _Nullable message);

/// 记一条改写（newText 为空等于还原）
void SLChatRewriteSave(NSString *msgid, NSArray *_Nullable aliases, NSString *_Nullable newText,
                       NSString *_Nullable orig, NSString *_Nullable session);

NSInteger SLChatRewriteCount(void);

/// 全部改写记录，每条 @{@"id", @"text", @"orig", @"session", @"time"}，按时间倒序
NSArray<NSDictionary *> *SLChatRewriteEntries(void);

void SLChatRewriteRemove(NSString *msgid);
void SLChatRewriteClearAll(void);
void SLChatRewriteClearSession(NSString *_Nullable session);

/// 当前聊天页的会话标识；拿不到具体会话号时退化成 VC 地址（同一会话内稳定）
NSString *SLChatRewriteCurrentSessionKey(void);

/// 从气泡（或其子视图）反查消息，弹出修改面板
void SLChatRewriteBeginFromBubble(UIView *_Nullable view);

/// 从 MDChatUIMenuView 进入：靠 targetView / targetViewFrame / targetViewCenter / msgid
/// 四路反查被长按的那条消息（气泡本身不在菜单的视图链上，不能从点击视图往上爬）
void SLChatRewriteBeginFromMenu(UIView *_Nullable menuView);

/// 聊天页离开时调用：按开关决定是否清掉本会话的改写
void SLChatRewriteHandleLeave(UIViewController *_Nullable vc);

/// 刷新当前聊天页（改写后重排）
void SLChatRewriteReloadChat(void);

/// 保存后把新文本直接写进活着的模型 / 气泡标签。
/// 气泡的字是建会话数据时解析进 cellViewModel 的，只 reloadData 不会重算，
/// 所以必须把这层也改掉，否则「保存成功、界面照旧」。
void SLChatRewritePatchLiveText(NSArray *_Nullable aliases, NSString *_Nullable orig,
                                NSString *_Nullable repl);

/// 刷新后回读可见气泡上真正显示的字（诊断用）
void SLChatRewriteDumpVisibleText(void);

#pragma mark - 每条消息自己的「时间 / 距离」
//
// 聊天界面上每条消息上方那行 `12:48 35.95km` 是 App 拿这条消息的发送时间 +
// 当时的经纬度现场算的，每条都不一样 —— 所以只能一条一条改，绝不能放一个全局开关。
// 映射按 msgid 存，渲染时按「这条消息上方最近的那行」贴回去。
//
// v0.5.11 起取代设置页里那两个全局输入框（已删除，旧值一并清掉）。

/// 这条消息自定义的时间描述（"12:01" / "10-28 15:19" / "5分钟前"），没有则 nil
NSString *_Nullable SLMetaTimeFor(NSString *_Nullable msgid);
/// 这条消息自定义的距离（"96.96km" 或 "96.96"），没有则 nil
NSString *_Nullable SLMetaDistFor(NSString *_Nullable msgid);
/// 这条消息自定义的绝对日期（"10-28 15:19"），填了就整体替换时间头，没有则 nil
NSString *_Nullable SLMetaDateFor(NSString *_Nullable msgid);

/// 记一条（时间 / 距离 / 日期 都为空等于删除该条）
void SLMetaSave(NSString *_Nullable msgid, NSString *_Nullable time,
                NSString *_Nullable dist, NSString *_Nullable date);

/// 该消息是否已经有自定义时间 / 距离 / 日期
BOOL SLMetaHasOverride(NSString *_Nullable msgid);

/// 把整张表可见行的时间行按映射刷一遍（保存后 / cell 显示时调）
void SLChatMetaApplyTable(UITableView *_Nullable tv);

/// 从气泡菜单进入「改时间 / 距离」面板（跟「修改」同一套锚点反查）
void SLChatMetaBeginFromMenu(UIView *_Nullable menuView);

/// 从「长按时间行本身」进入：直接拿这条 cell 的 msgid，零坐标反查误差
void SLChatMetaBeginFromCell(UITableViewCell *_Nullable cell);

/// 给这条 cell 里的时间行 UILabel 挂一个长按手势（只挂一次），零坐标反查误差
void SLChatMetaAttachTimeLongPress(UITableViewCell *_Nullable cell);

#pragma mark - 实拍卡片（knock_type28）

/// 卡片上的时间 / 公里数。空字符串 = 不改。
/// v0.5.11 起这两个全局值不再由界面写入，只保留给卡片 JSON 做兼容读。
NSString *_Nullable SLRealShotTime(void);
NSString *_Nullable SLRealShotDistance(void);
void SLRealShotSetTime(NSString *_Nullable v);
void SLRealShotSetDistance(NSString *_Nullable v);

/// 卡片 body（prerender JSON）按上面的设置做字面量替换。
/// 只动 JSON，普通文字原样返回 —— 不依赖任何字段名。
NSString *_Nullable SLApplyRealShotEdits(NSString *_Nullable json);

/// 聊天界面每条消息下面那行「1分钟前 35.95km」。
/// 这串是 App 用发送时间 + 当前位置现场算的，不在任何 JSON 里，
/// 所以按显示形态拆（时间描述 + 数字km）再按设置重组。
NSString *_Nullable SLApplyMetaEdits(NSString *_Nullable s);

/// 把当前屏幕上所有「时间 + 距离」按设置刷一遍（设置改完立刻调）。
void SLChatMetaSweep(UIView *_Nullable root);

#pragma mark - 防撤回

BOOL SLRecallGuardEnabled(void);
void SLRecallGuardSetEnabled(BOOL on);

/// 传本次从模型读到的 body，返回最终该显示的 body。
/// 正文正常时按 msgid 记一份；等正文被清空 / 变成撤回提示时，若这条是「被拦」的，
/// 就顶回原文并把 mid 写进持久拦截名单（重进仍在）。
NSString *_Nullable SLRecallGuardBody(NSString *_Nullable mid, NSString *_Nullable body);

/// 这条消息是不是被我们拦截下来的撤回（持久名单）
BOOL SLRecallIsBlocked(NSString *_Nullable mid);

/// 被拦消息的原文（持久名单里存的）
NSString *_Nullable SLRecallBlockedOriginal(NSString *_Nullable mid);

/// 撤销一条拦截（同时清掉持久记录）
void SLRecallUnblock(NSString *_Nullable mid);

/// 单格渲染层拦截：被拦的那条盖一张居中浅灰卡片（红「已拦截」徽章 + 原文自动换行）。
/// 只对被拦 mid 生效，别的消息一律不动（解决「贴满屏」）。不再重绑 → 无蓝色死循环。
void SLRecallApplyCell(UITableViewCell *_Nullable cell);

/// 隐藏拦截标记：开启后撤回行渲染成普通「对方撤回了一条消息」，不露标记/原文（截图安全）。
BOOL SLRecallHidden(void);
void SLRecallSetHidden(BOOL on);

/// 甲卡片的高度估算（供 heightForRow 撑高被拦的撤回行）
CGFloat SLRecallCardHeight(NSString *_Nullable orig, CGFloat tableWidth);

/// 由 indexPath 反查该行消息的 msgid（行高 hook 用；取不到返回 nil）
NSString *_Nullable SLCRMsgidAtIndexPath(UITableView *_Nullable tv, NSIndexPath *_Nullable ip);

/// 撤回态整形：灰底刷白、字号提回正文，再贴一句「对方撤回了一条消息」。
void SLRecallStyleSweep(void);

/// 刷新可见的被拦撤回行（只按卡片重绘，不重绑）。
void SLRecallRepaintVisible(void);

@interface SLChatRewriteListController : UITableViewController
@end

NS_ASSUME_NONNULL_END
