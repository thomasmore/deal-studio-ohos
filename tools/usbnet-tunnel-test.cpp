// Host test for the USB network's tunnel (entry/src/main/cpp/usbnet_tunnel.h),
// against a fake tun (a SOCK_SEQPACKET socketpair: one read is one packet, like
// a tun) and a fake gnirehtet relay (a TCP server on 127.0.0.1). Run it under
// ThreadSanitizer and AddressSanitizer:
//
//   for san in thread address; do
//     g++ -std=c++17 -g -O1 -Wall -Wextra -Werror -fsanitize=$san -I entry/src/main/cpp -I tools/usbnet-host-stubs tools/usbnet-tunnel-test.cpp -o /tmp/usbnet-tunnel-test-$san -pthread
//     setarch "$(uname -m)" -R /tmp/usbnet-tunnel-test-$san || break   # TSan needs ASLR off on recent kernels
//   done

#include "usbnet_tunnel.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
using usbnet::UniqueFd;

int g_failures = 0;

void Check(bool ok, const std::string &what)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
    if (!ok) {
        g_failures++;
    }
}

std::vector<uint8_t> Packet(size_t length, uint8_t d0, uint8_t d1, uint8_t d2, uint8_t d3, uint8_t fill)
{
    std::vector<uint8_t> p(length, fill);
    p[0] = 0x45;
    p[2] = static_cast<uint8_t>(length >> 8);
    p[3] = static_cast<uint8_t>(length & 0xff);
    p[16] = d0;
    p[17] = d1;
    p[18] = d2;
    p[19] = d3;
    return p;
}

bool ReadExact(int fd, uint8_t *out, size_t n, int timeoutMs)
{
    auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
    size_t have = 0;
    while (have < n) {
        auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
        pollfd pfd{fd, POLLIN, 0};
        if (left <= 0 || poll(&pfd, 1, static_cast<int>(left)) <= 0) {
            return false;
        }
        ssize_t got = recv(fd, out + have, n - have, 0);
        if (got <= 0) {
            return false;
        }
        have += static_cast<size_t>(got);
    }
    return true;
}

/** One packet from the fake tun, or empty after timeoutMs. */
std::vector<uint8_t> ReadTun(int fd, int timeoutMs)
{
    pollfd pfd{fd, POLLIN, 0};
    if (poll(&pfd, 1, timeoutMs) <= 0) {
        return {};
    }
    std::vector<uint8_t> buf(70000);
    ssize_t n = recv(fd, buf.data(), buf.size(), 0);
    buf.resize(n > 0 ? static_cast<size_t>(n) : 0);
    return buf;
}

/** A fake relay: listens on an ephemeral loopback port. */
class FakeRelay {
public:
    FakeRelay() : listen_(socket(AF_INET, SOCK_STREAM, 0))
    {
        int one = 1;
        setsockopt(listen_.Get(), SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        bind(listen_.Get(), reinterpret_cast<sockaddr *>(&addr), sizeof(addr));
        listen(listen_.Get(), 4);
        socklen_t len = sizeof(addr);
        getsockname(listen_.Get(), reinterpret_cast<sockaddr *>(&addr), &len);
        port_ = ntohs(addr.sin_port);
    }

    int Port() const { return port_; }

    /** Accepts the tunnel and sends it a client id; an invalid fd after timeoutMs. */
    UniqueFd Accept(int timeoutMs)
    {
        pollfd pfd{listen_.Get(), POLLIN, 0};
        if (poll(&pfd, 1, timeoutMs) <= 0) {
            return {};
        }
        UniqueFd client(accept(listen_.Get(), nullptr, nullptr));
        uint8_t id[4] = {0, 0, 0, 7};
        send(client.Get(), id, sizeof(id), MSG_NOSIGNAL);
        return client;
    }

private:
    UniqueFd listen_;
    int port_ = 0;
};

bool WaitStatus(const usbnet::Tunnel &t, const std::string &prefix, int timeoutMs)
{
    auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
    while (Clock::now() < deadline) {
        if (t.Status().rfind(prefix, 0) == 0) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return false;
}

long MsSince(Clock::time_point t)
{
    return static_cast<long>(std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t).count());
}

void TestTraffic()
{
    int pair[2];
    socketpair(AF_UNIX, SOCK_SEQPACKET, 0, pair);
    UniqueFd tun(pair[0]);
    UniqueFd phone(pair[1]);  // the phone's side of the fake tun
    FakeRelay relay;
    auto tunnel = std::make_unique<usbnet::Tunnel>(tun.Get(), relay.Port());

    UniqueFd conn = relay.Accept(3000);
    Check(conn.Valid(), "tunnel connects to the relay");
    Check(WaitStatus(*tunnel, "connected", 2000), "status becomes 'connected'");

    // Up: a packet to 10.0.2.2 is dropped, the next one goes through intact.
    auto blocked = Packet(60, 10, 0, 2, 2, 0x11);
    auto normal = Packet(1500, 8, 8, 8, 8, 0x22);
    send(phone.Get(), blocked.data(), blocked.size(), 0);
    send(phone.Get(), normal.data(), normal.size(), 0);
    std::vector<uint8_t> got(normal.size());
    Check(ReadExact(conn.Get(), got.data(), got.size(), 2000) && got == normal,
          "up: the packet reaches the relay intact, 10.0.2.2 does not");
    pollfd pfd{conn.Get(), POLLIN, 0};
    Check(poll(&pfd, 1, 200) == 0, "up: nothing else arrives (10.0.2.2 dropped)");

    // Down: two packets sent in odd pieces come out as two whole packets.
    auto a = Packet(40, 10, 0, 0, 2, 0x33);
    auto b = Packet(65535, 10, 0, 0, 2, 0x44);
    std::vector<uint8_t> stream(a);
    stream.insert(stream.end(), b.begin(), b.end());
    for (size_t pos = 0, chunk = 7; pos < stream.size(); pos += chunk, chunk = chunk * 5 + 3) {
        size_t n = std::min(chunk, stream.size() - pos);
        send(conn.Get(), stream.data() + pos, n, MSG_NOSIGNAL);
    }
    Check(ReadTun(phone.Get(), 2000) == a, "down: first packet whole");
    Check(ReadTun(phone.Get(), 2000) == b, "down: 64 KB packet whole");
    Check(tunnel->Status().find("connected, up 1 KB, down 64 KB") == 0, "counters: " + tunnel->Status());

    // The relay goes away: back to waiting, then reconnects on its own.
    conn.Reset();
    Check(WaitStatus(*tunnel, "waiting", 2000), "relay gone: status 'waiting'");
    UniqueFd again = relay.Accept(3000);
    Check(again.Valid(), "reconnects by itself");
    Check(WaitStatus(*tunnel, "connected", 2000), "connected again");

    // Stopping while connected and idle is immediate (no 200 ms poll ticks).
    auto t0 = Clock::now();
    tunnel.reset();
    long ms = MsSince(t0);
    Check(ms < 100, "stop while connected took " + std::to_string(ms) + " ms");
}

void TestStopWhileWaiting()
{
    int pair[2];
    socketpair(AF_UNIX, SOCK_SEQPACKET, 0, pair);
    UniqueFd tun(pair[0]);
    UniqueFd phone(pair[1]);
    // A port nobody listens on: the tunnel keeps waiting between tries.
    FakeRelay closed;
    int port = closed.Port();
    { FakeRelay discard = std::move(closed); }
    auto tunnel = std::make_unique<usbnet::Tunnel>(tun.Get(), port);
    Check(WaitStatus(*tunnel, "waiting", 1000), "no relay: status 'waiting'");
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    auto t0 = Clock::now();
    tunnel.reset();
    long ms = MsSince(t0);
    Check(ms < 100, "stop while waiting to reconnect took " + std::to_string(ms) + " ms");
}

void TestStopDuringHandshake()
{
    int pair[2];
    socketpair(AF_UNIX, SOCK_SEQPACKET, 0, pair);
    UniqueFd tun(pair[0]);
    UniqueFd phone(pair[1]);
    // A listener that never sends the client id, like hdc with no relay behind it.
    FakeRelay silent;
    auto tunnel = std::make_unique<usbnet::Tunnel>(tun.Get(), silent.Port());
    std::this_thread::sleep_for(std::chrono::milliseconds(300));  // connected, waiting for the id
    auto t0 = Clock::now();
    tunnel.reset();
    long ms = MsSince(t0);
    Check(ms < 100, "stop during the 5 s handshake wait took " + std::to_string(ms) + " ms");
}

}  // namespace

int main()
{
    TestTraffic();
    TestStopWhileWaiting();
    TestStopDuringHandshake();
    if (g_failures > 0) {
        std::printf("%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    std::printf("usbnet tunnel: all checks passed\n");
    return EXIT_SUCCESS;
}
