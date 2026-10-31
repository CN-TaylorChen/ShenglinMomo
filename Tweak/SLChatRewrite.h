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

#pragma mark - 实拍卡片（knock_type28）

/// 卡片上的时间 / 公里数。空字符串 = 不改。
NSString *_Nullable SLRealShotTime(void);
NSString *_Nullable SLRealShotDistance(void);
void SLRealShotSetTime(NSString *_Nullable v);
void SLRealShotSetDistance(NSString *_Nullable v);

/// 卡片 body（prerender JSON）按上面的设置做字面量替换。
/// 只动 JSON，普通文字原样返回 —— 不依赖任何字段名。
NSString *_Nullable SLApplyRealShotEdits(NSString *_Nullable json);

#pragma mark - 防撤回

BOOL SLRecallGuardEnabled(void);
void SLRecallGuardSetEnabled(BOOL on);

/// 传本次从模型读到的 body，返回最终该显示的 body。
/// 正文正常时按 msgid 记一份；等正文被清空 / 变成撤回提示时顶回原文。
NSString *_Nullable SLRecallGuardBody(NSString *_Nullable mid, NSString *_Nullable body);

@interface SLChatRewriteListController : UITableViewController
@end

NS_ASSUME_NONNULL_END
