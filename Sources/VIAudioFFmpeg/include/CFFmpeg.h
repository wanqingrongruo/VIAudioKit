#if __has_include(<libavformat/avformat.h>)
// CocoaPods 环境：使用标准路径
#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libswresample/swresample.h>
#import <libavutil/avutil.h>
#import <libavutil/opt.h>
#import <libavutil/channel_layout.h>
#else
// SPM 环境：直接导入 framework 头文件
#import <avformat.h>
#import <avcodec.h>
#import <swresample.h>
#import <avutil.h>
#import <opt.h>
#import <channel_layout.h>
#endif

static const int64_t CFFMPEG_AV_NOPTS_VALUE = AV_NOPTS_VALUE;
static const int CFFMPEG_AVERROR_EOF = AVERROR_EOF;
static const int CFFMPEG_AVERROR_EAGAIN = AVERROR(EAGAIN);
