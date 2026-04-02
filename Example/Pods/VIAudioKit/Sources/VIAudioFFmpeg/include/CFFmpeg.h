#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libswresample/swresample.h>
#import <libavutil/avutil.h>
#import <libavutil/opt.h>
#import <libavutil/channel_layout.h>

static const int64_t CFFMPEG_AV_NOPTS_VALUE = AV_NOPTS_VALUE;
static const int CFFMPEG_AVERROR_EOF = AVERROR_EOF;
static const int CFFMPEG_AVERROR_EAGAIN = AVERROR(EAGAIN);
