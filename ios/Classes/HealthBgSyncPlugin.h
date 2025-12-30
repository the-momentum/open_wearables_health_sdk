//
//  HealthBgSyncPlugin.h
//  health_bg_sync
//
//  Created for Flutter plugin registration
//

#import <Flutter/Flutter.h>

// Forward declaration - actual implementation is in Swift
@protocol FlutterPluginRegistrar;
@interface HealthBgSyncPlugin : NSObject<FlutterPlugin>
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
@end

