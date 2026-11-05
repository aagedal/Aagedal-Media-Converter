/* Minimal fault-injection dependencies for the extracted, patched C functions.
 * This is not FFmpeg/Whisper ABI or full-library compilation coverage. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#define AVERROR(x) (-(x))
#define AVERROR_EOF (-999)
#define AV_LOG_ERROR 0
#define AV_LOG_INFO 1
#define AV_LOG_DEBUG 2
#define AV_DICT_DONT_STRDUP_VAL 1
#define WHISPER_SAMPLE_RATE 16000
#define AV_ROUND_DOWN 2
static int64_t av_rescale_rnd(int64_t a, int64_t b, int64_t c, int rounding) {
    assert(rounding == AV_ROUND_DOWN);
    __int128 value = (__int128)a * b;
    return (int64_t)(value / c - (value < 0 && value % c != 0));
}
#define WHISPER_SAMPLING_GREEDY 0
#define FFMAX(a,b) ((a) > (b) ? (a) : (b))
#define FFMIN(a,b) ((a) < (b) ? (a) : (b))
#define av_strcasecmp strcasecmp
#define av_isspace isspace
#define av_strnlen strnlen
#define FF_FILTER_FORWARD_STATUS_BACK(a,b) ((void)0)
#define FF_FILTER_FORWARD_WANTED(a,b) ((void)0)
#define FFERROR_NOT_READY (-998)
static void av_log(void *ctx, int level, const char *fmt, ...) {
    (void)ctx; (void)level; (void)fmt;
}
typedef struct AVDictionary { int unused; } AVDictionary;
typedef struct AVFrame { AVDictionary *metadata; } AVFrame;
typedef struct AVIOContext { int error; } AVIOContext;
typedef struct WhisperContext {
    void *ctx_wsp;
    int audio_buffer_fill_size, audio_buffer_vad_size, max_len, index, eof;
    int64_t audio_buffer_start_samples, next_pts;
    float *audio_buffer;
    const char *language, *format;
    bool translate;
    AVIOContext *avio_context;
} WhisperContext;
typedef struct AVFilterLink { int unused; } AVFilterLink;
typedef struct AVFilterContext {
    WhisperContext *priv;
    AVFilterLink **inputs, **outputs;
} AVFilterContext;
struct whisper_full_params {
    const char *language;
    bool translate;
    int n_threads, print_special, print_progress, print_realtime, print_timestamps;
    int max_len, token_timestamps, split_on_word;
};
static int allocation_count, fail_allocation, infer_error, write_error, close_error;
static int metadata_error, metadata_call, fail_metadata_call = 1;
static int last_frame_error, status_sent, input_status, input_ack;
static int segment_count = 1;
static int64_t segment_t0 = 2, segment_t1 = 7;
static const char *segment_text = "";
static char output[65536];
static size_t output_length;
static int live_allocations;
static void *av_malloc(size_t n) {
    if (++allocation_count == fail_allocation) return NULL;
    void *p = malloc(n);
    if (p) live_allocations++;
    return p;
}
static void av_freep(void *arg) {
    void **p = arg;
    if (*p) { free(*p); live_allocations--; }
    *p = NULL;
}
static char *av_strdup(const char *s) {
    char *p = av_malloc(strlen(s)+1);
    if (p) strcpy(p,s);
    return p;
}
static char *av_strireplace(const char *s, const char *from, const char *to) {
    (void)from; (void)to;
    return av_strdup(s); /* Non-JSON cleanup behavior is outside this harness. */
}
static char *av_asprintf(const char *fmt, ...) {
    va_list ap, aq;
    va_start(ap,fmt); va_copy(aq,ap);
    int n = vsnprintf(NULL,0,fmt,ap); va_end(ap);
    char *p = av_malloc((size_t)n+1);
    if (p) vsnprintf(p,(size_t)n+1,fmt,aq);
    va_end(aq); return p;
}
static int av_dict_set(AVDictionary **dict, const char *key, const char *value, int flags) {
    (void)dict; (void)key;
    if (flags == AV_DICT_DONT_STRDUP_VAL) { void *p=(void *)value; av_freep(&p); }
    return ++metadata_call == fail_metadata_call ? metadata_error : 0;
}
static struct whisper_full_params whisper_full_default_params(int mode) {
    (void)mode; return (struct whisper_full_params){0};
}
static int ff_filter_get_nb_threads(AVFilterContext *ctx) { (void)ctx; return 1; }
static int whisper_full(void *ctx, struct whisper_full_params p, float *a, int n) {
    (void)ctx; (void)p; (void)a; (void)n; return infer_error;
}
static int whisper_full_n_segments(void *ctx) { (void)ctx; return segment_count; }
static const char *whisper_full_get_segment_text(void *ctx, int i) { (void)ctx; (void)i; return segment_text; }
static bool whisper_full_get_segment_speaker_turn_next(void *ctx,int i) { (void)ctx; (void)i; return false; }
static int64_t whisper_full_get_segment_t0(void *ctx,int i) { (void)ctx; (void)i; return segment_t0; }
static int64_t whisper_full_get_segment_t1(void *ctx,int i) { (void)ctx; (void)i; return segment_t1; }
static void avio_write(AVIOContext *ctx, const char *buf, size_t n) {
    (void)ctx; assert(output_length+n<sizeof(output));
    memcpy(output+output_length,buf,n); output_length+=n; output[output_length]=0;
}
static void avio_flush(AVIOContext *ctx) { if (write_error) ctx->error=write_error; }
static int avio_closep(AVIOContext **ctx) { *ctx=NULL; return close_error; }
static int ff_inlink_queued_frames(AVFilterLink *link) { (void)link; return 0; }
static int ff_inlink_consume_frame(AVFilterLink *link,AVFrame **frame) { (void)link; (void)frame; return 0; }
static int filter_frame(AVFilterLink *link,AVFrame *frame) { (void)link; (void)frame; return 0; }
static int ff_inlink_acknowledge_status(AVFilterLink *link,int *status,int64_t *pts) {
    (void)link; *status=input_status; *pts=4; return input_ack;
}
static void ff_outlink_set_status(AVFilterLink *link,int status,int64_t pts) { (void)link; (void)pts; status_sent=status; }
static int push_last_frame(AVFilterLink *link) { (void)link; return last_frame_error; }
/* PATCHED_FUNCTIONS */
int main(int argc, char **argv) {
    float audio[80001]={0};
    AVIOContext io={0};
    WhisperContext w={.ctx_wsp=&io,.audio_buffer_fill_size=4,.audio_buffer=audio,
        .audio_buffer_start_samples=1600,.format="json",.max_len=10,.avio_context=&io};
    AVFilterLink link={0}, *links[]={&link};
    AVFilterContext ctx={.priv=&w,.inputs=links,.outputs=links};
    AVFrame frame={0};
    assert(argc>=2);
    if (!strcmp(argv[1],"escape")) {
        assert(argc==3); segment_text=argv[2];
        w.audio_buffer_fill_size=1600;
        assert(run_transcription(&ctx,&frame,1600)==0);
        assert(w.audio_buffer_fill_size==0);
        fputs(output,stdout);
    } else if (!strcmp(argv[1],"timing")) {
        assert(argc==6);
        w.audio_buffer_start_samples=strtoll(argv[2],NULL,10);
        w.audio_buffer_fill_size=atoi(argv[3]);
        assert(w.audio_buffer_fill_size>0 && w.audio_buffer_fill_size<=80001);
        segment_t0=strtoll(argv[4],NULL,10); segment_t1=strtoll(argv[5],NULL,10);
        segment_text=" [BLANK_AUDIO]";
        assert(run_transcription(&ctx,&frame,w.audio_buffer_fill_size)==0);
        fputs(output,stdout);
    } else if (!strcmp(argv[1],"partial-timing")) {
        w.audio_buffer_start_samples=0; w.audio_buffer_fill_size=49;
        segment_t0=0; segment_t1=INT64_MAX;
        for (int i=0;i<3;i++) {
            assert(run_transcription(&ctx,&frame,17)==0);
            assert(w.audio_buffer_start_samples==(i<2 ? (i+1)*17 : 34));
        }
        assert(w.audio_buffer_fill_size==0);
        fputs(output,stdout);
    } else if (!strcmp(argv[1],"time-overflow")) {
        w.audio_buffer_start_samples=INT64_MAX;
        assert(run_transcription(&ctx,&frame,4)==AVERROR(EINVAL));
        assert(output_length==0 && w.audio_buffer_fill_size==4);
    } else if (!strcmp(argv[1],"allocation")) {
        segment_text="quotes \\\" and \\n and control\001";
        segment_count=2;
        assert(argc==3); fail_allocation=atoi(argv[2]);
        int result=run_transcription(&ctx,&frame,4);
        if (allocation_count>=fail_allocation) {
            assert(result==AVERROR(ENOMEM)); assert(w.audio_buffer_fill_size==4);
        } else assert(result==0);
    } else if (!strcmp(argv[1],"inference")) {
        infer_error=1; assert(run_transcription(&ctx,&frame,4)==AVERROR(EIO));
        assert(output_length==0 && w.audio_buffer_fill_size==4);
    } else if (!strcmp(argv[1],"missing-context")) {
        w.ctx_wsp=NULL; assert(run_transcription(&ctx,&frame,4)==AVERROR(EIO));
    } else if (!strcmp(argv[1],"null-segment")) {
        segment_text=NULL; assert(run_transcription(&ctx,&frame,4)==AVERROR(EIO));
    } else if (!strcmp(argv[1],"write")) {
        write_error=AVERROR(ENOSPC); assert(run_transcription(&ctx,&frame,4)==write_error);
        assert(w.audio_buffer_fill_size==4);
    } else if (!strcmp(argv[1],"metadata")) {
        metadata_error=AVERROR(ENOMEM); assert(run_transcription(&ctx,&frame,4)==metadata_error);
    } else if (!strcmp(argv[1],"metadata-duration")) {
        metadata_error=AVERROR(ENOMEM); fail_metadata_call=2;
        assert(run_transcription(&ctx,&frame,4)==metadata_error);
        assert(w.audio_buffer_fill_size==4);
    } else if (!strcmp(argv[1],"overlap")) {
        for(int i=0;i<8;i++) audio[i]=(float)i;
        w.audio_buffer_fill_size=8;
        assert(run_transcription(&ctx,&frame,2)==0);
        assert(w.audio_buffer_fill_size==6);
        for(int i=0;i<6;i++) assert(audio[i]==(float)(i+2));
    } else if (!strcmp(argv[1],"eof-last-frame")) {
        w.eof=1; last_frame_error=AVERROR(EIO);
        assert(activate(&ctx)==last_frame_error && status_sent==0);
    } else if (!strcmp(argv[1],"eof-close")) {
        w.eof=1; close_error=AVERROR(EIO);
        assert(activate(&ctx)==close_error && status_sent==0);
    } else if (!strcmp(argv[1],"eof-flush")) {
        w.eof=1; write_error=AVERROR(ENOSPC);
        assert(activate(&ctx)==write_error && status_sent==0);
    } else if (!strcmp(argv[1],"upstream-error")) {
        input_ack=1; input_status=AVERROR(EIO);
        assert(activate(&ctx)==0 && status_sent==input_status && !w.eof);
    } else if (!strcmp(argv[1],"eof-success")) {
        input_ack=1; input_status=AVERROR_EOF;
        assert(activate(&ctx)==0 && status_sent==AVERROR_EOF && !w.avio_context);
    } else if (!strcmp(argv[1],"no-speech")) {
        segment_count=0; assert(run_transcription(&ctx,&frame,4)==0);
        assert(w.audio_buffer_fill_size==0 && output_length==0);
    } else assert(0);
    assert(live_allocations==0);
    return 0;
}
