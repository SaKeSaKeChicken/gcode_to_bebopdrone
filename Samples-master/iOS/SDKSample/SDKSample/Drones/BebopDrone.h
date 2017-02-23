//
//  BebopDrone.h
//  SDKSample
//

#import <Foundation/Foundation.h>
#import <libARController/ARController.h>
#import <libARDiscovery/ARDISCOVERY_BonjourDiscovery.h>
#import <libARMavlink/libARMavlink.h>
#import <mavlink/parrot/mavlink.h>
#import <libARDataTransfer/ARDataTransfer.h>

@class BebopDrone;

@protocol BebopDroneDelegate <NSObject>
@required
/**
 * Called when the connection to the drone did change
 * Called on the main thread
 * @param bebopDrone the drone concerned
 * @param state the state of the connection
 */
- (void)bebopDrone:(BebopDrone*)bebopDrone connectionDidChange:(eARCONTROLLER_DEVICE_STATE)state;

/**
 * Called when the battery charge did change
 * Called on the main thread
 * @param bebopDrone the drone concerned
 * @param batteryPercent the battery remaining (in percent)
 */
- (void)bebopDrone:(BebopDrone*)bebopDrone batteryDidChange:(int)batteryPercentage;

/**
 * Called when the piloting state did change
 * Called on the main thread
 * @param bebopDrone the drone concerned
 * @param batteryPercent the piloting state of the drone
 */
- (void)bebopDrone:(BebopDrone*)bebopDrone flyingStateDidChange:(eARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE)state;

/**
 * Called when the video decoder should be configured
 * Called on separate thread
 * @param bebopDrone the drone concerned
 * @param codec the codec information about the stream
 * @return true if configuration went well, false otherwise
 */
- (BOOL)bebopDrone:(BebopDrone*)bebopDrone configureDecoder:(ARCONTROLLER_Stream_Codec_t)codec;

/**
 * Called when a frame has been received
 * Called on separate thread
 * @param bebopDrone the drone concerned
 * @param frame the frame received
 */
- (BOOL)bebopDrone:(BebopDrone*)bebopDrone didReceiveFrame:(ARCONTROLLER_Frame_t*)frame;

/**
 * Called before medias will be downloaded
 * Called on the main thread
 * @param bebopDrone the drone concerned
 * @param nbMedias the number of medias that will be downloaded
 */
- (void)bebopDrone:(BebopDrone*)bebopDrone didFoundMatchingMedias:(NSUInteger)nbMedias;

/**
 * Called each time the progress of a download changes
 * Called on the main thread
 * @param bebopDrone the drone concerned
 * @param mediaName the name of the media
 * @param progress the progress of its download (from 0 to 100)
 */
- (void)bebopDrone:(BebopDrone*)bebopDrone media:(NSString*)mediaName downloadDidProgress:(int)progress;

/**
 * Called when a media download has ended
 * Called on the main thread
 * @param bebopDrone the drone concerned
 * @param mediaName the name of the media
 */
- (void)bebopDrone:(BebopDrone*)bebopDrone mediaDownloadDidFinish:(NSString*)mediaName;

@end

@interface BebopDrone : NSObject

@property (nonatomic, weak) id<BebopDroneDelegate>delegate;

- (id)initWithService:(ARService*)service;
- (void)connect;
- (void)disconnect;
- (eARCONTROLLER_DEVICE_STATE)connectionState;
- (eARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE)flyingState;

- (void)emergency;
- (void)takeOff;
- (void)land;
- (void)takePicture;
- (void)setPitch:(uint8_t)pitch;
- (void)setRoll:(uint8_t)roll;
- (void)setYaw:(uint8_t)yaw;
- (void)setGaz:(uint8_t)gaz;
- (void)setFlag:(uint8_t)flag;
//ここから作った
- (void)outDoorWifi:(uint8_t)outdrw;
- (void)hm;

- (void)moveRel: (float_t)dX dY:(float_t)dY dZ:(float_t)dZ dPsi:(float_t)dPsi;
- (void)mvdrn: (float_t)flag roll:(float_t)roll pitch:(float_t)pitch yaw:(float_t)yaw gaz:(float_t)gaz timestampAndSeqNum:(float_t)timestampAndSeqNum;
- (void)createDataTransferManager;
- (void)testWaypoint;
- (void)stpAutoFlight;
//void FTPProgress (void* arg, float percent);
//void FTPComp (void* arg, float percent);
//ここまで
- (void)aiueo;
- (void)startMediaListThread;
- (void)getAllMediaAsync;

- (void)downloadMedias;
- (void)cancelDownloadMedias;
@end
