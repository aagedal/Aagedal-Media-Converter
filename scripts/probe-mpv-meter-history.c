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

// Cumulative, bounded evidence survives a missed polling snapshot. Command return
// means accepted by the API; events and queried state are separate observations.
struct command_record { const char *name; int action; double start, end; int removal_confirmed; };
struct event_record { const char *name; int action; double time; int64_t entry; };
static struct command_record commands[16];
static struct event_record events[128];
static int command_count, event_count;

static void record_command(const char *name, int action, double start, double beginning)
{
    if (command_count == 16) exit(1);
    commands[command_count++] = (struct command_record){name, action, start,
                                                         monotonic_seconds() - beginning, 0};
}

static void print_lifecycle(int generation)
{
    printf(",\"lifecycle-version\":1,\"requested-generation\":%d,\"commands\":[", generation);
    for (int i = 0; i < command_count; i++) {
        struct command_record *r = &commands[i];
        printf("%s{\"id\":%d,\"name\":\"%s\",\"action\":%d,\"start\":%.9f,\"end\":%.9f,\"result\":0,\"removal-confirmed\":%s}",
               i ? "," : "", i + 1, r->name, r->action, r->start, r->end,
               r->removal_confirmed ? "true" : "false");
    }
    printf("],\"events\":[");
    for (int i = 0; i < event_count; i++) {
        struct event_record *r = &events[i];
        printf("%s{\"id\":%d,\"name\":\"%s\",\"action\":%d,\"time\":%.9f,\"entry\":%lld}",
               i ? "," : "", i + 1, r->name, r->action, r->time, (long long)r->entry);
    }
    printf("]");
}

int main(int argc, char **argv)
{
    if (argc < 3 ||
        (strcmp(argv[2], "null") && strcmp(argv[2], "coreaudio") && strcmp(argv[2], "avfoundation"))) {
        fprintf(stderr, "usage: probe MEDIA {null|coreaudio|avfoundation} [SECOND_AUDIO_ID] [--video] [--steady] [--stall|--short-stall] [--replacement MEDIA]\n");
        return 2;
    }
    int video = 0, steady = 0, stall = 0;
    const char *second_audio = NULL;
    const char *replacement = NULL;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--video")) video = 1;
        else if (!strcmp(argv[i], "--steady")) steady = 1;
        else if (!strcmp(argv[i], "--stall")) stall = 14;
        else if (!strcmp(argv[i], "--short-stall")) stall = 4;
        else if (!strcmp(argv[i], "--replacement") && i + 1 < argc) replacement = argv[++i];
        else if (!second_audio && strspn(argv[i], "0123456789") == strlen(argv[i]) && argv[i][0])
            second_audio = argv[i];
        else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            return 2;
        }
    }
    if (stall && !steady) {
        fprintf(stderr, "--stall requires --steady to avoid hiding lifecycle actions\n");
        return 2;
    }
    if (replacement && steady) {
        fprintf(stderr, "--replacement requires the lifecycle scenario\n");
        return 2;
    }
    mpv_handle *mpv = mpv_create();
    if (!mpv)
        return 1;
    checked(mpv_set_option_string(mpv, "config", "no"));
    checked(mpv_set_option_string(mpv, "ao", argv[2]));
    checked(mpv_set_option_string(mpv, "vid", video ? "auto" : "no"));
    // Decode and synchronize video without creating a presentation window.
    checked(mpv_set_option_string(mpv, "vo", "null"));
    checked(mpv_set_option_string(mpv, "volume", "0"));
    checked(mpv_set_option_string(mpv, "keep-open", "yes"));
    checked(mpv_set_option_string(mpv, "terminal", "no"));
    checked(mpv_initialize(mpv));
    add_meter(mpv);
    double beginning = monotonic_seconds();
    double command_start = monotonic_seconds() - beginning;
    const char *load[] = {"loadfile", argv[1], NULL};
    checked(mpv_command(mpv, load));
    record_command("load", 0, command_start, beginning);
    double poll = 0;
    int action = 0, seen_history = 0, seen_requested_output = 0, seen_video = 0;
    int generation = 0, replaced = 0;
    while (monotonic_seconds() - beginning < (steady ? 18 : replacement ? 16 : 12)) {
        mpv_event *event = mpv_wait_event(mpv, 0.01);
        const char *event_name = NULL;
        int64_t entry = -1;
        switch (event->event_id) {
        case MPV_EVENT_START_FILE:
            event_name = "start-file";
            entry = ((mpv_event_start_file *)event->data)->playlist_entry_id;
            break;
        case MPV_EVENT_FILE_LOADED: event_name = "file-loaded"; break;
        case MPV_EVENT_SEEK: event_name = "seek"; break;
        case MPV_EVENT_PLAYBACK_RESTART: event_name = "playback-restart"; break;
        case MPV_EVENT_END_FILE: event_name = "end-file"; break;
        case MPV_EVENT_QUEUE_OVERFLOW:
            fprintf(stderr, "Event queue overflow; lifecycle evidence lost\n");
            mpv_terminate_destroy(mpv);
            return 1;
        default: break;
        }
        if (event_name) {
            if (event_count == 128) {
                fprintf(stderr, "Lifecycle event evidence capacity exceeded\n");
                mpv_terminate_destroy(mpv);
                return 1;
            }
            events[event_count++] = (struct event_record){event_name, action,
                                        monotonic_seconds() - beginning, entry};
        }
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
        // Drain queued events before issuing the next scheduled transition.
        // Events still have no command ID; the analyzer reports observations,
        // not causal acknowledgments or presentation completion.
        if (event->event_id != MPV_EVENT_NONE) continue;
        command_start = elapsed;
        if (steady) {
            // Continue draining events while deliberately withholding metadata reads.
            if (stall && elapsed > 2 && elapsed < 2 + stall) continue;
        } else if (action == 0 && elapsed > 2) {
            checked(mpv_set_property_string(mpv, "pause", "yes"));
            action++;
            record_command("pause", action, command_start, beginning);
        } else if (action == 1 && elapsed > 2.5) {
            checked(mpv_set_property_string(mpv, "pause", "no"));
            action++;
            record_command("resume", action, command_start, beginning);
        } else if (action == 2 && elapsed > 4) {
            const char *seek[] = {"seek", "8", "absolute+exact", NULL};
            checked(mpv_command(mpv, seek));
            action++;
            record_command("seek", action, command_start, beginning);
        } else if (action == 3 && elapsed > 6) {
            checked(mpv_set_property_string(mpv, "speed", "1.5"));
            action++;
            record_command("speed", action, command_start, beginning);
        } else if (action == 4 && elapsed > 8) {
            const char *remove[] = {"af", "remove", "@amc_timing", NULL};
            checked(mpv_command(mpv, remove));
            mpv_node removed;
            int removal_confirmed = mpv_get_property(mpv, "af-metadata/amc_timing", MPV_FORMAT_NODE, &removed) < 0;
            if (!removal_confirmed) mpv_free_node_contents(&removed);
            add_meter(mpv);
            action++;
            record_command("reinsert", action, command_start, beginning);
            commands[command_count - 1].removal_confirmed = removal_confirmed;
        } else if (second_audio && action == 5 && elapsed > 10) {
            checked(mpv_set_property_string(mpv, "aid", second_audio));
            action++;
            record_command("track", action, command_start, beginning);
        } else if (replacement && !replaced && action == (second_audio ? 6 : 5) && elapsed > 12) {
            const char *replace[] = {"loadfile", replacement, "replace", NULL};
            checked(mpv_command(mpv, replace));
            action++;
            generation++;
            replaced = 1;
            record_command("replace", action, command_start, beginning);
        }
        if (elapsed < poll)
            continue;
        poll = elapsed + 0.1;
        double read_start = monotonic_seconds() - beginning;
        double position = 0, audio_pts = 0, speed = 0;
        int paused = 0, seeking = 0;
        int64_t audio_id = 0;
        int have_speed = mpv_get_property(mpv, "speed", MPV_FORMAT_DOUBLE, &speed) >= 0;
        int have_paused = mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused) >= 0;
        int have_seeking = mpv_get_property(mpv, "seeking", MPV_FORMAT_FLAG, &seeking) >= 0;
        int have_audio_id = mpv_get_property(mpv, "aid", MPV_FORMAT_INT64, &audio_id) >= 0;
        int have_position = mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0;
        int have_audio_pts = mpv_get_property(mpv, "audio-pts", MPV_FORMAT_DOUBLE, &audio_pts) >= 0;
        char *path = NULL;
        int source_confirmed = mpv_get_property(mpv, "path", MPV_FORMAT_STRING, &path) >= 0 &&
                               path && !strcmp(path, generation ? replacement : argv[1]);
        mpv_free(path);
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
        int64_t video_id = 0;
        int have_video = mpv_get_property(mpv, "vid", MPV_FORMAT_INT64, &video_id) >= 0;
        if (have_video && video_id > 0) seen_video = 1;
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
        if (have_position && isfinite(position)) printf("%.9f", position); else printf("null");
        printf(",\"audio-pts\":");
        if (have_audio_pts && isfinite(audio_pts)) printf("%.9f", audio_pts); else printf("null");
        printf(",\"requested-output\":\"%s\",\"output-confirmed\":%s,\"speed\":", argv[2], output_confirmed ? "true" : "false");
        if (have_speed && isfinite(speed)) printf("%.9f", speed); else printf("null");
        printf(",\"paused\":%s,\"seeking\":%s,\"audio-id\":", have_paused ? (paused ? "true" : "false") : "null", have_seeking ? (seeking ? "true" : "false") : "null");
        if (have_audio_id) printf("%lld", (long long)audio_id); else printf("null");
        printf(",\"scenario\":\"%s\",\"poll-stall\":%s,\"video-enabled\":%s,\"video-id\":",
               steady ? "steady" : "lifecycle", stall ? "true" : "false", video ? "true" : "false");
        if (have_video) printf("%lld", (long long)video_id); else printf("null");
        printf(",\"read-start\":%.9f,\"read-end\":%.9f,\"stall-seconds\":%d",
               read_start, monotonic_seconds() - beginning, stall);
        print_lifecycle(generation);
        printf(",\"source-confirmed\":%s", source_confirmed ? "true" : "false");
        printf(",\"replacement-requested\":%s,\"requested-second-audio-id\":",
               replacement ? "true" : "false");
        if (second_audio) printf("%lld", (long long)strtoll(second_audio, NULL, 10)); else printf("null");
        printf(",\"history\":%s}\n", history ? history : "null");
        fflush(stdout);
        if (result >= 0)
            mpv_free_node_contents(&metadata);
    }
    mpv_terminate_destroy(mpv);
    if (!seen_history || !seen_requested_output || (!steady && action != 5 + !!second_audio + !!replacement) || (video && !seen_video)) {
        fprintf(stderr, "Incomplete capture: history=%d, requested-output=%d, actions=%d\n",
                seen_history, seen_requested_output, action);
        return 1;
    }
    return 0;
}
