//
//  BebopVC.m
//  SDKSample
//

#import "BebopVC.h"
#import "BebopDrone.h"
#import "BebopVideoView.h"

#define DEGREES_TO_RADIANS(degrees)((M_PI * degrees)/180)

@interface BebopVC ()<BebopDroneDelegate>

#define SEKIDO_R 6378136.6
#define KYOKU_R 6356751.9
#define RAD_TO_DEG(radians) ((radians) * (180.0 / M_PI))
#define DEG_TO_RAD(degrees) ((M_PI * degrees)/180)

@property (nonatomic, strong) UIAlertView *connectionAlertView;
@property (nonatomic, strong) UIAlertController *downloadAlertController;
@property (nonatomic, strong) UIProgressView *downloadProgressView;
@property (nonatomic, strong) BebopDrone *bebopDrone;

@property (nonatomic) dispatch_semaphore_t stateSem;

@property (nonatomic, assign) NSUInteger nbMaxDownload;

@property (nonatomic, assign) int currentDownloadIndex; // from 1 to nbMaxDownload

@property (nonatomic, strong) IBOutlet BebopVideoView *videoView;
@property (nonatomic, strong) IBOutlet UILabel *batteryLabel;
@property (nonatomic, strong) IBOutlet UILabel *outdoorLabel;
@property (nonatomic, strong) IBOutlet UITextField *toX;
@property (nonatomic, strong) IBOutlet UITextField *toY;
@property (nonatomic, strong) IBOutlet UITextField *toZ;
@property (nonatomic, strong) IBOutlet UITextField *toR;
@property (nonatomic, strong) IBOutlet UIButton *takeOffLandBt;
@property (nonatomic, strong) IBOutlet UIButton *downloadMediasBt;

@property(nonatomic, strong) NSMutableArray *lin;
@property(nonatomic, strong) NSMutableArray *seg;
@property(nonatomic, strong) NSMutableArray *ikk;

@property (nonatomic) float r_ido; //その緯度での地球の半径
@property (nonatomic) float nw_idm; //現在地のメーターあたりの緯度aiueo
@property (nonatomic) float nw_kdm; //現在地のメーターあたりの経度


@end

@implementation BebopVC

-(void)viewDidLoad {
    _stateSem = dispatch_semaphore_create(0);
    
    _bebopDrone = [[BebopDrone alloc] initWithService:_service];
    [_bebopDrone setDelegate:self];
    [_bebopDrone connect];
    
    _connectionAlertView = [[UIAlertView alloc] initWithTitle:[_service name] message:@"Connecting ..."
                                           delegate:self cancelButtonTitle:nil otherButtonTitles:nil, nil];
}

- (void)viewDidAppear:(BOOL)animated {
    if ([_bebopDrone connectionState] != ARCONTROLLER_DEVICE_STATE_RUNNING) {
        [_connectionAlertView show];
    }
}

- (void) viewDidDisappear:(BOOL)animated
{
    if (_connectionAlertView && !_connectionAlertView.isHidden) {
        [_connectionAlertView dismissWithClickedButtonIndex:0 animated:NO];
    }
    _connectionAlertView = [[UIAlertView alloc] initWithTitle:[_service name] message:@"Disconnecting ..."
                                           delegate:self cancelButtonTitle:nil otherButtonTitles:nil, nil];
    [_connectionAlertView show];
    
    // in background, disconnect from the drone
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [_bebopDrone disconnect];
        // wait for the disconnection to appear
        dispatch_semaphore_wait(_stateSem, DISPATCH_TIME_FOREVER);
        _bebopDrone = nil;
        
        // dismiss the alert view in main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [_connectionAlertView dismissWithClickedButtonIndex:0 animated:YES];
        });
    });
}


#pragma mark BebopDroneDelegate
-(void)bebopDrone:(BebopDrone *)bebopDrone connectionDidChange:(eARCONTROLLER_DEVICE_STATE)state {
    switch (state) {
        case ARCONTROLLER_DEVICE_STATE_RUNNING:
            [_connectionAlertView dismissWithClickedButtonIndex:0 animated:YES];
            break;
        case ARCONTROLLER_DEVICE_STATE_STOPPED:
            dispatch_semaphore_signal(_stateSem);
            
            // Go back
            [self.navigationController popViewControllerAnimated:YES];
            
            break;
            
        default:
            break;
    }
}

- (void)bebopDrone:(BebopDrone*)bebopDrone batteryDidChange:(int)batteryPercentage {
    [_batteryLabel setText:[NSString stringWithFormat:@"%d%%", batteryPercentage]];
}

- (void)bebopDrone:(BebopDrone*)bebopDrone flyingStateDidChange:(eARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE)state {
    switch (state) {
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_LANDED:
            [_takeOffLandBt setTitle:@"Take off" forState:UIControlStateNormal];
            [_takeOffLandBt setEnabled:YES];
            [_downloadMediasBt setEnabled:YES];
            break;
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_FLYING:
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_HOVERING:
            [_takeOffLandBt setTitle:@"Land" forState:UIControlStateNormal];
            [_takeOffLandBt setEnabled:YES];
            [_downloadMediasBt setEnabled:NO];
            break;
        default:
            [_takeOffLandBt setEnabled:NO];
            [_downloadMediasBt setEnabled:NO];
    }
}

- (BOOL)bebopDrone:(BebopDrone*)bebopDrone configureDecoder:(ARCONTROLLER_Stream_Codec_t)codec {
    return [_videoView configureDecoder:codec];
}

- (BOOL)bebopDrone:(BebopDrone*)bebopDrone didReceiveFrame:(ARCONTROLLER_Frame_t*)frame {
    return [_videoView displayFrame:frame];
}

- (void)bebopDrone:(BebopDrone*)bebopDrone didFoundMatchingMedias:(NSUInteger)nbMedias {
    _nbMaxDownload = nbMedias;
    _currentDownloadIndex = 1;
    
    if (nbMedias > 0) {
        [_downloadAlertController setMessage:@"Downloading medias"];
        UIViewController *customVC = [[UIViewController alloc] init];
        _downloadProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        [_downloadProgressView setProgress:0];
        [customVC.view addSubview:_downloadProgressView];
        
        [customVC.view addConstraint:[NSLayoutConstraint
                                      constraintWithItem:_downloadProgressView
                                      attribute:NSLayoutAttributeCenterX
                                      relatedBy:NSLayoutRelationEqual
                                      toItem:customVC.view
                                      attribute:NSLayoutAttributeCenterX
                                      multiplier:1.0f
                                      constant:0.0f]];
        [customVC.view addConstraint:[NSLayoutConstraint
                                      constraintWithItem:_downloadProgressView
                                      attribute:NSLayoutAttributeBottom
                                      relatedBy:NSLayoutRelationEqual
                                      toItem:customVC.bottomLayoutGuide
                                      attribute:NSLayoutAttributeTop
                                      multiplier:1.0f
                                      constant:-20.0f]];
        
        [_downloadAlertController setValue:customVC forKey:@"contentViewController"];
    } else {
        [_downloadAlertController dismissViewControllerAnimated:YES completion:^{
            _downloadProgressView = nil;
            _downloadAlertController = nil;
        }];
    }
}

- (void)bebopDrone:(BebopDrone*)bebopDrone media:(NSString*)mediaName downloadDidProgress:(int)progress {
    float completedProgress = ((_currentDownloadIndex - 1) / (float)_nbMaxDownload);
    float currentProgress = (progress / 100.f) / (float)_nbMaxDownload;
    [_downloadProgressView setProgress:(completedProgress + currentProgress)];
}

- (void)bebopDrone:(BebopDrone*)bebopDrone mediaDownloadDidFinish:(NSString*)mediaName {
    _currentDownloadIndex++;
    
    if (_currentDownloadIndex > _nbMaxDownload) {
        [_downloadAlertController dismissViewControllerAnimated:YES completion:^{
            _downloadProgressView = nil;
            _downloadAlertController = nil;
        }];
        
    }
}

#pragma mark buttons click
- (IBAction)emergencyClicked:(id)sender {
    [_bebopDrone emergency];
}

- (IBAction)takeOffLandClicked:(id)sender {
    switch ([_bebopDrone flyingState]) {
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_LANDED:
            [_bebopDrone takeOff];
            break;
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_FLYING:
        case ARCOMMANDS_ARDRONE3_PILOTINGSTATE_FLYINGSTATECHANGED_STATE_HOVERING:
            [_bebopDrone land];
            break;
        default:
            break;
    }
}

- (IBAction)takePictureClicked:(id)sender {
    [_bebopDrone takePicture];
}

- (IBAction)downloadMediasClicked:(id)sender {
    [_downloadAlertController dismissViewControllerAnimated:YES completion:nil];
    
    _downloadAlertController = [UIAlertController alertControllerWithTitle:@"Download"
                                                                   message:@"Fetching medias"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                                         handler:^(UIAlertAction * action) {
                                                             [_bebopDrone cancelDownloadMedias];
                                                         }];
    [_downloadAlertController addAction:cancelAction];
    
    
    UIViewController *customVC = [[UIViewController alloc] init];
    UIActivityIndicatorView* spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    [spinner startAnimating];
    [customVC.view addSubview:spinner];
    
    [customVC.view addConstraint:[NSLayoutConstraint
                                  constraintWithItem: spinner
                                  attribute:NSLayoutAttributeCenterX
                                  relatedBy:NSLayoutRelationEqual
                                  toItem:customVC.view
                                  attribute:NSLayoutAttributeCenterX
                                  multiplier:1.0f
                                  constant:0.0f]];
    [customVC.view addConstraint:[NSLayoutConstraint
                                  constraintWithItem:spinner
                                  attribute:NSLayoutAttributeBottom
                                  relatedBy:NSLayoutRelationEqual
                                  toItem:customVC.bottomLayoutGuide
                                  attribute:NSLayoutAttributeTop
                                  multiplier:1.0f
                                  constant:-20.0f]];
    
    
    [_downloadAlertController setValue:customVC forKey:@"contentViewController"];
    
    [self presentViewController:_downloadAlertController animated:YES completion:nil];
    
    [_bebopDrone downloadMedias];
}

- (IBAction)gazUpTouchDown:(id)sender {
    [_bebopDrone setGaz:50];
}

- (IBAction)gazDownTouchDown:(id)sender {
    [_bebopDrone setGaz:-50];
}

- (IBAction)gazUpTouchUp:(id)sender {
    [_bebopDrone setGaz:0];
}

- (IBAction)gazDownTouchUp:(id)sender {
    [_bebopDrone setGaz:0];
}

- (IBAction)yawLeftTouchDown:(id)sender {
    [_bebopDrone setYaw:-50];
}

- (IBAction)yawRightTouchDown:(id)sender {
    [_bebopDrone setYaw:50];
}

- (IBAction)yawLeftTouchUp:(id)sender {
    [_bebopDrone setYaw:0];
}

- (IBAction)yawRightTouchUp:(id)sender {
    [_bebopDrone setYaw:0];
}

- (IBAction)rollLeftTouchDown:(id)sender {
    [_bebopDrone setFlag:1];
    [_bebopDrone setRoll:-50];
}

- (IBAction)rollRightTouchDown:(id)sender {
    [_bebopDrone setFlag:1];
    [_bebopDrone setRoll:50];
}

- (IBAction)rollLeftTouchUp:(id)sender {
    [_bebopDrone setFlag:0];
    [_bebopDrone setRoll:0];
}

- (IBAction)rollRightTouchUp:(id)sender {
    [_bebopDrone setFlag:0];
    [_bebopDrone setRoll:0];
}

- (IBAction)pitchForwardTouchDown:(id)sender {
    [_bebopDrone setFlag:1];
    [_bebopDrone setPitch:50];
}

- (IBAction)pitchBackTouchDown:(id)sender {
    [_bebopDrone setFlag:1];
    [_bebopDrone setPitch:-50];
}

- (IBAction)pitchForwardTouchUp:(id)sender {
    [_bebopDrone setFlag:0];
    [_bebopDrone setPitch:0];
}

- (IBAction)pitchBackTouchUp:(id)sender {
    [_bebopDrone setFlag:0];
    [_bebopDrone setPitch:0];
}



- (IBAction)outdoor:(id)sender{
    [_bebopDrone outDoorWifi:1];
}//アウトドアモード

-(IBAction)home:(id)sender{
    [_bebopDrone hm];
    NSLog(@"Home Button");
}


- (IBAction)moveRel:(id)sender{
    goX = [_toX.text floatValue];
    goY = [_toY.text floatValue];
    goZ = [_toZ.text floatValue];
    goR = [_toR.text floatValue];
    
    goZ = -goZ;
    goR = DEGREES_TO_RADIANS(goR);
    
    NSLog(@("%f%f%f%f"),goX,goY,goZ,goR);
    [_bebopDrone moveRel:goX dY:goY dZ:goZ dPsi:goR];
}//相対的な位置制御

-(IBAction)henkan:(id)sender{
    _lin = [NSMutableArray array]; //lin[行目]という、行ごとに分割する配列を作る
    _seg = [NSMutableArray array]; //seg[行目][個目]という、区切りごとに分割する配列を作る _lin = [self.moto.text componentsSeparatedByString:@"\n"];
    for (int i = 0; i < [_lin count]; i++) {
        _seg[i] = [_lin[i] componentsSeparatedByString:@" "];
    }
    _ikk = _seg;
    //ikk[行目][個目]という、実際の目標地点の緯度経度高度を格納する配列を seg と同じ大きさで作る
//    _r_ido = SEKIDO_R * cos(self.homeLocation.latitude * M_PI / 180);
    
    
    _nw_idm = 90 * 2 / (KYOKU_R * M_PI);
    _nw_kdm = 90 * 2 / (_r_ido * M_PI);
    
    float x_buf = 0.0;
    float y_buf = 0.0;
    float theta = 0.0;
    float alpha = 0.0;
//    float kakudo = [self.kkd.text floatValue];
    
    for(int i = 0; i<[_seg count]; i++){
        if([_seg[i][0] hasPrefix:@"G"] == 1 && [_seg[i][0] hasSuffix:@"1"] == 1){ //G1 の時の処理
            for(int j = 0; j<[_seg[i] count]; j++){ if([_seg[i][j] hasPrefix:@"X"] == 1) {
                x_buf = [[_seg[i][j] substringFromIndex:(1)] floatValue];
            }else if([_seg[i][j] hasPrefix:@"Y"] == 1) {
                y_buf = [[_seg[i][j] substringFromIndex:(1)] floatValue];
            }else if([_seg[i][j] hasPrefix:@"Z"] == 1) {
                _ikk[i][3] = [_seg[i][j] substringFromIndex:1];
            }else if([_seg[i][j] hasPrefix:@"F"] == 1) {
                _ikk[i][4] = [_seg[i][j] substringFromIndex:1];
            }else if([_seg[i][j] hasPrefix:@"R"] == 1) {
                _ikk[i][5] = [_seg[i][j] substringFromIndex:1];
                
            }
                if(j == [_seg[i] count]-1){
                    //j が[_seg[i] count]-1 の時、つまり for 文の最後 if(x_buf == 0){
                    if(y_buf==0){ theta = 0;
                    }else if(y_buf>0){ theta = 90;
                    }else{
                        theta = -90;
                    }
                }else if(y_buf == 0){
                    if(x_buf>0){ theta = 0;
                    }else{
                        theta = 180;
                    } }else{
                        theta = RAD_TO_DEG(atan(y_buf/x_buf));
                        //theta を Degree で }
//                        alpha = DEG_TO_RAD(theta + kakudo); //theta に、角度をつけた alpha を
//                        _ikk[i][1] = [NSString stringWithFormat:@"%f",self.homeLocation.latitude + _nw_kdm * sqrt(x_buf * x_buf + y_buf * y_buf) * cos(alpha)];
//                        _ikk[i][2] = [NSString stringWithFormat:@"%f",self.homeLocation.longitude + _nw_idm * sqrt(x_buf * x_buf + y_buf * y_buf) * sin(alpha)];
                        //ホームポイントの緯度経度、1m あたりの緯度経度の変化量、角度から XY を算出
                    }
                
                
            }
        }else if([_seg[i][0] hasPrefix:@"G"] == 1 && [_seg[i][0] hasSuffix:@"4"] == 1){
            //G4 の時の処理
            for(int j = 0; j<[_seg[i] count]; j++){
                if([_seg[i][j] hasPrefix:@"P"] == 1) {
                    _ikk[i][1] = [_seg[i][j] substringFromIndex:1];
                } }
        }else if([_seg[i][0] hasPrefix:@"G"] == 1 && [_seg[i][0] hasSuffix:@"28"] == 1){ //ホームに行く処理
        }
    }
}

- (IBAction)mavstart:(id)sender{
    [_bebopDrone createDataTransferManager];
    //[_bebopDrone testWaypoint];
}

- (IBAction)stpMav:(id)sender{
    [_bebopDrone stpAutoFlight];
}

- (IBAction)see_file:(id)sender{
    [_bebopDrone aiueo];
}

- (IBAction)mvdrn:(id)sender{
    [_bebopDrone mvdrn:1 roll:1 pitch:1 yaw:50 gaz:1 timestampAndSeqNum:2];
}//これに関してはよくわからない

@end
