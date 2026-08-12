#import "AnymexExtensionRuntimeBridgePlugin.h"

// Swift classes exposed to ObjC via the auto-generated header.
// The module name is derived from the podspec/product name.
#import <anymex_extension_runtime_bridge/anymex_extension_runtime_bridge-Swift.h>

#import <dlfcn.h>
#import <sys/mman.h>
#import <pthread.h>

// ---------------------------------------------------------------------------
// Static state shared across the plugin lifecycle
// ---------------------------------------------------------------------------
static AnymexExtensionRuntimeBridgePlugin *_sharedPlugin = nil;
static BOOL _jvmReady = NO;
static pthread_mutex_t _jvmMutex = PTHREAD_MUTEX_INITIALIZER;

@implementation AnymexExtensionRuntimeBridgePlugin {
    FlutterMethodChannel *_channel;
    JavaLauncher *_launcher;
    JniHelper *_jni;
    NSString *_javaHome;
    NSString *_bridgeJarPath;
}

#pragma mark - Registration

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel *channel =
        [FlutterMethodChannel methodChannelWithName:@"anymeXBridge"
                                    binaryMessenger:[registrar messenger]];
    AnymexExtensionRuntimeBridgePlugin *instance =
        [[AnymexExtensionRuntimeBridgePlugin alloc] initWithChannel:channel];
    [registrar addMethodCallDelegate:instance channel:channel];
    _sharedPlugin = instance;
}

- (instancetype)initWithChannel:(FlutterMethodChannel *)channel {
    self = [super init];
    if (self) {
        _channel = channel;
        _launcher = [[JavaLauncher alloc] init];
        _jni = [[JniHelper alloc] init];
    }
    return self;
}

#pragma mark - Method Call Handler

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSString *method = call.method;

    if ([method isEqualToString:@"getPlatformVersion"]) {
        NSString *version = [@"iOS " stringByAppendingString:[[UIDevice currentDevice] systemVersion]];
        result(version);
        return;
    }

    if ([method isEqualToString:@"loadAnymeXRuntimeHost"]) {
        [self handleLoadRuntime:call result:result];
        return;
    }

    if ([method isEqualToString:@"isLoaded"]) {
        result(@(_jni.isAttached));
        return;
    }

    if ([method isEqualToString:@"setCookies"]) {
        [self handleSetCookies:call result:result];
        return;
    }

    if ([method isEqualToString:@"setUserAgent"]) {
        [self handleSetUserAgent:call result:result];
        return;
    }

    if ([method isEqualToString:@"cancelRequest"]) {
        [self handleCancelRequest:call result:result];
        return;
    }

    if ([method isEqualToString:@"getImageBytes"]) {
        [self handleGetImageBytes:call result:result];
        return;
    }

    // Generic bridge method invocation
    if ([method isEqualToString:@"invokeBridgeMethod"]) {
        [self handleInvokeBridgeMethod:call result:result];
        return;
    }

    result(FlutterMethodNotImplemented);
}

#pragma mark - JVM Launch

- (void)handleLoadRuntime:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSDictionary *args = call.arguments;
    NSString *bridgePath = args[@"path"];
    NSDictionary *settings = args[@"settings"];

    if (bridgePath.length == 0) {
        result(@(NO));
        return;
    }

    // Discover the embedded JDK
    NSString *jdkHome = [JavaLauncher findJavaHome];
    if (jdkHome == nil) {
        NSLog(@"[AnymeXPlugin] OpenJDK not found in app bundle");
        result(@(NO));
        return;
    }

    _javaHome = jdkHome;
    _bridgeJarPath = bridgePath;

    NSLog(@"[AnymeXPlugin] Launching JVM from: %@", jdkHome);
    NSLog(@"[AnymeXPlugin] Bridge JAR: %@", bridgePath);

    // Reset exit override state
    [ExitOverride.shared reset];

    // Build extra JVM args from settings
    NSMutableArray<NSString *> *extraArgs = [NSMutableArray array];

    if (settings[@"proxyHost"]) {
        NSString *host = settings[@"proxyHost"];
        NSString *port = settings[@"proxyPort"] ?: @"8080";
        [extraArgs addObject:[NSString stringWithFormat:@"-Dhttp.proxyHost=%@", host]];
        [extraArgs addObject:[NSString stringWithFormat:@"-Dhttp.proxyPort=%@", port]];
        [extraArgs addObject:[NSString stringWithFormat:@"-Dhttps.proxyHost=%@", host]];
        [extraArgs addObject:[NSString stringWithFormat:@"-Dhttps.proxyPort=%@", port]];
    }

    // Launch JVM
    __weak typeof(self) weakSelf = self;
    [_launcher startJvmAsyncWithJavaHome:jdkHome
                           bridgeJarPath:bridgePath
                               extraArgs:extraArgs
                              completion:^(BOOL success) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            result(@(NO));
            return;
        }

        if (success) {
            // Try to attach to the JVM via JNI
            BOOL attached = [strongSelf->_jni attachIfNecessary];
            if (attached) {
                _jvmReady = YES;
                NSLog(@"[AnymeXPlugin] JVM launched and JNI attached successfully");

                // Initialize the bridge Java side
                [strongSelf initializeBridgeJavaSide];

                result(@(YES));
            } else {
                NSLog(@"[AnymeXPlugin] JVM started but JNI attachment failed");
                result(@(NO));
            }
        } else {
            NSLog(@"[AnymeXPlugin] JVM launch failed");
            result(@(NO));
        }
    }];
}

#pragma mark - Bridge Java-Side Init

/// After the JVM is up, call the Java-side bridge initializer to register
/// the Dart callback mechanism. The Java bridge exposes a static method that
/// we can invoke via JNI.
- (void)initializeBridgeJavaSide {
    pthread_mutex_lock(&_jvmMutex);

    JNIEnv *env = [_jni env];
    if (!env) {
        pthread_mutex_unlock(&_jvmMutex);
        NSLog(@"[AnymeXPlugin] Cannot init bridge: no JNIEnv");
        return;
    }

    // Look up the RuntimeBridge main class
    jclass bridgeClass = [_jni findClass:@"com/anymex/runtimehost/RuntimeBridge"];
    if (bridgeClass == nil) {
        NSLog(@"[AnymeXPlugin] RuntimeBridge class not found — bridge JAR may not contain it");
        [_jni exceptionClear];
        pthread_mutex_unlock(&_jvmMutex);
        return;
    }

    // Call static void init() if it exists
    jmethodID initMethod = [_jni getStaticMethod:bridgeClass
                                           name:"init"
                                        sig:"()V"];
    if (initMethod != nil) {
        [_jni callStaticVoidMethod:bridgeClass method:initMethod];
        [_jni exceptionClear];
    }

    NSLog(@"[AnymeXPlugin] Bridge Java side initialized");
    pthread_mutex_unlock(&_jvmMutex);
}

#pragma mark - Set Cookies

- (void)handleSetCookies:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSDictionary *args = call.arguments;
    NSString *url = args[@"url"];
    NSString *cookieString = args[@"cookieString"];

    if (url.length == 0 || cookieString.length == 0) {
        result(nil);
        return;
    }

    pthread_mutex_lock(&_jvmMutex);

    if (!_jvmReady || ![_jni env]) {
        pthread_mutex_unlock(&_jvmMutex);
        result(nil);
        return;
    }

    JNIEnv *env = [_jni env];
    jclass bridgeClass = [_jni findClass:@"com/anymex/runtimehost/RuntimeBridge"];
    if (bridgeClass == nil) {
        [_jni exceptionClear];
        pthread_mutex_unlock(&_jvmMutex);
        result(nil);
        return;
    }

    jmethodID method = [_jni getStaticMethod:bridgeClass
                                       name:"setCookies"
                                    sig:"(Ljava/lang/String;Ljava/lang/String;)V"];
    if (method != nil) {
        jstring jUrl = [_jni toJString:url];
        jstring jCookies = [_jni toJString:cookieString];
        [_jni callStaticVoidMethod:bridgeClass method:method, jUrl, jCookies];
        [_jni exceptionClear];
    }

    pthread_mutex_unlock(&_jvmMutex);
    result(nil);
}

#pragma mark - Set User Agent

- (void)handleSetUserAgent:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSDictionary *args = call.arguments;
    NSString *url = args[@"url"];
    NSString *userAgent = args[@"userAgent"];

    if (url.length == 0 || userAgent.length == 0) {
        result(nil);
        return;
    }

    pthread_mutex_lock(&_jvmMutex);

    if (!_jvmReady || ![_jni env]) {
        pthread_mutex_unlock(&_jvmMutex);
        result(nil);
        return;
    }

    JNIEnv *env = [_jni env];
    jclass bridgeClass = [_jni findClass:@"com/anymex/runtimehost/RuntimeBridge"];
    if (bridgeClass == nil) {
        [_jni exceptionClear];
        pthread_mutex_unlock(&_jvmMutex);
        result(nil);
        return;
    }

    jmethodID method = [_jni getStaticMethod:bridgeClass
                                       name:"setUserAgent"
                                    sig:"(Ljava/lang/String;Ljava/lang/String;)V"];
    if (method != nil) {
        jstring jUrl = [_jni toJString:url];
        jstring jUa = [_jni toJString:userAgent];
        [_jni callStaticVoidMethod:bridgeClass method:method, jUrl, jUa];
        [_jni exceptionClear];
    }

    pthread_mutex_unlock(&_jvmMutex);
    result(nil);
}

#pragma mark - Cancel Request

- (void)handleCancelRequest:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSDictionary *args = call.arguments;
    NSString *token = args[@"token"];

    if (token.length == 0) {
        result(@(NO));
        return;
    }

    pthread_mutex_lock(&_jvmMutex);

    if (!_jvmReady || ![_jni env]) {
        pthread_mutex_unlock(&_jvmMutex);
        result(@(NO));
        return;
    }

    JNIEnv *env = [_jni env];
    jclass bridgeClass = [_jni findClass:@"com/anymex/runtimehost/RuntimeBridge"];
    if (bridgeClass == nil) {
        [_jni exceptionClear];
        pthread_mutex_unlock(&_jvmMutex);
        result(@(NO));
        return;
    }

    jmethodID method = [_jni getStaticMethod:bridgeClass
                                       name:"cancelRequest"
                                    sig:"(Ljava/lang/String;)Z"];
    if (method != nil) {
        jstring jToken = [_jni toJString:token];
        jboolean cancelled = [_jni callStaticBooleanMethod:bridgeClass method:method, jToken];
        [_jni exceptionClear];
        result(@(cancelled));
    } else {
        result(@(NO));
    }

    pthread_mutex_unlock(&_jvmMutex);
}

#pragma mark - Get Image Bytes

- (void)handleGetImageBytes:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSDictionary *args = call.arguments;
    NSString *sourceId = args[@"sourceId"];
    NSNumber *isAnime = args[@"isAnime"];
    NSString *url = args[@"url"];

    if (sourceId.length == 0 || url.length == 0) {
        result(nil);
        return;
    }

    pthread_mutex_lock(&_jvmMutex);

    if (!_jvmReady || ![_jni env]) {
        pthread_mutex_unlock(&_jvmMutex);
        result(nil);
        return;
    }

    JNIEnv *env = [_jni env];
    jclass bridgeClass = [_jni findClass:@"com/anymex/runtimehost/RuntimeBridge"];
    if (bridgeClass == nil) {
        [_jni exceptionClear];
        pthread_mutex_unlock(&_jvmMutex);
        result(nil);
        return;
    }

    jmethodID method = [_jni getStaticMethod:bridgeClass
                                       name:"getImageBytes"
                                    sig:"(Ljava/lang/String;ZLjava/lang/String;)[B"];
    if (method != nil) {
        jstring jSourceId = [_jni toJString:sourceId];
        jstring jUrl = [_jni toJString:url];
        jbyteArray imageBytes = [_jni callStaticObjectMethod:bridgeClass method:method, jSourceId, (jboolean)[isAnime boolValue], jUrl];

        if (imageBytes != nil && ![_jni exceptionCheck]) {
            FlutterStandardTypedData *data = [self convertJByteArrayToFlutterData:imageBytes env:env];
            result(data);
        } else {
            [_jni exceptionClear];
            result(nil);
        }
    } else {
        result(nil);
    }

    pthread_mutex_unlock(&_jvmMutex);
}

#pragma mark - Generic Bridge Method Invocation

/// Handles the generic `invokeBridgeMethod` call used by BridgeDispatcher
/// and other high-level Dart APIs. The args dict contains:
///   - methodName: String
///   - args: List (positional arguments to the Java method)
- (void)handleInvokeBridgeMethod:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSDictionary *args = call.arguments;
    NSString *methodName = args[@"methodName"];
    NSArray *dartArgs = args[@"args"];

    if (methodName.length == 0) {
        result([FlutterError errorWithCode:@"INVALID_ARGS"
                                   message:@"methodName is required"
                                   details:nil]);
        return;
    }

    pthread_mutex_lock(&_jvmMutex);

    if (!_jvmReady || ![_jni env]) {
        pthread_mutex_unlock(&_jvmMutex);
        result([FlutterError errorWithCode:@"JVM_NOT_READY"
                                   message:@"JVM is not running"
                                   details:nil]);
        return;
    }

    JNIEnv *env = [_jni env];
    jclass bridgeClass = [_jni findClass:@"com/anymex/runtimehost/RuntimeBridge"];
    if (bridgeClass == nil) {
        [_jni exceptionClear];
        pthread_mutex_unlock(&_jvmMutex);
        result([FlutterError errorWithCode:@"CLASS_NOT_FOUND"
                                   message:@"RuntimeBridge class not found"
                                   details:nil]);
        return;
    }

    // Try to find the method with different signatures depending on arg count
    // The Java side exposes: static Object invoke(String methodName, Object... args)
    jmethodID method = [_jni getStaticMethod:bridgeClass
                                       name:"invoke"
                                    sig:"(Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/Object;"];

    if (method == nil) {
        // Fallback: try the simple dispatch method
        method = [_jni getStaticMethod:bridgeClass
                                  name:"dispatch"
                               sig:"(Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/String;"];
    }

    if (method == nil) {
        [_jni exceptionClear];
        pthread_mutex_unlock(&_jvmMutex);
        result([FlutterError errorWithCode:@"METHOD_NOT_FOUND"
                                   message:@"invoke/dispatch method not found on RuntimeBridge"
                                   details:nil]);
        return;
    }

    // Convert Dart args to Java Object array
    jstring jMethodName = [_jni toJString:methodName];
    jclass objClass = [_jni findClass:@"java/lang/Object"];
    jobjectArray jArgsArray = (jobjectArray)[_jni newObjectArray:(jint)dartArgs.count
                                                         class:objClass];
    if (jArgsArray == nil) {
        [_jni exceptionClear];
        pthread_mutex_unlock(&_jvmMutex);
        result([FlutterError errorWithCode:@"ARRAY_CREATE_FAILED"
                                   message:@"Failed to create Java Object[]"
                                   details:nil]);
        return;
    }

    for (NSUInteger i = 0; i < dartArgs.count; i++) {
        id dartArg = dartArgs[i];
        jobject jArg = [self convertDartToJavaObject:dartArg env:env];
        [_jni setObjectArrayElement:jArgsArray index:(jint)i value:jArg];
    }

    // Invoke
    jobject javaResult = [_jni callStaticObjectMethod:bridgeClass method:method, jMethodName, jArgsArray];

    if ([_jni exceptionCheck]) {
        NSString *errMsg = [self getJavaExceptionMessage:env];
        [_jni exceptionClear];
        pthread_mutex_unlock(&_jvmMutex);
        result([FlutterError errorWithCode:@"JAVA_EXCEPTION"
                                   message:errMsg ?: @"Unknown Java exception"
                                   details:nil]);
        return;
    }

    // Convert Java result back to Dart-compatible type
    id dartResult = [self convertJavaObjectToDart:javaResult env:env];

    pthread_mutex_unlock(&_jvmMutex);
    result(dartResult);
}

#pragma mark - Dart ↔ Java Type Conversion

/// Convert a jbyteArray to FlutterStandardTypedData.
- (FlutterStandardTypedData *)convertJByteArrayToFlutterData:(jbyteArray)array env:(JNIEnv *)env {
    if (array == nil) return nil;

    jsize len = [_jni getArrayLength:array];
    if (len <= 0) return [FlutterStandardTypedData typedDataWithBytes:[[NSData alloc] init]];

    jbyte *bytes = (jbyte *)[_jni getByteArrayElements:array];
    NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)len];
    [_jni releaseByteArrayElements:array bytes:bytes];

    return [FlutterStandardTypedData typedDataWithBytes:data];
}

/// Convert a Dart object (from method channel) to a Java object.
- (jobject)convertDartToJavaObject:(id)obj env:(JNIEnv *)env {
    if (obj == nil || obj == [NSNull null]) {
        return nil;
    }

    if ([obj isKindOfClass:[NSString class]]) {
        return [_jni toJString:(NSString *)obj];
    }

    if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)obj;

        // Check the exact type
        if (strcmp(num.objCType, @encode(BOOL)) == 0) {
            jclass boolClass = [_jni findClass:@"java/lang/Boolean"];
            jmethodID valueOf = [_jni getStaticMethod:boolClass name:"valueOf" sig:"(Z)Ljava/lang/Boolean;"];
            return [_jni callStaticObjectMethod:boolClass method:valueOf, (jboolean)[num boolValue]];
        }
        if (strcmp(num.objCType, @encode(int)) == 0 ||
            strcmp(num.objCType, @encode(long)) == 0 ||
            strcmp(num.objCType, @encode(short)) == 0) {
            jclass intClass = [_jni findClass:@"java/lang/Integer"];
            jmethodID valueOf = [_jni getStaticMethod:intClass name:"valueOf" sig:"(I)Ljava/lang/Integer;"];
            return [_jni callStaticObjectMethod:intClass method:valueOf, (jint)[num intValue]];
        }
        if (strcmp(num.objCType, @encode(long long)) == 0) {
            jclass longClass = [_jni findClass:@"java/lang/Long"];
            jmethodID valueOf = [_jni getStaticMethod:longClass name:"valueOf" sig:"(J)Ljava/lang/Long;"];
            return [_jni callStaticObjectMethod:longClass method:valueOf, (jlong)[num longLongValue]];
        }
        if (strcmp(num.objCType, @encode(double)) == 0 ||
            strcmp(num.objCType, @encode(float)) == 0) {
            jclass doubleClass = [_jni findClass:@"java/lang/Double"];
            jmethodID valueOf = [_jni getStaticMethod:doubleClass name:"valueOf" sig:"(D)Ljava/lang/Double;"];
            return [_jni callStaticObjectMethod:doubleClass method:valueOf, (jdouble)[num doubleValue]];
        }

        // Default: Integer
        jclass intClass = [_jni findClass:@"java/lang/Integer"];
        jmethodID valueOf = [_jni getStaticMethod:intClass name:"valueOf" sig:"(I)Ljava/lang/Integer;"];
        return [_jni callStaticObjectMethod:intClass method:valueOf, (jint)[num intValue]];
    }

    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)obj;
        jclass listClass = [_jni findClass:@"java/util/ArrayList"];
        jobject list = [_jni newObject:listClass];
        jmethodID addMethod = [_jni getMethod:listClass name:"add" sig:"(Ljava/lang/Object;)Z"];

        for (id item in arr) {
            jobject jItem = [self convertDartToJavaObject:item env:env];
            if (jItem != nil) {
                [_jni callBooleanMethod:list method:addMethod, jItem];
            }
        }
        return list;
    }

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        jclass mapClass = [_jni findClass:@"java/util/HashMap"];
        jobject map = [_jni newObject:mapClass];
        jmethodID putMethod = [_jni getMethod:mapClass name:"put" sig:"(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"];

        for (id key in dict) {
            jobject jKey = [self convertDartToJavaObject:key env:env];
            jobject jValue = [self convertDartToJavaObject:dict[key] env:env];
            if (jKey != nil && jValue != nil) {
                [_jni callObjectMethod:map method:putMethod, jKey, jValue];
            }
        }
        return map;
    }

    if ([obj isKindOfClass:[FlutterStandardTypedData class]]) {
        NSData *data = [(FlutterStandardTypedData *)obj data];
        jbyteArray byteArray = [_jni newByteArray:(jsize)data.length];
        if (byteArray != nil) {
            [_jni setByteArrayRegion:byteArray buffer:(const jbyte *)[data bytes] length:(jsize)data.length];
        }
        return byteArray;
    }

    // Fallback: convert to string
    return [_jni toJString:[obj description]];
}

/// Convert a Java object back to a Dart-compatible type.
- (id)convertJavaObjectToDart:(jobject)obj env:(JNIEnv *)env {
    if (obj == nil) return nil;

    // Check if it's a String
    jclass stringClass = [_jni findClass:@"java/lang/String"];
    if ([_jni isInstanceOf:obj class:stringClass]) {
        return [_jni fromJString:(jstring)obj];
    }

    // Check if it's a Number
    jclass numberClass = [_jni findClass:@"java/lang/Number"];
    if ([_jni isInstanceOf:obj class:numberClass]) {
        // Try to get as various numeric types
        jclass intClass = [_jni findClass:@"java/lang/Integer"];
        jclass longClass = [_jni findClass:@"java/lang/Long"];
        jclass doubleClass = [_jni findClass:@"java/lang/Double"];
        jclass boolClass = [_jni findClass:@"java/lang/Boolean"];

        if ([_jni isInstanceOf:obj class:boolClass]) {
            jmethodID boolValue = [_jni getMethod:boolClass name:"booleanValue" sig:"()Z"];
            jboolean val = [_jni callBooleanMethod:obj method:boolValue];
            return @(val);
        }

        if ([_jni isInstanceOf:obj class:intClass]) {
            jmethodID intValue = [_jni getMethod:intClass name:"intValue" sig:"()I"];
            jint val = [_jni callIntMethod:obj method:intValue];
            return @(val);
        }

        if ([_jni isInstanceOf:obj class:longClass]) {
            jmethodID longValue = [_jni getMethod:longClass name:"longValue" sig:"()J"];
            jlong val = [_jni callLongMethod:obj method:longValue];
            return @(val);
        }

        if ([_jni isInstanceOf:obj class:doubleClass]) {
            jmethodID doubleValue = [_jni getMethod:doubleClass name:"doubleValue" sig:"()D"];
            jdouble val = [_jni callDoubleMethod:obj method:doubleValue];
            return @(val);
        }

        // Generic number fallback
        jmethodID doubleValue2 = [_jni getMethod:numberClass name:"doubleValue" sig:"()D"];
        jdouble val = [_jni callDoubleMethod:obj method:doubleValue2];
        return @(val);
    }

    // Check if it's a Boolean
    jclass boolClass = [_jni findClass:@"java/lang/Boolean"];
    if ([_jni isInstanceOf:obj class:boolClass]) {
        jmethodID boolValue = [_jni getMethod:boolClass name:"booleanValue" sig:"()Z"];
        jboolean val = [_jni callBooleanMethod:obj method:boolValue];
        return @(val);
    }

    // Check if it's a List/Collection
    jclass listClass = [_jni findClass:@"java/util/List"];
    if ([_jni isInstanceOf:obj class:listClass]) {
        jmethodID sizeMethod = [_jni getMethod:listClass name:"size" sig:"()I"];
        jmethodID getMethod = [_jni getMethod:listClass name:"get" sig:"(I)Ljava/lang/Object;"];

        jint size = [_jni callIntMethod:obj method:sizeMethod];
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:(NSUInteger)size];

        for (jint i = 0; i < size; i++) {
            jobject element = [_jni callObjectMethod:obj method:getMethod, i];
            id dartElement = [self convertJavaObjectToDart:element env:env];
            if (dartElement != nil) {
                [arr addObject:dartElement];
            } else {
                [arr addObject:[NSNull null]];
            }
        }
        return arr;
    }

    // Check if it's a Map
    jclass mapClass = [_jni findClass:@"java/util/Map"];
    if ([_jni isInstanceOf:obj class:mapClass]) {
        jmethodID entrySetMethod = [_jni getMethod:mapClass name:"entrySet" sig:"()Ljava/util/Set;"];
        jobject entrySet = [_jni callObjectMethod:obj method:entrySetMethod];

        jclass setClass = [_jni findClass:@"java/util/Set"];
        jmethodID iteratorMethod = [_jni getMethod:setClass name:"iterator" sig:"()Ljava/util/Iterator;"];
        jobject iterator = [_jni callObjectMethod:entrySet method:iteratorMethod];

        jclass iteratorClass = [_jni findClass:@"java/util/Iterator"];
        jmethodID hasNextMethod = [_jni getMethod:iteratorClass name:"hasNext" sig:"()Z"];
        jmethodID nextMethod = [_jni getMethod:iteratorClass name:"next" sig:"()Ljava/lang/Object;"];

        jclass entryClass = [_jni findClass:@"java/util/Map$Entry"];
        jmethodID getKeyMethod = [_jni getMethod:entryClass name:"getKey" sig:"()Ljava/lang/Object;"];
        jmethodID getValueMethod = [_jni getMethod:entryClass name:"getValue" sig:"()Ljava/lang/Object;"];

        NSMutableDictionary *dict = [NSMutableDictionary dictionary];

        while ([_jni callBooleanMethod:iterator method:hasNextMethod]) {
            jobject entry = [_jni callObjectMethod:iterator method:nextMethod];
            jobject key = [_jni callObjectMethod:entry method:getKeyMethod];
            jobject value = [_jni callObjectMethod:entry method:getValueMethod];

            id dartKey = [self convertJavaObjectToDart:key env:env];
            id dartValue = [self convertJavaObjectToDart:value env:env];

            if (dartKey != nil) {
                dict[dartKey] = dartValue ?: [NSNull null];
            }
        }

        return dict;
    }

    // Check if it's a byte array
    if ([_jni isByteArray:obj]) {
        return [self convertJByteArrayToFlutterData:(jbyteArray)obj env:env];
    }

    // Fallback: toString
    jclass objClass = [_jni findClass:@"java/lang/Object"];
    jmethodID toString = [_jni getMethod:objClass name:"toString" sig:"()Ljava/lang/String;"];
    jobject strObj = [_jni callObjectMethod:obj method:toString];
    if (strObj != nil) {
        return [_jni fromJString:(jstring)strObj];
    }

    return [NSNull null];
}

/// Get the message from a pending Java exception.
- (NSString *)getJavaExceptionMessage:(JNIEnv *)env {
    jthrowable exception = [_jni exceptionOccurred];
    if (exception == nil) return @"Unknown error";

    jclass throwableClass = [_jni findClass:@"java/lang/Throwable"];
    jmethodID getMessage = [_jni getMethod:throwableClass name:"getMessage" sig:"()Ljava/lang/String;"];
    jmethodID toString2 = [_jni getMethod:throwableClass name:"toString" sig:"()Ljava/lang/String;"];

    jobject msgObj = [_jni callObjectMethod:exception method:getMessage];
    NSString *message = nil;

    if (msgObj != nil) {
        message = [_jni fromJString:(jstring)msgObj];
    } else {
        jobject strObj = [_jni callObjectMethod:exception method:toString2];
        if (strObj != nil) {
            message = [_jni fromJString:(jstring)strObj];
        }
    }

    [_jni exceptionClear];
    return message ?: @"Unknown Java exception";
}

#pragma mark - Cleanup

- (void)dealloc {
    pthread_mutex_lock(&_jvmMutex);
    _jvmReady = NO;
    [_jni detach];
    pthread_mutex_unlock(&_jvmMutex);
}

@end
