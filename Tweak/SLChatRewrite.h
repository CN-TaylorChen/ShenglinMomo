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

/// 记一条改写（newText 为空等于还原）
void SLChatRewriteSave(NSString *msgid, NSString *_Nullable newText,
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

/// 聊天页离开时调用：按开关决定是否清掉本会话的改写
void SLChatRewriteHandleLeave(UIViewController *_Nullable vc);

/// 刷新当前聊天页（改写后重排）
void SLChatRewriteReloadChat(void);

@interface SLChatRewriteListController : UITableViewController
@end

NS_ASSUME_NONNULL_END
