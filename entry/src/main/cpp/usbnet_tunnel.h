// The USB network's tunnel: copies IPv4 packets between the VPN's tun fd and
// the gnirehtet relay at 127.0.0.1:<port>. No NAPI here, so the host test
// (tools/usbnet-tunnel-test.cpp) runs it against a fake tun and a fake relay.
//
// Relay protocol (gnirehtet 2.5): on connect the relay sends a 4-byte client id;
// after that each side writes whole IPv4 packets back to back on the stream.
// The framing is in usbnet_packets.h.
//
// If the relay goes away (script stopped, cable pulled) the tunnel stays and
// reconnects every second, so traffic resumes on its own. The threads sleep in
// poll() until there is data or the stop eventfd fires; nothing wakes on a timer
// while the tunnel is idle.

#ifndef VERA_USBNET_TUNNEL_H
#define VERA_USBNET_TUNNEL_H

#include "usbnet_packets.h"

// hilog's OH_LOG_* macros read these two macros; they cannot be constexpr.
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000      // NOLINT(cppcoreguidelines-macro-usage)
#define LOG_TAG "VERA-USBNET"  // NOLINT(cppcoreguidelines-macro-usage)
#include <hilog/log.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <exception>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

namespace usbnet {

constexpr int kHandshakeTimeoutMs = 5000;
constexpr int kReconnectDelayMs = 1000;
/** Room for one more packet behind a partial one; see Tunnel::PumpDown. */
constexpr size_t kDownBufferSize = 2 * (usbnet::kIpv4MaxPacket + 1);

/** An owned file descriptor, closed when it goes out of scope. */
class UniqueFd {
public:
    UniqueFd() = default;
    explicit UniqueFd(int fd) : fd_(fd) {}
    ~UniqueFd() { Reset(); }
    UniqueFd(const UniqueFd &) = delete;
    UniqueFd &operator=(const UniqueFd &) = delete;
    UniqueFd(UniqueFd &&other) noexcept : fd_(std::exchange(other.fd_, -1)) {}
    UniqueFd &operator=(UniqueFd &&other) noexcept
    {
        if (this != &other) {
            Reset();
            fd_ = std::exchange(other.fd_, -1);
        }
        return *this;
    }

    [[nodiscard]] int Get() const { return fd_; }
    [[nodiscard]] bool Valid() const { return fd_ >= 0; }
    void Reset()
    {
        if (fd_ >= 0) {
            close(fd_);
            fd_ = -1;
        }
    }

private:
    int fd_ = -1;
};

/**
 * A one-way signal threads can poll on. Once Fire()d it stays readable (it is
 * never read), so every poll that includes it returns from then on.
 */
class Signal {
public:
    Signal() : fd_(eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK))
    {
        if (!fd_.Valid()) {
            throw std::system_error(errno, std::generic_category(), "eventfd");
        }
    }

    void Fire()
    {
        uint64_t one = 1;
        // A full counter (EAGAIN) still leaves it readable, which is all we need.
        ssize_t ignored = write(fd_.Get(), &one, sizeof(one));
        (void)ignored;
    }

    [[nodiscard]] bool Fired() const
    {
        pollfd pfd{fd_.Get(), POLLIN, 0};
        return poll(&pfd, 1, 0) > 0;
    }

    [[nodiscard]] int Fd() const { return fd_.Get(); }

private:
    UniqueFd fd_;
};

enum class Wait { kReady, kStopped, kTimeout, kError };

/**
 * Waits until fd is ready for `events` or any of the signals fires.
 * timeoutMs < 0 waits for as long as it takes.
 */
inline Wait WaitFor(int fd, short events, const Signal &stop, const Signal *also, int timeoutMs)
{
    pollfd fds[3] = {{fd, events, 0}, {stop.Fd(), POLLIN, 0}, {also != nullptr ? also->Fd() : -1, POLLIN, 0}};
    nfds_t count = also != nullptr ? 3 : 2;
    while (true) {
        int r = poll(fds, count, timeoutMs);
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            return Wait::kError;
        }
        if (r == 0) {
            return Wait::kTimeout;
        }
        if (fds[1].revents != 0 || (count == 3 && fds[2].revents != 0)) {
            return Wait::kStopped;
        }
        return Wait::kReady;
    }
}

/** The tunnel between one VPN tun fd and the relay; owns its threads. */
class Tunnel {
public:
    // Buffers are allocated here, where a failure is still an exception the
    // caller sees; nothing in the threads allocates, so nothing there throws.
    Tunnel(int tunFd, int port)
        : tun_(tunFd), port_(port), upBuf_(usbnet::kIpv4MaxPacket + 1), downBuf_(kDownBufferSize),
          thread_([this] { Run(); })
    {
    }

    ~Tunnel()
    {
        stop_.Fire();
        if (thread_.joinable()) {
            thread_.join();
        }
    }

    // The threads hold `this`: a Tunnel never moves.
    Tunnel(const Tunnel &) = delete;
    Tunnel &operator=(const Tunnel &) = delete;
    Tunnel(Tunnel &&) = delete;
    Tunnel &operator=(Tunnel &&) = delete;

    [[nodiscard]] std::string Status() const
    {
        std::string s;
        {
            std::lock_guard<std::mutex> lock(statusMutex_);
            s = status_;
        }
        if (s == "connected") {
            s += ", up " + std::to_string(up_.load() / 1024) + " KB, down " +
                 std::to_string(down_.load() / 1024) + " KB";
        }
        return s;
    }

private:
    void SetStatus(const char *status)
    {
        std::lock_guard<std::mutex> lock(statusMutex_);
        if (status_ != status) {
            OH_LOG_INFO(LOG_APP, "%{public}s", status);
            status_ = status;
        }
    }

    bool WriteAll(int fd, const uint8_t *data, size_t size, bool isSocket, const Signal *also)
    {
        while (size > 0) {
            ssize_t w = isSocket ? send(fd, data, size, MSG_NOSIGNAL) : write(fd, data, size);
            if (w < 0) {
                if (errno == EINTR) {
                    continue;
                }
                if ((errno == EAGAIN || errno == EWOULDBLOCK) &&
                    WaitFor(fd, POLLOUT, stop_, also, -1) == Wait::kReady) {
                    continue;
                }
                return false;
            }
            data += w;
            size -= static_cast<size_t>(w);
        }
        return true;
    }

    /** Connects and reads the relay's client id; an invalid fd if the relay is not there. */
    UniqueFd ConnectRelay()
    {
        UniqueFd sock(socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0));
        if (!sock.Valid()) {
            return {};
        }
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(static_cast<uint16_t>(port_));
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        // The BSD socket API takes a sockaddr *; there is no cast-free way.
        if (connect(sock.Get(), reinterpret_cast<sockaddr *>(&addr),  // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast)
                    sizeof(addr)) != 0) {
            return {};
        }
        // hdc accepts the connection even with no relay behind it and then
        // closes it, so the client id is what says the relay is really there.
        uint8_t id[4];
        size_t have = 0;
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(kHandshakeTimeoutMs);
        while (have < sizeof(id)) {
            auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - std::chrono::steady_clock::now()).count();
            if (left <= 0 || WaitFor(sock.Get(), POLLIN, stop_, nullptr, static_cast<int>(left)) != Wait::kReady) {
                return {};
            }
            ssize_t got = recv(sock.Get(), id + have, sizeof(id) - have, 0);
            if (got <= 0) {
                return {};
            }
            have += static_cast<size_t>(got);
        }
        return sock;
    }

    /** tun -> relay. One read() of the tun fd is one packet. Fires done when it ends. */
    void PumpUp(int sock, Signal &done)
    {
        std::vector<uint8_t> &buf = upBuf_;
        while (WaitFor(tun_, POLLIN, stop_, &done, -1) == Wait::kReady) {
            ssize_t n = read(tun_, buf.data(), buf.size());
            if (n < 0) {
                if (errno == EAGAIN || errno == EINTR) {
                    continue;
                }
                break;
            }
            const auto size = static_cast<size_t>(n);
            if (!usbnet::IsIpv4(buf.data(), size) || usbnet::IsToRelayLocalhost(buf.data(), size)) {
                continue;  // the relay speaks IPv4 only; 10.0.2.2 is never forwarded
            }
            if (!WriteAll(sock, buf.data(), size, true, &done)) {
                break;
            }
            up_ += size;
        }
        done.Fire();
        shutdown(sock, SHUT_RDWR);  // wakes PumpDown
    }

    /** relay -> tun. The stream is split back into packets by the IPv4 total length. */
    void PumpDown(int sock, Signal &done)
    {
        // Holds at most one partial packet plus a full recv, so it never fills up.
        std::vector<uint8_t> &buf = downBuf_;
        size_t have = 0;
        while (WaitFor(sock, POLLIN, stop_, &done, -1) == Wait::kReady) {
            ssize_t n = recv(sock, buf.data() + have, buf.size() - have, 0);
            if (n <= 0) {
                break;
            }
            have += static_cast<size_t>(n);
            auto result = usbnet::SplitIpv4Stream(buf.data(), have, [this, &done](const uint8_t *p, size_t len) {
                if (!WriteAll(tun_, p, len, false, &done)) {
                    return false;
                }
                down_ += len;
                return true;
            });
            if (result.status != usbnet::SplitStatus::kOk) {
                if (result.status == usbnet::SplitStatus::kMalformed) {
                    OH_LOG_ERROR(LOG_APP, "stream out of step, reconnecting");
                }
                break;
            }
            if (result.consumed > 0) {
                memmove(buf.data(), buf.data() + result.consumed, have - result.consumed);
                have -= result.consumed;
            }
        }
        done.Fire();
    }

    void Run()
    {
        while (!stop_.Fired()) {
            SetStatus("waiting for the computer (run ./usb-net.sh)");
            UniqueFd sock = ConnectRelay();
            if (!sock.Valid()) {
                // Sleep until the next try, or until we are stopped.
                WaitFor(-1, 0, stop_, nullptr, kReconnectDelayMs);
                continue;
            }
            SetStatus("connected");
            try {
                Signal done;
                std::thread up([this, &sock, &done] { PumpUp(sock.Get(), done); });
                PumpDown(sock.Get(), done);
                done.Fire();
                up.join();
            } catch (const std::exception &e) {
                // No thread or eventfd for this connection: try again after the delay.
                OH_LOG_ERROR(LOG_APP, "connection setup failed: %{public}s", e.what());
                WaitFor(-1, 0, stop_, nullptr, kReconnectDelayMs);
            }
        }
        SetStatus("off");
    }

    const int tun_;  // owned by the VPN connection, not closed here
    const int port_;
    Signal stop_;
    mutable std::mutex statusMutex_;
    std::string status_ = "off";
    std::atomic<uint64_t> up_{0};
    std::atomic<uint64_t> down_{0};
    std::vector<uint8_t> upBuf_;    // used by PumpUp only
    std::vector<uint8_t> downBuf_;  // used by PumpDown only
    std::thread thread_;  // last: starts Run() once everything above exists
};

}  // namespace usbnet

#endif  // VERA_USBNET_TUNNEL_H
