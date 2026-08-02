//
//  AnymexExtensionRuntimeBridgePlugin.m
//
//  Objective-C plugin registrar for the AnymeX Extension Runtime Bridge.
//
//  This file does two things:
//  1. Registers the standard Flutter MethodChannel for diagnostic and
//     control operations (getPlatformVersion, getJVMStatus, etc.)
//  2. Registers the Dart FFI symbol lookup so that Dart code can resolve
//     the @_cdecl exported Swift functions at runtime.
//
//  The Dart FFI entry points (anymex_ios_jvm_init, anymex_ios_jvm_call,
//  etc.) are exported as C symbols from the compiled binary and resolved
//  by the Dart side using DynamicLibrary.process().
//

#import "AnymexExtensionRuntimeBridgePlugin.h"

// Forward declarations of the @_cdecl Swift functions.
// These symbols are exported from SwiftAnymexExtensionRuntimeBridgePlugin.swift.
extern int32_t anymex_ios_jvm_init(const char *classpath);
extern const char *anymex_ios_jvm_call(const char *method, const char *argsJson);
extern void anymex_ios_jvm_destroy(void);
extern bool anymex_ios_jvm_is_initialized(void);
extern int32_t anymex_ios_jvm_set_cookies(const char *url, const char *cookieString);
extern int32_t anymex_ios_jvm_set_user_agent(const char *url, const char *userAgent);
extern int32_t anymex_ios_jvm_set_property(const char *key, const char *value);
extern const char *anymex_ios_jvm_get_property(const char *key);
extern const char *anymex_ios_jvm_get_last_error(void);

@implementation AnymexExtensionRuntimeBridgePlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel *channel =
        [FlutterMethodChannel methodChannelWithName:@"anymex_extension_runtime_bridge"
                                    binaryMessenger:[registrar messenger]];

    AnymexExtensionRuntimeBridgePlugin *instance =
        [[AnymexExtensionRuntimeBridgePlugin alloc] init];

    [registrar addMethodCallDelegate:instance channel:channel];

    NSLog(@"[AnymeXBridge] iOS plugin registered. FFI symbols available:");
    NSLog(@"[AnymeXBridge]   anymex_ios_jvm_init");
    NSLog(@"[AnymeXBridge]   anymex_ios_jvm_call");
    NSLog(@"[AnymeXBridge]   anymex_ios_jvm_destroy");
    NSLog(@"[AnymeXBridge]   anymex_ios_jvm_is_initialized");
    NSLog(@"[AnymeXBridge]   anymex_ios_jvm_set_cookies");
    NSLog(@"[AnymeXBridge]   anymex_ios_jvm_set_user_agent");
    NSLog(@"[AnymeXBridge]   anymex_ios_jvm_set_property");
    NSLog(@"[AnymeXBridge]   anymex_ios_jvm_get_property");
    NSLog(@"[AnymeXBridge]   anymex_ios_jvm_get_last_error");
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([@"getPlatformVersion" isEqualToString:call.method]) {
        NSString *version = [@"iOS " stringByAppendingString:[[UIDevice currentDevice] systemVersion]];
        result(version);
        return;
    }

    if ([@"getJVMStatus" isEqualToString:call.method]) {
        bool initialized = anymex_ios_jvm_is_initialized();
        NSMutableDictionary *status = [[NSMutableDictionary alloc] init];
        [status setObject:@"iOS" forKey:@"platform"];
        [status setObject:[[UIDevice currentDevice] systemVersion] forKey:@"osVersion"];
        [status setObject:@(initialized) forKey:@"jvmInitialized"];
        [status setObject:@"OpenJDK Zero (libjvm.a)" forKey:@"vmType"];
        [status setObject:@"ARM64" forKey:@"arch"];
        result(status);
        return;
    }

    if ([@"getJVMVersion" isEqualToString:call.method]) {
        bool initialized = anymex_ios_jvm_is_initialized();
        if (!initialized) {
            result(@"JVM not initialized");
            return;
        }
        NSString *version = @"JNI 1.8 (OpenJDK Zero VM for iOS ARM64)";
        result(version);
        return;
    }

    if ([@"initJVM" isEqualToString:call.method]) {
        NSString *classpath = call.arguments[@"classpath"];
        if (classpath == nil || [classpath length] == 0) {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"classpath argument is required"
                                       details:nil]);
            return;
        }

        int32_t ret = anymex_ios_jvm_init([classpath UTF8String]);
        if (ret == 0) {
            result(@"JVM initialized successfully");
        } else {
            NSString *errMsg = [NSString stringWithFormat:@"JNI_CreateJavaVM failed with code %d", ret];
            result([FlutterError errorWithCode:@"JVM_INIT_FAILED"
                                       message:errMsg
                                       details:nil]);
        }
        return;
    }

    if ([@"destroyJVM" isEqualToString:call.method]) {
        anymex_ios_jvm_destroy();
        result(@"JVM destroyed");
        return;
    }

    if ([@"callJvmMethod" isEqualToString:call.method]) {
        NSString *method = call.arguments[@"method"];
        NSString *argsJson = call.arguments[@"argsJson"];

        if (method == nil || [method length] == 0) {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"method argument is required"
                                       details:nil]);
            return;
        }

        NSString *jsonArg = argsJson != nil ? argsJson : @"{}";
        const char *response = anymex_ios_jvm_call([method UTF8String], [jsonArg UTF8String]);

        if (response != NULL) {
            NSString *responseStr = [NSString stringWithUTF8String:response];
            // Free the strdup'd C string that was returned by the Swift function
            free((void *)response);
            result(responseStr);
        } else {
            result([FlutterError errorWithCode:@"JVM_CALL_FAILED"
                                       message:@"JVM method returned null"
                                       details:nil]);
        }
        return;
    }

    if ([@"setCookies" isEqualToString:call.method]) {
        NSString *url = call.arguments[@"url"];
        NSString *cookieString = call.arguments[@"cookieString"];

        if (url == nil || cookieString == nil || [url length] == 0 || [cookieString length] == 0) {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"url and cookieString are required"
                                       details:nil]);
            return;
        }

        int32_t ret = anymex_ios_jvm_set_cookies([url UTF8String], [cookieString UTF8String]);
        if (ret == 0) {
            result(@"ok");
        } else {
            result([FlutterError errorWithCode:@"SET_COOKIES_FAILED"
                                       message:@"Failed to set cookies in JVM"
                                       details:nil]);
        }
        return;
    }

    if ([@"setUserAgent" isEqualToString:call.method]) {
        NSString *url = call.arguments[@"url"];
        NSString *userAgent = call.arguments[@"userAgent"];

        if (url == nil || userAgent == nil || [url length] == 0 || [userAgent length] == 0) {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"url and userAgent are required"
                                       details:nil]);
            return;
        }

        int32_t ret = anymex_ios_jvm_set_user_agent([url UTF8String], [userAgent UTF8String]);
        if (ret == 0) {
            result(@"ok");
        } else {
            result([FlutterError errorWithCode:@"SET_UA_FAILED"
                                       message:@"Failed to set user-agent in JVM"
                                       details:nil]);
        }
        return;
    }

    if ([@"setProperty" isEqualToString:call.method]) {
        NSString *key = call.arguments[@"key"];
        NSString *value = call.arguments[@"value"];

        if (key == nil || value == nil || [key length] == 0) {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"key and value are required"
                                       details:nil]);
            return;
        }

        int32_t ret = anymex_ios_jvm_set_property([key UTF8String], [value UTF8String]);
        result(@(ret == 0));
        return;
    }

    if ([@"getProperty" isEqualToString:call.method]) {
        NSString *key = call.arguments[@"key"];

        if (key == nil || [key length] == 0) {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"key is required"
                                       details:nil]);
            return;
        }

        const char *value = anymex_ios_jvm_get_property([key UTF8String]);
        if (value != NULL) {
            NSString *valueStr = [NSString stringWithUTF8String:value];
            free((void *)value);
            result(valueStr);
        } else {
            result(nil);
        }
        return;
    }

    if ([@"getLastError" isEqualToString:call.method]) {
        const char *error = anymex_ios_jvm_get_last_error();
        if (error != NULL) {
            NSString *errorStr = [NSString stringWithUTF8String:error];
            free((void *)error);
            result(errorStr);
        } else {
            result(nil);
        }
        return;
    }

    result(FlutterMethodNotImplemented);
}

@end
