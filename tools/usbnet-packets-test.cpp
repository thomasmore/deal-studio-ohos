// Host test for the USB network's packet framing (entry/src/main/cpp/usbnet_packets.h).
//
//   g++ -std=c++17 -Wall -Wextra -Werror -I entry/src/main/cpp tools/usbnet-packets-test.cpp -o /tmp/usbnet-packets-test
//   /tmp/usbnet-packets-test

#include "usbnet_packets.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

int g_failures = 0;

void Check(bool ok, const char *what)
{
    if (!ok) {
        std::printf("FAIL: %s\n", what);
        g_failures++;
    }
}

// An IPv4 packet of `length` bytes to a.b.c.d, filled after the header with `fill`.
std::vector<uint8_t> Packet(size_t length, uint8_t a = 1, uint8_t b = 1, uint8_t c = 1, uint8_t d = 1,
                            uint8_t fill = 0xab)
{
    std::vector<uint8_t> p(length, fill);
    p[0] = 0x45;
    p[2] = static_cast<uint8_t>(length >> 8);
    p[3] = static_cast<uint8_t>(length & 0xff);
    p[16] = a;
    p[17] = b;
    p[18] = c;
    p[19] = d;
    return p;
}

void Append(std::vector<uint8_t> &to, const std::vector<uint8_t> &p)
{
    to.insert(to.end(), p.begin(), p.end());
}

struct Collect {
    std::vector<size_t> lengths;
    bool refuse = false;
    bool operator()(const uint8_t *, size_t length)
    {
        if (refuse) {
            return false;
        }
        lengths.push_back(length);
        return true;
    }
};

void TestWholePackets()
{
    std::vector<uint8_t> stream;
    Append(stream, Packet(20));
    Append(stream, Packet(1500));
    Append(stream, Packet(60));
    Collect sink;
    auto r = usbnet::SplitIpv4Stream(stream.data(), stream.size(), sink);
    Check(r.status == usbnet::SplitStatus::kOk, "whole: status ok");
    Check(r.consumed == stream.size(), "whole: everything consumed");
    Check(sink.lengths == std::vector<size_t>({20, 1500, 60}), "whole: three packets in order");
}

void TestPartialPacketWaits()
{
    std::vector<uint8_t> stream;
    Append(stream, Packet(100));
    std::vector<uint8_t> second = Packet(200);
    stream.insert(stream.end(), second.begin(), second.begin() + 50);
    Collect sink;
    auto r = usbnet::SplitIpv4Stream(stream.data(), stream.size(), sink);
    Check(r.status == usbnet::SplitStatus::kOk, "partial: status ok");
    Check(r.consumed == 100, "partial: only the whole packet consumed");
    Check(sink.lengths.size() == 1, "partial: one packet handed on");

    // Fewer than 4 bytes: the length is not even known yet.
    Collect sink2;
    auto r2 = usbnet::SplitIpv4Stream(second.data(), 3, sink2);
    Check(r2.status == usbnet::SplitStatus::kOk && r2.consumed == 0 && sink2.lengths.empty(),
          "partial: 3 bytes wait for more");
}

void TestByteByByteMatchesWhole()
{
    // Feed the stream in odd-sized chunks the way recv() might, keeping the
    // unconsumed tail, and check the same packets come out.
    std::vector<uint8_t> stream;
    for (size_t len : {20, 33, 1500, 65535, 40}) {
        Append(stream, Packet(len));
    }
    Collect sink;
    std::vector<uint8_t> buffer;
    size_t pos = 0;
    size_t chunk = 1;
    while (pos < stream.size()) {
        size_t n = std::min(chunk, stream.size() - pos);
        buffer.insert(buffer.end(), stream.begin() + pos, stream.begin() + pos + n);
        pos += n;
        chunk = chunk * 3 + 1;
        auto r = usbnet::SplitIpv4Stream(buffer.data(), buffer.size(), sink);
        Check(r.status == usbnet::SplitStatus::kOk, "chunks: status ok");
        buffer.erase(buffer.begin(), buffer.begin() + r.consumed);
    }
    Check(buffer.empty(), "chunks: nothing left over");
    Check(sink.lengths == std::vector<size_t>({20, 33, 1500, 65535, 40}), "chunks: same packets");
}

void TestMalformed()
{
    std::vector<uint8_t> stream = Packet(40);
    stream[0] = 0x60;  // IPv6
    Collect sink;
    auto r = usbnet::SplitIpv4Stream(stream.data(), stream.size(), sink);
    Check(r.status == usbnet::SplitStatus::kMalformed && r.consumed == 0, "malformed: not IPv4");

    std::vector<uint8_t> shortLen = Packet(40);
    shortLen[2] = 0;
    shortLen[3] = 19;  // shorter than any IPv4 header
    auto r2 = usbnet::SplitIpv4Stream(shortLen.data(), shortLen.size(), sink);
    Check(r2.status == usbnet::SplitStatus::kMalformed, "malformed: length below header");

    std::vector<uint8_t> afterGood;
    Append(afterGood, Packet(30));
    std::vector<uint8_t> bad = Packet(30);
    bad[0] = 0x00;
    Append(afterGood, bad);
    Collect sink3;
    auto r3 = usbnet::SplitIpv4Stream(afterGood.data(), afterGood.size(), sink3);
    Check(r3.status == usbnet::SplitStatus::kMalformed && r3.consumed == 30 && sink3.lengths.size() == 1,
          "malformed: good packet before it still handed on");
}

void TestSinkFailure()
{
    std::vector<uint8_t> stream = Packet(40);
    Collect sink;
    sink.refuse = true;
    auto r = usbnet::SplitIpv4Stream(stream.data(), stream.size(), sink);
    Check(r.status == usbnet::SplitStatus::kSinkFailed && r.consumed == 0, "sink failure reported");
}

void TestRelayLocalhost()
{
    std::vector<uint8_t> local = Packet(40, 10, 0, 2, 2);
    std::vector<uint8_t> other = Packet(40, 10, 0, 2, 3);
    std::vector<uint8_t> v6 = Packet(40, 10, 0, 2, 2);
    v6[0] = 0x60;
    Check(usbnet::IsToRelayLocalhost(local.data(), local.size()), "10.0.2.2 detected");
    Check(!usbnet::IsToRelayLocalhost(other.data(), other.size()), "10.0.2.3 passes");
    Check(!usbnet::IsToRelayLocalhost(v6.data(), v6.size()), "not IPv4: not matched");
    Check(!usbnet::IsToRelayLocalhost(local.data(), 19), "too short: not matched");
}

}  // namespace

int main()
{
    TestWholePackets();
    TestPartialPacketWaits();
    TestByteByByteMatchesWhole();
    TestMalformed();
    TestSinkFailure();
    TestRelayLocalhost();
    if (g_failures > 0) {
        std::printf("%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    std::printf("usbnet packets: all checks passed\n");
    return EXIT_SUCCESS;
}
