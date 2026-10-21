// Thin C wrapper around IOKit's MMC / SCSITask user client, so Swift can send raw
// SCSI commands (READ, WRITE, GET CONFIGURATION, ...) to an optical drive.
#ifndef CMMC_H
#define CMMC_H

#include <stdint.h>

typedef struct cmmc_drive cmmc_drive;

typedef struct {
    char vendor[64];
    char product[64];
    char bsd_name[64];     // e.g. "disk4"; empty when no disc is inserted
    uint64_t registry_id;  // the authoring service; used to open the drive
    uint64_t stable_id;    // an ancestor that survives exclusive access (the service is
                           // torn down and recreated then); use it to tell drives apart
} cmmc_drive_info;

enum { CMMC_DIR_NONE = 0, CMMC_DIR_IN = 1, CMMC_DIR_OUT = 2 };

/// Fills up to `max` entries; returns the number of authoring-capable drives found.
int cmmc_list(cmmc_drive_info *out, int max);

/// Opens the drive and takes exclusive access (the disc must be unmounted first).
/// On failure returns NULL and stores the IOReturn code in *err.
cmmc_drive *cmmc_open(uint64_t registry_id, int32_t *err);

/// Runs one command. Returns 0 on GOOD status, 2 on CHECK CONDITION (sense fields set),
/// another SCSI status value, or a negative number for a transport (IOReturn) error.
int cmmc_execute(cmmc_drive *d, const uint8_t *cdb, uint8_t cdb_len,
                 void *buf, uint64_t len, int direction, uint32_t timeout_ms,
                 uint8_t *sense_key, uint8_t *asc, uint8_t *ascq, uint64_t *transferred,
                 int32_t *ioreturn);

/// Releases exclusive access and frees the drive.
void cmmc_close(cmmc_drive *d);

#endif
