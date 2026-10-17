/* Diagnostic for the pinned static FFmpeg decoder. SPDX-License-Identifier: LGPL-2.1-or-later */
#include <stdio.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/intreadwrite.h>

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    AVFormatContext *format = NULL;
    if (avformat_open_input(&format, argv[1], NULL, NULL) < 0 ||
        avformat_find_stream_info(format, NULL) < 0) return 1;
    int stream = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (stream < 0) return 1;
    const AVCodec *codec = avcodec_find_decoder(format->streams[stream]->codecpar->codec_id);
    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (!context || avcodec_parameters_to_context(context, format->streams[stream]->codecpar) < 0) return 1;
    context->flags2 |= AV_CODEC_FLAG2_SKIP_MANUAL;
    context->pkt_timebase = format->streams[stream]->time_base;
    if (avcodec_open2(context, codec, NULL) < 0) return 1;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int count = 0;
    while (count < 5 && av_read_frame(format, packet) >= 0) {
        if (packet->stream_index == stream) {
            printf("PACKET pts=%lld flags=%d delay=%d\n", packet->pts, packet->flags, context->delay);
            if (avcodec_send_packet(context, packet) < 0) return 1;
            while (avcodec_receive_frame(context, frame) >= 0) {
                AVFrameSideData *side = av_frame_get_side_data(frame, AV_FRAME_DATA_SKIP_SAMPLES);
                printf("FRAME pts=%lld flags=%d n=%d skip=%u trim=%u delay=%d\n",
                       frame->pts, frame->flags, frame->nb_samples,
                       side ? AV_RL32(side->data) : 0, side ? AV_RL32(side->data + 4) : 0,
                       context->delay);
                av_frame_unref(frame);
                count++;
            }
        }
        av_packet_unref(packet);
    }
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&context);
    avformat_close_input(&format);
    return count == 5 ? 0 : 1;
}
