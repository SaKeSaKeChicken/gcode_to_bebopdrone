//
//  BebopDrone.m
//  SDKSample
//

#import "BebopDrone.h"
#import "SDCardModule.h"

#define DEVICE_PORT_MAV 61 //Mavlink
#define DEVICE_PORT_MP     21 // Movie and Picture
#define MEDIA_FOLDER    "internal_005"

@interface BebopDrone ()<SDCardModuleDelegate>

@property (nonatomic, assign) ARCONTROLLER_Device_t *deviceController;
@property (nonatomic, assign) ARService *service;
@property (nonatomic, strong) SDCardModule *sdCardModule;
@property (nonatomic, assign) eARCONTROLLER_DEVICE_STATE connectionState;
@property (nonatomic, assign) eARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE flyingState;
@property (nonatomic, strong) NSString *currentRunId;
@property (nonatomic, strong) NSString *outdrState;

@property (nonatomic) dispatch_semaphore_t resolveSemaphore;


//データやりとりのやつここから

@property (nonatomic, assign) ARSAL_Thread_t threadRetreiveAllMedias;   // the thread that will do the media retrieving
@property (nonatomic, assign) ARSAL_Thread_t threadGetThumbnails;       // the thread that will download the thumbnails
@property (nonatomic, assign) ARSAL_Thread_t threadMediasDownloader;    // the thread that will download medias

@property (nonatomic, assign) ARDATATRANSFER_Manager_t *manager;        // the data transfer manager
@property (nonatomic, assign) ARUTILS_Manager_t *ftpListManager;        // an ftp that will do the list
@property (nonatomic, assign) ARUTILS_Manager_t *ftpQueueManager;       // an ftp that will do the download
//ここまで

@end

@implementation BebopDrone

-(id)initWithService:(ARService *)service {
    self = [super init];
    if (self) {
        
        _service = service;
        _flyingState = ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_LANDED;
    }
    return self;
}

- (void)dealloc
{
    if (_deviceController) {
        ARCONTROLLER_Device_Delete(&_deviceController);
    }
}

- (void)connect {
    
    if (!_deviceController) {
        // call createDeviceControllerWithService in background
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // if the product type of the service matches with the supported types
            eARDISCOVERY_PRODUCT product = _service.product;
            eARDISCOVERY_PRODUCT_FAMILY family = ARDISCOVERY_getProductFamily(product);
            if (family == ARDISCOVERY_PRODUCT_FAMILY_ARDRONE) {
                // create the device controller
                [self createDeviceControllerWithService:_service];
                [self createSDCardModule];
            }
        });
    } else {
        ARCONTROLLER_Device_Start (_deviceController);
    }
}

- (void)disconnect {
    ARCONTROLLER_Device_Stop (_deviceController);
}

- (eARCONTROLLER_DEVICE_STATE)connectionState {
    return _connectionState;
}

- (eARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE)flyingState {
    return _flyingState;
}

- (void)createDeviceControllerWithService:(ARService*)service {
    // first get a discovery device
    ARDISCOVERY_Device_t *discoveryDevice = [self createDiscoveryDeviceWithService:service];
    
    if (discoveryDevice != NULL) {
        eARCONTROLLER_ERROR error = ARCONTROLLER_OK;
        
        // create the device controller
        _deviceController = ARCONTROLLER_Device_New (discoveryDevice, &error);
        
        // add the state change callback to be informed when the device controller starts, stops...
        if (error == ARCONTROLLER_OK) {
            error = ARCONTROLLER_Device_AddStateChangedCallback(_deviceController, stateChanged, (__bridge void *)(self));
        }
        
        // add the command received callback to be informed when a command has been received from the device
        if (error == ARCONTROLLER_OK) {
            error = ARCONTROLLER_Device_AddCommandReceivedCallback(_deviceController, onCommandReceived, (__bridge void *)(self));
        }
        
        // add the received frame callback to be informed when a frame should be displayed
        if (error == ARCONTROLLER_OK) {
            error = ARCONTROLLER_Device_SetVideoStreamMP4Compliant(_deviceController, 1);
        }
        
        // add the received frame callback to be informed when a frame should be displayed
        if (error == ARCONTROLLER_OK) {
            error = ARCONTROLLER_Device_SetVideoStreamCallbacks(_deviceController, configDecoderCallback,
                                                                didReceiveFrameCallback, NULL , (__bridge void *)(self));
        }
        
        // start the device controller (the callback stateChanged should be called soon)
        if (error == ARCONTROLLER_OK) {
            error = ARCONTROLLER_Device_Start (_deviceController);
        }
        
        // we don't need the discovery device anymore
        ARDISCOVERY_Device_Delete (&discoveryDevice);
        
        // if an error occured, inform the delegate that the state is stopped
        if (error != ARCONTROLLER_OK) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [_delegate bebopDrone:self connectionDidChange:ARCONTROLLER_DEVICE_STATE_STOPPED];
            });
        }
    } else {
        // if an error occured, inform the delegate that the state is stopped
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate bebopDrone:self connectionDidChange:ARCONTROLLER_DEVICE_STATE_STOPPED];
        });
    }
}

- (ARDISCOVERY_Device_t *)createDiscoveryDeviceWithService:(ARService*)service {
    ARDISCOVERY_Device_t *device = NULL;
    eARDISCOVERY_ERROR errorDiscovery = ARDISCOVERY_OK;
    
    device = ARDISCOVERY_Device_New (&errorDiscovery);
    
    if (errorDiscovery == ARDISCOVERY_OK) {
        // need to resolve service to get the IP
        BOOL resolveSucceeded = [self resolveService:service];
        
        if (resolveSucceeded) {
            NSString *ip = [[ARDiscovery sharedInstance] convertNSNetServiceToIp:service];
            int port = (int)[(NSNetService *)service.service port];
            
            if (ip) {
                // create a Wifi discovery device
                errorDiscovery = ARDISCOVERY_Device_InitWifi (device, service.product, [service.name UTF8String], [ip UTF8String], port);
            } else {
                NSLog(@"ip is null");
                errorDiscovery = ARDISCOVERY_ERROR;
            }
        } else {
            NSLog(@"Resolve error");
            errorDiscovery = ARDISCOVERY_ERROR;
        }
        
        if (errorDiscovery != ARDISCOVERY_OK) {
            NSLog(@"Discovery error :%s", ARDISCOVERY_Error_ToString(errorDiscovery));
            ARDISCOVERY_Device_Delete(&device);
        }
    }
    
    return device;
}

- (void)createSDCardModule {
    eARUTILS_ERROR ftpError = ARUTILS_OK;
    ARUTILS_Manager_t *ftpListManager = NULL;
    ARUTILS_Manager_t *ftpQueueManager = NULL;
    NSString *ip = [[ARDiscovery sharedInstance] convertNSNetServiceToIp:_service];
    
    ftpListManager = ARUTILS_Manager_New(&ftpError);
    if(ftpError == ARUTILS_OK) {
        ftpQueueManager = ARUTILS_Manager_New(&ftpError);
    }
    
    if (ip) {
        if(ftpError == ARUTILS_OK) {
            ftpError = ARUTILS_Manager_InitWifiFtp(ftpListManager, [ip UTF8String], DEVICE_PORT_MP, ARUTILS_FTP_ANONYMOUS, "");
        }
        
        if(ftpError == ARUTILS_OK) {
            ftpError = ARUTILS_Manager_InitWifiFtp(ftpQueueManager, [ip UTF8String], DEVICE_PORT_MP, ARUTILS_FTP_ANONYMOUS, "");
        }
    }
    
    
    _sdCardModule = [[SDCardModule alloc] initWithFtpListManager:ftpListManager andFtpQueueManager:ftpQueueManager];
    _sdCardModule.delegate = self;
}

#pragma mark commands
- (void)emergency {
    if (_deviceController && (_connectionState == ARCONTROLLER_DEVICE_STATE_RUNNING)) {
        _deviceController->aRDrone3->sendPilotingEmergency(_deviceController->aRDrone3);
    }
}

- (void)takeOff {
    if (_deviceController && (_connectionState == ARCONTROLLER_DEVICE_STATE_RUNNING)) {
        _deviceController->aRDrone3->sendPilotingTakeOff(_deviceController->aRDrone3);
    }
}

- (void)land {
    if (_deviceController && (_connectionState == ARCONTROLLER_DEVICE_STATE_RUNNING)) {
        _deviceController->aRDrone3->sendPilotingLanding(_deviceController->aRDrone3);
    }
}

- (void)takePicture {
    if (_deviceController && (_connectionState == ARCONTROLLER_DEVICE_STATE_RUNNING)) {
        _deviceController->aRDrone3->sendMediaRecordPictureV2(_deviceController->aRDrone3);
    }
}

- (void)setPitch:(uint8_t)pitch {
    if (_deviceController && (_connectionState == ARCONTROLLER_DEVICE_STATE_RUNNING)) {
        _deviceController->aRDrone3->setPilotingPCMDPitch(_deviceController->aRDrone3, pitch);
    }
}

- (void)setRoll:(uint8_t)roll {
    if (_deviceController && (_connectionState == ARCONTROLLER_DEVICE_STATE_RUNNING)) {
        _deviceController->aRDrone3->setPilotingPCMDRoll(_deviceController->aRDrone3, roll);
    }
}

- (void)setYaw:(uint8_t)yaw {
    if (_deviceController && (_connectionState == ARCONTROLLER_DEVICE_STATE_RUNNING)) {
        _deviceController->aRDrone3->setPilotingPCMDYaw(_deviceController->aRDrone3, yaw);
    }
}

- (void)setGaz:(uint8_t)gaz {
    if (_deviceController && (_connectionState == ARCONTROLLER_DEVICE_STATE_RUNNING)) {
        _deviceController->aRDrone3->setPilotingPCMDGaz(_deviceController->aRDrone3, gaz);
    }
}

- (void)setFlag:(uint8_t)flag {
    if (_deviceController && (_connectionState == ARCONTROLLER_DEVICE_STATE_RUNNING)) {
        _deviceController->aRDrone3->setPilotingPCMDFlag(_deviceController->aRDrone3, flag);
    }
}




//ここから作ったARDataTransfer
- (void)createDataTransferManager
{
    
    NSString *productIP = [[ARDiscovery sharedInstance] convertNSNetServiceToIp:_service];
    NSLog(@"%@",productIP);
    
    eARDATATRANSFER_ERROR result = ARDATATRANSFER_OK;
    _manager = ARDATATRANSFER_Manager_New(&result);
    
    if (result == ARDATATRANSFER_OK)
    {
        eARUTILS_ERROR ftpError = ARUTILS_OK;
        _ftpListManager = ARUTILS_Manager_New(&ftpError);
        if(ftpError == ARUTILS_OK)
        {
            _ftpQueueManager = ARUTILS_Manager_New(&ftpError);
        }
        
        if(ftpError == ARUTILS_OK)
        {
            ftpError = ARUTILS_Manager_InitWifiFtp(_ftpListManager, [productIP UTF8String], DEVICE_PORT_MAV, ARUTILS_FTP_ANONYMOUS, "");
        }
        
        if(ftpError == ARUTILS_OK)
        {
            ftpError = ARUTILS_Manager_InitWifiFtp(_ftpQueueManager, [productIP UTF8String], DEVICE_PORT_MAV, ARUTILS_FTP_ANONYMOUS, "");
        }
        
        if(ftpError != ARUTILS_OK)
        {
            result = ARDATATRANSFER_ERROR_FTP;
            NSLog(@"ftpError100 : %d",result);
        }
    }
    
    if (result == ARDATATRANSFER_OK)
    {
        //送信側デバイスのディレクトリのパス取得、そこにファイルを作る
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsDirectory = [paths objectAtIndex:0];
        NSString *appFile = [documentsDirectory stringByAppendingPathComponent:@"aiueo2.mavlink"];
        
        NSLog(@"appFile: %@", appFile);
        
        mavlink_mission_item_t item;
        eARMAVLINK_ERROR error;
        
        // Create file generator
        ARMAVLINK_FileGenerator_t *generator =  ARMAVLINK_FileGenerator_New(&error);
        
        float nwlat = 35.389799;
        float nwlon = 139.427719;
        float al = 5;
        
//        error = ARMAVLINK_MissionItemUtils_CreateMavlinkTakeoffMissionItem(&item, 35.389657, 139.427790, 2, 0, 10);
//        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
//        
//        error = ARMAVLINK_MissionItemUtils_CreateMavlinkDelay(&item, 1);
//        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
//        
//        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, 35.389677, 139.427810, 3, 90);
//        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
//        
//        error = ARMAVLINK_MissionItemUtils_CreateMavlinkLandMissionItem(&item, 35.389667, 139.427800, 2, 0);
//        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkTakeoffMissionItem(&item, nwlat, nwlon, 1, 0, 10);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkChangeSpeedMissionItem(&item, 0, 0.5 , -1);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
//        error = ARMAVLINK_MissionItemUtils_CreateMavlinkMissionItemWithAllParams(&item, <#float param1#>, <#float param2#>, <#float param3#>, <#float param4#>, <#float latitude#>, <#float longitude#>, <#float altitude#>, <#int command#>, <#int seq#>, <#int frame#>, <#int current#>, <#int autocontinue#>)
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat, nwlon, al, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);

        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat, nwlon - 0.000011 * al, 1, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat, nwlon - 0.000011 * al, al, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat + 0.000009 * al, nwlon - 0.000011 * al, 1, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat + 0.000009 * al, nwlon - 0.000011 * al, al, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat + 0.000009 * al, nwlon, 1, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat + 0.000009 * al, nwlon, al, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat, nwlon, 1, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat, nwlon, al, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat, nwlon - 0.000011 * al, al, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat + 0.000009 * al, nwlon - 0.000011 * al, al, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat + 0.000009 * al, nwlon, al, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, nwlat, nwlon, 1, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkLandMissionItem(&item, nwlat, nwlon, 1, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        // Create the mavlink file
        ARMAVLINK_FileGenerator_CreateMavlinkFile(generator, [appFile cStringUsingEncoding:NSASCIIStringEncoding]);
        
        ARDATATRANSFER_Uploader_ProgressCallback_t progressCallback = FTPProgress;
        ARDATATRANSFER_Uploader_CompletionCallback_t completionCallback = FTPComp;
        
        result = ARDATATRANSFER_Uploader_New(_manager, _ftpListManager, MEDIA_FOLDER, (char *)[appFile UTF8String], progressCallback, (__bridge void *)(self), completionCallback, (__bridge void *)(self), ARDATATRANSFER_UPLOADER_RESUME_TRUE);
        NSLog(@"uploader_new result : %d", result);
        
        ARDATATRANSFER_Uploader_ThreadRun(_manager);
        
        result = ARDATATRANSFER_Uploader_Delete(_manager);
        NSLog(@"uploader_delete result : %d", result);
        
        // Delete the generator to free up memory
        ARMAVLINK_FileGenerator_Delete(&generator);
        
        // Tell drone to run the file from it's FTP
        [self deviceController]->common->sendMavlinkStart([self deviceController]->common, MEDIA_FOLDER, ARCOMMANDS_COMMON_MAVLINK_START_TYPE_FLIGHTPLAN);
        
    }
}

void FTPComp (void* arg, eARDATATRANSFER_ERROR error)
{
    NSLog(@"comp error : %s", ARDATATRANSFER_Error_ToString(error));
}
void FTPProgress (void* arg, float percent)
{
    NSLog(@"%f percent now",percent);
}

//
- (void)aiueo
{

    [self startMediaListThread];
}
- (void)startMediaListThread
{
    // first retrieve Medias without their thumbnails
    ARSAL_Thread_Create(&_threadRetreiveAllMedias, ARMediaStorage_retreiveAllMediasAsync, (__bridge void *)self);
}

static void* ARMediaStorage_retreiveAllMediasAsync(void* arg)
{
    BebopDrone *self = (__bridge BebopDrone *)(arg);
    [self getAllMediaAsync];
    return NULL;
}

- (void)getAllMediaAsync
{
    NSString *productIP = @"192.168.42.1";  // TODO: get this address from libARController
    
    eARDATATRANSFER_ERROR result = ARDATATRANSFER_OK;
    _manager = ARDATATRANSFER_Manager_New(&result);
    
    if (result == ARDATATRANSFER_OK)
    {
        eARUTILS_ERROR ftpError = ARUTILS_OK;
        _ftpListManager = ARUTILS_Manager_New(&ftpError);
        if(ftpError == ARUTILS_OK)
        {
            _ftpQueueManager = ARUTILS_Manager_New(&ftpError);
        }
        
        if(ftpError == ARUTILS_OK)
        {
            ftpError = ARUTILS_Manager_InitWifiFtp(_ftpListManager, [productIP UTF8String], DEVICE_PORT_MP, ARUTILS_FTP_ANONYMOUS, "");
        }
        
        if(ftpError == ARUTILS_OK)
        {
            ftpError = ARUTILS_Manager_InitWifiFtp(_ftpQueueManager, [productIP UTF8String], DEVICE_PORT_MP, ARUTILS_FTP_ANONYMOUS, "");
        }
        
        if(ftpError != ARUTILS_OK)
        {
            result = ARDATATRANSFER_ERROR_FTP;
        }
    }
    // NO ELSE
    
    if (result == ARDATATRANSFER_OK)
    {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *path = [paths lastObject];
        
        result = ARDATATRANSFER_MediasDownloader_New(_manager, _ftpListManager, _ftpQueueManager, MEDIA_FOLDER, [path UTF8String]);
        NSLog(@"1:%s",ARDATATRANSFER_Error_ToString(result));
    }
    
    int mediaListCount = 0;
    NSLog(@"2:%s",ARDATATRANSFER_Error_ToString(result));
    if (result == ARDATATRANSFER_OK)
    {
        NSLog(@"3:%s",ARDATATRANSFER_Error_ToString(result));
        mediaListCount = ARDATATRANSFER_MediasDownloader_GetAvailableMediasSync(_manager,0,&result);
        NSLog(@"4:%s",ARDATATRANSFER_Error_ToString(result));
        if (result == ARDATATRANSFER_OK)
        {
            for (int i = 0 ; i < mediaListCount && result == ARDATATRANSFER_OK; i++)
            {
                ARDATATRANSFER_Media_t * mediaObject = ARDATATRANSFER_MediasDownloader_GetAvailableMediaAtIndex(_manager, i, &result);
                NSLog(@"Media %i: %s", i, mediaObject->name);
                // Do what you want with this mediaObject
            }
        }
    }
}



//作ったmoveRel
- (void)moveRel: (float_t)dX dY:(float_t)dY dZ:(float_t)dZ dPsi:(float_t)dPsi {
    if (_deviceController && (_connectionState == ARCONTROLLER_DEVICE_STATE_RUNNING)) {
        _deviceController->aRDrone3->sendPilotingMoveBy(_deviceController->aRDrone3, dX, dY, dZ, dPsi);
    }
}

//作る
- (void)mvdrn: (float_t)flag roll:(float_t)roll pitch:(float_t)pitch yaw:(float_t)yaw gaz:(float_t)gaz timestampAndSeqNum:(float_t)timestampAndSeqNum{
_deviceController->aRDrone3->sendPilotingPCMD(_deviceController->aRDrone3, flag, roll, pitch, yaw, gaz, timestampAndSeqNum);

}

//作ったoutdoor wifiとスピードをアウトドアモードにする
//それによって、GPSを取れるようになる
- (void)outDoorWifi:(uint8_t)outdrw {
    _deviceController->common->sendWifiSettingsOutdoorSetting(_deviceController->common, outdrw);
}

-(void)hm{
    _deviceController->aRDrone3->sendGPSSettingsResetHome(_deviceController->aRDrone3);
}

- (void)testWaypoint
{
    if([self deviceController] != nil)
    {
        // Get path for file
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsDirectory = [paths objectAtIndex:0];
        NSString *appFile = [documentsDirectory stringByAppendingPathComponent:@"TestFile.waypoint"];
        
        NSLog(@"paths:%@", paths);
        NSLog(@"appFile:%@", appFile);

        mavlink_mission_item_t item;
        eARMAVLINK_ERROR error;
        
        // Create file generator
        ARMAVLINK_FileGenerator_t *generator =  ARMAVLINK_FileGenerator_New(&error);
        
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkTakeoffMissionItem(&item, 35.386343, 139.428841, 50, 180, 100);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkDelay(&item, 10);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkNavWaypointMissionItem(&item, 35.386343, 139.428841, 50, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        error = ARMAVLINK_MissionItemUtils_CreateMavlinkLandMissionItem(&item, 35.386343, 139.428841, 50, 0);
        error = ARMAVLINK_FileGenerator_AddMissionItem(generator, &item);
        
        // Create the mavlink file
        ARMAVLINK_FileGenerator_CreateMavlinkFile(generator, [appFile cStringUsingEncoding:NSASCIIStringEncoding]);
        
        // Util stuff
        eARUTILS_ERROR utilError;
        ARUTILS_Manager_t *utilsManager = ARUTILS_Manager_New(&utilError);
        NSLog(@"utilError_String0:%s", ARUTILS_Error_ToString(utilError));
        NSLog(@"utilError0:%d", utilError);
        // Put the file on the drone FTP
        ARUTILS_Ftp_ProgressCallback_t ftpCallback = FTPProgress;

//        utilError = ARUTILS_Manager_Ftp_Put(utilsManager, [@"TestFile.waypoint" cStringUsingEncoding:NSASCIIStringEncoding], [appFile cStringUsingEncoding:NSASCIIStringEncoding], ftpCallback, (__bridge void *)(self), FTP_RESUME_TRUE);
        
        utilError = ARUTILS_Manager_Ftp_Put(utilsManager,(char*)DEVICE_PORT_MAV, [@"TestFile.waypoint" cStringUsingEncoding:NSASCIIStringEncoding], ftpCallback, (__bridge void *)(self), FTP_RESUME_TRUE);
        
        NSLog(@"utilError_String1:%s", ARUTILS_Error_ToString(utilError));
        NSLog(@"utilError1:%d", utilError);
        // Delete the generator to free up memory
        ARMAVLINK_FileGenerator_Delete(&generator);
        
        // Tell drone to run the file from it's FTP
        [self deviceController]->common->sendMavlinkStart([self deviceController]->common, (char*)[@"TestFile.waypoint" cStringUsingEncoding:NSASCIIStringEncoding], ARCOMMANDS_COMMON_MAVLINK_START_TYPE_FLIGHTPLAN);
        
        // Put this in a callback to delete when the mavlink file has completed or stopped
        utilError =  ARUTILS_Manager_Ftp_Delete(utilsManager, [@"TestFile.waypoint" cStringUsingEncoding:NSASCIIStringEncoding]);
        NSLog(@"utilError_String2:%s", ARUTILS_Error_ToString(utilError));
        NSLog(@"utilError2:%d", utilError);
    }
}

- (void)strtAutoFlight{
    
    eARUTILS_ERROR utilError;
    ARUTILS_Manager_t *utilsManager = ARUTILS_Manager_New(&utilError);
    
    [self deviceController]->common->sendMavlinkStart([self deviceController]->common, (char*)[@"TestFile.waypoint" cStringUsingEncoding:NSASCIIStringEncoding], ARCOMMANDS_COMMON_MAVLINK_START_TYPE_FLIGHTPLAN);
    
    // Put this in a callback to delete when the mavlink file has completed or stopped
    utilError =  ARUTILS_Manager_Ftp_Delete(utilsManager, [@"TestFile.waypoint" cStringUsingEncoding:NSASCIIStringEncoding]);
    NSLog(@"utilError_String2:%s", ARUTILS_Error_ToString(utilError));
    NSLog(@"utilError2:%d", utilError);
}

- (void)stpAutoFlight
{
    _deviceController->common->sendMavlinkPause(_deviceController->common);
}

//ここまで作ったやつ







-(void)downloadMedias {
    if (_currentRunId && ![_currentRunId isEqualToString:@""]) {
        [_sdCardModule getFlightMedias:_currentRunId];
    } else {
        [_sdCardModule getTodaysFlightMedias];
    }

}

- (void)cancelDownloadMedias {
    [_sdCardModule cancelGetMedias];
}

#pragma mark Device controller callbacks
// called when the state of the device controller has changed
static void stateChanged (eARCONTROLLER_DEVICE_STATE newState, eARCONTROLLER_ERROR error, void *customData) {
    BebopDrone *bebopDrone = (__bridge BebopDrone*)customData;
    if (bebopDrone != nil) {
        switch (newState) {
            case ARCONTROLLER_DEVICE_STATE_RUNNING:
                bebopDrone.deviceController->aRDrone3->sendMediaStreamingVideoEnable(bebopDrone.deviceController->aRDrone3, 1);
                break;
            case ARCONTROLLER_DEVICE_STATE_STOPPED:
                break;
            default:
                break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            bebopDrone.connectionState = newState;
            [bebopDrone.delegate bebopDrone:bebopDrone connectionDidChange:newState];
        });
    }
}





// called when a command has been received from the drone
static void onCommandReceived (eARCONTROLLER_DICTIONARY_KEY commandKey, ARCONTROLLER_DICTIONARY_ELEMENT_t *elementDictionary, void *customData) {
    BebopDrone *bebopDrone = (__bridge BebopDrone*)customData;

    // if the command received is a battery state changed
    if ((commandKey == ARCONTROLLER_DICTIONARY_KEY_COMMON_COMMONSTATE_BATTERYSTATECHANGED) &&
        (elementDictionary != NULL)) {
        ARCONTROLLER_DICTIONARY_ARG_t *arg = NULL;
        ARCONTROLLER_DICTIONARY_ELEMENT_t *element = NULL;
        
        HASH_FIND_STR (elementDictionary, ARCONTROLLER_DICTIONARY_SINGLE_KEY, element);
        if (element != NULL) {
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_COMMON_COMMONSTATE_BATTERYSTATECHANGED_PERCENT, arg);
            if (arg != NULL) {
                uint8_t battery = arg->value.U8;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [bebopDrone.delegate bebopDrone:bebopDrone batteryDidChange:battery];
                });
            }
        }
    }
    // if the command received is a battery state changed
    else if ((commandKey == ARCONTROLLER_DICTIONARY_KEY_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED) &&
        (elementDictionary != NULL)) {
        ARCONTROLLER_DICTIONARY_ARG_t *arg = NULL;
        ARCONTROLLER_DICTIONARY_ELEMENT_t *element = NULL;
        
        HASH_FIND_STR (elementDictionary, ARCONTROLLER_DICTIONARY_SINGLE_KEY, element);
        if (element != NULL) {
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE, arg);
            if (arg != NULL) {
                bebopDrone.flyingState = arg->value.I32;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [bebopDrone.delegate bebopDrone:bebopDrone flyingStateDidChange:bebopDrone.flyingState];
                });
            }
        }
    }
    // if the command received is a run id changed
    else if ((commandKey == ARCONTROLLER_DICTIONARY_KEY_COMMON_RUNSTATE_RUNIDCHANGED) &&
             (elementDictionary != NULL)) {
        ARCONTROLLER_DICTIONARY_ARG_t *arg = NULL;
        ARCONTROLLER_DICTIONARY_ELEMENT_t *element = NULL;
        
        HASH_FIND_STR (elementDictionary, ARCONTROLLER_DICTIONARY_SINGLE_KEY, element);
        if (element != NULL) {
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_COMMON_RUNSTATE_RUNIDCHANGED_RUNID, arg);
            if (arg != NULL) {
                char * runId =
                arg->value.String;
                if (runId != NULL) {
                    bebopDrone.currentRunId = [NSString stringWithUTF8String:runId];
                }
            }
        }
    }
    //ホームポジションがリセットされたら...作動しない！！！！！！！！
    if ((commandKey == ARCONTROLLER_DICTIONARY_KEY_ARDRONE3_GPSSETTINGSSTATE_RESETHOMECHANGED) && (elementDictionary != NULL))
    {
        ARCONTROLLER_DICTIONARY_ARG_t *arg = NULL;
        ARCONTROLLER_DICTIONARY_ELEMENT_t *element = NULL;
        HASH_FIND_STR (elementDictionary, ARCONTROLLER_DICTIONARY_SINGLE_KEY, element);
        if (element != NULL)
        {
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_ARDRONE3_GPSSETTINGSSTATE_RESETHOMECHANGED_LATITUDE, arg);
            if (arg != NULL)
            {
                double latitude = arg->value.Double;
                NSLog(@"home latitude : %f",latitude);
            }
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_ARDRONE3_GPSSETTINGSSTATE_RESETHOMECHANGED_LONGITUDE, arg);
            if (arg != NULL)
            {
                double longitude = arg->value.Double;
                NSLog(@"home longitude : %f",longitude);
            }
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_ARDRONE3_GPSSETTINGSSTATE_RESETHOMECHANGED_ALTITUDE, arg);
            if (arg != NULL)
            {
                double altitude = arg->value.Double;
                NSLog(@"home altitude : %f",altitude);
                
            }
        }
    }
    //ワイファイセッティングが屋外用になったら
    if ((commandKey == ARCONTROLLER_DICTIONARY_KEY_COMMON_WIFISETTINGSSTATE_OUTDOORSETTINGSCHANGED) && (elementDictionary != NULL))
    {
        ARCONTROLLER_DICTIONARY_ARG_t *arg = NULL;
        ARCONTROLLER_DICTIONARY_ELEMENT_t *element = NULL;
        HASH_FIND_STR (elementDictionary, ARCONTROLLER_DICTIONARY_SINGLE_KEY, element);
        if (element != NULL)
        {
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_COMMON_WIFISETTINGSSTATE_OUTDOORSETTINGSCHANGED_OUTDOOR, arg);
            if (arg != NULL)
            {
                uint8_t outdoor = arg->value.U8;
                bebopDrone.outdrState = [NSString stringWithFormat:@"%d",outdoor];
                NSLog(@"outdrstate:%@", bebopDrone.outdrState);
            }
        }
    }
    //ポジションが変わったらNSLogで緯度軽度高度を送り続ける
    if ((commandKey == ARCONTROLLER_DICTIONARY_KEY_ARDRONE3_PILOTINGSTATE_POSITIONCHANGED) && (elementDictionary != NULL))
    {
        ARCONTROLLER_DICTIONARY_ARG_t *arg = NULL;
        ARCONTROLLER_DICTIONARY_ELEMENT_t *element = NULL;
        HASH_FIND_STR (elementDictionary, ARCONTROLLER_DICTIONARY_SINGLE_KEY, element);
        if (element != NULL)
        {
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_ARDRONE3_PILOTINGSTATE_POSITIONCHANGED_LATITUDE, arg);
            if (arg != NULL)
            {
                double latitude = arg->value.Double;
                NSLog(@"latitude:%f",latitude);
            }
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_ARDRONE3_PILOTINGSTATE_POSITIONCHANGED_LONGITUDE, arg);
            if (arg != NULL)
            {
                double longitude = arg->value.Double;
                NSLog(@"longitude:%f",longitude);
            }
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_ARDRONE3_PILOTINGSTATE_POSITIONCHANGED_ALTITUDE, arg);
            if (arg != NULL)
            {
                double altitude = arg->value.Double;
                NSLog(@"altitude:%f",altitude);
            }
        }
    }
    //フライトプランがスタートされたら、エラーがあるかどうか調べる
    if ((commandKey == ARCONTROLLER_DICTIONARY_KEY_COMMON_MAVLINKSTATE_MAVLINKPLAYERRORSTATECHANGED) && (elementDictionary != NULL))
    {
        NSLog(@"a");
        ARCONTROLLER_DICTIONARY_ARG_t *arg = NULL;
        ARCONTROLLER_DICTIONARY_ELEMENT_t *element = NULL;
        HASH_FIND_STR (elementDictionary, ARCONTROLLER_DICTIONARY_SINGLE_KEY, element);
        if (element != NULL)
        {
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_COMMON_MAVLINKSTATE_MAVLINKPLAYERRORSTATECHANGED_ERROR, arg);
            if (arg != NULL)
            {
            eARCOMMANDS_COMMON_MAVLINKSTATE_MAVLINKPLAYERRORSTATECHANGED_ERROR error = arg->value.I32;
                NSLog(@"flightplan error : %u", error);
                
            }
        }
    }
    //コンポーネントの状態が変わったら、コンポーネントが使えるかどうか？を表示する component0:GPS 1:Calibration 2:Mavlink file 3:Take off 1がOK 0がダメ
    if ((commandKey == ARCONTROLLER_DICTIONARY_KEY_COMMON_FLIGHTPLANSTATE_COMPONENTSTATELISTCHANGED) && (elementDictionary != NULL))
    {
        ARCONTROLLER_DICTIONARY_ARG_t *arg = NULL;
        ARCONTROLLER_DICTIONARY_ELEMENT_t *dictElement = NULL;
        ARCONTROLLER_DICTIONARY_ELEMENT_t *dictTmp = NULL;
        HASH_ITER(hh, elementDictionary, dictElement, dictTmp)
        {
            HASH_FIND_STR (dictElement->arguments, ARCONTROLLER_DICTIONARY_KEY_COMMON_FLIGHTPLANSTATE_COMPONENTSTATELISTCHANGED_COMPONENT, arg);
            if (arg != NULL)
            {
                eARCOMMANDS_COMMON_FLIGHTPLANSTATE_COMPONENTSTATELISTCHANGED_COMPONENT component = arg->value.I32;
                NSLog(@"component : %u",component);
            }
            
            HASH_FIND_STR (dictElement->arguments, ARCONTROLLER_DICTIONARY_KEY_COMMON_FLIGHTPLANSTATE_COMPONENTSTATELISTCHANGED_STATE, arg);
            if (arg != NULL)
            {
                uint8_t State = arg->value.U8;
                NSLog(@"State : %hhu",State);
            }
        }
    }
    //FlightPlanできるかどうか？ 1がOK 0がダメ
    if ((commandKey == ARCONTROLLER_DICTIONARY_KEY_COMMON_FLIGHTPLANSTATE_AVAILABILITYSTATECHANGED) && (elementDictionary != NULL))
    {
        ARCONTROLLER_DICTIONARY_ARG_t *arg = NULL;
        ARCONTROLLER_DICTIONARY_ELEMENT_t *element = NULL;
        HASH_FIND_STR (elementDictionary, ARCONTROLLER_DICTIONARY_SINGLE_KEY, element);
        if (element != NULL)
        {
            HASH_FIND_STR (element->arguments, ARCONTROLLER_DICTIONARY_KEY_COMMON_FLIGHTPLANSTATE_AVAILABILITYSTATECHANGED_AVAILABILITYSTATE, arg);
            if (arg != NULL)
            {
                uint8_t AvailabilityState = arg->value.U8;
                NSLog(@"AvailabilityState:%hhu", AvailabilityState);
            }
        }
    }
}

static eARCONTROLLER_ERROR configDecoderCallback (ARCONTROLLER_Stream_Codec_t codec, void *customData) {
    BebopDrone *bebopDrone = (__bridge BebopDrone*)customData;
    
    BOOL success = [bebopDrone.delegate bebopDrone:bebopDrone configureDecoder:codec];
    
    return (success) ? ARCONTROLLER_OK : ARCONTROLLER_ERROR;
}

static eARCONTROLLER_ERROR didReceiveFrameCallback (ARCONTROLLER_Frame_t *frame, void *customData) {
    BebopDrone *bebopDrone = (__bridge BebopDrone*)customData;
    
    BOOL success = [bebopDrone.delegate bebopDrone:bebopDrone didReceiveFrame:frame];
    
    return (success) ? ARCONTROLLER_OK : ARCONTROLLER_ERROR;
}


#pragma mark resolveService
- (BOOL)resolveService:(ARService*)service {
    BOOL retval = NO;
    _resolveSemaphore = dispatch_semaphore_create(0);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(discoveryDidResolve:) name:kARDiscoveryNotificationServiceResolved object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(discoveryDidNotResolve:) name:kARDiscoveryNotificationServiceNotResolved object:nil];
    
    [[ARDiscovery sharedInstance] resolveService:service];
    
    // this semaphore will be signaled in discoveryDidResolve or discoveryDidNotResolve
    dispatch_semaphore_wait(_resolveSemaphore, DISPATCH_TIME_FOREVER);
    
    NSString *ip = [[ARDiscovery sharedInstance] convertNSNetServiceToIp:service];
    if (ip != nil)
    {
        retval = YES;
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kARDiscoveryNotificationServiceResolved object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kARDiscoveryNotificationServiceNotResolved object:nil];
    _resolveSemaphore = nil;
    return retval;
}

- (void)discoveryDidResolve:(NSNotification *)notification {
    dispatch_semaphore_signal(_resolveSemaphore);
}

- (void)discoveryDidNotResolve:(NSNotification *)notification {
    NSLog(@"Resolve failed");
    dispatch_semaphore_signal(_resolveSemaphore);
}

#pragma mark SDCardModuleDelegate
- (void)sdcardModule:(SDCardModule*)module didFoundMatchingMedias:(NSUInteger)nbMedias {
    [_delegate bebopDrone:self didFoundMatchingMedias:nbMedias];
}

- (void)sdcardModule:(SDCardModule*)module media:(NSString*)mediaName downloadDidProgress:(int)progress {
    [_delegate bebopDrone:self media:mediaName downloadDidProgress:progress];
}

- (void)sdcardModule:(SDCardModule*)module mediaDownloadDidFinish:(NSString*)mediaName {
    [_delegate bebopDrone:self mediaDownloadDidFinish:mediaName];
}

@end
