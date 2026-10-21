//  Mac2PhoneAudio — a CoreAudio virtual output device.
//
//  Anything an app plays into this device is written into a ring buffer and
//  handed straight back out on the device's input stream, so the mac2phone
//  server can pick it up and send it to the phone. Choosing it as the output
//  device is what makes the Mac's own speakers go quiet.
//
//  Lives inside coreaudiod, so: no allocation and no locking on the IO path.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - Constants

#define kDeviceUID          "Mac2PhoneAudioDevice"
#define kDeviceModelUID     "Mac2PhoneAudioModel"
#define kDeviceName         "Mac2Phone"
#define kManufacturerName   "Mac2Phone"
#define kBoxUID             "Mac2PhoneAudioBox"

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4
};

#define kChannelCount        2
#define kSampleRate          48000.0
#define kBytesPerFrame       (kChannelCount * (UInt32)sizeof(Float32))
// Power of two so the wrap is a mask. ~341 ms at 48 kHz — plenty of slack
// between the writing app and our reader without adding real latency.
#define kRingFrames          16384
#define kRingMask            (kRingFrames - 1)
#define kZeroTimeStampPeriod kRingFrames

#pragma mark - State

static pthread_mutex_t  gStateMutex     = PTHREAD_MUTEX_INITIALIZER;
static UInt32           gRefCount       = 0;
static AudioServerPlugInHostRef gHost   = NULL;

static UInt32           gIORunningCount = 0;
static Float64          gSampleRate     = kSampleRate;
static Float32          gRing[kRingFrames * kChannelCount];

// Zero-timestamp bookkeeping, all touched only from GetZeroTimeStamp.
static UInt64           gAnchorHostTime = 0;
static Float64          gAnchorSample   = 0;
static UInt64           gTimeStampCount = 0;
static Float64          gHostTicksPerFrame = 0;

static Boolean          gInputStreamActive  = true;
static Boolean          gOutputStreamActive = true;

static void EnsureTimebase(void)
{
    if (gHostTicksPerFrame != 0) return;
    struct mach_timebase_info info;
    mach_timebase_info(&info);
    Float64 hostTicksPerNanosecond = (Float64)info.denom / (Float64)info.numer;
    gHostTicksPerFrame = 1000000000.0 * hostTicksPerNanosecond / gSampleRate;
}

static void FillStreamFormat(AudioStreamBasicDescription* outFormat)
{
    memset(outFormat, 0, sizeof(AudioStreamBasicDescription));
    outFormat->mSampleRate       = gSampleRate;
    outFormat->mFormatID         = kAudioFormatLinearPCM;
    outFormat->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket   = kBytesPerFrame;
    outFormat->mFramesPerPacket  = 1;
    outFormat->mBytesPerFrame    = kBytesPerFrame;
    outFormat->mChannelsPerFrame = kChannelCount;
    outFormat->mBitsPerChannel   = 32;
}

#pragma mark - Prototypes

static HRESULT      Mac2Phone_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG        Mac2Phone_AddRef(void* inDriver);
static ULONG        Mac2Phone_Release(void* inDriver);
static OSStatus     Mac2Phone_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus     Mac2Phone_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus     Mac2Phone_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus     Mac2Phone_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     Mac2Phone_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus     Mac2Phone_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus     Mac2Phone_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean      Mac2Phone_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress);
static OSStatus     Mac2Phone_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus     Mac2Phone_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus     Mac2Phone_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus     Mac2Phone_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus     Mac2Phone_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     Mac2Phone_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus     Mac2Phone_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus     Mac2Phone_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus     Mac2Phone_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus     Mac2Phone_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus     Mac2Phone_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

#pragma mark - Interface

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Mac2Phone_QueryInterface,
    Mac2Phone_AddRef,
    Mac2Phone_Release,
    Mac2Phone_Initialize,
    Mac2Phone_CreateDevice,
    Mac2Phone_DestroyDevice,
    Mac2Phone_AddDeviceClient,
    Mac2Phone_RemoveDeviceClient,
    Mac2Phone_PerformDeviceConfigurationChange,
    Mac2Phone_AbortDeviceConfigurationChange,
    Mac2Phone_HasProperty,
    Mac2Phone_IsPropertySettable,
    Mac2Phone_GetPropertyDataSize,
    Mac2Phone_GetPropertyData,
    Mac2Phone_SetPropertyData,
    Mac2Phone_StartIO,
    Mac2Phone_StopIO,
    Mac2Phone_GetZeroTimeStamp,
    Mac2Phone_WillDoIOOperation,
    Mac2Phone_BeginIOOperation,
    Mac2Phone_DoIOOperation,
    Mac2Phone_EndIOOperation
};

static AudioServerPlugInDriverInterface*    gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef           gDriverRef    = &gInterfacePtr;

void* Mac2PhoneAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* Mac2PhoneAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}

#pragma mark - COM plumbing

static HRESULT Mac2Phone_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareIllegalOperationError;

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    Boolean match = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!match) return E_NOINTERFACE;

    pthread_mutex_lock(&gStateMutex);
    ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    *outInterface = gDriverRef;
    return S_OK;
}

static ULONG Mac2Phone_AddRef(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) ++gRefCount;
    ULONG value = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return value;
}

static ULONG Mac2Phone_Release(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) --gRefCount;
    ULONG value = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return value;
}

#pragma mark - Lifecycle

static OSStatus Mac2Phone_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    memset(gRing, 0, sizeof(gRing));
    EnsureTimebase();
    return 0;
}

static OSStatus Mac2Phone_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;   // the device is static
}

static OSStatus Mac2Phone_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Mac2Phone_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return 0;
}

static OSStatus Mac2Phone_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return 0;
}

static OSStatus Mac2Phone_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inChangeInfo;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (inChangeAction == 0) return 0;

    pthread_mutex_lock(&gStateMutex);
    gSampleRate = (Float64)inChangeAction;
    gHostTicksPerFrame = 0;
    EnsureTimebase();
    memset(gRing, 0, sizeof(gRing));
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus Mac2Phone_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return 0;
}

#pragma mark - Property helpers

static Boolean IsKnownObject(AudioObjectID inObjectID)
{
    return inObjectID == kObjectID_PlugIn || inObjectID == kObjectID_Device
        || inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output;
}

static OSStatus GetPlugInPropertySize(const AudioObjectPropertyAddress* inAddress, UInt32* outSize)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:              *outSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:     *outSize = sizeof(CFStringRef); return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:         *outSize = sizeof(AudioObjectID); return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice: *outSize = sizeof(AudioObjectID); return 0;
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDevicePropertySize(const AudioObjectPropertyAddress* inAddress, UInt32* outSize)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:              *outSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner:              *outSize = sizeof(AudioObjectID); return 0;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:           *outSize = sizeof(CFStringRef); return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            UInt32 count = 2;
            if (inAddress->mScope == kAudioObjectPropertyScopeInput) count = 1;
            else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) count = 1;
            *outSize = count * sizeof(AudioObjectID);
            return 0;
        }
        case kAudioObjectPropertyControlList:        *outSize = 0; return 0;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod: *outSize = sizeof(UInt32); return 0;
        case kAudioDevicePropertyRelatedDevices:     *outSize = sizeof(AudioObjectID); return 0;
        case kAudioDevicePropertyNominalSampleRate:  *outSize = sizeof(Float64); return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates: *outSize = 2 * sizeof(AudioValueRange); return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:  *outSize = 2 * sizeof(UInt32); return 0;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelCount * sizeof(AudioChannelDescription));
            return 0;
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamPropertySize(const AudioObjectPropertyAddress* inAddress, UInt32* outSize)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:              *outSize = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner:              *outSize = sizeof(AudioObjectID); return 0;
        case kAudioObjectPropertyOwnedObjects:       *outSize = 0; return 0;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:            *outSize = sizeof(UInt32); return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:     *outSize = sizeof(AudioStreamBasicDescription); return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: *outSize = 2 * sizeof(AudioStreamRangedDescription); return 0;
        default: return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Property entry points

static OSStatus Mac2Phone_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;

    switch (inObjectID) {
        case kObjectID_PlugIn:        return GetPlugInPropertySize(inAddress, outDataSize);
        case kObjectID_Device:        return GetDevicePropertySize(inAddress, outDataSize);
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: return GetStreamPropertySize(inAddress, outDataSize);
        default:                      return kAudioHardwareBadObjectError;
    }
}

static Boolean Mac2Phone_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress)
{
    if (!IsKnownObject(inObjectID)) return false;
    UInt32 size = 0;
    return Mac2Phone_GetPropertyDataSize(inDriver, inObjectID, inClientPID, inAddress, 0, NULL, &size) == 0;
}

static OSStatus Mac2Phone_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    (void)inClientPID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsKnownObject(inObjectID)) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;

    *outIsSettable = false;
    if (inObjectID == kObjectID_Device && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        *outIsSettable = true;
    } else if ((inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output)
               && (inAddress->mSelector == kAudioStreamPropertyIsActive
                   || inAddress->mSelector == kAudioStreamPropertyVirtualFormat
                   || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        *outIsSettable = true;
    }
    return 0;
}

#define WRITE_SCALAR(type, value)                                        \
    do {                                                                 \
        if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
        *((type*)outData) = (value);                                     \
        *outDataSize = sizeof(type);                                     \
        return 0;                                                        \
    } while (0)

static OSStatus Mac2Phone_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)inClientPID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL || (outData == NULL && inDataSize > 0)) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_PlugIn) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass: WRITE_SCALAR(AudioClassID, kAudioObjectClassID);
            case kAudioObjectPropertyClass:     WRITE_SCALAR(AudioClassID, kAudioPlugInClassID);
            case kAudioObjectPropertyOwner:     WRITE_SCALAR(AudioObjectID, kAudioObjectUnknown);
            case kAudioObjectPropertyManufacturer:
                WRITE_SCALAR(CFStringRef, CFSTR(kManufacturerName));
            case kAudioPlugInPropertyResourceBundle:
                WRITE_SCALAR(CFStringRef, CFSTR(""));
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return 0; }
                ((AudioObjectID*)outData)[0] = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
                return 0;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareIllegalOperationError;
                CFStringRef uid = *((CFStringRef*)inQualifierData);
                AudioObjectID result = CFEqual(uid, CFSTR(kDeviceUID)) ? kObjectID_Device : kAudioObjectUnknown;
                WRITE_SCALAR(AudioObjectID, result);
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Device) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass: WRITE_SCALAR(AudioClassID, kAudioObjectClassID);
            case kAudioObjectPropertyClass:     WRITE_SCALAR(AudioClassID, kAudioDeviceClassID);
            case kAudioObjectPropertyOwner:     WRITE_SCALAR(AudioObjectID, kObjectID_PlugIn);
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyModelName: WRITE_SCALAR(CFStringRef, CFSTR(kDeviceName));
            case kAudioObjectPropertyManufacturer: WRITE_SCALAR(CFStringRef, CFSTR(kManufacturerName));
            case kAudioDevicePropertyDeviceUID: WRITE_SCALAR(CFStringRef, CFSTR(kDeviceUID));
            case kAudioDevicePropertyModelUID:  WRITE_SCALAR(CFStringRef, CFSTR(kDeviceModelUID));
            case kAudioDevicePropertyTransportType: WRITE_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
            case kAudioDevicePropertyClockDomain:   WRITE_SCALAR(UInt32, 0);
            case kAudioDevicePropertyDeviceIsAlive: WRITE_SCALAR(UInt32, 1);
            case kAudioDevicePropertyDeviceIsRunning: WRITE_SCALAR(UInt32, gIORunningCount > 0 ? 1 : 0);
            case kAudioDevicePropertyDeviceCanBeDefaultDevice: WRITE_SCALAR(UInt32, 1);
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: WRITE_SCALAR(UInt32, 1);
            case kAudioDevicePropertyLatency:       WRITE_SCALAR(UInt32, 0);
            case kAudioDevicePropertySafetyOffset:  WRITE_SCALAR(UInt32, 0);
            case kAudioDevicePropertyIsHidden:      WRITE_SCALAR(UInt32, 0);
            case kAudioDevicePropertyZeroTimeStampPeriod: WRITE_SCALAR(UInt32, kZeroTimeStampPeriod);
            case kAudioDevicePropertyRelatedDevices: {
                if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return 0; }
                ((AudioObjectID*)outData)[0] = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
                return 0;
            }
            case kAudioObjectPropertyControlList:
                *outDataSize = 0;
                return 0;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams: {
                AudioObjectID ids[2];
                UInt32 count = 0;
                if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                    ids[count++] = kObjectID_Stream_Input;
                } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    ids[count++] = kObjectID_Stream_Output;
                } else {
                    ids[count++] = kObjectID_Stream_Input;
                    ids[count++] = kObjectID_Stream_Output;
                }
                UInt32 fits = inDataSize / (UInt32)sizeof(AudioObjectID);
                if (fits < count) count = fits;
                memcpy(outData, ids, count * sizeof(AudioObjectID));
                *outDataSize = count * (UInt32)sizeof(AudioObjectID);
                return 0;
            }
            case kAudioDevicePropertyNominalSampleRate: WRITE_SCALAR(Float64, gSampleRate);
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange ranges[2] = { { 44100.0, 44100.0 }, { 48000.0, 48000.0 } };
                UInt32 fits = inDataSize / (UInt32)sizeof(AudioValueRange);
                UInt32 count = fits < 2 ? fits : 2;
                memcpy(outData, ranges, count * sizeof(AudioValueRange));
                *outDataSize = count * (UInt32)sizeof(AudioValueRange);
                return 0;
            }
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                ((UInt32*)outData)[0] = 1;
                ((UInt32*)outData)[1] = 2;
                *outDataSize = 2 * (UInt32)sizeof(UInt32);
                return 0;
            }
            case kAudioDevicePropertyPreferredChannelLayout: {
                UInt32 needed = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription));
                if (inDataSize < needed) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout* layout = (AudioChannelLayout*)outData;
                memset(layout, 0, needed);
                layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                layout->mNumberChannelDescriptions = kChannelCount;
                layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                *outDataSize = needed;
                return 0;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output) {
        Boolean isInput = (inObjectID == kObjectID_Stream_Input);
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass: WRITE_SCALAR(AudioClassID, kAudioObjectClassID);
            case kAudioObjectPropertyClass:     WRITE_SCALAR(AudioClassID, kAudioStreamClassID);
            case kAudioObjectPropertyOwner:     WRITE_SCALAR(AudioObjectID, kObjectID_Device);
            case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return 0;
            case kAudioStreamPropertyIsActive:
                WRITE_SCALAR(UInt32, (isInput ? gInputStreamActive : gOutputStreamActive) ? 1 : 0);
            case kAudioStreamPropertyDirection: WRITE_SCALAR(UInt32, isInput ? 1 : 0);
            case kAudioStreamPropertyTerminalType:
                WRITE_SCALAR(UInt32, isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
            case kAudioStreamPropertyStartingChannel: WRITE_SCALAR(UInt32, 1);
            case kAudioStreamPropertyLatency:         WRITE_SCALAR(UInt32, 0);
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                FillStreamFormat((AudioStreamBasicDescription*)outData);
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return 0;
            }
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                UInt32 fits = inDataSize / (UInt32)sizeof(AudioStreamRangedDescription);
                UInt32 count = fits < 2 ? fits : 2;
                Float64 rates[2] = { 44100.0, 48000.0 };
                for (UInt32 i = 0; i < count; ++i) {
                    AudioStreamRangedDescription* entry = &((AudioStreamRangedDescription*)outData)[i];
                    memset(entry, 0, sizeof(AudioStreamRangedDescription));
                    FillStreamFormat(&entry->mFormat);
                    entry->mFormat.mSampleRate = rates[i];
                    entry->mSampleRateRange.mMinimum = rates[i];
                    entry->mSampleRateRange.mMaximum = rates[i];
                }
                *outDataSize = count * (UInt32)sizeof(AudioStreamRangedDescription);
                return 0;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

static OSStatus Mac2Phone_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_Device && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 requested = *((const Float64*)inData);
        if (requested != 44100.0 && requested != 48000.0) return kAudioHardwareIllegalOperationError;
        pthread_mutex_lock(&gStateMutex);
        Boolean changed = (requested != gSampleRate);
        pthread_mutex_unlock(&gStateMutex);
        if (changed && gHost != NULL) {
            gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)requested, NULL);
        }
        return 0;
    }

    if ((inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output)) {
        if (inAddress->mSelector == kAudioStreamPropertyIsActive) {
            if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            Boolean active = *((const UInt32*)inData) != 0;
            pthread_mutex_lock(&gStateMutex);
            if (inObjectID == kObjectID_Stream_Input) gInputStreamActive = active;
            else gOutputStreamActive = active;
            pthread_mutex_unlock(&gStateMutex);
            return 0;
        }
        if (inAddress->mSelector == kAudioStreamPropertyVirtualFormat
            || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat) {
            if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription* format = (const AudioStreamBasicDescription*)inData;
            if (format->mFormatID != kAudioFormatLinearPCM) return kAudioDeviceUnsupportedFormatError;
            if (format->mChannelsPerFrame != kChannelCount) return kAudioDeviceUnsupportedFormatError;
            if (format->mSampleRate != 44100.0 && format->mSampleRate != 48000.0) return kAudioDeviceUnsupportedFormatError;
            if (format->mSampleRate != gSampleRate && gHost != NULL) {
                gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)format->mSampleRate, NULL);
            }
            return 0;
        }
    }

    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - IO

static OSStatus Mac2Phone_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (gIORunningCount == 0) {
        memset(gRing, 0, sizeof(gRing));
        gTimeStampCount = 0;
        gAnchorSample   = 0;
        gAnchorHostTime = mach_absolute_time();
        gHostTicksPerFrame = 0;
        EnsureTimebase();
    }
    ++gIORunningCount;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus Mac2Phone_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (gIORunningCount > 0) --gIORunningCount;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus Mac2Phone_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    // The device has no real clock, so we invent a perfectly regular one: the
    // anchor steps forward one ring buffer at a time as host time catches up.
    UInt64 ticksPerRing = (UInt64)(gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod);
    UInt64 now = mach_absolute_time();

    pthread_mutex_lock(&gStateMutex);
    if (gTimeStampCount == 0) {
        gAnchorHostTime = now;
        gAnchorSample = 0;
        gTimeStampCount = 1;
    } else {
        UInt64 next = gAnchorHostTime + ticksPerRing;
        while (now >= next) {
            gAnchorHostTime = next;
            gAnchorSample += kZeroTimeStampPeriod;
            ++gTimeStampCount;
            next = gAnchorHostTime + ticksPerRing;
        }
    }
    *outSampleTime = gAnchorSample;
    *outHostTime   = gAnchorHostTime;
    *outSeed       = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus Mac2Phone_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    Boolean willDo = false;
    Boolean inPlace = true;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            willDo = true;
            break;
        default:
            break;
    }
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = inPlace;
    return 0;
}

static OSStatus Mac2Phone_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus Mac2Phone_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (ioMainBuffer == NULL || inIOBufferFrameSize == 0) return 0;

    Float32* buffer = (Float32*)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        UInt64 start = (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
            UInt64 slot = ((start + frame) & kRingMask) * kChannelCount;
            // Accumulate: several clients can write overlapping ranges in one cycle.
            gRing[slot]     += buffer[frame * kChannelCount];
            gRing[slot + 1] += buffer[frame * kChannelCount + 1];
        }
        return 0;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        UInt64 start = (UInt64)inIOCycleInfo->mInputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
            UInt64 slot = ((start + frame) & kRingMask) * kChannelCount;
            buffer[frame * kChannelCount]     = gRing[slot];
            buffer[frame * kChannelCount + 1] = gRing[slot + 1];
            // Clear behind the reader so silence stays silent instead of looping.
            gRing[slot]     = 0.0f;
            gRing[slot + 1] = 0.0f;
        }
        return 0;
    }

    return 0;
}

static OSStatus Mac2Phone_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}
