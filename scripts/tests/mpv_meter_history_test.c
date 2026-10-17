#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "amc_meter_history.h"

static void test_copy_and_repeat_reads(void)
{
    struct amc_meter_history history = {0};
    char payload[] = "{\"peak\":\"-inf\"}";
    assert(amc_meter_history_at(&history, 0) == NULL);
    assert(amc_meter_history_append(&history, payload));
    payload[2] = 'X';
    for (int i = 0; i < 3; i++) {
        const struct amc_meter_record *record = amc_meter_history_at(&history, 0);
        assert(record != NULL);
        assert(record->sequence == 1);
        assert(strcmp(record->json, "{\"peak\":\"-inf\"}") == 0);
        assert(history.count == 1);
        assert(history.sequence == 1);
    }
    assert(amc_meter_history_at(&history, 1) == NULL);
    assert(amc_meter_history_at(&history, SIZE_MAX) == NULL);
    amc_meter_history_clear(&history);
}

static void test_wrap_and_eviction(void)
{
    struct amc_meter_history history = {0};
    const uint64_t total = AMC_METER_CAPACITY * 3 + 7;
    for (uint64_t i = 1; i <= total; i++) {
        char payload[64];
        snprintf(payload, sizeof(payload), "{\"frame\":%" PRIu64 "}", i);
        assert(amc_meter_history_append(&history, payload));
        size_t expected_count = i < AMC_METER_CAPACITY ? (size_t)i : AMC_METER_CAPACITY;
        assert(history.count == expected_count);
        for (size_t j = 0; j < expected_count; j++) {
            uint64_t expected = i - expected_count + j + 1;
            const struct amc_meter_record *record = amc_meter_history_at(&history, j);
            assert(record != NULL);
            assert(record->sequence == expected);
            snprintf(payload, sizeof(payload), "{\"frame\":%" PRIu64 "}", expected);
            assert(strcmp(record->json, payload) == 0);
        }
        assert(amc_meter_history_at(&history, expected_count) == NULL);
    }
    assert(history.sequence == total);
    assert(history.evicted == total - AMC_METER_CAPACITY);
    assert(history.rejected == 0);
    amc_meter_history_clear(&history);
}

static void test_rejection_and_reset(void)
{
    struct amc_meter_history history = {0};
    char *large = malloc(AMC_METER_MAX_RECORD_BYTES + 2);
    assert(large != NULL);
    memset(large, 'x', AMC_METER_MAX_RECORD_BYTES + 1);
    large[AMC_METER_MAX_RECORD_BYTES + 1] = '\0';

    assert(amc_meter_history_append(&history, "first"));
    assert(!amc_meter_history_append(&history, large));
    assert(history.sequence == 2);
    assert(history.rejected == 1);
    assert(history.count == 1);
    assert(strcmp(amc_meter_history_at(&history, 0)->json, "first") == 0);
    assert(amc_meter_history_append(&history, "third"));
    assert(amc_meter_history_at(&history, 1)->sequence == 3);

    large[AMC_METER_MAX_RECORD_BYTES - 1] = '\0';
    assert(amc_meter_history_append(&history, large));
    assert(strlen(amc_meter_history_at(&history, 2)->json) == AMC_METER_MAX_RECORD_BYTES - 1);
    free(large);

    for (size_t i = 0; i < AMC_METER_CAPACITY; i++)
        assert(amc_meter_history_append(&history, "fill"));
    const uint64_t sequence = history.sequence;
    const uint64_t evicted = history.evicted;
    const uint64_t rejected = history.rejected;
    assert(evicted == 3);
    amc_meter_history_clear(&history);
    assert(history.epoch == 1);
    assert(history.count == 0);
    assert(history.head == 0);
    assert(history.sequence == sequence);
    assert(history.evicted == evicted);
    assert(history.rejected == rejected);
    assert(amc_meter_history_at(&history, 0) == NULL);
    assert(amc_meter_history_append(&history, "after reset"));
    assert(amc_meter_history_at(&history, 0)->sequence == sequence + 1);
    assert(strcmp(amc_meter_history_at(&history, 0)->json, "after reset") == 0);
    amc_meter_history_clear(&history);
    amc_meter_history_clear(&history);
    assert(history.epoch == 3);
}

static void test_payload_boundary_and_full_rejection(void)
{
    struct amc_meter_history history = {0};
    char *payload = malloc(AMC_METER_MAX_RECORD_BYTES + 2);
    assert(payload != NULL);
    memset(payload, 'x', AMC_METER_MAX_RECORD_BYTES + 1);
    payload[AMC_METER_MAX_RECORD_BYTES] = '\0';
    assert(amc_meter_history_append(&history, payload));
    assert(strlen(amc_meter_history_at(&history, 0)->json) == AMC_METER_MAX_RECORD_BYTES);
    for (size_t i = 1; i < AMC_METER_CAPACITY; i++)
        assert(amc_meter_history_append(&history, "fill"));
    payload[AMC_METER_MAX_RECORD_BYTES] = 'x';
    payload[AMC_METER_MAX_RECORD_BYTES + 1] = '\0';
    assert(!amc_meter_history_append(&history, payload));
    assert(history.count == AMC_METER_CAPACITY);
    assert(history.evicted == 0);
    assert(history.rejected == 1);
    assert(history.sequence == AMC_METER_CAPACITY + 1);
    assert(amc_meter_history_at(&history, 0)->sequence == 1);
    assert(strlen(amc_meter_history_at(&history, 0)->json) == AMC_METER_MAX_RECORD_BYTES);
    assert(amc_meter_history_at(&history, AMC_METER_CAPACITY - 1)->sequence == AMC_METER_CAPACITY);
    free(payload);
    amc_meter_history_clear(&history);
}

int main(void)
{
    test_copy_and_repeat_reads();
    test_wrap_and_eviction();
    test_rejection_and_reset();
    test_payload_boundary_and_full_rejection();
    puts("Meter history queue checks passed.");
    return 0;
}
