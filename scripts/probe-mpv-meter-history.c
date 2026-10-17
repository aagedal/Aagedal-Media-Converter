/* Experimental meter diagnostics. SPDX-License-Identifier: LGPL-2.1-or-later */
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

static double monotonic_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int checked(int result)
{
    if (result < 0) {
        fprintf(stderr, "mpv: %s\n", mpv_error_string(result));
        exit(1);
    }
    return result;
}

static void add_meter(mpv_handle *mpv)
{
    const char *command[] = {"af", "add", "@amc_timing:lavfi=graph=[ebur128=metadata=1,astats=metadata=1:reset=1]:amc-meter-history=yes", NULL};
    checked(mpv_command(mpv, command));
}

int main(int argc, char **argv)
{
    if ((argc != 3 && argc != 4) ||
        (strcmp(argv[2], "null") && strcmp(argv[2], "coreaudio") && strcmp(argv[2], "avfoundation"))) {
        fprintf(stderr, "usage: probe MEDIA {null|coreaudio|avfoundation} [SECOND_AUDIO_ID]\n");
        return 2;
    }
    mpv_handle *mpv = mpv_create();
    if (!mpv)
        return 1;
    checked(mpv_set_option_string(mpv, "config", "no"));
    checked(mpv_set_option_string(mpv, "ao", argv[2]));
    checked(mpv_set_option_string(mpv, "vid", "no"));
    checked(mpv_set_option_string(mpv, "volume", "0"));
    checked(mpv_set_option_string(mpv, "keep-open", "yes"));
    checked(mpv_set_option_string(mpv, "terminal", "no"));
    checked(mpv_initialize(mpv));
    add_meter(mpv);
    const char *load[] = {"loadfile", argv[1], NULL};
    checked(mpv_command(mpv, load));
    double beginning = monotonic_seconds(), poll = 0;
    int action = 0, seen_history = 0, seen_requested_output = 0;
    while (monotonic_seconds() - beginning < 12) {
        mpv_event *event = mpv_wait_event(mpv, 0.01);
        if (event->event_id == MPV_EVENT_SHUTDOWN)
            break;
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = event->data;
            if (end->reason == MPV_END_FILE_REASON_ERROR) {
                fprintf(stderr, "Playback failed: %s\n", mpv_error_string(end->error));
                mpv_terminate_destroy(mpv);
                return 1;
            }
        }
        double elapsed = monotonic_seconds() - beginning;
        if (action == 0 && elapsed > 2) {
            checked(mpv_set_property_string(mpv, "pause", "yes"));
            action++;
        } else if (action == 1 && elapsed > 2.5) {
            checked(mpv_set_property_string(mpv, "pause", "no"));
            action++;
        } else if (action == 2 && elapsed > 4) {
            const char *seek[] = {"seek", "8", "absolute+exact", NULL};
            checked(mpv_command(mpv, seek));
            action++;
        } else if (action == 3 && elapsed > 6) {
            checked(mpv_set_property_string(mpv, "speed", "1.5"));
            action++;
        } else if (action == 4 && elapsed > 8) {
            const char *remove[] = {"af", "remove", "@amc_timing", NULL};
            checked(mpv_command(mpv, remove));
            add_meter(mpv);
            action++;
        } else if (argc == 4 && action == 5 && elapsed > 10) {
            checked(mpv_set_property_string(mpv, "aid", argv[3]));
            action++;
        }
        if (elapsed < poll)
            continue;
        poll = elapsed + 0.1;
        double position = 0, audio_pts = 0, speed = 0;
        int paused = 0, seeking = 0;
        int64_t audio_id = 0;
        int have_speed = mpv_get_property(mpv, "speed", MPV_FORMAT_DOUBLE, &speed) >= 0;
        int have_paused = mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused) >= 0;
        int have_seeking = mpv_get_property(mpv, "seeking", MPV_FORMAT_FLAG, &seeking) >= 0;
        int have_audio_id = mpv_get_property(mpv, "aid", MPV_FORMAT_INT64, &audio_id) >= 0;
        int have_position = mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0;
        int have_audio_pts = mpv_get_property(mpv, "audio-pts", MPV_FORMAT_DOUBLE, &audio_pts) >= 0;
        char *output = NULL;
        mpv_get_property(mpv, "current-ao", MPV_FORMAT_STRING, &output);
        // Restrict the diagnostic driver's string to the known caller input.
        if (output && strcmp(output, argv[2])) {
            fprintf(stderr, "Output substituted: requested %s, actual %s\n", argv[2], output);
            mpv_free(output);
            mpv_terminate_destroy(mpv);
            return 1;
        }
        int output_confirmed = output != NULL;
        if (output_confirmed)
            seen_requested_output = 1;
        mpv_free(output);
        mpv_node metadata;
        int result = mpv_get_property(mpv, "af-metadata/amc_timing", MPV_FORMAT_NODE, &metadata);
        const char *history = NULL;
        if (result >= 0 && metadata.format == MPV_FORMAT_NODE_MAP) {
            for (int n = 0; n < metadata.u.list->num; n++) {
                if (!strcmp(metadata.u.list->keys[n], "amc-meter-history-v1") &&
                    metadata.u.list->values[n].format == MPV_FORMAT_STRING)
                    history = metadata.u.list->values[n].u.string;
            }
        }
        if (history)
            seen_history = 1;
        printf("{\"receipt\":%.9f,\"action\":%d,\"position\":", elapsed, action);
        if (have_position) printf("%.9f", position); else printf("null");
        printf(",\"audio-pts\":");
        if (have_audio_pts) printf("%.9f", audio_pts); else printf("null");
        printf(",\"requested-output\":\"%s\",\"output-confirmed\":%s,\"speed\":", argv[2], output_confirmed ? "true" : "false");
        if (have_speed && isfinite(speed)) printf("%.9f", speed); else printf("null");
        printf(",\"paused\":%s,\"seeking\":%s,\"audio-id\":", have_paused ? (paused ? "true" : "false") : "null", have_seeking ? (seeking ? "true" : "false") : "null");
        if (have_audio_id) printf("%lld", (long long)audio_id); else printf("null");
        printf(",\"history\":%s}\n", history ? history : "null");
        fflush(stdout);
        if (result >= 0)
            mpv_free_node_contents(&metadata);
    }
    mpv_terminate_destroy(mpv);
    if (!seen_history || !seen_requested_output || action != (argc == 4 ? 6 : 5)) {
        fprintf(stderr, "Incomplete capture: history=%d, requested-output=%d, actions=%d\n",
                seen_history, seen_requested_output, action);
        return 1;
    }
    return 0;
}
