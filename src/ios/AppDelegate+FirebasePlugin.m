#import "AppDelegate+FirebasePlugin.h"
#import "FirebasePlugin.h"
#import "Firebase.h"
#import <objc/runtime.h>


@import UserNotifications;
@import FirebaseFirestore;

// Implement UNUserNotificationCenterDelegate to receive display notification via APNS for devices running iOS 10 and above.
// Implement FIRMessagingDelegate to receive data message via FCM for devices running iOS 10 and above.
@interface AppDelegate () <UNUserNotificationCenterDelegate, FIRMessagingDelegate>
@end

#define kApplicationInBackgroundKey @"applicationInBackground"

@implementation AppDelegate (FirebasePlugin)

static AppDelegate* instance;
static id <UNUserNotificationCenterDelegate> _previousDelegate;

+ (AppDelegate*) instance {
    return instance;
}

static NSDictionary* mutableUserInfo;
static FIRAuthStateDidChangeListenerHandle authStateChangeListener;
static bool authStateChangeListenerInitialized = false;

+ (void)load {
    Method original = class_getInstanceMethod(self, @selector(application:didFinishLaunchingWithOptions:));
    Method swizzled = class_getInstanceMethod(self, @selector(application:swizzledDidFinishLaunchingWithOptions:));
    method_exchangeImplementations(original, swizzled);
}

- (void)setApplicationInBackground:(NSNumber *)applicationInBackground {
    objc_setAssociatedObject(self, kApplicationInBackgroundKey, applicationInBackground, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSNumber *)applicationInBackground {
    return objc_getAssociatedObject(self, kApplicationInBackgroundKey);
}

- (BOOL)application:(UIApplication *)application swizzledDidFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self application:application swizzledDidFinishLaunchingWithOptions:launchOptions];
   
    @try{
        instance = self;
     
        bool isFirebaseInitializedWithPlist = false;
        if(![FIRApp defaultApp]) {
            // get GoogleService-Info.plist file path
            NSString *filePath = [[NSBundle mainBundle] pathForResource:@"GoogleService-Info" ofType:@"plist"];
            
            // if file is successfully found, use it
            if(filePath){
                [FirebasePlugin.firebasePlugin _logMessage:@"GoogleService-Info.plist found, setup: [FIRApp configureWithOptions]"];
                // create firebase configure options passing .plist as content
                FIROptions *options = [[FIROptions alloc] initWithContentsOfFile:filePath];

                // configure FIRApp with options
                [FIRApp configureWithOptions:options];
                
                isFirebaseInitializedWithPlist = true;
            }else{
                // no .plist found, try default App
                [FirebasePlugin.firebasePlugin _logError:@"GoogleService-Info.plist NOT FOUND, setup: [FIRApp defaultApp]"];
                [FIRApp configure];
            }
        }else{
            // Firebase SDK has already been initialised:
            // Assume that another call (probably from another plugin) did so with the plist
            isFirebaseInitializedWithPlist = true;
        }
    
        // Set UNUserNotificationCenter delegate
        if ([UNUserNotificationCenter currentNotificationCenter].delegate != nil) {
            _previousDelegate = [UNUserNotificationCenter currentNotificationCenter].delegate;
        }
        [UNUserNotificationCenter currentNotificationCenter].delegate = self;

        // Set FCM messaging delegate
        [FIRMessaging messaging].delegate = self;
        
        // Setup Firestore
        [FirebasePlugin setFirestore:[FIRFirestore firestore]];
        
        // Setup Google SignIn
        [GIDSignIn sharedInstance].clientID = [FIRApp defaultApp].options.clientID;
        [GIDSignIn sharedInstance].delegate = self;
        
        authStateChangeListener = [[FIRAuth auth] addAuthStateDidChangeListener:^(FIRAuth * _Nonnull auth, FIRUser * _Nullable user) {
            @try {
                if(!authStateChangeListenerInitialized){
                    authStateChangeListenerInitialized = true;
                }else{
                    [FirebasePlugin.firebasePlugin executeGlobalJavascript:[NSString stringWithFormat:@"FirebasePlugin._onAuthStateChange(%@)", (user != nil ? @"true": @"false")]];
                }
            }@catch (NSException *exception) {
                [FirebasePlugin.firebasePlugin handlePluginExceptionWithoutContext:exception];
            }
        }];


        self.applicationInBackground = @(YES);
       
    }@catch (NSException *exception) {
        [FirebasePlugin.firebasePlugin handlePluginExceptionWithoutContext:exception];
    }

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    self.applicationInBackground = @(NO);
    [FirebasePlugin.firebasePlugin _logMessage:@"Enter foreground"];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    self.applicationInBackground = @(YES);
    [FirebasePlugin.firebasePlugin _logMessage:@"Enter background"];
}

# pragma mark - Google SignIn
- (void)signIn:(GIDSignIn *)signIn
didSignInForUser:(GIDGoogleUser *)user
     withError:(NSError *)error {
    @try{
        CDVPluginResult* pluginResult;
        if (error == nil) {
            GIDAuthentication *authentication = user.authentication;
            FIRAuthCredential *credential =
            [FIRGoogleAuthProvider credentialWithIDToken:authentication.idToken
                                           accessToken:authentication.accessToken];
            
            NSNumber* key = [[FirebasePlugin firebasePlugin] saveAuthCredential:credential];
            NSMutableDictionary* result = [[NSMutableDictionary alloc] init];
            [result setValue:@"true" forKey:@"instantVerification"];
            [result setValue:key forKey:@"id"];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result];
        } else {
          pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.description];
        }
        if ([FirebasePlugin firebasePlugin].googleSignInCallbackId != nil) {
            [[FirebasePlugin firebasePlugin].commandDelegate sendPluginResult:pluginResult callbackId:[FirebasePlugin firebasePlugin].googleSignInCallbackId];
        }
    }@catch (NSException *exception) {
        [FirebasePlugin.firebasePlugin handlePluginExceptionWithoutContext:exception];
    }
}

- (void)signIn:(GIDSignIn *)signIn
didDisconnectWithUser:(GIDGoogleUser *)user
     withError:(NSError *)error {
    NSString* msg = @"Google SignIn delegate: didDisconnectWithUser";
    if(error != nil){
        [FirebasePlugin.firebasePlugin _logError:[NSString stringWithFormat:@"%@: %@", msg, error]];
    }else{
        [FirebasePlugin.firebasePlugin _logMessage:msg];
    }
}

# pragma mark - FIRMessagingDelegate
- (void)messaging:(FIRMessaging *)messaging didReceiveRegistrationToken:(NSString *)fcmToken {
    @try{
        [FirebasePlugin.firebasePlugin _logMessage:[NSString stringWithFormat:@"didReceiveRegistrationToken: %@", fcmToken]];
        [FirebasePlugin.firebasePlugin sendToken:fcmToken];
    }@catch (NSException *exception) {
        [FirebasePlugin.firebasePlugin handlePluginExceptionWithoutContext:exception];
    }
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    [FIRMessaging messaging].APNSToken = deviceToken;
    [FirebasePlugin.firebasePlugin _logMessage:[NSString stringWithFormat:@"didRegisterForRemoteNotificationsWithDeviceToken: %@", deviceToken]];
    [FirebasePlugin.firebasePlugin sendApnsToken:[FirebasePlugin.firebasePlugin hexadecimalStringFromData:deviceToken]];
}
- (void)logRemoteMessage:(NSString*)customerId :(NSString*)message :(NSString*)url :(NSString*)auditLogId
{

        NSString *post = [NSString stringWithFormat:@"customerId=%@&message=%@&isIos=true&AuditLogId=%@", customerId, message, auditLogId];
        NSData *postData = [post dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
        NSString *postLength = [NSString stringWithFormat:@"%lu", (unsigned long)[postData length]];
        NSString *urlForHttp = [NSString stringWithFormat:@"%@",url];
         NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
         [request setURL:[NSURL URLWithString:urlForHttp]];
         [request setHTTPMethod:@"POST"];
         [request setValue:postLength forHTTPHeaderField:@"Content-Length"];
         [request setHTTPBody:postData];
         
         NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
         [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
             NSString *requestReply = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
             NSLog(@"Request reply: %@", requestReply);
             if([requestReply length] == 0)
             {
                 NSMutableDictionary* userInfo = [[NSMutableDictionary alloc] init];
                 NSString *errorString = [NSString stringWithFormat:@"Error in logRemoteMessage, customerId: %@, message: %@, auditLogId: %@", customerId, message, auditLogId];
                 NSError *error = [NSError errorWithDomain:errorString  code:0 userInfo:userInfo];
                 [[FIRCrashlytics crashlytics] recordError:error];
             }
         }] resume];
 
}
//Tells the app that a remote notification arrived that indicates there is data to be fetched.
// Called when a message arrives in the foreground and remote notifications permission has been granted
- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
    fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler {
  
    @try{
        //[self logRemoteMessage:@"488919":@"Test background Notification":@"https://dmsweb.conveyor.cloud/api/settings/CreateRemoteMessageRecivedLog":@"123"];
     
        [[FIRMessaging messaging] appDidReceiveMessage:userInfo];
        mutableUserInfo = [userInfo mutableCopy];
        NSDictionary* aps = [mutableUserInfo objectForKey:@"aps"];
        // Remote notification variables for a silent cutoff date update
        NSString* newCutoffDate1 = [mutableUserInfo objectForKey:@"newCutoffDate1"];
        NSString* newCutoffDate2 = [mutableUserInfo objectForKey:@"newCutoffDate2"];
        
        NSString* customerId = [mutableUserInfo objectForKey:@"CustomerID"];
        NSString* serverTimeZone = [mutableUserInfo objectForKey:@"serverTimeZone"];
        NSString* messageBody = [mutableUserInfo objectForKey:@"body"];
        NSString* websiteUrl = [mutableUserInfo objectForKey:@"websiteUrl"];
        NSString* auditLogId = [mutableUserInfo objectForKey:@"AuditLogId"];
        if(newCutoffDate1 == nil){
          
            [self logRemoteMessage:customerId:messageBody:websiteUrl:auditLogId];
        }
        bool isContentAvailable = false;
        if([aps objectForKey:@"alert"] != nil){
            @try
                 {
                     isContentAvailable = [[aps objectForKey:@"content-available"] isEqualToNumber:[NSNumber numberWithInt:1]];
                 }
                 @catch(id anException) {
                    // ignore
                 }
            [mutableUserInfo setValue:@"notification" forKey:@"messageType"];
            NSString* tap;
            if([self.applicationInBackground isEqual:[NSNumber numberWithBool:YES]] && !isContentAvailable){
                tap = @"background";
            }
            [mutableUserInfo setValue:tap forKey:@"tap"];
        }else{
            [mutableUserInfo setValue:@"data" forKey:@"messageType"];
        }
        if(newCutoffDate1 != nil && customerId != nil){
            
            NSDateFormatter *dateFormatter = [NSDateFormatter new];
            [dateFormatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
            [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"];
            NSTimeZone *timeZone = [NSTimeZone timeZoneWithName: serverTimeZone];
            [dateFormatter setTimeZone:timeZone];
            
            // Next cutoff date and the after that to incase the first date is already passed when set to the frequencyNumber
            NSDate* newCutoffUpdateDate1 = [dateFormatter dateFromString:newCutoffDate1];
            newCutoffDate1 = [dateFormatter stringFromDate: newCutoffUpdateDate1];
            NSDate* newCutoffUpdateDate2 = [dateFormatter dateFromString:newCutoffDate2];
            newCutoffDate2 = [dateFormatter stringFromDate: newCutoffUpdateDate2];
            
            // Loop through the scheduled notifications on this device and match the customer id and old cutoff date to change the localnotifcation
            [[UNUserNotificationCenter currentNotificationCenter] getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *requests){
                [FirebasePlugin.firebasePlugin _logMessage:[NSString stringWithFormat:@"requests: %@", requests]];
                for (int i=0; i<[requests count]; i++)
                {
                    // Notification we are looking at
                    UNNotificationRequest* scheduledNotification = [requests objectAtIndex:i];
                    NSDictionary *userInfoCurrent = scheduledNotification.content.userInfo;
                    mutableUserInfo = [userInfoCurrent mutableCopy];
                    NSString* firstNotificationData =[mutableUserInfo objectForKey:@"data"];
                    NSError *jsonError;
                    NSData *objectData = [firstNotificationData dataUsingEncoding:NSUTF8StringEncoding];
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:objectData
                                                          options:NSJSONReadingMutableContainers
                                                            error:&jsonError];
                    
                    NSString* SHCutOffDateStr =[json objectForKey:@"cutOffDate"]; // old date we are looking to match frequencyNumber
                    [dateFormatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
                    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"];
                    NSTimeZone *timeZone = [NSTimeZone timeZoneWithName: serverTimeZone];
                    [dateFormatter setTimeZone:timeZone];
                    NSDate* SHCutOffDate = [dateFormatter dateFromString:SHCutOffDateStr];
                    SHCutOffDateStr = [dateFormatter stringFromDate: SHCutOffDate];
                    // Scheduled notification variables
                    NSNumber *SHFrequencyNumber  =[json objectForKey:@"frequencyNumber"];
                    NSString* SHFrequencyName  =[json objectForKey:@"frequencyName"];
                    NSString* SHCustomerId  =[json objectForKey:@"customerId"];
                    NSNumber* SHOrderNumber  =[json objectForKey:@"orderNumber"];
                    NSString* SHNotificationDate  =[json objectForKey:@"notificationDate"];
                    NSString* SHNotificationLocalStorageKey  =[json objectForKey:@"notificationLocalStorageKey"];
                    NSString* SHNotificationTimeZoneKey  =[json objectForKey:@"serverTimeZone"];
                  
                    // For now, we are dealing with a single recurring local notification update so we only need to check if this notifications customer id matches the push notifications customer id
                    if ([SHCustomerId isEqualToString:customerId] && ![newCutoffDate1 isEqualToString:SHCutOffDateStr])
                    {
                       
                        int scheduledNotificationId = [scheduledNotification.identifier intValue]; // id we are looking to match
                      
                        __block NSDate *newCutoffDate = nil;
                        __block NSDate *newFireDate = nil;
                        // Build new cutoff notification
                        // Calculate new fire date with with SH frequency Number and newCutoffDate

                        NSDate *newFireDate1 = [newCutoffUpdateDate1 dateByAddingTimeInterval:-3600*SHFrequencyNumber.intValue];
                        NSDate *newFireDate2 = [newCutoffUpdateDate2 dateByAddingTimeInterval:-3600*SHFrequencyNumber.intValue];
                        NSDate *now = [NSDate date];
                      
                        if ([now compare:newFireDate1] == NSOrderedAscending) {
                            newFireDate = newFireDate1;
                            newCutoffDate = newCutoffUpdateDate1;
                        }else
                        {
                            newFireDate = newFireDate2;
                            newCutoffDate = newCutoffUpdateDate2;
                            
                        }
                        // testing
                       // newFireDate = [now dateByAddingTimeInterval:60];
                       // newCutoffDate = [now dateByAddingTimeInterval:86520];
                        [FirebasePlugin.firebasePlugin _logMessage:[NSString stringWithFormat:@"Setting new fire date: %@", newFireDate]];
                        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
                        content.title = @"Delivery Change Cut-Off";
                        
                        NSString* NewNotificationText = @"As of ";
                        NSString* NewNotificationHourText = @"hours";
                        if([SHFrequencyNumber intValue] == 1)
                        {
                            NewNotificationHourText =@"hour";
                        }
                    
                        [dateFormatter setDateFormat:@"MM-dd h:mm a"];
                        NSTimeZone *timeZone = [NSTimeZone timeZoneWithName: serverTimeZone];
                        [dateFormatter setTimeZone:timeZone];
                        NSString* NewNotificationTimeStamp = [dateFormatter stringFromDate: newFireDate];
                        
                        NewNotificationText = [NewNotificationText stringByAppendingString:NewNotificationTimeStamp];
                       NewNotificationText = [NewNotificationText stringByAppendingString:@", the cut-off time to change your next delivery is "];
                       NewNotificationText = [NewNotificationText stringByAppendingString:[NSString stringWithFormat:@"%@",SHFrequencyNumber]];
                       NewNotificationText = [NewNotificationText stringByAppendingString:@" "];
                       NewNotificationText = [NewNotificationText stringByAppendingString:NewNotificationHourText];
                       NewNotificationText = [NewNotificationText stringByAppendingString:@" away, on "];
                        
                        [dateFormatter setDateFormat:@"MM-dd"];
                        NSString* NewNotificationCutoffDateStr1 = [dateFormatter stringFromDate: newCutoffDate];
                        NewNotificationText = [NewNotificationText stringByAppendingString:NewNotificationCutoffDateStr1];
                        NewNotificationText = [NewNotificationText stringByAppendingString:@" at "];
                        
                        [dateFormatter setDateFormat:@"h:mm a"];
                        NSString* NewNotificationCutoffDateStr2 = [dateFormatter stringFromDate:newCutoffDate];
                        NewNotificationText = [NewNotificationText stringByAppendingString:NewNotificationCutoffDateStr2];
                        content.body = NewNotificationText;
                     
                        NSMutableDictionary *newNotification = [[NSMutableDictionary alloc]init]; // this is the first layer of the notification that is being used in local notifications plugin
                        NSMutableDictionary *newNotificationData = [[NSMutableDictionary alloc]init]; // data layer
                        NSMutableDictionary *newNotificationTriggerType = [[NSMutableDictionary alloc]init]; // trigger layer
                        // Set json data for local notification
            
                        [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"];
                        [dateFormatter setTimeZone:timeZone];
                        NSString* NewNotificationCutoffStr = [dateFormatter stringFromDate: now];
                        //Set Notification Data
                        [newNotificationData setValue:NewNotificationCutoffStr forKey:@"cutOffDate"];
                        // Data that stays the same
                        [newNotificationData setValue:SHCustomerId forKey:@"customerId"];
                        [newNotificationData setValue:SHFrequencyNumber forKey:@"frequencyNumber"];
                        [newNotificationData setValue:SHFrequencyName forKey:@"frequencyName"];
                        [newNotificationData setValue:SHOrderNumber forKey:@"orderNumber"];
                        [newNotificationData setValue:SHNotificationLocalStorageKey forKey:@"notificationLocalStorageKey"];
                        
                        [dateFormatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
                        [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"];
                        NSString* newFireDateStr = [dateFormatter stringFromDate: SHCutOffDate];
                        [newNotificationData setValue:newFireDateStr forKey:@"notificationDate"];
                        
                        [newNotificationData setValue:SHNotificationTimeZoneKey forKey:@"serverTimeZone"];
                        [newNotificationData setValue:@"Cutoff" forKey:@"title"];

                        [newNotificationData setValue:[dateFormatter stringFromDate:[NSDate date]] forKey:@"timeStamp"];
                        //Set Trigger Type
                        [newNotificationTriggerType setValue:@"updateCutoffDates" forKey:@"type"];
                        //Set first layer notification info
                        NSError *error;
                        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:newNotificationData // Here you can pass array or dictionary
                                            options:NSJSONWritingPrettyPrinted
                                            error:&error];
                        NSString *jsonString;
                        if (jsonData) {
                            jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                            [newNotification setObject:jsonString forKey:@"data"];
                        } else {
                            NSLog(@"Got an error: %@", error);
                            jsonString = @"";
                        }
                        
                        [newNotification setValue: [NSNumber numberWithInt:1] forKey:@"priority"]; // cordova local notification needs this set to one to show in foreground
                       [newNotification setValue: [NSNumber numberWithInt:true] forKey:@"foreground"];
                       [newNotification setValue: [NSNumber numberWithInt:true] forKey:@"lockscreen"];
                        [newNotification setObject:newNotificationTriggerType forKey:@"trigger"];
                        NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
                        [newNotification setValue:[numberFormatter numberFromString:scheduledNotification.identifier] forKey:@"id"];
                        [newNotification setValue: content.body forKey:@"text"];
                        [newNotification setValue: content.title forKey:@"title"];
                        content.userInfo = newNotification;
                        content.sound = [UNNotificationSound defaultSound];
                        [FirebasePlugin.firebasePlugin _logMessage:[NSString stringWithFormat:@"Set new notification user info: %@", content.userInfo]];
                        NSDateComponents *triggerDate = [[NSCalendar currentCalendar]
                                                                components:NSCalendarUnitYear +
                                                                NSCalendarUnitMonth + NSCalendarUnitDay +
                                                                NSCalendarUnitHour + NSCalendarUnitMinute +
                                                                NSCalendarUnitSecond fromDate:newFireDate];
                        UNCalendarNotificationTrigger *trigger = [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:triggerDate repeats:YES];
                        [FirebasePlugin.firebasePlugin _logMessage:[NSString stringWithFormat:@"Setting new trigger: %@", trigger]];
                        [FirebasePlugin.firebasePlugin _logMessage:[NSString stringWithFormat:@"Setting new triggerDate: %@", triggerDate]];
                        UNNotificationRequest *notification = [UNNotificationRequest requestWithIdentifier:scheduledNotification.identifier content:content trigger:trigger];
                        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
                        //Cancelling the specific local notification
                        [[UNUserNotificationCenter currentNotificationCenter]removePendingNotificationRequestsWithIdentifiers:@[scheduledNotification.identifier]];
                               [center addNotificationRequest:notification withCompletionHandler:^(NSError * _Nullable error) {
                                   if (error != nil) {
                                       NSLog(@"Something went wrong: %@",error);
                                   }
                               }];
                    }
                }
                
      
            }];
        }
     
        [FirebasePlugin.firebasePlugin _logMessage:[NSString stringWithFormat:@"didReceiveRemoteNotification: %@", mutableUserInfo]];
        
        UIApplication *app = [UIApplication sharedApplication];
      
        
        completionHandler(UIBackgroundFetchResultNewData);
        if([self.applicationInBackground isEqual:[NSNumber numberWithBool:YES]] && isContentAvailable){
            [FirebasePlugin.firebasePlugin _logError:@"didReceiveRemoteNotification: omitting foreground notification as content-available:1 so system notification will be shown"];
        }else{
            [self processMessageForForegroundNotification:mutableUserInfo];
        }
        if([self.applicationInBackground isEqual:[NSNumber numberWithBool:YES]] || !isContentAvailable){
            
            [FirebasePlugin.firebasePlugin sendNotification:mutableUserInfo];
        }
       
      
    }@catch (NSException *exception) {
        [FirebasePlugin.firebasePlugin handlePluginExceptionWithoutContext:exception];
    }
}

// Scans a message for keys which indicate a notification should be shown.
// If found, extracts relevant keys and uses then to display a local notification
-(void)processMessageForForegroundNotification:(NSDictionary*)messageData {
    bool showForegroundNotification = [messageData objectForKey:@"notification_foreground"];
    if(!showForegroundNotification){
        return;
    }
    
    NSString* title = nil;
    NSString* body = nil;
    NSString* sound = nil;
    NSNumber* badge = nil;
    
    // Extract APNS notification keys
    NSDictionary* aps = [messageData objectForKey:@"aps"];
    if([aps objectForKey:@"alert"] != nil){
        NSDictionary* alert = [aps objectForKey:@"alert"];
        if([alert objectForKey:@"title"] != nil){
            title = [alert objectForKey:@"title"];
        }
        if([alert objectForKey:@"body"] != nil){
            body = [alert objectForKey:@"body"];
        }
        if([aps objectForKey:@"sound"] != nil){
            sound = [aps objectForKey:@"sound"];
        }
        if([aps objectForKey:@"badge"] != nil){
            badge = [aps objectForKey:@"badge"];
        }
    }
    
    // Extract data notification keys
    if([messageData objectForKey:@"notification_title"] != nil){
        title = [messageData objectForKey:@"notification_title"];
    }
    if([messageData objectForKey:@"notification_body"] != nil){
        body = [messageData objectForKey:@"notification_body"];
    }
    if([messageData objectForKey:@"notification_ios_sound"] != nil){
        sound = [messageData objectForKey:@"notification_ios_sound"];
    }
    if([messageData objectForKey:@"notification_ios_badge"] != nil){
        badge = [messageData objectForKey:@"notification_ios_badge"];
    }
   
    if(title == nil || body == nil){
        return;
    }
    
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
        @try{
            if (settings.alertSetting == UNNotificationSettingEnabled) {
                UNMutableNotificationContent *objNotificationContent = [[UNMutableNotificationContent alloc] init];
                objNotificationContent.title = [NSString localizedUserNotificationStringForKey:title arguments:nil];
                objNotificationContent.body = [NSString localizedUserNotificationStringForKey:body arguments:nil];
                
                NSDictionary* alert = [[NSDictionary alloc] initWithObjectsAndKeys:
                                       title, @"title",
                                       body, @"body"
                                       , nil];
                NSMutableDictionary* aps = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                                     alert, @"alert",
                                     nil];
                
                if(![sound isKindOfClass:[NSString class]] || [sound isEqualToString:@"default"]){
                    objNotificationContent.sound = [UNNotificationSound defaultSound];
                    [aps setValue:sound forKey:@"sound"];
                }else if(sound != nil){
                    objNotificationContent.sound = [UNNotificationSound soundNamed:sound];
                    [aps setValue:sound forKey:@"sound"];
                }
                
                if(badge != nil){
                    [aps setValue:badge forKey:@"badge"];
                }
                
                NSString* messageType = @"data";
                if([mutableUserInfo objectForKey:@"messageType"] != nil){
                    messageType = [mutableUserInfo objectForKey:@"messageType"];
                }
                
                NSDictionary* userInfo = [[NSDictionary alloc] initWithObjectsAndKeys:
                                          @"true", @"notification_foreground",
                                          messageType, @"messageType",
                                          aps, @"aps"
                                          , nil];
                
                objNotificationContent.userInfo = userInfo;
                
                UNTimeIntervalNotificationTrigger *trigger =  [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1f repeats:NO];
                UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"local_notification" content:objNotificationContent trigger:trigger];
                [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                    if (!error) {
                        [FirebasePlugin.firebasePlugin _logMessage:@"Local Notification succeeded"];
                    } else {
                        [FirebasePlugin.firebasePlugin _logError:[NSString stringWithFormat:@"Local Notification failed: %@", error.description]];
                    }
                }];
            }else{
                [FirebasePlugin.firebasePlugin _logError:@"processMessageForForegroundNotification: cannot show notification as permission denied"];
            }
        }@catch (NSException *exception) {
            [FirebasePlugin.firebasePlugin handlePluginExceptionWithoutContext:exception];
        }
    }];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    [FirebasePlugin.firebasePlugin _logError:[NSString stringWithFormat:@"didFailToRegisterForRemoteNotificationsWithError: %@", error.description]];
}

// Asks the delegate how to handle a notification that arrived while the app was running in the foreground
// Called when an APS notification arrives when app is in foreground
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    
    @try{

        if (![notification.request.trigger isKindOfClass:UNPushNotificationTrigger.class] && ![notification.request.trigger isKindOfClass:UNTimeIntervalNotificationTrigger.class]){
            if (_previousDelegate) {
                // bubbling notification
                [_previousDelegate userNotificationCenter:center
                          willPresentNotification:notification
                            withCompletionHandler:completionHandler];
                return;
            } else {
                [FirebasePlugin.firebasePlugin _logError:@"willPresentNotification: aborting as not a supported UNNotificationTrigger"];
                return;
            }
        }
        
        [[FIRMessaging messaging] appDidReceiveMessage:notification.request.content.userInfo];
        
        mutableUserInfo = [notification.request.content.userInfo mutableCopy];
        
        NSString* messageType = [mutableUserInfo objectForKey:@"messageType"];
        if(![messageType isEqualToString:@"data"]){
            [mutableUserInfo setValue:@"notification" forKey:@"messageType"];
        }

        // Print full message.
        [FirebasePlugin.firebasePlugin _logMessage:[NSString stringWithFormat:@"willPresentNotification: %@", mutableUserInfo]];

        bool isContentAvailable = true;
        NSDictionary* aps = [mutableUserInfo objectForKey:@"aps"];
        @try {
            isContentAvailable = [[aps objectForKey:@"content-available"] isEqualToNumber:[NSNumber numberWithInt:1]];
        } @catch (NSException *exception) {
            
        }
        NSString* newCutoffDate1 = [mutableUserInfo objectForKey:@"newCutoffDate1"];
        NSString* customerId = [mutableUserInfo objectForKey:@"CustomerID"];

        NSString* messageBody = [mutableUserInfo objectForKey:@"body"];
        NSString* websiteUrl = [mutableUserInfo objectForKey:@"websiteUrl"];
        NSString* auditLogId = [mutableUserInfo objectForKey:@"AuditLogId"];
        if(newCutoffDate1 == nil){
                 
            [self logRemoteMessage:customerId:messageBody:websiteUrl:auditLogId];
        }
        if(isContentAvailable){
            [FirebasePlugin.firebasePlugin _logError:@"willPresentNotification: aborting as content-available:1 so system notification will be shown"];
            return;
        }
        
        bool showForegroundNotification = [mutableUserInfo objectForKey:@"notification_foreground"];
        bool hasAlert = [aps objectForKey:@"alert"] != nil;
        bool hasBadge = [aps objectForKey:@"badge"] != nil;
        bool hasSound = [aps objectForKey:@"sound"] != nil;

        if(showForegroundNotification){
            [FirebasePlugin.firebasePlugin _logMessage:[NSString stringWithFormat:@"willPresentNotification: foreground notification alert=%@, badge=%@, sound=%@", hasAlert ? @"YES" : @"NO", hasBadge ? @"YES" : @"NO", hasSound ? @"YES" : @"NO"]];
            if(hasAlert && hasBadge && hasSound){
                completionHandler(UNNotificationPresentationOptionAlert + UNNotificationPresentationOptionBadge + UNNotificationPresentationOptionSound);
            }else if(hasAlert && hasBadge){
                completionHandler(UNNotificationPresentationOptionAlert + UNNotificationPresentationOptionBadge);
            }else if(hasAlert && hasSound){
                completionHandler(UNNotificationPresentationOptionAlert + UNNotificationPresentationOptionSound);
            }else if(hasBadge && hasSound){
                completionHandler(UNNotificationPresentationOptionBadge + UNNotificationPresentationOptionSound);
            }else if(hasAlert){
                completionHandler(UNNotificationPresentationOptionAlert);
            }else if(hasBadge){
                completionHandler(UNNotificationPresentationOptionBadge);
            }else if(hasSound){
                completionHandler(UNNotificationPresentationOptionSound);
            }
        }else{
            [FirebasePlugin.firebasePlugin _logMessage:@"willPresentNotification: foreground notification not set"];
        }
        
        if(![messageType isEqualToString:@"data"]){
            [FirebasePlugin.firebasePlugin sendNotification:mutableUserInfo];
            
        }
        
    }@catch (NSException *exception) {
        [FirebasePlugin.firebasePlugin handlePluginExceptionWithoutContext:exception];
    }
}

// Asks the delegate to process the user's response to a delivered notification.
// Called when user taps on system notification
- (void) userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completionHandler
{
    @try{
        
        if (![response.notification.request.trigger isKindOfClass:UNPushNotificationTrigger.class] && ![response.notification.request.trigger isKindOfClass:UNTimeIntervalNotificationTrigger.class]){
            if (_previousDelegate) {
                // bubbling event
                [_previousDelegate userNotificationCenter:center
                               didReceiveNotificationResponse:response
                            withCompletionHandler:completionHandler];
                return;
            } else {
                [FirebasePlugin.firebasePlugin _logMessage:@"didReceiveNotificationResponse: aborting as not a supported UNNotificationTrigger"];
                return;
            }
        }

        [[FIRMessaging messaging] appDidReceiveMessage:response.notification.request.content.userInfo];
        
        mutableUserInfo = [response.notification.request.content.userInfo mutableCopy];
      
        NSString* tap;
        if([self.applicationInBackground isEqual:[NSNumber numberWithBool:YES]]){
            {
                NSString* newCutoffDate1 = [mutableUserInfo objectForKey:@"newCutoffDate1"];
     
                
                NSString* customerId = [mutableUserInfo objectForKey:@"CustomerID"];

                NSString* messageBody = [mutableUserInfo objectForKey:@"body"];
                NSString* websiteUrl = [mutableUserInfo objectForKey:@"websiteUrl"];
                NSString* auditLogId = [mutableUserInfo objectForKey:@"AuditLogId"];
                tap = @"background";
                
                if(newCutoffDate1 == nil){
                         
                    [self logRemoteMessage:customerId:messageBody:websiteUrl:auditLogId];
                }
            
            }
        }else{
            tap = @"foreground";
            
        }
        [mutableUserInfo setValue:tap forKey:@"tap"];
        if([mutableUserInfo objectForKey:@"messageType"] == nil){
            [mutableUserInfo setValue:@"notification" forKey:@"messageType"];
        }
        
        // Dynamic Actions
        if (response.actionIdentifier && ![response.actionIdentifier isEqual:UNNotificationDefaultActionIdentifier]) {
            [mutableUserInfo setValue:response.actionIdentifier forKey:@"action"];
        }
        
        // Print full message.
        [FirebasePlugin.firebasePlugin _logInfo:[NSString stringWithFormat:@"didReceiveNotificationResponse: %@", mutableUserInfo]];

        [FirebasePlugin.firebasePlugin sendNotification:mutableUserInfo];

        completionHandler();
        
    }@catch (NSException *exception) {
        [FirebasePlugin.firebasePlugin handlePluginExceptionWithoutContext:exception];
    }
}


// Apple Sign In
- (void)authorizationController:(ASAuthorizationController *)controller
   didCompleteWithAuthorization:(ASAuthorization *)authorization API_AVAILABLE(ios(13.0)) {
    @try{
        CDVPluginResult* pluginResult;
        NSString* errorMessage = nil;
        FIROAuthCredential *credential;
        
        if ([authorization.credential isKindOfClass:[ASAuthorizationAppleIDCredential class]]) {
            ASAuthorizationAppleIDCredential *appleIDCredential = authorization.credential;
            NSString *rawNonce = [FirebasePlugin appleSignInNonce];
            if(rawNonce == nil){
                errorMessage = @"Invalid state: A login callback was received, but no login request was sent.";
            }else if (appleIDCredential.identityToken == nil) {
                errorMessage = @"Unable to fetch identity token.";
            }else{
                NSString *idToken = [[NSString alloc] initWithData:appleIDCredential.identityToken
                                                          encoding:NSUTF8StringEncoding];
                if (idToken == nil) {
                    errorMessage = [NSString stringWithFormat:@"Unable to serialize id token from data: %@", appleIDCredential.identityToken];
                }else{
                    // Initialize a Firebase credential.
                    credential = [FIROAuthProvider credentialWithProviderID:@"apple.com"
                        IDToken:idToken
                        rawNonce:rawNonce];
                    
                    NSNumber* key = [[FirebasePlugin firebasePlugin] saveAuthCredential:credential];
                    NSMutableDictionary* result = [[NSMutableDictionary alloc] init];
                    [result setValue:@"true" forKey:@"instantVerification"];
                    [result setValue:key forKey:@"id"];
                    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result];
                }
            }
            if(errorMessage != nil){
                [FirebasePlugin.firebasePlugin _logError:errorMessage];
                pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];
            }
            if ([FirebasePlugin firebasePlugin].appleSignInCallbackId != nil) {
                [[FirebasePlugin firebasePlugin].commandDelegate sendPluginResult:pluginResult callbackId:[FirebasePlugin firebasePlugin].appleSignInCallbackId];
            }
        }
    }@catch (NSException *exception) {
        [FirebasePlugin.firebasePlugin handlePluginExceptionWithoutContext:exception];
    }
}

- (void)authorizationController:(ASAuthorizationController *)controller
           didCompleteWithError:(NSError *)error API_AVAILABLE(ios(13.0)) {
    NSString* errorMessage = [NSString stringWithFormat:@"Sign in with Apple errored: %@", error];
    [FirebasePlugin.firebasePlugin _logError:errorMessage];
    if ([FirebasePlugin firebasePlugin].appleSignInCallbackId != nil) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errorMessage];
        [[FirebasePlugin firebasePlugin].commandDelegate sendPluginResult:pluginResult callbackId:[FirebasePlugin firebasePlugin].appleSignInCallbackId];
    }
}

- (nonnull ASPresentationAnchor)presentationAnchorForAuthorizationController:(nonnull ASAuthorizationController *)controller  API_AVAILABLE(ios(13.0)){
    return self.viewController.view.window;
}

@end
