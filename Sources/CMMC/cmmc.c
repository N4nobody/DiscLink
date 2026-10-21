#include "cmmc.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <stdlib.h>
#include <string.h>

struct cmmc_drive {
    IOCFPlugInInterface **plugin;
    MMCDeviceInterface **mmc;
    SCSITaskDeviceInterface **dev;
};

static void copy_string(CFTypeRef value, char *out, size_t size) {
    out[0] = 0;
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)value, out, (CFIndex)size, kCFStringEncodingUTF8);
    }
}

static CFTypeRef search(io_service_t s, CFStringRef key, IOOptionBits opts) {
    return IORegistryEntrySearchCFProperty(s, kIOServicePlane, key, kCFAllocatorDefault, opts);
}

static CFMutableDictionaryRef authoring_matching(void) {
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(props, CFSTR(kIOPropertySCSITaskDeviceCategory), CFSTR(kIOPropertySCSITaskAuthoringDevice));
    CFDictionarySetValue(match, CFSTR(kIOPropertyMatchKey), props);
    CFRelease(props);
    return match;
}

int cmmc_list(cmmc_drive_info *out, int max) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, authoring_matching(), &it) != KERN_SUCCESS) return 0;
    int n = 0;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        if (n < max) {
            cmmc_drive_info *info = &out[n];
            memset(info, 0, sizeof(*info));
            IORegistryEntryGetRegistryEntryID(s, &info->registry_id);
            // Service -> peripheral device driver -> logical unit nub. Exclusive access
            // replaces the service; the logical unit stays, so it identifies the drive.
            info->stable_id = info->registry_id;
            io_registry_entry_t up = s, parent = 0;
            IOObjectRetain(up);
            for (int level = 0; level < 2; level++) {
                if (IORegistryEntryGetParentEntry(up, kIOServicePlane, &parent) != KERN_SUCCESS) break;
                IOObjectRelease(up);
                up = parent;
                IORegistryEntryGetRegistryEntryID(up, &info->stable_id);
            }
            IOObjectRelease(up);
            CFTypeRef chars = search(s, CFSTR("Device Characteristics"), kIORegistryIterateRecursively | kIORegistryIterateParents);
            if (chars && CFGetTypeID(chars) == CFDictionaryGetTypeID()) {
                copy_string(CFDictionaryGetValue(chars, CFSTR("Vendor Name")), info->vendor, sizeof(info->vendor));
                copy_string(CFDictionaryGetValue(chars, CFSTR("Product Name")), info->product, sizeof(info->product));
            }
            if (chars) CFRelease(chars);
            CFTypeRef bsd = search(s, CFSTR("BSD Name"), kIORegistryIterateRecursively);
            copy_string(bsd, info->bsd_name, sizeof(info->bsd_name));
            if (bsd) CFRelease(bsd);
        }
        n++;
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return n < max ? n : max;
}

cmmc_drive *cmmc_open(uint64_t registry_id, int32_t *err) {
    *err = 0;
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registry_id));
    if (!s) { *err = kIOReturnNoDevice; return NULL; }
    cmmc_drive *d = calloc(1, sizeof(*d));
    SInt32 score = 0;
    IOReturn r = IOCreatePlugInInterfaceForService(s, kIOMMCDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &d->plugin, &score);
    IOObjectRelease(s);
    if (r != kIOReturnSuccess || !d->plugin) { *err = r ? r : kIOReturnError; free(d); return NULL; }
    HRESULT h = (*d->plugin)->QueryInterface(d->plugin, CFUUIDGetUUIDBytes(kIOMMCDeviceInterfaceID), (LPVOID *)&d->mmc);
    if (h != S_OK || !d->mmc) { *err = kIOReturnUnsupported; cmmc_close(d); return NULL; }
    d->dev = (*d->mmc)->GetSCSITaskDeviceInterface(d->mmc);
    if (!d->dev) { *err = kIOReturnUnsupported; cmmc_close(d); return NULL; }
    r = (*d->dev)->ObtainExclusiveAccess(d->dev);
    if (r != kIOReturnSuccess) {
        *err = r;
        (*d->dev)->Release(d->dev); d->dev = NULL;
        cmmc_close(d);
        return NULL;
    }
    return d;
}

int cmmc_execute(cmmc_drive *d, const uint8_t *cdb, uint8_t cdb_len,
                 void *buf, uint64_t len, int direction, uint32_t timeout_ms,
                 uint8_t *sense_key, uint8_t *asc, uint8_t *ascq, uint64_t *transferred,
                 int32_t *ioreturn) {
    *sense_key = 0; *asc = 0; *ascq = 0; *transferred = 0; *ioreturn = 0;
    SCSITaskInterface **task = (*d->dev)->CreateSCSITask(d->dev);
    if (!task) { *ioreturn = kIOReturnNoMemory; return -1; }
    UInt8 c[16] = {0};
    memcpy(c, cdb, cdb_len);
    IOReturn r = (*task)->SetCommandDescriptorBlock(task, c, cdb_len);
    if (r == kIOReturnSuccess && len > 0 && direction != CMMC_DIR_NONE) {
        SCSITaskSGElement range;
        range.address = (mach_vm_address_t)(uintptr_t)buf;
        range.length = len;
        r = (*task)->SetScatterGatherEntries(task, &range, 1, len,
            direction == CMMC_DIR_IN ? kSCSIDataTransfer_FromTargetToInitiator : kSCSIDataTransfer_FromInitiatorToTarget);
    }
    if (r == kIOReturnSuccess) r = (*task)->SetTimeoutDuration(task, timeout_ms);
    SCSI_Sense_Data sense;
    memset(&sense, 0, sizeof(sense));
    SCSITaskStatus status = kSCSITaskStatus_No_Status;
    UInt64 count = 0;
    if (r == kIOReturnSuccess) r = (*task)->ExecuteTaskSync(task, &sense, &status, &count);
    (*task)->Release(task);
    *transferred = count;
    if (r != kIOReturnSuccess) { *ioreturn = r; return -1; }
    if (status == kSCSITaskStatus_CHECK_CONDITION) {
        *sense_key = sense.SENSE_KEY & 0x0F;
        *asc = sense.ADDITIONAL_SENSE_CODE;
        *ascq = sense.ADDITIONAL_SENSE_CODE_QUALIFIER;
    }
    return (int)status;
}

void cmmc_close(cmmc_drive *d) {
    if (!d) return;
    if (d->dev) { (*d->dev)->ReleaseExclusiveAccess(d->dev); (*d->dev)->Release(d->dev); }
    if (d->mmc) (*d->mmc)->Release(d->mmc);
    if (d->plugin) IODestroyPlugInInterface(d->plugin);
    free(d);
}
