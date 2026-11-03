// IPv4 packet framing for the USB network (napi_usbnet.cpp), kept free of
// system calls so it can be tested on the host: tools/usbnet-packets-test.cpp.

#ifndef VERA_USBNET_PACKETS_H
#define VERA_USBNET_PACKETS_H

#include <cstddef>
#include <cstdint>

namespace usbnet {

constexpr size_t kIpv4MinHeader = 20;
/** The largest IPv4 packet: the total-length field is 16 bits. */
constexpr size_t kIpv4MaxPacket = 65535;

inline bool IsIpv4(const uint8_t *packet, size_t size)
{
    return size >= kIpv4MinHeader && (packet[0] >> 4) == 4;
}

/**
 * Whether an IPv4 packet is addressed to 10.0.2.2. gnirehtet's relay sends
 * that address to the computer's own localhost (an emulator convention), so
 * such packets are never forwarded: phone apps must not reach the computer's
 * localhost-only services.
 */
inline bool IsToRelayLocalhost(const uint8_t *packet, size_t size)
{
    return IsIpv4(packet, size) && packet[16] == 10 && packet[17] == 0 && packet[18] == 2 && packet[19] == 2;
}

enum class SplitStatus {
    kOk,          // every whole packet was handed on; a partial one may remain
    kMalformed,   // the stream is out of step: not IPv4, or an impossible length
    kSinkFailed,  // the sink refused a packet
};

struct SplitResult {
    size_t consumed = 0;  // bytes at the front of the buffer that were whole packets
    SplitStatus status = SplitStatus::kOk;
};

/**
 * Splits a byte stream of back-to-back IPv4 packets (what the relay sends) at
 * each packet's total length, calling sink(packet, length) -> bool for each
 * whole one. A trailing partial packet is left unconsumed for the next read.
 */
template <typename Sink>
SplitResult SplitIpv4Stream(const uint8_t *data, size_t size, Sink &&sink)
{
    size_t off = 0;
    while (size - off >= 4) {
        const uint8_t *p = data + off;
        if ((p[0] >> 4) != 4) {
            return {off, SplitStatus::kMalformed};
        }
        size_t length = (static_cast<size_t>(p[2]) << 8) | p[3];
        if (length < kIpv4MinHeader) {
            return {off, SplitStatus::kMalformed};
        }
        if (size - off < length) {
            break;
        }
        if (!sink(p, length)) {
            return {off, SplitStatus::kSinkFailed};
        }
        off += length;
    }
    return {off, SplitStatus::kOk};
}

}  // namespace usbnet

#endif  // VERA_USBNET_PACKETS_H
