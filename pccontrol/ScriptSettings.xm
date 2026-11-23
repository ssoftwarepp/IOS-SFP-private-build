#import "ScriptSettings.h"
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

static UIWindow *zxSettingsWindow;
static id zxSettingsPresenter;
static __weak UIWindow *zxPreviousKeyWindow;
static BOOL zxSettingsOpening;

BOOL zxScriptSettingsVisible(void) {
    @synchronized(NSFileManager.defaultManager) { return zxSettingsOpening; }
}
BOOL zxReserveScriptSettings(void) {
    @synchronized(NSFileManager.defaultManager) {
        if (zxSettingsOpening) return NO;
        zxSettingsOpening = YES;
        return YES;
    }
}

BOOL zxScriptHasSettings(NSString *bundlePath) {
    return [bundlePath.pathExtension.lowercaseString isEqualToString:@"bdl"] &&
        [[NSFileManager defaultManager] fileExistsAtPath:[bundlePath stringByAppendingPathComponent:@"index.html"]];
}

@interface ZXScriptSettingsController : UIViewController <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, copy) NSString *bundlePath;
@property (nonatomic, copy) void (^completion)(BOOL);
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, assign) BOOL runAfterSave;
@end

@implementation ZXScriptSettingsController

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    [configuration.userContentController addScriptMessageHandler:self name:@"iosSfpSettings"];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    NSString *html = [self.bundlePath stringByAppendingPathComponent:@"index.html"];
    [self.webView loadFileURL:[NSURL fileURLWithPath:html]
        allowingReadAccessToURL:[NSURL fileURLWithPath:self.bundlePath isDirectory:YES]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self.bundlePath.lastPathComponent stringByDeletingPathExtension];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
        target:self action:@selector(cancelSettings)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:self.runAfterSave ? @"保存并运行" : @"保存" style:UIBarButtonItemStyleDone
        target:self action:@selector(saveSettings)];
    self.navigationItem.rightBarButtonItem.enabled = NO;
}

- (void)cancelSettings { [self finish:NO]; }

- (void)saveSettings {
    [self.webView evaluateJavaScript:@"window.iosSfpSettingsSubmit && window.iosSfpSettingsSubmit()"
        completionHandler:^(id result, NSError *error) {
            if (error || result == nil || [result isKindOfClass:NSNull.class])
                [self showError:@"页面需要定义 iosSfpSettingsSubmit()。"];
        }];
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置未保存" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSData *savedData = [NSData dataWithContentsOfFile:[self.bundlePath stringByAppendingPathComponent:@"settings.json"]];
    id stored = savedData ? [NSJSONSerialization JSONObjectWithData:savedData options:0 error:nil] : nil;
    if (![stored isKindOfClass:NSDictionary.class]) stored = @{};
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:stored options:0 error:nil];
    NSString *literal = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"window.dispatchEvent(new CustomEvent('ios-sfp-settings', {detail: %@}));", literal];
    [webView evaluateJavaScript:script completionHandler:nil];
    self.navigationItem.rightBarButtonItem.enabled = YES;
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *payload = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    if (![payload[@"action"] isEqualToString:@"save"] || ![payload[@"data"] isKindOfClass:NSDictionary.class]) {
        [self showError:@"设置数据必须是 JSON 对象。"]; return;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload[@"data"] options:NSJSONWritingPrettyPrinted error:nil];
    if (!json || json.length > 256 * 1024 || ![json writeToFile:[self.bundlePath stringByAppendingPathComponent:@"settings.json"] atomically:YES]) {
        [self showError:@"写入 settings.json 失败。"]; return;
    }
    [self finish:YES];
}

- (void)finish:(BOOL)saved {
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"iosSfpSettings"];
    self.webView.navigationDelegate = nil;
    void (^done)(BOOL) = self.completion;
    self.completion = nil;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (zxSettingsWindow) {
            zxSettingsWindow.hidden = YES;
            zxSettingsWindow.rootViewController = nil;
            zxSettingsWindow = nil;
        }
        [zxPreviousKeyWindow makeKeyWindow];
        zxPreviousKeyWindow = nil;
        zxSettingsPresenter = nil;
        @synchronized(NSFileManager.defaultManager) { zxSettingsOpening = NO; }
        if (done) done(saved);
    }];
}
@end

void zxPresentScriptSettings(NSString *bundlePath, BOOL runAfterSave, void (^completion)(BOOL saved)) {
    if (!zxScriptHasSettings(bundlePath)) { if (completion) completion(NO); return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        ZXScriptSettingsController *page = [[ZXScriptSettingsController alloc] init];
        page.bundlePath = bundlePath;
        page.runAfterSave = runAfterSave;
        page.completion = completion;
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:page];
        UIWindowScene *scene = (UIWindowScene *)[UIApplication.sharedApplication.connectedScenes anyObject];
        zxSettingsWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        zxSettingsWindow.frame = UIScreen.mainScreen.bounds;
        zxSettingsWindow.windowLevel = UIWindowLevelAlert + 2;
        zxSettingsWindow.rootViewController = [[UIViewController alloc] init];
        zxSettingsWindow.rootViewController.view.backgroundColor = UIColor.systemBackgroundColor;
        zxSettingsPresenter = navigation;
        zxPreviousKeyWindow = UIApplication.sharedApplication.keyWindow;
        [zxSettingsWindow makeKeyAndVisible];
        [zxSettingsWindow.rootViewController presentViewController:navigation animated:YES completion:nil];
    });
}
