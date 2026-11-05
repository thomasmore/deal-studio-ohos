// Host stand-in for OpenHarmony's hilog, for tools/usbnet-tunnel-test.cpp only:
// the tunnel's log lines are dropped.
#pragma once
#define LOG_APP 0
#define OH_LOG_INFO(type, ...) ((void)0)
#define OH_LOG_ERROR(type, ...) ((void)0)
