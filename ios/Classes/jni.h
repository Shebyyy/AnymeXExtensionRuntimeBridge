/*
 * Minimal JNI header for AnymeX Extension Runtime Bridge (iOS)
 *
 * This thin header re-exports the full JNI definitions from the include/
 * directory. It exists in Classes/ so that the Objective-C plugin registrar
 * and Swift bridging header can find it without additional search paths.
 *
 * The canonical JNI definitions live in: ios/include/jni.h
 */

#ifndef CLASSES_JNI_H_INCLUDED
#define CLASSES_JNI_H_INCLUDED

#include "../include/jni.h"

#endif /* CLASSES_JNI_H_INCLUDED */
