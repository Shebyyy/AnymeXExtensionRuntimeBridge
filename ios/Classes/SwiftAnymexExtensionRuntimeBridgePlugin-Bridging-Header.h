//
//  SwiftAnymexExtensionRuntimeBridgePlugin-Bridging-Header.h
//
//  Bridging header for the AnymeX Extension Runtime Bridge iOS plugin.
//  This header imports the JNI C definitions so that the Swift plugin
//  code can call JNI functions (JNI_CreateJavaVM, etc.) and use JNI types
//  (JavaVM, JNIEnv, jstring, etc.) directly.
//

#import "jni.h"
