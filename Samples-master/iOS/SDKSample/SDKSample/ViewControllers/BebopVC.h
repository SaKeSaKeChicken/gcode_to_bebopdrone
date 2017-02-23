//
//  BebopVC.h
//  SDKSample
//

#import <UIKit/UIKit.h>
#import <libARDiscovery/ARDISCOVERY_BonjourDiscovery.h>

@interface BebopVC : UIViewController{
    IBOutlet UITextField *toX;
    IBOutlet UITextField *toY;
    IBOutlet UITextField *toZ;
    IBOutlet UITextField *toR;
    
    float goX;
    float goY;
    float goZ;
    float goR;
    
    IBOutlet UITextView *moto;
    
    IBOutlet UITextField *g_num;
    IBOutlet UITextField *x_num;
    IBOutlet UITextField *y_num;
    IBOutlet UITextField *z_num;
    IBOutlet UITextField *f_num;
    IBOutlet UITextField *r_num;
    
    IBOutlet UITextView *console;

    
}

-(IBAction)henkan:(id)sender;

@property (nonatomic, strong) ARService *service;


@end
