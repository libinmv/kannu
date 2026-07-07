#import "QuickShareServiceDiscovery.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

NSArray<NSSharingService *> *KannuSharingServicesForItems(NSArray *items) {
    return [NSSharingService sharingServicesForItems:items];
}

#pragma clang diagnostic pop
