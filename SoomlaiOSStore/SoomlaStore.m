/*
 Copyright (C) 2012-2014 Soomla Inc.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "SoomlaStore.h"
#import "StoreConfig.h"
#import "StorageManager.h"
#import "StoreInfo.h"
#import "StoreEventHandling.h"
#import "VirtualGood.h"
#import "VirtualCategory.h"
#import "VirtualCurrency.h"
#import "VirtualCurrencyPack.h"
#import "VirtualCurrencyStorage.h"
#import "VirtualGoodStorage.h"
#import "InsufficientFundsException.h"
#import "NotEnoughGoodsException.h"
#import "VirtualItemNotFoundException.h"
#import "MarketItem.h"
#import "SoomlaUtils.h"
#import "PurchaseWithMarket.h"

#import "SoomlaVerification.h"

#import "VerifyStoreReceipt.h"

#define SOOMLA_STORE_VERSION @"3.6.22"

@interface SoomlaStore (){
    NSMutableArray* verifications;
}
@end


@implementation SoomlaStore

@synthesize initialized;

static NSString* TAG = @"SOOMLA SoomlaStore";

+ (SoomlaStore*)getInstance{
    static SoomlaStore* _instance = nil;

    @synchronized( self ) {
        if( _instance == nil ) {
            _instance = [[SoomlaStore alloc] init];
        }
    }

    return _instance;
}

+ (NSString*)getVersion {
    return SOOMLA_STORE_VERSION;
}

- (BOOL)initializeWithStoreAssets:(id<IStoreAssets>)storeAssets {
    if (self.initialized) {
        LogDebug(TAG, @"SoomlaStore already initialized.");
        return NO;
    }
    
    LogDebug(TAG, @"SoomlaStore Initializing ...");
    
    [StorageManager getInstance];
    [[StoreInfo getInstance] setStoreAssets:storeAssets];

    [self loadBillingService];

    [self refreshMarketItemsDetails];

    [self verifySubscriptions];

    self.initialized = YES;
    [StoreEventHandling postSoomlaStoreInitialized];

    return YES;
}

- (void)requestDidFinish:(SKRequest *)request {
  LogDebug(TAG, @"App store receipt request finished");
  [self verifySubscriptions];
}

- (void)verifySubscriptions {
  // perform local receipt verification to check for renewed or expired subscriptions
  NSURL *receiptPath = [[NSBundle mainBundle] appStoreReceiptURL];
  NSString *path = receiptPath.path;
  
  LogDebug(TAG, ([NSString stringWithFormat:@"Verify app store receipt at path: %@", path]));
  if(![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    LogDebug(TAG, @"Receipt does not exist yet, requesting...");

    SKReceiptRefreshRequest *receiptRequest = [[SKReceiptRefreshRequest alloc] initWithReceiptProperties:nil];
    receiptRequest.delegate = self;
    [receiptRequest start];
  } else if([VerifyStoreReceipt verifyReceiptAtPath:path]) {
    LogDebug(TAG, @"App has valid receipt. Check for IAP receipts now.");
    
    NSDateFormatter *isoDate = [NSDateFormatter new];
    isoDate.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    isoDate.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    
    NSMutableDictionary *latestExpiryDatePerProduct = [NSMutableDictionary new];
    NSArray *iapDataArray = [VerifyStoreReceipt obtainInAppPurchases:path];
    for(NSDictionary *iapData in iapDataArray) {
      NSString *itemId = iapData[@"ProductIdentifier"];
      PurchasableVirtualItem *pvi;
      @try {
        // purchasableItemWithProductId: throws exception if the item does not exist
        // this happens if the user has previously bought an IAP (non-consumable or subscription)
        // and the developer removed/changed product IDs afterwards
        pvi = [[StoreInfo getInstance] purchasableItemWithProductId:itemId];
      } @catch(VirtualItemNotFoundException *ex) {
        LogError(TAG, ([NSString stringWithFormat:@"Couldn't find the VirtualCurrencyPack OR MarketItem with productId: %@ from the IAP receipt"
                        @". It's unexpected so an unexpected error is being emitted.", itemId]));
        
        [StoreEventHandling postUnexpectedError:ERR_GENERAL forObject:self];
        continue;
      }
      
      if(pvi == nil || ![pvi.purchaseType isKindOfClass:[PurchaseWithMarket class]]) {
        continue;
      }
      
      if(!((PurchaseWithMarket *)pvi.purchaseType).isSubscription) {
        LogDebug(TAG, ([NSString stringWithFormat:@"Receipt for non-consumable item \"%@\" found, setting purchased to true.", pvi.itemId]));
          
        [pvi resetBalance:1];
      } else if(iapData[@"SubExpDate"]) {
        // found receipt for a subscription
        LogDebug(TAG, ([NSString stringWithFormat:@"Receipt for subscription item \"%@\" found: %@", pvi.itemId, iapData]));
        
        NSDate *expireDate = [isoDate dateFromString:iapData[@"SubExpDate"]];
        NSDate *latest = [latestExpiryDatePerProduct objectForKey:itemId];
          
        if(latest == nil || [expireDate compare:latest] == NSOrderedDescending) {
          [latestExpiryDatePerProduct setValue:expireDate forKey:itemId];
        }
      }
    }
      
    for(NSString *itemId in latestExpiryDatePerProduct) {
      PurchasableVirtualItem *pvi;
      @try {
        // purchasableItemWithProductId: throws exception if the item does not exist
        // this happens if the user has previously bought an IAP (non-consumable or subscription)
        // and the developer removed/changed product IDs afterwards
        pvi = [[StoreInfo getInstance] purchasableItemWithProductId:itemId];
      } @catch(VirtualItemNotFoundException *ex) {
        LogError(TAG, ([NSString stringWithFormat:@"Couldn't find the VirtualCurrencyPack OR MarketItem with productId: %@ from the IAP receipt"
                        @". It's unexpected so an unexpected error is being emitted.", itemId]));
          
        [StoreEventHandling postUnexpectedError:ERR_GENERAL forObject:self];
        continue;
      }
        
      if(pvi == nil || ![pvi.purchaseType isKindOfClass:[PurchaseWithMarket class]]) {
        continue;
      }

      // sub expire date is after current date
      // NOTE: checking local date is not optimal as users can just change the date in settings
      NSDate *expireDate = [latestExpiryDatePerProduct objectForKey:itemId];
      NSDate *now = [NSDate date];
        
      LogDebug(TAG, ([NSString stringWithFormat:@"Subscription expire date for item %@: %@, current date: %@", itemId, expireDate, now]));
      if([expireDate compare:now] == NSOrderedDescending) {
        LogDebug(TAG, @"Subscription still active, setting purchased to true.");
        [pvi resetBalance:1];
      } else {
        LogDebug(TAG, @"Subscription not active, setting purchased to false.");
        [pvi resetBalance:0];
      }
    }
  } else {
    LogError(TAG, @"Appstore receipt is invalid. Cannot check for active subscriptions.");
  }
}

- (void)loadBillingService {
    if ([SKPaymentQueue canMakePayments]) {
        [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
        [StoreEventHandling postBillingSupported];
        if (!verifications) {
            verifications = [NSMutableArray array];
        }
        [self retryUnfinishedTransactions];
    } else {
        [StoreEventHandling postBillingNotSupported];
    }
}

- (void)retryUnfinishedTransactions {
    NSArray* transactions = [[SKPaymentQueue defaultQueue] transactions];
    LogDebug(TAG, ([NSString stringWithFormat:@"Retrying any unfinished transactions: %lu", (unsigned long)transactions.count]));
    [self paymentQueue:[SKPaymentQueue defaultQueue] updatedTransactions:transactions];
}

static NSString* developerPayload = NULL;
- (BOOL)buyInMarketWithMarketItem:(MarketItem*)marketItem andPayload:(NSString*)payload{

    if ([SKPaymentQueue canMakePayments]) {
        SKMutablePayment *payment = [[SKMutablePayment alloc] init] ;
        payment.productIdentifier = marketItem.productId;
        payment.quantity = 1;
        developerPayload = payload;
        [[SKPaymentQueue defaultQueue] addPayment:payment];

        @try {
            PurchasableVirtualItem* pvi = [[StoreInfo getInstance] purchasableItemWithProductId:marketItem.productId];
            [StoreEventHandling postMarketPurchaseStarted:pvi];
        }
        @catch (NSException *exception) {
            LogError(TAG, ([NSString stringWithFormat:@"Couldn't find a purchasable item with productId: %@", marketItem.productId]));
        }
    } else {
        LogError(TAG, @"Can't make purchases. Parental control is probably enabled.");
        return NO;
    }

    return YES;
}

- (void) refreshInventory {
    [self restoreTransactions];
    [self refreshMarketItemsDetails];
}

- (void)restoreTransactions {
    [self verifySubscriptions];
  
    if ([SKPaymentQueue canMakePayments]) {
        [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
    }

    [StoreEventHandling postRestoreTransactionsStarted];
}

- (BOOL)transactionsAlreadyRestored {
    // Defaults to NO
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"RESTORED"];
}

#pragma mark -
#pragma mark SKPaymentTransactionObserver methods

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions
{
    for (SKPaymentTransaction *transaction in transactions)
    {
        switch (transaction.transactionState)
        {
            case SKPaymentTransactionStatePurchased:
                [self completeTransaction:transaction];
                break;
            case SKPaymentTransactionStateFailed:
                [self failedTransaction:transaction];
                break;
            case SKPaymentTransactionStateRestored:
                [self restoreTransaction:transaction];
                break;
            case SKPaymentTransactionStateDeferred:
                // Do not block your UI. Allow the user to continue using your app.
                [self deferTransaction:transaction];
                break;
        }
    }
}

// from http://stackoverflow.com/questions/2197362/converting-nsdata-to-base64
- (NSString*)base64forData:(NSData*)theData {
    const uint8_t* input = (const uint8_t*)[theData bytes];
    NSInteger length = [theData length];
    static char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
    NSMutableData* data = [NSMutableData dataWithLength:((length + 2) / 3) * 4];
    uint8_t* output = (uint8_t*)data.mutableBytes;
    NSInteger i;
    for (i=0; i < length; i += 3) {
        NSInteger value = 0;
        NSInteger j;
        for (j = i; j < (i + 3); j++) {
            value <<= 8;
            
            if (j < length) {
                value |= (0xFF & input[j]);
            }
        }
        NSInteger theIndex = (i / 3) * 4;
        output[theIndex + 0] =                    table[(value >> 18) & 0x3F];
        output[theIndex + 1] =                    table[(value >> 12) & 0x3F];
        output[theIndex + 2] = (i + 1) < length ? table[(value >> 6)  & 0x3F] : '=';
        output[theIndex + 3] = (i + 2) < length ? table[(value >> 0)  & 0x3F] : '=';
    }
    return [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
}

- (void)finalizeTransaction:(SKPaymentTransaction *)transaction isRestored:(BOOL)isRestored forPurchasable:(PurchasableVirtualItem*)pvi {
    if ([StoreInfo isItemNonConsumable:pvi]){
        int balance = [[[StorageManager getInstance] virtualItemStorage:pvi] balanceForItem:pvi.itemId];
        if (balance == 1){
            // Remove the transaction from the payment queue.
            [[SKPaymentQueue defaultQueue] finishTransaction: transaction];
            return;
        }
    }

    float version = [[[UIDevice currentDevice] systemVersion] floatValue];

    NSURL* receiptUrl = [NSURL URLWithString:@"file:///"];
    if (version >= 7) {
        receiptUrl = [[NSBundle mainBundle] appStoreReceiptURL];
    }
    NSString* receiptUrlStr = @"";
    if (receiptUrl) {
        receiptUrlStr = [receiptUrl absoluteString];
    }
    
    NSString *receiptString = @"";
    if ([[NSFileManager defaultManager] fileExistsAtPath:[receiptUrl path]]) {
        
        NSData *receiptData = [NSData dataWithContentsOfURL:receiptUrl];
        
        receiptString = [self base64forData:receiptData];
        if (receiptString == nil) {
            receiptString = @"";
        }
    }

    NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateStyle = NSDateFormatterShortStyle;
    NSString* transactionDateStr = [dateFormatter stringFromDate:transaction.transactionDate];
    
    NSString* originalDateStr = transaction.originalTransaction ? [dateFormatter stringFromDate:transaction.originalTransaction.transactionDate] : transactionDateStr;
    
    if (receiptUrlStr && transaction.transactionIdentifier && receiptString && transactionDateStr) {
        
        [StoreEventHandling postMarketPurchase:pvi isRestored:isRestored withExtraInfo:@{
                                                                   @"receiptUrl": receiptUrlStr,
                                                                   @"transactionIdentifier": transaction.transactionIdentifier,
                                                                   @"receiptBase64": receiptString,
                                                                   @"transactionDate": transactionDateStr,
                                                                   @"originalTransactionDate": originalDateStr,
                                                                   @"originalTransactionIdentifier": transaction.originalTransaction ? transaction.originalTransaction.transactionIdentifier : transaction.transactionIdentifier
                                                                   }
                                    andPayload:developerPayload];
        
        [pvi giveAmount:1];
        [StoreEventHandling postItemPurchased:pvi.itemId isRestored:isRestored withPayload:developerPayload];
        developerPayload = NULL;
        
        // Remove the transaction from the payment queue.
        [[SKPaymentQueue defaultQueue] finishTransaction: transaction];
        
    } else {
        
        LogError(TAG, ([NSString stringWithFormat:@"Transaction for %@ has missing info! The user will not get what he just bought.", transaction.payment.productIdentifier]));
        [self finishFailedTransaction:transaction];
        
    }
}

- (void)purchaseVerified:(NSNotification*)notification {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:EVENT_MARKET_PURCHASE_VERIF object:notification.object];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:EVENT_UNEXPECTED_STORE_ERROR object:notification.object];
    
    NSDictionary* userInfo = notification.userInfo;
    PurchasableVirtualItem* purchasable = [userInfo objectForKey:DICT_ELEMENT_PURCHASABLE];
    BOOL verified = [(NSNumber*)[userInfo objectForKey:DICT_ELEMENT_VERIFIED] boolValue];
    SKPaymentTransaction* transaction = [userInfo objectForKey:DICT_ELEMENT_TRANSACTION];
    BOOL isRestored = [(NSNumber *)userInfo[DICT_ELEMENT_IS_RESTORED] boolValue];

    if (verified) {
        [self finalizeTransaction:transaction isRestored:isRestored forPurchasable:purchasable];
    } else {
        LogError(TAG, ([NSString stringWithFormat:@"Failed to verify transaction receipt for %@. The user will not get what he just bought.", purchasable]));
        [self finishFailedTransaction:transaction];
    }
    
    [verifications removeObject:notification.object];
}

- (void)finishFailedTransaction:(SKPaymentTransaction *)transaction {
    [[SKPaymentQueue defaultQueue] finishTransaction: transaction];
    [StoreEventHandling postUnexpectedError:ERR_VERIFICATION_FAIL forObject:self];
}

- (void)unexpectedVerificationError:(NSNotification*)notification{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:EVENT_MARKET_PURCHASE_VERIF object:notification.object];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:EVENT_UNEXPECTED_STORE_ERROR object:notification.object];
    [verifications removeObject:notification.object];
}

-(void)givePurchasedItem:(SKPaymentTransaction *)transaction isRestored:(BOOL)isRestored {
    @try {
        PurchasableVirtualItem* pvi = [[StoreInfo getInstance] purchasableItemWithProductId:transaction.payment.productIdentifier];

        if (VERIFY_PURCHASES) {
            [StoreEventHandling postVerificationStarted:pvi];

            SoomlaVerification *sv = [[SoomlaVerification alloc] initWithTransaction:transaction andPurchasable:pvi isRestored:isRestored];

            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(purchaseVerified:) name:EVENT_MARKET_PURCHASE_VERIF object:sv];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(unexpectedVerificationError:) name:EVENT_UNEXPECTED_STORE_ERROR object:sv];

            [sv verifyData];

            [verifications addObject:sv];
        } else {
            [self finalizeTransaction:transaction isRestored:isRestored forPurchasable:pvi];
        }

    } @catch (VirtualItemNotFoundException* e) {
        LogError(TAG, ([NSString stringWithFormat:@"An error occured when handling completed purchase for PurchasableVirtualItem with productId: %@"
                                                          @". It's unexpected so an unexpected error is being emitted.", transaction.payment.productIdentifier]));
        [StoreEventHandling postUnexpectedError:ERR_PURCHASE_FAIL forObject:self];
        [[SKPaymentQueue defaultQueue] finishTransaction: transaction];
    }
}

- (void)givePurchasedItem:(SKPaymentTransaction *)transaction {
    [self givePurchasedItem:transaction isRestored:NO];
}

- (void) completeTransaction: (SKPaymentTransaction *)transaction
{
    LogDebug(TAG, ([NSString stringWithFormat:@"Transaction completed for product: %@", transaction.payment.productIdentifier]));
    [self givePurchasedItem:transaction];
}

- (void)paymentQueue:(SKPaymentQueue *)queue removedTransactions:(NSArray *)transactions {
    LogDebug(TAG, @"removedTransactions was called");
}

- (void) restoreTransaction: (SKPaymentTransaction *)transaction
{
    @try {
      PurchasableVirtualItem* pvi = [[StoreInfo getInstance] purchasableItemWithProductId:transaction.payment.productIdentifier];
      if([pvi.purchaseType isKindOfClass:[PurchaseWithMarket class]] &&
         ((PurchaseWithMarket *)pvi.purchaseType).isSubscription) {
        LogDebug(TAG, @"Not restoring subscription transaction");
        return;
      }
    }
    @catch (VirtualItemNotFoundException* e) {
      LogError(TAG, ([NSString stringWithFormat:@"Couldn't find the RESTORED VirtualCurrencyPack OR MarketItem with productId: %@"
                      @". It's unexpected so an unexpected error is being emitted.", transaction.payment.productIdentifier]));
      
      [StoreEventHandling postUnexpectedError:ERR_GENERAL forObject:self];
    }
  
    LogDebug(TAG, ([NSString stringWithFormat:@"Restore transaction for product: %@", transaction.payment.productIdentifier]));
    [self givePurchasedItem:transaction isRestored:YES];
}

- (void) failedTransaction: (SKPaymentTransaction *)transaction
{
    if (transaction.error.code != SKErrorPaymentCancelled) {
        LogError(TAG, ([NSString stringWithFormat:@"An error occured for product id \"%@\" with code \"%ld\" and description \"%@\"", transaction.payment.productIdentifier, (long)transaction.error.code, transaction.error.debugDescription]));

        [StoreEventHandling postUnexpectedError:ERR_PURCHASE_FAIL forObject:self];
    }
    else{

        @try {
            PurchasableVirtualItem* pvi = [[StoreInfo getInstance] purchasableItemWithProductId:transaction.payment.productIdentifier];

            [StoreEventHandling postMarketPurchaseCancelled:pvi];
        }
        @catch (VirtualItemNotFoundException* e) {
            LogError(TAG, ([NSString stringWithFormat:@"Couldn't find the CANCELLED VirtualCurrencyPack OR MarketItem with productId: %@"
                            @". It's unexpected so an unexpected error is being emitted.", transaction.payment.productIdentifier]));
            
            [StoreEventHandling postUnexpectedError:ERR_GENERAL forObject:self];
        }

    }
    [[SKPaymentQueue defaultQueue] finishTransaction: transaction];
}

- (void) deferTransaction: (SKPaymentTransaction *)transaction {
    LogDebug(TAG, ([NSString stringWithFormat:@"Defer transaction for product: %@", transaction.payment.productIdentifier]));
    @try {
        PurchasableVirtualItem* pvi = [[StoreInfo getInstance] purchasableItemWithProductId:transaction.payment.productIdentifier];
        [StoreEventHandling postMarketPurchaseDeferred:pvi andPayload:developerPayload];
    } @catch (VirtualItemNotFoundException* e) {
        LogError(TAG, ([NSString stringWithFormat:@"Couldn't find the DEFERRED VirtualCurrencyPack OR MarketItem with productId: %@"
                        @". It's unexpected so an unexpected error is being emitted.", transaction.payment.productIdentifier]));
        [StoreEventHandling postUnexpectedError:ERR_PURCHASE_FAIL forObject:self];
        [[SKPaymentQueue defaultQueue] finishTransaction: transaction];
    }
    
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"RESTORED"];
    [defaults synchronize];
    
    [StoreEventHandling postRestoreTransactionsFinished:YES];
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
    [StoreEventHandling postRestoreTransactionsFinished:NO];
}


- (void)refreshMarketItemsDetails {
    SKProductsRequest *productsRequest = [[SKProductsRequest alloc] initWithProductIdentifiers:[[NSSet alloc] initWithArray:[[StoreInfo getInstance] allProductIds]]];
    productsRequest.delegate = self;
    [productsRequest start];
    [StoreEventHandling postMarketItemsRefreshStarted];
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response
{
    NSMutableArray* virtualItems = [NSMutableArray array];
    NSMutableArray* marketItems = [NSMutableArray array];
    NSArray *products = response.products;
    for(SKProduct* product in products) {
        NSString* title = product.localizedTitle;
        NSString* description = product.localizedDescription;
        NSDecimalNumber* price = product.price;
        NSLocale* locale = product.priceLocale;
        NSString* productId = product.productIdentifier;
        LogDebug(TAG, ([NSString stringWithFormat:@"title: %@  price: %@  productId: %@  desc: %@",title,[price descriptionWithLocale:locale],productId,description]));

        @try {
            PurchasableVirtualItem* pvi = [[StoreInfo getInstance] purchasableItemWithProductId:productId];

            PurchaseType* purchaseType = pvi.purchaseType;
            if ([purchaseType isKindOfClass:[PurchaseWithMarket class]]) {
                MarketItem* mi = ((PurchaseWithMarket*)purchaseType).marketItem;
                [mi setMarketInformation:[MarketItem priceWithCurrencySymbol:locale andPrice:price andBackupPrice:mi.price]
                          andTitle:title
                          andDescription:description
                          andCurrencyCode:[locale objectForKey:NSLocaleCurrencyCode]
                          andPriceMicros:(product.price.floatValue * 1000000)];

                [marketItems addObject:mi];
                [virtualItems addObject:pvi];
            }
        }
        @catch (VirtualItemNotFoundException* e) {
            LogError(TAG, ([NSString stringWithFormat:@"Couldn't find the PurchasableVirtualItem with productId: %@"
                            @". It's unexpected so an unexpected error is being emitted.", productId]));
            [StoreEventHandling postUnexpectedError:ERR_GENERAL forObject:self];
        }
    }

    for (NSString *invalidProductId in response.invalidProductIdentifiers)
    {
        LogError(TAG, ([NSString stringWithFormat: @"Invalid product id (when trying to fetch item details): %@" , invalidProductId]));
    }

    NSUInteger idsCount = [[[StoreInfo getInstance] allProductIds] count];
    NSUInteger productsCount = [products count];
    if (idsCount != productsCount)
    {
        LogError(TAG, ([NSString stringWithFormat: @"Expecting %d products but only fetched %d from iTunes Store" , (int)idsCount, (int)productsCount]));
    }
    
    if (virtualItems.count > 0) {
        [[StoreInfo getInstance] saveWithVirtualItems:virtualItems];
    }

    [StoreEventHandling postMarketItemsRefreshFinished:marketItems];
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
    LogError(TAG, ([NSString stringWithFormat:@"Market items details failed to refresh: %@", error.localizedDescription]));
    
    [StoreEventHandling postMarketItemsRefreshFailed:error.localizedDescription];
}


@end
