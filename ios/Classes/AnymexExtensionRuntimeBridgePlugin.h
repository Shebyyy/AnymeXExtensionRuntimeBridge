// AnymexExtensionRuntimeBridgePlugin.h
// AnymeX Extension Runtime Bridge — iOS Plugin
//
// Objective-C header for Flutter plugin registration.
// The actual implementation lives in AnymexExtensionRuntimeBridgePlugin.swift.
//
// This header is imported by Flutter's auto-generated GeneratedPluginRegistrant.m
// so it can call +registerWithRegistrar: on the plugin class.

#import <Flutter/Flutter.h>

@interface AnymexExtensionRuntimeBridgePlugin : NSObject <FlutterPlugin>
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
@end
