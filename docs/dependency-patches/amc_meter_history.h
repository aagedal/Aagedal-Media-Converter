/* Experimental mpv meter transport. SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef AMC_METER_HISTORY_H
#define AMC_METER_HISTORY_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define AMC_METER_CAPACITY 128
#define AMC_METER_MAX_RECORD_BYTES 16384

struct amc_meter_record {
    uint64_t sequence;
    char *json;
};

/* Zero-initialize before use. Owned only by mpv's filter thread. */
struct amc_meter_history {
    uint64_t epoch, sequence, evicted, rejected;
    size_t count, head;
    struct amc_meter_record entries[AMC_METER_CAPACITY];
};

static inline void amc_meter_history_clear(struct amc_meter_history *h)
{
    for (size_t i = 0; i < AMC_METER_CAPACITY; i++) {
        free(h->entries[i].json);
        h->entries[i] = (struct amc_meter_record){0};
    }
    h->count = h->head = 0;
    h->epoch++;
}

static inline const struct amc_meter_record *amc_meter_history_at(
    const struct amc_meter_history *h, size_t index)
{
    return index < h->count
        ? &h->entries[(h->head + index) % AMC_METER_CAPACITY] : NULL;
}

static inline bool amc_meter_history_append(struct amc_meter_history *h,
                                          const char *json)
{
    h->sequence++;
    size_t size = 0;
    while (size <= AMC_METER_MAX_RECORD_BYTES && json[size])
        size++;
    if (size > AMC_METER_MAX_RECORD_BYTES) {
        h->rejected++;
        return false;
    }
    char *copy = malloc(size + 1);
    if (!copy) {
        h->rejected++;
        return false;
    }
    memcpy(copy, json, size + 1);
    size_t index = (h->head + h->count) % AMC_METER_CAPACITY;
    if (h->count == AMC_METER_CAPACITY) {
        free(h->entries[index].json);
        h->head = (h->head + 1) % AMC_METER_CAPACITY;
        h->evicted++;
    } else {
        h->count++;
    }
    h->entries[index] = (struct amc_meter_record){h->sequence, copy};
    return true;
}

#endif
