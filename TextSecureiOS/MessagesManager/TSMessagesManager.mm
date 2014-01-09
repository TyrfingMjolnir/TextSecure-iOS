//
//  MessagesManager.m
//  TextSecureiOS
//
//  Created by Frederic Jacobs on 30/11/13.
//  Copyright (c) 2013 Open Whisper Systems. All rights reserved.
//

#import "TSMessagesManager.h"
#import "TSContact.h"
#import "NSData+Base64.h"
#import "TSSubmitMessageRequest.h"
#import "TSMessagesManager.h"
#import "TSKeyManager.h"
#import "Cryptography.h"
#import "TSMessage.h"
#import "TSMessagesDatabase.h"
#import "TSUserKeysDatabase.h"
#import "TSThread.h"
#import "TSMessageSignal.hh"
#import "TSPushMessageContent.hh"
#import "TSWhisperMessage.hh"
#import "TSEncryptedWhisperMessage.hh"
#import "TSPreKeyWhisperMessage.hh"
#import "TSECKeyPair.h"
#import "TSRecipientPrekeyRequest.h"

#import "TSHKDF.h"


@implementation TSMessagesManager

+ (id)sharedManager {
    static TSMessagesManager *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] init];
    });
    return sharedMyManager;
}

- (id)init {
    if (self = [super init]) {
        
    }
    return self;
}

- (void)processPushNotification:(NSDictionary *)pushInfo{
  // obviously
  NSData *payload = [NSData dataFromBase64String:[pushInfo objectForKey:@"m"]];
  unsigned char version[1];
  unsigned char iv[16];
  int ciphertext_length=([payload length]-10-17)*sizeof(char);
  unsigned char *ciphertext =  (unsigned char*)malloc(ciphertext_length);
  unsigned char mac[10];
  [payload getBytes:version range:NSMakeRange(0, 1)];
  [payload getBytes:iv range:NSMakeRange(1, 16)];
  [payload getBytes:ciphertext range:NSMakeRange(17, [payload length]-10-17)];
  [payload getBytes:mac range:NSMakeRange([payload length]-10, 10)];
  
  
  NSData* signalingKey = [NSData dataFromBase64String:[TSKeyManager getSignalingKeyToken]];
  // Actually only the first 32 bits of this are the crypto key
  NSData* signalingKeyAESKeyMaterial = [signalingKey subdataWithRange:NSMakeRange(0, 32)];
  NSData* signalingKeyHMACKeyMaterial = [signalingKey subdataWithRange:NSMakeRange(32, 20)];
  NSData* decryptedPayload=[Cryptography decrypt:[NSData dataWithBytes:ciphertext length:ciphertext_length] withKey:signalingKeyAESKeyMaterial withIV:[NSData dataWithBytes:iv length:16] withVersion:[NSData dataWithBytes:version length:1] withHMACKey:signalingKeyHMACKeyMaterial forHMAC:[NSData dataWithBytes:mac length:10]];
  // Now get the protocol buffer message out
  TSMessageSignal *messageSignal = [[TSMessageSignal alloc] initWithData:decryptedPayload];

  TSMessage* message = [self decryptMessageSignal:messageSignal];
  message.recipientId = [TSKeyManager getUsernameToken]; // recipient is me!
  
  [TSMessagesDatabase storeMessage:message];
  UIAlertView *pushAlert = [[UIAlertView alloc] initWithTitle:@"you have a new message" message:@"" delegate:self cancelButtonTitle:@"OK" otherButtonTitles:nil, nil];
  [[NSNotificationCenter defaultCenter] postNotificationName:TSDatabaseDidUpdateNotification object:self userInfo:@{@"messageType":@"receive"}];
  [pushAlert show];

}


#pragma mark TSProtocol Methods
-(void) encryptTSWhisperMessage:(TSEncryptedWhisperMessage*)message onThread:(TSThread*)thread {

  
  
}
-(TSMessage*) decryptMessageSignal:(TSMessageSignal*)messageSignal  {

  
  // This protocol buffer has a type which indicates whether its encrypted message is encapsulated in the PreKeyWhisperMessage format or the WhisperMessage format, it also has e.g. source, destination and timstame
  
  // sets [thread.receiveEphemerals setReceiveEphemerals];
  // This allocation will update the keys as needed
  // All the ephemeral and persistant variables are updated, so we can go through the decryption process!
  switch (messageSignal.contentType) {
    case TSEncryptedWhisperMessageType:
#warning not implemented
      break;
    case TSPreKeyWhisperMessageType:
#warning not implemented
      [self initialRootKeyDerivation:(TSPreKeyWhisperMessage*)messageSignal.message forParty:TSReceiver];
      break;
    case TSUnencryptedWhisperMessageType: {
      TSPushMessageContent* messageContent = [[TSPushMessageContent alloc] initWithData:messageSignal.message.message];
      return [messageSignal getTSMessage:messageContent];
      break;
    }
    default:
      break;
  }
  return nil;
}

-(void) sendMessage:(TSMessage*)message onThread:(TSThread*)thread ofType:(TSWhisperMessageType) messageType{
  [TSMessagesDatabase storeMessage:message];
  __block NSString *serializedMessage=@"";
  switch (messageType) {
    case TSEncryptedWhisperMessageType: {
      // let's go ahead and encrypt and update our keys
      TSEncryptedWhisperMessage *encryptedMessage = [[TSEncryptedWhisperMessage alloc] init];
      TSECKeyPair* ephemeralKey =[TSECKeyPair keyPairGenerateWithPreKeyId:0];
      
      encryptedMessage.ephemeralKey = [ephemeralKey getPublicKey];
      encryptedMessage.counter = [TSMessagesDatabase getN:thread forParty:TSSender];
      encryptedMessage.previousCounter = [TSMessagesDatabase getPNs:thread];
      break;
    }
    case TSPreKeyWhisperMessageType:{
        // get a contact's prekey
        TSContact* contact = [[TSContact alloc] initWithRegisteredID:message.recipientId];
        [[TSNetworkManager sharedManager] queueAuthenticatedRequest:[[TSRecipientPrekeyRequest alloc] initWithRecipient:contact] success:^(AFHTTPRequestOperation *operation, id responseObject) {
          switch (operation.response.statusCode) {
            case 200:{
              
              TSPreKeyWhisperMessage *prekeyMessage = [[TSPreKeyWhisperMessage alloc] init];
              prekeyMessage.preKeyId = [responseObject objectForKey:@"keyId"];
              prekeyMessage.recipientPreKey = [NSData dataFromBase64String:[responseObject objectForKey:@"publicKey"]];
              prekeyMessage.recipientIdentityKey = [NSData dataFromBase64String:[responseObject objectForKey:@"identityKey"]];
              [self initialRootKeyDerivation:prekeyMessage forParty:TSSender];
              TSEncryptedWhisperMessage *encryptedWhisperMessage = [[TSEncryptedWhisperMessage alloc] init];
              NSData* ephemeralKeyPublic = [self createNewChainFromTheirPublicKey:prekeyMessage.recipientPreKey];
              encryptedWhisperMessage.ephemeralKey = ephemeralKeyPublic;
              encryptedWhisperMessage.previousCounter=0;
              encryptedWhisperMessage.counter = 0;
              
              
              // So let's encrypt a message using this
              [self encryptTSWhisperMessage:encryptedWhisperMessage onThread:thread];
              
              //Finally let's serialize
              serializedMessage = [[encryptedWhisperMessage serializedProtocolBuffer] base64EncodedString];
              break;
            }
            default:
              DLog(@"error sending message");
  #warning Add error handling if not able to get contacts prekey
              break;
          }
        } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
  #warning right now it is not succesfully processing returned response, but is giving 200
          
        }];
      }
      
      break;
    case TSUnencryptedWhisperMessageType:
      serializedMessage= [[TSPushMessageContent serializedPushMessageContent:message] base64Encoding];
      break;
    default:
      break;
  }
  
  
  


  [[TSNetworkManager sharedManager] queueAuthenticatedRequest:[[TSSubmitMessageRequest alloc] initWithRecipient:message.recipientId message:serializedMessage] success:^(AFHTTPRequestOperation *operation, id responseObject) {
    
    switch (operation.response.statusCode) {
      case 200:
        DLog(@"we have some success information %@",responseObject);
        // So let's encrypt a message using this
        break;
        
      default:
        DLog(@"error sending message");
#warning Add error handling if not able to get contacts prekey
        break;
    }
  } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
#warning right now it is not succesfully processing returned response, but is giving 200
    DLog(@"failure %d, %@, %@",operation.response.statusCode,operation.response.description,[[NSString alloc] initWithData:operation.responseData encoding:NSUTF8StringEncoding]);
    [[NSNotificationCenter defaultCenter] postNotificationName:TSDatabaseDidUpdateNotification object:self userInfo:@{@"messageType":@"send"}];
    
  }];
  
  
}

#pragma mark - AxolotlKeyAgreement protocol methods
-(NSData*)createNewChainFromTheirPublicKey:(NSData*)publicKey {
#warning store this
  TSECKeyPair* myEphemeralKey = [TSECKeyPair keyPairGenerateWithPreKeyId:0];
  // store this
  NSData* sharedSecret = [myEphemeralKey generateSharedSecretFromPublicKey:publicKey];
  return [myEphemeralKey getPublicKey];
  
}
-(void)initialRootKeyDerivation:(TSPreKeyWhisperMessage*)keyAgreementMessage forParty:(TSParty) party {
#warning this is crap
  NSData* masterKey;
  switch (party) {
    case TSSender: {
      // TSPrekeyWhisperMessage comes pre-populated with their prekey/ephemeral key/base key and their identity key
      TSECKeyPair *ourIdentityKey = [TSUserKeysDatabase getIdentityKeyWithError:nil];
      TSECKeyPair *ourEphemeralKey = [TSECKeyPair keyPairGenerateWithPreKeyId:0];
      
      masterKey = [self masterKeyAlice:ourIdentityKey ourEphemeral:ourEphemeralKey theirIdentityPublicKey:keyAgreementMessage.recipientIdentityKey theirEphemeralPublicKey:keyAgreementMessage.recipientPreKey];
      // TSPrekeyWhisperMessage comes we populate the TSPrekeyWhisperMessage instead with our public ephemeral key/base key and their identity key
      keyAgreementMessage.baseKey = [ourEphemeralKey getPublicKey];
      keyAgreementMessage.identityKey = [ourIdentityKey getPublicKey];
      
      break;
    }
    case TSReceiver: {
      TSECKeyPair *ourEphemeralKey = [TSUserKeysDatabase getPreKeyWithId:[keyAgreementMessage.preKeyId unsignedLongValue] error:nil];
      TSECKeyPair *ourIdentityKey =  [TSUserKeysDatabase getIdentityKeyWithError:nil];

      masterKey=[self masterKeyAlice:ourIdentityKey ourEphemeral:ourEphemeralKey theirIdentityPublicKey:keyAgreementMessage.baseKey theirEphemeralPublicKey:keyAgreementMessage.identityKey];
      break;
    }
    default:
      break;
  }
  
  /*
   The concatenated ECDHE shared secrets are then fed into HKDF to derive a 32 byte root key (RK) and 32 byte chain key (CK). HKDF is used with a salt of zero bytes and an info of the octet string "WhisperText".
   
   The first 32 bytes out of the HDKF are used for the root key (RK) and the second 32 bytes out are used for the chain key (CK).
   */
  NSData* rkCK = [TSHKDF deriveKeyFromMaterial:masterKey outputLength:64 info:[@"WhisperText" dataUsingEncoding:NSASCIIStringEncoding] salt:[NSData data]];
  
  NSData* RK = [rkCK subdataWithRange:NSMakeRange(0, 32)];
  NSData* CK = [rkCK subdataWithRange:NSMakeRange(32, 32)];
  

  
  
}
-(NSData*)masterKeyAlice:(TSECKeyPair*)ourIdentityKeyPair ourEphemeral:(TSECKeyPair*)ourEphemeralKeyPair theirIdentityPublicKey:(NSData*)theirIdentityPublicKey theirEphemeralPublicKey:(NSData*)theirEphemeralPublicKey {
  /*
  ECDH (private,public)
  ECDHE(theirEphemeral, ourIdentity)
  ECDHE(theirIdentity, ourEphemeral)
  ECDHE(theirEphemeral, ourEphemeral)
   */
  NSMutableData *masterKey = [NSMutableData data];
  [masterKey appendData:[ourIdentityKeyPair generateSharedSecretFromPublicKey:theirEphemeralPublicKey]];
  [masterKey appendData:[ourEphemeralKeyPair generateSharedSecretFromPublicKey:theirIdentityPublicKey]];
  [masterKey appendData:[ourEphemeralKeyPair generateSharedSecretFromPublicKey:theirEphemeralPublicKey]];
  return masterKey;
}

-(NSData*)masterKeyBob:(TSECKeyPair*)ourIdentityKeyPair ourEphemeral:(TSECKeyPair*)ourEphemeralKeyPair theirIdentityPublicKey:(NSData*)theirIdentityPublicKey theirEphemeralPublicKey:(NSData*)theirEphemeralPublicKey {
  /*
  ECDHE(theirIdentity, ourEphemeral)
  ECDHE(theirEphemeral, ourIdentity)
  ECDHE(theirEphemeral, ourEphemeral)
   */
  NSMutableData *masterKey = [NSMutableData data];
  [masterKey appendData:[ourEphemeralKeyPair generateSharedSecretFromPublicKey:theirIdentityPublicKey]];
  [masterKey appendData:[ourIdentityKeyPair generateSharedSecretFromPublicKey:theirEphemeralPublicKey]];
  [masterKey appendData:[ourEphemeralKeyPair generateSharedSecretFromPublicKey:theirEphemeralPublicKey]];
  return masterKey;
}
@end
