/*
 * This file is part of Adblock Plus <https://adblockplus.org/>,
 * Copyright (C) 2006-present eyeo GmbH
 *
 * Adblock Plus is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 3 as
 * published by the Free Software Foundation.
 *
 * Adblock Plus is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Adblock Plus.  If not, see <http://www.gnu.org/licenses/>.
 */

#import "WebViewGesturesHandler.h"
#import "UnpreventableUILongPressGestureRecognizer.h"
#import "ContextMenuProvider.h"
#import "Settings.h"
#import "ObjCLogger.h"

@interface WebViewGesturesHandler () {
    UIView *_viewToRecognize;
    UnpreventableUILongPressGestureRecognizer *_longTapRecognizer;
    NSString *_webViewIntrospectionJSCode;
}

@end

@implementation WebViewGesturesHandler

- (instancetype)initWithViewToRecognize:(UIView *)viewToRecognize
{
    if (self = [super init]) {
        _viewToRecognize = viewToRecognize;
        _longTapRecognizer = [[UnpreventableUILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(longPressRecognized:)];
        _longTapRecognizer.allowableMovement = 20;
        _longTapRecognizer.minimumPressDuration = 1.0f;
        [_viewToRecognize addGestureRecognizer:_longTapRecognizer];
    }
    return self;
}

- (void)dealloc
{
    [_viewToRecognize removeGestureRecognizer:_longTapRecognizer];
}

- (void)setCurrentWebView:(WKWebView *)currentWebView
{
    _currentWebView = currentWebView;
    if (!_webViewIntrospectionJSCode) {
        // Lazy load of the introspection code
        NSString *path = [[Settings coreBundle] pathForResource:@"WebViewIntrospection" ofType:@"js"];
        _webViewIntrospectionJSCode = [NSString stringWithContentsOfFile:path
                                                                encoding:NSUTF8StringEncoding
                                                                   error:nil];
    }
}

- (void)longPressRecognized:(UILongPressGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        CGPoint touchPosition = [gestureRecognizer locationInView:_currentWebView];
        if (_handlerBlock) {
            _handlerBlock(touchPosition);
        }
    }
}

- (void)getURLs:(CurrentContextURLs *)urls fromCurrentPosition:(CGPoint)point
{

    point.x -= _currentWebView.scrollView.contentInset.left;
    point.y -= _currentWebView.scrollView.contentInset.top;

    // convert point from view to HTML coordinate system
    CGSize viewSize = _currentWebView.frame.size;
    __block CGFloat windowInnerWidth;
    __block CGFloat windowInnerHeight;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [_currentWebView evaluateJavaScript:@"window.innerWidth" completionHandler:^(id _Nullable result, NSError * _Nullable error) {
        if (!error) {
            NSString *stringResult = [NSString stringWithFormat:@"%@", result];
            windowInnerWidth = [stringResult floatValue];
        } else {
            NSLog(@"Error evaluatingJS for innerWidth: %@", [error localizedDescription]);
        }
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);
    [_currentWebView evaluateJavaScript:@"window.innerHeight" completionHandler:^(id _Nullable result, NSError * _Nullable error) {
        if (!error) {
            NSString *stringResult = [NSString stringWithFormat:@"%@", result];
            windowInnerHeight = [stringResult floatValue];
        } else {
            NSLog(@"Error evaluatingJS for innerHeight: %@", [error localizedDescription]);
        }
        dispatch_semaphore_signal(sem2);
    }];
    dispatch_semaphore_wait(sem2, DISPATCH_TIME_FOREVER);

    CGSize windowSize = CGSizeMake(windowInnerWidth, windowInnerHeight);
    CGFloat f = windowSize.width / viewSize.width;
    point.x = point.x * f;
    point.y = point.y * f;

    dispatch_semaphore_t sem3 = dispatch_semaphore_create(0);
    [_currentWebView evaluateJavaScript:_webViewIntrospectionJSCode completionHandler:^(id _Nullable result, NSError * _Nullable error) {
        if (error) {
            NSLog(@"Error evaluatingJS for introspectionJSCode: %@", [error localizedDescription]);
        }
        dispatch_semaphore_signal(sem3);
    }];
    dispatch_semaphore_wait(sem3, DISPATCH_TIME_FOREVER);

    // get the Tags at the touch location
    __block NSString *elementsJSON;

    dispatch_semaphore_t sem4 = dispatch_semaphore_create(0);
    [_currentWebView evaluateJavaScript:[NSString stringWithFormat:@"com_kitt_SearchElementsPropertiesAtPoint(%li,%li);",
                                         (long)point.x, (long)point.y] completionHandler:^(id _Nullable result, NSError * _Nullable error) {
        if (!error) {
            elementsJSON = [NSString stringWithFormat:@"%@", result];
        } else {
            NSLog(@"Error evaluatingJS for searchElementsAtPropertiesAtPoint: %@", [error localizedDescription]);
        }
        dispatch_semaphore_signal(sem4);
    }];
    dispatch_semaphore_wait(sem4, DISPATCH_TIME_FOREVER);

    NSData *elementsData = [elementsJSON dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    NSDictionary *elements = [NSJSONSerialization JSONObjectWithData:elementsData options:0 error:&err];
    if (err) {
        LogError(@"Failed inspecting DOM at point (%li, %li): %@", (long)point.x, (long)point.y, [err localizedDescription]);
        return;
    }
    NSDictionary *maybeImage = elements[@"IMG"];
    if (maybeImage) {
        NSString *urlString = maybeImage[@"src"];
        if ([urlString length] > 0) {
            urls.image = [NSURL URLWithString:urlString];
        }
        urls.label = maybeImage[@"alt"];
    } else {
        urls.image = nil;
        urls.label = nil;
    }
    NSDictionary *maybeLink = elements[@"A"];
    if (maybeLink) {
        NSString *urlString = maybeLink[@"href"];
        if ([urlString length] > 0) {
            urls.link = [NSURL URLWithString:urlString];
        }
    } else {
        urls.link = nil;
    }
}

@end
