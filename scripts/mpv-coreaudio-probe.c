// Isolated libmpv failure probe. Never linked into the application.
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <mpv/client.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *mode;
static int created, disposed, injected, invalid_calls, listeners, notifications;
static AudioComponentInstance live[256];
static pthread_mutex_t listener_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    AudioObjectID object;
    AudioObjectPropertyAddress address;
    AudioObjectPropertyListenerProc callback;
    void *context;
} registrations[256];

static void *real_symbol(const char *name) {
    void *symbol = dlsym(RTLD_NEXT, name);
    if (!symbol) { fprintf(stderr, "Missing system symbol: %s\n", name); exit(2); }
    return symbol;
}

static int live_index(AudioComponentInstance unit) {
    for (int i = 0; i < 256; i++) if (live[i] == unit && unit) return i;
    return -1;
}

OSStatus AudioComponentInstanceNew(AudioComponent component, AudioComponentInstance *unit) {
    OSStatus (*original)(AudioComponent, AudioComponentInstance *) = real_symbol(__func__);
    OSStatus result = original(component, unit);
    if (result == noErr) {
        int slot = 0;
        while (slot < 256 && live[slot]) slot++;
        if (slot == 256) exit(2);
        live[slot] = *unit;
        created++;
    }
    return result;
}

OSStatus AudioUnitInitialize(AudioUnit unit) {
    if (!strcmp(mode, "fail-init")) { injected++; return kAudioUnitErr_FailedInitialization; }
    OSStatus (*original)(AudioUnit) = real_symbol(__func__);
    return original(unit);
}

OSStatus AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID property,
                            AudioUnitScope scope, AudioUnitElement element,
                            const void *data, UInt32 size) {
    if (!strcmp(mode, "fail-format") && property == kAudioUnitProperty_StreamFormat) {
        injected++;
        return kAudioUnitErr_FormatNotSupported;
    }
    OSStatus (*original)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                         AudioUnitElement, const void *, UInt32) = real_symbol(__func__);
    return original(unit, property, scope, element, data, size);
}

// Record stale-handle operations without forwarding them to CoreAudio: the
// report must survive the defect so it can identify each invalid cleanup call.
OSStatus AudioOutputUnitStop(AudioUnit unit) {
    if (live_index(unit) < 0) { invalid_calls++; return kAudioUnitErr_Uninitialized; }
    OSStatus (*original)(AudioUnit) = real_symbol(__func__);
    return original(unit);
}

OSStatus AudioUnitUninitialize(AudioUnit unit) {
    if (live_index(unit) < 0) { invalid_calls++; return kAudioUnitErr_Uninitialized; }
    OSStatus (*original)(AudioUnit) = real_symbol(__func__);
    return original(unit);
}

OSStatus AudioComponentInstanceDispose(AudioComponentInstance unit) {
    int slot = live_index(unit);
    if (slot < 0) { invalid_calls++; return kAudioUnitErr_Uninitialized; }
    OSStatus (*original)(AudioComponentInstance) = real_symbol(__func__);
    OSStatus result = original(unit);
    if (result == noErr) { live[slot] = NULL; disposed++; }
    return result;
}

OSStatus AudioObjectAddPropertyListener(AudioObjectID object,
    const AudioObjectPropertyAddress *address, AudioObjectPropertyListenerProc callback, void *context) {
    OSStatus (*original)(AudioObjectID, const AudioObjectPropertyAddress *,
                        AudioObjectPropertyListenerProc, void *) = real_symbol(__func__);
    OSStatus result = original(object, address, callback, context);
    if (result == noErr) {
        pthread_mutex_lock(&listener_lock);
        int slot = 0;
        while (slot < 256 && registrations[slot].callback) slot++;
        if (slot == 256) exit(2);
        registrations[slot].object = object;
        registrations[slot].address = *address;
        registrations[slot].callback = callback;
        registrations[slot].context = context;
        listeners++;
        pthread_mutex_unlock(&listener_lock);
    }
    return result;
}

OSStatus AudioObjectRemovePropertyListener(AudioObjectID object,
    const AudioObjectPropertyAddress *address, AudioObjectPropertyListenerProc callback, void *context) {
    OSStatus (*original)(AudioObjectID, const AudioObjectPropertyAddress *,
                        AudioObjectPropertyListenerProc, void *) = real_symbol(__func__);
    pthread_mutex_lock(&listener_lock);
    OSStatus result = original(object, address, callback, context);
    if (result == noErr) {
        for (int i = 0; i < 256; i++) {
            if (registrations[i].object == object && registrations[i].callback == callback &&
                registrations[i].context == context &&
                registrations[i].address.mSelector == address->mSelector &&
                registrations[i].address.mScope == address->mScope &&
                registrations[i].address.mElement == address->mElement) {
                registrations[i].callback = NULL;
                listeners--;
                break;
            }
        }
    }
    pthread_mutex_unlock(&listener_lock);
    return result;
}

static int notify_default_device(void) {
    int sent = 0;
    // Prevent listener retirement while manually delivering this notification.
    // This exercises libmpv's callback without changing the real default device.
    pthread_mutex_lock(&listener_lock);
    for (int i = 0; i < 256; i++) {
        if (registrations[i].callback && registrations[i].object == kAudioObjectSystemObject &&
            registrations[i].address.mSelector == kAudioHardwarePropertyDefaultOutputDevice) {
            registrations[i].callback(registrations[i].object, 1,
                                      &registrations[i].address, registrations[i].context);
            notifications++;
            sent = 1;
            break;
        }
    }
    pthread_mutex_unlock(&listener_lock);
    return sent;
}

static void option(mpv_handle *player, const char *name, const char *value) {
    if (mpv_set_option_string(player, name, value) < 0) exit(2);
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: probe normal|notify|fail-init|fail-format tone-file\n"); return 2; }
    mode = argv[1];
    int playing = !strcmp(mode, "normal") || !strcmp(mode, "notify");
    if (!playing && strcmp(mode, "fail-init") && strcmp(mode, "fail-format")) return 2;
    int playback_cycles = 0, failure_cycles = 0;
    for (int cycle = 0; cycle < 4; cycle++) {
        mpv_handle *player = mpv_create();
        if (!player) return 2;
        option(player, "config", "no");
        option(player, "terminal", "yes");
        option(player, "msg-level", "all=warn");
        option(player, "load-scripts", "no");
        option(player, "vo", "null");
        option(player, "ao", "coreaudio");
        option(player, "volume", "0");
        option(player, "audio-fallback-to-null", "no");
        if (mpv_initialize(player) < 0) return 2;
        const char *command[] = {"loadfile", argv[2], NULL};
        if (mpv_command(player, command) < 0) return 2;
        int completed = 0;
        int notified = 0;
        for (int tick = 0; tick < 100; tick++) {
            mpv_event *event = mpv_wait_event(player, 0.1);
            if (event->event_id == MPV_EVENT_END_FILE) {
                mpv_event_end_file *end = event->data;
                if (end->reason == MPV_END_FILE_REASON_ERROR) failure_cycles++;
                completed = 1;
                break;
            }
            double position = 0;
            if (playing &&
                mpv_get_property(player, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0 && position > 0.1) {
                if (!strcmp(mode, "notify") && !notified) {
                    notified = notify_default_device();
                    continue;
                }
                if (!strcmp(mode, "notify") && position <= 0.3) continue;
                char *backend = mpv_get_property_string(player, "current-ao");
                if (backend && !strcmp(backend, "coreaudio")) playback_cycles++;
                mpv_free(backend);
                completed = 1;
                break;
            }
        }
        mpv_terminate_destroy(player);
        if (!completed) { fprintf(stderr, "Playback deadline exceeded\n"); return 1; }
    }
    printf("{\"mode\":\"%s\",\"created\":%d,\"disposed\":%d,\"injected\":%d,"
           "\"invalid_calls\":%d,\"listeners_remaining\":%d,\"notifications\":%d,\"playback_cycles\":%d,\"failure_cycles\":%d}\n",
           mode, created, disposed, injected, invalid_calls, listeners, notifications, playback_cycles, failure_cycles);
    return !(created > 0 && created == disposed && invalid_calls == 0 && listeners == 0 &&
             (strcmp(mode, "notify") || notifications == 4) &&
             (playing ? playback_cycles == 4 : injected >= 4 && failure_cycles == 4));
}
